use crate::{
    ledger_lease::normalized_ledger_path,
    ledger_migrations::{MIGRATION_REGISTRY, plan_migrations, validate_history},
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    env, fs,
    fs::OpenOptions,
    io::{self, Write},
    ops::{Add, AddAssign, Neg, Sub},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
};
use time::{
    Date, Duration, Month, OffsetDateTime,
    format_description::well_known::{Iso8601, Rfc3339},
};

pub const LEDGER_VERSION: i64 = 1;
pub const DEFAULT_BASE_CURRENCY: &str = "CNY";
pub const LOCAL_SYNC_GENESIS_CURSOR: &str = "local_cursor_0000";
pub const IDEMPOTENCY_STATE_VERSION: i64 = 1;
const LOCAL_SYNC_DEVICE_ID: &str = "local_device";
const IDEMPOTENCY_MAX_RECORDS: usize = 5_000;
const INSTRUMENT_TYPES: &[&str] = &[
    "cash",
    "equity",
    "fund",
    "crypto",
    "fx_cash",
    "receivable",
    "other",
];

static LEDGER_WRITE_LOCKS: OnceLock<Mutex<BTreeMap<PathBuf, Arc<Mutex<()>>>>> = OnceLock::new();

#[derive(Clone, Copy)]
enum LedgerReadPolicy {
    Current,
    SupportedForValidation,
}

macro_rules! with_ledger_write_lock {
    ($path:expr, $body:block) => {{
        let lock = ledger_write_lock($path);
        let _guard = lock
            .lock()
            .expect("local ledger write lock should not be poisoned");
        $body
    }};
}

fn ledger_write_lock(path: &Path) -> Arc<Mutex<()>> {
    let key = normalized_lock_path(path);
    let mut locks = LEDGER_WRITE_LOCKS
        .get_or_init(|| Mutex::new(BTreeMap::new()))
        .lock()
        .expect("local ledger lock registry should not be poisoned");
    locks
        .entry(key)
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone()
}

fn normalized_lock_path(path: &Path) -> PathBuf {
    normalized_ledger_path(path).unwrap_or_else(|_| {
        if path.is_absolute() {
            path.to_path_buf()
        } else {
            env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .join(path)
        }
    })
}

pub fn empty_document(base_currency: &str) -> Value {
    json!({
        "ledgerVersion": LEDGER_VERSION,
        "baseCurrency": base_currency,
        "metadata": {
            "schema": "LOCAL_LEDGER_FORMAT_V1",
            "dataSourceMode": "real_local"
        },
        "accounts": [],
        "instruments": [],
        "holdings": [],
        "movements": [],
        "movementEntries": [],
        "dcaPlans": [],
        "dcaReminders": [],
        "subscriptions": [],
        "categories": [],
        "counterparties": [],
        "quotes": [],
        "fxRates": [],
        "snapshots": [],
        "aiProposals": [],
        "evidenceRefs": [],
        "anomalies": [],
        "syncState": {
            "cursor": null,
            "nextChangeSequence": 1,
            "pendingChangeIds": []
        },
        "syncChanges": [],
        "idempotencyState": {
            "version": IDEMPOTENCY_STATE_VERSION,
            "records": {}
        },
        "migrations": []
    })
}

pub fn load_or_initialize(path: &Path) -> io::Result<Value> {
    if path.exists() {
        return read_document(path);
    }

    if let Some(document) = recover_unpublished_document(path)? {
        return Ok(document);
    }

    let document = empty_document(DEFAULT_BASE_CURRENCY);
    write_document(path, &document)?;
    Ok(document)
}

pub fn read_document(path: &Path) -> io::Result<Value> {
    read_document_with_policy(path, LedgerReadPolicy::Current)
}

pub fn validate_supported_ledger(path: &Path) -> io::Result<Value> {
    read_document_with_policy(path, LedgerReadPolicy::SupportedForValidation)
}

fn read_document_with_policy(path: &Path, policy: LedgerReadPolicy) -> io::Result<Value> {
    let raw = fs::read_to_string(path)?;
    let mut document: Value = serde_json::from_str(&raw).map_err(invalid_data)?;
    prepare_document_for_read(&mut document, policy).map_err(validation_error)?;
    Ok(document)
}

pub fn write_document(path: &Path, document: &Value) -> io::Result<()> {
    validate_document(document).map_err(validation_error)?;

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let tmp_path = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec_pretty(document).map_err(invalid_data)?;
    let result: io::Result<()> = (|| {
        let mut temporary = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&tmp_path)?;
        temporary.write_all(&bytes)?;
        temporary.sync_all()?;
        drop(temporary);

        fs::rename(&tmp_path, path)?;
        OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)?
            .sync_all()?;
        sync_parent_directory(path)?;
        Ok(())
    })();
    // On failure the temp file is preserved for fail-closed startup recovery. It
    // is never treated as authoritative while the primary ledger exists.
    result?;
    Ok(())
}

fn recover_unpublished_document(path: &Path) -> io::Result<Option<Value>> {
    let tmp_path = path.with_extension("json.tmp");
    if !tmp_path.exists() {
        return Ok(None);
    }
    let metadata = fs::symlink_metadata(&tmp_path)?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "ledger recovery temp must be a regular non-symlink file: {}",
                tmp_path.display()
            ),
        ));
    }

    let raw = fs::read_to_string(&tmp_path)?;
    let mut document: Value = serde_json::from_str(&raw).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "primary ledger is missing and recovery temp is invalid (preserved at {}): {error}",
                tmp_path.display()
            ),
        )
    })?;
    prepare_document_for_read(&mut document, LedgerReadPolicy::Current).map_err(|errors| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "primary ledger is missing and recovery temp failed validation (preserved at {}): {}",
                tmp_path.display(),
                errors.join("; ")
            ),
        )
    })?;

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::rename(&tmp_path, path)?;
    OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)?
        .sync_all()?;
    sync_parent_directory(path)?;
    Ok(Some(document))
}

fn prepare_document_for_read(
    document: &mut Value,
    policy: LedgerReadPolicy,
) -> Result<(), Vec<String>> {
    let version = document
        .as_object()
        .ok_or_else(|| vec!["ledger document must be a JSON object".to_string()])?
        .get("ledgerVersion")
        .and_then(Value::as_i64)
        .filter(|version| *version >= 1)
        .ok_or_else(|| vec!["ledgerVersion must be a positive integer".to_string()])?;

    match policy {
        LedgerReadPolicy::Current if version != LEDGER_VERSION => {
            return Err(vec![format!(
                "ledgerVersion {version} is not the current supported version {LEDGER_VERSION}"
            )]);
        }
        LedgerReadPolicy::SupportedForValidation => {
            if version > LEDGER_VERSION {
                return Err(vec![format!(
                    "ledgerVersion {version} is newer than supported version {LEDGER_VERSION}"
                )]);
            }
            plan_migrations(MIGRATION_REGISTRY, version, LEDGER_VERSION)
                .map_err(|error| vec![error])?;
        }
        LedgerReadPolicy::Current => {}
    }

    match version {
        1 => apply_v1_read_compatibility(document),
        _ => {
            return Err(vec![format!(
                "ledgerVersion {version} has no registered validation implementation"
            )]);
        }
    }
    validate_document_for_version(document, version)
}

#[cfg(unix)]
fn sync_parent_directory(path: &Path) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        OpenOptions::new().read(true).open(parent)?.sync_all()?;
    }
    Ok(())
}

#[cfg(not(unix))]
fn sync_parent_directory(_path: &Path) -> io::Result<()> {
    Ok(())
}

fn apply_v1_read_compatibility(document: &mut Value) {
    let Some(object) = document.as_object_mut() else {
        return;
    };
    object
        .entry("subscriptions".to_string())
        .or_insert_with(|| json!([]));
    object
        .entry("syncChanges".to_string())
        .or_insert_with(|| json!([]));
    object
        .entry("idempotencyState".to_string())
        .or_insert_with(|| {
            json!({
                "version": IDEMPOTENCY_STATE_VERSION,
                "records": {}
            })
        });
    if let Some(sync_state) = object.get_mut("syncState").and_then(Value::as_object_mut) {
        sync_state
            .entry("nextChangeSequence".to_string())
            .or_insert_with(|| json!(1));
    }
}

#[derive(Debug)]
pub enum LedgerError {
    InvalidInput(Vec<String>),
    Conflict(String),
    IdempotencyKeyReused,
    NotFound(String),
    Io(io::Error),
}

#[derive(Debug)]
pub struct IdempotencyRequest {
    key_hash: String,
    request_hash: String,
    operation: String,
    created_at: String,
    expires_at: String,
}

impl IdempotencyRequest {
    pub fn new(
        key_hash: String,
        request_hash: String,
        operation: String,
        created_at: String,
        expires_at: String,
    ) -> Self {
        Self {
            key_hash,
            request_hash,
            operation,
            created_at,
            expires_at,
        }
    }
}

#[derive(Debug)]
pub struct IdempotentResponse {
    pub status_code: u16,
    pub body: Value,
    pub replayed: bool,
}

#[derive(Debug)]
pub struct AiImportContext {
    pub proposal_id: String,
    pub atomic_group_id: String,
    pub movement_id: String,
    pub now: String,
}

fn successful_idempotent_response(status_code: u16, data: Value) -> IdempotentResponse {
    IdempotentResponse {
        status_code,
        body: if status_code == 204 {
            Value::Null
        } else {
            json!({
                "ok": true,
                "data": data
            })
        },
        replayed: false,
    }
}

fn idempotency_replay(
    document: &mut Value,
    request: &IdempotencyRequest,
    now: &str,
) -> Result<Option<IdempotentResponse>, LedgerError> {
    let record = document["idempotencyState"]["records"]
        .get(&request.key_hash)
        .cloned();
    let Some(record) = record else {
        return Ok(None);
    };

    let expires_at = record
        .get("expiresAt")
        .and_then(Value::as_str)
        .expect("validated idempotency record expiresAt should be a string");
    if timestamp_is_at_or_before(expires_at, now) {
        document["idempotencyState"]["records"]
            .as_object_mut()
            .expect("validated idempotency records should be an object")
            .remove(&request.key_hash);
        return Ok(None);
    }

    if record.get("operation").and_then(Value::as_str) != Some(request.operation.as_str())
        || record.get("requestHash").and_then(Value::as_str) != Some(request.request_hash.as_str())
    {
        return Err(LedgerError::IdempotencyKeyReused);
    }

    let status_code = record
        .get("statusCode")
        .and_then(Value::as_u64)
        .and_then(|status| u16::try_from(status).ok())
        .expect("validated idempotency statusCode should fit u16");
    let body = record
        .get("responseBody")
        .expect("validated idempotency responseBody should exist")
        .clone();
    Ok(Some(IdempotentResponse {
        status_code,
        body,
        replayed: true,
    }))
}

fn store_idempotency_response(
    document: &mut Value,
    request: &IdempotencyRequest,
    response: &IdempotentResponse,
) {
    prune_idempotency_records(document, &request.created_at, Some(&request.key_hash));
    document["idempotencyState"]["records"]
        .as_object_mut()
        .expect("validated idempotency records should be an object")
        .insert(
            request.key_hash.clone(),
            json!({
                "requestHash": request.request_hash,
                "operation": request.operation,
                "statusCode": response.status_code,
                "responseBody": response.body,
                "createdAt": request.created_at,
                "expiresAt": request.expires_at
            }),
        );
}

fn prune_idempotency_records(document: &mut Value, now: &str, keep_key: Option<&str>) {
    let records = document["idempotencyState"]["records"]
        .as_object_mut()
        .expect("validated idempotency records should be an object");
    records.retain(|key, record| {
        keep_key == Some(key.as_str())
            || record
                .get("expiresAt")
                .and_then(Value::as_str)
                .is_some_and(|expires_at| !timestamp_is_at_or_before(expires_at, now))
    });

    if records.len() < IDEMPOTENCY_MAX_RECORDS {
        return;
    }

    let mut oldest = records
        .iter()
        .filter(|(key, _)| keep_key != Some(key.as_str()))
        .map(|(key, record)| {
            (
                record
                    .get("createdAt")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                key.clone(),
            )
        })
        .collect::<Vec<_>>();
    oldest.sort_unstable();
    let remove_count = records
        .len()
        .saturating_add(1)
        .saturating_sub(IDEMPOTENCY_MAX_RECORDS);
    for (_, key) in oldest.into_iter().take(remove_count) {
        records.remove(&key);
    }
}

fn timestamp_is_at_or_before(timestamp: &str, other: &str) -> bool {
    let timestamp = OffsetDateTime::parse(timestamp, &Rfc3339)
        .expect("validated timestamp should parse as RFC3339");
    let other =
        OffsetDateTime::parse(other, &Rfc3339).expect("server timestamp should parse as RFC3339");
    timestamp <= other
}

fn idempotent_ledger_write<F>(
    path: &Path,
    request: &IdempotencyRequest,
    status_code: u16,
    mutation: F,
) -> Result<IdempotentResponse, LedgerError>
where
    F: FnOnce(&mut Value) -> Result<Value, LedgerError>,
{
    with_ledger_write_lock!(path, {
        let mut document = read_document(path)?;
        if let Some(response) = idempotency_replay(&mut document, request, &request.created_at)? {
            return Ok(response);
        }

        let data = mutation(&mut document)?;
        let response = successful_idempotent_response(status_code, data);
        store_idempotency_response(&mut document, request, &response);
        write_document(path, &document)?;
        Ok(response)
    })
}

pub fn replay_idempotency(
    path: &Path,
    request: &IdempotencyRequest,
) -> Result<Option<IdempotentResponse>, LedgerError> {
    with_ledger_write_lock!(path, {
        let mut document = read_document(path)?;
        idempotency_replay(&mut document, request, &request.created_at)
    })
}

pub fn persist_idempotent_result(
    path: &Path,
    status_code: u16,
    data: Value,
    request: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, request, status_code, |_| Ok(data))
}

impl From<io::Error> for LedgerError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

pub fn list_accounts(path: &Path) -> io::Result<Value> {
    let document = read_document(path)?;
    let accounts = document["accounts"]
        .as_array()
        .expect("validated local ledger accounts should be an array")
        .iter()
        .map(|account| project_account_for_api_with_document(&document, account))
        .collect::<Vec<_>>();
    Ok(json!(accounts))
}

pub fn get_account(path: &Path, account_id: &str) -> io::Result<Option<Value>> {
    let accounts = list_accounts(path)?;
    Ok(accounts
        .as_array()
        .expect("projected accounts should be an array")
        .iter()
        .find(|account| account.get("id").and_then(Value::as_str) == Some(account_id))
        .cloned())
}

pub fn list_sync_changes(path: &Path, since: Option<&str>) -> Result<(String, Value), LedgerError> {
    let document = read_document(path)?;
    let cursor = sync_cursor_from_document(&document);
    let changes = sync_changes_for_document(&document, since)?;
    Ok((cursor, changes))
}

pub fn sync_cursor_from_document(document: &Value) -> String {
    document
        .get("syncState")
        .and_then(|sync_state| sync_state.get("cursor"))
        .and_then(Value::as_str)
        .filter(|cursor| !cursor.trim().is_empty())
        .unwrap_or(LOCAL_SYNC_GENESIS_CURSOR)
        .to_string()
}

pub fn ack_sync_changes(
    path: &Path,
    input: Value,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 204, |document| {
        let ack_change_ids = sync_ack_change_ids_for_input(document, &input)?;
        let pending_change_ids = document["syncState"]["pendingChangeIds"]
            .as_array_mut()
            .expect("validated local ledger pendingChangeIds should be an array");
        pending_change_ids.retain(|value| {
            value
                .as_str()
                .is_none_or(|change_id| !ack_change_ids.iter().any(|id| id == change_id))
        });
        Ok(Value::Null)
    })
}

pub fn ingest_sync_push(
    path: &Path,
    input: Value,
    authenticated_device_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let (device_id, incoming_changes) =
            sync_push_changes_for_input(&input, authenticated_device_id, now)?;
        let mut accepted_change_ids = Vec::new();
        let mut applied_change_ids = Vec::new();
        let mut skipped_change_ids = Vec::new();
        let mut conflicts = Vec::new();

        for mut incoming_change in incoming_changes {
            let source_change_id = incoming_change
                .get("sourceChangeId")
                .and_then(Value::as_str)
                .expect("validated sourceChangeId should be a string")
                .to_string();
            if sync_source_change_exists(document, &device_id, &source_change_id) {
                skipped_change_ids.push(source_change_id);
                continue;
            }

            let entity_id = incoming_change
                .get("entityId")
                .and_then(Value::as_str)
                .expect("validated entityId should be a string")
                .to_string();
            let payload = incoming_change
                .get("payload")
                .expect("validated account create payload should exist")
                .clone();
            let existing_account = document["accounts"]
                .as_array()
                .expect("validated local ledger accounts should be an array")
                .iter()
                .find(|account| account.get("id").and_then(Value::as_str) == Some(&entity_id))
                .cloned();
            if let Some(existing_account) = existing_account {
                conflicts.push(account_create_sync_conflict(
                    &device_id,
                    &source_change_id,
                    &entity_id,
                    &existing_account,
                    &incoming_change,
                    now,
                ));
                continue;
            }

            document["accounts"]
                .as_array_mut()
                .expect("validated local ledger accounts should be an array")
                .push(payload);
            incoming_change["id"] = json!(next_sync_change_id(document));
            append_sync_log_change(document, incoming_change);
            accepted_change_ids.push(source_change_id.clone());
            applied_change_ids.push(source_change_id);
        }

        Ok(json!({
            "cursor": document["syncState"]["cursor"],
            "acceptedChangeIds": accepted_change_ids,
            "appliedChangeIds": applied_change_ids,
            "skippedChangeIds": skipped_change_ids,
            "conflicts": conflicts
        }))
    })
}

pub fn validate_sync_push_input(
    input: &Value,
    authenticated_device_id: &str,
    now: &str,
) -> Result<(), LedgerError> {
    sync_push_changes_for_input(input, authenticated_device_id, now).map(|_| ())
}

pub fn list_account_anomalies(path: &Path, now: &str) -> io::Result<Value> {
    let document = read_document(path)?;
    Ok(json!(account_anomalies_for_document(&document, now)?))
}

pub fn list_quotes(path: &Path, now: &str) -> io::Result<Value> {
    let document = read_document(path)?;
    Ok(json!(project_quote_items(
        document["quotes"]
            .as_array()
            .expect("validated local ledger quotes should be an array"),
        now
    )))
}

pub fn list_fx_rates(path: &Path, now: &str) -> io::Result<Value> {
    let document = read_document(path)?;
    Ok(json!(project_quote_items(
        document["fxRates"]
            .as_array()
            .expect("validated local ledger fxRates should be an array"),
        now
    )))
}

pub fn refresh_quotes(
    path: &Path,
    input: Value,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let Some(object) = input.as_object() else {
            return Err(LedgerError::InvalidInput(vec![
                "quote refresh input must be a JSON object".to_string(),
            ]));
        };

        let mut errors = object
            .get("_providerErrors")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let mut refreshed_quotes = Vec::new();
        let mut refreshed_fx_rates = Vec::new();

        if let Some(mode) = object.get("mode") {
            match mode.as_str() {
                Some("manual" | "startup" | "scheduled") => {}
                _ => errors.push(quote_refresh_error(
                    "request",
                    None,
                    "mode must be manual, startup, or scheduled",
                    false,
                )),
            }
        }

        match object.get("quotes") {
            Some(Value::Array(items)) => {
                for item in items {
                    match quote_from_refresh_input(item, now) {
                        Ok(quote) => {
                            upsert_quote(document, quote.clone());
                            refreshed_quotes.push(project_quote_item(&quote, now));
                        }
                        Err(error) => errors.push(quote_refresh_error(
                            "instrument",
                            item.get("instrumentId").and_then(Value::as_str),
                            &error,
                            false,
                        )),
                    }
                }
            }
            Some(_) => errors.push(quote_refresh_error(
                "request",
                None,
                "quotes must be an array when present",
                false,
            )),
            None => {}
        }

        match object.get("fxRates") {
            Some(Value::Array(items)) => {
                for item in items {
                    match fx_rate_from_refresh_input(item, now) {
                        Ok(rate) => {
                            if let Err(error) = upsert_fx_rate(document, rate.clone()) {
                                errors.push(quote_refresh_error(
                                    "fx_pair",
                                    fx_pair_target_id(item).as_deref(),
                                    &error,
                                    false,
                                ));
                            } else {
                                refreshed_fx_rates.push(project_quote_item(&rate, now));
                            }
                        }
                        Err(error) => errors.push(quote_refresh_error(
                            "fx_pair",
                            fx_pair_target_id(item).as_deref(),
                            &error,
                            false,
                        )),
                    }
                }
            }
            Some(_) => errors.push(quote_refresh_error(
                "request",
                None,
                "fxRates must be an array when present",
                false,
            )),
            None => {}
        }

        let wrote_any = !refreshed_quotes.is_empty() || !refreshed_fx_rates.is_empty();
        if !wrote_any && errors.is_empty() {
            errors.push(quote_refresh_error(
                "request",
                None,
                "no quote provider is configured; pass quotes/fxRates payload or keep using cache",
                true,
            ));
        }

        let status = if wrote_any && errors.is_empty() {
            "success"
        } else if wrote_any {
            "partial_success"
        } else {
            "offline"
        };

        Ok(json!({
            "status": status,
            "quotes": refreshed_quotes,
            "fxRates": refreshed_fx_rates,
            "errors": errors,
            "completedAt": now
        }))
    })
}

pub fn quote_refresh_targets(path: &Path, input: &Value) -> io::Result<Vec<Value>> {
    let document = read_document(path)?;
    let requested_ids = input
        .get("instruments")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .unwrap_or_else(|| {
            document["holdings"]
                .as_array()
                .expect("validated local ledger holdings should be an array")
                .iter()
                .filter(|holding| {
                    parse_decimal(
                        holding
                            .get("quantity")
                            .and_then(Value::as_str)
                            .unwrap_or("0"),
                    )
                    .is_ok_and(|quantity| quantity > DecimalAmount::ZERO)
                })
                .filter_map(|holding| holding.get("instrumentId").and_then(Value::as_str))
                .map(str::to_string)
                .collect::<Vec<_>>()
        });

    let mut targets = Vec::new();
    for instrument_id in requested_ids {
        if targets.iter().any(|target: &Value| {
            target.get("instrumentId").and_then(Value::as_str) == Some(instrument_id.as_str())
        }) {
            continue;
        }
        let instrument = document["instruments"]
            .as_array()
            .expect("validated local ledger instruments should be an array")
            .iter()
            .find(|instrument| {
                instrument.get("id").and_then(Value::as_str) == Some(instrument_id.as_str())
            });
        let symbol = instrument
            .and_then(|instrument| instrument.get("symbol").and_then(Value::as_str))
            .filter(|symbol| !symbol.trim().is_empty())
            .map(str::to_string)
            .or_else(|| infer_yahoo_symbol_from_id(&instrument_id));
        let quote_currency = instrument
            .and_then(|instrument| instrument.get("quoteCurrency").and_then(Value::as_str))
            .unwrap_or(DEFAULT_BASE_CURRENCY)
            .to_string();
        let display_name = instrument
            .and_then(|instrument| instrument.get("displayName").and_then(Value::as_str))
            .unwrap_or(instrument_id.as_str())
            .to_string();
        targets.push(json!({
            "instrumentId": instrument_id,
            "symbol": symbol,
            "quoteCurrency": quote_currency,
            "displayName": display_name
        }));
    }

    Ok(targets)
}

pub fn fx_refresh_targets(path: &Path, input: &Value) -> io::Result<Vec<Value>> {
    let document = read_document(path)?;
    let base_currency = document
        .get("baseCurrency")
        .and_then(Value::as_str)
        .unwrap_or(DEFAULT_BASE_CURRENCY)
        .to_string();
    let requested_pairs = input
        .get("currencyPairs")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let base = item.get("baseCurrency").and_then(Value::as_str)?;
                    let quote = item.get("quoteCurrency").and_then(Value::as_str)?;
                    Some((base.to_string(), quote.to_string()))
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_else(|| {
            document["accounts"]
                .as_array()
                .expect("validated local ledger accounts should be an array")
                .iter()
                .filter(|account| account.get("status").and_then(Value::as_str) != Some("archived"))
                .flat_map(|account| {
                    account
                        .get("cashBalances")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .filter_map(|balance| balance.get("currency").and_then(Value::as_str))
                        .filter(|currency| *currency != base_currency)
                        .map(|currency| (currency.to_string(), base_currency.clone()))
                        .collect::<Vec<_>>()
                })
                .collect::<Vec<_>>()
        });

    let mut targets = Vec::new();
    for (base, quote) in requested_pairs {
        if base == quote
            || targets.iter().any(|target: &Value| {
                target.get("baseCurrency").and_then(Value::as_str) == Some(base.as_str())
                    && target.get("quoteCurrency").and_then(Value::as_str) == Some(quote.as_str())
            })
        {
            continue;
        }
        targets.push(json!({
            "baseCurrency": base,
            "quoteCurrency": quote,
            "symbol": format!("{}{}=X", base, quote)
        }));
    }

    Ok(targets)
}

pub fn create_account(
    path: &Path,
    input: Value,
    account_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 201, |document| {
        let account = account_from_create_input(&input, account_id, now)?;

        {
            let accounts = document["accounts"]
                .as_array_mut()
                .expect("validated local ledger accounts should be an array");

            if accounts
                .iter()
                .any(|account| account.get("id").and_then(Value::as_str) == Some(account_id))
            {
                return Err(LedgerError::Conflict(format!(
                    "account id already exists: {account_id}"
                )));
            }

            accounts.push(account.clone());
        }

        append_sync_change(document, "account", account_id, "create", &account, now);
        Ok(project_account_for_api(&account))
    })
}

pub fn update_account(
    path: &Path,
    account_id: &str,
    patch: Value,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let account = find_account_mut(document, account_id).ok_or_else(|| {
            LedgerError::NotFound(format!("account does not exist: {account_id}"))
        })?;
        apply_account_patch(account, &patch, now)?;
        let projected = project_account_for_api(account);
        append_sync_change(document, "account", account_id, "update", &projected, now);
        Ok(projected)
    })
}

pub fn archive_account(
    path: &Path,
    account_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let account = find_account_mut(document, account_id).ok_or_else(|| {
            LedgerError::NotFound(format!("account does not exist: {account_id}"))
        })?;
        account["status"] = json!("archived");
        account["visibility"] = json!("archived");
        account["updatedAt"] = json!(now);
        let projected = project_account_for_api(account);
        append_sync_change(document, "account", account_id, "update", &projected, now);
        Ok(projected)
    })
}

pub fn list_holdings(path: &Path) -> io::Result<Value> {
    let document = read_document(path)?;
    Ok(json!(project_holdings_for_api(&document)))
}

pub fn list_holdings_by_account(path: &Path, account_id: &str) -> io::Result<Value> {
    let document = read_document(path)?;
    Ok(json!(
        project_holdings_for_api(&document)
            .into_iter()
            .filter(|holding| holding.get("accountId").and_then(Value::as_str) == Some(account_id))
            .collect::<Vec<_>>()
    ))
}

pub fn list_movements(path: &Path) -> io::Result<Value> {
    let document = read_document(path)?;
    let movements = document["movements"]
        .as_array()
        .expect("validated local ledger movements should be an array")
        .iter()
        .map(project_movement_for_api)
        .collect::<Vec<_>>();
    Ok(json!(movements))
}

pub fn get_movement(path: &Path, movement_id: &str) -> io::Result<Option<Value>> {
    let movements = list_movements(path)?;
    Ok(movements
        .as_array()
        .expect("projected movements should be an array")
        .iter()
        .find(|movement| movement.get("id").and_then(Value::as_str) == Some(movement_id))
        .cloned())
}

pub fn create_movement_draft(
    path: &Path,
    input: Value,
    movement_id: &str,
    atomic_group_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 201, |document| {
        let movement =
            movement_from_create_input(document, &input, movement_id, atomic_group_id, now)?;

        {
            let movements = document["movements"]
                .as_array_mut()
                .expect("validated local ledger movements should be an array");
            movements.push(movement.clone());
        }

        if let Some(entries) = movement.get("entries").and_then(Value::as_array) {
            let movement_entries = document["movementEntries"]
                .as_array_mut()
                .expect("validated local ledger movementEntries should be an array");
            for entry in entries {
                let mut indexed_entry = entry.clone();
                indexed_entry["movementId"] = json!(movement_id);
                indexed_entry["atomicGroupId"] = json!(atomic_group_id);
                movement_entries.push(indexed_entry);
            }
        }

        Ok(project_movement_for_api(&movement))
    })
}

pub fn create_correction_proposal(
    path: &Path,
    input: Value,
    movement_id: &str,
    atomic_group_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let Some(object) = input.as_object() else {
            return Err(LedgerError::InvalidInput(vec![
                "correction input must be a JSON object".to_string(),
            ]));
        };

        let mut errors = Vec::new();
        let target_movement_id = required_string(object, "targetMovementId", &mut errors);
        let reason = required_string(object, "reason", &mut errors);
        let mut proposed_diffs = object
            .get("proposedDiffs")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let replacement_entries = object.get("replacementEntries");

        if !errors.is_empty() {
            return Err(LedgerError::InvalidInput(errors));
        }

        let target_movement_id = target_movement_id.expect("validated correction targetMovementId");
        let reason = reason.expect("validated correction reason");
        let target = document["movements"]
            .as_array()
            .expect("validated local ledger movements should be an array")
            .iter()
            .find(|movement| {
                movement.get("id").and_then(Value::as_str) == Some(target_movement_id.as_str())
            })
            .cloned()
            .ok_or_else(|| {
                LedgerError::NotFound(format!(
                    "target movement does not exist: {target_movement_id}"
                ))
            })?;

        if target.get("status").and_then(Value::as_str) != Some("confirmed")
            && target.get("status").and_then(Value::as_str) != Some("in_transit")
        {
            return Err(LedgerError::Conflict(format!(
                "target movement must be confirmed before correction: {target_movement_id}"
            )));
        }

        if target
            .get("entries")
            .and_then(Value::as_array)
            .is_some_and(|entries| {
                entries
                    .iter()
                    .any(|entry| entry.get("instrumentId").is_some())
            })
        {
            return Err(LedgerError::InvalidInput(vec![
                "investment movement correction is not supported until quantity and cost-basis replacement semantics are explicit"
                    .to_string(),
            ]));
        }

        if pending_correction_exists(document, &target_movement_id) {
            return Err(LedgerError::Conflict(format!(
                "target movement already has a pending correction: {target_movement_id}"
            )));
        }

        let correction_entries = if let Some(replacement_entries) = replacement_entries {
            let (entries, normalized_replacement) = correction_entries_for_replacement(
                document,
                &target,
                replacement_entries,
                movement_id,
            )?;
            if proposed_diffs.is_empty() {
                proposed_diffs.push(json!({
                    "fieldPath": "entries",
                    "oldValue": target["entries"],
                    "newValue": normalized_replacement,
                    "severity": "danger",
                    "reason": reason
                }));
            }
            entries
        } else {
            vec![correction_entry_from_diffs(
                &target,
                &proposed_diffs,
                movement_id,
            )?]
        };
        let target_title = target
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or(target_movement_id.as_str());
        let movement = json!({
            "id": movement_id,
            "atomicGroupId": atomic_group_id,
            "type": "correction",
            "occurredAt": now,
            "recordedAt": now,
            "status": "pending_review",
            "title": format!("更正：{target_title}"),
            "description": reason,
            "entries": correction_entries,
            "tags": ["correction"],
            "source": {
                "kind": "manual",
                "sourceId": target_movement_id,
                "createdBy": "user"
            },
            "createdAt": now,
            "updatedAt": now
        });

        document["movements"]
            .as_array_mut()
            .expect("validated local ledger movements should be an array")
            .push(movement.clone());
        if let Some(entries) = movement.get("entries").and_then(Value::as_array) {
            let movement_entries = document["movementEntries"]
                .as_array_mut()
                .expect("validated local ledger movementEntries should be an array");
            for entry in entries {
                let mut indexed_entry = entry.clone();
                indexed_entry["movementId"] = json!(movement_id);
                indexed_entry["atomicGroupId"] = json!(atomic_group_id);
                movement_entries.push(indexed_entry);
            }
        }

        let mut group = atomic_group_from_movement(&movement, "pending");
        group["operation"] = json!("correction");
        group["targetId"] = json!(target_movement_id);
        group["diffs"] = json!(proposed_diffs);
        group["warnings"] = json!([
            {
                "code": "confirmed_movement_not_modified",
                "message": "该更正不会改写原 confirmed 记录，只会在确认后新增 correction movement。",
                "severity": "info"
            }
        ]);

        Ok(group)
    })
}

pub fn submit_movement_review(
    path: &Path,
    movement_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let movement = find_movement_mut(document, movement_id).ok_or_else(|| {
            LedgerError::NotFound(format!("movement does not exist: {movement_id}"))
        })?;

        match movement.get("status").and_then(Value::as_str) {
            Some("draft") => {
                movement["status"] = json!("pending_review");
                movement["updatedAt"] = json!(now);
            }
            Some("pending_review") => {}
            Some(status) => {
                return Err(LedgerError::Conflict(format!(
                    "movement cannot be submitted for review from status: {status}"
                )));
            }
            None => {
                return Err(LedgerError::InvalidInput(vec![
                    "movement.status must be present".to_string(),
                ]));
            }
        }

        let group = atomic_group_from_movement(movement, "pending");
        Ok(group)
    })
}

pub fn confirm_atomic_group(
    path: &Path,
    atomic_group_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        if let Some(result) = confirm_counterparty_merge_atomic_group(document, atomic_group_id)? {
            return Ok(result);
        }
        if let Some(result) = confirm_ai_movement_atomic_group(document, atomic_group_id, now)? {
            return Ok(result);
        }

        let candidate_movements = document["movements"]
            .as_array()
            .expect("validated local ledger movements should be an array")
            .iter()
            .filter(|movement| {
                movement.get("atomicGroupId").and_then(Value::as_str) == Some(atomic_group_id)
            })
            .cloned()
            .collect::<Vec<_>>();

        if candidate_movements.is_empty() {
            return Err(LedgerError::NotFound(format!(
                "atomic group does not exist: {atomic_group_id}"
            )));
        }

        let mut confirmed_movement_ids = Vec::new();
        for movement in &candidate_movements {
            match movement.get("status").and_then(Value::as_str) {
                Some("draft" | "pending_review") => {
                    apply_movement_effect(document, movement, now)?;
                    confirmed_movement_ids.push(
                        movement
                            .get("id")
                            .and_then(Value::as_str)
                            .expect("validated movement id should be a string")
                            .to_string(),
                    );
                }
                Some("confirmed" | "in_transit") => {}
                Some("cancelled" | "reversed") => {
                    return Err(LedgerError::Conflict(format!(
                        "atomic group cannot be confirmed from movement status: {}",
                        movement
                            .get("status")
                            .and_then(Value::as_str)
                            .expect("status should exist")
                    )));
                }
                Some(status) => {
                    return Err(LedgerError::Conflict(format!(
                        "atomic group cannot be confirmed from movement status: {status}"
                    )));
                }
                None => {
                    return Err(LedgerError::InvalidInput(vec![
                        "movement.status must be present".to_string(),
                    ]));
                }
            }
        }

        if !confirmed_movement_ids.is_empty() {
            let mut movement_sync_changes = Vec::new();
            let movements = document["movements"]
                .as_array_mut()
                .expect("validated local ledger movements should be an array");
            for movement in movements.iter_mut().filter(|movement| {
                movement.get("atomicGroupId").and_then(Value::as_str) == Some(atomic_group_id)
            }) {
                if matches!(
                    movement.get("status").and_then(Value::as_str),
                    Some("draft" | "pending_review")
                ) {
                    movement["status"] = json!(confirmed_status_for_movement(movement));
                    movement["updatedAt"] = json!(now);
                    let movement_id = movement
                        .get("id")
                        .and_then(Value::as_str)
                        .expect("validated movement id should be a string")
                        .to_string();
                    movement_sync_changes.push((
                        movement_id,
                        sync_operation_for_movement(movement),
                        project_movement_for_api(movement),
                    ));
                }
            }
            for (movement_id, operation, payload) in movement_sync_changes {
                append_sync_change(document, "movement", &movement_id, operation, &payload, now);
            }
            mark_dca_reminders_recorded_for_movements(document, &candidate_movements, now);
            mark_subscriptions_charged_for_movements(document, &candidate_movements, now)?;
        }

        Ok(json!({
            "atomicGroupId": atomic_group_id,
            "confirmedMovementIds": confirmed_movement_ids,
            "snapshotInvalidated": !confirmed_movement_ids.is_empty(),
            "ledgerWrite": !confirmed_movement_ids.is_empty(),
            "devOnly": false
        }))
    })
}

pub fn reject_atomic_group(
    path: &Path,
    atomic_group_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 204, |document| {
        if reject_ai_atomic_group(document, atomic_group_id)? {
            return Ok(Value::Null);
        }

        let candidate_movements = document["movements"]
            .as_array()
            .expect("validated local ledger movements should be an array")
            .iter()
            .filter(|movement| {
                movement.get("atomicGroupId").and_then(Value::as_str) == Some(atomic_group_id)
            })
            .cloned()
            .collect::<Vec<_>>();
        if candidate_movements.is_empty() {
            return Err(LedgerError::NotFound(format!(
                "atomic group does not exist: {atomic_group_id}"
            )));
        }
        let movements = document["movements"]
            .as_array_mut()
            .expect("validated local ledger movements should be an array");

        for movement in movements.iter_mut().filter(|movement| {
            movement.get("atomicGroupId").and_then(Value::as_str) == Some(atomic_group_id)
        }) {
            match movement.get("status").and_then(Value::as_str) {
                Some("draft" | "pending_review") => {
                    movement["status"] = json!("cancelled");
                    movement["updatedAt"] = json!(now);
                }
                Some("cancelled") => {}
                Some(status) => {
                    return Err(LedgerError::Conflict(format!(
                        "atomic group cannot be rejected from movement status: {status}"
                    )));
                }
                None => {
                    return Err(LedgerError::InvalidInput(vec![
                        "movement.status must be present".to_string(),
                    ]));
                }
            }
        }

        clear_rejected_subscription_charge_proposals(document, &candidate_movements, now);

        Ok(Value::Null)
    })
}

pub fn list_dca_plans(path: &Path) -> io::Result<Value> {
    let document = read_document(path)?;
    Ok(json!(
        document["dcaPlans"]
            .as_array()
            .expect("validated local ledger dcaPlans should be an array")
            .clone()
    ))
}

pub fn create_dca_plan(
    path: &Path,
    input: Value,
    plan_id: &str,
    reminder_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 201, |document| {
        let plan = dca_plan_from_create_input(document, &input, plan_id, now)?;
        let reminder = dca_reminder_from_plan(&plan, reminder_id);

        document["dcaPlans"]
            .as_array_mut()
            .expect("validated local ledger dcaPlans should be an array")
            .push(plan.clone());
        document["dcaReminders"]
            .as_array_mut()
            .expect("validated local ledger dcaReminders should be an array")
            .push(reminder);

        Ok(plan)
    })
}

pub fn update_dca_plan(
    path: &Path,
    plan_id: &str,
    patch: Value,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        if let Some(object) = patch.as_object()
            && let Some(Value::String(funding_account_id)) = object.get("fundingAccountId")
            && !active_account_exists(document, funding_account_id)
        {
            return Err(LedgerError::InvalidInput(vec![
                "fundingAccountId does not exist or is archived".to_string(),
            ]));
        }

        let projected = {
            let plan = document["dcaPlans"]
                .as_array_mut()
                .expect("validated local ledger dcaPlans should be an array")
                .iter_mut()
                .find(|plan| plan.get("id").and_then(Value::as_str) == Some(plan_id))
                .ok_or_else(|| {
                    LedgerError::NotFound(format!("DCA plan does not exist: {plan_id}"))
                })?;

            apply_dca_plan_patch(plan, &patch, now)?;
            plan.clone()
        };

        sync_open_dca_reminders_for_plan(document, plan_id, &projected, now);
        Ok(projected)
    })
}

pub fn list_due_dca_reminders(path: &Path) -> io::Result<Value> {
    let document = read_document(path)?;
    let reminders = document["dcaReminders"]
        .as_array()
        .expect("validated local ledger dcaReminders should be an array")
        .iter()
        .filter(|reminder| {
            matches!(
                reminder.get("status").and_then(Value::as_str),
                Some("due" | "overdue")
            ) && reminder
                .get("planId")
                .and_then(Value::as_str)
                .is_some_and(|plan_id| is_dca_plan_active(&document, plan_id))
        })
        .cloned()
        .collect::<Vec<_>>();
    Ok(json!(reminders))
}

pub fn skip_dca_reminder(
    path: &Path,
    reminder_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        update_dca_reminder_status(document, reminder_id, "skipped", None, now)
    })
}

pub fn snooze_dca_reminder(
    path: &Path,
    reminder_id: &str,
    input: Value,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let Some(object) = input.as_object() else {
            return Err(LedgerError::InvalidInput(vec![
                "snooze input must be a JSON object".to_string(),
            ]));
        };
        let mut errors = Vec::new();
        let until = required_string(object, "until", &mut errors);
        if let Some(until) = until.as_deref()
            && parse_rfc3339(until).is_none()
        {
            errors.push("until must be an RFC3339 timestamp".to_string());
        }
        if !errors.is_empty() {
            return Err(LedgerError::InvalidInput(errors));
        }

        update_dca_reminder_status(document, reminder_id, "snoozed", until, now)
    })
}

pub fn mark_dca_executed_as_proposal(
    path: &Path,
    reminder_id: &str,
    movement_id: &str,
    atomic_group_id: &str,
    input: &Value,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let Some(object) = input.as_object() else {
            return Err(LedgerError::InvalidInput(vec![
                "DCA execution input must be a JSON object".to_string(),
            ]));
        };
        let mut errors = Vec::new();
        for key in object.keys() {
            if !matches!(
                key.as_str(),
                "holdingAccountId" | "quantity" | "totalCost" | "quoteCurrency" | "executedAt"
            ) {
                errors.push(format!("unsupported DCA execution field: {key}"));
            }
        }
        let holding_account_id = required_string(object, "holdingAccountId", &mut errors);
        let quantity = required_string(object, "quantity", &mut errors);
        let total_cost =
            normalized_required_money(object.get("totalCost"), "totalCost", &mut errors);
        let quote_currency = required_string(object, "quoteCurrency", &mut errors);
        let executed_at = match object.get("executedAt") {
            None | Some(Value::Null) => Some(now.to_string()),
            Some(Value::String(value)) if parse_rfc3339(value).is_some() => Some(value.to_string()),
            _ => {
                errors.push("executedAt must be an RFC3339 timestamp".to_string());
                None
            }
        };
        if let Some(quantity) = quantity.as_deref()
            && !is_positive_decimal_string(quantity)
        {
            errors.push("quantity must be a positive decimal string".to_string());
        }
        if let Some(amount) = total_cost
            .as_ref()
            .and_then(|money| money.get("amount"))
            .and_then(Value::as_str)
            && !is_positive_decimal_string(amount)
        {
            errors.push("totalCost.amount must be a positive decimal string".to_string());
        }
        if !errors.is_empty() {
            return Err(LedgerError::InvalidInput(errors));
        }
        let holding_account_id = holding_account_id.expect("validated holdingAccountId");
        let quantity = quantity.expect("validated quantity");
        let total_cost = total_cost.expect("validated totalCost");
        let total_cost_amount = total_cost["amount"]
            .as_str()
            .expect("validated totalCost.amount")
            .to_string();
        let total_cost_currency = total_cost["currency"]
            .as_str()
            .expect("validated totalCost.currency")
            .to_string();
        let quote_currency = quote_currency.expect("validated quoteCurrency");
        let executed_at = executed_at.expect("validated executedAt");

        let reminder = document["dcaReminders"]
            .as_array()
            .expect("validated local ledger dcaReminders should be an array")
            .iter()
            .find(|reminder| reminder.get("id").and_then(Value::as_str) == Some(reminder_id))
            .cloned()
            .ok_or_else(|| {
                LedgerError::NotFound(format!("DCA reminder does not exist: {reminder_id}"))
            })?;

        match reminder.get("status").and_then(Value::as_str) {
            Some("due" | "overdue" | "snoozed") => {}
            Some(status) => {
                return Err(LedgerError::Conflict(format!(
                    "DCA reminder cannot be recorded from status: {status}"
                )));
            }
            None => {
                return Err(LedgerError::InvalidInput(vec![
                    "DCA reminder.status must be present".to_string(),
                ]));
            }
        }

        if document["movements"]
            .as_array()
            .expect("validated local ledger movements should be an array")
            .iter()
            .any(|movement| {
                movement.get("status").and_then(Value::as_str) == Some("pending_review")
                    && movement
                        .get("source")
                        .and_then(|source| source.get("kind"))
                        .and_then(Value::as_str)
                        == Some("system")
                    && movement
                        .get("source")
                        .and_then(|source| source.get("sourceId"))
                        .and_then(Value::as_str)
                        == Some(reminder_id)
            })
        {
            return Err(LedgerError::Conflict(format!(
                "DCA reminder already has a pending execution proposal: {reminder_id}"
            )));
        }

        let plan_id = reminder
            .get("planId")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                LedgerError::InvalidInput(vec!["DCA reminder.planId is missing".to_string()])
            })?;
        let plan = document["dcaPlans"]
            .as_array()
            .expect("validated local ledger dcaPlans should be an array")
            .iter()
            .find(|plan| plan.get("id").and_then(Value::as_str) == Some(plan_id))
            .cloned()
            .ok_or_else(|| LedgerError::NotFound(format!("DCA plan does not exist: {plan_id}")))?;
        let funding_account_id = plan
            .get("fundingAccountId")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                LedgerError::InvalidInput(vec![
                    "DCA plan.fundingAccountId is required to record execution".to_string(),
                ])
            })?;
        let funding_account = active_account(document, funding_account_id).ok_or_else(|| {
            LedgerError::NotFound(format!(
                "DCA funding account does not exist or is archived: {funding_account_id}"
            ))
        })?;
        if !funding_account
            .get("supportedCurrencies")
            .and_then(Value::as_array)
            .is_some_and(|items| {
                items
                    .iter()
                    .any(|item| item.as_str() == Some(total_cost_currency.as_str()))
            })
        {
            return Err(LedgerError::InvalidInput(vec![format!(
                "DCA funding account does not support totalCost currency: {total_cost_currency}"
            )]));
        }
        let holding_account = active_account(document, &holding_account_id).ok_or_else(|| {
            LedgerError::NotFound(format!(
                "DCA holding account does not exist or is archived: {holding_account_id}"
            ))
        })?;
        if !matches!(
            holding_account.get("balanceMode").and_then(Value::as_str),
            Some("holdings" | "mixed")
        ) {
            return Err(LedgerError::InvalidInput(vec![format!(
                "DCA holding account must use holdings or mixed balanceMode: {holding_account_id}"
            )]));
        }
        if !holding_account
            .get("supportedCurrencies")
            .and_then(Value::as_array)
            .is_some_and(|items| {
                items
                    .iter()
                    .any(|item| item.as_str() == Some(quote_currency.as_str()))
            })
        {
            return Err(LedgerError::InvalidInput(vec![format!(
                "DCA holding account does not support quoteCurrency: {quote_currency}"
            )]));
        }
        let target_instrument_id = plan
            .get("targetInstrumentId")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                LedgerError::InvalidInput(vec![
                    "DCA plan.targetInstrumentId is required".to_string(),
                ])
            })?;
        if let Some(instrument) = document["instruments"]
            .as_array()
            .expect("validated local ledger instruments should be an array")
            .iter()
            .find(|instrument| {
                instrument.get("id").and_then(Value::as_str) == Some(target_instrument_id)
            })
            && instrument.get("quoteCurrency").and_then(Value::as_str)
                != Some(quote_currency.as_str())
        {
            return Err(LedgerError::Conflict(format!(
                "DCA target instrument quote currency does not match execution: {target_instrument_id}"
            )));
        }

        let display_name = plan
            .get("displayName")
            .and_then(Value::as_str)
            .unwrap_or(target_instrument_id);
        let movement = json!({
            "id": movement_id,
            "atomicGroupId": atomic_group_id,
            "type": "buy",
            "occurredAt": executed_at,
            "recordedAt": now,
            "status": "pending_review",
            "title": format!("记录{display_name}定投"),
            "description": "用户点击“记录已执行”后生成的候选记录；不下单、不转账。",
            "entries": [
                {
                    "id": format!("entry_{movement_id}_cash_out"),
                    "accountId": funding_account_id,
                    "amount": total_cost_amount,
                    "currency": total_cost_currency,
                    "direction": "out",
                    "role": "source"
                },
                {
                    "id": format!("entry_{movement_id}_holding_in"),
                    "accountId": holding_account_id,
                    "instrumentId": target_instrument_id,
                    "amount": quantity,
                    "currency": quote_currency,
                    "direction": "in",
                    "role": "destination"
                }
            ],
            "categoryId": "cat_investment_dca",
            "tags": ["dca"],
            "source": {
                "kind": "system",
                "sourceId": reminder_id,
                "createdBy": "system"
            },
            "createdAt": now,
            "updatedAt": now
        });

        document["movements"]
            .as_array_mut()
            .expect("validated local ledger movements should be an array")
            .push(movement.clone());
        if let Some(entries) = movement.get("entries").and_then(Value::as_array) {
            let movement_entries = document["movementEntries"]
                .as_array_mut()
                .expect("validated local ledger movementEntries should be an array");
            for entry in entries {
                let mut indexed_entry = entry.clone();
                indexed_entry["movementId"] = json!(movement_id);
                indexed_entry["atomicGroupId"] = json!(atomic_group_id);
                movement_entries.push(indexed_entry);
            }
        }

        let mut group = atomic_group_from_movement(&movement, "pending");
        group["warnings"] = json!([
            {
                "code": "record_only_no_order",
                "message": "该候选只记录用户已执行的定投，不连接券商、不下单、不转账。",
                "severity": "info"
            }
        ]);
        Ok(group)
    })
}

pub fn list_subscriptions(path: &Path) -> io::Result<Value> {
    let document = read_document(path)?;
    let mut items = document["subscriptions"]
        .as_array()
        .expect("validated local ledger subscriptions should be an array")
        .clone();
    items.sort_by(|left, right| {
        left.get("nextChargeDate")
            .and_then(Value::as_str)
            .unwrap_or("9999-12-31")
            .cmp(
                right
                    .get("nextChargeDate")
                    .and_then(Value::as_str)
                    .unwrap_or("9999-12-31"),
            )
            .then_with(|| {
                left.get("displayName")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .cmp(
                        right
                            .get("displayName")
                            .and_then(Value::as_str)
                            .unwrap_or_default(),
                    )
            })
    });
    Ok(json!(items))
}

pub fn get_subscription(path: &Path, subscription_id: &str) -> io::Result<Option<Value>> {
    let document = read_document(path)?;
    Ok(document["subscriptions"]
        .as_array()
        .expect("validated local ledger subscriptions should be an array")
        .iter()
        .find(|item| item.get("id").and_then(Value::as_str) == Some(subscription_id))
        .cloned())
}

pub fn list_upcoming_subscriptions(path: &Path, through_date: &str) -> io::Result<Value> {
    let document = read_document(path)?;
    let items = document["subscriptions"]
        .as_array()
        .expect("validated local ledger subscriptions should be an array")
        .iter()
        .filter(|item| {
            matches!(
                item.get("status").and_then(Value::as_str),
                Some("trial" | "active")
            ) && item
                .get("nextChargeDate")
                .and_then(Value::as_str)
                .is_some_and(|date| date <= through_date)
        })
        .cloned()
        .collect::<Vec<_>>();
    Ok(json!(items))
}

pub fn create_subscription(
    path: &Path,
    input: Value,
    subscription_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 201, |document| {
        let subscription = subscription_from_create_input(document, &input, subscription_id, now)?;
        document["subscriptions"]
            .as_array_mut()
            .expect("validated local ledger subscriptions should be an array")
            .push(subscription.clone());
        append_sync_change(
            document,
            "subscription",
            subscription_id,
            "create",
            &subscription,
            now,
        );
        Ok(subscription)
    })
}

pub fn update_subscription(
    path: &Path,
    subscription_id: &str,
    patch: Value,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let subscription_index = document["subscriptions"]
            .as_array()
            .expect("validated local ledger subscriptions should be an array")
            .iter()
            .position(|subscription| {
                subscription.get("id").and_then(Value::as_str) == Some(subscription_id)
            })
            .ok_or_else(|| {
                LedgerError::NotFound(format!("subscription does not exist: {subscription_id}"))
            })?;
        let mut updated = document["subscriptions"][subscription_index].clone();
        apply_subscription_patch(&mut updated, &patch, now)?;
        validate_subscription_payment(document, &updated)?;
        document["subscriptions"][subscription_index] = updated.clone();
        append_sync_change(
            document,
            "subscription",
            subscription_id,
            "update",
            &updated,
            now,
        );
        Ok(updated)
    })
}

pub fn cancel_subscription(
    path: &Path,
    subscription_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let cancelled = {
            let subscription =
                find_subscription_mut(document, subscription_id).ok_or_else(|| {
                    LedgerError::NotFound(format!("subscription does not exist: {subscription_id}"))
                })?;
            if subscription
                .get("pendingChargeMovementId")
                .and_then(Value::as_str)
                .is_some()
            {
                return Err(LedgerError::Conflict(
                    "reject the pending subscription charge proposal before cancellation"
                        .to_string(),
                ));
            }
            match subscription.get("status").and_then(Value::as_str) {
                Some("cancelled") => {}
                Some("expired") => {
                    return Err(LedgerError::Conflict(
                        "expired subscription cannot be cancelled".to_string(),
                    ));
                }
                Some(_) => {
                    subscription["status"] = json!("cancelled");
                    subscription["cancelledAt"] = json!(now);
                    subscription["autoRenew"] = json!(false);
                    subscription["nextChargeDate"] = Value::Null;
                    subscription["updatedAt"] = json!(now);
                }
                None => {
                    return Err(LedgerError::InvalidInput(vec![
                        "subscription.status is missing".to_string(),
                    ]));
                }
            }
            subscription.clone()
        };
        append_sync_change(
            document,
            "subscription",
            subscription_id,
            "update",
            &cancelled,
            now,
        );
        Ok(cancelled)
    })
}

pub fn create_subscription_charge_proposal(
    path: &Path,
    subscription_id: &str,
    movement_id: &str,
    atomic_group_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 201, |document| {
        create_subscription_charge_proposal_in_document(
            document,
            subscription_id,
            movement_id,
            atomic_group_id,
            now,
        )
    })
}

pub fn create_due_subscription_charge_proposals<F>(
    path: &Path,
    input: Value,
    now: &str,
    idempotency: &IdempotencyRequest,
    mut next_ids: F,
) -> Result<IdempotentResponse, LedgerError>
where
    F: FnMut() -> (String, String),
{
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let (through_date, limit) = parse_subscription_due_scan_input(&input)?;
        let mut candidates = document["subscriptions"]
            .as_array()
            .expect("validated local ledger subscriptions should be an array")
            .iter()
            .filter(|subscription| {
                matches!(
                    subscription.get("status").and_then(Value::as_str),
                    Some("trial" | "active")
                ) && subscription
                    .get("nextChargeDate")
                    .and_then(Value::as_str)
                    .is_some_and(|date| date <= through_date.as_str())
            })
            .map(|subscription| {
                (
                    subscription
                        .get("nextChargeDate")
                        .and_then(Value::as_str)
                        .expect("eligible subscription nextChargeDate should exist")
                        .to_string(),
                    subscription
                        .get("id")
                        .and_then(Value::as_str)
                        .expect("validated subscription id should exist")
                        .to_string(),
                    subscription.clone(),
                )
            })
            .collect::<Vec<_>>();
        candidates.sort_unstable_by(|left, right| {
            left.0.cmp(&right.0).then_with(|| left.1.cmp(&right.1))
        });

        let mut created = Vec::new();
        let mut skipped = Vec::new();
        let mut already_pending_count = 0_usize;
        let mut blocked_count = 0_usize;
        let mut remaining_eligible_count = 0_usize;

        for (charge_date, subscription_id, subscription) in candidates {
            if subscription
                .get("pendingChargeMovementId")
                .and_then(Value::as_str)
                .is_some()
            {
                already_pending_count += 1;
                skipped.push(subscription_due_scan_skip(
                    &subscription_id,
                    &charge_date,
                    "already_pending",
                ));
                continue;
            }

            let payment_account_id = subscription
                .get("paymentAccountId")
                .and_then(Value::as_str)
                .expect("validated subscription paymentAccountId should exist");
            let currency = subscription
                .get("amount")
                .and_then(|money| money.get("currency"))
                .and_then(Value::as_str)
                .expect("validated subscription currency should exist");
            if let Some(issue) = subscription_payment_issue(document, payment_account_id, currency)
            {
                blocked_count += 1;
                let reason = match issue {
                    SubscriptionPaymentIssue::AccountUnavailable => "payment_account_unavailable",
                    SubscriptionPaymentIssue::CurrencyUnsupported => "payment_currency_unsupported",
                };
                skipped.push(subscription_due_scan_skip(
                    &subscription_id,
                    &charge_date,
                    reason,
                ));
                continue;
            }

            if created.len() >= limit {
                remaining_eligible_count += 1;
                continue;
            }

            let (movement_id, atomic_group_id) = next_ids();
            created.push(create_subscription_charge_proposal_in_document(
                document,
                &subscription_id,
                &movement_id,
                &atomic_group_id,
                now,
            )?);
        }

        Ok(json!({
            "throughDate": through_date,
            "createdCount": created.len(),
            "alreadyPendingCount": already_pending_count,
            "blockedCount": blocked_count,
            "remainingEligibleCount": remaining_eligible_count,
            "hasMore": remaining_eligible_count > 0,
            "created": created,
            "skipped": skipped
        }))
    })
}

fn parse_subscription_due_scan_input(input: &Value) -> Result<(String, usize), LedgerError> {
    let Some(object) = input.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "subscription due scan input must be a JSON object".to_string(),
        ]));
    };
    let mut errors = Vec::new();
    let mut unknown = object
        .keys()
        .filter(|key| !matches!(key.as_str(), "throughDate" | "limit"))
        .cloned()
        .collect::<Vec<_>>();
    unknown.sort_unstable();
    if !unknown.is_empty() {
        errors.push(format!(
            "unsupported subscription due scan fields: {}",
            unknown.join(", ")
        ));
    }
    let through_date = match object.get("throughDate").and_then(Value::as_str) {
        Some(value) if Date::parse(value, &Iso8601::DATE).is_ok() => Some(value.to_string()),
        _ => {
            errors.push("throughDate must be an ISO date".to_string());
            None
        }
    };
    let limit = match object.get("limit") {
        None => Some(100_usize),
        Some(value) => match value.as_u64().and_then(|value| usize::try_from(value).ok()) {
            Some(value @ 1..=200) => Some(value),
            _ => {
                errors.push("limit must be an integer from 1 to 200".to_string());
                None
            }
        },
    };
    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(errors));
    }
    Ok((
        through_date.expect("validated throughDate should exist"),
        limit.expect("validated limit should exist"),
    ))
}

fn subscription_due_scan_skip(
    subscription_id: &str,
    scheduled_charge_date: &str,
    reason: &str,
) -> Value {
    json!({
        "subscriptionId": subscription_id,
        "scheduledChargeDate": scheduled_charge_date,
        "reason": reason
    })
}

fn create_subscription_charge_proposal_in_document(
    document: &mut Value,
    subscription_id: &str,
    movement_id: &str,
    atomic_group_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    let subscription = document["subscriptions"]
        .as_array()
        .expect("validated local ledger subscriptions should be an array")
        .iter()
        .find(|item| item.get("id").and_then(Value::as_str) == Some(subscription_id))
        .cloned()
        .ok_or_else(|| {
            LedgerError::NotFound(format!("subscription does not exist: {subscription_id}"))
        })?;
    if !matches!(
        subscription.get("status").and_then(Value::as_str),
        Some("trial" | "active")
    ) {
        return Err(LedgerError::Conflict(
            "subscription must be trial or active to generate a charge".to_string(),
        ));
    }
    if subscription
        .get("pendingChargeMovementId")
        .and_then(Value::as_str)
        .is_some()
    {
        return Err(LedgerError::Conflict(
            "subscription already has a pending charge proposal".to_string(),
        ));
    }
    let charge_date = subscription
        .get("nextChargeDate")
        .and_then(Value::as_str)
        .ok_or_else(|| LedgerError::Conflict("subscription has no next charge date".to_string()))?;
    validate_subscription_payment(document, &subscription)?;
    let payment_account_id = subscription
        .get("paymentAccountId")
        .and_then(Value::as_str)
        .expect("validated subscription paymentAccountId should exist");
    let amount = subscription
        .get("amount")
        .and_then(|money| money.get("amount"))
        .and_then(Value::as_str)
        .expect("validated subscription amount should exist");
    let currency = subscription
        .get("amount")
        .and_then(|money| money.get("currency"))
        .and_then(Value::as_str)
        .expect("validated subscription currency should exist");
    let display_name = subscription
        .get("displayName")
        .and_then(Value::as_str)
        .expect("validated subscription displayName should exist");
    let provider = subscription
        .get("provider")
        .and_then(Value::as_str)
        .expect("validated subscription provider should exist");
    let mut movement = movement_from_create_input(
        document,
        &json!({
            "type": "expense",
            "occurredAt": format!("{charge_date}T00:00:00Z"),
            "title": format!("{display_name} 订阅扣款"),
            "description": format!("{provider} 订阅的待确认计划扣款；确认前不影响正式账本。"),
            "entries": [{
                "accountId": payment_account_id,
                "amount": amount,
                "currency": currency,
                "direction": "out",
                "role": "source"
            }],
            "tags": ["subscription"]
        }),
        movement_id,
        atomic_group_id,
        now,
    )?;
    movement["status"] = json!("pending_review");
    movement["subscriptionId"] = json!(subscription_id);
    movement["scheduledChargeDate"] = json!(charge_date);
    movement["source"] = json!({
        "kind": "system",
        "sourceId": subscription_id,
        "createdBy": "system"
    });

    document["movements"]
        .as_array_mut()
        .expect("validated local ledger movements should be an array")
        .push(movement.clone());
    if let Some(entries) = movement.get("entries").and_then(Value::as_array) {
        let movement_entries = document["movementEntries"]
            .as_array_mut()
            .expect("validated local ledger movementEntries should be an array");
        for entry in entries {
            let mut indexed_entry = entry.clone();
            indexed_entry["movementId"] = json!(movement_id);
            indexed_entry["atomicGroupId"] = json!(atomic_group_id);
            movement_entries.push(indexed_entry);
        }
    }
    let subscription_mut =
        find_subscription_mut(document, subscription_id).expect("subscription should still exist");
    subscription_mut["pendingChargeMovementId"] = json!(movement_id);
    subscription_mut["pendingChargeDate"] = json!(charge_date);
    subscription_mut["updatedAt"] = json!(now);

    let mut group = atomic_group_from_movement(&movement, "pending");
    group["subscriptionId"] = json!(subscription_id);
    group["scheduledChargeDate"] = json!(charge_date);
    group["warnings"] = json!([{
        "code": "subscription_charge_requires_confirmation",
        "message": "该订阅扣款只是候选；用户确认后才写入正式账本。",
        "severity": "info"
    }]);
    Ok(group)
}

pub fn portfolio_overview(path: &Path, now: &str) -> io::Result<Value> {
    let document = read_document(path)?;
    let summary = summarize_accounts(&document, now)?;
    let ai_pending_count = pending_ai_proposal_count(&document);
    let recent_movements = recent_movements_from_document(&document);
    let in_transit_count = recent_movements
        .iter()
        .filter(|movement| movement.get("status").and_then(Value::as_str) == Some("in_transit"))
        .count();
    let dca_due_count = document["dcaReminders"]
        .as_array()
        .expect("validated local ledger dcaReminders should be an array")
        .iter()
        .filter(|reminder| {
            matches!(
                reminder.get("status").and_then(Value::as_str),
                Some("due" | "overdue")
            ) && reminder
                .get("planId")
                .and_then(Value::as_str)
                .is_some_and(|plan_id| is_dca_plan_active(&document, plan_id))
        })
        .count();

    Ok(json!({
        "latestSnapshot": summary.latest_snapshot,
        "previousSnapshot": Value::Null,
        "pendingSummary": {
            "aiPendingCount": ai_pending_count,
            "accountAnomalyCount": summary.account_anomaly_count,
            "dcaDueCount": dca_due_count,
            "inTransitCount": in_transit_count,
            "quoteProblemCount": summary.unpriceable_count,
            "syncProblemCount": 0
        },
        "quoteStatusSummary": {
            "freshCount": summary.fresh_count,
            "staleCount": summary.stale_count,
            "offlineCachedCount": summary.offline_cached_count,
            "unpriceableCount": summary.unpriceable_count,
            "errorCount": summary.error_count
        },
        "primaryHoldings": summary.primary_holdings,
        "recentMovements": recent_movements
    }))
}

pub fn asset_allocation(path: &Path, now: &str) -> io::Result<Value> {
    let document = read_document(path)?;
    let summary = summarize_accounts(&document, now)?;
    Ok(json!({
        "slices": summary.allocation_slices,
        "totalAssets": money(summary.gross_assets, &summary.base_currency),
        "totalLiabilities": money(summary.total_liabilities, &summary.base_currency),
        "netWorth": money(summary.net_worth(), &summary.base_currency)
    }))
}

pub fn latest_snapshot(path: &Path, now: &str) -> io::Result<Value> {
    let document = read_document(path)?;
    if let Some(snapshot) = latest_persisted_snapshot(&document) {
        return Ok(snapshot);
    }
    Ok(summarize_accounts(&document, now)?.latest_snapshot)
}

pub fn list_snapshots(path: &Path) -> io::Result<Value> {
    let document = read_document(path)?;
    Ok(json!(
        document["snapshots"]
            .as_array()
            .expect("validated local ledger snapshots should be an array")
            .clone()
    ))
}

pub fn create_manual_snapshot(
    path: &Path,
    input: Value,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let Some(object) = input.as_object() else {
            return Err(LedgerError::InvalidInput(vec![
                "manual snapshot input must be a JSON object".to_string(),
            ]));
        };
        let mut errors = Vec::new();
        let reason = required_enum(
            object,
            "reason",
            &["baseline", "manual_refresh"],
            &mut errors,
        );
        if !errors.is_empty() {
            return Err(LedgerError::InvalidInput(errors));
        }

        let mut snapshot = summarize_accounts(document, now)?.latest_snapshot;
        if snapshot.is_null() {
            return Err(LedgerError::Conflict(
                "cannot create a manual snapshot before any included account exists".to_string(),
            ));
        }
        snapshot["reason"] = json!(reason.expect("validated snapshot reason"));
        snapshot["createdAt"] = json!(now);

        document["snapshots"]
            .as_array_mut()
            .expect("validated local ledger snapshots should be an array")
            .push(snapshot.clone());
        Ok(snapshot)
    })
}

pub fn list_instruments(path: &Path) -> io::Result<Value> {
    let document = read_document(path)?;
    Ok(json!(
        document["instruments"]
            .as_array()
            .expect("validated local ledger instruments should be an array")
            .clone()
    ))
}

pub fn get_instrument(path: &Path, instrument_id: &str) -> io::Result<Option<Value>> {
    let document = read_document(path)?;
    Ok(document["instruments"]
        .as_array()
        .expect("validated local ledger instruments should be an array")
        .iter()
        .find(|instrument| instrument.get("id").and_then(Value::as_str) == Some(instrument_id))
        .cloned())
}

pub fn create_instrument(
    path: &Path,
    input: Value,
    fallback_instrument_id: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 201, |document| {
        let instrument = instrument_from_input(&input, fallback_instrument_id)?;
        let instrument_id = instrument
            .get("id")
            .and_then(Value::as_str)
            .expect("validated instrument id should be string");
        if document["instruments"]
            .as_array()
            .expect("validated local ledger instruments should be an array")
            .iter()
            .any(|existing| existing.get("id").and_then(Value::as_str) == Some(instrument_id))
        {
            return Err(LedgerError::Conflict(format!(
                "instrument already exists: {instrument_id}"
            )));
        }

        document["instruments"]
            .as_array_mut()
            .expect("validated local ledger instruments should be an array")
            .push(instrument.clone());
        Ok(instrument)
    })
}

pub fn update_instrument(
    path: &Path,
    instrument_id: &str,
    patch: Value,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let instrument = document["instruments"]
            .as_array_mut()
            .expect("validated local ledger instruments should be an array")
            .iter_mut()
            .find(|instrument| instrument.get("id").and_then(Value::as_str) == Some(instrument_id))
            .ok_or_else(|| {
                LedgerError::NotFound(format!("instrument does not exist: {instrument_id}"))
            })?;
        apply_instrument_patch(instrument, &patch)?;
        let projected = instrument.clone();
        Ok(projected)
    })
}

pub fn list_categories(path: &Path) -> io::Result<Value> {
    let document = read_document(path)?;
    Ok(json!(
        document["categories"]
            .as_array()
            .expect("validated local ledger categories should be an array")
            .clone()
    ))
}

pub fn create_category(
    path: &Path,
    input: Value,
    category_id: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 201, |document| {
        let category = category_from_input(&input, category_id)?;
        document["categories"]
            .as_array_mut()
            .expect("validated local ledger categories should be an array")
            .push(category.clone());
        Ok(category)
    })
}

pub fn update_category(
    path: &Path,
    category_id: &str,
    patch: Value,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let category = document["categories"]
            .as_array_mut()
            .expect("validated local ledger categories should be an array")
            .iter_mut()
            .find(|category| category.get("id").and_then(Value::as_str) == Some(category_id))
            .ok_or_else(|| {
                LedgerError::NotFound(format!("category does not exist: {category_id}"))
            })?;
        apply_category_patch(category, &patch)?;
        let projected = category.clone();
        Ok(projected)
    })
}

pub fn list_counterparties(path: &Path) -> io::Result<Value> {
    let document = read_document(path)?;
    Ok(json!(
        document["counterparties"]
            .as_array()
            .expect("validated local ledger counterparties should be an array")
            .clone()
    ))
}

pub fn create_counterparty(
    path: &Path,
    input: Value,
    counterparty_id: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 201, |document| {
        let counterparty = counterparty_from_input(&input, counterparty_id)?;
        document["counterparties"]
            .as_array_mut()
            .expect("validated local ledger counterparties should be an array")
            .push(counterparty.clone());
        Ok(counterparty)
    })
}

pub fn update_counterparty(
    path: &Path,
    counterparty_id: &str,
    patch: Value,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let counterparty = document["counterparties"]
            .as_array_mut()
            .expect("validated local ledger counterparties should be an array")
            .iter_mut()
            .find(|counterparty| {
                counterparty.get("id").and_then(Value::as_str) == Some(counterparty_id)
            })
            .ok_or_else(|| {
                LedgerError::NotFound(format!("counterparty does not exist: {counterparty_id}"))
            })?;
        apply_counterparty_patch(counterparty, &patch)?;
        let projected = counterparty.clone();
        Ok(projected)
    })
}

pub fn create_counterparty_merge_proposal(
    path: &Path,
    input: Value,
    proposal_id: &str,
    atomic_group_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let group = counterparty_merge_group_from_input(document, &input, atomic_group_id)?;
        let proposal = json!({
            "id": proposal_id,
            "status": "pending",
            "source": {
                "kind": "manual_import",
                "evidenceRefs": []
            },
            "atomicGroups": [group.clone()],
            "summary": group
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or("对手方合并候选"),
            "warnings": [],
            "createdAt": now
        });

        document["aiProposals"]
            .as_array_mut()
            .expect("validated local ledger aiProposals should be an array")
            .push(proposal);
        Ok(group)
    })
}

pub fn create_ai_import_proposal(
    path: &Path,
    input: Value,
    source_kind: &str,
    context: &AiImportContext,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        let groups = ai_import_groups_from_input(
            document,
            &input,
            source_kind,
            &context.proposal_id,
            &context.atomic_group_id,
            &context.movement_id,
            &context.now,
        )?;
        let proposal = ai_import_proposal_from_groups(
            &input,
            source_kind,
            &context.proposal_id,
            groups,
            &context.now,
        );

        document["aiProposals"]
            .as_array_mut()
            .expect("validated local ledger aiProposals should be an array")
            .push(proposal.clone());
        Ok(proposal)
    })
}

pub fn edit_ai_atomic_group(
    path: &Path,
    atomic_group_id: &str,
    patch: Value,
    movement_id: &str,
    now: &str,
    idempotency: &IdempotencyRequest,
) -> Result<IdempotentResponse, LedgerError> {
    idempotent_ledger_write(path, idempotency, 200, |document| {
        if standalone_pending_movement_for_group(document, atomic_group_id).is_some() {
            return Err(LedgerError::Conflict(
                "standalone ledger candidates cannot be edited; reject and regenerate the candidate"
                    .to_string(),
            ));
        }
        let source_id =
            find_ai_proposal_id_for_group(document, atomic_group_id).ok_or_else(|| {
                LedgerError::NotFound(format!("AI atomic group does not exist: {atomic_group_id}"))
            })?;
        let group = find_ai_atomic_group(document, atomic_group_id).ok_or_else(|| {
            LedgerError::NotFound(format!("AI atomic group does not exist: {atomic_group_id}"))
        })?;

        match group.get("status").and_then(Value::as_str) {
            Some("pending" | "edited") => {}
            Some(status) => {
                return Err(LedgerError::Conflict(format!(
                    "AI atomic group cannot be edited from status: {status}"
                )));
            }
            None => {
                return Err(LedgerError::InvalidInput(vec![
                    "atomic group status must be present".to_string(),
                ]));
            }
        }

        let edited_group = edited_ai_atomic_group_from_patch(
            document,
            &group,
            &patch,
            &source_id,
            movement_id,
            now,
        )?;
        replace_ai_atomic_group(document, atomic_group_id, edited_group.clone())?;
        Ok(edited_group)
    })
}

pub fn list_pending_ai_proposals(path: &Path) -> io::Result<Value> {
    let document = read_document(path)?;
    Ok(json!(pending_ai_proposals_for_document(&document)))
}

fn pending_ai_proposal_count(document: &Value) -> usize {
    let stored = document["aiProposals"]
        .as_array()
        .expect("validated local ledger aiProposals should be an array")
        .iter()
        .filter(|proposal| is_pending_ai_proposal(proposal))
        .count();
    stored + standalone_pending_movement_groups(document).len()
}

fn is_pending_ai_proposal(proposal: &Value) -> bool {
    matches!(
        proposal.get("status").and_then(Value::as_str),
        Some("pending" | "edited" | "partially_reviewed")
    ) && proposal_has_pending_group(proposal)
}

pub fn get_ai_proposal(path: &Path, proposal_id: &str) -> io::Result<Option<Value>> {
    let document = read_document(path)?;
    let stored = document["aiProposals"]
        .as_array()
        .expect("validated local ledger aiProposals should be an array")
        .iter()
        .find(|proposal| proposal.get("id").and_then(Value::as_str) == Some(proposal_id))
        .cloned();
    if stored.is_some() {
        return Ok(stored);
    }
    Ok(standalone_pending_movement_groups(&document)
        .into_iter()
        .map(|movements| standalone_pending_movement_group_proposal(&movements))
        .find(|proposal| proposal.get("id").and_then(Value::as_str) == Some(proposal_id)))
}

fn pending_ai_proposals_for_document(document: &Value) -> Vec<Value> {
    let mut proposals = document["aiProposals"]
        .as_array()
        .expect("validated local ledger aiProposals should be an array")
        .iter()
        .filter(|proposal| is_pending_ai_proposal(proposal))
        .cloned()
        .collect::<Vec<_>>();
    proposals.extend(
        standalone_pending_movement_groups(document)
            .into_iter()
            .map(|movements| standalone_pending_movement_group_proposal(&movements)),
    );
    proposals.sort_by(|left, right| {
        let left_key = (
            left.get("createdAt")
                .and_then(Value::as_str)
                .unwrap_or_default(),
            left.get("id").and_then(Value::as_str).unwrap_or_default(),
        );
        let right_key = (
            right
                .get("createdAt")
                .and_then(Value::as_str)
                .unwrap_or_default(),
            right.get("id").and_then(Value::as_str).unwrap_or_default(),
        );
        left_key.cmp(&right_key)
    });
    proposals
}

fn standalone_pending_movements(document: &Value) -> impl Iterator<Item = &Value> {
    document["movements"]
        .as_array()
        .expect("validated local ledger movements should be an array")
        .iter()
        .filter(|movement| movement.get("status").and_then(Value::as_str) == Some("pending_review"))
}

fn standalone_pending_movement_groups(document: &Value) -> Vec<Vec<&Value>> {
    let mut groups = BTreeMap::<String, Vec<&Value>>::new();
    for movement in standalone_pending_movements(document) {
        let Some(atomic_group_id) = movement.get("atomicGroupId").and_then(Value::as_str) else {
            continue;
        };
        groups
            .entry(atomic_group_id.to_string())
            .or_default()
            .push(movement);
    }
    for movements in groups.values_mut() {
        movements.sort_unstable_by_key(|movement| {
            movement
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or_default()
        });
    }
    groups.into_values().collect()
}

fn standalone_pending_movement_for_group<'a>(
    document: &'a Value,
    atomic_group_id: &str,
) -> Option<&'a Value> {
    standalone_pending_movements(document).find(|movement| {
        movement.get("atomicGroupId").and_then(Value::as_str) == Some(atomic_group_id)
    })
}

fn standalone_pending_movement_group_proposal(movements: &[&Value]) -> Value {
    let movement = movements
        .first()
        .copied()
        .expect("standalone pending movement group should not be empty");
    let movement_id = movement
        .get("id")
        .and_then(Value::as_str)
        .expect("validated pending movement id should be a string");
    let title = movement
        .get("title")
        .and_then(Value::as_str)
        .expect("validated pending movement title should be a string");
    let created_at = movements
        .iter()
        .filter_map(|movement| {
            movement
                .get("createdAt")
                .or_else(|| movement.get("recordedAt"))
                .and_then(Value::as_str)
        })
        .min()
        .expect("validated pending movement timestamp should be a string");
    let is_subscription = movements.iter().any(|movement| {
        movement
            .get("subscriptionId")
            .and_then(Value::as_str)
            .is_some()
    });
    let is_dca = movements.iter().any(|movement| {
        movement
            .get("tags")
            .and_then(Value::as_array)
            .is_some_and(|tags| tags.iter().any(|tag| tag.as_str() == Some("dca")))
    });
    let (source_label, warnings) = if is_subscription {
        (
            "订阅计划",
            json!([{
                "code": "subscription_charge_requires_confirmation",
                "message": "该订阅扣费只是候选；用户确认后才写入正式账本。",
                "severity": "info"
            }]),
        )
    } else if is_dca {
        (
            "定投提醒",
            json!([{
                "code": "record_only_no_order",
                "message": "该候选只记录用户已执行的定投，不连接券商、不下单、不转账。",
                "severity": "info"
            }]),
        )
    } else {
        (
            "手动记录",
            json!([{
                "code": "manual_candidate_requires_confirmation",
                "message": "该记录仍是候选；用户确认后才写入正式账本。",
                "severity": "info"
            }]),
        )
    };
    let mut group = atomic_group_from_movement(movement, "pending");
    group["proposedMovements"] = json!(
        movements
            .iter()
            .map(|movement| project_movement_for_api(movement))
            .collect::<Vec<_>>()
    );
    group["warnings"] = warnings.clone();
    if let Some(subscription_id) = movement.get("subscriptionId").and_then(Value::as_str) {
        group["subscriptionId"] = json!(subscription_id);
    }
    if let Some(charge_date) = movement.get("scheduledChargeDate").and_then(Value::as_str) {
        group["scheduledChargeDate"] = json!(charge_date);
    }
    let evidence_refs = movements
        .iter()
        .filter_map(|movement| movement.get("id").and_then(Value::as_str))
        .map(|movement_id| {
            json!({
                "id": format!("evidence_movement_{movement_id}"),
                "type": "text",
                "label": source_label
            })
        })
        .collect::<Vec<_>>();
    json!({
        "id": format!("proposal_movement_{movement_id}"),
        "status": "pending",
        "source": {
            "kind": "manual_import",
            "evidenceRefs": evidence_refs
        },
        "summary": title,
        "atomicGroups": [group],
        "warnings": warnings,
        "createdAt": created_at
    })
}

pub fn ensure_real_and_fixture_paths_separate(
    real_path: &Path,
    fixture_path: &Path,
) -> Result<(), String> {
    let real = normalize_path(real_path);
    let fixture = normalize_path(fixture_path);

    if real == fixture {
        return Err("real ledger path and fixture path must not be the same".to_string());
    }

    if real
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.to_ascii_lowercase().contains("fixture"))
    {
        return Err("real ledger path must not look like a fixture path".to_string());
    }

    Ok(())
}

pub fn validate_document(document: &Value) -> Result<(), Vec<String>> {
    validate_document_for_version(document, LEDGER_VERSION)
}

fn validate_document_for_version(
    document: &Value,
    expected_version: i64,
) -> Result<(), Vec<String>> {
    let mut errors = Vec::new();

    let Some(object) = document.as_object() else {
        return Err(vec!["ledger document must be a JSON object".to_string()]);
    };

    if object.get("ledgerVersion").and_then(Value::as_i64) != Some(expected_version) {
        errors.push(format!("ledgerVersion must be {expected_version}"));
    }

    match object.get("baseCurrency").and_then(Value::as_str) {
        Some(value) if !value.trim().is_empty() => {}
        _ => errors.push("baseCurrency must be a non-empty currency code".to_string()),
    }

    for key in [
        "accounts",
        "instruments",
        "holdings",
        "movements",
        "movementEntries",
        "dcaPlans",
        "dcaReminders",
        "subscriptions",
        "categories",
        "counterparties",
        "quotes",
        "fxRates",
        "snapshots",
        "aiProposals",
        "evidenceRefs",
        "anomalies",
        "syncChanges",
        "migrations",
    ] {
        require_array(object, key, &mut errors);
    }

    if let Err(error) = validate_history(document, MIGRATION_REGISTRY) {
        errors.push(error);
    }

    validate_sync_state_and_changes(
        object.get("syncState"),
        object.get("syncChanges"),
        &mut errors,
    );

    validate_idempotency_state(object.get("idempotencyState"), &mut errors);

    if contains_fixture_marker(document) {
        errors.push("real local ledger must not contain debug fixture markers".to_string());
    }

    validate_accounts(object.get("accounts"), &mut errors);
    validate_core_ledger_entities(document, &mut errors);
    validate_dca_entities(document, &mut errors);
    validate_subscriptions(
        object.get("subscriptions"),
        object.get("accounts"),
        object.get("movements"),
        &mut errors,
    );

    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
    }
}

fn validate_dca_entities(document: &Value, errors: &mut Vec<String>) {
    let Some(plans) = document.get("dcaPlans").and_then(Value::as_array) else {
        return;
    };
    let Some(reminders) = document.get("dcaReminders").and_then(Value::as_array) else {
        return;
    };

    let account_ids = document["accounts"]
        .as_array()
        .map(|accounts| {
            accounts
                .iter()
                .filter_map(|account| account.get("id").and_then(Value::as_str))
                .collect::<BTreeSet<_>>()
        })
        .unwrap_or_default();
    let mut plan_ids = BTreeSet::new();
    let mut plan_index = BTreeMap::new();

    for (index, plan) in plans.iter().enumerate() {
        let Some(plan) = plan.as_object() else {
            errors.push(format!("dcaPlans[{index}] must be an object"));
            continue;
        };
        let id = plan.get("id").and_then(Value::as_str);
        match id {
            Some(id) if !id.is_empty() => {
                if !plan_ids.insert(id) {
                    errors.push(format!("duplicate DCA plan id: {id}"));
                }
                plan_index.entry(id).or_insert(plan);
            }
            _ => errors.push(format!("dcaPlans[{index}].id must be a non-empty string")),
        }
        for key in ["displayName", "targetInstrumentId"] {
            if plan
                .get(key)
                .and_then(Value::as_str)
                .is_none_or(str::is_empty)
            {
                errors.push(format!(
                    "dcaPlans[{index}].{key} must be a non-empty string"
                ));
            }
        }
        if let Some(funding_account_id) = plan.get("fundingAccountId") {
            match funding_account_id.as_str() {
                Some(id) if account_ids.contains(id) => {}
                _ => errors.push(format!(
                    "dcaPlans[{index}].fundingAccountId must reference an existing account"
                )),
            }
        }
        validate_positive_money(
            plan.get("plannedAmount"),
            &format!("dcaPlans[{index}].plannedAmount"),
            errors,
        );
        if !matches!(
            plan.get("frequency").and_then(Value::as_str),
            Some("weekly" | "monthly" | "custom")
        ) {
            errors.push(format!("dcaPlans[{index}].frequency is invalid"));
        }
        if plan
            .get("nextDueDate")
            .and_then(Value::as_str)
            .is_none_or(|value| Date::parse(value, &Iso8601::DATE).is_err())
        {
            errors.push(format!("dcaPlans[{index}].nextDueDate must be an ISO date"));
        }
        if !matches!(
            plan.get("reminderStatus").and_then(Value::as_str),
            Some("active" | "snoozed" | "paused" | "completed")
        ) {
            errors.push(format!("dcaPlans[{index}].reminderStatus is invalid"));
        }
        validate_optional_timestamp(
            plan.get("lastActionAt"),
            &format!("dcaPlans[{index}].lastActionAt"),
            errors,
        );
        validate_optional_timestamp(
            plan.get("createdAt"),
            &format!("dcaPlans[{index}].createdAt"),
            errors,
        );
        validate_optional_timestamp(
            plan.get("updatedAt"),
            &format!("dcaPlans[{index}].updatedAt"),
            errors,
        );
        if plan.contains_key("note") && !plan.get("note").is_some_and(Value::is_string) {
            errors.push(format!("dcaPlans[{index}].note must be a string"));
        }
    }

    let mut reminder_ids = BTreeSet::new();
    let mut open_by_plan = BTreeMap::<&str, usize>::new();
    let mut reminder_index = BTreeMap::new();
    for (index, reminder) in reminders.iter().enumerate() {
        let Some(reminder) = reminder.as_object() else {
            errors.push(format!("dcaReminders[{index}] must be an object"));
            continue;
        };
        let id = reminder.get("id").and_then(Value::as_str);
        match id {
            Some(id) if !id.is_empty() => {
                if !reminder_ids.insert(id) {
                    errors.push(format!("duplicate DCA reminder id: {id}"));
                }
                reminder_index.entry(id).or_insert(reminder);
            }
            _ => errors.push(format!(
                "dcaReminders[{index}].id must be a non-empty string"
            )),
        }
        let plan_id = reminder.get("planId").and_then(Value::as_str);
        let plan = match plan_id {
            Some(plan_id) => match plan_index.get(plan_id) {
                Some(plan) => Some(*plan),
                None => {
                    errors.push(format!(
                        "dcaReminders[{index}].planId must reference an existing DCA plan"
                    ));
                    None
                }
            },
            None => {
                errors.push(format!(
                    "dcaReminders[{index}].planId must be a non-empty string"
                ));
                None
            }
        };
        if reminder
            .get("displayName")
            .and_then(Value::as_str)
            .is_none_or(str::is_empty)
        {
            errors.push(format!(
                "dcaReminders[{index}].displayName must be a non-empty string"
            ));
        }
        validate_positive_money(
            reminder.get("plannedAmount"),
            &format!("dcaReminders[{index}].plannedAmount"),
            errors,
        );
        if reminder
            .get("dueDate")
            .and_then(Value::as_str)
            .is_none_or(|value| Date::parse(value, &Iso8601::DATE).is_err())
        {
            errors.push(format!("dcaReminders[{index}].dueDate must be an ISO date"));
        }
        let status = reminder.get("status").and_then(Value::as_str);
        if !matches!(
            status,
            Some("due" | "overdue" | "snoozed" | "recorded" | "skipped")
        ) {
            errors.push(format!("dcaReminders[{index}].status is invalid"));
        }
        if status == Some("snoozed") {
            if reminder
                .get("snoozedUntil")
                .and_then(Value::as_str)
                .and_then(parse_rfc3339)
                .is_none()
            {
                errors.push(format!(
                    "dcaReminders[{index}].snoozedUntil must be an RFC3339 timestamp when snoozed"
                ));
            }
        } else if reminder.contains_key("snoozedUntil") {
            errors.push(format!(
                "dcaReminders[{index}].snoozedUntil is only valid for snoozed reminders"
            ));
        }
        validate_optional_timestamp(
            reminder.get("updatedAt"),
            &format!("dcaReminders[{index}].updatedAt"),
            errors,
        );

        if matches!(status, Some("due" | "overdue" | "snoozed"))
            && let Some(plan_id) = plan_id
        {
            let count = open_by_plan.entry(plan_id).or_default();
            *count += 1;
            if *count > 1 {
                errors.push(format!(
                    "DCA plan has more than one open reminder: {plan_id}"
                ));
            }
            if let Some(plan) = plan {
                for (reminder_key, plan_key) in [
                    ("displayName", "displayName"),
                    ("plannedAmount", "plannedAmount"),
                    ("dueDate", "nextDueDate"),
                ] {
                    if reminder.get(reminder_key) != plan.get(plan_key) {
                        errors.push(format!(
                            "dcaReminders[{index}].{reminder_key} must match its open DCA plan"
                        ));
                    }
                }
            }
        }
    }

    let mut pending_counts = BTreeMap::<&str, usize>::new();
    let mut confirmed_counts = BTreeMap::<&str, usize>::new();
    if let Some(movements) = document.get("movements").and_then(Value::as_array) {
        for (index, movement) in movements.iter().enumerate() {
            let is_dca = movement
                .get("tags")
                .and_then(Value::as_array)
                .is_some_and(|tags| tags.iter().any(|tag| tag.as_str() == Some("dca")))
                && movement
                    .get("source")
                    .and_then(|source| source.get("kind"))
                    .and_then(Value::as_str)
                    == Some("system");
            if !is_dca {
                continue;
            }
            let Some(reminder_id) = movement
                .get("source")
                .and_then(|source| source.get("sourceId"))
                .and_then(Value::as_str)
            else {
                errors.push(format!(
                    "movements[{index}] DCA source.sourceId must reference a reminder"
                ));
                continue;
            };
            if !reminder_index.contains_key(reminder_id) {
                errors.push(format!(
                    "movements[{index}] DCA source.sourceId must reference an existing reminder"
                ));
                continue;
            }
            match movement.get("status").and_then(Value::as_str) {
                Some("pending_review") => *pending_counts.entry(reminder_id).or_default() += 1,
                Some("confirmed") => *confirmed_counts.entry(reminder_id).or_default() += 1,
                _ => {}
            }
        }
    }
    for (reminder_id, count) in pending_counts {
        if count > 1 {
            errors.push(format!(
                "DCA reminder has more than one pending proposal: {reminder_id}"
            ));
        }
    }
    for (reminder_id, reminder) in reminder_index {
        let confirmed = confirmed_counts.get(reminder_id).copied().unwrap_or(0);
        if reminder.get("status").and_then(Value::as_str) == Some("recorded") && confirmed != 1 {
            errors.push(format!(
                "recorded DCA reminder must reference exactly one confirmed movement: {reminder_id}"
            ));
        }
    }
}

fn validate_positive_money(value: Option<&Value>, label: &str, errors: &mut Vec<String>) {
    let Some(value) = value else {
        errors.push(format!("{label} is required"));
        return;
    };
    let Some(object) = value.as_object() else {
        errors.push(format!("{label} must be an object"));
        return;
    };
    if object
        .get("amount")
        .and_then(Value::as_str)
        .is_none_or(|amount| !is_positive_decimal_string(amount))
    {
        errors.push(format!("{label}.amount must be a positive decimal string"));
    }
    if object
        .get("currency")
        .and_then(Value::as_str)
        .is_none_or(str::is_empty)
    {
        errors.push(format!("{label}.currency must be a non-empty string"));
    }
}

fn validate_optional_timestamp(value: Option<&Value>, label: &str, errors: &mut Vec<String>) {
    match value {
        None | Some(Value::Null) => {}
        Some(Value::String(value)) if parse_rfc3339(value).is_some() => {}
        _ => errors.push(format!("{label} must be an RFC3339 timestamp")),
    }
}

fn validate_accounts(accounts: Option<&Value>, errors: &mut Vec<String>) {
    let Some(accounts) = accounts.and_then(Value::as_array) else {
        return;
    };

    for (index, account) in accounts.iter().enumerate() {
        let Some(account) = account.as_object() else {
            errors.push(format!("accounts[{index}] must be an object"));
            continue;
        };

        for key in ["id", "displayName", "accountType", "defaultCurrency"] {
            if account
                .get(key)
                .and_then(Value::as_str)
                .is_none_or(str::is_empty)
            {
                errors.push(format!(
                    "accounts[{index}].{key} must be a non-empty string"
                ));
            }
        }

        for key in [
            "visibility",
            "status",
            "balanceMode",
            "createdAt",
            "updatedAt",
        ] {
            if account
                .get(key)
                .and_then(Value::as_str)
                .is_none_or(str::is_empty)
            {
                errors.push(format!(
                    "accounts[{index}].{key} must be a non-empty string"
                ));
            }
        }

        if !account
            .get("includeInNetWorth")
            .is_some_and(Value::is_boolean)
        {
            errors.push(format!(
                "accounts[{index}].includeInNetWorth must be a boolean"
            ));
        }

        validate_string_array(
            account.get("supportedCurrencies"),
            &format!("accounts[{index}].supportedCurrencies"),
            errors,
        );
        validate_string_array(
            account.get("tags"),
            &format!("accounts[{index}].tags"),
            errors,
        );

        if let (Some(default_currency), Some(supported_currencies)) = (
            account.get("defaultCurrency").and_then(Value::as_str),
            account.get("supportedCurrencies").and_then(string_array),
        ) && !supported_currencies
            .iter()
            .any(|currency| currency == default_currency)
        {
            errors.push(format!(
                "accounts[{index}].supportedCurrencies must include defaultCurrency"
            ));
        }

        let Some(cash_balances) = account.get("cashBalances").and_then(Value::as_array) else {
            errors.push(format!("accounts[{index}].cashBalances must be an array"));
            continue;
        };

        for (balance_index, balance) in cash_balances.iter().enumerate() {
            let Some(balance) = balance.as_object() else {
                errors.push(format!(
                    "accounts[{index}].cashBalances[{balance_index}] must be an object"
                ));
                continue;
            };

            match balance.get("amount").and_then(Value::as_str) {
                Some(amount) if is_decimal_string(amount) => {}
                _ => errors.push(format!(
                    "accounts[{index}].cashBalances[{balance_index}].amount must be a decimal string"
                )),
            }

            if balance
                .get("currency")
                .and_then(Value::as_str)
                .is_none_or(str::is_empty)
            {
                errors.push(format!(
                    "accounts[{index}].cashBalances[{balance_index}].currency must be non-empty"
                ));
            }

            if balance
                .get("asOf")
                .and_then(Value::as_str)
                .is_none_or(str::is_empty)
            {
                errors.push(format!(
                    "accounts[{index}].cashBalances[{balance_index}].asOf must be non-empty"
                ));
            }

            if !matches!(
                balance.get("quality").and_then(Value::as_str),
                Some("exact" | "estimated" | "incomplete" | "unpriceable" | "anomaly")
            ) {
                errors.push(format!(
                    "accounts[{index}].cashBalances[{balance_index}].quality must be a valid ValueQuality"
                ));
            }
        }
    }
}

fn validate_core_ledger_entities(document: &Value, errors: &mut Vec<String>) {
    let account_ids = document["accounts"]
        .as_array()
        .map(|accounts| {
            accounts
                .iter()
                .filter_map(|account| account.get("id").and_then(Value::as_str))
                .collect::<BTreeSet<_>>()
        })
        .unwrap_or_default();
    let instrument_ids = validate_instruments(document.get("instruments"), errors);
    validate_fx_rates(document.get("fxRates"), errors);
    validate_holdings(
        document.get("holdings"),
        &account_ids,
        &instrument_ids,
        errors,
    );
    let movement_index = validate_movements(document, &account_ids, &instrument_ids, errors);
    validate_movement_entry_index(document.get("movementEntries"), &movement_index, errors);
}

fn validate_fx_rates(value: Option<&Value>, errors: &mut Vec<String>) {
    let Some(rates) = value.and_then(Value::as_array) else {
        return;
    };
    let mut ids = BTreeSet::new();
    let mut time_points = BTreeSet::new();
    for (index, rate) in rates.iter().enumerate() {
        let label = format!("fxRates[{index}]");
        let Some(rate) = rate.as_object() else {
            errors.push(format!("{label} must be an object"));
            continue;
        };
        match rate.get("id").and_then(Value::as_str) {
            Some(id) if !id.is_empty() => {
                if !ids.insert(id) {
                    errors.push(format!("duplicate FX rate id: {id}"));
                }
            }
            _ => errors.push(format!("{label}.id must be a non-empty string")),
        }
        let base = rate.get("baseCurrency").and_then(Value::as_str);
        let quote = rate.get("quoteCurrency").and_then(Value::as_str);
        if base.is_none_or(str::is_empty) {
            errors.push(format!("{label}.baseCurrency must be a non-empty string"));
        }
        if quote.is_none_or(str::is_empty) {
            errors.push(format!("{label}.quoteCurrency must be a non-empty string"));
        }
        if base.is_some() && base == quote {
            errors.push(format!("{label} must use two different currencies"));
        }
        let as_of_text = rate.get("asOf").and_then(Value::as_str);
        if let (Some(base), Some(quote), Some(as_of)) = (base, quote, as_of_text)
            && !time_points.insert((base, quote, as_of))
        {
            errors.push(format!(
                "duplicate FX rate time point: {base}/{quote} at {as_of}"
            ));
        }
        if rate
            .get("rate")
            .and_then(Value::as_str)
            .is_none_or(|rate| !is_positive_decimal_string(rate))
        {
            errors.push(format!("{label}.rate must be a positive decimal string"));
        }
        if as_of_text.and_then(parse_rfc3339).is_none() {
            errors.push(format!("{label}.asOf must be an RFC3339 timestamp"));
        }
        if rate
            .get("source")
            .and_then(Value::as_str)
            .is_none_or(str::is_empty)
        {
            errors.push(format!("{label}.source must be a non-empty string"));
        }
        if !matches!(
            rate.get("status").and_then(Value::as_str),
            Some("fresh" | "stale" | "offline_cached" | "incomplete" | "unpriceable" | "error")
        ) {
            errors.push(format!("{label}.status is invalid"));
        }
        if let Some(expires_at) = rate.get("expiresAt")
            && expires_at.as_str().and_then(parse_rfc3339).is_none()
        {
            errors.push(format!("{label}.expiresAt must be an RFC3339 timestamp"));
        }
        if let Some(source_url) = rate.get("sourceUrl")
            && source_url.as_str().is_none_or(str::is_empty)
        {
            errors.push(format!("{label}.sourceUrl must be a non-empty string"));
        }
    }
}

fn validate_instruments<'a>(
    instruments: Option<&'a Value>,
    errors: &mut Vec<String>,
) -> BTreeSet<&'a str> {
    let Some(instruments) = instruments.and_then(Value::as_array) else {
        return BTreeSet::new();
    };
    let mut ids = BTreeSet::new();
    for (index, instrument) in instruments.iter().enumerate() {
        let Some(instrument) = instrument.as_object() else {
            errors.push(format!("instruments[{index}] must be an object"));
            continue;
        };
        let id = instrument.get("id").and_then(Value::as_str);
        match id {
            Some(id) if !id.is_empty() => {
                if !ids.insert(id) {
                    errors.push(format!("duplicate instrument id: {id}"));
                }
            }
            _ => errors.push(format!(
                "instruments[{index}].id must be a non-empty string"
            )),
        }
        for key in ["displayName", "quoteCurrency"] {
            if instrument
                .get(key)
                .and_then(Value::as_str)
                .is_none_or(str::is_empty)
            {
                errors.push(format!(
                    "instruments[{index}].{key} must be a non-empty string"
                ));
            }
        }
        if !matches!(
            instrument.get("type").and_then(Value::as_str),
            Some("cash" | "equity" | "fund" | "crypto" | "fx_cash" | "receivable" | "other")
        ) {
            errors.push(format!("instruments[{index}].type is invalid"));
        }
    }
    ids
}

fn validate_holdings(
    holdings: Option<&Value>,
    account_ids: &BTreeSet<&str>,
    instrument_ids: &BTreeSet<&str>,
    errors: &mut Vec<String>,
) {
    let Some(holdings) = holdings.and_then(Value::as_array) else {
        return;
    };
    let mut ids = BTreeSet::new();
    let mut account_instruments = BTreeSet::new();
    for (index, holding) in holdings.iter().enumerate() {
        let Some(holding) = holding.as_object() else {
            errors.push(format!("holdings[{index}] must be an object"));
            continue;
        };
        let id = holding.get("id").and_then(Value::as_str);
        match id {
            Some(id) if !id.is_empty() => {
                if !ids.insert(id) {
                    errors.push(format!("duplicate holding id: {id}"));
                }
            }
            _ => errors.push(format!("holdings[{index}].id must be a non-empty string")),
        }
        let account_id = holding.get("accountId").and_then(Value::as_str);
        match account_id {
            Some(account_id) if account_ids.contains(account_id) => {}
            _ => errors.push(format!(
                "holdings[{index}].accountId must reference an existing account"
            )),
        }
        let instrument_id = holding.get("instrumentId").and_then(Value::as_str);
        match instrument_id {
            Some(instrument_id) if instrument_ids.contains(instrument_id) => {}
            _ => errors.push(format!(
                "holdings[{index}].instrumentId must reference an existing instrument"
            )),
        }
        if let (Some(account_id), Some(instrument_id)) = (account_id, instrument_id)
            && !account_instruments.insert((account_id, instrument_id))
        {
            errors.push(format!(
                "duplicate holding for account/instrument: {account_id}/{instrument_id}"
            ));
        }
        match holding.get("quantity").and_then(Value::as_str) {
            Some(quantity)
                if is_decimal_string(quantity)
                    && parse_decimal(quantity)
                        .is_ok_and(|quantity| quantity >= DecimalAmount::ZERO) => {}
            _ => errors.push(format!(
                "holdings[{index}].quantity must be a non-negative decimal string"
            )),
        }
        if let Some(cost_basis) = holding.get("costBasisTotal") {
            validate_non_negative_money(
                cost_basis,
                &format!("holdings[{index}].costBasisTotal"),
                errors,
            );
        }
        if let Some(market_value) = holding.get("marketValue") {
            validate_non_negative_money(
                market_value,
                &format!("holdings[{index}].marketValue"),
                errors,
            );
            if market_value
                .get("asOf")
                .and_then(Value::as_str)
                .is_none_or(str::is_empty)
            {
                errors.push(format!(
                    "holdings[{index}].marketValue.asOf must be a non-empty string"
                ));
            }
            if !matches!(
                market_value.get("quality").and_then(Value::as_str),
                Some("exact" | "estimated" | "incomplete" | "unpriceable" | "anomaly")
            ) {
                errors.push(format!("holdings[{index}].marketValue.quality is invalid"));
            }
        }
        if !matches!(
            holding.get("quoteStatus").and_then(Value::as_str),
            Some("fresh" | "stale" | "offline_cached" | "incomplete" | "unpriceable" | "error")
        ) {
            errors.push(format!("holdings[{index}].quoteStatus is invalid"));
        }
        if holding
            .get("asOf")
            .and_then(Value::as_str)
            .is_none_or(str::is_empty)
        {
            errors.push(format!("holdings[{index}].asOf must be a non-empty string"));
        }
    }
}

#[derive(Default)]
struct StoredMovementIndex<'a> {
    groups: BTreeMap<&'a str, &'a str>,
    entry_ids: BTreeMap<&'a str, BTreeSet<&'a str>>,
}

fn validate_movements<'a>(
    document: &'a Value,
    account_ids: &BTreeSet<&str>,
    instrument_ids: &BTreeSet<&str>,
    errors: &mut Vec<String>,
) -> StoredMovementIndex<'a> {
    let Some(movements) = document["movements"].as_array() else {
        return StoredMovementIndex::default();
    };
    let mut index_by_id = StoredMovementIndex::default();
    for (index, movement) in movements.iter().enumerate() {
        let Some(movement) = movement.as_object() else {
            errors.push(format!("movements[{index}] must be an object"));
            continue;
        };
        let movement_id = movement.get("id").and_then(Value::as_str);
        let atomic_group_id = movement.get("atomicGroupId").and_then(Value::as_str);
        match (movement_id, atomic_group_id) {
            (Some(movement_id), Some(group_id))
                if !movement_id.is_empty() && !group_id.is_empty() =>
            {
                if index_by_id.groups.insert(movement_id, group_id).is_some() {
                    errors.push(format!("duplicate movement id: {movement_id}"));
                }
            }
            _ => {
                if movement_id.is_none_or(str::is_empty) {
                    errors.push(format!("movements[{index}].id must be a non-empty string"));
                }
                if atomic_group_id.is_none_or(str::is_empty) {
                    errors.push(format!(
                        "movements[{index}].atomicGroupId must be a non-empty string"
                    ));
                }
            }
        }
        for key in [
            "occurredAt",
            "recordedAt",
            "title",
            "createdAt",
            "updatedAt",
        ] {
            if movement
                .get(key)
                .and_then(Value::as_str)
                .is_none_or(str::is_empty)
            {
                errors.push(format!(
                    "movements[{index}].{key} must be a non-empty string"
                ));
            }
        }
        let movement_type = movement.get("type").and_then(Value::as_str);
        if !matches!(
            movement_type,
            Some(
                "income"
                    | "expense"
                    | "transfer"
                    | "buy"
                    | "sell"
                    | "dividend"
                    | "interest"
                    | "fee"
                    | "adjustment"
                    | "loan_disbursement"
                    | "loan_repayment"
                    | "correction"
            )
        ) {
            errors.push(format!("movements[{index}].type is invalid"));
        }
        if !matches!(
            movement.get("status").and_then(Value::as_str),
            Some(
                "draft" | "pending_review" | "confirmed" | "in_transit" | "cancelled" | "reversed"
            )
        ) {
            errors.push(format!("movements[{index}].status is invalid"));
        }
        validate_string_array(
            movement.get("tags"),
            &format!("movements[{index}].tags"),
            errors,
        );
        let entry_ids = validate_stored_movement_entries(
            movement.get("entries"),
            index,
            account_ids,
            instrument_ids,
            matches!(
                movement.get("status").and_then(Value::as_str),
                Some("confirmed" | "in_transit" | "reversed")
            ),
            errors,
        );
        if let Some(movement_id) = movement_id {
            index_by_id.entry_ids.insert(movement_id, entry_ids);
        }
        if let (Some(movement_type), Some(entries)) = (
            movement_type,
            movement.get("entries").and_then(Value::as_array),
        ) {
            if movement_type == "transfer" {
                validate_simple_transfer(Some(entries), movement.get("transferMeta"), errors);
            } else if movement_type != "correction" {
                validate_movement_semantics(document, movement_type, entries, errors);
            }
        }
        validate_investment_sale_result(movement, index, errors);
        validate_movement_cost_basis_fx(movement, index, errors);
    }
    index_by_id
}

fn validate_stored_movement_entries<'a>(
    entries: Option<&'a Value>,
    movement_index: usize,
    account_ids: &BTreeSet<&str>,
    instrument_ids: &BTreeSet<&str>,
    require_instrument_exists: bool,
    errors: &mut Vec<String>,
) -> BTreeSet<&'a str> {
    let Some(entries) = entries.and_then(Value::as_array) else {
        errors.push(format!(
            "movements[{movement_index}].entries must be a non-empty array"
        ));
        return BTreeSet::new();
    };
    if entries.is_empty() {
        errors.push(format!(
            "movements[{movement_index}].entries must be a non-empty array"
        ));
    }
    let mut ids = BTreeSet::new();
    for (entry_index, entry) in entries.iter().enumerate() {
        let label = format!("movements[{movement_index}].entries[{entry_index}]");
        let Some(entry) = entry.as_object() else {
            errors.push(format!("{label} must be an object"));
            continue;
        };
        let id = entry.get("id").and_then(Value::as_str);
        match id {
            Some(id) if !id.is_empty() => {
                if !ids.insert(id) {
                    errors.push(format!("duplicate movement entry id: {id}"));
                }
            }
            _ => errors.push(format!("{label}.id must be a non-empty string")),
        }
        let account_id = entry.get("accountId").and_then(Value::as_str);
        if account_id.is_none_or(|account_id| !account_ids.contains(account_id)) {
            errors.push(format!(
                "{label}.accountId must reference an existing account"
            ));
        }
        if !entry
            .get("amount")
            .and_then(Value::as_str)
            .is_some_and(is_positive_decimal_string)
        {
            errors.push(format!("{label}.amount must be a positive decimal string"));
        }
        if entry
            .get("currency")
            .and_then(Value::as_str)
            .is_none_or(str::is_empty)
        {
            errors.push(format!("{label}.currency must be a non-empty string"));
        }
        if !matches!(
            entry.get("direction").and_then(Value::as_str),
            Some("in" | "out")
        ) {
            errors.push(format!("{label}.direction must be in or out"));
        }
        if !matches!(
            entry.get("role").and_then(Value::as_str),
            Some("source" | "destination" | "fee" | "discount" | "pnl" | "tax" | "adjustment")
        ) {
            errors.push(format!("{label}.role is invalid"));
        }
        if let Some(instrument_id) = entry.get("instrumentId").and_then(Value::as_str)
            && require_instrument_exists
            && !instrument_ids.contains(instrument_id)
        {
            errors.push(format!(
                "{label}.instrumentId must reference an existing instrument"
            ));
        }
    }
    ids
}

fn validate_movement_entry_index(
    entries: Option<&Value>,
    movements: &StoredMovementIndex<'_>,
    errors: &mut Vec<String>,
) {
    let Some(entries) = entries.and_then(Value::as_array) else {
        return;
    };
    let mut indexed = BTreeMap::<&str, BTreeSet<&str>>::new();
    let mut global_entry_ids = BTreeSet::new();
    for (index, entry) in entries.iter().enumerate() {
        let Some(entry) = entry.as_object() else {
            errors.push(format!("movementEntries[{index}] must be an object"));
            continue;
        };
        let movement_id = entry.get("movementId").and_then(Value::as_str);
        let atomic_group_id = entry.get("atomicGroupId").and_then(Value::as_str);
        let entry_id = entry.get("id").and_then(Value::as_str);
        match movement_id {
            Some(movement_id) if movements.groups.contains_key(movement_id) => {
                if atomic_group_id != movements.groups.get(movement_id).copied() {
                    errors.push(format!(
                        "movementEntries[{index}].atomicGroupId must match its movement"
                    ));
                }
                if let Some(entry_id) = entry_id {
                    indexed.entry(movement_id).or_default().insert(entry_id);
                }
            }
            _ => errors.push(format!(
                "movementEntries[{index}].movementId must reference an existing movement"
            )),
        }
        match entry_id {
            Some(entry_id) if !entry_id.is_empty() => {
                if !global_entry_ids.insert(entry_id) {
                    errors.push(format!("duplicate indexed movement entry id: {entry_id}"));
                }
            }
            _ => errors.push(format!(
                "movementEntries[{index}].id must be a non-empty string"
            )),
        }
    }
    for (movement_id, expected_ids) in &movements.entry_ids {
        let actual_ids = indexed.get(movement_id).cloned().unwrap_or_default();
        if &actual_ids != expected_ids {
            errors.push(format!(
                "movementEntries index does not match movement.entries for {movement_id}"
            ));
        }
    }
}

fn validate_non_negative_money(value: &Value, label: &str, errors: &mut Vec<String>) {
    let Some(value) = value.as_object() else {
        errors.push(format!("{label} must be an object"));
        return;
    };
    match value.get("amount").and_then(Value::as_str) {
        Some(amount)
            if is_decimal_string(amount)
                && parse_decimal(amount).is_ok_and(|amount| amount >= DecimalAmount::ZERO) => {}
        _ => errors.push(format!(
            "{label}.amount must be a non-negative decimal string"
        )),
    }
    if value
        .get("currency")
        .and_then(Value::as_str)
        .is_none_or(str::is_empty)
    {
        errors.push(format!("{label}.currency must be a non-empty string"));
    }
}

fn parsed_money_parts<'a>(
    value: Option<&'a Value>,
    label: &str,
    errors: &mut Vec<String>,
) -> Option<(DecimalAmount, &'a str)> {
    let Some(value) = value else {
        errors.push(format!("{label} is required"));
        return None;
    };
    let Some(object) = value.as_object() else {
        errors.push(format!("{label} must be an object"));
        return None;
    };
    let amount = match object.get("amount").and_then(Value::as_str) {
        Some(amount) => match parse_decimal(amount) {
            Ok(amount) => Some(amount),
            Err(_) => {
                errors.push(format!("{label}.amount must be a decimal string"));
                None
            }
        },
        None => {
            errors.push(format!("{label}.amount must be a decimal string"));
            None
        }
    };
    let currency = match object.get("currency").and_then(Value::as_str) {
        Some(currency) if !currency.is_empty() => Some(currency),
        _ => {
            errors.push(format!("{label}.currency must be a non-empty string"));
            None
        }
    };
    amount.zip(currency)
}

#[derive(Clone, Copy)]
struct ParsedExecutionFxBasis<'a> {
    base_currency: &'a str,
    quote_currency: &'a str,
    rate: DecimalAmount,
}

fn validate_execution_fx_basis<'a>(
    value: Option<&'a Value>,
    label: &str,
    errors: &mut Vec<String>,
) -> Option<ParsedExecutionFxBasis<'a>> {
    let Some(value) = value else {
        errors.push(format!("{label} is required"));
        return None;
    };
    let Some(object) = value.as_object() else {
        errors.push(format!("{label} must be an object"));
        return None;
    };
    let base_currency = object
        .get("baseCurrency")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty());
    let quote_currency = object
        .get("quoteCurrency")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty());
    let rate = object
        .get("rate")
        .and_then(Value::as_str)
        .and_then(|value| parse_decimal(value).ok())
        .filter(|value| *value > DecimalAmount::ZERO);
    if base_currency.is_none() {
        errors.push(format!("{label}.baseCurrency must be a non-empty string"));
    }
    if quote_currency.is_none() {
        errors.push(format!("{label}.quoteCurrency must be a non-empty string"));
    }
    if rate.is_none() {
        errors.push(format!("{label}.rate must be a positive decimal string"));
    }
    if object
        .get("asOf")
        .and_then(Value::as_str)
        .and_then(parse_rfc3339)
        .is_none()
    {
        errors.push(format!("{label}.asOf must be an RFC3339 timestamp"));
    }
    for field in ["sourceRateId", "source"] {
        if object
            .get(field)
            .and_then(Value::as_str)
            .is_none_or(str::is_empty)
        {
            errors.push(format!("{label}.{field} must be a non-empty string"));
        }
    }
    if !matches!(object.get("inverted"), Some(Value::Bool(_))) {
        errors.push(format!("{label}.inverted must be a boolean"));
    }
    match (base_currency, quote_currency, rate) {
        (Some(base_currency), Some(quote_currency), Some(rate)) => Some(ParsedExecutionFxBasis {
            base_currency,
            quote_currency,
            rate,
        }),
        _ => None,
    }
}

fn validate_investment_sale_result(
    movement: &serde_json::Map<String, Value>,
    movement_index: usize,
    errors: &mut Vec<String>,
) {
    let Some(result) = movement.get("saleResult") else {
        return;
    };
    let label = format!("movements[{movement_index}].saleResult");
    if movement.get("type").and_then(Value::as_str) != Some("sell") {
        errors.push(format!("{label} is only valid for sell movements"));
    }
    if !matches!(
        movement.get("status").and_then(Value::as_str),
        Some("confirmed" | "in_transit" | "reversed")
    ) {
        errors.push(format!(
            "{label} is only valid after a sell movement is confirmed"
        ));
    }
    let Some(result) = result.as_object() else {
        errors.push(format!("{label} must be an object"));
        return;
    };
    if result.get("costBasisMethod").and_then(Value::as_str) != Some("average_cost") {
        errors.push(format!("{label}.costBasisMethod must be average_cost"));
    }
    let status = result.get("realizedPnlStatus").and_then(Value::as_str);
    if !matches!(
        status,
        Some("calculated" | "calculated_with_fx" | "cost_basis_unavailable" | "currency_mismatch")
    ) {
        errors.push(format!("{label}.realizedPnlStatus is invalid"));
    }

    let gross = parsed_money_parts(
        result.get("grossProceeds"),
        &format!("{label}.grossProceeds"),
        errors,
    );
    let fees = parsed_money_parts(
        result.get("feeAndTaxTotal"),
        &format!("{label}.feeAndTaxTotal"),
        errors,
    );
    let net = parsed_money_parts(
        result.get("netProceeds"),
        &format!("{label}.netProceeds"),
        errors,
    );
    for (field, value) in [
        ("grossProceeds", gross),
        ("feeAndTaxTotal", fees),
        ("netProceeds", net),
    ] {
        if value.is_some_and(|(amount, _)| amount < DecimalAmount::ZERO) {
            errors.push(format!("{label}.{field}.amount must be non-negative"));
        }
    }
    if let (
        Some((gross_amount, gross_currency)),
        Some((fee_amount, fee_currency)),
        Some((net_amount, net_currency)),
    ) = (gross, fees, net)
    {
        if gross_currency != fee_currency || gross_currency != net_currency {
            errors.push(format!(
                "{label} gross proceeds, fees, and net proceeds must use one currency"
            ));
        }
        if gross_amount - fee_amount != net_amount {
            errors.push(format!("{label}.netProceeds must equal gross minus fees"));
        }
    }

    let released = result.get("costBasisReleased").and_then(|value| {
        parsed_money_parts(Some(value), &format!("{label}.costBasisReleased"), errors)
    });
    if released.is_some_and(|(amount, _)| amount < DecimalAmount::ZERO) {
        errors.push(format!(
            "{label}.costBasisReleased.amount must be non-negative"
        ));
    }
    let pnl = result
        .get("realizedPnl")
        .and_then(|value| parsed_money_parts(Some(value), &format!("{label}.realizedPnl"), errors));
    let converted_net = result
        .get("netProceedsInCostBasisCurrency")
        .and_then(|value| {
            parsed_money_parts(
                Some(value),
                &format!("{label}.netProceedsInCostBasisCurrency"),
                errors,
            )
        });
    let fx_basis = result.get("fxBasis").and_then(|value| {
        validate_execution_fx_basis(Some(value), &format!("{label}.fxBasis"), errors)
    });

    match status {
        Some("calculated") => {
            let (
                Some((net_amount, net_currency)),
                Some((released_amount, released_currency)),
                Some((pnl_amount, pnl_currency)),
            ) = (net, released, pnl)
            else {
                errors.push(format!(
                    "{label} calculated status requires costBasisReleased and realizedPnl"
                ));
                return;
            };
            if net_currency != released_currency || net_currency != pnl_currency {
                errors.push(format!("{label} calculated amounts must use one currency"));
            }
            if net_amount - released_amount != pnl_amount {
                errors.push(format!(
                    "{label}.realizedPnl must equal net proceeds minus released cost basis"
                ));
            }
            if converted_net.is_some() || fx_basis.is_some() {
                errors.push(format!(
                    "{label} same-currency calculation must not include an FX basis"
                ));
            }
        }
        Some("calculated_with_fx") => {
            let (
                Some((net_amount, net_currency)),
                Some((released_amount, released_currency)),
                Some((converted_amount, converted_currency)),
                Some((pnl_amount, pnl_currency)),
                Some(fx_basis),
            ) = (net, released, converted_net, pnl, fx_basis)
            else {
                errors.push(format!(
                    "{label} FX calculation requires net conversion, released cost, realized PnL, and FX basis"
                ));
                return;
            };
            if net_currency != fx_basis.base_currency
                || released_currency != fx_basis.quote_currency
                || converted_currency != released_currency
                || pnl_currency != released_currency
            {
                errors.push(format!(
                    "{label} FX currencies must connect net proceeds to released cost basis"
                ));
            }
            if multiply_decimal(net_amount, fx_basis.rate) != converted_amount {
                errors.push(format!(
                    "{label}.netProceedsInCostBasisCurrency must equal net proceeds times FX rate"
                ));
            }
            if converted_amount - released_amount != pnl_amount {
                errors.push(format!(
                    "{label}.realizedPnl must equal converted net proceeds minus released cost basis"
                ));
            }
        }
        Some("cost_basis_unavailable") => {
            if released.is_some() || pnl.is_some() || converted_net.is_some() || fx_basis.is_some()
            {
                errors.push(format!(
                    "{label} unavailable cost basis must not include released cost or realized PnL"
                ));
            }
        }
        Some("currency_mismatch") => {
            if released.is_none() || pnl.is_some() || converted_net.is_some() || fx_basis.is_some()
            {
                errors.push(format!(
                    "{label} currency mismatch requires released cost and no realized PnL"
                ));
            }
            if let (Some((_, net_currency)), Some((_, released_currency))) = (net, released)
                && net_currency == released_currency
            {
                errors.push(format!(
                    "{label} currency mismatch requires different proceeds and cost currencies"
                ));
            }
        }
        _ => {}
    }
}

fn validate_movement_cost_basis_fx(
    movement: &serde_json::Map<String, Value>,
    movement_index: usize,
    errors: &mut Vec<String>,
) {
    let Some(value) = movement.get("costBasisFx") else {
        return;
    };
    let label = format!("movements[{movement_index}].costBasisFx");
    if movement.get("type").and_then(Value::as_str) != Some("buy") {
        errors.push(format!("{label} is only valid for buy movements"));
    }
    if !matches!(
        movement.get("status").and_then(Value::as_str),
        Some("confirmed" | "in_transit" | "reversed")
    ) {
        errors.push(format!(
            "{label} is only valid after a buy movement is confirmed"
        ));
    }
    let parsed = validate_execution_fx_basis(Some(value), &label, errors);
    let principal_currency = movement
        .get("entries")
        .and_then(Value::as_array)
        .and_then(|entries| {
            entries.iter().find(|entry| {
                entry.get("instrumentId").is_none()
                    && entry.get("role").and_then(Value::as_str) == Some("source")
            })
        })
        .and_then(|entry| entry.get("currency"))
        .and_then(Value::as_str);
    if let (Some(parsed), Some(principal_currency)) = (parsed, principal_currency) {
        if parsed.base_currency != principal_currency {
            errors.push(format!(
                "{label}.baseCurrency must match the buy principal currency"
            ));
        }
        if parsed.base_currency == parsed.quote_currency {
            errors.push(format!("{label} must convert between different currencies"));
        }
    }
}

fn validate_subscriptions(
    subscriptions: Option<&Value>,
    accounts: Option<&Value>,
    movements: Option<&Value>,
    errors: &mut Vec<String>,
) {
    let Some(subscriptions) = subscriptions.and_then(Value::as_array) else {
        return;
    };
    let account_ids = accounts
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.get("id").and_then(Value::as_str))
                .collect::<BTreeSet<_>>()
        })
        .unwrap_or_default();
    let movement_by_id = movements
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|movement| {
                    Some((movement.get("id")?.as_str()?.to_string(), movement.clone()))
                })
                .collect::<BTreeMap<_, _>>()
        })
        .unwrap_or_default();
    let mut ids = BTreeSet::new();
    let mut pending_keys = BTreeSet::new();
    let mut pending_links = BTreeMap::new();

    for (index, subscription) in subscriptions.iter().enumerate() {
        let path = format!("subscriptions[{index}]");
        let Some(object) = subscription.as_object() else {
            errors.push(format!("{path} must be an object"));
            continue;
        };
        for key in ["id", "displayName", "provider", "paymentAccountId"] {
            if object
                .get(key)
                .and_then(Value::as_str)
                .is_none_or(str::is_empty)
            {
                errors.push(format!("{path}.{key} must be a non-empty string"));
            }
        }
        if let Some(id) = object.get("id").and_then(Value::as_str)
            && !ids.insert(id)
        {
            errors.push(format!("duplicate subscription id: {id}"));
        }
        if let Some(account_id) = object.get("paymentAccountId").and_then(Value::as_str)
            && !account_ids.contains(account_id)
        {
            errors.push(format!("{path}.paymentAccountId must reference an account"));
        }
        match object.get("amount").and_then(Value::as_object) {
            Some(amount) => {
                if amount
                    .get("amount")
                    .and_then(Value::as_str)
                    .is_none_or(|value| !is_positive_decimal_string(value))
                {
                    errors.push(format!(
                        "{path}.amount.amount must be a positive decimal string"
                    ));
                }
                if amount
                    .get("currency")
                    .and_then(Value::as_str)
                    .is_none_or(str::is_empty)
                {
                    errors.push(format!("{path}.amount.currency must be non-empty"));
                }
            }
            None => errors.push(format!("{path}.amount must be an object")),
        }
        validate_subscription_cycle(object.get("billingCycle"), &path, errors);
        validate_subscription_duration(object.get("duration"), &path, errors);
        let start = validate_iso_date_field(object.get("startDate"), &path, "startDate", errors);
        let end = match object.get("endDate") {
            None | Some(Value::Null) => None,
            value => validate_iso_date_field(value, &path, "endDate", errors),
        };
        let next = match object.get("nextChargeDate") {
            None | Some(Value::Null) => None,
            value => validate_iso_date_field(value, &path, "nextChargeDate", errors),
        };
        if let (Some(start), Some(end)) = (start, end)
            && end < start
        {
            errors.push(format!("{path}.endDate must be on or after startDate"));
        }
        if let (Some(start), Some(next)) = (start, next)
            && next < start
        {
            errors.push(format!(
                "{path}.nextChargeDate must be on or after startDate"
            ));
        }
        let status = object.get("status").and_then(Value::as_str);
        if !matches!(
            status,
            Some("trial" | "active" | "paused" | "cancelled" | "expired")
        ) {
            errors.push(format!("{path}.status is invalid"));
        }
        if matches!(status, Some("trial" | "active")) && next.is_none() {
            errors.push(format!(
                "{path}.nextChargeDate is required while trial or active"
            ));
        }
        if matches!(status, Some("cancelled" | "expired")) && next.is_some() {
            errors.push(format!(
                "{path}.nextChargeDate must be null while cancelled or expired"
            ));
        }
        if object.get("autoRenew").and_then(Value::as_bool).is_none() {
            errors.push(format!("{path}.autoRenew must be a boolean"));
        }
        if !matches!(
            object.get("billingAnchorDay").and_then(Value::as_u64),
            Some(1..=31)
        ) {
            errors.push(format!(
                "{path}.billingAnchorDay must be an integer from 1 to 31"
            ));
        }
        if !matches!(
            object.get("reminderDaysBefore").and_then(Value::as_u64),
            Some(0..=365)
        ) {
            errors.push(format!(
                "{path}.reminderDaysBefore must be an integer from 0 to 365"
            ));
        }
        let pending_movement = match object.get("pendingChargeMovementId") {
            None => None,
            Some(Value::String(value)) if !value.is_empty() => Some(value.as_str()),
            Some(_) => {
                errors.push(format!(
                    "{path}.pendingChargeMovementId must be a non-empty string"
                ));
                None
            }
        };
        let pending_date = match object.get("pendingChargeDate") {
            None => None,
            Some(Value::String(value)) if !value.is_empty() => Some(value.as_str()),
            Some(_) => {
                errors.push(format!(
                    "{path}.pendingChargeDate must be a non-empty string"
                ));
                None
            }
        };
        if pending_movement.is_some() != pending_date.is_some() {
            errors.push(format!(
                "{path}.pendingChargeMovementId and pendingChargeDate must appear together"
            ));
        }
        if let Some(date) = pending_date
            && Date::parse(date, &Iso8601::DATE).is_err()
        {
            errors.push(format!("{path}.pendingChargeDate must be an ISO date"));
        }
        if let (Some(subscription_id), Some(movement_id), Some(charge_date)) = (
            object.get("id").and_then(Value::as_str),
            pending_movement,
            pending_date,
        ) {
            if !pending_keys.insert((subscription_id.to_string(), charge_date.to_string())) {
                errors.push(format!(
                    "duplicate pending subscription charge for {subscription_id} on {charge_date}"
                ));
            }
            pending_links.insert(
                subscription_id.to_string(),
                (movement_id.to_string(), charge_date.to_string()),
            );
            match movement_by_id.get(movement_id) {
                Some(movement) => {
                    if movement.get("status").and_then(Value::as_str) != Some("pending_review") {
                        errors.push(format!(
                            "{path}.pendingChargeMovementId must reference a pending_review movement"
                        ));
                    }
                    if movement.get("subscriptionId").and_then(Value::as_str)
                        != Some(subscription_id)
                    {
                        errors.push(format!(
                            "{path}.pendingChargeMovementId must reference the same subscription"
                        ));
                    }
                    if movement.get("scheduledChargeDate").and_then(Value::as_str)
                        != Some(charge_date)
                    {
                        errors.push(format!(
                            "{path}.pendingChargeDate must match movement.scheduledChargeDate"
                        ));
                    }
                }
                None => errors.push(format!(
                    "{path}.pendingChargeMovementId must reference an existing movement"
                )),
            }
        }
    }

    if let Some(movements) = movements.and_then(Value::as_array) {
        for (index, movement) in movements.iter().enumerate() {
            if movement.get("status").and_then(Value::as_str) != Some("pending_review") {
                continue;
            }
            let Some(subscription_id_value) = movement.get("subscriptionId") else {
                continue;
            };
            let Some(subscription_id) = subscription_id_value
                .as_str()
                .filter(|subscription_id| !subscription_id.is_empty())
            else {
                errors.push(format!(
                    "movements[{index}].subscriptionId must be a non-empty string"
                ));
                continue;
            };
            let movement_id = movement
                .get("id")
                .and_then(Value::as_str)
                .filter(|movement_id| !movement_id.is_empty());
            if movement_id.is_none() {
                errors.push(format!(
                    "movements[{index}].id must be a non-empty string for a pending subscription charge"
                ));
            }
            if movement
                .get("atomicGroupId")
                .and_then(Value::as_str)
                .is_none_or(str::is_empty)
            {
                errors.push(format!(
                    "movements[{index}].atomicGroupId must be a non-empty string for a pending subscription charge"
                ));
            }
            let charge_date = movement
                .get("scheduledChargeDate")
                .and_then(Value::as_str)
                .filter(|charge_date| !charge_date.is_empty());
            if charge_date.is_none() {
                errors.push(format!(
                    "movements[{index}].scheduledChargeDate must be a non-empty ISO date"
                ));
            } else if charge_date.is_some_and(|date| Date::parse(date, &Iso8601::DATE).is_err()) {
                errors.push(format!(
                    "movements[{index}].scheduledChargeDate must be an ISO date"
                ));
            }
            match (movement_id, charge_date, pending_links.get(subscription_id)) {
                (Some(movement_id), Some(charge_date), Some((linked_id, linked_date)))
                    if linked_id == movement_id && linked_date == charge_date => {}
                _ => errors.push(format!(
                    "movements[{index}] pending subscription charge must match the subscription pending pointer"
                )),
            }
        }
    }
}

fn validate_subscription_cycle(value: Option<&Value>, path: &str, errors: &mut Vec<String>) {
    let Some(cycle) = value.and_then(Value::as_object) else {
        errors.push(format!("{path}.billingCycle must be an object"));
        return;
    };
    if !matches!(
        cycle.get("unit").and_then(Value::as_str),
        Some("day" | "week" | "month" | "year")
    ) {
        errors.push(format!("{path}.billingCycle.unit is invalid"));
    }
    if !matches!(cycle.get("interval").and_then(Value::as_u64), Some(1..=365)) {
        errors.push(format!(
            "{path}.billingCycle.interval must be an integer from 1 to 365"
        ));
    }
}

fn validate_subscription_duration(value: Option<&Value>, path: &str, errors: &mut Vec<String>) {
    let Some(value) = value else {
        return;
    };
    let Some(duration) = value.as_object() else {
        errors.push(format!("{path}.duration must be an object"));
        return;
    };
    if !matches!(
        duration.get("unit").and_then(Value::as_str),
        Some("day" | "month" | "year")
    ) {
        errors.push(format!("{path}.duration.unit is invalid"));
    }
    if !matches!(
        duration.get("count").and_then(Value::as_u64),
        Some(1..=1200)
    ) {
        errors.push(format!(
            "{path}.duration.count must be an integer from 1 to 1200"
        ));
    }
}

fn validate_iso_date_field(
    value: Option<&Value>,
    path: &str,
    key: &str,
    errors: &mut Vec<String>,
) -> Option<Date> {
    match value.and_then(Value::as_str) {
        Some(value) => match Date::parse(value, &Iso8601::DATE) {
            Ok(date) => Some(date),
            Err(_) => {
                errors.push(format!("{path}.{key} must be an ISO date"));
                None
            }
        },
        None => {
            errors.push(format!("{path}.{key} must be an ISO date"));
            None
        }
    }
}

fn validate_sync_state_and_changes(
    sync_state: Option<&Value>,
    sync_changes: Option<&Value>,
    errors: &mut Vec<String>,
) {
    let Some(sync_state) = sync_state.and_then(Value::as_object) else {
        errors.push("syncState must be an object".to_string());
        return;
    };
    let cursor = match sync_state.get("cursor") {
        Some(Value::Null) => None,
        Some(Value::String(value)) if !value.trim().is_empty() => Some(value.as_str()),
        _ => {
            errors.push("syncState.cursor must be null or a non-empty string".to_string());
            None
        }
    };
    if !matches!(
        sync_state.get("nextChangeSequence").and_then(Value::as_u64),
        Some(1..)
    ) {
        errors.push("syncState.nextChangeSequence must be a positive integer".to_string());
    }
    let pending: &[Value] = match sync_state.get("pendingChangeIds").and_then(Value::as_array) {
        Some(pending) => pending,
        None => {
            errors.push("syncState.pendingChangeIds must be an array".to_string());
            &[]
        }
    };
    let Some(changes) = sync_changes.and_then(Value::as_array) else {
        return;
    };

    let allowed_entity_types = [
        "account",
        "instrument",
        "holding",
        "movement",
        "dca_plan",
        "subscription",
        "category",
        "counterparty",
        "quote",
        "fx_rate",
        "snapshot",
        "ai_proposal",
    ];
    let allowed_operations = ["create", "update", "delete", "correction"];
    let mut known_ids = BTreeMap::<String, (usize, bool)>::new();
    let mut source_changes = BTreeSet::<(String, String)>::new();
    let mut previous_sequence = None;

    for (index, change) in changes.iter().enumerate() {
        let path = format!("syncChanges[{index}]");
        let Some(change) = change.as_object() else {
            errors.push(format!("{path} must be an object"));
            continue;
        };

        let change_id = change.get("id").and_then(Value::as_str);
        let sequence = change_id.and_then(sync_change_sequence);
        match (change_id, sequence) {
            (Some(change_id), Some(sequence)) => {
                if known_ids.contains_key(change_id) {
                    errors.push(format!(
                        "{path}.id is a duplicate sync change id: {change_id}"
                    ));
                }
                if previous_sequence.is_some_and(|previous| sequence <= previous) {
                    errors.push(format!(
                        "{path}.id sequence must be strictly increasing in syncChanges"
                    ));
                }
                previous_sequence = Some(sequence);
            }
            _ => errors.push(format!(
                "{path}.id must be a canonical positive local_change_N id"
            )),
        }

        let device_id = change
            .get("deviceId")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty());
        if device_id.is_none() {
            errors.push(format!("{path}.deviceId must be a non-empty string"));
        }
        if !matches!(
            change.get("entityType").and_then(Value::as_str),
            Some(value) if allowed_entity_types.contains(&value)
        ) {
            errors.push(format!("{path}.entityType is invalid"));
        }
        if change
            .get("entityId")
            .and_then(Value::as_str)
            .is_none_or(|value| value.trim().is_empty())
        {
            errors.push(format!("{path}.entityId must be a non-empty string"));
        }
        if !matches!(
            change.get("operation").and_then(Value::as_str),
            Some(value) if allowed_operations.contains(&value)
        ) {
            errors.push(format!("{path}.operation is invalid"));
        }
        if !change.contains_key("payload") {
            errors.push(format!("{path}.payload must be present"));
        }
        if change
            .get("createdAt")
            .and_then(Value::as_str)
            .and_then(parse_rfc3339)
            .is_none()
        {
            errors.push(format!("{path}.createdAt must be an RFC3339 timestamp"));
        }

        let source_device_id = change
            .get("sourceDeviceId")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty());
        let source_change_id = change
            .get("sourceChangeId")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty());
        let is_local = match (source_device_id, source_change_id) {
            (None, None) => {
                if device_id != Some(LOCAL_SYNC_DEVICE_ID) {
                    errors.push(format!(
                        "{path} non-local change must include sourceDeviceId/sourceChangeId"
                    ));
                }
                if change.contains_key("receivedAt") {
                    errors.push(format!("{path} local change must not include receivedAt"));
                }
                true
            }
            (Some(source_device_id), Some(source_change_id)) => {
                if device_id != Some(source_device_id) {
                    errors.push(format!("{path}.sourceDeviceId must equal deviceId"));
                }
                if source_device_id == LOCAL_SYNC_DEVICE_ID {
                    errors.push(format!(
                        "{path}.sourceDeviceId must not use the reserved local device id"
                    ));
                }
                if !source_changes
                    .insert((source_device_id.to_string(), source_change_id.to_string()))
                {
                    errors.push(format!(
                        "{path} has duplicate sourceDeviceId/sourceChangeId"
                    ));
                }
                if change
                    .get("receivedAt")
                    .and_then(Value::as_str)
                    .and_then(parse_rfc3339)
                    .is_none()
                {
                    errors.push(format!("{path}.receivedAt must be an RFC3339 timestamp"));
                }
                false
            }
            _ => {
                errors.push(format!(
                    "{path}.sourceDeviceId and sourceChangeId must appear together"
                ));
                false
            }
        };

        if let Some(change_id) = change_id {
            known_ids
                .entry(change_id.to_string())
                .or_insert((index, is_local));
        }
    }

    match (changes.last(), cursor) {
        (None, None) => {}
        (None, Some(_)) => {
            errors.push("syncState.cursor must be null for an empty log".to_string())
        }
        (Some(last), Some(cursor)) if last.get("id").and_then(Value::as_str) == Some(cursor) => {}
        (Some(_), Some(_)) => {
            errors.push("syncState.cursor must equal the last sync change id".to_string())
        }
        (Some(_), None) => {
            errors.push("syncState.cursor must equal the last sync change id".to_string())
        }
    }

    let mut pending_seen = BTreeSet::new();
    let mut previous_pending_index = None;
    for (index, pending_id) in pending.iter().enumerate() {
        let Some(pending_id) = pending_id.as_str().filter(|value| !value.trim().is_empty()) else {
            errors.push(format!(
                "syncState.pendingChangeIds[{index}] must be a non-empty string"
            ));
            continue;
        };
        if !pending_seen.insert(pending_id) {
            errors.push("syncState.pendingChangeIds must not contain duplicates".to_string());
            continue;
        }
        let Some((log_index, is_local)) = known_ids.get(pending_id).copied() else {
            errors.push(format!(
                "syncState.pendingChangeIds contains unknown sync change id: {pending_id}"
            ));
            continue;
        };
        if !is_local {
            errors.push(format!(
                "syncState.pendingChangeIds must reference only local changes: {pending_id}"
            ));
        }
        if previous_pending_index.is_some_and(|previous| log_index <= previous) {
            errors.push("syncState.pendingChangeIds must follow sync log order".to_string());
        }
        previous_pending_index = Some(log_index);
    }
}

fn sync_change_sequence(change_id: &str) -> Option<u64> {
    let sequence = change_id
        .strip_prefix("local_change_")?
        .parse::<u64>()
        .ok()?;
    (sequence > 0 && change_id == format!("local_change_{sequence:06}")).then_some(sequence)
}

fn validate_idempotency_state(state: Option<&Value>, errors: &mut Vec<String>) {
    let Some(state) = state.and_then(Value::as_object) else {
        errors.push("idempotencyState must be an object".to_string());
        return;
    };

    if state.get("version").and_then(Value::as_i64) != Some(IDEMPOTENCY_STATE_VERSION) {
        errors.push(format!(
            "idempotencyState.version must be {IDEMPOTENCY_STATE_VERSION}"
        ));
    }

    let Some(records) = state.get("records").and_then(Value::as_object) else {
        errors.push("idempotencyState.records must be an object".to_string());
        return;
    };

    for (key_hash, record) in records {
        let path = format!("idempotencyState.records.{key_hash}");
        if !is_sha256_urlsafe_hash(key_hash) {
            errors.push(format!("{path} key must be a SHA-256 URL-safe hash"));
        }

        let Some(record) = record.as_object() else {
            errors.push(format!("{path} must be an object"));
            continue;
        };

        match record.get("requestHash").and_then(Value::as_str) {
            Some(hash) if is_sha256_urlsafe_hash(hash) => {}
            _ => errors.push(format!(
                "{path}.requestHash must be a SHA-256 URL-safe hash"
            )),
        }
        if record
            .get("operation")
            .and_then(Value::as_str)
            .is_none_or(str::is_empty)
        {
            errors.push(format!("{path}.operation must be a non-empty string"));
        }
        if !matches!(
            record.get("statusCode").and_then(Value::as_u64),
            Some(100..=599)
        ) {
            errors.push(format!("{path}.statusCode must be an HTTP status code"));
        }
        if !record.contains_key("responseBody") {
            errors.push(format!("{path}.responseBody must be present"));
        }

        let created_at = record.get("createdAt").and_then(Value::as_str);
        let expires_at = record.get("expiresAt").and_then(Value::as_str);
        let created = created_at.and_then(parse_rfc3339);
        let expires = expires_at.and_then(parse_rfc3339);
        if created.is_none() {
            errors.push(format!("{path}.createdAt must be an RFC3339 timestamp"));
        }
        if expires.is_none() {
            errors.push(format!("{path}.expiresAt must be an RFC3339 timestamp"));
        }
        if let (Some(created), Some(expires)) = (created, expires)
            && expires <= created
        {
            errors.push(format!("{path}.expiresAt must be after createdAt"));
        }
    }
}

fn is_sha256_urlsafe_hash(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn parse_rfc3339(value: &str) -> Option<OffsetDateTime> {
    OffsetDateTime::parse(value, &Rfc3339).ok()
}

fn find_account_mut<'a>(document: &'a mut Value, account_id: &str) -> Option<&'a mut Value> {
    document["accounts"]
        .as_array_mut()
        .expect("validated local ledger accounts should be an array")
        .iter_mut()
        .find(|account| account.get("id").and_then(Value::as_str) == Some(account_id))
}

fn find_movement_mut<'a>(document: &'a mut Value, movement_id: &str) -> Option<&'a mut Value> {
    document["movements"]
        .as_array_mut()
        .expect("validated local ledger movements should be an array")
        .iter_mut()
        .find(|movement| movement.get("id").and_then(Value::as_str) == Some(movement_id))
}

fn apply_account_patch(account: &mut Value, patch: &Value, now: &str) -> Result<(), LedgerError> {
    let Some(object) = patch.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "account patch must be a JSON object".to_string(),
        ]));
    };

    let mut errors = Vec::new();
    for key in object.keys() {
        if !matches!(
            key.as_str(),
            "displayName"
                | "institutionName"
                | "accountType"
                | "defaultCurrency"
                | "supportedCurrencies"
                | "includeInNetWorth"
                | "visibility"
                | "status"
                | "balanceMode"
                | "cashBalances"
                | "tags"
                | "note"
        ) {
            errors.push(format!("{key} is not an updatable account field"));
        }
    }

    if let Some(value) = object.get("displayName") {
        match value.as_str().filter(|value| !value.trim().is_empty()) {
            Some(value) => account["displayName"] = json!(value),
            None => errors.push("displayName must be a non-empty string".to_string()),
        }
    }

    if object.contains_key("institutionName") {
        patch_optional_string(account, object, "institutionName", &mut errors);
    }

    if let Some(value) = object.get("accountType") {
        match value.as_str() {
            Some(
                value @ ("bank" | "brokerage" | "exchange" | "wallet" | "platform_wallet"
                | "virtual_card" | "social_security" | "credit_card" | "loan" | "cash"
                | "other"),
            ) => account["accountType"] = json!(value),
            _ => errors.push("accountType must be a valid AccountType".to_string()),
        }
    }

    if let Some(value) = object.get("defaultCurrency") {
        match value.as_str().filter(|value| !value.trim().is_empty()) {
            Some(value) => account["defaultCurrency"] = json!(value),
            None => errors.push("defaultCurrency must be a non-empty string".to_string()),
        }
    }

    if let Some(value) = object.get("supportedCurrencies") {
        match string_array(value) {
            Some(items) if !items.is_empty() => account["supportedCurrencies"] = json!(items),
            _ => errors.push("supportedCurrencies must be a non-empty string array".to_string()),
        }
    }

    if let Some(value) = object.get("includeInNetWorth") {
        match value.as_bool() {
            Some(value) => account["includeInNetWorth"] = json!(value),
            None => errors.push("includeInNetWorth must be a boolean".to_string()),
        }
    }

    if let Some(value) = object.get("visibility") {
        match value.as_str() {
            Some(value @ ("normal" | "hidden_amount" | "archived")) => {
                account["visibility"] = json!(value)
            }
            _ => errors.push("visibility must be normal, hidden_amount, or archived".to_string()),
        }
    }

    if let Some(value) = object.get("status") {
        match value.as_str() {
            Some(value @ ("active" | "inactive" | "archived")) => account["status"] = json!(value),
            _ => errors.push("status must be active, inactive, or archived".to_string()),
        }
    }

    if let Some(value) = object.get("balanceMode") {
        match value.as_str() {
            Some(value @ ("cash_balance" | "holdings" | "liability" | "mixed")) => {
                account["balanceMode"] = json!(value)
            }
            _ => errors.push(
                "balanceMode must be cash_balance, holdings, liability, or mixed".to_string(),
            ),
        }
    }

    if let Some(value) = object.get("cashBalances")
        && let Some(balances) = normalized_opening_balances(Some(value), now, &mut errors)
    {
        account["cashBalances"] = json!(balances);
    }

    if let Some(value) = object.get("tags") {
        match string_array(value) {
            Some(items) => account["tags"] = json!(items),
            None => errors.push("tags must be a string array".to_string()),
        }
    }

    if object.contains_key("note") {
        patch_optional_string(account, object, "note", &mut errors);
    }

    if let (Some(default_currency), Some(supported_currencies)) = (
        account.get("defaultCurrency").and_then(Value::as_str),
        account.get("supportedCurrencies").and_then(string_array),
    ) && !supported_currencies
        .iter()
        .any(|currency| currency == default_currency)
    {
        errors.push("supportedCurrencies must include defaultCurrency".to_string());
    }

    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(errors));
    }

    account["updatedAt"] = json!(now);
    Ok(())
}

fn patch_optional_string(
    target: &mut Value,
    object: &serde_json::Map<String, Value>,
    key: &str,
    errors: &mut Vec<String>,
) {
    match object.get(key) {
        Some(Value::Null) => {
            if let Some(target) = target.as_object_mut() {
                target.remove(key);
            }
        }
        Some(Value::String(value)) if !value.trim().is_empty() => target[key] = json!(value),
        _ => errors.push(format!("{key} must be a non-empty string or null")),
    }
}

struct AccountSummary {
    base_currency: String,
    gross_assets: DecimalAmount,
    total_liabilities: DecimalAmount,
    fresh_count: u64,
    stale_count: u64,
    offline_cached_count: u64,
    unpriceable_count: u64,
    error_count: u64,
    account_anomaly_count: u64,
    latest_snapshot: Value,
    allocation_slices: Vec<Value>,
    primary_holdings: Vec<Value>,
}

impl AccountSummary {
    fn net_worth(&self) -> DecimalAmount {
        self.gross_assets - self.total_liabilities
    }
}

fn summarize_accounts(document: &Value, now: &str) -> io::Result<AccountSummary> {
    let base_currency = document
        .get("baseCurrency")
        .and_then(Value::as_str)
        .unwrap_or(DEFAULT_BASE_CURRENCY)
        .to_string();
    let accounts = document["accounts"]
        .as_array()
        .expect("validated local ledger accounts should be an array");

    let mut gross_assets = DecimalAmount::ZERO;
    let mut total_liabilities = DecimalAmount::ZERO;
    let mut fresh_count = 0_u64;
    let mut stale_count = 0_u64;
    let mut offline_cached_count = 0_u64;
    let mut unpriceable_count = 0_u64;
    let mut error_count = 0_u64;
    let mut account_anomaly_count = 0_u64;
    let mut included_account_count = 0_u64;
    let mut account_values = Vec::new();
    let mut allocation_by_category: BTreeMap<String, DecimalAmount> = BTreeMap::new();
    let mut quality = "exact";
    let projected_holdings = project_holdings_for_api(document);

    for account in accounts {
        if !account
            .get("includeInNetWorth")
            .and_then(Value::as_bool)
            .unwrap_or(true)
            || account.get("status").and_then(Value::as_str) == Some("archived")
        {
            continue;
        }

        included_account_count += 1;
        let is_liability = is_liability_account(account);
        let mut account_total = DecimalAmount::ZERO;
        let mut has_base_value = false;
        let mut account_quality = "exact";
        let account_id = account
            .get("id")
            .and_then(Value::as_str)
            .expect("validated account id should be a string");

        for balance in account
            .get("cashBalances")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let Some(balance_currency) = balance.get("currency").and_then(Value::as_str) else {
                unpriceable_count += 1;
                quality = combine_quality(quality, "incomplete");
                continue;
            };
            let amount = parse_decimal(
                balance
                    .get("amount")
                    .and_then(Value::as_str)
                    .expect("validated cash balance amount should be a string"),
            )?;
            let (amount, balance_quality) = if balance_currency == base_currency.as_str() {
                (
                    amount,
                    balance
                        .get("quality")
                        .and_then(Value::as_str)
                        .unwrap_or("exact"),
                )
            } else if let Some((converted, status)) =
                convert_amount(document, amount, balance_currency, &base_currency, now)
            {
                count_quote_status(
                    status,
                    &mut fresh_count,
                    &mut stale_count,
                    &mut offline_cached_count,
                    &mut unpriceable_count,
                    &mut error_count,
                );
                (converted, quality_from_quote_status(status))
            } else {
                unpriceable_count += 1;
                quality = combine_quality(quality, "incomplete");
                account_quality = combine_quality(account_quality, "incomplete");
                continue;
            };
            has_base_value = true;
            account_total += amount;
            account_quality = combine_quality(account_quality, balance_quality);
            quality = combine_quality(quality, balance_quality);
        }

        for holding in projected_holdings
            .iter()
            .filter(|holding| holding.get("accountId").and_then(Value::as_str) == Some(account_id))
        {
            match holding.get("quoteStatus").and_then(Value::as_str) {
                Some("fresh") => fresh_count += 1,
                Some("stale") => stale_count += 1,
                Some("offline_cached") => offline_cached_count += 1,
                Some("error") => error_count += 1,
                Some("unpriceable" | "incomplete") | None => unpriceable_count += 1,
                Some(_) => unpriceable_count += 1,
            }

            let Some(market_value) = holding.get("marketValue") else {
                quality = combine_quality(quality, "incomplete");
                account_quality = combine_quality(account_quality, "incomplete");
                continue;
            };
            if market_value.get("currency").and_then(Value::as_str) != Some(base_currency.as_str())
            {
                unpriceable_count += 1;
                quality = combine_quality(quality, "incomplete");
                account_quality = combine_quality(account_quality, "incomplete");
                continue;
            }

            let amount = parse_decimal(
                market_value
                    .get("amount")
                    .and_then(Value::as_str)
                    .expect("validated market value amount should be a string"),
            )?;
            has_base_value = true;
            account_total += amount;
            let holding_quality = market_value
                .get("quality")
                .and_then(Value::as_str)
                .unwrap_or("estimated");
            account_quality = combine_quality(account_quality, holding_quality);
            quality = combine_quality(quality, holding_quality);
        }

        if !has_base_value {
            continue;
        }

        account_values.push(json!({
            "accountId": account_id,
            "value": {
                "amount": money_amount(account_total),
                "currency": base_currency,
                "asOf": now,
                "quality": account_quality
            }
        }));

        if account_total.is_negative() {
            total_liabilities += absolute_decimal(account_total);
            if !is_liability {
                account_anomaly_count += 1;
                quality = combine_quality(quality, "anomaly");
            }
        } else if account_total > DecimalAmount::ZERO {
            gross_assets += account_total;
            let category = allocation_category(account).to_string();
            *allocation_by_category
                .entry(category)
                .or_insert(DecimalAmount::ZERO) += account_total;
        }
    }

    if account_anomaly_count > 0 {
        quality = combine_quality(quality, "anomaly");
    }

    let net_worth = gross_assets - total_liabilities;
    let latest_snapshot = if included_account_count == 0 {
        Value::Null
    } else {
        json!({
            "id": format!("snap_local_{}", now.replace([':', '-', '.'], "")),
            "snapshotAt": now,
            "baseCurrency": base_currency,
            "grossAssets": money(gross_assets, &base_currency),
            "totalLiabilities": money(total_liabilities, &base_currency),
            "netWorth": money(net_worth, &base_currency),
            "quality": quality,
            "quoteStatusSummary": {
                "freshCount": fresh_count,
                "staleCount": stale_count,
                "offlineCachedCount": offline_cached_count,
                "unpriceableCount": unpriceable_count,
                "errorCount": error_count
            },
            "accountValues": account_values
        })
    };

    let allocation_slices = allocation_by_category
        .into_iter()
        .filter(|(_, amount)| *amount > DecimalAmount::ZERO)
        .map(|(category, amount)| {
            let percent = if gross_assets > DecimalAmount::ZERO {
                percent_tenths(amount, gross_assets)
            } else {
                0
            };
            json!({
                "category": category,
                "percent": percent_amount(percent),
                "value": money(amount, &base_currency)
            })
        })
        .collect();

    Ok(AccountSummary {
        base_currency,
        gross_assets,
        total_liabilities,
        fresh_count,
        stale_count,
        offline_cached_count,
        unpriceable_count,
        error_count,
        account_anomaly_count,
        latest_snapshot,
        allocation_slices,
        primary_holdings: projected_holdings.into_iter().take(5).collect(),
    })
}

fn account_anomalies_for_document(document: &Value, now: &str) -> io::Result<Vec<Value>> {
    let accounts = document["accounts"]
        .as_array()
        .expect("validated local ledger accounts should be an array");
    let holdings = project_holdings_for_api(document);
    let mut anomalies = Vec::new();

    for account in accounts {
        if account.get("status").and_then(Value::as_str) == Some("archived") {
            continue;
        }
        let account_id = account
            .get("id")
            .and_then(Value::as_str)
            .expect("validated account id should be a string");
        let account_name = account
            .get("displayName")
            .and_then(Value::as_str)
            .unwrap_or(account_id);

        if !is_liability_account(account)
            && let Some(value) = projected_account_value_with_holdings(document, account)
            && let Some(amount) = value.get("amount").and_then(Value::as_str)
            && parse_decimal(amount)?.is_negative()
        {
            anomalies.push(json!({
                "id": format!("anom_{account_id}_negative_balance"),
                "accountId": account_id,
                "accountName": account_name,
                "kind": "negative_balance",
                "severity": "critical",
                "detail": format!("{account_name} 是资产账户，但余额为负数，请确认是否应改为负债或录入更正。"),
                "affectedValue": value,
                "action": "reconcile",
                "createdAt": now
            }));
        }

        let mut has_stale_quote = false;
        let mut has_unpriceable = false;
        for holding in holdings
            .iter()
            .filter(|holding| holding.get("accountId").and_then(Value::as_str) == Some(account_id))
        {
            match holding.get("quoteStatus").and_then(Value::as_str) {
                Some("stale" | "offline_cached") => has_stale_quote = true,
                Some("unpriceable" | "incomplete" | "error") | None => has_unpriceable = true,
                _ => {}
            }
        }

        if has_stale_quote {
            anomalies.push(json!({
                "id": format!("anom_{account_id}_quote_stale"),
                "accountId": account_id,
                "accountName": account_name,
                "kind": "quote_stale",
                "severity": "warning",
                "detail": format!("{account_name} 存在过期报价，当前估值使用缓存或旧价格。"),
                "action": "refresh",
                "createdAt": now
            }));
        }
        if has_unpriceable {
            anomalies.push(json!({
                "id": format!("anom_{account_id}_unpriceable"),
                "accountId": account_id,
                "accountName": account_name,
                "kind": "unpriceable",
                "severity": "warning",
                "detail": format!("{account_name} 存在无法估值的持仓或现金折算，净资产可能不完整。"),
                "action": "refresh",
                "createdAt": now
            }));
        }
    }

    Ok(anomalies)
}

fn sync_changes_for_document(document: &Value, since: Option<&str>) -> Result<Value, LedgerError> {
    let changes = document["syncChanges"]
        .as_array()
        .expect("validated local ledger syncChanges should be an array");
    let since = since.map(str::trim).filter(|value| !value.is_empty());
    let start = match since {
        Some(LOCAL_SYNC_GENESIS_CURSOR) => 0,
        Some(cursor) => changes
            .iter()
            .position(|change| change.get("id").and_then(Value::as_str) == Some(cursor))
            .map(|index| index + 1)
            .ok_or_else(|| {
                LedgerError::InvalidInput(vec![format!(
                    "since cursor must reference an existing sync change: {cursor}"
                )])
            })?,
        None => 0,
    };
    Ok(json!(
        changes.iter().skip(start).cloned().collect::<Vec<_>>()
    ))
}

fn sync_ack_change_ids_for_input(
    document: &Value,
    input: &Value,
) -> Result<Vec<String>, LedgerError> {
    let Some(object) = input.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "sync ack request must be a JSON object".to_string(),
        ]));
    };

    let changes = document["syncChanges"]
        .as_array()
        .expect("validated local ledger syncChanges should be an array");
    let known_change_ids = changes
        .iter()
        .filter_map(|change| change.get("id").and_then(Value::as_str))
        .map(str::to_string)
        .collect::<Vec<_>>();
    let mut ack_change_ids = Vec::new();
    let mut errors = Vec::new();
    let mut genesis_cursor_requested = false;

    if let Some(cursor_value) = object.get("cursor") {
        match cursor_value
            .as_str()
            .filter(|value| !value.trim().is_empty())
        {
            Some(cursor) => {
                if cursor == LOCAL_SYNC_GENESIS_CURSOR {
                    genesis_cursor_requested = true;
                } else {
                    match changes
                        .iter()
                        .position(|change| change.get("id").and_then(Value::as_str) == Some(cursor))
                    {
                        Some(index) => {
                            for change in changes.iter().take(index + 1) {
                                if let Some(change_id) = change.get("id").and_then(Value::as_str) {
                                    ack_change_ids.push(change_id.to_string());
                                }
                            }
                        }
                        None => errors.push(format!(
                            "cursor must reference an existing sync change: {cursor}"
                        )),
                    }
                }
            }
            None => errors.push("cursor must be a non-empty string when present".to_string()),
        }
    }

    for key in ["changeIds", "ackedChangeIds"] {
        if let Some(value) = object.get(key) {
            match string_array(value) {
                Some(change_ids) => ack_change_ids.extend(change_ids),
                None => errors.push(format!("{key} must be an array of non-empty strings")),
            }
        }
    }

    ack_change_ids.sort();
    ack_change_ids.dedup();

    if ack_change_ids.is_empty() && errors.is_empty() && !genesis_cursor_requested {
        errors.push("sync ack request must include cursor or changeIds".to_string());
    }
    for change_id in &ack_change_ids {
        if !known_change_ids
            .iter()
            .any(|known_id| known_id == change_id)
        {
            errors.push(format!(
                "changeIds contains unknown sync change id: {change_id}"
            ));
        }
    }

    if errors.is_empty() {
        Ok(ack_change_ids)
    } else {
        Err(LedgerError::InvalidInput(errors))
    }
}

fn sync_push_changes_for_input(
    input: &Value,
    authenticated_device_id: &str,
    now: &str,
) -> Result<(String, Vec<Value>), LedgerError> {
    let Some(object) = input.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "sync push request must be a JSON object".to_string(),
        ]));
    };
    if contains_fixture_marker(input) {
        return Err(LedgerError::InvalidInput(vec![
            "debug fixture, fixture, and demo payloads must not be synced".to_string(),
        ]));
    }

    let mut errors = Vec::new();
    let device_id = match object
        .get("deviceId")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
    {
        Some(value) => value.to_string(),
        None => {
            errors.push("deviceId must be a non-empty string".to_string());
            String::new()
        }
    };
    if device_id != authenticated_device_id {
        errors.push("deviceId must match the authenticated device".to_string());
    }
    if device_id == LOCAL_SYNC_DEVICE_ID {
        errors.push(format!(
            "deviceId must not use reserved id {LOCAL_SYNC_DEVICE_ID}"
        ));
    }
    let changes: &[Value] = match object.get("changes").and_then(Value::as_array) {
        Some(changes) => changes,
        None => {
            errors.push("changes must be an array".to_string());
            &[]
        }
    };

    let mut normalized_changes = Vec::new();
    for (index, change) in changes.iter().enumerate() {
        match sync_change_from_push_input(change, authenticated_device_id, now) {
            Ok(change) => normalized_changes.push(change),
            Err(mut change_errors) => {
                errors.extend(
                    change_errors
                        .drain(..)
                        .map(|error| format!("changes[{index}].{error}")),
                );
            }
        }
    }

    if errors.is_empty() {
        Ok((device_id, normalized_changes))
    } else {
        Err(LedgerError::InvalidInput(errors))
    }
}

fn sync_change_from_push_input(
    input: &Value,
    request_device_id: &str,
    now: &str,
) -> Result<Value, Vec<String>> {
    let Some(object) = input.as_object() else {
        return Err(vec!["must be a JSON object".to_string()]);
    };

    let mut errors = Vec::new();
    let source_change_id = required_sync_string(object, "id", &mut errors);
    let change_device_id = required_sync_string(object, "deviceId", &mut errors);
    let entity_type = required_sync_enum(object, "entityType", &["account"], &mut errors);
    let entity_id = required_sync_string(object, "entityId", &mut errors);
    let operation = required_sync_enum(object, "operation", &["create"], &mut errors);
    match object.get("baseVersion").and_then(Value::as_u64) {
        Some(0) => {}
        _ => errors.push("baseVersion must be 0 for account create".to_string()),
    }
    let created_at = required_sync_string(object, "createdAt", &mut errors);
    let payload = match object.get("payload") {
        Some(payload) => payload.clone(),
        None => {
            errors.push("payload is required".to_string());
            Value::Null
        }
    };

    if let Some(change_device_id) = change_device_id.as_deref()
        && change_device_id != request_device_id
    {
        errors.push("deviceId must match the request deviceId".to_string());
    }
    if created_at.as_deref().and_then(parse_rfc3339).is_none() {
        errors.push("createdAt must be an RFC3339 timestamp".to_string());
    }
    if let Some(entity_id) = entity_id.as_deref() {
        validate_inbound_account_payload(&payload, entity_id, &mut errors);
    }

    if !errors.is_empty() {
        return Err(errors);
    }

    let source_change_id = source_change_id.expect("validated source change id");
    Ok(json!({
        "id": Value::Null,
        "deviceId": request_device_id,
        "sourceDeviceId": request_device_id,
        "sourceChangeId": source_change_id,
        "entityType": entity_type.expect("validated entityType"),
        "entityId": entity_id.expect("validated entityId"),
        "operation": operation.expect("validated operation"),
        "payload": payload,
        "baseVersion": 0,
        "createdAt": created_at.expect("validated createdAt"),
        "receivedAt": now
    }))
}

fn validate_inbound_account_payload(payload: &Value, entity_id: &str, errors: &mut Vec<String>) {
    let Some(account) = payload.as_object() else {
        errors.push("payload must be a complete Account object".to_string());
        return;
    };

    if account.get("id").and_then(Value::as_str) != Some(entity_id) {
        errors.push("payload.id must equal entityId".to_string());
    }
    if !matches!(
        account.get("accountType").and_then(Value::as_str),
        Some(
            "bank"
                | "brokerage"
                | "exchange"
                | "wallet"
                | "platform_wallet"
                | "virtual_card"
                | "social_security"
                | "credit_card"
                | "loan"
                | "cash"
                | "other"
        )
    ) {
        errors.push("payload.accountType is invalid".to_string());
    }
    if !matches!(
        account.get("visibility").and_then(Value::as_str),
        Some("normal" | "hidden_amount" | "archived")
    ) {
        errors.push("payload.visibility is invalid".to_string());
    }
    if !matches!(
        account.get("status").and_then(Value::as_str),
        Some("active" | "inactive" | "archived")
    ) {
        errors.push("payload.status is invalid".to_string());
    }
    if !matches!(
        account.get("balanceMode").and_then(Value::as_str),
        Some("cash_balance" | "holdings" | "liability" | "mixed")
    ) {
        errors.push("payload.balanceMode is invalid".to_string());
    }
    for key in ["createdAt", "updatedAt"] {
        if account
            .get(key)
            .and_then(Value::as_str)
            .and_then(parse_rfc3339)
            .is_none()
        {
            errors.push(format!("payload.{key} must be an RFC3339 timestamp"));
        }
    }
    for key in ["institutionName", "note"] {
        if account.contains_key(key) && !account.get(key).is_some_and(Value::is_string) {
            errors.push(format!("payload.{key} must be a string"));
        }
    }
    if let Some(cash_balances) = account.get("cashBalances").and_then(Value::as_array) {
        for (index, balance) in cash_balances.iter().enumerate() {
            if balance
                .get("asOf")
                .and_then(Value::as_str)
                .and_then(parse_rfc3339)
                .is_none()
            {
                errors.push(format!(
                    "payload.cashBalances[{index}].asOf must be an RFC3339 timestamp"
                ));
            }
        }
    }

    let candidate = json!([payload.clone()]);
    let mut account_errors = Vec::new();
    validate_accounts(Some(&candidate), &mut account_errors);
    errors.extend(
        account_errors
            .into_iter()
            .map(|error| error.replacen("accounts[0]", "payload", 1)),
    );
}

fn account_create_sync_conflict(
    device_id: &str,
    source_change_id: &str,
    entity_id: &str,
    existing_account: &Value,
    incoming_change: &Value,
    now: &str,
) -> Value {
    let mut remote_change = incoming_change.clone();
    remote_change["id"] = json!(source_change_id);
    json!({
        "id": format!("account_exists:{device_id}:{source_change_id}"),
        "kind": "entity_already_exists",
        "entityType": "account",
        "entityId": entity_id,
        "localChange": {
            "id": format!("existing:{entity_id}"),
            "deviceId": LOCAL_SYNC_DEVICE_ID,
            "entityType": "account",
            "entityId": entity_id,
            "operation": "create",
            "payload": existing_account,
            "baseVersion": 0,
            "createdAt": now
        },
        "remoteChange": remote_change,
        "resolution": "manual"
    })
}

fn required_sync_string(
    object: &serde_json::Map<String, Value>,
    key: &str,
    errors: &mut Vec<String>,
) -> Option<String> {
    match object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
    {
        Some(value) => Some(value.to_string()),
        None => {
            errors.push(format!("{key} must be a non-empty string"));
            None
        }
    }
}

fn required_sync_enum(
    object: &serde_json::Map<String, Value>,
    key: &str,
    allowed: &[&str],
    errors: &mut Vec<String>,
) -> Option<String> {
    match object.get(key).and_then(Value::as_str) {
        Some(value) if allowed.contains(&value) => Some(value.to_string()),
        _ => {
            errors.push(format!("{key} must be one of {}", allowed.join(", ")));
            None
        }
    }
}

fn sync_source_change_exists(document: &Value, device_id: &str, source_change_id: &str) -> bool {
    document["syncChanges"]
        .as_array()
        .expect("validated local ledger syncChanges should be an array")
        .iter()
        .any(|change| {
            let change_device_id = change
                .get("sourceDeviceId")
                .or_else(|| change.get("deviceId"))
                .and_then(Value::as_str);
            let change_source_id = change
                .get("sourceChangeId")
                .or_else(|| change.get("id"))
                .and_then(Value::as_str);
            change_device_id == Some(device_id) && change_source_id == Some(source_change_id)
        })
}

fn append_sync_change(
    document: &mut Value,
    entity_type: &str,
    entity_id: &str,
    operation: &str,
    payload: &Value,
    now: &str,
) {
    let change_id = next_sync_change_id(document);
    let change = json!({
        "id": change_id,
        "deviceId": LOCAL_SYNC_DEVICE_ID,
        "entityType": entity_type,
        "entityId": entity_id,
        "operation": operation,
        "payload": payload,
        "createdAt": now
    });

    append_sync_log_change(document, change);
    let sync_state = document["syncState"]
        .as_object_mut()
        .expect("validated local ledger syncState should be an object");
    sync_state
        .entry("pendingChangeIds".to_string())
        .or_insert_with(|| json!([]))
        .as_array_mut()
        .expect("validated local ledger pendingChangeIds should be an array")
        .push(json!(change_id));
}

fn append_sync_log_change(document: &mut Value, change: Value) {
    let change_id = change
        .get("id")
        .and_then(Value::as_str)
        .expect("validated sync change id should be a string")
        .to_string();
    document["syncChanges"]
        .as_array_mut()
        .expect("validated local ledger syncChanges should be an array")
        .push(change);
    let sync_state = document["syncState"]
        .as_object_mut()
        .expect("validated local ledger syncState should be an object");
    sync_state.insert("cursor".to_string(), json!(change_id));
}

fn next_sync_change_id(document: &mut Value) -> String {
    let fallback_sequence = document["syncChanges"]
        .as_array()
        .and_then(|changes| {
            changes
                .iter()
                .filter_map(|change| change.get("id").and_then(Value::as_str))
                .filter_map(|change_id| {
                    change_id
                        .strip_prefix("local_change_")
                        .and_then(|suffix| suffix.parse::<u64>().ok())
                })
                .max()
        })
        .map(|sequence| sequence.saturating_add(1))
        .unwrap_or(1);
    let sync_state = document["syncState"]
        .as_object_mut()
        .expect("validated local ledger syncState should be an object");
    let stored_sequence = sync_state
        .get("nextChangeSequence")
        .and_then(Value::as_u64)
        .unwrap_or(fallback_sequence);
    let sequence = stored_sequence.max(fallback_sequence);
    sync_state.insert(
        "nextChangeSequence".to_string(),
        json!(sequence.saturating_add(1)),
    );
    format!("local_change_{sequence:06}")
}

fn account_from_create_input(
    input: &Value,
    account_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    let Some(object) = input.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "create account input must be a JSON object".to_string(),
        ]));
    };

    let mut errors = Vec::new();
    let display_name = required_string(object, "displayName", &mut errors);
    let institution_name = optional_string(object, "institutionName", &mut errors);
    let account_type = required_enum(
        object,
        "accountType",
        &[
            "bank",
            "brokerage",
            "exchange",
            "wallet",
            "platform_wallet",
            "virtual_card",
            "social_security",
            "credit_card",
            "loan",
            "cash",
            "other",
        ],
        &mut errors,
    );
    let default_currency = required_string(object, "defaultCurrency", &mut errors);
    let supported_currencies = required_string_array(object, "supportedCurrencies", &mut errors);
    let include_in_net_worth = required_bool(object, "includeInNetWorth", &mut errors);
    let balance_mode = required_enum(
        object,
        "balanceMode",
        &["cash_balance", "holdings", "liability", "mixed"],
        &mut errors,
    );
    let opening_balances =
        normalized_opening_balances(object.get("openingBalances"), now, &mut errors);

    if let (Some(default_currency), Some(supported_currencies)) =
        (default_currency.as_deref(), supported_currencies.as_ref())
        && !supported_currencies
            .iter()
            .any(|currency| currency == default_currency)
    {
        errors.push("supportedCurrencies must include defaultCurrency".to_string());
    }

    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(errors));
    }

    let mut account = json!({
        "id": account_id,
        "displayName": display_name.expect("validated displayName"),
        "accountType": account_type.expect("validated accountType"),
        "defaultCurrency": default_currency.expect("validated defaultCurrency"),
        "supportedCurrencies": supported_currencies.expect("validated supportedCurrencies"),
        "includeInNetWorth": include_in_net_worth.expect("validated includeInNetWorth"),
        "visibility": "normal",
        "status": "active",
        "balanceMode": balance_mode.expect("validated balanceMode"),
        "cashBalances": opening_balances.expect("validated openingBalances"),
        "tags": [],
        "createdAt": now,
        "updatedAt": now
    });

    if let Some(institution_name) = institution_name {
        account["institutionName"] = json!(institution_name);
    }

    Ok(account)
}

fn movement_from_create_input(
    document: &Value,
    input: &Value,
    movement_id: &str,
    atomic_group_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    let Some(object) = input.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "create movement draft input must be a JSON object".to_string(),
        ]));
    };

    let mut errors = Vec::new();
    let movement_type = required_enum(
        object,
        "type",
        &[
            "income",
            "expense",
            "transfer",
            "buy",
            "sell",
            "dividend",
            "interest",
            "fee",
            "adjustment",
            "loan_disbursement",
            "loan_repayment",
            "correction",
        ],
        &mut errors,
    );
    let occurred_at = required_string(object, "occurredAt", &mut errors);
    let title = required_string(object, "title", &mut errors);
    let description = optional_string(object, "description", &mut errors);
    let entries =
        normalized_movement_entries(document, object.get("entries"), movement_id, &mut errors);
    let tags = match object.get("tags") {
        Some(value) => match string_array(value) {
            Some(items) => items,
            None => {
                errors.push("tags must be a string array".to_string());
                Vec::new()
            }
        },
        None => Vec::new(),
    };
    let category_id = optional_string(object, "categoryId", &mut errors);
    let counterparty_id = optional_string(object, "counterpartyId", &mut errors);
    let amount_breakdown = normalized_amount_breakdown(object.get("amountBreakdown"), &mut errors);
    let settlement = normalized_settlement(object.get("settlement"), &mut errors);
    let transfer_meta = normalized_transfer_meta(object.get("transferMeta"), &mut errors);

    if movement_type.as_deref() == Some("transfer") {
        validate_simple_transfer(entries.as_deref(), transfer_meta.as_ref(), &mut errors);
    } else if transfer_meta.is_some() {
        errors.push("transferMeta is only valid for transfer movements".to_string());
    }
    if let (Some(movement_type), Some(entries)) = (movement_type.as_deref(), entries.as_deref()) {
        validate_movement_semantics(document, movement_type, entries, &mut errors);
    }

    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(errors));
    }

    let mut movement = json!({
        "id": movement_id,
        "atomicGroupId": atomic_group_id,
        "type": movement_type.expect("validated movement type"),
        "occurredAt": occurred_at.expect("validated occurredAt"),
        "recordedAt": now,
        "status": "draft",
        "title": title.expect("validated title"),
        "entries": entries.expect("validated entries"),
        "tags": tags,
        "settlement": settlement.expect("validated settlement"),
        "source": {
            "kind": "manual",
            "createdBy": "user"
        },
        "createdAt": now,
        "updatedAt": now
    });

    if let Some(description) = description {
        movement["description"] = json!(description);
    }
    if let Some(category_id) = category_id {
        movement["categoryId"] = json!(category_id);
    }
    if let Some(counterparty_id) = counterparty_id {
        movement["counterpartyId"] = json!(counterparty_id);
    }
    if let Some(amount_breakdown) = amount_breakdown {
        movement["amountBreakdown"] = amount_breakdown;
    }
    if let Some(transfer_meta) = transfer_meta {
        movement["transferMeta"] = transfer_meta;
    }

    Ok(movement)
}

fn correction_entry_from_diffs(
    target: &Value,
    diffs: &[Value],
    movement_id: &str,
) -> Result<Value, LedgerError> {
    if diffs.is_empty() {
        return Err(LedgerError::InvalidInput(vec![
            "proposedDiffs must contain one amount diff for correction MVP".to_string(),
        ]));
    }

    let mut amount_delta: Option<DecimalAmount> = None;
    for diff in diffs {
        let field_path = diff.get("fieldPath").and_then(Value::as_str).unwrap_or("");
        if !field_path.to_ascii_lowercase().contains("amount") {
            return Err(LedgerError::InvalidInput(vec![format!(
                "unsupported correction diff fieldPath: {field_path}"
            )]));
        }
        let old_value = diff_value_as_decimal(diff.get("oldValue")).ok_or_else(|| {
            LedgerError::InvalidInput(vec![format!(
                "unsupported correction oldValue for fieldPath: {field_path}"
            )])
        })?;
        let new_value = diff_value_as_decimal(diff.get("newValue")).ok_or_else(|| {
            LedgerError::InvalidInput(vec![format!(
                "unsupported correction newValue for fieldPath: {field_path}"
            )])
        })?;
        amount_delta = Some(amount_delta.unwrap_or(DecimalAmount::ZERO) + (new_value - old_value));
    }

    let delta = amount_delta.unwrap_or(DecimalAmount::ZERO);
    if delta == DecimalAmount::ZERO {
        return Err(LedgerError::InvalidInput(vec![
            "correction amount delta must not be zero".to_string(),
        ]));
    }

    let base_entry = target
        .get("entries")
        .and_then(Value::as_array)
        .and_then(|entries| {
            entries
                .iter()
                .find(|entry| entry.get("role").and_then(Value::as_str) == Some("source"))
                .or_else(|| entries.first())
        })
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec![
                "target movement must have at least one entry for correction".to_string(),
            ])
        })?;
    let account_id = base_entry
        .get("accountId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec![
                "target movement entry.accountId is required".to_string(),
            ])
        })?;
    let currency = base_entry
        .get("currency")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec![
                "target movement entry.currency is required".to_string(),
            ])
        })?;
    let direction = match (
        base_entry.get("direction").and_then(Value::as_str),
        delta > DecimalAmount::ZERO,
    ) {
        (Some("out"), true) | (Some("in"), false) => "out",
        (Some("out"), false) | (Some("in"), true) => "in",
        _ => {
            return Err(LedgerError::InvalidInput(vec![
                "target movement entry.direction must be in or out".to_string(),
            ]));
        }
    };

    let mut entry = json!({
        "id": format!("entry_{movement_id}_correction"),
        "accountId": account_id,
        "amount": money_amount(delta.abs()),
        "currency": currency,
        "direction": direction,
        "role": "adjustment"
    });
    if let Some(instrument_id) = base_entry.get("instrumentId").and_then(Value::as_str) {
        entry["instrumentId"] = json!(instrument_id);
    }
    Ok(entry)
}

fn correction_entries_for_replacement(
    document: &Value,
    target: &Value,
    replacement_input: &Value,
    movement_id: &str,
) -> Result<(Vec<Value>, Vec<Value>), LedgerError> {
    let Some(replacement_items) = replacement_input.as_array() else {
        return Err(LedgerError::InvalidInput(vec![
            "replacementEntries must be a non-empty array".to_string(),
        ]));
    };
    let sanitized_items = replacement_items
        .iter()
        .map(|item| {
            let mut item = item.clone();
            if let Some(object) = item.as_object_mut() {
                object.remove("id");
            }
            item
        })
        .collect::<Vec<_>>();
    let mut errors = Vec::new();
    let replacement_value = json!(sanitized_items);
    let replacement_entries =
        normalized_movement_entries(document, Some(&replacement_value), movement_id, &mut errors)
            .unwrap_or_default();
    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(
            errors
                .into_iter()
                .map(|error| {
                    error
                        .replacen("entries[", "replacementEntries[", 1)
                        .replacen("entries must", "replacementEntries must", 1)
                })
                .collect(),
        ));
    }

    let target_entries = target
        .get("entries")
        .and_then(Value::as_array)
        .filter(|entries| !entries.is_empty())
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec![
                "target movement must have entries for replacement correction".to_string(),
            ])
        })?;
    if movement_entry_effects(target_entries)? == movement_entry_effects(&replacement_entries)? {
        return Err(LedgerError::InvalidInput(vec![
            "replacementEntries must change the target movement ledger effect".to_string(),
        ]));
    }

    let mut correction_entries =
        Vec::with_capacity(target_entries.len() + replacement_entries.len());
    for (index, target_entry) in target_entries.iter().enumerate() {
        let account_id = target_entry
            .get("accountId")
            .and_then(Value::as_str)
            .expect("validated target entry accountId should exist");
        let amount = target_entry
            .get("amount")
            .and_then(Value::as_str)
            .expect("validated target entry amount should exist");
        let currency = target_entry
            .get("currency")
            .and_then(Value::as_str)
            .expect("validated target entry currency should exist");
        let direction = match target_entry.get("direction").and_then(Value::as_str) {
            Some("in") => "out",
            Some("out") => "in",
            _ => unreachable!("validated target entry direction should be in or out"),
        };
        let mut reversal = json!({
            "id": format!("entry_{movement_id}_reversal_{index}"),
            "accountId": account_id,
            "amount": amount,
            "currency": currency,
            "direction": direction,
            "role": "adjustment"
        });
        if let Some(instrument_id) = target_entry.get("instrumentId").and_then(Value::as_str) {
            reversal["instrumentId"] = json!(instrument_id);
        }
        correction_entries.push(reversal);
    }
    correction_entries.extend(replacement_entries.clone());
    Ok((correction_entries, replacement_entries))
}

fn movement_entry_effects(
    entries: &[Value],
) -> Result<BTreeMap<String, DecimalAmount>, LedgerError> {
    let mut effects = BTreeMap::new();
    for entry in entries {
        let account_id = entry
            .get("accountId")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                LedgerError::InvalidInput(vec!["entry.accountId is required".to_string()])
            })?;
        let currency = entry
            .get("currency")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                LedgerError::InvalidInput(vec!["entry.currency is required".to_string()])
            })?;
        let instrument_id = entry
            .get("instrumentId")
            .and_then(Value::as_str)
            .unwrap_or("");
        let amount =
            parse_decimal(entry.get("amount").and_then(Value::as_str).ok_or_else(|| {
                LedgerError::InvalidInput(vec!["entry.amount is required".to_string()])
            })?)
            .map_err(|error| LedgerError::InvalidInput(vec![error.to_string()]))?;
        let signed = match entry.get("direction").and_then(Value::as_str) {
            Some("in") => amount,
            Some("out") => -amount,
            _ => {
                return Err(LedgerError::InvalidInput(vec![
                    "entry.direction must be in or out".to_string(),
                ]));
            }
        };
        let key = format!("{account_id}\u{1f}{currency}\u{1f}{instrument_id}");
        *effects.entry(key).or_insert(DecimalAmount::ZERO) += signed;
    }
    effects.retain(|_, amount| *amount != DecimalAmount::ZERO);
    Ok(effects)
}

fn pending_correction_exists(document: &Value, target_movement_id: &str) -> bool {
    document["movements"]
        .as_array()
        .expect("validated movements should be an array")
        .iter()
        .any(|movement| {
            movement.get("type").and_then(Value::as_str) == Some("correction")
                && movement.get("status").and_then(Value::as_str) == Some("pending_review")
                && movement
                    .get("source")
                    .and_then(|source| source.get("sourceId"))
                    .and_then(Value::as_str)
                    == Some(target_movement_id)
        })
}

fn diff_value_as_decimal(value: Option<&Value>) -> Option<DecimalAmount> {
    match value? {
        Value::String(value) => parse_decimal(value).ok(),
        Value::Number(value) => parse_decimal(&value.to_string()).ok(),
        Value::Object(object) => object
            .get("amount")
            .and_then(Value::as_str)
            .and_then(|amount| parse_decimal(amount).ok()),
        _ => None,
    }
}

fn dca_plan_from_create_input(
    document: &Value,
    input: &Value,
    plan_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    let Some(object) = input.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "create DCA plan input must be a JSON object".to_string(),
        ]));
    };

    let mut errors = Vec::new();
    let display_name = required_string(object, "displayName", &mut errors);
    let target_instrument_id = required_string(object, "targetInstrumentId", &mut errors);
    let funding_account_id = optional_string(object, "fundingAccountId", &mut errors);
    if let Some(account_id) = funding_account_id.as_deref()
        && !active_account_exists(document, account_id)
    {
        errors.push("fundingAccountId does not exist or is archived".to_string());
    }
    let planned_amount =
        normalized_required_money(object.get("plannedAmount"), "plannedAmount", &mut errors);
    if let Some(amount) = planned_amount
        .as_ref()
        .and_then(|money| money.get("amount"))
        .and_then(Value::as_str)
        && !is_positive_decimal_string(amount)
    {
        errors.push("plannedAmount.amount must be a positive decimal string".to_string());
    }
    let frequency = required_enum(
        object,
        "frequency",
        &["weekly", "monthly", "custom"],
        &mut errors,
    );
    let next_due_date = required_string(object, "nextDueDate", &mut errors);
    if let Some(next_due_date) = next_due_date.as_deref()
        && Date::parse(next_due_date, &Iso8601::DATE).is_err()
    {
        errors.push("nextDueDate must be an ISO date".to_string());
    }
    let note = optional_string(object, "note", &mut errors);

    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(errors));
    }

    let mut plan = json!({
        "id": plan_id,
        "displayName": display_name.expect("validated displayName"),
        "targetInstrumentId": target_instrument_id.expect("validated targetInstrumentId"),
        "plannedAmount": planned_amount.expect("validated plannedAmount"),
        "frequency": frequency.expect("validated frequency"),
        "nextDueDate": next_due_date.expect("validated nextDueDate"),
        "reminderStatus": "active",
        "lastActionAt": Value::Null,
        "createdAt": now,
        "updatedAt": now
    });

    if let Some(funding_account_id) = funding_account_id {
        plan["fundingAccountId"] = json!(funding_account_id);
    }
    if let Some(note) = note {
        plan["note"] = json!(note);
    }

    Ok(plan)
}

fn apply_dca_plan_patch(plan: &mut Value, patch: &Value, now: &str) -> Result<(), LedgerError> {
    let Some(object) = patch.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "DCA plan patch must be a JSON object".to_string(),
        ]));
    };

    let mut errors = Vec::new();
    for key in object.keys() {
        if !matches!(
            key.as_str(),
            "displayName"
                | "targetInstrumentId"
                | "fundingAccountId"
                | "plannedAmount"
                | "frequency"
                | "nextDueDate"
                | "reminderStatus"
                | "note"
        ) {
            errors.push(format!("{key} is not an updatable DCA plan field"));
        }
    }

    if let Some(value) = object.get("displayName") {
        match value.as_str().filter(|value| !value.trim().is_empty()) {
            Some(value) => plan["displayName"] = json!(value),
            None => errors.push("displayName must be a non-empty string".to_string()),
        }
    }

    if let Some(value) = object.get("targetInstrumentId") {
        match value.as_str().filter(|value| !value.trim().is_empty()) {
            Some(value) => plan["targetInstrumentId"] = json!(value),
            None => errors.push("targetInstrumentId must be a non-empty string".to_string()),
        }
    }

    if object.contains_key("fundingAccountId") {
        patch_optional_string(plan, object, "fundingAccountId", &mut errors);
    }

    if let Some(value) = object.get("plannedAmount")
        && let Some(planned_amount) =
            normalized_required_money(Some(value), "plannedAmount", &mut errors)
    {
        if planned_amount
            .get("amount")
            .and_then(Value::as_str)
            .is_some_and(is_positive_decimal_string)
        {
            plan["plannedAmount"] = planned_amount;
        } else {
            errors.push("plannedAmount.amount must be a positive decimal string".to_string());
        }
    }

    if let Some(value) = object.get("frequency") {
        match value.as_str() {
            Some(value @ ("weekly" | "monthly" | "custom")) => plan["frequency"] = json!(value),
            _ => errors.push("frequency must be weekly, monthly, or custom".to_string()),
        }
    }

    if let Some(value) = object.get("nextDueDate") {
        match value
            .as_str()
            .filter(|value| !value.trim().is_empty() && Date::parse(value, &Iso8601::DATE).is_ok())
        {
            Some(value) => plan["nextDueDate"] = json!(value),
            None => errors.push("nextDueDate must be a non-empty ISO date".to_string()),
        }
    }

    if let Some(value) = object.get("reminderStatus") {
        match value.as_str() {
            Some(value @ ("active" | "snoozed" | "paused" | "completed")) => {
                plan["reminderStatus"] = json!(value)
            }
            _ => errors
                .push("reminderStatus must be active, snoozed, paused, or completed".to_string()),
        }
    }

    if object.contains_key("note") {
        patch_optional_string(plan, object, "note", &mut errors);
    }

    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(errors));
    }

    plan["updatedAt"] = json!(now);
    Ok(())
}

fn sync_open_dca_reminders_for_plan(document: &mut Value, plan_id: &str, plan: &Value, now: &str) {
    let display_name = plan.get("displayName").cloned();
    let planned_amount = plan.get("plannedAmount").cloned();
    let due_date = plan.get("nextDueDate").cloned();

    for reminder in document["dcaReminders"]
        .as_array_mut()
        .expect("validated local ledger dcaReminders should be an array")
        .iter_mut()
        .filter(|reminder| reminder.get("planId").and_then(Value::as_str) == Some(plan_id))
        .filter(|reminder| {
            matches!(
                reminder.get("status").and_then(Value::as_str),
                Some("due" | "overdue" | "snoozed")
            )
        })
    {
        if let Some(display_name) = display_name.clone() {
            reminder["displayName"] = display_name;
        }
        if let Some(planned_amount) = planned_amount.clone() {
            reminder["plannedAmount"] = planned_amount;
        }
        if let Some(due_date) = due_date.clone() {
            reminder["dueDate"] = due_date;
        }
        reminder["updatedAt"] = json!(now);
    }
}

fn is_dca_plan_active(document: &Value, plan_id: &str) -> bool {
    document["dcaPlans"]
        .as_array()
        .expect("validated local ledger dcaPlans should be an array")
        .iter()
        .find(|plan| plan.get("id").and_then(Value::as_str) == Some(plan_id))
        .is_some_and(|plan| plan.get("reminderStatus").and_then(Value::as_str) == Some("active"))
}

fn dca_reminder_from_plan(plan: &Value, reminder_id: &str) -> Value {
    json!({
        "id": reminder_id,
        "planId": plan
            .get("id")
            .and_then(Value::as_str)
            .expect("validated DCA plan id should be string"),
        "displayName": plan
            .get("displayName")
            .and_then(Value::as_str)
            .expect("validated DCA displayName should be string"),
        "plannedAmount": plan
            .get("plannedAmount")
            .expect("validated DCA plannedAmount should exist")
            .clone(),
        "dueDate": plan
            .get("nextDueDate")
            .and_then(Value::as_str)
            .expect("validated DCA nextDueDate should be string"),
        "status": "due"
    })
}

fn category_from_input(input: &Value, category_id: &str) -> Result<Value, LedgerError> {
    let Some(object) = input.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "category input must be a JSON object".to_string(),
        ]));
    };

    let mut errors = Vec::new();
    let display_name = required_string(object, "displayName", &mut errors);
    let kind = required_enum(
        object,
        "kind",
        &[
            "income",
            "expense",
            "transfer",
            "investment",
            "liability",
            "system",
        ],
        &mut errors,
    );
    let parent_id = optional_string(object, "parentId", &mut errors);
    let is_system = object
        .get("isSystem")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let ai_description = optional_string(object, "aiDescription", &mut errors);

    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(errors));
    }

    let mut category = json!({
        "id": category_id,
        "displayName": display_name.expect("validated category displayName"),
        "kind": kind.expect("validated category kind"),
        "isSystem": is_system
    });
    if let Some(parent_id) = parent_id {
        category["parentId"] = json!(parent_id);
    }
    if let Some(ai_description) = ai_description {
        category["aiDescription"] = json!(ai_description);
    }
    Ok(category)
}

fn instrument_from_input(
    input: &Value,
    fallback_instrument_id: &str,
) -> Result<Value, LedgerError> {
    let Some(object) = input.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "instrument input must be a JSON object".to_string(),
        ]));
    };

    let mut errors = Vec::new();
    let instrument_id =
        optional_string(object, "id", &mut errors).unwrap_or_else(|| fallback_instrument_id.into());
    let instrument_type = required_enum(object, "type", INSTRUMENT_TYPES, &mut errors);
    let display_name = required_string(object, "displayName", &mut errors);
    let quote_currency = required_string(object, "quoteCurrency", &mut errors);
    let symbol = optional_string(object, "symbol", &mut errors);
    let market = optional_string(object, "market", &mut errors);
    let source_ref = optional_string(object, "sourceRef", &mut errors);

    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(errors));
    }

    let mut instrument = json!({
        "id": instrument_id,
        "type": instrument_type.expect("validated instrument type"),
        "displayName": display_name.expect("validated instrument displayName"),
        "quoteCurrency": quote_currency.expect("validated instrument quoteCurrency")
    });
    if let Some(symbol) = symbol {
        instrument["symbol"] = json!(symbol);
    }
    if let Some(market) = market {
        instrument["market"] = json!(market);
    }
    if let Some(source_ref) = source_ref {
        instrument["sourceRef"] = json!(source_ref);
    }
    Ok(instrument)
}

fn apply_instrument_patch(instrument: &mut Value, patch: &Value) -> Result<(), LedgerError> {
    let Some(object) = patch.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "instrument patch must be a JSON object".to_string(),
        ]));
    };

    let mut errors = Vec::new();
    for key in object.keys() {
        if !matches!(
            key.as_str(),
            "type" | "symbol" | "displayName" | "quoteCurrency" | "market" | "sourceRef"
        ) {
            errors.push(format!("{key} is not an updatable instrument field"));
        }
    }
    if let Some(instrument_type) = object.get("type") {
        match instrument_type.as_str() {
            Some(value) if INSTRUMENT_TYPES.contains(&value) => instrument["type"] = json!(value),
            _ => errors.push("type must be a valid InstrumentType".to_string()),
        }
    }
    if let Some(display_name) = object.get("displayName") {
        match display_name
            .as_str()
            .filter(|value| !value.trim().is_empty())
        {
            Some(value) => instrument["displayName"] = json!(value),
            None => errors.push("displayName must be a non-empty string".to_string()),
        }
    }
    if let Some(quote_currency) = object.get("quoteCurrency") {
        match quote_currency
            .as_str()
            .filter(|value| !value.trim().is_empty())
        {
            Some(value) => instrument["quoteCurrency"] = json!(value),
            None => errors.push("quoteCurrency must be a non-empty string".to_string()),
        }
    }
    if object.contains_key("symbol") {
        patch_optional_string(instrument, object, "symbol", &mut errors);
    }
    if object.contains_key("market") {
        patch_optional_string(instrument, object, "market", &mut errors);
    }
    if object.contains_key("sourceRef") {
        patch_optional_string(instrument, object, "sourceRef", &mut errors);
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(LedgerError::InvalidInput(errors))
    }
}

fn apply_category_patch(category: &mut Value, patch: &Value) -> Result<(), LedgerError> {
    let Some(object) = patch.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "category patch must be a JSON object".to_string(),
        ]));
    };

    let mut errors = Vec::new();
    for key in object.keys() {
        if !matches!(
            key.as_str(),
            "displayName" | "parentId" | "kind" | "isSystem" | "aiDescription"
        ) {
            errors.push(format!("{key} is not an updatable category field"));
        }
    }
    if let Some(display_name) = object.get("displayName") {
        match display_name
            .as_str()
            .filter(|value| !value.trim().is_empty())
        {
            Some(value) => category["displayName"] = json!(value),
            None => errors.push("displayName must be a non-empty string".to_string()),
        }
    }
    if object.contains_key("parentId") {
        patch_optional_string(category, object, "parentId", &mut errors);
    }
    if let Some(kind) = object.get("kind") {
        match kind.as_str() {
            Some(
                value @ ("income" | "expense" | "transfer" | "investment" | "liability" | "system"),
            ) => category["kind"] = json!(value),
            _ => errors.push("kind must be a valid CategoryKind".to_string()),
        }
    }
    if let Some(is_system) = object.get("isSystem") {
        match is_system.as_bool() {
            Some(value) => category["isSystem"] = json!(value),
            None => errors.push("isSystem must be a boolean".to_string()),
        }
    }
    if object.contains_key("aiDescription") {
        patch_optional_string(category, object, "aiDescription", &mut errors);
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(LedgerError::InvalidInput(errors))
    }
}

fn counterparty_from_input(input: &Value, counterparty_id: &str) -> Result<Value, LedgerError> {
    let Some(object) = input.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "counterparty input must be a JSON object".to_string(),
        ]));
    };

    let mut errors = Vec::new();
    let display_name = required_string(object, "displayName", &mut errors);
    let aliases = match object.get("aliases") {
        Some(value) => match string_array(value) {
            Some(items) => items,
            None => {
                errors.push("aliases must be a string array".to_string());
                Vec::new()
            }
        },
        None => Vec::new(),
    };
    let normalized_name = optional_string(object, "normalizedName", &mut errors);
    let category_hint_id = optional_string(object, "categoryHintId", &mut errors);
    let is_user_merged = object
        .get("isUserMerged")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(errors));
    }

    let display_name = display_name.expect("validated counterparty displayName");
    let normalized_name =
        normalized_name.unwrap_or_else(|| normalize_name(&display_name, counterparty_id));
    let mut counterparty = json!({
        "id": counterparty_id,
        "displayName": display_name,
        "aliases": aliases,
        "normalizedName": normalized_name,
        "isUserMerged": is_user_merged
    });
    if let Some(category_hint_id) = category_hint_id {
        counterparty["categoryHintId"] = json!(category_hint_id);
    }
    Ok(counterparty)
}

fn apply_counterparty_patch(counterparty: &mut Value, patch: &Value) -> Result<(), LedgerError> {
    let Some(object) = patch.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "counterparty patch must be a JSON object".to_string(),
        ]));
    };

    let mut errors = Vec::new();
    for key in object.keys() {
        if !matches!(
            key.as_str(),
            "displayName" | "aliases" | "normalizedName" | "categoryHintId" | "isUserMerged"
        ) {
            errors.push(format!("{key} is not an updatable counterparty field"));
        }
    }
    if let Some(display_name) = object.get("displayName") {
        match display_name
            .as_str()
            .filter(|value| !value.trim().is_empty())
        {
            Some(value) => counterparty["displayName"] = json!(value),
            None => errors.push("displayName must be a non-empty string".to_string()),
        }
    }
    if let Some(aliases) = object.get("aliases") {
        match string_array(aliases) {
            Some(items) => counterparty["aliases"] = json!(items),
            None => errors.push("aliases must be a string array".to_string()),
        }
    }
    if object.contains_key("normalizedName") {
        patch_optional_string(counterparty, object, "normalizedName", &mut errors);
    }
    if object.contains_key("categoryHintId") {
        patch_optional_string(counterparty, object, "categoryHintId", &mut errors);
    }
    if let Some(is_user_merged) = object.get("isUserMerged") {
        match is_user_merged.as_bool() {
            Some(value) => counterparty["isUserMerged"] = json!(value),
            None => errors.push("isUserMerged must be a boolean".to_string()),
        }
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(LedgerError::InvalidInput(errors))
    }
}

fn counterparty_merge_group_from_input(
    document: &Value,
    input: &Value,
    atomic_group_id: &str,
) -> Result<Value, LedgerError> {
    let Some(object) = input.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "counterparty merge input must be a JSON object".to_string(),
        ]));
    };

    let mut errors = Vec::new();
    let source_ids = match object.get("sourceCounterpartyIds").and_then(string_array) {
        Some(items) if items.len() >= 2 => items,
        _ => {
            errors.push("sourceCounterpartyIds must contain at least two IDs".to_string());
            Vec::new()
        }
    };
    let target_display_name = required_string(object, "targetDisplayName", &mut errors);

    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(errors));
    }

    let source_counterparties = source_ids
        .iter()
        .map(|id| {
            find_counterparty(document, id)
                .cloned()
                .ok_or_else(|| LedgerError::NotFound(format!("counterparty does not exist: {id}")))
        })
        .collect::<Result<Vec<_>, _>>()?;
    let target_id = source_ids
        .first()
        .expect("validated source IDs should not be empty")
        .clone();
    let target_display_name = target_display_name.expect("validated targetDisplayName");
    let merged_aliases = merged_counterparty_aliases(&source_counterparties, &target_display_name);
    let category_hint_id = source_counterparties.iter().find_map(|counterparty| {
        counterparty
            .get("categoryHintId")
            .and_then(Value::as_str)
            .map(str::to_string)
    });
    let mut payload = json!({
        "id": target_id,
        "displayName": target_display_name,
        "aliases": merged_aliases,
        "normalizedName": normalize_name(&target_display_name, &target_id),
        "isUserMerged": true
    });
    if let Some(category_hint_id) = category_hint_id {
        payload["categoryHintId"] = json!(category_hint_id);
    }

    let source_names = source_counterparties
        .iter()
        .filter_map(|counterparty| counterparty.get("displayName").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join(" / ");

    Ok(json!({
        "id": atomic_group_id,
        "title": format!("合并对手方：{source_names}"),
        "operation": "merge",
        "targetType": "counterparty",
        "targetId": target_id,
        "proposedEntities": [
            {
                "id": target_id,
                "entityType": "counterparty",
                "payload": payload
            }
        ],
        "diffs": [
            {
                "fieldPath": "counterparty.displayName",
                "oldValue": source_names,
                "newValue": target_display_name,
                "severity": "important",
                "reason": "用户请求将多个对手方归并为同一主体"
            }
        ],
        "mergeMeta": {
            "sourceCounterpartyIds": source_ids,
            "targetCounterpartyId": target_id
        },
        "warnings": [
            {
                "code": "counterparty_merge_requires_confirmation",
                "message": "该操作只创建合并候选；确认前不会修改对手方目录或历史记录。",
                "severity": "info"
            }
        ],
        "status": "pending",
        "validation": {
            "isValid": true,
            "errors": []
        }
    }))
}

fn merged_counterparty_aliases(
    source_counterparties: &[Value],
    target_display_name: &str,
) -> Vec<String> {
    let mut aliases = Vec::new();
    for name in source_counterparties
        .iter()
        .filter_map(|counterparty| counterparty.get("displayName").and_then(Value::as_str))
        .chain(std::iter::once(target_display_name))
    {
        push_unique_alias(&mut aliases, name);
    }
    for alias in source_counterparties
        .iter()
        .flat_map(|counterparty| {
            counterparty
                .get("aliases")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
        })
        .filter_map(Value::as_str)
    {
        push_unique_alias(&mut aliases, alias);
    }
    aliases
}

fn push_unique_alias(aliases: &mut Vec<String>, alias: &str) {
    let alias = alias.trim();
    if alias.is_empty() {
        return;
    }
    if !aliases.iter().any(|item| item == alias) {
        aliases.push(alias.to_string());
    }
}

fn find_counterparty<'a>(document: &'a Value, counterparty_id: &str) -> Option<&'a Value> {
    document["counterparties"]
        .as_array()
        .expect("validated local ledger counterparties should be an array")
        .iter()
        .find(|counterparty| {
            counterparty.get("id").and_then(Value::as_str) == Some(counterparty_id)
        })
}

fn normalize_name(display_name: &str, fallback: &str) -> String {
    let normalized = display_name
        .trim()
        .to_ascii_lowercase()
        .chars()
        .filter(|ch| !ch.is_whitespace())
        .collect::<String>();
    if normalized.is_empty() {
        fallback.to_string()
    } else {
        normalized
    }
}

fn proposal_has_pending_group(proposal: &Value) -> bool {
    proposal
        .get("atomicGroups")
        .and_then(Value::as_array)
        .is_some_and(|groups| {
            groups.iter().any(|group| {
                matches!(
                    group.get("status").and_then(Value::as_str),
                    Some("pending" | "edited")
                )
            })
        })
}

fn project_account_for_api(account: &Value) -> Value {
    let mut projected = account.clone();

    if projected.get("value").is_none()
        && let Some(value) = projected_account_value(account)
    {
        projected["value"] = value;
    }

    projected
}

fn project_account_for_api_with_document(document: &Value, account: &Value) -> Value {
    let mut projected = account.clone();
    if let Some(value) = projected_account_value_with_holdings(document, account) {
        projected["value"] = value;
    } else if projected.get("value").is_none()
        && let Some(value) = projected_account_value(account)
    {
        projected["value"] = value;
    }
    projected
}

fn project_movement_for_api(movement: &Value) -> Value {
    let mut projected = movement.clone();

    if projected.get("displayAmount").is_none()
        && let Some(display_amount) = projected_movement_amount(movement)
    {
        projected["displayAmount"] = display_amount;
    }

    projected
}

fn project_holdings_for_api(document: &Value) -> Vec<Value> {
    let mut holdings = document["holdings"]
        .as_array()
        .expect("validated local ledger holdings should be an array")
        .iter()
        .filter(|holding| {
            parse_decimal(
                holding
                    .get("quantity")
                    .and_then(Value::as_str)
                    .unwrap_or("0"),
            )
            .is_ok_and(|quantity| quantity > DecimalAmount::ZERO)
        })
        .map(|holding| project_holding_for_api(document, holding))
        .collect::<Vec<_>>();

    holdings.sort_by(|left, right| {
        let left_value = holding_market_value_amount(left).unwrap_or(DecimalAmount::ZERO);
        let right_value = holding_market_value_amount(right).unwrap_or(DecimalAmount::ZERO);
        right_value.cmp(&left_value)
    });
    holdings
}

fn project_holding_for_api(document: &Value, holding: &Value) -> Value {
    let mut projected = holding.clone();
    if projected.get("instrument").is_none()
        && let Some(instrument_id) = holding.get("instrumentId").and_then(Value::as_str)
    {
        projected["instrument"] = instrument_for_api(document, instrument_id);
    }
    if let Some((market_value, status)) = quoted_holding_market_value(document, holding) {
        projected["marketValue"] = market_value;
        projected["quoteStatus"] = json!(status);
        if let Some(as_of) = projected["marketValue"].get("asOf").cloned() {
            projected["asOf"] = as_of;
        }
        if let Some(object) = projected.as_object_mut() {
            object.remove("unrealizedPnl");
            object.remove("unrealizedPnlRate");
        }
    }
    if projected.get("unrealizedPnl").is_none()
        && let (Some(market_value), Some(cost_basis)) = (
            projected
                .get("marketValue")
                .and_then(|value| value.get("amount"))
                .and_then(Value::as_str),
            projected
                .get("costBasisTotal")
                .and_then(|value| value.get("amount"))
                .and_then(Value::as_str),
        )
        && let (Ok(market_value), Ok(cost_basis)) =
            (parse_decimal(market_value), parse_decimal(cost_basis))
        && projected
            .get("marketValue")
            .and_then(|value| value.get("currency"))
            .and_then(Value::as_str)
            == projected
                .get("costBasisTotal")
                .and_then(|value| value.get("currency"))
                .and_then(Value::as_str)
    {
        let currency = projected
            .get("costBasisTotal")
            .and_then(|value| value.get("currency"))
            .and_then(Value::as_str)
            .unwrap_or(DEFAULT_BASE_CURRENCY);
        projected["unrealizedPnl"] = money(market_value - cost_basis, currency);
    }
    projected
}

fn project_quote_items(items: &[Value], now: &str) -> Vec<Value> {
    items
        .iter()
        .map(|item| project_quote_item(item, now))
        .collect()
}

fn project_quote_item(item: &Value, now: &str) -> Value {
    let mut projected = item.clone();
    projected["status"] = json!(effective_quote_status(item, now));
    projected
}

fn quote_from_refresh_input(input: &Value, now: &str) -> Result<Value, String> {
    let object = input
        .as_object()
        .ok_or_else(|| "quote must be a JSON object".to_string())?;
    let instrument_id = required_non_empty_field(object, "instrumentId")?;
    let price = required_positive_decimal_field(object, "price")?;
    let currency = required_non_empty_field(object, "currency")?;
    let as_of = optional_non_empty_field(object, "asOf")?.unwrap_or_else(|| now.to_string());
    if parse_rfc3339(&as_of).is_none() {
        return Err("quote.asOf must be an RFC3339 timestamp".to_string());
    }
    let source =
        optional_non_empty_field(object, "source")?.unwrap_or_else(|| "manual_refresh".to_string());
    let status = optional_status_field(object, "status")?.unwrap_or("fresh");
    let id = optional_non_empty_field(object, "id")?
        .unwrap_or_else(|| stable_quote_id("quote", &[&instrument_id, &as_of]));

    let mut quote = json!({
        "id": id,
        "instrumentId": instrument_id,
        "price": price,
        "currency": currency,
        "asOf": as_of,
        "source": source,
        "status": status
    });
    if let Some(source_url) = optional_non_empty_field(object, "sourceUrl")? {
        quote["sourceUrl"] = json!(source_url);
    }
    if let Some(expires_at) = optional_non_empty_field(object, "expiresAt")? {
        quote["expiresAt"] = json!(expires_at);
    }
    Ok(quote)
}

fn fx_rate_from_refresh_input(input: &Value, now: &str) -> Result<Value, String> {
    let object = input
        .as_object()
        .ok_or_else(|| "FX rate must be a JSON object".to_string())?;
    let base_currency = required_non_empty_field(object, "baseCurrency")?;
    let quote_currency = required_non_empty_field(object, "quoteCurrency")?;
    let rate = required_positive_decimal_field(object, "rate")?;
    let as_of = optional_non_empty_field(object, "asOf")?.unwrap_or_else(|| now.to_string());
    if parse_rfc3339(&as_of).is_none() {
        return Err("FX rate.asOf must be an RFC3339 timestamp".to_string());
    }
    let source =
        optional_non_empty_field(object, "source")?.unwrap_or_else(|| "manual_refresh".to_string());
    let status = optional_status_field(object, "status")?.unwrap_or("fresh");
    let id = optional_non_empty_field(object, "id")?
        .unwrap_or_else(|| stable_quote_id("fx", &[&base_currency, &quote_currency, &as_of]));

    let mut rate_item = json!({
        "id": id,
        "baseCurrency": base_currency,
        "quoteCurrency": quote_currency,
        "rate": rate,
        "asOf": as_of,
        "source": source,
        "status": status
    });
    if let Some(source_url) = optional_non_empty_field(object, "sourceUrl")? {
        rate_item["sourceUrl"] = json!(source_url);
    }
    if let Some(expires_at) = optional_non_empty_field(object, "expiresAt")? {
        rate_item["expiresAt"] = json!(expires_at);
    }
    Ok(rate_item)
}

fn upsert_quote(document: &mut Value, quote: Value) {
    let instrument_id = quote
        .get("instrumentId")
        .and_then(Value::as_str)
        .expect("validated quote instrumentId should be a string")
        .to_string();
    let quotes = document["quotes"]
        .as_array_mut()
        .expect("validated local ledger quotes should be an array");
    if let Some(existing) = quotes.iter_mut().find(|item| {
        item.get("instrumentId").and_then(Value::as_str) == Some(instrument_id.as_str())
    }) {
        *existing = quote;
    } else {
        quotes.push(quote);
    }
}

fn upsert_fx_rate(document: &mut Value, rate: Value) -> Result<(), String> {
    let rate_id = rate
        .get("id")
        .and_then(Value::as_str)
        .expect("validated FX rate id should be a string")
        .to_string();
    let rates = document["fxRates"]
        .as_array_mut()
        .expect("validated local ledger fxRates should be an array");
    if let Some(existing) = rates
        .iter_mut()
        .find(|item| item.get("id").and_then(Value::as_str) == Some(rate_id.as_str()))
    {
        for field in ["baseCurrency", "quoteCurrency", "asOf"] {
            if existing.get(field) != rate.get(field) {
                return Err(format!("FX rate id cannot change {field}: {rate_id}"));
            }
        }
        *existing = rate;
    } else {
        let base_currency = rate.get("baseCurrency");
        let quote_currency = rate.get("quoteCurrency");
        let as_of = rate.get("asOf");
        if rates.iter().any(|existing| {
            existing.get("baseCurrency") == base_currency
                && existing.get("quoteCurrency") == quote_currency
                && existing.get("asOf") == as_of
        }) {
            return Err(format!(
                "FX rate pair/asOf already exists with a different id: {rate_id}"
            ));
        }
        rates.push(rate);
    }
    Ok(())
}

fn quoted_holding_market_value(document: &Value, holding: &Value) -> Option<(Value, &'static str)> {
    let now = current_timestamp_for_projection();
    let instrument_id = holding.get("instrumentId").and_then(Value::as_str)?;
    let quantity = parse_decimal(holding.get("quantity")?.as_str()?).ok()?;
    let quote = latest_quote_for_instrument(document, instrument_id)?;
    let price = parse_decimal(quote.get("price")?.as_str()?).ok()?;
    let quote_currency = quote.get("currency")?.as_str()?;
    let quote_status = effective_quote_status(quote, &now);
    let base_currency = document
        .get("baseCurrency")
        .and_then(Value::as_str)
        .unwrap_or(DEFAULT_BASE_CURRENCY);
    let quote_value = multiply_decimal(quantity, price);
    let as_of = quote
        .get("asOf")
        .and_then(Value::as_str)
        .unwrap_or(now.as_str());

    let (base_value, fx_status) =
        convert_amount(document, quote_value, quote_currency, base_currency, &now)?;
    let status = combine_quote_status(quote_status, fx_status);
    Some((
        json!({
            "amount": money_amount(base_value),
            "currency": base_currency,
            "asOf": as_of,
            "quality": quality_from_quote_status(status)
        }),
        status,
    ))
}

fn latest_quote_for_instrument<'a>(document: &'a Value, instrument_id: &str) -> Option<&'a Value> {
    document["quotes"]
        .as_array()
        .expect("validated local ledger quotes should be an array")
        .iter()
        .rev()
        .find(|quote| quote.get("instrumentId").and_then(Value::as_str) == Some(instrument_id))
}

fn convert_amount(
    document: &Value,
    amount: DecimalAmount,
    from_currency: &str,
    to_currency: &str,
    now: &str,
) -> Option<(DecimalAmount, &'static str)> {
    if from_currency == to_currency {
        return Some((amount, "fresh"));
    }
    let (rate, status) = fx_rate_between(document, from_currency, to_currency, now)?;
    Some((multiply_decimal(amount, rate), status))
}

fn fx_rate_between(
    document: &Value,
    from_currency: &str,
    to_currency: &str,
    now: &str,
) -> Option<(DecimalAmount, &'static str)> {
    let (rate, inverted) = fx_rate_at_or_before(document, from_currency, to_currency, now)?;
    let parsed = parse_decimal(rate.get("rate")?.as_str()?).ok()?;
    let status = effective_quote_status(rate, now);
    if inverted {
        divide_decimal(DecimalAmount::ONE, parsed).map(|inverse| (inverse, status))
    } else {
        Some((parsed, status))
    }
}

fn fx_rate_at_or_before<'a>(
    document: &'a Value,
    from_currency: &str,
    to_currency: &str,
    at: &str,
) -> Option<(&'a Value, bool)> {
    let cutoff = parse_rfc3339(at)?;
    document["fxRates"]
        .as_array()
        .expect("validated local ledger fxRates should be an array")
        .iter()
        .filter_map(|rate| {
            let base = rate.get("baseCurrency").and_then(Value::as_str)?;
            let quote = rate.get("quoteCurrency").and_then(Value::as_str)?;
            let inverted = if base == from_currency && quote == to_currency {
                false
            } else if base == to_currency && quote == from_currency {
                true
            } else {
                return None;
            };
            let as_of = parse_rfc3339(rate.get("asOf")?.as_str()?)?;
            (as_of <= cutoff).then_some((as_of, rate, inverted))
        })
        .max_by_key(|(as_of, _, _)| *as_of)
        .map(|(_, rate, inverted)| (rate, inverted))
}

struct ExecutionFxConversion {
    amount: DecimalAmount,
    basis: Value,
}

fn convert_execution_amount(
    document: &Value,
    amount: DecimalAmount,
    from_currency: &str,
    to_currency: &str,
    occurred_at: &str,
) -> Option<ExecutionFxConversion> {
    if from_currency == to_currency {
        return Some(ExecutionFxConversion {
            amount,
            basis: Value::Null,
        });
    }
    let (source_rate, inverted) =
        fx_rate_at_or_before(document, from_currency, to_currency, occurred_at)?;
    if matches!(
        source_rate.get("status").and_then(Value::as_str),
        Some("incomplete" | "unpriceable" | "error")
    ) {
        return None;
    }
    let stored_rate = parse_decimal(source_rate.get("rate")?.as_str()?).ok()?;
    let applied_rate = if inverted {
        divide_decimal(DecimalAmount::ONE, stored_rate)?
    } else {
        stored_rate
    };
    let mut basis = json!({
        "baseCurrency": from_currency,
        "quoteCurrency": to_currency,
        "rate": applied_rate.decimal_string(),
        "asOf": source_rate.get("asOf")?.clone(),
        "sourceRateId": source_rate.get("id")?.clone(),
        "source": source_rate.get("source")?.clone(),
        "inverted": inverted
    });
    if let Some(source_url) = source_rate.get("sourceUrl") {
        basis["sourceUrl"] = source_url.clone();
    }
    Some(ExecutionFxConversion {
        amount: multiply_decimal(amount, applied_rate),
        basis,
    })
}

fn effective_quote_status(item: &Value, now: &str) -> &'static str {
    let status = match item.get("status").and_then(Value::as_str) {
        Some("fresh") | None => "fresh",
        Some("stale") => "stale",
        Some("offline_cached") => "offline_cached",
        Some("incomplete") => "incomplete",
        Some("unpriceable") => "unpriceable",
        Some("error") => "error",
        Some(_) => "error",
    };

    if status == "fresh" && is_expired(item.get("expiresAt").and_then(Value::as_str), now) {
        "stale"
    } else {
        status
    }
}

fn is_expired(expires_at: Option<&str>, now: &str) -> bool {
    let Some(expires_at) = expires_at else {
        return false;
    };
    let Ok(expires_at) = OffsetDateTime::parse(expires_at, &Rfc3339) else {
        return false;
    };
    let Ok(now) = OffsetDateTime::parse(now, &Rfc3339) else {
        return false;
    };
    expires_at < now
}

fn combine_quote_status(left: &'static str, right: &'static str) -> &'static str {
    fn rank(status: &str) -> u8 {
        match status {
            "fresh" => 0,
            "stale" => 1,
            "offline_cached" => 2,
            "incomplete" | "unpriceable" => 3,
            "error" => 4,
            _ => 4,
        }
    }
    if rank(right) > rank(left) {
        right
    } else {
        left
    }
}

fn quality_from_quote_status(status: &str) -> &'static str {
    match status {
        "fresh" => "exact",
        "stale" | "offline_cached" => "estimated",
        _ => "incomplete",
    }
}

fn count_quote_status(
    status: &str,
    fresh: &mut u64,
    stale: &mut u64,
    offline: &mut u64,
    unpriceable: &mut u64,
    error: &mut u64,
) {
    match status {
        "fresh" => *fresh += 1,
        "stale" => *stale += 1,
        "offline_cached" => *offline += 1,
        "error" => *error += 1,
        _ => *unpriceable += 1,
    }
}

fn required_non_empty_field(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<String, String> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .ok_or_else(|| format!("{key} must be a non-empty string"))
}

fn optional_non_empty_field(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Option<String>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value.to_string())),
        _ => Err(format!("{key} must be a non-empty string when present")),
    }
}

fn required_positive_decimal_field(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<String, String> {
    let value = required_non_empty_field(object, key)?;
    if is_positive_decimal_string(&value) {
        Ok(value)
    } else {
        Err(format!("{key} must be a positive decimal string"))
    }
}

fn optional_status_field(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Option<&'static str>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => match value.as_str() {
            "fresh" => Ok(Some("fresh")),
            "stale" => Ok(Some("stale")),
            "offline_cached" => Ok(Some("offline_cached")),
            "incomplete" => Ok(Some("incomplete")),
            "unpriceable" => Ok(Some("unpriceable")),
            "error" => Ok(Some("error")),
            _ => Err(format!("{key} must be a valid QuoteStatus")),
        },
        _ => Err(format!("{key} must be a valid QuoteStatus")),
    }
}

fn quote_refresh_error(
    target_type: &str,
    target_id: Option<&str>,
    message: &str,
    retryable: bool,
) -> Value {
    let mut error = json!({
        "targetType": target_type,
        "message": message,
        "retryable": retryable
    });
    if let Some(target_id) = target_id {
        error["targetId"] = json!(target_id);
    }
    error
}

fn fx_pair_target_id(input: &Value) -> Option<String> {
    let base = input.get("baseCurrency").and_then(Value::as_str)?;
    let quote = input.get("quoteCurrency").and_then(Value::as_str)?;
    Some(format!("{base}/{quote}"))
}

fn stable_quote_id(prefix: &str, parts: &[&str]) -> String {
    let mut id = prefix.to_string();
    for part in parts {
        id.push('_');
        id.push_str(&clean_identifier(part));
    }
    id
}

fn infer_yahoo_symbol_from_id(instrument_id: &str) -> Option<String> {
    let value = instrument_id.trim();
    if value.is_empty() || value.starts_with("inst_") || value.len() > 16 {
        return None;
    }
    value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-' | '='))
        .then(|| value.to_ascii_uppercase())
}

fn clean_identifier(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect()
}

fn current_timestamp_for_projection() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .expect("RFC3339 formatting should succeed")
}

fn instrument_for_api(document: &Value, instrument_id: &str) -> Value {
    document["instruments"]
        .as_array()
        .expect("validated local ledger instruments should be an array")
        .iter()
        .find(|instrument| instrument.get("id").and_then(Value::as_str) == Some(instrument_id))
        .cloned()
        .unwrap_or_else(|| {
            json!({
                "id": instrument_id,
                "type": "other",
                "displayName": instrument_id,
                "quoteCurrency": DEFAULT_BASE_CURRENCY
            })
        })
}

fn holding_market_value_amount(holding: &Value) -> Option<DecimalAmount> {
    parse_decimal(holding.get("marketValue")?.get("amount")?.as_str()?).ok()
}

fn recent_movements_from_document(document: &Value) -> Vec<Value> {
    document["movements"]
        .as_array()
        .expect("validated local ledger movements should be an array")
        .iter()
        .filter(|movement| movement.get("status").and_then(Value::as_str) != Some("cancelled"))
        .rev()
        .take(20)
        .map(project_movement_for_api)
        .collect()
}

fn latest_persisted_snapshot(document: &Value) -> Option<Value> {
    document["snapshots"]
        .as_array()
        .expect("validated local ledger snapshots should be an array")
        .last()
        .cloned()
}

fn projected_account_value(account: &Value) -> Option<Value> {
    let default_currency = account.get("defaultCurrency").and_then(Value::as_str);
    let balances = account.get("cashBalances")?.as_array()?;

    let balance = balances
        .iter()
        .find(|balance| balance.get("currency").and_then(Value::as_str) == default_currency)
        .or_else(|| balances.first())?;

    Some(json!({
        "amount": balance.get("amount")?.clone(),
        "currency": balance.get("currency")?.clone(),
        "asOf": balance.get("asOf")?.clone(),
        "quality": balance.get("quality")?.clone()
    }))
}

fn projected_account_value_with_holdings(document: &Value, account: &Value) -> Option<Value> {
    let currency = document
        .get("baseCurrency")
        .and_then(Value::as_str)
        .unwrap_or(DEFAULT_BASE_CURRENCY);
    let now = current_timestamp_for_projection();
    let account_id = account.get("id").and_then(Value::as_str)?;
    let mut total = DecimalAmount::ZERO;
    let mut has_value = false;
    let mut quality = "exact";

    for balance in account
        .get("cashBalances")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let balance_currency = balance.get("currency").and_then(Value::as_str)?;
        let amount = parse_decimal(balance.get("amount")?.as_str()?).ok()?;
        let (amount, balance_quality) = if balance_currency == currency {
            (
                amount,
                balance
                    .get("quality")
                    .and_then(Value::as_str)
                    .unwrap_or("exact"),
            )
        } else {
            let (converted, status) =
                convert_amount(document, amount, balance_currency, currency, &now)?;
            (converted, quality_from_quote_status(status))
        };
        total += amount;
        has_value = true;
        quality = combine_quality(quality, balance_quality);
    }

    for holding in project_holdings_for_api(document)
        .iter()
        .filter(|holding| holding.get("accountId").and_then(Value::as_str) == Some(account_id))
    {
        let Some(market_value) = holding.get("marketValue") else {
            quality = combine_quality(quality, "incomplete");
            continue;
        };
        if market_value.get("currency").and_then(Value::as_str) != Some(currency) {
            quality = combine_quality(quality, "incomplete");
            continue;
        }
        let amount = parse_decimal(market_value.get("amount")?.as_str()?).ok()?;
        total += amount;
        has_value = true;
        quality = combine_quality(
            quality,
            market_value
                .get("quality")
                .and_then(Value::as_str)
                .unwrap_or("estimated"),
        );
    }

    has_value.then(|| {
        json!({
            "amount": money_amount(total),
            "currency": currency,
            "asOf": now,
            "quality": quality
        })
    })
}

fn projected_movement_amount(movement: &Value) -> Option<Value> {
    if let Some(paid_amount) = movement
        .get("amountBreakdown")
        .and_then(|breakdown| breakdown.get("paidAmount"))
    {
        return Some(paid_amount.clone());
    }

    let entry = movement.get("entries")?.as_array()?.first()?;
    Some(json!({
        "amount": entry.get("amount")?.clone(),
        "currency": entry.get("currency")?.clone()
    }))
}

fn atomic_group_from_movement(movement: &Value, status: &str) -> Value {
    json!({
        "id": movement
            .get("atomicGroupId")
            .and_then(Value::as_str)
            .expect("validated atomicGroupId should be a string"),
        "title": movement
            .get("title")
            .and_then(Value::as_str)
            .expect("validated movement title should be a string"),
        "operation": "create",
        "targetType": "movement",
        "targetId": movement
            .get("id")
            .and_then(Value::as_str)
            .expect("validated movement id should be a string"),
        "proposedMovements": [project_movement_for_api(movement)],
        "warnings": [],
        "status": status,
        "validation": {
            "isValid": true,
            "errors": []
        }
    })
}

fn confirmed_status_for_movement(movement: &Value) -> &'static str {
    if movement
        .get("settlement")
        .and_then(|settlement| settlement.get("status"))
        .and_then(Value::as_str)
        == Some("in_transit")
    {
        "in_transit"
    } else {
        "confirmed"
    }
}

fn sync_operation_for_movement(movement: &Value) -> &'static str {
    if movement.get("type").and_then(Value::as_str) == Some("correction") {
        "correction"
    } else {
        "create"
    }
}

fn is_liability_account(account: &Value) -> bool {
    matches!(
        account.get("balanceMode").and_then(Value::as_str),
        Some("liability")
    ) || matches!(
        account.get("accountType").and_then(Value::as_str),
        Some("loan" | "credit_card")
    )
}

fn allocation_category(account: &Value) -> &'static str {
    match account.get("accountType").and_then(Value::as_str) {
        Some("brokerage") => "投资",
        Some("exchange") => "数字资产",
        Some(
            "bank" | "wallet" | "platform_wallet" | "virtual_card" | "social_security" | "cash",
        ) => "现金",
        _ => "其他",
    }
}

fn combine_quality(current: &str, next: &str) -> &'static str {
    let rank = |quality: &str| match quality {
        "exact" => 0,
        "estimated" => 1,
        "incomplete" | "unpriceable" => 2,
        "anomaly" => 3,
        _ => 2,
    };

    let quality = if rank(next) > rank(current) {
        next
    } else {
        current
    };

    match quality {
        "exact" => "exact",
        "estimated" => "estimated",
        "anomaly" => "anomaly",
        _ => "incomplete",
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct DecimalAmount(i128);

impl DecimalAmount {
    const SCALE: i128 = 100_000_000;
    const ZERO: Self = Self(0);
    const ONE: Self = Self(Self::SCALE);

    fn parse(value: &str) -> io::Result<Self> {
        let (negative, value) = match value.strip_prefix('-') {
            Some(value) => (true, value),
            None => (false, value.strip_prefix('+').unwrap_or(value)),
        };
        let mut parts = value.split('.');
        let integer = parts.next().unwrap_or_default();
        let fraction = parts.next().unwrap_or_default();

        if parts.next().is_some()
            || integer.is_empty()
            || !integer.chars().all(|c| c.is_ascii_digit())
            || !fraction.chars().all(|c| c.is_ascii_digit())
            || fraction.len() > 8
        {
            return Err(invalid_decimal(value));
        }

        let integer_units = integer.parse::<i128>().map_err(invalid_data)? * Self::SCALE;
        let fraction_units = if fraction.is_empty() {
            0
        } else {
            let padded = format!("{fraction:0<8}");
            padded.parse::<i128>().map_err(invalid_data)?
        };
        let units = integer_units + fraction_units;
        Ok(if negative { Self(-units) } else { Self(units) })
    }

    fn is_negative(self) -> bool {
        self.0 < 0
    }

    fn abs(self) -> Self {
        if self.is_negative() { -self } else { self }
    }

    fn money_string(self) -> String {
        let raw = signed_fixed_string(self.0, 8);
        let Some((integer, fraction)) = raw.split_once('.') else {
            return format!("{raw}.00");
        };
        let mut keep = fraction.len();
        while keep > 2 && fraction.as_bytes()[keep - 1] == b'0' {
            keep -= 1;
        }
        format!("{integer}.{}", &fraction[..keep])
    }

    fn decimal_string(self) -> String {
        let raw = signed_fixed_string(self.0, 8);
        if raw.contains('.') {
            raw.trim_end_matches('0').trim_end_matches('.').to_string()
        } else {
            raw
        }
    }
}

impl Add for DecimalAmount {
    type Output = Self;

    fn add(self, rhs: Self) -> Self::Output {
        Self(self.0 + rhs.0)
    }
}

impl AddAssign for DecimalAmount {
    fn add_assign(&mut self, rhs: Self) {
        self.0 += rhs.0;
    }
}

impl Sub for DecimalAmount {
    type Output = Self;

    fn sub(self, rhs: Self) -> Self::Output {
        Self(self.0 - rhs.0)
    }
}

impl Neg for DecimalAmount {
    type Output = Self;

    fn neg(self) -> Self::Output {
        Self(-self.0)
    }
}

fn parse_decimal(value: &str) -> io::Result<DecimalAmount> {
    DecimalAmount::parse(value)
}

fn multiply_decimal(left: DecimalAmount, right: DecimalAmount) -> DecimalAmount {
    DecimalAmount(round_div(left.0 * right.0, DecimalAmount::SCALE))
}

fn divide_decimal(left: DecimalAmount, right: DecimalAmount) -> Option<DecimalAmount> {
    (right.0 != 0).then(|| DecimalAmount(round_div(left.0 * DecimalAmount::SCALE, right.0)))
}

fn absolute_decimal(value: DecimalAmount) -> DecimalAmount {
    value.abs()
}

fn money(value: DecimalAmount, currency: &str) -> Value {
    json!({
        "amount": money_amount(value),
        "currency": currency
    })
}

fn money_amount(value: DecimalAmount) -> String {
    value.money_string()
}

fn percent_tenths(amount: DecimalAmount, total: DecimalAmount) -> i128 {
    round_div(amount.0 * 1000, total.0)
}

fn percent_amount(tenths: i128) -> String {
    signed_fixed_string(tenths, 1)
}

fn round_div(numerator: i128, denominator: i128) -> i128 {
    if denominator == 0 {
        return 0;
    }

    if numerator >= 0 {
        (numerator + denominator.abs() / 2) / denominator
    } else {
        (numerator - denominator.abs() / 2) / denominator
    }
}

fn signed_fixed_string(units: i128, scale_digits: u32) -> String {
    let scale = 10_i128.pow(scale_digits);
    let sign = if units < 0 { "-" } else { "" };
    let absolute = units.abs();
    let integer = absolute / scale;
    let fraction = absolute % scale;
    format!(
        "{sign}{integer}.{fraction:0width$}",
        width = scale_digits as usize
    )
}

fn invalid_decimal(value: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("decimal value is unsupported for local summary: {value}"),
    )
}

fn required_string(
    object: &serde_json::Map<String, Value>,
    key: &str,
    errors: &mut Vec<String>,
) -> Option<String> {
    match object.get(key).and_then(Value::as_str) {
        Some(value) if !value.trim().is_empty() => Some(value.to_string()),
        _ => {
            errors.push(format!("{key} must be a non-empty string"));
            None
        }
    }
}

fn subscription_from_create_input(
    document: &Value,
    input: &Value,
    subscription_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    let Some(object) = input.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "subscription input must be a JSON object".to_string(),
        ]));
    };
    let mut errors = Vec::new();
    let display_name = required_string(object, "displayName", &mut errors);
    let provider = required_string(object, "provider", &mut errors);
    let plan_name = optional_string(object, "planName", &mut errors);
    let payment_account_id = required_string(object, "paymentAccountId", &mut errors);
    let amount = normalized_subscription_amount(object.get("amount"), &mut errors);
    let billing_cycle = normalized_subscription_cycle(object.get("billingCycle"), &mut errors);
    let start_date =
        normalized_subscription_date(object.get("startDate"), "startDate", &mut errors);
    let next_charge_date = match object.get("nextChargeDate") {
        None => start_date,
        value => normalized_subscription_date(value, "nextChargeDate", &mut errors),
    };
    let duration = normalized_subscription_duration(object.get("duration"), &mut errors);
    let supplied_end_date = match object.get("endDate") {
        None | Some(Value::Null) => None,
        value => normalized_subscription_date(value, "endDate", &mut errors),
    };
    if duration.is_some() && supplied_end_date.is_some() {
        errors.push("duration and endDate are mutually exclusive".to_string());
    }
    let status = match object.get("status") {
        None => Some("active".to_string()),
        Some(Value::String(value)) if matches!(value.as_str(), "trial" | "active" | "paused") => {
            Some(value.clone())
        }
        _ => {
            errors.push("status must be trial, active, or paused on create".to_string());
            None
        }
    };
    let auto_renew = match object.get("autoRenew") {
        None => Some(true),
        Some(Value::Bool(value)) => Some(*value),
        _ => {
            errors.push("autoRenew must be a boolean".to_string());
            None
        }
    };
    let reminder_days_before = match object.get("reminderDaysBefore") {
        None => Some(3_u64),
        Some(value) => match value.as_u64() {
            Some(value @ 0..=365) => Some(value),
            _ => {
                errors.push("reminderDaysBefore must be an integer from 0 to 365".to_string());
                None
            }
        },
    };
    let note = optional_string(object, "note", &mut errors);

    if let (Some(account_id), Some(currency)) = (
        payment_account_id.as_deref(),
        amount
            .as_ref()
            .and_then(|money| money.get("currency"))
            .and_then(Value::as_str),
    ) {
        match subscription_payment_issue(document, account_id, currency) {
            Some(SubscriptionPaymentIssue::AccountUnavailable) => {
                errors.push("paymentAccountId does not exist or is archived".to_string());
            }
            Some(SubscriptionPaymentIssue::CurrencyUnsupported) => {
                errors.push("amount.currency must be supported by the payment account".to_string());
            }
            None => {}
        }
    }
    if let (Some(start), Some(next)) = (start_date, next_charge_date)
        && next < start
    {
        errors.push("nextChargeDate must be on or after startDate".to_string());
    }
    let computed_end_date = match (start_date, duration.as_ref()) {
        (Some(start), Some(duration)) => {
            subscription_duration_end_date(start, duration, &mut errors)
        }
        _ => supplied_end_date,
    };
    if let (Some(start), Some(end)) = (start_date, computed_end_date)
        && end < start
    {
        errors.push("endDate must be on or after startDate".to_string());
    }
    if let (Some(next), Some(end)) = (next_charge_date, computed_end_date)
        && next > end
    {
        errors.push("nextChargeDate must not be after endDate".to_string());
    }
    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(errors));
    }

    let mut subscription = json!({
        "id": subscription_id,
        "displayName": display_name.expect("validated displayName"),
        "provider": provider.expect("validated provider"),
        "amount": amount.expect("validated amount"),
        "paymentAccountId": payment_account_id.expect("validated paymentAccountId"),
        "billingCycle": billing_cycle.expect("validated billingCycle"),
        "billingAnchorDay": start_date.expect("validated startDate").day(),
        "startDate": start_date.expect("validated startDate").to_string(),
        "endDate": computed_end_date.map(|date| date.to_string()),
        "nextChargeDate": next_charge_date.expect("validated nextChargeDate").to_string(),
        "autoRenew": auto_renew.expect("validated autoRenew"),
        "reminderDaysBefore": reminder_days_before.expect("validated reminderDaysBefore"),
        "status": status.expect("validated status"),
        "createdAt": now,
        "updatedAt": now
    });
    if let Some(plan_name) = plan_name {
        subscription["planName"] = json!(plan_name);
    }
    if let Some(duration) = duration {
        subscription["duration"] = duration;
    }
    if let Some(note) = note {
        subscription["note"] = json!(note);
    }
    Ok(subscription)
}

fn validate_subscription_payment(
    document: &Value,
    subscription: &Value,
) -> Result<(), LedgerError> {
    let account_id = subscription
        .get("paymentAccountId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec![
                "paymentAccountId must be a non-empty string".to_string(),
            ])
        })?;
    let currency = subscription
        .get("amount")
        .and_then(|money| money.get("currency"))
        .and_then(Value::as_str)
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec![
                "amount.currency must be a non-empty string".to_string(),
            ])
        })?;
    match subscription_payment_issue(document, account_id, currency) {
        Some(SubscriptionPaymentIssue::AccountUnavailable) => Err(LedgerError::InvalidInput(vec![
            "paymentAccountId does not exist or is archived".to_string(),
        ])),
        Some(SubscriptionPaymentIssue::CurrencyUnsupported) => {
            Err(LedgerError::InvalidInput(vec![
                "amount.currency must be supported by the payment account".to_string(),
            ]))
        }
        None => Ok(()),
    }
}

fn apply_subscription_patch(
    subscription: &mut Value,
    patch: &Value,
    now: &str,
) -> Result<(), LedgerError> {
    let object = patch
        .as_object()
        .expect("subscription patch object validated before mutation");
    if object.is_empty() {
        return Err(LedgerError::InvalidInput(vec![
            "subscription patch must contain at least one field".to_string(),
        ]));
    }
    let allowed = [
        "displayName",
        "provider",
        "planName",
        "amount",
        "paymentAccountId",
        "billingCycle",
        "startDate",
        "duration",
        "endDate",
        "nextChargeDate",
        "autoRenew",
        "reminderDaysBefore",
        "status",
        "note",
    ];
    let unknown = object
        .keys()
        .filter(|key| !allowed.contains(&key.as_str()))
        .cloned()
        .collect::<Vec<_>>();
    if !unknown.is_empty() {
        return Err(LedgerError::InvalidInput(vec![format!(
            "unsupported subscription patch fields: {}",
            unknown.join(", ")
        )]));
    }
    if object.get("duration").is_some_and(|value| !value.is_null())
        && object.get("endDate").is_some_and(|value| !value.is_null())
    {
        return Err(LedgerError::InvalidInput(vec![
            "duration and endDate are mutually exclusive".to_string(),
        ]));
    }

    let mut candidate = subscription.clone();
    for key in ["displayName", "provider", "paymentAccountId"] {
        if let Some(value) = object.get(key) {
            candidate[key] = value.clone();
        }
    }
    for key in ["planName", "note"] {
        if let Some(value) = object.get(key) {
            if value.is_null() {
                candidate
                    .as_object_mut()
                    .expect("subscription should be an object")
                    .remove(key);
            } else {
                candidate[key] = value.clone();
            }
        }
    }
    for key in [
        "amount",
        "billingCycle",
        "startDate",
        "nextChargeDate",
        "autoRenew",
        "reminderDaysBefore",
    ] {
        if let Some(value) = object.get(key) {
            candidate[key] = value.clone();
        }
    }
    if object.contains_key("startDate") {
        let mut date_errors = Vec::new();
        if let Some(start) =
            normalized_subscription_date(candidate.get("startDate"), "startDate", &mut date_errors)
        {
            candidate["billingAnchorDay"] = json!(start.day());
        }
        if !date_errors.is_empty() {
            return Err(LedgerError::InvalidInput(date_errors));
        }
    }
    if let Some(value) = object.get("status") {
        if !matches!(value.as_str(), Some("trial" | "active" | "paused")) {
            return Err(LedgerError::InvalidInput(vec![
                "status patch must be trial, active, or paused; use cancel endpoint to cancel"
                    .to_string(),
            ]));
        }
        candidate["status"] = value.clone();
    }
    if let Some(value) = object.get("duration").filter(|value| !value.is_null()) {
        let mut errors = Vec::new();
        let duration = normalized_subscription_duration(Some(value), &mut errors);
        let start =
            normalized_subscription_date(candidate.get("startDate"), "startDate", &mut errors);
        let end = match (start, duration.as_ref()) {
            (Some(start), Some(duration)) => {
                subscription_duration_end_date(start, duration, &mut errors)
            }
            _ => None,
        };
        if !errors.is_empty() {
            return Err(LedgerError::InvalidInput(errors));
        }
        candidate["duration"] = duration.expect("validated duration");
        candidate["endDate"] = json!(end.expect("validated end date").to_string());
    } else if let Some(value) = object.get("endDate") {
        candidate
            .as_object_mut()
            .expect("subscription should be an object")
            .remove("duration");
        candidate["endDate"] = value.clone();
    } else if object.contains_key("duration") {
        candidate
            .as_object_mut()
            .expect("subscription should be an object")
            .remove("duration");
        candidate["endDate"] = Value::Null;
    } else if object.contains_key("startDate")
        && let Some(duration) = candidate.get("duration").cloned()
    {
        let mut errors = Vec::new();
        let start =
            normalized_subscription_date(candidate.get("startDate"), "startDate", &mut errors);
        let end =
            start.and_then(|start| subscription_duration_end_date(start, &duration, &mut errors));
        if !errors.is_empty() {
            return Err(LedgerError::InvalidInput(errors));
        }
        candidate["endDate"] = json!(end.expect("validated end date").to_string());
    }

    candidate["updatedAt"] = json!(now);
    let payment_id = candidate
        .get("paymentAccountId")
        .and_then(Value::as_str)
        .unwrap_or("missing");
    let fake_accounts = json!([{ "id": payment_id }]);
    let candidate_array = json!([candidate.clone()]);
    let mut errors = Vec::new();
    validate_subscriptions(
        Some(&candidate_array),
        Some(&fake_accounts),
        None,
        &mut errors,
    );
    if let (Some(next), Some(end)) = (
        candidate
            .get("nextChargeDate")
            .and_then(Value::as_str)
            .and_then(|value| Date::parse(value, &Iso8601::DATE).ok()),
        candidate
            .get("endDate")
            .and_then(Value::as_str)
            .and_then(|value| Date::parse(value, &Iso8601::DATE).ok()),
    ) && next > end
    {
        errors.push("nextChargeDate must not be after endDate".to_string());
    }
    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(errors));
    }
    *subscription = candidate;
    Ok(())
}

fn normalized_subscription_amount(
    value: Option<&Value>,
    errors: &mut Vec<String>,
) -> Option<Value> {
    let money = normalized_required_money(value, "amount", errors)?;
    if money
        .get("amount")
        .and_then(Value::as_str)
        .is_none_or(|amount| !is_positive_decimal_string(amount))
    {
        errors.push("amount.amount must be a positive decimal string".to_string());
        return None;
    }
    Some(money)
}

fn normalized_subscription_cycle(value: Option<&Value>, errors: &mut Vec<String>) -> Option<Value> {
    let Some(object) = value.and_then(Value::as_object) else {
        errors.push("billingCycle must be an object".to_string());
        return None;
    };
    let unit = match object.get("unit").and_then(Value::as_str) {
        Some(value @ ("day" | "week" | "month" | "year")) => Some(value),
        _ => {
            errors.push("billingCycle.unit must be day, week, month, or year".to_string());
            None
        }
    };
    let interval = match object.get("interval").and_then(Value::as_u64) {
        Some(value @ 1..=365) => Some(value),
        _ => {
            errors.push("billingCycle.interval must be an integer from 1 to 365".to_string());
            None
        }
    };
    match (unit, interval) {
        (Some(unit), Some(interval)) => Some(json!({"unit": unit, "interval": interval})),
        _ => None,
    }
}

fn normalized_subscription_duration(
    value: Option<&Value>,
    errors: &mut Vec<String>,
) -> Option<Value> {
    let value = value?;
    let Some(object) = value.as_object() else {
        errors.push("duration must be an object".to_string());
        return None;
    };
    let unit = match object.get("unit").and_then(Value::as_str) {
        Some(value @ ("day" | "month" | "year")) => Some(value),
        _ => {
            errors.push("duration.unit must be day, month, or year".to_string());
            None
        }
    };
    let count = match object.get("count").and_then(Value::as_u64) {
        Some(value @ 1..=1200) => Some(value),
        _ => {
            errors.push("duration.count must be an integer from 1 to 1200".to_string());
            None
        }
    };
    match (unit, count) {
        (Some(unit), Some(count)) => Some(json!({"unit": unit, "count": count})),
        _ => None,
    }
}

fn normalized_subscription_date(
    value: Option<&Value>,
    label: &str,
    errors: &mut Vec<String>,
) -> Option<Date> {
    match value.and_then(Value::as_str) {
        Some(value) => match Date::parse(value, &Iso8601::DATE) {
            Ok(date) => Some(date),
            Err(_) => {
                errors.push(format!("{label} must be an ISO date in YYYY-MM-DD format"));
                None
            }
        },
        None => {
            errors.push(format!("{label} is required"));
            None
        }
    }
}

fn subscription_duration_end_date(
    start: Date,
    duration: &Value,
    errors: &mut Vec<String>,
) -> Option<Date> {
    let unit = duration.get("unit").and_then(Value::as_str)?;
    let count = duration.get("count").and_then(Value::as_u64)?;
    let exclusive_end = advance_subscription_date(start, unit, count).or_else(|| {
        errors.push("duration exceeds supported calendar range".to_string());
        None
    })?;
    exclusive_end.checked_sub(Duration::days(1)).or_else(|| {
        errors.push("duration end date is out of range".to_string());
        None
    })
}

fn advance_subscription_date(date: Date, unit: &str, count: u64) -> Option<Date> {
    match unit {
        "day" => date.checked_add(Duration::days(i64::try_from(count).ok()?)),
        "week" => date.checked_add(Duration::weeks(i64::try_from(count).ok()?)),
        "month" => add_calendar_months(date, i32::try_from(count).ok()?),
        "year" => add_calendar_months(date, i32::try_from(count.checked_mul(12)?).ok()?),
        _ => None,
    }
}

fn advance_subscription_billing_date(
    date: Date,
    unit: &str,
    count: u64,
    anchor_day: u8,
) -> Option<Date> {
    match unit {
        "month" => add_calendar_months_with_anchor(date, i32::try_from(count).ok()?, anchor_day),
        "year" => add_calendar_months_with_anchor(
            date,
            i32::try_from(count.checked_mul(12)?).ok()?,
            anchor_day,
        ),
        _ => advance_subscription_date(date, unit, count),
    }
}

fn add_calendar_months(date: Date, months: i32) -> Option<Date> {
    add_calendar_months_with_anchor(date, months, date.day())
}

fn add_calendar_months_with_anchor(date: Date, months: i32, anchor_day: u8) -> Option<Date> {
    let month_index = date.year().checked_mul(12)? + i32::from(u8::from(date.month())) - 1;
    let next_index = month_index.checked_add(months)?;
    let year = next_index.div_euclid(12);
    let month_number = u8::try_from(next_index.rem_euclid(12) + 1).ok()?;
    let month = Month::try_from(month_number).ok()?;
    let day = anchor_day.min(month.length(year));
    Date::from_calendar_date(year, month, day).ok()
}

fn find_subscription_mut<'a>(
    document: &'a mut Value,
    subscription_id: &str,
) -> Option<&'a mut Value> {
    document["subscriptions"]
        .as_array_mut()
        .expect("validated local ledger subscriptions should be an array")
        .iter_mut()
        .find(|item| item.get("id").and_then(Value::as_str) == Some(subscription_id))
}

fn optional_string(
    object: &serde_json::Map<String, Value>,
    key: &str,
    errors: &mut Vec<String>,
) -> Option<String> {
    match object.get(key) {
        None | Some(Value::Null) => None,
        Some(Value::String(value)) if !value.trim().is_empty() => Some(value.to_string()),
        _ => {
            errors.push(format!("{key} must be a non-empty string when present"));
            None
        }
    }
}

fn required_bool(
    object: &serde_json::Map<String, Value>,
    key: &str,
    errors: &mut Vec<String>,
) -> Option<bool> {
    match object.get(key).and_then(Value::as_bool) {
        Some(value) => Some(value),
        None => {
            errors.push(format!("{key} must be a boolean"));
            None
        }
    }
}

fn required_enum(
    object: &serde_json::Map<String, Value>,
    key: &str,
    allowed: &[&str],
    errors: &mut Vec<String>,
) -> Option<String> {
    match object.get(key).and_then(Value::as_str) {
        Some(value) if allowed.contains(&value) => Some(value.to_string()),
        _ => {
            errors.push(format!("{key} must be one of {}", allowed.join(", ")));
            None
        }
    }
}

fn required_string_array(
    object: &serde_json::Map<String, Value>,
    key: &str,
    errors: &mut Vec<String>,
) -> Option<Vec<String>> {
    let Some(value) = object.get(key) else {
        errors.push(format!("{key} must be a non-empty string array"));
        return None;
    };

    match string_array(value) {
        Some(items) if !items.is_empty() => Some(items),
        _ => {
            errors.push(format!("{key} must be a non-empty string array"));
            None
        }
    }
}

fn normalized_opening_balances(
    value: Option<&Value>,
    now: &str,
    errors: &mut Vec<String>,
) -> Option<Vec<Value>> {
    let Some(value) = value else {
        return Some(Vec::new());
    };

    let Some(items) = value.as_array() else {
        errors.push("openingBalances must be an array when present".to_string());
        return None;
    };

    let mut balances = Vec::new();
    for (index, item) in items.iter().enumerate() {
        let Some(item) = item.as_object() else {
            errors.push(format!("openingBalances[{index}] must be an object"));
            continue;
        };

        let currency = required_string(item, "currency", errors);
        let amount = match item.get("amount").and_then(Value::as_str) {
            Some(amount) if is_decimal_string(amount) => Some(amount.to_string()),
            _ => {
                errors.push(format!(
                    "openingBalances[{index}].amount must be a decimal string"
                ));
                None
            }
        };

        let as_of = item
            .get("asOf")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .unwrap_or(now);

        let quality = item
            .get("quality")
            .and_then(Value::as_str)
            .unwrap_or("exact");

        if !matches!(
            quality,
            "exact" | "estimated" | "incomplete" | "unpriceable" | "anomaly"
        ) {
            errors.push(format!(
                "openingBalances[{index}].quality must be a valid ValueQuality"
            ));
        }

        if let (Some(currency), Some(amount)) = (currency, amount) {
            balances.push(json!({
                "currency": currency,
                "amount": amount,
                "asOf": as_of,
                "quality": quality
            }));
        }
    }

    Some(balances)
}

fn normalized_movement_entries(
    document: &Value,
    value: Option<&Value>,
    movement_id: &str,
    errors: &mut Vec<String>,
) -> Option<Vec<Value>> {
    let Some(value) = value else {
        errors.push("entries must be a non-empty array".to_string());
        return None;
    };

    let Some(items) = value.as_array() else {
        errors.push("entries must be a non-empty array".to_string());
        return None;
    };

    if items.is_empty() {
        errors.push("entries must be a non-empty array".to_string());
        return None;
    }

    let mut entries = Vec::new();
    for (index, item) in items.iter().enumerate() {
        let Some(item) = item.as_object() else {
            errors.push(format!("entries[{index}] must be an object"));
            continue;
        };

        let id = item
            .get("id")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| format!("entry_{movement_id}_{index}"));
        let account_id = required_string(item, "accountId", errors);
        if let Some(account_id) = account_id.as_deref()
            && !active_account_exists(document, account_id)
        {
            errors.push(format!(
                "entries[{index}].accountId does not exist or is archived"
            ));
        }

        let amount = match item.get("amount").and_then(Value::as_str) {
            Some(amount) if is_positive_decimal_string(amount) => Some(amount.to_string()),
            _ => {
                errors.push(format!(
                    "entries[{index}].amount must be a positive decimal string"
                ));
                None
            }
        };
        let currency = required_string(item, "currency", errors);
        let direction = match item.get("direction").and_then(Value::as_str) {
            Some(value @ ("in" | "out")) => Some(value.to_string()),
            _ => {
                errors.push(format!("entries[{index}].direction must be in or out"));
                None
            }
        };
        let role = match item.get("role").and_then(Value::as_str) {
            Some(
                value @ ("source" | "destination" | "fee" | "discount" | "pnl" | "tax"
                | "adjustment"),
            ) => Some(value.to_string()),
            _ => {
                errors.push(format!(
                    "entries[{index}].role must be a valid MovementEntryRole"
                ));
                None
            }
        };
        let instrument_id = optional_string(item, "instrumentId", errors);

        if let (Some(account_id), Some(currency)) = (account_id.as_deref(), currency.as_deref())
            && let Some(account) = active_account(document, account_id)
        {
            let supports_currency = account
                .get("supportedCurrencies")
                .and_then(Value::as_array)
                .is_some_and(|items| items.iter().any(|item| item.as_str() == Some(currency)));
            if !supports_currency {
                errors.push(format!(
                    "entries[{index}].currency is not supported by the account"
                ));
            }
            if instrument_id.is_some()
                && !matches!(
                    account.get("balanceMode").and_then(Value::as_str),
                    Some("holdings" | "mixed")
                )
            {
                errors.push(format!(
                    "entries[{index}] with instrumentId requires a holdings or mixed account"
                ));
            }
        }

        if let (Some(account_id), Some(amount), Some(currency), Some(direction), Some(role)) =
            (account_id, amount, currency, direction, role)
        {
            let mut entry = json!({
                "id": id,
                "accountId": account_id,
                "amount": amount,
                "currency": currency,
                "direction": direction,
                "role": role
            });

            if let Some(instrument_id) = instrument_id {
                entry["instrumentId"] = json!(instrument_id);
            }

            entries.push(entry);
        }
    }

    Some(entries)
}

fn normalized_settlement(value: Option<&Value>, errors: &mut Vec<String>) -> Option<Value> {
    let Some(value) = value else {
        return Some(json!({ "status": "settled" }));
    };

    let Some(object) = value.as_object() else {
        errors.push("settlement must be an object when present".to_string());
        return None;
    };

    let status = match object.get("status").and_then(Value::as_str) {
        Some(value @ ("settled" | "in_transit" | "failed" | "unknown")) => value,
        _ => {
            errors.push(
                "settlement.status must be settled, in_transit, failed, or unknown".to_string(),
            );
            "unknown"
        }
    };

    let mut settlement = json!({ "status": status });
    if let Some(expected_settle_at) = optional_string(object, "expectedSettleAt", errors) {
        settlement["expectedSettleAt"] = json!(expected_settle_at);
    }
    if let Some(settled_at) = optional_string(object, "settledAt", errors) {
        settlement["settledAt"] = json!(settled_at);
    }
    if let Some(delay) = object.get("expectedDelayHours") {
        match delay.as_u64() {
            Some(delay) => settlement["expectedDelayHours"] = json!(delay),
            None => errors
                .push("settlement.expectedDelayHours must be a non-negative integer".to_string()),
        }
    }

    Some(settlement)
}

fn normalized_amount_breakdown(value: Option<&Value>, errors: &mut Vec<String>) -> Option<Value> {
    let value = value?;

    let Some(object) = value.as_object() else {
        errors.push("amountBreakdown must be an object when present".to_string());
        return None;
    };

    if !object.contains_key("paidAmount") {
        errors.push("amountBreakdown.paidAmount is required".to_string());
    }
    let paid_amount = normalized_money(
        object.get("paidAmount"),
        "amountBreakdown.paidAmount",
        errors,
    );
    let mut breakdown = json!({});
    if let Some(gross_amount) = normalized_money(
        object.get("grossAmount"),
        "amountBreakdown.grossAmount",
        errors,
    ) {
        breakdown["grossAmount"] = gross_amount;
    }
    if let Some(savings_amount) = normalized_money(
        object.get("savingsAmount"),
        "amountBreakdown.savingsAmount",
        errors,
    ) {
        breakdown["savingsAmount"] = savings_amount;
    }
    if let Some(paid_amount) = paid_amount {
        breakdown["paidAmount"] = paid_amount;
    }
    if let Some(value) = object.get("benefitSource") {
        match value.as_str() {
            Some(
                value @ ("coupon" | "platform_subsidy" | "merchant_discount" | "free_order"
                | "other"),
            ) => {
                breakdown["benefitSource"] = json!(value);
            }
            _ => errors
                .push("amountBreakdown.benefitSource must be a valid benefit source".to_string()),
        }
    }

    Some(breakdown)
}

fn normalized_transfer_meta(value: Option<&Value>, errors: &mut Vec<String>) -> Option<Value> {
    let value = value?;

    let Some(object) = value.as_object() else {
        errors.push("transferMeta must be an object when present".to_string());
        return None;
    };

    let mut meta = json!({});
    for key in ["fromAccountId", "toAccountId", "note"] {
        if let Some(value) = optional_string(object, key, errors) {
            meta[key] = json!(value);
        }
    }
    for key in ["fromAmount", "toAmount", "feeAmount", "lossAmount"] {
        if let Some(value) =
            normalized_money(object.get(key), &format!("transferMeta.{key}"), errors)
        {
            meta[key] = value;
        }
    }
    if let Some(value) = object.get("fxRate") {
        match value.as_str() {
            Some(value) if is_positive_decimal_string(value) => meta["fxRate"] = json!(value),
            _ => errors.push("transferMeta.fxRate must be a positive decimal string".to_string()),
        }
    }

    Some(meta)
}

fn validate_simple_transfer(
    entries: Option<&[Value]>,
    transfer_meta: Option<&Value>,
    errors: &mut Vec<String>,
) {
    let Some(entries) = entries else {
        return;
    };
    if entries.len() != 2 {
        errors.push(
            "transfer entries must contain exactly one source and one destination".to_string(),
        );
        return;
    }

    let source_entries = entries
        .iter()
        .filter(|entry| entry.get("role").and_then(Value::as_str) == Some("source"))
        .collect::<Vec<_>>();
    let destination_entries = entries
        .iter()
        .filter(|entry| entry.get("role").and_then(Value::as_str) == Some("destination"))
        .collect::<Vec<_>>();
    if source_entries.len() != 1 || destination_entries.len() != 1 {
        errors.push(
            "transfer entries must contain exactly one source and one destination".to_string(),
        );
        return;
    }

    let source = source_entries[0];
    let destination = destination_entries[0];
    if source.get("direction").and_then(Value::as_str) != Some("out") {
        errors.push("transfer source entry.direction must be out".to_string());
    }
    if destination.get("direction").and_then(Value::as_str) != Some("in") {
        errors.push("transfer destination entry.direction must be in".to_string());
    }

    let source_account_id = source.get("accountId").and_then(Value::as_str);
    let destination_account_id = destination.get("accountId").and_then(Value::as_str);
    if source_account_id.is_some() && source_account_id == destination_account_id {
        errors.push("transfer source and destination accounts must differ".to_string());
    }

    let source_currency = source.get("currency").and_then(Value::as_str);
    let destination_currency = destination.get("currency").and_then(Value::as_str);
    if source_currency != destination_currency {
        errors.push("current server mode supports same-currency transfers only".to_string());
    }
    let source_amount = source
        .get("amount")
        .and_then(Value::as_str)
        .and_then(|value| parse_decimal(value).ok());
    let destination_amount = destination
        .get("amount")
        .and_then(Value::as_str)
        .and_then(|value| parse_decimal(value).ok());
    if source_amount != destination_amount {
        errors.push("same-currency transfer source and destination amounts must match".to_string());
    }

    let Some(meta) = transfer_meta.and_then(Value::as_object) else {
        return;
    };
    if meta.get("fromAccountId").and_then(Value::as_str) != source_account_id {
        errors.push("transferMeta.fromAccountId must match the source entry".to_string());
    }
    if meta.get("toAccountId").and_then(Value::as_str) != destination_account_id {
        errors.push("transferMeta.toAccountId must match the destination entry".to_string());
    }
    if let Some(from_amount) = meta.get("fromAmount")
        && !money_matches_entry(from_amount, source)
    {
        errors.push("transferMeta.fromAmount must match the source entry".to_string());
    }
    if let Some(to_amount) = meta.get("toAmount")
        && !money_matches_entry(to_amount, destination)
    {
        errors.push("transferMeta.toAmount must match the destination entry".to_string());
    }
    if ["feeAmount", "lossAmount", "fxRate"]
        .iter()
        .any(|key| meta.contains_key(*key))
    {
        errors.push(
            "current server mode does not support transfer fees, losses, or FX conversion"
                .to_string(),
        );
    }
}

fn validate_movement_semantics(
    document: &Value,
    movement_type: &str,
    entries: &[Value],
    errors: &mut Vec<String>,
) {
    match movement_type {
        "income" | "dividend" | "interest" => {
            validate_single_cash_movement(movement_type, entries, "in", "source", errors);
        }
        "expense" | "fee" => {
            validate_single_cash_movement(movement_type, entries, "out", "source", errors);
        }
        "adjustment" => {
            if entries.len() != 1 {
                errors.push("adjustment must contain exactly one cash entry".to_string());
                return;
            }
            let entry = &entries[0];
            if entry.get("instrumentId").is_some() {
                errors.push("adjustment entry must not contain instrumentId".to_string());
            }
            if entry.get("role").and_then(Value::as_str) != Some("adjustment") {
                errors.push("adjustment entry.role must be adjustment".to_string());
            }
        }
        "buy" => validate_buy_or_sell(entries, true, errors),
        "sell" => validate_buy_or_sell(entries, false, errors),
        "loan_disbursement" => validate_loan_movement(document, entries, true, errors),
        "loan_repayment" => validate_loan_movement(document, entries, false, errors),
        "correction" => errors.push(
            "correction drafts must be created through /v1/movements/corrections".to_string(),
        ),
        "transfer" => {}
        _ => errors.push(format!(
            "movement type is not supported by current server semantics: {movement_type}"
        )),
    }
}

fn validate_single_cash_movement(
    movement_type: &str,
    entries: &[Value],
    expected_direction: &str,
    expected_role: &str,
    errors: &mut Vec<String>,
) {
    if entries.len() != 1 {
        errors.push(format!(
            "{movement_type} must contain exactly one cash entry"
        ));
        return;
    }
    let entry = &entries[0];
    if entry.get("instrumentId").is_some() {
        errors.push(format!(
            "{movement_type} entry must not contain instrumentId"
        ));
    }
    if entry.get("direction").and_then(Value::as_str) != Some(expected_direction) {
        errors.push(format!(
            "{movement_type} entry.direction must be {expected_direction}"
        ));
    }
    if entry.get("role").and_then(Value::as_str) != Some(expected_role) {
        errors.push(format!(
            "{movement_type} entry.role must be {expected_role}"
        ));
    }
}

fn validate_buy_or_sell(entries: &[Value], is_buy: bool, errors: &mut Vec<String>) {
    let movement_type = if is_buy { "buy" } else { "sell" };
    if entries.len() < 2 {
        errors.push(format!(
            "{movement_type} must contain one principal cash leg and one holding leg"
        ));
        return;
    }
    let cash_role = if is_buy { "source" } else { "destination" };
    let holding_role = if is_buy { "destination" } else { "source" };
    let cash_direction = if is_buy { "out" } else { "in" };
    let holding_direction = if is_buy { "in" } else { "out" };
    let cash_legs = entries
        .iter()
        .filter(|entry| {
            entry.get("instrumentId").is_none()
                && entry.get("role").and_then(Value::as_str) == Some(cash_role)
        })
        .collect::<Vec<_>>();
    let holding_legs = entries
        .iter()
        .filter(|entry| {
            entry.get("instrumentId").is_some()
                && entry.get("role").and_then(Value::as_str) == Some(holding_role)
        })
        .collect::<Vec<_>>();
    if cash_legs.len() != 1 || holding_legs.len() != 1 {
        errors.push(format!(
            "{movement_type} must contain exactly one principal cash leg and one holding leg"
        ));
        return;
    }
    let cash = cash_legs[0];
    let holding = holding_legs[0];
    if cash.get("direction").and_then(Value::as_str) != Some(cash_direction) {
        errors.push(format!(
            "{movement_type} principal cash entry.direction must be {cash_direction}"
        ));
    }
    if holding.get("direction").and_then(Value::as_str) != Some(holding_direction) {
        errors.push(format!(
            "{movement_type} holding entry.direction must be {holding_direction}"
        ));
    }
    let cash_account = cash.get("accountId").and_then(Value::as_str);
    let cash_currency = cash.get("currency").and_then(Value::as_str);
    let mut fee_total = DecimalAmount::ZERO;
    for entry in entries {
        if std::ptr::eq(entry, cash) || std::ptr::eq(entry, holding) {
            continue;
        }
        if !matches!(
            entry.get("role").and_then(Value::as_str),
            Some("fee" | "tax")
        ) {
            errors.push(format!(
                "{movement_type} additional entries must use fee or tax role"
            ));
            continue;
        }
        if entry.get("instrumentId").is_some() {
            errors.push(format!(
                "{movement_type} fee/tax entries must be cash entries without instrumentId"
            ));
        }
        if entry.get("direction").and_then(Value::as_str) != Some("out") {
            errors.push(format!(
                "{movement_type} fee/tax entry.direction must be out"
            ));
        }
        if entry.get("accountId").and_then(Value::as_str) != cash_account
            || entry.get("currency").and_then(Value::as_str) != cash_currency
        {
            errors.push(format!(
                "{movement_type} fee/tax entries must use the principal cash account and currency"
            ));
        }
        if let Some(amount) = entry
            .get("amount")
            .and_then(Value::as_str)
            .and_then(|amount| parse_decimal(amount).ok())
        {
            fee_total += amount;
        }
    }
    if !is_buy
        && let Some(proceeds) = cash
            .get("amount")
            .and_then(Value::as_str)
            .and_then(|amount| parse_decimal(amount).ok())
        && fee_total > proceeds
    {
        errors.push("sell fee/tax total must not exceed gross proceeds".to_string());
    }
}

fn validate_loan_movement(
    document: &Value,
    entries: &[Value],
    is_disbursement: bool,
    errors: &mut Vec<String>,
) {
    let movement_type = if is_disbursement {
        "loan_disbursement"
    } else {
        "loan_repayment"
    };
    if entries.len() != 2 {
        errors.push(format!(
            "{movement_type} must contain exactly one source and one destination"
        ));
        return;
    }
    let source_entries = entries
        .iter()
        .filter(|entry| entry.get("role").and_then(Value::as_str) == Some("source"))
        .collect::<Vec<_>>();
    let destination_entries = entries
        .iter()
        .filter(|entry| entry.get("role").and_then(Value::as_str) == Some("destination"))
        .collect::<Vec<_>>();
    if source_entries.len() != 1 || destination_entries.len() != 1 {
        errors.push(format!(
            "{movement_type} must contain exactly one source and one destination"
        ));
        return;
    }

    let source = source_entries[0];
    let destination = destination_entries[0];
    if source.get("direction").and_then(Value::as_str) != Some("out") {
        errors.push(format!(
            "{movement_type} source entry.direction must be out"
        ));
    }
    if destination.get("direction").and_then(Value::as_str) != Some("in") {
        errors.push(format!(
            "{movement_type} destination entry.direction must be in"
        ));
    }
    if source.get("instrumentId").is_some() || destination.get("instrumentId").is_some() {
        errors.push(format!(
            "{movement_type} entries must be cash/liability entries without instrumentId"
        ));
    }
    let source_account_id = source.get("accountId").and_then(Value::as_str);
    let destination_account_id = destination.get("accountId").and_then(Value::as_str);
    if source_account_id.is_some() && source_account_id == destination_account_id {
        errors.push(format!(
            "{movement_type} source and destination accounts must differ"
        ));
    }
    let source_is_liability = source_account_id
        .and_then(|account_id| active_account(document, account_id))
        .is_some_and(is_liability_account);
    let destination_is_liability = destination_account_id
        .and_then(|account_id| active_account(document, account_id))
        .is_some_and(is_liability_account);
    if is_disbursement {
        if !source_is_liability || destination_is_liability {
            errors.push(
                "loan_disbursement must flow out of a liability account into a non-liability account"
                    .to_string(),
            );
        }
    } else if source_is_liability || !destination_is_liability {
        errors.push(
            "loan_repayment must flow out of a non-liability account into a liability account"
                .to_string(),
        );
    }
    if source.get("currency").and_then(Value::as_str)
        != destination.get("currency").and_then(Value::as_str)
    {
        errors.push(format!(
            "current server mode supports same-currency {movement_type} movements only"
        ));
    }
    let source_amount = source
        .get("amount")
        .and_then(Value::as_str)
        .and_then(|value| parse_decimal(value).ok());
    let destination_amount = destination
        .get("amount")
        .and_then(Value::as_str)
        .and_then(|value| parse_decimal(value).ok());
    if source_amount != destination_amount {
        errors.push(format!(
            "{movement_type} source and destination amounts must match"
        ));
    }
}

fn money_matches_entry(money: &Value, entry: &Value) -> bool {
    let money_amount = money
        .get("amount")
        .and_then(Value::as_str)
        .and_then(|value| parse_decimal(value).ok());
    let entry_amount = entry
        .get("amount")
        .and_then(Value::as_str)
        .and_then(|value| parse_decimal(value).ok());
    money_amount == entry_amount
        && money.get("currency").and_then(Value::as_str)
            == entry.get("currency").and_then(Value::as_str)
}

fn normalized_money(value: Option<&Value>, label: &str, errors: &mut Vec<String>) -> Option<Value> {
    let value = value?;

    let Some(object) = value.as_object() else {
        errors.push(format!("{label} must be an object"));
        return None;
    };

    let amount = match object.get("amount").and_then(Value::as_str) {
        Some(amount) if is_decimal_string(amount) => Some(amount.to_string()),
        _ => {
            errors.push(format!("{label}.amount must be a decimal string"));
            None
        }
    };
    let currency = required_string(object, "currency", errors);

    match (amount, currency) {
        (Some(amount), Some(currency)) => Some(json!({
            "amount": amount,
            "currency": currency
        })),
        _ => None,
    }
}

fn normalized_required_money(
    value: Option<&Value>,
    label: &str,
    errors: &mut Vec<String>,
) -> Option<Value> {
    if value.is_none() {
        errors.push(format!("{label} is required"));
    }
    normalized_money(value, label, errors)
}

fn active_account_exists(document: &Value, account_id: &str) -> bool {
    active_account(document, account_id).is_some()
}

fn active_account<'a>(document: &'a Value, account_id: &str) -> Option<&'a Value> {
    document["accounts"]
        .as_array()
        .expect("validated local ledger accounts should be an array")
        .iter()
        .find(|account| {
            account.get("id").and_then(Value::as_str) == Some(account_id)
                && account.get("status").and_then(Value::as_str) != Some("archived")
        })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SubscriptionPaymentIssue {
    AccountUnavailable,
    CurrencyUnsupported,
}

fn subscription_payment_issue(
    document: &Value,
    account_id: &str,
    currency: &str,
) -> Option<SubscriptionPaymentIssue> {
    let Some(account) = active_account(document, account_id) else {
        return Some(SubscriptionPaymentIssue::AccountUnavailable);
    };
    let supports_currency = account
        .get("supportedCurrencies")
        .and_then(Value::as_array)
        .is_some_and(|items| items.iter().any(|item| item.as_str() == Some(currency)));
    (!supports_currency).then_some(SubscriptionPaymentIssue::CurrencyUnsupported)
}

fn apply_movement_effect(
    document: &mut Value,
    movement: &Value,
    now: &str,
) -> Result<(), LedgerError> {
    let entries = movement
        .get("entries")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec!["movement.entries is missing".to_string()])
        })?;
    match movement.get("type").and_then(Value::as_str) {
        Some("buy") => apply_buy_or_sell_movement(document, movement, entries, true, now),
        Some("sell") => apply_buy_or_sell_movement(document, movement, entries, false, now),
        _ => apply_movement_entries(document, entries, now),
    }
}

fn apply_movement_entries(
    document: &mut Value,
    entries: &[Value],
    now: &str,
) -> Result<(), LedgerError> {
    for entry in entries {
        let account_id = entry
            .get("accountId")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                LedgerError::InvalidInput(vec!["entry.accountId is missing".to_string()])
            })?;
        let currency = entry
            .get("currency")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                LedgerError::InvalidInput(vec!["entry.currency is missing".to_string()])
            })?;
        let amount =
            parse_decimal(entry.get("amount").and_then(Value::as_str).ok_or_else(|| {
                LedgerError::InvalidInput(vec!["entry.amount is missing".to_string()])
            })?)
            .map_err(|error| LedgerError::InvalidInput(vec![error.to_string()]))?;
        let delta = match entry.get("direction").and_then(Value::as_str) {
            Some("in") => amount,
            Some("out") => -amount,
            _ => {
                return Err(LedgerError::InvalidInput(vec![
                    "entry.direction must be in or out".to_string(),
                ]));
            }
        };

        if let Some(instrument_id) = entry.get("instrumentId").and_then(Value::as_str) {
            apply_holding_delta(document, account_id, instrument_id, currency, delta, now)?;
        } else {
            apply_account_cash_delta(document, account_id, currency, delta, now)?;
        }
    }

    Ok(())
}

fn apply_buy_or_sell_movement(
    document: &mut Value,
    movement: &Value,
    entries: &[Value],
    is_buy: bool,
    now: &str,
) -> Result<(), LedgerError> {
    let cash_role = if is_buy { "source" } else { "destination" };
    let holding_role = if is_buy { "destination" } else { "source" };
    let cash = entries
        .iter()
        .find(|entry| {
            entry.get("instrumentId").is_none()
                && entry.get("role").and_then(Value::as_str) == Some(cash_role)
        })
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec!["buy/sell cash leg is missing".to_string()])
        })?;
    let holding = entries
        .iter()
        .find(|entry| {
            entry.get("instrumentId").is_some()
                && entry.get("role").and_then(Value::as_str) == Some(holding_role)
        })
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec!["buy/sell holding leg is missing".to_string()])
        })?;

    let cash_account_id = required_entry_string(cash, "accountId")?;
    let cash_currency = required_entry_string(cash, "currency")?;
    let cash_amount = parse_entry_amount(cash)?;
    let holding_account_id = required_entry_string(holding, "accountId")?;
    let quote_currency = required_entry_string(holding, "currency")?;
    let instrument_id = required_entry_string(holding, "instrumentId")?;
    let quantity = parse_entry_amount(holding)?;
    let occurred_at = movement
        .get("occurredAt")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec!["movement.occurredAt is missing".to_string()])
        })?;
    let mut fee_total = DecimalAmount::ZERO;
    for entry in entries.iter().filter(|entry| {
        matches!(
            entry.get("role").and_then(Value::as_str),
            Some("fee" | "tax")
        )
    }) {
        if required_entry_string(entry, "accountId")? != cash_account_id
            || required_entry_string(entry, "currency")? != cash_currency
            || required_entry_string(entry, "direction")? != "out"
            || entry.get("instrumentId").is_some()
        {
            return Err(LedgerError::InvalidInput(vec![
                "buy/sell fee and tax legs must be cash outflows from the principal account and currency"
                    .to_string(),
            ]));
        }
        fee_total += parse_entry_amount(entry)?;
    }

    if is_buy {
        let total_cash_out = cash_amount + fee_total;
        apply_account_cash_delta(
            document,
            cash_account_id,
            cash_currency,
            -total_cash_out,
            now,
        )?;
        let cost_basis_fx = apply_holding_purchase(
            document,
            HoldingPurchase {
                account_id: holding_account_id,
                instrument_id,
                quote_currency,
                quantity,
                cost_amount: total_cash_out,
                cost_currency: cash_currency,
            },
            occurred_at,
            now,
        )?;
        if let Some(cost_basis_fx) = cost_basis_fx {
            record_movement_cost_basis_fx(document, movement, cost_basis_fx)?;
        }
    } else {
        if fee_total > cash_amount {
            return Err(LedgerError::InvalidInput(vec![
                "sell fee/tax total must not exceed gross proceeds".to_string(),
            ]));
        }
        let released_cost_basis = apply_holding_sale(
            document,
            holding_account_id,
            instrument_id,
            quote_currency,
            quantity,
            now,
        )?;
        let net_proceeds = cash_amount - fee_total;
        apply_account_cash_delta(document, cash_account_id, cash_currency, net_proceeds, now)?;
        record_investment_sale_result(
            document,
            movement,
            InvestmentSaleInputs {
                gross_proceeds: cash_amount,
                fee_and_tax_total: fee_total,
                net_proceeds,
                cash_currency,
                released_cost_basis,
                occurred_at,
            },
        )?;
    }

    Ok(())
}

struct InvestmentSaleInputs<'a> {
    gross_proceeds: DecimalAmount,
    fee_and_tax_total: DecimalAmount,
    net_proceeds: DecimalAmount,
    cash_currency: &'a str,
    released_cost_basis: Option<(DecimalAmount, String)>,
    occurred_at: &'a str,
}

fn record_investment_sale_result(
    document: &mut Value,
    movement: &Value,
    inputs: InvestmentSaleInputs<'_>,
) -> Result<(), LedgerError> {
    let InvestmentSaleInputs {
        gross_proceeds,
        fee_and_tax_total,
        net_proceeds,
        cash_currency,
        released_cost_basis,
        occurred_at,
    } = inputs;
    let movement_id = movement
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| LedgerError::InvalidInput(vec!["movement.id is missing".to_string()]))?;
    let mut result = json!({
        "costBasisMethod": "average_cost",
        "grossProceeds": money(gross_proceeds, cash_currency),
        "feeAndTaxTotal": money(fee_and_tax_total, cash_currency),
        "netProceeds": money(net_proceeds, cash_currency),
        "realizedPnlStatus": "cost_basis_unavailable"
    });
    if let Some((released_amount, released_currency)) = released_cost_basis {
        result["costBasisReleased"] = money(released_amount, &released_currency);
        if released_currency == cash_currency {
            result["realizedPnl"] = money(net_proceeds - released_amount, cash_currency);
            result["realizedPnlStatus"] = json!("calculated");
        } else if let Some(conversion) = convert_execution_amount(
            document,
            net_proceeds,
            cash_currency,
            &released_currency,
            occurred_at,
        ) {
            result["netProceedsInCostBasisCurrency"] = money(conversion.amount, &released_currency);
            result["realizedPnl"] = money(conversion.amount - released_amount, &released_currency);
            result["fxBasis"] = conversion.basis;
            result["realizedPnlStatus"] = json!("calculated_with_fx");
        } else {
            result["realizedPnlStatus"] = json!("currency_mismatch");
        }
    }
    let stored = document["movements"]
        .as_array_mut()
        .expect("validated local ledger movements should be an array")
        .iter_mut()
        .find(|stored| stored.get("id").and_then(Value::as_str) == Some(movement_id))
        .ok_or_else(|| LedgerError::NotFound(format!("movement does not exist: {movement_id}")))?;
    stored["saleResult"] = result;
    Ok(())
}

fn record_movement_cost_basis_fx(
    document: &mut Value,
    movement: &Value,
    cost_basis_fx: Value,
) -> Result<(), LedgerError> {
    let movement_id = movement
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| LedgerError::InvalidInput(vec!["movement.id is missing".to_string()]))?;
    let stored = document["movements"]
        .as_array_mut()
        .expect("validated local ledger movements should be an array")
        .iter_mut()
        .find(|stored| stored.get("id").and_then(Value::as_str) == Some(movement_id))
        .ok_or_else(|| LedgerError::NotFound(format!("movement does not exist: {movement_id}")))?;
    stored["costBasisFx"] = cost_basis_fx;
    Ok(())
}

fn required_entry_string<'a>(entry: &'a Value, key: &str) -> Result<&'a str, LedgerError> {
    entry
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| LedgerError::InvalidInput(vec![format!("buy/sell entry.{key} is missing")]))
}

fn parse_entry_amount(entry: &Value) -> Result<DecimalAmount, LedgerError> {
    parse_decimal(required_entry_string(entry, "amount")?)
        .map_err(|error| LedgerError::InvalidInput(vec![error.to_string()]))
}

fn apply_account_cash_delta(
    document: &mut Value,
    account_id: &str,
    currency: &str,
    delta: DecimalAmount,
    now: &str,
) -> Result<(), LedgerError> {
    let account = find_account_mut(document, account_id)
        .ok_or_else(|| LedgerError::NotFound(format!("account does not exist: {account_id}")))?;
    if account.get("status").and_then(Value::as_str) == Some("archived") {
        return Err(LedgerError::Conflict(format!(
            "account is archived: {account_id}"
        )));
    }

    let balances = account["cashBalances"]
        .as_array_mut()
        .expect("validated account cashBalances should be an array");
    if let Some(balance) = balances
        .iter_mut()
        .find(|balance| balance.get("currency").and_then(Value::as_str) == Some(currency))
    {
        let current = parse_decimal(
            balance
                .get("amount")
                .and_then(Value::as_str)
                .expect("validated balance amount should be a string"),
        )
        .map_err(|error| LedgerError::InvalidInput(vec![error.to_string()]))?;
        balance["amount"] = json!(money_amount(current + delta));
        balance["asOf"] = json!(now);
        balance["quality"] = json!("exact");
    } else {
        balances.push(json!({
            "currency": currency,
            "amount": money_amount(delta),
            "asOf": now,
            "quality": "exact"
        }));
    }
    account["updatedAt"] = json!(now);
    Ok(())
}

struct HoldingPurchase<'a> {
    account_id: &'a str,
    instrument_id: &'a str,
    quote_currency: &'a str,
    quantity: DecimalAmount,
    cost_amount: DecimalAmount,
    cost_currency: &'a str,
}

fn apply_holding_purchase(
    document: &mut Value,
    purchase: HoldingPurchase<'_>,
    occurred_at: &str,
    now: &str,
) -> Result<Option<Value>, LedgerError> {
    let HoldingPurchase {
        account_id,
        instrument_id,
        quote_currency,
        quantity,
        cost_amount,
        cost_currency,
    } = purchase;
    if !active_account_exists(document, account_id) {
        return Err(LedgerError::NotFound(format!(
            "account does not exist or is archived: {account_id}"
        )));
    }
    ensure_matching_instrument(document, instrument_id, quote_currency)?;

    let existing_index = document["holdings"]
        .as_array()
        .expect("validated local ledger holdings should be an array")
        .iter()
        .position(|holding| {
            holding.get("accountId").and_then(Value::as_str) == Some(account_id)
                && holding.get("instrumentId").and_then(Value::as_str) == Some(instrument_id)
        });

    let mut cost_basis_fx = None;
    if let Some(index) = existing_index {
        let existing = document["holdings"][index].clone();
        let current_quantity = parse_decimal(
            existing
                .get("quantity")
                .and_then(Value::as_str)
                .expect("holding quantity should be a string"),
        )
        .map_err(|error| LedgerError::InvalidInput(vec![error.to_string()]))?;
        let next_quantity = current_quantity + quantity;

        if let Some(existing_cost_basis) = existing.get("costBasisTotal")
            && let Some(existing_currency) =
                existing_cost_basis.get("currency").and_then(Value::as_str)
            && existing_currency != cost_currency
        {
            cost_basis_fx = Some(
                convert_execution_amount(
                    document,
                    cost_amount,
                    cost_currency,
                    existing_currency,
                    occurred_at,
                )
                .ok_or_else(|| {
                    LedgerError::Conflict(format!(
                        "cannot combine holding cost basis across {cost_currency} and {existing_currency} without an FX rate at or before {occurred_at}"
                    ))
                })?
                .basis,
            );
        }

        let next_cost_basis = add_purchase_value(
            document,
            existing.get("costBasisTotal"),
            current_quantity,
            cost_amount,
            cost_currency,
            occurred_at,
            "holding cost basis",
        )?;
        let next_market_value = add_purchase_value(
            document,
            existing.get("marketValue"),
            current_quantity,
            cost_amount,
            cost_currency,
            occurred_at,
            "holding fallback market value",
        )?;

        let holding = document["holdings"]
            .as_array_mut()
            .expect("validated local ledger holdings should be an array")
            .get_mut(index)
            .expect("holding index should remain valid");
        holding["quantity"] = json!(next_quantity.decimal_string());
        if let Some((amount, currency)) = next_cost_basis {
            holding["costBasisTotal"] = money(amount, &currency);
        }
        if let Some((amount, currency)) = next_market_value {
            holding["marketValue"] = json!({
                "amount": money_amount(amount),
                "currency": currency,
                "asOf": now,
                "quality": "estimated"
            });
        }
        holding["quoteStatus"] = json!("stale");
        holding["asOf"] = json!(now);
        if let Some(object) = holding.as_object_mut() {
            object.remove("unrealizedPnl");
            object.remove("unrealizedPnlRate");
        }
    } else {
        document["holdings"]
            .as_array_mut()
            .expect("validated local ledger holdings should be an array")
            .push(json!({
                "id": stable_holding_id(account_id, instrument_id),
                "accountId": account_id,
                "instrumentId": instrument_id,
                "quantity": quantity.decimal_string(),
                "costBasisTotal": money(cost_amount, cost_currency),
                "marketValue": {
                    "amount": money_amount(cost_amount),
                    "currency": cost_currency,
                    "asOf": now,
                    "quality": "estimated"
                },
                "quoteStatus": "stale",
                "asOf": now,
                "note": "Cost fallback until a quote is available"
            }));
    }

    Ok(cost_basis_fx)
}

fn add_purchase_value(
    document: &Value,
    existing: Option<&Value>,
    current_quantity: DecimalAmount,
    purchase_amount: DecimalAmount,
    purchase_currency: &str,
    occurred_at: &str,
    label: &str,
) -> Result<Option<(DecimalAmount, String)>, LedgerError> {
    let Some(existing) = existing else {
        return if current_quantity == DecimalAmount::ZERO {
            Ok(Some((purchase_amount, purchase_currency.to_string())))
        } else {
            Ok(None)
        };
    };
    let existing_amount = parse_decimal(
        existing
            .get("amount")
            .and_then(Value::as_str)
            .ok_or_else(|| LedgerError::InvalidInput(vec![format!("{label}.amount is missing")]))?,
    )
    .map_err(|error| LedgerError::InvalidInput(vec![error.to_string()]))?;
    let existing_currency = existing
        .get("currency")
        .and_then(Value::as_str)
        .ok_or_else(|| LedgerError::InvalidInput(vec![format!("{label}.currency is missing")]))?;
    let converted_purchase = convert_execution_amount(
        document,
        purchase_amount,
        purchase_currency,
        existing_currency,
        occurred_at,
    )
    .map(|conversion| conversion.amount)
    .ok_or_else(|| {
        LedgerError::Conflict(format!(
            "cannot combine {label} across {purchase_currency} and {existing_currency} without an FX rate at or before {occurred_at}"
        ))
    })?;
    Ok(Some((
        existing_amount + converted_purchase,
        existing_currency.to_string(),
    )))
}

fn apply_holding_sale(
    document: &mut Value,
    account_id: &str,
    instrument_id: &str,
    quote_currency: &str,
    quantity: DecimalAmount,
    now: &str,
) -> Result<Option<(DecimalAmount, String)>, LedgerError> {
    if !active_account_exists(document, account_id) {
        return Err(LedgerError::NotFound(format!(
            "account does not exist or is archived: {account_id}"
        )));
    }
    ensure_matching_instrument(document, instrument_id, quote_currency)?;
    let index = document["holdings"]
        .as_array()
        .expect("validated local ledger holdings should be an array")
        .iter()
        .position(|holding| {
            holding.get("accountId").and_then(Value::as_str) == Some(account_id)
                && holding.get("instrumentId").and_then(Value::as_str) == Some(instrument_id)
        })
        .ok_or_else(|| {
            LedgerError::Conflict(format!(
                "holding does not exist for sell/out entry: {instrument_id}"
            ))
        })?;
    let existing = document["holdings"][index].clone();
    let current_quantity = parse_decimal(
        existing
            .get("quantity")
            .and_then(Value::as_str)
            .expect("holding quantity should be a string"),
    )
    .map_err(|error| LedgerError::InvalidInput(vec![error.to_string()]))?;
    let next_quantity = current_quantity - quantity;
    if next_quantity < DecimalAmount::ZERO {
        return Err(LedgerError::Conflict(format!(
            "holding quantity cannot become negative: {instrument_id}"
        )));
    }
    let next_cost_basis = proportional_remaining_value(
        existing.get("costBasisTotal"),
        current_quantity,
        next_quantity,
        "holding cost basis",
    )?;
    let released_cost_basis =
        match (existing.get("costBasisTotal"), &next_cost_basis) {
            (Some(current), Some((remaining_amount, remaining_currency))) => {
                let current_amount =
                    parse_decimal(current.get("amount").and_then(Value::as_str).ok_or_else(
                        || {
                            LedgerError::InvalidInput(vec![
                                "holding cost basis.amount is missing".to_string(),
                            ])
                        },
                    )?)
                    .map_err(|error| LedgerError::InvalidInput(vec![error.to_string()]))?;
                let current_currency =
                    current
                        .get("currency")
                        .and_then(Value::as_str)
                        .ok_or_else(|| {
                            LedgerError::InvalidInput(vec![
                                "holding cost basis.currency is missing".to_string(),
                            ])
                        })?;
                if current_currency != remaining_currency {
                    return Err(LedgerError::InvalidInput(vec![
                        "holding cost basis currency changed during sale".to_string(),
                    ]));
                }
                Some((
                    current_amount - *remaining_amount,
                    current_currency.to_string(),
                ))
            }
            (None, None) => None,
            _ => {
                return Err(LedgerError::InvalidInput(vec![
                    "holding cost basis reduction is inconsistent".to_string(),
                ]));
            }
        };
    let next_market_value = proportional_remaining_value(
        existing.get("marketValue"),
        current_quantity,
        next_quantity,
        "holding fallback market value",
    )?;

    let holding = document["holdings"]
        .as_array_mut()
        .expect("validated local ledger holdings should be an array")
        .get_mut(index)
        .expect("holding index should remain valid");
    holding["quantity"] = json!(next_quantity.decimal_string());
    if let Some((amount, currency)) = next_cost_basis {
        holding["costBasisTotal"] = money(amount, &currency);
    }
    if let Some((amount, currency)) = next_market_value {
        holding["marketValue"] = json!({
            "amount": money_amount(amount),
            "currency": currency,
            "asOf": now,
            "quality": "estimated"
        });
    }
    holding["quoteStatus"] = json!("stale");
    holding["asOf"] = json!(now);
    if let Some(object) = holding.as_object_mut() {
        object.remove("unrealizedPnl");
        object.remove("unrealizedPnlRate");
    }
    Ok(released_cost_basis)
}

fn proportional_remaining_value(
    value: Option<&Value>,
    current_quantity: DecimalAmount,
    remaining_quantity: DecimalAmount,
    label: &str,
) -> Result<Option<(DecimalAmount, String)>, LedgerError> {
    let Some(value) = value else {
        return Ok(None);
    };
    if current_quantity <= DecimalAmount::ZERO {
        return Err(LedgerError::Conflict(format!(
            "cannot reduce {label} from a non-positive holding quantity"
        )));
    }
    let current_amount =
        parse_decimal(value.get("amount").and_then(Value::as_str).ok_or_else(|| {
            LedgerError::InvalidInput(vec![format!("{label}.amount is missing")])
        })?)
        .map_err(|error| LedgerError::InvalidInput(vec![error.to_string()]))?;
    let currency = value
        .get("currency")
        .and_then(Value::as_str)
        .ok_or_else(|| LedgerError::InvalidInput(vec![format!("{label}.currency is missing")]))?;
    let remaining_amount = divide_decimal(
        multiply_decimal(current_amount, remaining_quantity),
        current_quantity,
    )
    .ok_or_else(|| LedgerError::Conflict(format!("cannot calculate remaining {label}")))?;
    Ok(Some((remaining_amount, currency.to_string())))
}

fn ensure_matching_instrument(
    document: &mut Value,
    instrument_id: &str,
    quote_currency: &str,
) -> Result<(), LedgerError> {
    if let Some(instrument) = document["instruments"]
        .as_array()
        .expect("validated local ledger instruments should be an array")
        .iter()
        .find(|instrument| instrument.get("id").and_then(Value::as_str) == Some(instrument_id))
    {
        if instrument.get("quoteCurrency").and_then(Value::as_str) != Some(quote_currency) {
            return Err(LedgerError::Conflict(format!(
                "instrument quote currency does not match holding entry: {instrument_id}"
            )));
        }
    } else {
        ensure_instrument(document, instrument_id, quote_currency);
    }
    Ok(())
}

fn apply_holding_delta(
    document: &mut Value,
    account_id: &str,
    instrument_id: &str,
    currency: &str,
    delta: DecimalAmount,
    now: &str,
) -> Result<(), LedgerError> {
    if !active_account_exists(document, account_id) {
        return Err(LedgerError::NotFound(format!(
            "account does not exist or is archived: {account_id}"
        )));
    }
    ensure_instrument(document, instrument_id, currency);

    let holdings = document["holdings"]
        .as_array_mut()
        .expect("validated local ledger holdings should be an array");
    if let Some(holding) = holdings.iter_mut().find(|holding| {
        holding.get("accountId").and_then(Value::as_str) == Some(account_id)
            && holding.get("instrumentId").and_then(Value::as_str) == Some(instrument_id)
    }) {
        let current_quantity = parse_decimal(
            holding
                .get("quantity")
                .and_then(Value::as_str)
                .expect("holding quantity should be a string"),
        )
        .map_err(|error| LedgerError::InvalidInput(vec![error.to_string()]))?;
        let next_quantity = current_quantity + delta;
        if next_quantity < DecimalAmount::ZERO {
            return Err(LedgerError::Conflict(format!(
                "holding quantity cannot become negative: {instrument_id}"
            )));
        }
        holding["quantity"] = json!(next_quantity.decimal_string());
        apply_holding_money_delta(holding, "costBasisTotal", currency, delta)?;
        apply_holding_valued_money_delta(holding, "marketValue", currency, delta, now)?;
        holding["quoteStatus"] = json!("stale");
        holding["asOf"] = json!(now);
        if let Some(pnl) = holding.as_object_mut() {
            pnl.remove("unrealizedPnl");
            pnl.remove("unrealizedPnlRate");
        }
    } else {
        if delta < DecimalAmount::ZERO {
            return Err(LedgerError::Conflict(format!(
                "holding does not exist for sell/out entry: {instrument_id}"
            )));
        }
        holdings.push(json!({
            "id": stable_holding_id(account_id, instrument_id),
            "accountId": account_id,
            "instrumentId": instrument_id,
            "quantity": delta.decimal_string(),
            "costBasisTotal": money(delta, currency),
            "marketValue": {
                "amount": money_amount(delta),
                "currency": currency,
                "asOf": now,
                "quality": "estimated"
            },
            "quoteStatus": "stale",
            "asOf": now,
            "note": "MVP cost-based valuation until quote refresh"
        }));
    }

    Ok(())
}

fn mark_dca_reminders_recorded_for_movements(document: &mut Value, movements: &[Value], now: &str) {
    let reminder_ids = movements
        .iter()
        .filter(|movement| movement.get("type").and_then(Value::as_str) == Some("buy"))
        .filter_map(|movement| {
            let source = movement.get("source")?;
            (source.get("kind").and_then(Value::as_str) == Some("system")
                && source.get("createdBy").and_then(Value::as_str) == Some("system"))
            .then(|| source.get("sourceId").and_then(Value::as_str))
            .flatten()
        })
        .map(str::to_string)
        .collect::<Vec<_>>();

    if reminder_ids.is_empty() {
        return;
    }

    let mut plan_ids = Vec::new();
    for reminder in document["dcaReminders"]
        .as_array_mut()
        .expect("validated local ledger dcaReminders should be an array")
        .iter_mut()
        .filter(|reminder| {
            reminder
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|id| reminder_ids.iter().any(|reminder_id| reminder_id == id))
        })
    {
        reminder["status"] = json!("recorded");
        reminder["updatedAt"] = json!(now);
        if let Some(plan_id) = reminder.get("planId").and_then(Value::as_str) {
            plan_ids.push(plan_id.to_string());
        }
    }

    for plan in document["dcaPlans"]
        .as_array_mut()
        .expect("validated local ledger dcaPlans should be an array")
        .iter_mut()
        .filter(|plan| {
            plan.get("id")
                .and_then(Value::as_str)
                .is_some_and(|id| plan_ids.iter().any(|plan_id| plan_id == id))
        })
    {
        plan["lastActionAt"] = json!(now);
        plan["updatedAt"] = json!(now);
    }
}

fn mark_subscriptions_charged_for_movements(
    document: &mut Value,
    movements: &[Value],
    now: &str,
) -> Result<(), LedgerError> {
    let charges = movements
        .iter()
        .filter_map(|movement| {
            Some((
                movement.get("subscriptionId")?.as_str()?.to_string(),
                movement.get("id")?.as_str()?.to_string(),
                movement.get("scheduledChargeDate")?.as_str()?.to_string(),
            ))
        })
        .collect::<Vec<_>>();

    for (subscription_id, movement_id, charge_date) in charges {
        let updated = {
            let subscription =
                find_subscription_mut(document, &subscription_id).ok_or_else(|| {
                    LedgerError::NotFound(format!(
                        "subscription for confirmed charge does not exist: {subscription_id}"
                    ))
                })?;
            if subscription
                .get("pendingChargeMovementId")
                .and_then(Value::as_str)
                != Some(movement_id.as_str())
            {
                return Err(LedgerError::Conflict(format!(
                    "subscription pending charge does not match movement: {subscription_id}"
                )));
            }
            let charge_date_value = Date::parse(&charge_date, &Iso8601::DATE).map_err(|_| {
                LedgerError::InvalidInput(vec![
                    "scheduled subscription charge date is invalid".to_string(),
                ])
            })?;
            let unit = subscription
                .get("billingCycle")
                .and_then(|value| value.get("unit"))
                .and_then(Value::as_str)
                .expect("validated subscription billingCycle.unit")
                .to_string();
            let interval = subscription
                .get("billingCycle")
                .and_then(|value| value.get("interval"))
                .and_then(Value::as_u64)
                .expect("validated subscription billingCycle.interval");
            let anchor_day = subscription
                .get("billingAnchorDay")
                .and_then(Value::as_u64)
                .and_then(|value| u8::try_from(value).ok())
                .expect("validated subscription billingAnchorDay");
            let next =
                advance_subscription_billing_date(charge_date_value, &unit, interval, anchor_day)
                    .ok_or_else(|| {
                    LedgerError::InvalidInput(vec![
                        "next subscription charge date exceeds supported calendar range"
                            .to_string(),
                    ])
                })?;
            let end = subscription
                .get("endDate")
                .and_then(Value::as_str)
                .and_then(|value| Date::parse(value, &Iso8601::DATE).ok());

            subscription["lastChargeDate"] = json!(charge_date);
            subscription["lastChargeMovementId"] = json!(movement_id);
            subscription["updatedAt"] = json!(now);
            subscription
                .as_object_mut()
                .expect("subscription should be an object")
                .remove("pendingChargeMovementId");
            subscription
                .as_object_mut()
                .expect("subscription should be an object")
                .remove("pendingChargeDate");
            if end.is_some_and(|end| next > end) {
                subscription["nextChargeDate"] = Value::Null;
                subscription["status"] = json!("expired");
            } else {
                subscription["nextChargeDate"] = json!(next.to_string());
                if subscription.get("status").and_then(Value::as_str) == Some("trial") {
                    subscription["status"] = json!("active");
                }
            }
            subscription.clone()
        };
        append_sync_change(
            document,
            "subscription",
            &subscription_id,
            "update",
            &updated,
            now,
        );
    }
    Ok(())
}

fn clear_rejected_subscription_charge_proposals(
    document: &mut Value,
    movements: &[Value],
    now: &str,
) {
    let charges = movements
        .iter()
        .filter_map(|movement| {
            Some((
                movement.get("subscriptionId")?.as_str()?.to_string(),
                movement.get("id")?.as_str()?.to_string(),
            ))
        })
        .collect::<Vec<_>>();
    for (subscription_id, movement_id) in charges {
        let Some(subscription) = find_subscription_mut(document, &subscription_id) else {
            continue;
        };
        if subscription
            .get("pendingChargeMovementId")
            .and_then(Value::as_str)
            == Some(movement_id.as_str())
        {
            subscription
                .as_object_mut()
                .expect("subscription should be an object")
                .remove("pendingChargeMovementId");
            subscription
                .as_object_mut()
                .expect("subscription should be an object")
                .remove("pendingChargeDate");
            subscription["updatedAt"] = json!(now);
        }
    }
}

fn ai_import_groups_from_input(
    document: &Value,
    input: &Value,
    source_kind: &str,
    proposal_id: &str,
    atomic_group_id: &str,
    movement_id: &str,
    now: &str,
) -> Result<Vec<Value>, LedgerError> {
    if source_kind == "csv_import"
        && let Some(groups) = csv_import_groups_from_input(
            document,
            input,
            proposal_id,
            atomic_group_id,
            movement_id,
            now,
        )?
    {
        return Ok(groups);
    }

    Ok(vec![ai_import_group_from_input(
        document,
        input,
        source_kind,
        proposal_id,
        atomic_group_id,
        movement_id,
        now,
    )?])
}

fn ai_import_group_from_input(
    document: &Value,
    input: &Value,
    source_kind: &str,
    proposal_id: &str,
    atomic_group_id: &str,
    movement_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    if let Some(movement_input) = ai_import_movement_input(input) {
        let movement = ai_proposed_movement_from_input(
            document,
            &movement_input,
            proposal_id,
            movement_id,
            atomic_group_id,
            now,
        )?;
        let mut group = atomic_group_from_movement(&movement, "pending");
        let title = movement
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("AI 候选记录");
        group["title"] = json!(format!("新增：{title}"));
        group["diffs"] = json!([]);
        group["warnings"] = json!([
            {
                "code": "ai_import_requires_user_confirmation",
                "message": "AI 导入只生成候选；确认前不会写入账本。",
                "severity": "info"
            }
        ]);
        group["sourceEvidence"] = json!([ai_evidence_ref(source_kind, proposal_id, input)]);
        return Ok(group);
    }

    Ok(json!({
        "id": atomic_group_id,
        "title": format!("{}：待编辑候选", ai_source_label(source_kind, input)),
        "operation": "create",
        "targetType": "movement",
        "targetId": movement_id,
        "proposedMovements": [],
        "diffs": [],
        "warnings": [
            {
                "code": "local_ai_requires_structured_movement",
                "message": "本地账本模式不会猜金额；请编辑候选并补全结构化记录后再确认。",
                "severity": "warning"
            }
        ],
        "status": "pending",
        "validation": {
            "isValid": false,
            "errors": [
                {
                    "code": "structured_movement_required",
                    "message": "需要结构化 movement 后才能确认写入账本。"
                }
            ]
        },
        "sourceEvidence": [ai_evidence_ref(source_kind, proposal_id, input)]
    }))
}

fn ai_import_proposal_from_groups(
    input: &Value,
    source_kind: &str,
    proposal_id: &str,
    groups: Vec<Value>,
    now: &str,
) -> Value {
    let summary = if groups.len() == 1 {
        groups[0]
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("AI 导入候选")
            .to_string()
    } else {
        format!(
            "{} 生成 {} 个候选",
            ai_source_label(source_kind, input),
            groups.len()
        )
    };

    json!({
        "id": proposal_id,
        "status": "pending",
        "source": {
            "kind": source_kind,
            "evidenceRefs": [ai_evidence_ref(source_kind, proposal_id, input)]
        },
        "atomicGroups": groups,
        "summary": summary,
        "warnings": [],
        "createdAt": now
    })
}

fn csv_import_groups_from_input(
    document: &Value,
    input: &Value,
    proposal_id: &str,
    atomic_group_id: &str,
    movement_id: &str,
    now: &str,
) -> Result<Option<Vec<Value>>, LedgerError> {
    let Some(csv) = input
        .get("csv")
        .or_else(|| input.get("content"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
    else {
        return Ok(None);
    };

    let rows = parse_csv_rows(csv)?;
    if rows.len() < 2 {
        return Ok(Some(vec![invalid_ai_import_group(
            "csv_import",
            proposal_id,
            atomic_group_id,
            movement_id,
            input,
            "CSV：待编辑候选",
            vec!["CSV must contain a header row and at least one data row".to_string()],
        )]));
    }

    let headers = rows[0]
        .iter()
        .map(|header| normalize_csv_header(header))
        .collect::<Vec<_>>();
    let default_account_id = csv_default_account_id(input);
    let default_currency = input
        .get("defaultCurrency")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(DEFAULT_BASE_CURRENCY);

    let mut groups = Vec::new();
    for (row_offset, row) in rows.iter().skip(1).enumerate() {
        if row.iter().all(|field| field.trim().is_empty()) {
            continue;
        }

        let row_number = row_offset + 2;
        let record = csv_record_from_row(&headers, row);
        let group_id = indexed_local_id(atomic_group_id, row_offset);
        let row_movement_id = indexed_local_id(movement_id, row_offset);

        match csv_movement_input_from_record(
            &record,
            row_number,
            default_account_id.as_deref(),
            default_currency,
            now,
        ) {
            Ok(movement_input) => {
                let movement = ai_proposed_movement_from_input(
                    document,
                    &movement_input,
                    proposal_id,
                    &row_movement_id,
                    &group_id,
                    now,
                )?;
                let mut group = atomic_group_from_movement(&movement, "pending");
                let title = movement
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or("CSV 候选记录");
                group["title"] = json!(format!("CSV 第{row_number}行：{title}"));
                group["diffs"] = json!([]);
                group["warnings"] = json!([
                    {
                        "code": "csv_import_requires_user_confirmation",
                        "message": "CSV 导入只生成候选；确认前不会写入账本。",
                        "severity": "info"
                    }
                ]);
                group["sourceEvidence"] =
                    json!([ai_evidence_ref("csv_import", proposal_id, input)]);
                groups.push(group);
            }
            Err(errors) => groups.push(invalid_ai_import_group(
                "csv_import",
                proposal_id,
                &group_id,
                &row_movement_id,
                input,
                &format!("CSV 第{row_number}行：待编辑候选"),
                errors,
            )),
        }
    }

    if groups.is_empty() {
        groups.push(invalid_ai_import_group(
            "csv_import",
            proposal_id,
            atomic_group_id,
            movement_id,
            input,
            "CSV：待编辑候选",
            vec!["CSV contains no non-empty data rows".to_string()],
        ));
    }

    Ok(Some(groups))
}

fn csv_default_account_id(input: &Value) -> Option<String> {
    input
        .get("defaultAccountId")
        .or_else(|| input.get("accountId"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .or_else(|| {
            input
                .get("selectedAccountIds")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .find_map(|value| value.as_str().filter(|id| !id.trim().is_empty()))
                .map(str::to_string)
        })
}

fn csv_record_from_row(headers: &[String], row: &[String]) -> BTreeMap<String, String> {
    let mut record = BTreeMap::new();
    for (index, header) in headers.iter().enumerate() {
        if header.is_empty() {
            continue;
        }
        record.insert(header.clone(), row.get(index).cloned().unwrap_or_default());
    }
    record
}

fn csv_movement_input_from_record(
    record: &BTreeMap<String, String>,
    row_number: usize,
    default_account_id: Option<&str>,
    default_currency: &str,
    now: &str,
) -> Result<Value, Vec<String>> {
    let mut errors = Vec::new();
    let raw_amount = csv_value(record, &["amount", "金额", "money", "value"])
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_default();
    let (amount, amount_sign) = normalized_csv_amount(raw_amount).unwrap_or_else(|| {
        errors.push(format!(
            "CSV row {row_number}: amount must be a decimal string"
        ));
        ("".to_string(), 0)
    });

    let direction = csv_direction(record, amount_sign).unwrap_or_else(|| {
        errors.push(format!(
            "CSV row {row_number}: direction/type/sign is required to avoid guessing"
        ));
        "out".to_string()
    });
    let movement_type = csv_movement_type(record, &direction).unwrap_or_else(|| {
        errors.push(format!("CSV row {row_number}: type is unsupported"));
        "expense".to_string()
    });
    let account_id = csv_value(record, &["accountId", "account", "账户id", "账户ID"])
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .or_else(|| default_account_id.map(str::to_string))
        .unwrap_or_else(|| {
            errors.push(format!(
                "CSV row {row_number}: accountId or selectedAccountIds[0] is required"
            ));
            String::new()
        });
    let currency = csv_value(record, &["currency", "币种"])
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(default_currency);
    let occurred_at = csv_value(record, &["occurredAt", "date", "time", "日期", "交易时间"])
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(now);
    let title = csv_value(
        record,
        &[
            "title",
            "description",
            "merchant",
            "counterparty",
            "摘要",
            "描述",
            "商户",
            "对手方",
        ],
    )
    .filter(|value| !value.trim().is_empty())
    .map(str::to_string)
    .unwrap_or_else(|| format!("CSV 第{row_number}行"));

    if !errors.is_empty() {
        return Err(errors);
    }

    let tags = csv_value(record, &["tags", "标签"])
        .map(csv_tags)
        .unwrap_or_else(|| vec!["csv_import".to_string()]);

    Ok(json!({
        "type": movement_type,
        "occurredAt": occurred_at,
        "title": title,
        "entries": [
            {
                "accountId": account_id,
                "amount": amount,
                "currency": currency,
                "direction": direction,
                "role": "source"
            }
        ],
        "amountBreakdown": {
            "paidAmount": {
                "amount": amount,
                "currency": currency
            }
        },
        "tags": tags
    }))
}

fn csv_value<'a>(record: &'a BTreeMap<String, String>, keys: &[&str]) -> Option<&'a str> {
    keys.iter()
        .find_map(|key| record.get(*key).map(String::as_str))
}

fn normalized_csv_amount(raw: &str) -> Option<(String, i8)> {
    let value = raw.trim().replace(',', "");
    let (sign, unsigned) = if let Some(unsigned) = value.strip_prefix('-') {
        (-1, unsigned)
    } else if let Some(unsigned) = value.strip_prefix('+') {
        (1, unsigned)
    } else {
        (0, value.as_str())
    };

    is_positive_decimal_string(unsigned).then(|| (unsigned.to_string(), sign))
}

fn csv_direction(record: &BTreeMap<String, String>, amount_sign: i8) -> Option<String> {
    if amount_sign < 0 {
        return Some("out".to_string());
    }
    if amount_sign > 0 {
        return Some("in".to_string());
    }

    let raw = csv_value(record, &["direction", "收支", "方向"])?.trim();
    match raw.to_ascii_lowercase().as_str() {
        "in" | "income" | "收入" | "入" => Some("in".to_string()),
        "out" | "expense" | "支出" | "出" => Some("out".to_string()),
        _ => None,
    }
}

fn csv_movement_type(record: &BTreeMap<String, String>, direction: &str) -> Option<String> {
    let Some(raw) = csv_value(record, &["type", "类型"]).map(str::trim) else {
        return match direction {
            "in" => Some("income".to_string()),
            "out" => Some("expense".to_string()),
            _ => None,
        };
    };

    match raw.to_ascii_lowercase().as_str() {
        "" => csv_movement_type(&BTreeMap::new(), direction),
        "income" | "收入" => Some("income".to_string()),
        "expense" | "支出" => Some("expense".to_string()),
        "fee" | "手续费" => Some("fee".to_string()),
        "interest" | "利息" => Some("interest".to_string()),
        "dividend" | "分红" => Some("dividend".to_string()),
        "buy" | "买入" => Some("buy".to_string()),
        "sell" | "卖出" => Some("sell".to_string()),
        "adjustment" | "余额观察" | "调整" => Some("adjustment".to_string()),
        "loan_disbursement" | "贷款发放" => Some("loan_disbursement".to_string()),
        "loan_repayment" | "还款" => Some("loan_repayment".to_string()),
        _ => None,
    }
}

fn csv_tags(raw: &str) -> Vec<String> {
    let tags = raw
        .split([';', '|'])
        .map(str::trim)
        .filter(|tag| !tag.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    if tags.is_empty() {
        vec!["csv_import".to_string()]
    } else {
        tags
    }
}

fn normalize_csv_header(header: &str) -> String {
    let compact = header
        .trim()
        .to_ascii_lowercase()
        .chars()
        .filter(|ch| !matches!(ch, ' ' | '_' | '-'))
        .collect::<String>();

    match compact.as_str() {
        "accountid" | "账户id" => "accountId".to_string(),
        "occurredat" | "date" | "time" | "日期" | "交易时间" => "occurredAt".to_string(),
        "title" | "description" | "merchant" | "counterparty" | "摘要" | "描述" | "商户"
        | "对手方" => compact,
        "amount" | "money" | "value" | "金额" => "amount".to_string(),
        "currency" | "币种" => "currency".to_string(),
        "direction" | "收支" | "方向" => "direction".to_string(),
        "type" | "类型" => "type".to_string(),
        "tags" | "标签" => "tags".to_string(),
        _ => compact,
    }
}

fn parse_csv_rows(raw: &str) -> Result<Vec<Vec<String>>, LedgerError> {
    let mut rows = Vec::new();
    let mut row = Vec::new();
    let mut field = String::new();
    let mut chars = raw.chars().peekable();
    let mut in_quotes = false;

    while let Some(ch) = chars.next() {
        match ch {
            '"' if in_quotes && chars.peek() == Some(&'"') => {
                field.push('"');
                chars.next();
            }
            '"' => in_quotes = !in_quotes,
            ',' if !in_quotes => {
                row.push(field.trim().to_string());
                field.clear();
            }
            '\n' if !in_quotes => {
                row.push(field.trim_end_matches('\r').trim().to_string());
                field.clear();
                if row.iter().any(|value| !value.is_empty()) {
                    rows.push(row);
                }
                row = Vec::new();
            }
            _ => field.push(ch),
        }
    }

    if in_quotes {
        return Err(LedgerError::InvalidInput(vec![
            "CSV contains an unclosed quoted field".to_string(),
        ]));
    }

    row.push(field.trim_end_matches('\r').trim().to_string());
    if row.iter().any(|value| !value.is_empty()) {
        rows.push(row);
    }
    Ok(rows)
}

fn indexed_local_id(base: &str, index: usize) -> String {
    if index == 0 {
        base.to_string()
    } else {
        format!("{base}_{:03}", index + 1)
    }
}

fn invalid_ai_import_group(
    source_kind: &str,
    proposal_id: &str,
    atomic_group_id: &str,
    movement_id: &str,
    input: &Value,
    title: &str,
    errors: Vec<String>,
) -> Value {
    json!({
        "id": atomic_group_id,
        "title": title,
        "operation": "create",
        "targetType": "movement",
        "targetId": movement_id,
        "proposedMovements": [],
        "diffs": [],
        "warnings": [
            {
                "code": "local_ai_requires_structured_movement",
                "message": "本地账本模式不会猜金额；请编辑候选并补全结构化记录后再确认。",
                "severity": "warning"
            }
        ],
        "status": "pending",
        "validation": {
            "isValid": false,
            "errors": errors
                .into_iter()
                .map(|message| json!({
                    "code": "structured_movement_required",
                    "message": message
                }))
                .collect::<Vec<_>>()
        },
        "sourceEvidence": [ai_evidence_ref(source_kind, proposal_id, input)]
    })
}

fn ai_import_movement_input(input: &Value) -> Option<Value> {
    for key in ["movement", "draftMovement", "proposedMovement"] {
        if let Some(value) = input.get(key).filter(|value| value.is_object()) {
            return Some(value.clone());
        }
    }

    if let Some(value) = input
        .get("proposedMovements")
        .and_then(Value::as_array)
        .and_then(|items| items.iter().find(|item| item.is_object()))
    {
        return Some(value.clone());
    }

    input
        .get("atomicGroups")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|group| group.get("proposedMovements").and_then(Value::as_array))
        .flatten()
        .find(|movement| movement.is_object())
        .cloned()
}

fn ai_proposed_movement_from_input(
    document: &Value,
    input: &Value,
    proposal_id: &str,
    movement_id: &str,
    atomic_group_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    let movement_id = input
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| !id.trim().is_empty())
        .unwrap_or(movement_id);
    let mut movement =
        movement_from_create_input(document, input, movement_id, atomic_group_id, now)?;
    movement["status"] = json!("pending_review");
    movement["source"] = json!({
        "kind": "ai_proposal",
        "sourceId": proposal_id,
        "createdBy": "ai"
    });
    Ok(movement)
}

fn edited_ai_atomic_group_from_patch(
    document: &Value,
    group: &Value,
    patch: &Value,
    proposal_id: &str,
    movement_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    let Some(movement_input) = ai_import_movement_input(patch) else {
        return Err(LedgerError::InvalidInput(vec![
            "AI atomic group edit patch must include movement, draftMovement, proposedMovement, or proposedMovements[0]".to_string(),
        ]));
    };

    let fallback_movement_id = group
        .get("targetId")
        .and_then(Value::as_str)
        .filter(|id| !id.trim().is_empty())
        .unwrap_or(movement_id);
    let movement = ai_proposed_movement_from_input(
        document,
        &movement_input,
        proposal_id,
        fallback_movement_id,
        group
            .get("id")
            .and_then(Value::as_str)
            .expect("AI atomic group id should be present"),
        now,
    )?;
    let mut edited = atomic_group_from_movement(&movement, "edited");
    edited["title"] = json!(format!(
        "新增：{}",
        movement
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("AI 候选记录")
    ));
    edited["diffs"] = patch.get("diffs").cloned().unwrap_or_else(|| json!([]));
    edited["warnings"] = json!([
        {
            "code": "ai_edit_requires_user_confirmation",
            "message": "编辑后的候选仍需用户接受整组才会写入账本。",
            "severity": "info"
        }
    ]);
    if let Some(source_evidence) = group.get("sourceEvidence") {
        edited["sourceEvidence"] = source_evidence.clone();
    }
    Ok(edited)
}

fn ai_evidence_ref(source_kind: &str, proposal_id: &str, input: &Value) -> Value {
    let mut evidence = json!({
        "id": format!("ev_{proposal_id}"),
        "kind": source_kind,
        "label": ai_source_label(source_kind, input)
    });
    if let Some(preview) = ai_input_preview(input) {
        evidence["preview"] = json!(preview);
    }
    evidence
}

fn ai_source_label(source_kind: &str, input: &Value) -> String {
    if let Some(file_name) = input
        .get("fileName")
        .or_else(|| input.get("filename"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
    {
        return file_name.to_string();
    }

    match source_kind {
        "user_text" => "文本输入".to_string(),
        "user_image" => "图片输入".to_string(),
        "csv_import" => "CSV 导入".to_string(),
        _ => "AI 输入".to_string(),
    }
}

fn ai_input_preview(input: &Value) -> Option<String> {
    let raw = input
        .get("text")
        .or_else(|| input.get("content"))
        .or_else(|| input.get("csv"))
        .and_then(Value::as_str)?
        .trim();
    if raw.is_empty() {
        return None;
    }
    let mut preview = raw.chars().take(80).collect::<String>();
    if raw.chars().count() > 80 {
        preview.push('…');
    }
    Some(preview)
}

fn confirm_ai_movement_atomic_group(
    document: &mut Value,
    atomic_group_id: &str,
    now: &str,
) -> Result<Option<Value>, LedgerError> {
    let Some(group) = find_ai_atomic_group(document, atomic_group_id) else {
        return Ok(None);
    };
    if group.get("operation").and_then(Value::as_str) != Some("create")
        || group.get("targetType").and_then(Value::as_str) != Some("movement")
    {
        return Ok(None);
    }

    match group.get("status").and_then(Value::as_str) {
        Some("pending" | "edited") => {}
        Some("approved") => {
            return Ok(Some(json!({
                "atomicGroupId": atomic_group_id,
                "confirmedMovementIds": [],
                "snapshotInvalidated": false,
                "ledgerWrite": false,
                "devOnly": false
            })));
        }
        Some("rejected") => {
            return Err(LedgerError::Conflict(
                "AI atomic group has already been rejected".to_string(),
            ));
        }
        Some(status) => {
            return Err(LedgerError::Conflict(format!(
                "AI atomic group cannot be confirmed from status: {status}"
            )));
        }
        None => {
            return Err(LedgerError::InvalidInput(vec![
                "atomic group status must be present".to_string(),
            ]));
        }
    }

    let proposed_movements = group
        .get("proposedMovements")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if proposed_movements.is_empty() || !ai_group_validation_is_valid(&group) {
        return Err(LedgerError::InvalidInput(vec![
            "AI movement atomic group must be edited into a valid proposed movement before approval".to_string(),
        ]));
    }

    let existing_ids = document["movements"]
        .as_array()
        .expect("validated local ledger movements should be an array")
        .iter()
        .filter_map(|movement| movement.get("id").and_then(Value::as_str))
        .map(str::to_string)
        .collect::<Vec<_>>();

    let mut confirmed_movement_ids = Vec::new();
    let mut movements_to_append = Vec::new();
    for proposed in proposed_movements {
        let movement_id = proposed
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.trim().is_empty())
            .ok_or_else(|| {
                LedgerError::InvalidInput(vec!["proposed movement id is missing".to_string()])
            })?
            .to_string();
        if existing_ids.iter().any(|id| id == &movement_id)
            || movements_to_append.iter().any(|movement: &Value| {
                movement.get("id").and_then(Value::as_str) == Some(movement_id.as_str())
            })
        {
            return Err(LedgerError::Conflict(format!(
                "movement already exists: {movement_id}"
            )));
        }

        required_movement_entries(&proposed)?;
        apply_movement_effect(document, &proposed, now)?;

        let mut movement = proposed.clone();
        movement["atomicGroupId"] = json!(atomic_group_id);
        movement["status"] = json!(confirmed_status_for_movement(&movement));
        movement["updatedAt"] = json!(now);
        if movement.get("recordedAt").is_none() {
            movement["recordedAt"] = json!(now);
        }
        if movement.get("createdAt").is_none() {
            movement["createdAt"] = json!(now);
        }
        if movement.get("source").is_none() {
            movement["source"] = json!({
                "kind": "ai_proposal",
                "sourceId": atomic_group_id,
                "createdBy": "ai"
            });
        }
        confirmed_movement_ids.push(movement_id);
        movements_to_append.push(movement);
    }

    for movement in &movements_to_append {
        append_movement_with_entries(document, movement)?;
        let movement_id = movement
            .get("id")
            .and_then(Value::as_str)
            .expect("validated AI movement id should be a string");
        let payload = project_movement_for_api(movement);
        append_sync_change(
            document,
            "movement",
            movement_id,
            sync_operation_for_movement(movement),
            &payload,
            now,
        );
    }
    set_ai_atomic_group_status(document, atomic_group_id, "approved")?;

    Ok(Some(json!({
        "atomicGroupId": atomic_group_id,
        "confirmedMovementIds": confirmed_movement_ids,
        "snapshotInvalidated": true,
        "ledgerWrite": true,
        "devOnly": false
    })))
}

fn ai_group_validation_is_valid(group: &Value) -> bool {
    group
        .get("validation")
        .and_then(|validation| validation.get("isValid"))
        .and_then(Value::as_bool)
        .unwrap_or_else(|| {
            group
                .get("proposedMovements")
                .and_then(Value::as_array)
                .is_some_and(|items| !items.is_empty())
        })
}

fn required_movement_entries(movement: &Value) -> Result<Vec<Value>, LedgerError> {
    movement
        .get("entries")
        .and_then(Value::as_array)
        .filter(|entries| !entries.is_empty())
        .cloned()
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec![
                "proposed movement entries must be a non-empty array".to_string(),
            ])
        })
}

fn append_movement_with_entries(document: &mut Value, movement: &Value) -> Result<(), LedgerError> {
    let movement_id = movement
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| LedgerError::InvalidInput(vec!["movement id is missing".to_string()]))?;
    let atomic_group_id = movement
        .get("atomicGroupId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec!["movement atomicGroupId is missing".to_string()])
        })?;

    document["movements"]
        .as_array_mut()
        .expect("validated local ledger movements should be an array")
        .push(movement.clone());

    let movement_entries = document["movementEntries"]
        .as_array_mut()
        .expect("validated local ledger movementEntries should be an array");
    for entry in required_movement_entries(movement)? {
        let mut indexed_entry = entry;
        indexed_entry["movementId"] = json!(movement_id);
        indexed_entry["atomicGroupId"] = json!(atomic_group_id);
        movement_entries.push(indexed_entry);
    }
    Ok(())
}

fn find_ai_proposal_id_for_group(document: &Value, atomic_group_id: &str) -> Option<String> {
    document["aiProposals"]
        .as_array()
        .expect("validated local ledger aiProposals should be an array")
        .iter()
        .find(|proposal| {
            proposal
                .get("atomicGroups")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .any(|group| group.get("id").and_then(Value::as_str) == Some(atomic_group_id))
        })
        .and_then(|proposal| proposal.get("id"))
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn replace_ai_atomic_group(
    document: &mut Value,
    atomic_group_id: &str,
    edited_group: Value,
) -> Result<(), LedgerError> {
    for proposal in document["aiProposals"]
        .as_array_mut()
        .expect("validated local ledger aiProposals should be an array")
    {
        if let Some(groups) = proposal
            .get_mut("atomicGroups")
            .and_then(Value::as_array_mut)
            && let Some(index) = groups
                .iter()
                .position(|group| group.get("id").and_then(Value::as_str) == Some(atomic_group_id))
        {
            groups[index] = edited_group;
            proposal["status"] = json!(proposal_status_from_groups(groups));
            return Ok(());
        }
    }

    Err(LedgerError::NotFound(format!(
        "AI atomic group does not exist: {atomic_group_id}"
    )))
}

fn confirm_counterparty_merge_atomic_group(
    document: &mut Value,
    atomic_group_id: &str,
) -> Result<Option<Value>, LedgerError> {
    let Some(group) = find_ai_atomic_group(document, atomic_group_id) else {
        return Ok(None);
    };
    if group.get("operation").and_then(Value::as_str) != Some("merge")
        || group.get("targetType").and_then(Value::as_str) != Some("counterparty")
    {
        return Ok(None);
    }

    match group.get("status").and_then(Value::as_str) {
        Some("pending" | "edited") => {}
        Some("approved") => {
            return Ok(Some(json!({
                "atomicGroupId": atomic_group_id,
                "confirmedMovementIds": [],
                "snapshotInvalidated": false,
                "ledgerWrite": false,
                "devOnly": false,
                "warnings": [
                    {
                        "code": "counterparty_merge_already_approved",
                        "message": "该对手方合并已确认。",
                        "severity": "info"
                    }
                ]
            })));
        }
        Some(status) => {
            return Err(LedgerError::Conflict(format!(
                "counterparty merge cannot be confirmed from status: {status}"
            )));
        }
        None => {
            return Err(LedgerError::InvalidInput(vec![
                "atomic group status must be present".to_string(),
            ]));
        }
    }

    let source_ids = group
        .get("mergeMeta")
        .and_then(|meta| meta.get("sourceCounterpartyIds"))
        .and_then(string_array)
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec![
                "counterparty merge group must include mergeMeta.sourceCounterpartyIds".to_string(),
            ])
        })?;
    let target_id = group
        .get("mergeMeta")
        .and_then(|meta| meta.get("targetCounterpartyId"))
        .and_then(Value::as_str)
        .or_else(|| source_ids.first().map(String::as_str))
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec![
                "counterparty merge group must include a targetCounterpartyId".to_string(),
            ])
        })?
        .to_string();
    let payload = group
        .get("proposedEntities")
        .and_then(Value::as_array)
        .and_then(|entities| entities.first())
        .and_then(|entity| entity.get("payload"))
        .cloned()
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec![
                "counterparty merge group must include proposedEntities[0].payload".to_string(),
            ])
        })?;

    let counterparties = document["counterparties"]
        .as_array_mut()
        .expect("validated local ledger counterparties should be an array");
    if !counterparties.iter().any(|counterparty| {
        counterparty.get("id").and_then(Value::as_str) == Some(target_id.as_str())
    }) {
        return Err(LedgerError::NotFound(format!(
            "target counterparty does not exist: {target_id}"
        )));
    }

    for counterparty in counterparties.iter_mut() {
        if counterparty.get("id").and_then(Value::as_str) == Some(target_id.as_str()) {
            *counterparty = payload.clone();
            break;
        }
    }
    counterparties.retain(|counterparty| {
        let id = counterparty.get("id").and_then(Value::as_str);
        id == Some(target_id.as_str())
            || !id.is_some_and(|id| source_ids.iter().any(|source_id| source_id == id))
    });

    for movement in document["movements"]
        .as_array_mut()
        .expect("validated local ledger movements should be an array")
    {
        if movement
            .get("counterpartyId")
            .and_then(Value::as_str)
            .is_some_and(|id| id != target_id && source_ids.iter().any(|source_id| source_id == id))
        {
            movement["counterpartyId"] = json!(target_id);
        }
    }

    set_ai_atomic_group_status(document, atomic_group_id, "approved")?;
    Ok(Some(json!({
        "atomicGroupId": atomic_group_id,
        "confirmedMovementIds": [],
        "snapshotInvalidated": false,
        "ledgerWrite": true,
        "mergedCounterpartyId": target_id,
        "devOnly": false
    })))
}

fn reject_ai_atomic_group(
    document: &mut Value,
    atomic_group_id: &str,
) -> Result<bool, LedgerError> {
    let Some(group) = find_ai_atomic_group(document, atomic_group_id) else {
        return Ok(false);
    };
    match group.get("status").and_then(Value::as_str) {
        Some("pending" | "edited") => {
            set_ai_atomic_group_status(document, atomic_group_id, "rejected")?;
            Ok(true)
        }
        Some("rejected") => Ok(true),
        Some(status) => Err(LedgerError::Conflict(format!(
            "AI atomic group cannot be rejected from status: {status}"
        ))),
        None => Err(LedgerError::InvalidInput(vec![
            "atomic group status must be present".to_string(),
        ])),
    }
}

fn find_ai_atomic_group(document: &Value, atomic_group_id: &str) -> Option<Value> {
    document["aiProposals"]
        .as_array()
        .expect("validated local ledger aiProposals should be an array")
        .iter()
        .flat_map(|proposal| {
            proposal
                .get("atomicGroups")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
        })
        .find(|group| group.get("id").and_then(Value::as_str) == Some(atomic_group_id))
        .cloned()
}

fn set_ai_atomic_group_status(
    document: &mut Value,
    atomic_group_id: &str,
    status: &str,
) -> Result<(), LedgerError> {
    let mut found = false;
    for proposal in document["aiProposals"]
        .as_array_mut()
        .expect("validated local ledger aiProposals should be an array")
    {
        let mut proposal_has_group = false;
        if let Some(groups) = proposal
            .get_mut("atomicGroups")
            .and_then(Value::as_array_mut)
        {
            for group in groups {
                if group.get("id").and_then(Value::as_str) == Some(atomic_group_id) {
                    group["status"] = json!(status);
                    found = true;
                    proposal_has_group = true;
                }
            }
        }
        if proposal_has_group {
            proposal["status"] = json!(proposal_status_from_groups(
                proposal
                    .get("atomicGroups")
                    .and_then(Value::as_array)
                    .expect("proposal atomicGroups should remain an array")
            ));
            if status == "approved" || status == "rejected" {
                proposal["reviewedAt"] = json!(
                    OffsetDateTime::now_utc()
                        .format(&Rfc3339)
                        .expect("RFC3339 formatting should succeed")
                );
            }
        }
    }

    if found {
        Ok(())
    } else {
        Err(LedgerError::NotFound(format!(
            "AI atomic group does not exist: {atomic_group_id}"
        )))
    }
}

fn proposal_status_from_groups(groups: &[Value]) -> &'static str {
    let has_pending = groups.iter().any(|group| {
        matches!(
            group.get("status").and_then(Value::as_str),
            Some("pending" | "edited")
        )
    });
    let has_edited = groups
        .iter()
        .any(|group| group.get("status").and_then(Value::as_str) == Some("edited"));
    let has_approved = groups
        .iter()
        .any(|group| group.get("status").and_then(Value::as_str) == Some("approved"));
    let has_rejected = groups
        .iter()
        .any(|group| group.get("status").and_then(Value::as_str) == Some("rejected"));

    if has_pending && (has_approved || has_rejected) {
        "partially_reviewed"
    } else if has_edited {
        "edited"
    } else if has_pending {
        "pending"
    } else if has_approved && has_rejected {
        "partially_reviewed"
    } else if has_approved {
        "approved"
    } else if has_rejected {
        "rejected"
    } else {
        "pending"
    }
}

fn apply_holding_money_delta(
    holding: &mut Value,
    field: &str,
    currency: &str,
    delta: DecimalAmount,
) -> Result<(), LedgerError> {
    let current = holding
        .get(field)
        .and_then(|value| value.get("amount"))
        .and_then(Value::as_str)
        .map(parse_decimal)
        .transpose()
        .map_err(|error| LedgerError::InvalidInput(vec![error.to_string()]))?
        .unwrap_or(DecimalAmount::ZERO);
    let next = current + delta;
    if next < DecimalAmount::ZERO {
        return Err(LedgerError::Conflict(format!(
            "{field} cannot become negative"
        )));
    }
    holding[field] = money(next, currency);
    Ok(())
}

fn apply_holding_valued_money_delta(
    holding: &mut Value,
    field: &str,
    currency: &str,
    delta: DecimalAmount,
    now: &str,
) -> Result<(), LedgerError> {
    let current = holding
        .get(field)
        .and_then(|value| value.get("amount"))
        .and_then(Value::as_str)
        .map(parse_decimal)
        .transpose()
        .map_err(|error| LedgerError::InvalidInput(vec![error.to_string()]))?
        .unwrap_or(DecimalAmount::ZERO);
    let next = current + delta;
    if next < DecimalAmount::ZERO {
        return Err(LedgerError::Conflict(format!(
            "{field} cannot become negative"
        )));
    }
    holding[field] = json!({
        "amount": money_amount(next),
        "currency": currency,
        "asOf": now,
        "quality": "estimated"
    });
    Ok(())
}

fn ensure_instrument(document: &mut Value, instrument_id: &str, currency: &str) {
    let instruments = document["instruments"]
        .as_array_mut()
        .expect("validated local ledger instruments should be an array");
    if instruments
        .iter()
        .any(|instrument| instrument.get("id").and_then(Value::as_str) == Some(instrument_id))
    {
        return;
    }

    instruments.push(json!({
        "id": instrument_id,
        "type": "other",
        "displayName": instrument_id,
        "quoteCurrency": currency
    }));
}

fn stable_holding_id(account_id: &str, instrument_id: &str) -> String {
    fn clean(value: &str) -> String {
        value
            .chars()
            .map(|ch| {
                if ch.is_ascii_alphanumeric() {
                    ch.to_ascii_lowercase()
                } else {
                    '_'
                }
            })
            .collect()
    }

    format!("holding_{}_{}", clean(account_id), clean(instrument_id))
}

fn update_dca_reminder_status(
    document: &mut Value,
    reminder_id: &str,
    status: &str,
    snoozed_until: Option<String>,
    now: &str,
) -> Result<Value, LedgerError> {
    let reminder = document["dcaReminders"]
        .as_array_mut()
        .expect("validated local ledger dcaReminders should be an array")
        .iter_mut()
        .find(|reminder| reminder.get("id").and_then(Value::as_str) == Some(reminder_id))
        .ok_or_else(|| {
            LedgerError::NotFound(format!("DCA reminder does not exist: {reminder_id}"))
        })?;

    reminder["status"] = json!(status);
    reminder["updatedAt"] = json!(now);
    if let Some(until) = snoozed_until {
        reminder["snoozedUntil"] = json!(until);
    } else if let Some(object) = reminder.as_object_mut() {
        object.remove("snoozedUntil");
    }

    let plan_id = reminder
        .get("planId")
        .and_then(Value::as_str)
        .map(str::to_string);
    let projected = reminder.clone();

    if let Some(plan_id) = plan_id
        && let Some(plan) = document["dcaPlans"]
            .as_array_mut()
            .expect("validated local ledger dcaPlans should be an array")
            .iter_mut()
            .find(|plan| plan.get("id").and_then(Value::as_str) == Some(plan_id.as_str()))
    {
        plan["lastActionAt"] = json!(now);
        plan["updatedAt"] = json!(now);
        if status == "snoozed" {
            plan["reminderStatus"] = json!("snoozed");
        }
    }

    Ok(projected)
}

fn validate_string_array(value: Option<&Value>, label: &str, errors: &mut Vec<String>) {
    match value.and_then(string_array) {
        Some(_) => {}
        None => errors.push(format!("{label} must be a string array")),
    }
}

fn string_array(value: &Value) -> Option<Vec<String>> {
    value
        .as_array()?
        .iter()
        .map(|item| {
            item.as_str()
                .filter(|value| !value.is_empty())
                .map(str::to_string)
        })
        .collect::<Option<Vec<_>>>()
}

fn require_array(object: &serde_json::Map<String, Value>, key: &str, errors: &mut Vec<String>) {
    if !object.get(key).is_some_and(Value::is_array) {
        errors.push(format!("{key} must be an array"));
    }
}

fn is_decimal_string(value: &str) -> bool {
    let value = value.strip_prefix(['+', '-']).unwrap_or(value);
    if value.is_empty() {
        return false;
    }

    let mut parts = value.split('.');
    let integer = parts.next().unwrap_or_default();
    let fraction = parts.next();

    if parts.next().is_some() || integer.is_empty() || !integer.chars().all(|c| c.is_ascii_digit())
    {
        return false;
    }

    match fraction {
        Some(value) => {
            !value.is_empty() && value.len() <= 8 && value.chars().all(|c| c.is_ascii_digit())
        }
        None => true,
    }
}

fn is_positive_decimal_string(value: &str) -> bool {
    is_decimal_string(value)
        && DecimalAmount::parse(value).is_ok_and(|amount| amount > DecimalAmount::ZERO)
}

fn contains_fixture_marker(value: &Value) -> bool {
    match value {
        Value::String(value) => {
            let lower = value.to_ascii_lowercase();
            lower == "debug_fixture" || lower == "fixture" || lower == "demo"
        }
        Value::Bool(true) => false,
        Value::Array(items) => items.iter().any(contains_fixture_marker),
        Value::Object(object) => object.iter().any(|(key, value)| {
            let lower_key = key.to_ascii_lowercase();
            lower_key == "isfixture"
                || lower_key == "fixture"
                || lower_key == "demodata"
                || contains_fixture_marker(value)
        }),
        _ => false,
    }
}

fn normalize_path(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .expect("current dir should be readable")
            .join(path)
    }
}

fn invalid_data(error: impl std::error::Error + Send + Sync + 'static) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error)
}

fn validation_error(errors: Vec<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, errors.join("; "))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn empty_document_is_valid_and_contains_no_assets() {
        let document = empty_document(DEFAULT_BASE_CURRENCY);

        validate_document(&document).expect("empty document should validate");
        assert_eq!(document["ledgerVersion"], LEDGER_VERSION);
        assert_eq!(document["baseCurrency"], DEFAULT_BASE_CURRENCY);
        assert_eq!(document["accounts"], json!([]));
        assert_eq!(document["movements"], json!([]));
        assert_eq!(document["subscriptions"], json!([]));
        assert_eq!(document["aiProposals"], json!([]));
    }

    fn valid_dca_document() -> Value {
        let now = "2026-07-16T00:00:00Z";
        let mut document = empty_document(DEFAULT_BASE_CURRENCY);
        let account = account_from_create_input(
            &json!({
                "displayName": "DCA 资金账户",
                "accountType": "brokerage",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "balanceMode": "mixed",
                "openingBalances": [{"currency": "CNY", "amount": "1000.00"}]
            }),
            "acct_dca_validation",
            now,
        )
        .expect("DCA validation account should be valid");
        document["accounts"] = json!([account]);
        document["dcaPlans"] = json!([{
            "id": "plan_dca_validation",
            "displayName": "指数基金定投",
            "targetInstrumentId": "inst_dca_validation",
            "fundingAccountId": "acct_dca_validation",
            "plannedAmount": {"amount": "200.00", "currency": "CNY"},
            "frequency": "monthly",
            "nextDueDate": "2026-08-01",
            "reminderStatus": "active",
            "lastActionAt": null,
            "createdAt": now,
            "updatedAt": now
        }]);
        document["dcaReminders"] = json!([{
            "id": "reminder_dca_validation",
            "planId": "plan_dca_validation",
            "displayName": "指数基金定投",
            "plannedAmount": {"amount": "200.00", "currency": "CNY"},
            "dueDate": "2026-08-01",
            "status": "due"
        }]);
        document
    }

    #[test]
    fn validate_document_rejects_malformed_dca_entities_and_links() {
        validate_document(&valid_dca_document()).expect("valid DCA document should pass");

        let cases: [(&str, &str, fn(&mut Value)); 8] = [
            (
                "duplicate plan id",
                "duplicate DCA plan id",
                |document: &mut Value| {
                    let duplicate = document["dcaPlans"][0].clone();
                    document["dcaPlans"]
                        .as_array_mut()
                        .expect("plans")
                        .push(duplicate);
                },
            ),
            (
                "dangling reminder plan",
                "planId must reference an existing DCA plan",
                |document: &mut Value| {
                    document["dcaReminders"][0]["planId"] = json!("missing_plan");
                },
            ),
            (
                "invalid due date",
                "dueDate must be an ISO date",
                |document: &mut Value| {
                    document["dcaReminders"][0]["dueDate"] = json!("not-a-date");
                },
            ),
            (
                "non-positive plan amount",
                "plannedAmount.amount must be a positive decimal string",
                |document: &mut Value| {
                    document["dcaPlans"][0]["plannedAmount"]["amount"] = json!("0");
                },
            ),
            (
                "open reminder drift",
                "plannedAmount must match its open DCA plan",
                |document: &mut Value| {
                    document["dcaReminders"][0]["plannedAmount"]["amount"] = json!("300.00");
                },
            ),
            (
                "multiple open reminders",
                "more than one open reminder",
                |document: &mut Value| {
                    let mut duplicate = document["dcaReminders"][0].clone();
                    duplicate["id"] = json!("reminder_dca_validation_2");
                    document["dcaReminders"]
                        .as_array_mut()
                        .expect("reminders")
                        .push(duplicate);
                },
            ),
            (
                "snoozed without timestamp",
                "snoozedUntil must be an RFC3339 timestamp",
                |document: &mut Value| {
                    document["dcaReminders"][0]["status"] = json!("snoozed");
                },
            ),
            (
                "recorded without movement",
                "recorded DCA reminder must reference exactly one confirmed movement",
                |document: &mut Value| {
                    document["dcaReminders"][0]["status"] = json!("recorded");
                },
            ),
        ];

        for (label, expected, mutate) in cases {
            let mut document = valid_dca_document();
            mutate(&mut document);
            let errors = validate_document(&document).expect_err(label);
            assert!(
                errors.iter().any(|error| error.contains(expected)),
                "{label}: expected {expected:?}, got {errors:?}"
            );
        }
    }

    #[test]
    fn validate_document_rejects_malformed_core_ledger_entities() {
        let now = "2026-07-15T00:00:00Z";
        let mut document = empty_document(DEFAULT_BASE_CURRENCY);
        let account = account_from_create_input(
            &json!({
                "displayName": "核心校验账户",
                "accountType": "brokerage",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "balanceMode": "holdings",
                "openingBalances": [{"currency": "CNY", "amount": "0.00"}]
            }),
            "acct_core_validation",
            now,
        )
        .expect("account fixture should be valid");
        document["accounts"] = json!([account]);
        document["instruments"] = json!([{
            "id": "inst_core_validation",
            "type": "fund",
            "displayName": "核心校验基金",
            "quoteCurrency": "CNY"
        }]);
        document["holdings"] = json!([{
            "id": "holding_core_validation",
            "accountId": "acct_core_validation",
            "instrumentId": "inst_core_validation",
            "quantity": "10",
            "costBasisTotal": {"amount": "100.00", "currency": "CNY"},
            "marketValue": {
                "amount": "100.00",
                "currency": "CNY",
                "asOf": now,
                "quality": "estimated"
            },
            "quoteStatus": "stale",
            "asOf": now
        }]);
        let mut movement = movement_from_create_input(
            &document,
            &json!({
                "type": "sell",
                "occurredAt": now,
                "title": "核心校验卖出",
                "entries": [
                    {
                        "accountId": "acct_core_validation",
                        "instrumentId": "inst_core_validation",
                        "amount": "1",
                        "currency": "CNY",
                        "direction": "out",
                        "role": "source"
                    },
                    {
                        "accountId": "acct_core_validation",
                        "amount": "10.00",
                        "currency": "CNY",
                        "direction": "in",
                        "role": "destination"
                    }
                ]
            }),
            "movement_core_validation",
            "group_core_validation",
            now,
        )
        .expect("movement fixture should be valid");
        movement["status"] = json!("confirmed");
        document["movementEntries"] = json!(
            movement["entries"]
                .as_array()
                .expect("movement entries")
                .iter()
                .map(|entry| {
                    let mut indexed = entry.clone();
                    indexed["movementId"] = json!("movement_core_validation");
                    indexed["atomicGroupId"] = json!("group_core_validation");
                    indexed
                })
                .collect::<Vec<_>>()
        );
        document["movements"] = json!([movement]);
        validate_document(&document).expect("complete core fixture should validate");

        let mut bad_direction = document.clone();
        bad_direction["movements"][0]["entries"][0]["direction"] = json!("sideways");
        let errors = validate_document(&bad_direction).expect_err("bad direction must fail");
        assert!(errors.iter().any(|error| error.contains("direction")));

        let mut negative_holding = document.clone();
        negative_holding["holdings"][0]["quantity"] = json!("-1");
        let errors = validate_document(&negative_holding).expect_err("negative holding must fail");
        assert!(errors.iter().any(|error| error.contains("quantity")));

        let mut missing_instrument = document.clone();
        missing_instrument["holdings"][0]["instrumentId"] = json!("inst_missing");
        let errors =
            validate_document(&missing_instrument).expect_err("missing instrument must fail");
        assert!(errors.iter().any(|error| error.contains("instrumentId")));

        let mut duplicate_instrument = document.clone();
        duplicate_instrument["instruments"] = json!([
            document["instruments"][0].clone(),
            document["instruments"][0].clone()
        ]);
        let errors =
            validate_document(&duplicate_instrument).expect_err("duplicate instrument must fail");
        assert!(
            errors
                .iter()
                .any(|error| error.contains("duplicate instrument id"))
        );

        let mut broken_index = document;
        broken_index["movementEntries"][0]["movementId"] = json!("movement_missing");
        let errors = validate_document(&broken_index).expect_err("broken entry index must fail");
        assert!(errors.iter().any(|error| error.contains("movementId")));
    }

    #[test]
    fn validate_document_rejects_broken_subscription_pending_links() {
        let now = "2026-07-13T00:00:00Z";
        let mut document = empty_document(DEFAULT_BASE_CURRENCY);
        let account = account_from_create_input(
            &json!({
                "displayName": "USD card",
                "accountType": "virtual_card",
                "defaultCurrency": "USD",
                "supportedCurrencies": ["USD"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [{"currency": "USD", "amount": "100.00"}]
            }),
            "acct_subscription",
            now,
        )
        .expect("account fixture should be valid");
        document["accounts"] = json!([account]);
        let mut subscription = subscription_from_create_input(
            &document,
            &json!({
                "displayName": "GPT Plus",
                "provider": "OpenAI",
                "amount": {"amount": "20.00", "currency": "USD"},
                "paymentAccountId": "acct_subscription",
                "billingCycle": {"unit": "month", "interval": 1},
                "startDate": "2026-07-13"
            }),
            "subscription_1",
            now,
        )
        .expect("subscription fixture should be valid");
        subscription["pendingChargeMovementId"] = json!("movement_subscription_1");
        subscription["pendingChargeDate"] = json!("2026-07-13");
        document["subscriptions"] = json!([subscription]);
        let mut movement = movement_from_create_input(
            &document,
            &json!({
                "type": "expense",
                "occurredAt": now,
                "title": "GPT Plus charge",
                "entries": [{
                    "accountId": "acct_subscription",
                    "amount": "20.00",
                    "currency": "USD",
                    "direction": "out",
                    "role": "source"
                }]
            }),
            "movement_subscription_1",
            "group_subscription_1",
            now,
        )
        .expect("subscription movement fixture should be valid");
        movement["status"] = json!("pending_review");
        movement["subscriptionId"] = json!("subscription_1");
        movement["scheduledChargeDate"] = json!("2026-07-13");
        document["movementEntries"] = json!(
            movement["entries"]
                .as_array()
                .expect("movement entries")
                .iter()
                .map(|entry| {
                    let mut indexed = entry.clone();
                    indexed["movementId"] = json!("movement_subscription_1");
                    indexed["atomicGroupId"] = json!("group_subscription_1");
                    indexed
                })
                .collect::<Vec<_>>()
        );
        document["movements"] = json!([movement]);
        validate_document(&document).expect("matching pending link should validate");

        let mut missing = document.clone();
        missing["movements"] = json!([]);
        let errors = validate_document(&missing).expect_err("missing movement must fail");
        assert!(
            errors
                .iter()
                .any(|error| error.contains("must reference an existing movement"))
        );

        let mut wrong_status = document.clone();
        wrong_status["movements"][0]["status"] = json!("confirmed");
        let errors = validate_document(&wrong_status).expect_err("wrong status must fail");
        assert!(
            errors
                .iter()
                .any(|error| error.contains("must reference a pending_review movement"))
        );

        let mut wrong_subscription = document.clone();
        wrong_subscription["movements"][0]["subscriptionId"] = json!("subscription_other");
        let errors =
            validate_document(&wrong_subscription).expect_err("wrong subscription must fail");
        assert!(
            errors
                .iter()
                .any(|error| error.contains("must reference the same subscription"))
        );

        let mut wrong_date = document.clone();
        wrong_date["movements"][0]["scheduledChargeDate"] = json!("2026-07-14");
        let errors = validate_document(&wrong_date).expect_err("wrong charge date must fail");
        assert!(
            errors
                .iter()
                .any(|error| error.contains("must match movement.scheduledChargeDate"))
        );

        let mut wrong_pointer_types = document.clone();
        wrong_pointer_types["subscriptions"][0]["pendingChargeMovementId"] = json!(123);
        wrong_pointer_types["subscriptions"][0]["pendingChargeDate"] = json!(false);
        let errors = validate_document(&wrong_pointer_types)
            .expect_err("non-string pending pointers must fail");
        assert!(
            errors.iter().any(|error| {
                error.contains("pendingChargeMovementId must be a non-empty string")
            })
        );
        assert!(
            errors
                .iter()
                .any(|error| error.contains("pendingChargeDate must be a non-empty string"))
        );

        let mut wrong_movement_types = document.clone();
        wrong_movement_types["movements"][0]["subscriptionId"] = json!(123);
        let errors = validate_document(&wrong_movement_types)
            .expect_err("non-string movement subscriptionId must fail");
        assert!(errors.iter().any(|error| {
            error.contains("movements[0].subscriptionId must be a non-empty string")
        }));

        let mut missing_group = document.clone();
        missing_group["movements"][0]["atomicGroupId"] = Value::Null;
        let errors = validate_document(&missing_group).expect_err("missing atomic group must fail");
        assert!(errors.iter().any(|error| {
            error.contains("movements[0].atomicGroupId must be a non-empty string")
        }));

        let mut orphan = document;
        orphan["subscriptions"][0]
            .as_object_mut()
            .expect("subscription should be an object")
            .remove("pendingChargeMovementId");
        orphan["subscriptions"][0]
            .as_object_mut()
            .expect("subscription should be an object")
            .remove("pendingChargeDate");
        let errors = validate_document(&orphan).expect_err("orphan movement must fail");
        assert!(errors.iter().any(|error| {
            error
                .contains("pending subscription charge must match the subscription pending pointer")
        }));
    }

    #[test]
    fn subscription_due_scan_input_defaults_and_rejects_out_of_range_limits() {
        assert_eq!(
            parse_subscription_due_scan_input(&json!({"throughDate": "2026-07-13"}))
                .expect("default limit should parse"),
            ("2026-07-13".to_string(), 100)
        );
        assert!(
            parse_subscription_due_scan_input(&json!({"throughDate": "2026-07-13", "limit": 200}))
                .is_ok()
        );
        for invalid in [
            json!({"throughDate": "2026-07-13", "limit": null}),
            json!({"throughDate": "2026-07-13", "limit": -1}),
            json!({"throughDate": "2026-07-13", "limit": 201}),
        ] {
            assert!(parse_subscription_due_scan_input(&invalid).is_err());
        }
    }

    #[test]
    fn standalone_pending_ai_projection_groups_movements_by_atomic_group() {
        let now = "2026-07-13T00:00:00Z";
        let mut document = empty_document(DEFAULT_BASE_CURRENCY);
        let account = account_from_create_input(
            &json!({
                "displayName": "Review account",
                "accountType": "bank",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [{"currency": "CNY", "amount": "100.00"}]
            }),
            "acct_review",
            now,
        )
        .expect("account fixture should be valid");
        document["accounts"] = json!([account]);

        let mut movement_b = movement_from_create_input(
            &document,
            &json!({
                "type": "expense",
                "occurredAt": now,
                "title": "Second movement",
                "entries": [{
                    "accountId": "acct_review",
                    "amount": "2.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                }]
            }),
            "movement_b",
            "group_shared",
            now,
        )
        .expect("movement fixture should be valid");
        movement_b["status"] = json!("pending_review");
        let mut movement_a = movement_from_create_input(
            &document,
            &json!({
                "type": "expense",
                "occurredAt": now,
                "title": "First movement",
                "entries": [{
                    "accountId": "acct_review",
                    "amount": "1.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                }]
            }),
            "movement_a",
            "group_shared",
            now,
        )
        .expect("movement fixture should be valid");
        movement_a["status"] = json!("pending_review");
        document["movements"] = json!([movement_b, movement_a]);

        let proposals = pending_ai_proposals_for_document(&document);
        assert_eq!(pending_ai_proposal_count(&document), 1);
        assert_eq!(proposals.len(), 1);
        assert_eq!(proposals[0]["id"], "proposal_movement_movement_a");
        assert_eq!(proposals[0]["atomicGroups"][0]["id"], "group_shared");
        assert_eq!(
            proposals[0]["atomicGroups"][0]["proposedMovements"]
                .as_array()
                .expect("proposed movements should be an array")
                .len(),
            2
        );
        assert_eq!(
            proposals[0]["atomicGroups"][0]["proposedMovements"][0]["id"],
            "movement_a"
        );
        assert_eq!(
            proposals[0]["atomicGroups"][0]["proposedMovements"][1]["id"],
            "movement_b"
        );
    }

    #[test]
    fn load_or_initialize_creates_empty_real_local_file() {
        let path = unique_temp_path("initialize");

        let document = load_or_initialize(&path).expect("ledger should initialize");
        assert!(path.exists());
        assert_eq!(document["accounts"], json!([]));

        let loaded = read_document(&path).expect("ledger should read after initialization");
        assert_eq!(loaded["baseCurrency"], DEFAULT_BASE_CURRENCY);

        let _ = fs::remove_file(path);
    }

    #[test]
    fn runtime_reads_and_writes_do_not_recreate_a_missing_primary_ledger() {
        let path = unique_temp_path("runtime_missing_primary");
        load_or_initialize(&path).expect("ledger should initialize once at startup");
        fs::remove_file(&path).expect("test should simulate a missing runtime ledger");

        let read_error = list_accounts(&path).expect_err("runtime read must fail closed");
        assert_eq!(read_error.kind(), io::ErrorKind::NotFound);
        assert!(!path.exists());

        let request = IdempotencyRequest::new(
            "key-hash".to_string(),
            "request-hash".to_string(),
            "POST /v1/accounts".to_string(),
            "2026-07-13T00:00:00Z".to_string(),
            "2026-08-12T00:00:00Z".to_string(),
        );
        let write_error = create_account(
            &path,
            json!({
                "displayName": "Must not be created",
                "accountType": "bank",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": []
            }),
            "acct_missing_ledger",
            "2026-07-13T00:00:00Z",
            &request,
        )
        .expect_err("runtime write must fail closed");
        match write_error {
            LedgerError::Io(error) => assert_eq!(error.kind(), io::ErrorKind::NotFound),
            other => panic!("expected missing-ledger IO error, got {other:?}"),
        }
        assert!(!path.exists());
    }

    #[test]
    fn load_or_initialize_recovers_valid_temp_when_primary_is_missing() {
        let path = unique_temp_path("recover_valid_temp");
        let tmp_path = path.with_extension("json.tmp");
        let document = empty_document("USD");
        if let Some(parent) = tmp_path.parent() {
            fs::create_dir_all(parent).expect("temp parent should exist");
        }
        let original =
            serde_json::to_vec_pretty(&document).expect("recovery ledger should serialize");
        fs::write(&tmp_path, &original).expect("recovery temp should write");

        let recovered = load_or_initialize(&path).expect("valid recovery temp should promote");

        assert_eq!(recovered["baseCurrency"], "USD");
        assert!(path.exists());
        assert!(!tmp_path.exists());
        assert_eq!(
            fs::read(&path).expect("promoted primary bytes should be readable"),
            original,
            "recovery must promote the validated temp byte-for-byte"
        );
        assert_eq!(
            read_document(&path).expect("promoted ledger should read")["baseCurrency"],
            "USD"
        );

        let _ = fs::remove_file(path);
    }

    #[test]
    fn load_or_initialize_preserves_unsupported_or_incomplete_recovery_temp() {
        for case in ["future", "missing_cursor"] {
            let path = unique_temp_path(&format!("reject_recovery_{case}"));
            let tmp_path = path.with_extension("json.tmp");
            let mut document = empty_document(DEFAULT_BASE_CURRENCY);
            if case == "future" {
                document["ledgerVersion"] = json!(LEDGER_VERSION + 1);
            } else {
                document["syncState"]
                    .as_object_mut()
                    .expect("syncState should be an object")
                    .remove("cursor");
            }
            fs::create_dir_all(tmp_path.parent().expect("temp should have a parent"))
                .expect("temp parent should exist");
            let original =
                serde_json::to_vec_pretty(&document).expect("recovery temp should serialize");
            fs::write(&tmp_path, &original).expect("recovery temp should write");

            let error =
                load_or_initialize(&path).expect_err("unsupported recovery temp must fail closed");
            assert_eq!(error.kind(), io::ErrorKind::InvalidData, "case {case}");
            assert!(!path.exists());
            assert!(tmp_path.exists());
            assert_eq!(
                fs::read(&tmp_path).expect("recovery temp bytes should remain readable"),
                original
            );
            let _ = fs::remove_file(tmp_path);
        }
    }

    #[test]
    fn existing_primary_is_never_replaced_by_a_stale_recovery_temp() {
        let path = unique_temp_path("ignore_stale_temp");
        let tmp_path = path.with_extension("json.tmp");
        let primary = empty_document("CNY");
        write_document(&path, &primary).expect("primary ledger should write");
        let stale = empty_document("USD");
        let stale_bytes = serde_json::to_vec_pretty(&stale).expect("stale temp should serialize");
        fs::write(&tmp_path, &stale_bytes).expect("stale temp should write");

        let loaded = load_or_initialize(&path).expect("existing primary should win");

        assert_eq!(loaded["baseCurrency"], "CNY");
        assert_eq!(
            read_document(&path).expect("primary should remain readable")["baseCurrency"],
            "CNY"
        );
        assert_eq!(
            fs::read(&tmp_path).expect("stale temp should remain untouched"),
            stale_bytes
        );
        let _ = fs::remove_file(path);
        let _ = fs::remove_file(tmp_path);
    }

    #[test]
    fn load_or_initialize_preserves_invalid_temp_instead_of_creating_empty_ledger() {
        let path = unique_temp_path("reject_invalid_temp");
        let tmp_path = path.with_extension("json.tmp");
        if let Some(parent) = tmp_path.parent() {
            fs::create_dir_all(parent).expect("temp parent should exist");
        }
        fs::write(&tmp_path, b"{partial").expect("invalid recovery temp should write");

        let error = load_or_initialize(&path).expect_err("invalid recovery temp must fail closed");

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(error.to_string().contains("recovery temp is invalid"));
        assert!(!path.exists());
        assert!(tmp_path.exists());

        let _ = fs::remove_file(tmp_path);
    }

    #[test]
    fn read_document_applies_narrow_v1_compatibility_without_rewriting() {
        let path = unique_temp_path("narrow_v1_read_compatibility");
        let mut document = empty_document(DEFAULT_BASE_CURRENCY);
        let object = document
            .as_object_mut()
            .expect("ledger should be an object");
        object.remove("idempotencyState");
        object.remove("subscriptions");
        object.remove("syncChanges");
        object["syncState"]
            .as_object_mut()
            .expect("syncState should be an object")
            .remove("nextChangeSequence");
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("legacy ledger directory should exist");
        }
        let original =
            serde_json::to_vec_pretty(&document).expect("legacy ledger should serialize");
        fs::write(&path, &original).expect("legacy ledger should write");

        let loaded = read_document(&path).expect("legacy ledger should normalize on read");
        assert_eq!(loaded["idempotencyState"]["version"], 1);
        assert_eq!(loaded["idempotencyState"]["records"], json!({}));
        assert_eq!(loaded["subscriptions"], json!([]));
        assert_eq!(loaded["syncChanges"], json!([]));
        assert_eq!(loaded["syncState"]["nextChangeSequence"], 1);
        assert_eq!(loaded["migrations"], json!([]));
        assert_eq!(
            validate_supported_ledger(&path)
                .expect("offline validation should accept the supported v1 profile"),
            loaded
        );
        assert_eq!(
            fs::read(&path).expect("legacy ledger bytes should remain readable"),
            original,
            "ordinary reads must not rewrite compatibility fields or migration history"
        );

        let _ = fs::remove_file(path);
    }

    #[test]
    fn read_document_fails_closed_when_required_sync_state_is_missing() {
        for missing in ["syncState", "cursor", "pendingChangeIds"] {
            let path = unique_temp_path(&format!("missing_{missing}"));
            let mut document = empty_document(DEFAULT_BASE_CURRENCY);
            if missing == "syncState" {
                document
                    .as_object_mut()
                    .expect("ledger should be an object")
                    .remove("syncState");
            } else {
                document["syncState"]
                    .as_object_mut()
                    .expect("syncState should be an object")
                    .remove(missing);
            }
            let original =
                serde_json::to_vec_pretty(&document).expect("invalid ledger should serialize");
            fs::create_dir_all(path.parent().expect("temp ledger should have a parent"))
                .expect("temp ledger parent should exist");
            fs::write(&path, &original).expect("invalid ledger should write");

            let error = read_document(&path).expect_err("missing sync state must fail closed");
            assert_eq!(
                error.kind(),
                io::ErrorKind::InvalidData,
                "missing {missing}"
            );
            assert!(
                error.to_string().contains("syncState"),
                "unexpected error for missing {missing}: {error}"
            );
            assert_eq!(
                fs::read(&path).expect("invalid ledger bytes should remain readable"),
                original
            );
            let _ = fs::remove_file(path);
        }
    }

    #[test]
    fn read_document_rejects_invalid_or_unsupported_versions_without_rewriting() {
        for (label, version) in [
            ("missing", None),
            ("string", Some(json!("1"))),
            ("zero", Some(json!(0))),
            ("future", Some(json!(LEDGER_VERSION + 1))),
        ] {
            let path = unique_temp_path(&format!("ledger_version_{label}"));
            let mut document = empty_document(DEFAULT_BASE_CURRENCY);
            match version {
                Some(version) => document["ledgerVersion"] = version,
                None => {
                    document
                        .as_object_mut()
                        .expect("ledger should be an object")
                        .remove("ledgerVersion");
                }
            }
            let original =
                serde_json::to_vec_pretty(&document).expect("invalid ledger should serialize");
            fs::create_dir_all(path.parent().expect("temp ledger should have a parent"))
                .expect("temp ledger parent should exist");
            fs::write(&path, &original).expect("invalid ledger should write");

            let error = read_document(&path).expect_err("invalid version must fail closed");
            assert_eq!(error.kind(), io::ErrorKind::InvalidData, "case {label}");
            assert!(error.to_string().contains("ledgerVersion"), "{error}");
            let validation_error = validate_supported_ledger(&path)
                .expect_err("offline validation must also reject unsupported versions");
            assert_eq!(
                validation_error.kind(),
                io::ErrorKind::InvalidData,
                "case {label}"
            );
            assert_eq!(
                fs::read(&path).expect("invalid ledger bytes should remain readable"),
                original
            );
            let _ = fs::remove_file(path);
        }
    }

    #[test]
    fn write_document_rejects_debug_fixture_markers() {
        let path = unique_temp_path("fixture_reject");
        let mut document = empty_document(DEFAULT_BASE_CURRENCY);
        document["metadata"]["dataSourceMode"] = json!("debug_fixture");

        let error = write_document(&path, &document).expect_err("fixture marker must fail");
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(!path.exists());
    }

    #[test]
    fn validate_document_rejects_invalid_decimal_string() {
        let mut document = empty_document(DEFAULT_BASE_CURRENCY);
        document["accounts"] = json!([
            {
                "id": "acct_bad",
                "displayName": "Bad Account",
                "accountType": "bank",
                "defaultCurrency": "CNY",
                "cashBalances": [
                    {
                        "currency": "CNY",
                        "amount": "12.3.4"
                    }
                ]
            }
        ]);

        let errors = validate_document(&document).expect_err("invalid decimal should fail");
        assert!(errors.iter().any(|error| error.contains("decimal string")));
    }

    #[test]
    fn real_and_fixture_paths_must_be_separate() {
        let real = Path::new("ledger.json");
        let fixture = Path::new("ledger.fixture.json");

        ensure_real_and_fixture_paths_separate(real, fixture).expect("separate paths should pass");

        let error =
            ensure_real_and_fixture_paths_separate(real, real).expect_err("same path should fail");
        assert!(error.contains("must not be the same"));

        let error = ensure_real_and_fixture_paths_separate(fixture, real)
            .expect_err("real path must not look like fixture");
        assert!(error.contains("must not look like"));
    }

    #[test]
    fn next_sync_change_id_recovers_from_regressed_sequence() {
        let mut document = empty_document(DEFAULT_BASE_CURRENCY);
        document["syncChanges"] = json!([
            {"id": "local_change_000007"},
            {"id": "local_change_000042"}
        ]);
        document["syncState"]["nextChangeSequence"] = json!(2);

        let change_id = next_sync_change_id(&mut document);

        assert_eq!(change_id, "local_change_000043");
        assert_eq!(document["syncState"]["nextChangeSequence"], 44);
    }

    #[test]
    fn validate_document_rejects_duplicate_sync_ids_and_dangling_pending_ids() {
        let mut document = empty_document(DEFAULT_BASE_CURRENCY);
        document["syncChanges"] = json!([
            {
                "id": "local_change_000001",
                "deviceId": LOCAL_SYNC_DEVICE_ID,
                "entityType": "account",
                "entityId": "acct_1",
                "operation": "create",
                "payload": {},
                "createdAt": "2026-07-10T00:00:00Z"
            },
            {
                "id": "local_change_000001",
                "deviceId": LOCAL_SYNC_DEVICE_ID,
                "entityType": "account",
                "entityId": "acct_2",
                "operation": "update",
                "payload": {},
                "createdAt": "2026-07-10T00:01:00Z"
            }
        ]);
        document["syncState"]["cursor"] = json!("local_change_000001");
        document["syncState"]["pendingChangeIds"] = json!([
            "local_change_000001",
            "local_change_000001",
            "local_change_000099"
        ]);

        let errors = validate_document(&document).expect_err("invalid sync state must fail");
        assert!(
            errors
                .iter()
                .any(|error| error.contains("duplicate sync change id"))
        );
        assert!(
            errors
                .iter()
                .any(|error| error.contains("must not contain duplicates"))
        );
        assert!(
            errors
                .iter()
                .any(|error| error.contains("unknown sync change id"))
        );
    }

    #[test]
    fn validate_document_requires_cursor_to_match_ordered_sync_log_tail() {
        let mut document = empty_document(DEFAULT_BASE_CURRENCY);
        document["syncChanges"] = json!([
            {
                "id": "local_change_000002",
                "deviceId": LOCAL_SYNC_DEVICE_ID,
                "entityType": "account",
                "entityId": "acct_2",
                "operation": "create",
                "payload": {},
                "createdAt": "2026-07-10T00:00:00Z"
            },
            {
                "id": "local_change_000001",
                "deviceId": LOCAL_SYNC_DEVICE_ID,
                "entityType": "account",
                "entityId": "acct_1",
                "operation": "create",
                "payload": {},
                "createdAt": "2026-07-10T00:01:00Z"
            }
        ]);
        document["syncState"]["cursor"] = json!("local_change_000002");
        document["syncState"]["nextChangeSequence"] = json!(1);

        let errors = validate_document(&document).expect_err("invalid sync order must fail");
        assert!(
            errors
                .iter()
                .any(|error| error.contains("strictly increasing"))
        );
        assert!(
            errors
                .iter()
                .any(|error| error.contains("must equal the last sync change id"))
        );
        assert!(
            !errors
                .iter()
                .any(|error| error.contains("nextChangeSequence must exceed"))
        );
    }

    #[test]
    fn validate_document_rejects_duplicate_remote_source_change() {
        let mut document = empty_document(DEFAULT_BASE_CURRENCY);
        document["syncChanges"] = json!([
            {
                "id": "local_change_000001",
                "deviceId": "remote_device",
                "sourceDeviceId": "remote_device",
                "sourceChangeId": "remote_change_1",
                "entityType": "account",
                "entityId": "acct_1",
                "operation": "create",
                "payload": {},
                "createdAt": "2026-07-10T00:00:00Z",
                "receivedAt": "2026-07-10T00:00:01Z"
            },
            {
                "id": "local_change_000002",
                "deviceId": "remote_device",
                "sourceDeviceId": "remote_device",
                "sourceChangeId": "remote_change_1",
                "entityType": "account",
                "entityId": "acct_1",
                "operation": "update",
                "payload": {},
                "createdAt": "2026-07-10T00:01:00Z",
                "receivedAt": "2026-07-10T00:01:01Z"
            }
        ]);
        document["syncState"]["cursor"] = json!("local_change_000002");

        let errors = validate_document(&document).expect_err("duplicate source must fail");
        assert!(
            errors
                .iter()
                .any(|error| error.contains("duplicate sourceDeviceId/sourceChangeId"))
        );
    }

    #[test]
    fn investment_sale_result_requires_conserved_realized_pnl() {
        let mut movement = json!({
            "type": "sell",
            "status": "confirmed",
            "saleResult": {
                "costBasisMethod": "average_cost",
                "grossProceeds": {"amount": "40.00", "currency": "CNY"},
                "feeAndTaxTotal": {"amount": "2.00", "currency": "CNY"},
                "netProceeds": {"amount": "38.00", "currency": "CNY"},
                "costBasisReleased": {"amount": "41.20", "currency": "CNY"},
                "realizedPnl": {"amount": "-3.20", "currency": "CNY"},
                "realizedPnlStatus": "calculated"
            }
        });
        let mut errors = Vec::new();
        validate_investment_sale_result(
            movement.as_object().expect("movement object"),
            0,
            &mut errors,
        );
        assert!(errors.is_empty(), "{errors:?}");

        movement["saleResult"]["realizedPnl"]["amount"] = json!("3.20");
        let mut errors = Vec::new();
        validate_investment_sale_result(
            movement.as_object().expect("movement object"),
            0,
            &mut errors,
        );
        assert!(errors.iter().any(|error| {
            error.contains("realizedPnl must equal net proceeds minus released cost basis")
        }));
    }

    #[test]
    fn investment_sale_result_never_subtracts_mismatched_currencies() {
        let now = "2026-07-16T00:00:00Z";
        let mut document = empty_document(DEFAULT_BASE_CURRENCY);
        document["accounts"] = json!([
            account_from_create_input(
                &json!({
                    "displayName": "人民币资金",
                    "accountType": "bank",
                    "defaultCurrency": "CNY",
                    "supportedCurrencies": ["CNY"],
                    "includeInNetWorth": true,
                    "balanceMode": "cash_balance",
                    "openingBalances": [{"currency": "CNY", "amount": "0.00"}]
                }),
                "acct_sale_cash",
                now,
            )
            .expect("cash account"),
            account_from_create_input(
                &json!({
                    "displayName": "跨币种持仓",
                    "accountType": "brokerage",
                    "defaultCurrency": "CNY",
                    "supportedCurrencies": ["CNY"],
                    "includeInNetWorth": true,
                    "balanceMode": "holdings",
                    "openingBalances": []
                }),
                "acct_sale_holding",
                now,
            )
            .expect("holding account")
        ]);
        document["instruments"] = json!([{
            "id": "inst_sale_fx",
            "type": "fund",
            "displayName": "跨币种基金",
            "quoteCurrency": "CNY"
        }]);
        document["holdings"] = json!([{
            "id": "holding_sale_fx",
            "accountId": "acct_sale_holding",
            "instrumentId": "inst_sale_fx",
            "quantity": "10",
            "costBasisTotal": {"amount": "100.00", "currency": "USD"},
            "marketValue": {
                "amount": "100.00",
                "currency": "USD",
                "asOf": now,
                "quality": "estimated"
            },
            "quoteStatus": "stale",
            "asOf": now
        }]);
        let movement = json!({
            "id": "mov_sale_fx",
            "type": "sell",
            "occurredAt": "2026-07-16T00:00:00Z",
            "entries": [
                {
                    "accountId": "acct_sale_holding",
                    "instrumentId": "inst_sale_fx",
                    "amount": "4",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": "acct_sale_cash",
                    "amount": "50.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                }
            ]
        });
        document["movements"] = json!([movement.clone()]);
        apply_buy_or_sell_movement(
            &mut document,
            &movement,
            movement["entries"].as_array().expect("entries"),
            false,
            now,
        )
        .expect("cross-currency sale should apply without fake PnL");

        let result = &document["movements"][0]["saleResult"];
        assert_eq!(result["costBasisReleased"]["amount"], "40.00");
        assert_eq!(result["costBasisReleased"]["currency"], "USD");
        assert_eq!(result["netProceeds"]["currency"], "CNY");
        assert_eq!(result["realizedPnlStatus"], "currency_mismatch");
        assert!(result.get("realizedPnl").is_none());

        document["fxRates"] = json!([
            {
                "id": "fx_cny_usd_historical",
                "baseCurrency": "CNY",
                "quoteCurrency": "USD",
                "rate": "1",
                "asOf": "2026-07-15T00:00:00Z",
                "source": "historical_test",
                "status": "stale"
            },
            {
                "id": "fx_cny_usd_future",
                "baseCurrency": "CNY",
                "quoteCurrency": "USD",
                "rate": "2",
                "asOf": "2026-07-17T00:00:00Z",
                "source": "future_test",
                "status": "fresh"
            }
        ]);
        let historical_movement = json!({
            "id": "mov_sale_fx_historical",
            "type": "sell",
            "occurredAt": "2026-07-16T00:00:00Z",
            "entries": [
                {
                    "accountId": "acct_sale_holding",
                    "instrumentId": "inst_sale_fx",
                    "amount": "1",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": "acct_sale_cash",
                    "amount": "10.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                }
            ]
        });
        document["movements"]
            .as_array_mut()
            .expect("movements")
            .push(historical_movement.clone());
        apply_buy_or_sell_movement(
            &mut document,
            &historical_movement,
            historical_movement["entries"]
                .as_array()
                .expect("historical entries"),
            false,
            now,
        )
        .expect("historical FX sale should calculate PnL");
        let historical_result = &document["movements"][1]["saleResult"];
        assert_eq!(historical_result["realizedPnlStatus"], "calculated_with_fx");
        assert_eq!(
            historical_result["netProceedsInCostBasisCurrency"],
            json!({"amount": "10.00", "currency": "USD"})
        );
        assert_eq!(
            historical_result["realizedPnl"],
            json!({"amount": "0.00", "currency": "USD"})
        );
        assert_eq!(
            historical_result["fxBasis"]["sourceRateId"],
            "fx_cny_usd_historical"
        );
        assert_eq!(historical_result["fxBasis"]["rate"], "1");

        let historical_buy = json!({
            "id": "mov_buy_fx_historical",
            "type": "buy",
            "occurredAt": "2026-07-16T00:00:00Z",
            "entries": [
                {
                    "accountId": "acct_sale_cash",
                    "amount": "10.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": "acct_sale_holding",
                    "instrumentId": "inst_sale_fx",
                    "amount": "1",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                }
            ]
        });
        document["movements"]
            .as_array_mut()
            .expect("movements")
            .push(historical_buy.clone());
        apply_buy_or_sell_movement(
            &mut document,
            &historical_buy,
            historical_buy["entries"].as_array().expect("buy entries"),
            true,
            now,
        )
        .expect("historical FX buy should preserve its basis");
        assert_eq!(document["holdings"][0]["quantity"], "6");
        assert_eq!(
            document["holdings"][0]["costBasisTotal"],
            json!({"amount": "60.00", "currency": "USD"})
        );
        assert_eq!(
            document["movements"][2]["costBasisFx"]["sourceRateId"],
            "fx_cny_usd_historical"
        );
    }

    #[test]
    fn money_amount_preserves_up_to_eight_decimal_places() {
        assert_eq!(
            money_amount(parse_decimal("100").expect("integer")),
            "100.00"
        );
        assert_eq!(
            money_amount(parse_decimal("1.23000000").expect("two decimals")),
            "1.23"
        );
        assert_eq!(
            money_amount(parse_decimal("0.00000001").expect("satoshi")),
            "0.00000001"
        );
        assert_eq!(
            money_amount(parse_decimal("-2.34567890").expect("signed precision")),
            "-2.3456789"
        );
    }

    #[test]
    fn fx_history_rejects_duplicate_ids_and_identity_changes() {
        let rate = json!({
            "id": "fx_history_1",
            "baseCurrency": "USD",
            "quoteCurrency": "CNY",
            "rate": "7.00",
            "asOf": "2026-07-01T00:00:00Z",
            "source": "test",
            "status": "stale"
        });
        let mut document = empty_document(DEFAULT_BASE_CURRENCY);
        document["fxRates"] = json!([rate.clone(), rate.clone()]);
        let errors = validate_document(&document).expect_err("duplicate FX ids must fail");
        assert!(
            errors
                .iter()
                .any(|error| error.contains("duplicate FX rate id"))
        );
        assert!(
            errors
                .iter()
                .any(|error| error.contains("duplicate FX rate time point"))
        );

        document["fxRates"] = json!([rate]);
        let changed_identity = json!({
            "id": "fx_history_1",
            "baseCurrency": "USD",
            "quoteCurrency": "CNY",
            "rate": "7.10",
            "asOf": "2026-07-02T00:00:00Z",
            "source": "test",
            "status": "fresh"
        });
        let error = upsert_fx_rate(&mut document, changed_identity)
            .expect_err("same FX id cannot change its time point");
        assert!(error.contains("cannot change asOf"));

        let duplicate_time = json!({
            "id": "fx_history_other_id",
            "baseCurrency": "USD",
            "quoteCurrency": "CNY",
            "rate": "7.20",
            "asOf": "2026-07-01T00:00:00Z",
            "source": "test",
            "status": "fresh"
        });
        let error = upsert_fx_rate(&mut document, duplicate_time)
            .expect_err("same pair/time cannot use another id");
        assert!(error.contains("pair/asOf already exists"));
    }

    fn unique_temp_path(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be after unix epoch")
            .as_nanos();
        std::env::temp_dir()
            .join(format!("finwealth_local_ledger_{label}_{nanos}"))
            .join("ledger.json")
    }
}
