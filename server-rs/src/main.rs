use argon2::{
    Argon2,
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
};
use axum::{
    Json, Router,
    extract::{Json as JsonExtractor, Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{any, get, patch, post},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
mod local_ledger;

use rand_core::{OsRng, RngCore};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    env,
    io::{self, Read},
    net::SocketAddr,
    path::{Path as FsPath, PathBuf},
    process,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};
use time::{
    Date, Duration, OffsetDateTime,
    format_description::well_known::{Iso8601, Rfc3339},
};
use yahoo_finance_api as yahoo;

const EMPTY_BOOTSTRAP: &str =
    include_str!("../../docs/contracts/examples/ledger_bootstrap_empty.response.json");
const OVERVIEW_EMPTY: &str =
    include_str!("../../docs/contracts/examples/portfolio_overview_empty.response.json");
const OVERVIEW_DEGRADED: &str =
    include_str!("../../docs/contracts/examples/portfolio_overview_degraded.response.json");
const AI_DIFF: &str =
    include_str!("../../docs/contracts/examples/ai_modify_movement_diff.response.json");
const DCA_PROPOSAL: &str =
    include_str!("../../docs/contracts/examples/dca_mark_executed_proposal.response.json");
const QUOTE_STALE: &str =
    include_str!("../../docs/contracts/examples/quote_refresh_stale.response.json");

#[derive(Clone)]
struct AppState {
    ledger: DevLedgerCore,
    local_ledger_path: Option<PathBuf>,
    auth: AuthStore,
}

impl AppState {
    fn dev() -> Self {
        Self {
            ledger: DevLedgerCore::new(),
            local_ledger_path: None,
            auth: AuthStore::from_env_or_dev(),
        }
    }

    fn local(path: PathBuf) -> Self {
        Self {
            ledger: DevLedgerCore::new(),
            local_ledger_path: Some(path),
            auth: AuthStore::from_env_or_dev(),
        }
    }

    #[cfg(test)]
    fn with_auth(mut self, auth: AuthStore) -> Self {
        self.auth = auth;
        self
    }

    fn should_use_local_ledger(&self, query: &HashMap<String, String>) -> bool {
        self.local_ledger_path.is_some() && !query.contains_key("scenario")
    }
}

#[derive(Clone)]
struct AuthStore {
    inner: Arc<Mutex<AuthState>>,
    config: AuthConfig,
}

#[derive(Clone)]
struct AuthConfig {
    username: Option<String>,
    password_hash: Option<String>,
    dev_plain_password: Option<String>,
}

#[derive(Default)]
struct AuthState {
    devices: BTreeMap<String, AuthDevice>,
}

#[derive(Clone)]
struct AuthDevice {
    id: String,
    name: String,
    refresh_token_hash: String,
    created_at: String,
    last_seen_at: String,
}

enum AuthError {
    Request(Vec<String>),
    Credentials,
    RefreshToken,
}

struct AuthTokens {
    access_token: String,
    refresh_token: String,
    expires_at: String,
    device_id: String,
}

impl AuthStore {
    fn from_env_or_dev() -> Self {
        Self {
            inner: Arc::new(Mutex::new(AuthState::default())),
            config: AuthConfig {
                username: env::var("FINWEALTH_AUTH_USERNAME").ok(),
                password_hash: env::var("FINWEALTH_AUTH_PASSWORD_HASH").ok(),
                dev_plain_password: env::var("FINWEALTH_AUTH_PASSWORD").ok(),
            },
        }
    }

    #[cfg(test)]
    fn configured(username: &str, password_hash: String) -> Self {
        Self {
            inner: Arc::new(Mutex::new(AuthState::default())),
            config: AuthConfig {
                username: Some(username.to_string()),
                password_hash: Some(password_hash),
                dev_plain_password: None,
            },
        }
    }

    fn login(&self, input: Value, now: &str) -> Result<AuthTokens, AuthError> {
        let Some(object) = input.as_object() else {
            return Err(AuthError::Request(vec![
                "login request must be a JSON object".to_string(),
            ]));
        };
        let mut errors = Vec::new();
        let username = required_auth_string(object, "username", &mut errors);
        let password = required_auth_string(object, "password", &mut errors);
        let device_name = required_auth_string(object, "deviceName", &mut errors);
        if !errors.is_empty() {
            return Err(AuthError::Request(errors));
        }

        let username = username.expect("validated username");
        let password = password.expect("validated password");
        let device_name = device_name.expect("validated deviceName");
        if !self.verify_password(&username, &password) {
            return Err(AuthError::Credentials);
        }

        Ok(self.issue_tokens(&device_name, None, now))
    }

    fn refresh(&self, input: Value, now: &str) -> Result<AuthTokens, AuthError> {
        let Some(object) = input.as_object() else {
            return Err(AuthError::Request(vec![
                "refresh request must be a JSON object".to_string(),
            ]));
        };
        let mut errors = Vec::new();
        let refresh_token = required_auth_string(object, "refreshToken", &mut errors);
        if !errors.is_empty() {
            return Err(AuthError::Request(errors));
        }
        let refresh_token = refresh_token.expect("validated refreshToken");
        let refresh_hash = token_hash(&refresh_token);
        let state = self.inner.lock().expect("auth store mutex should lock");
        let Some(device_id) = state
            .devices
            .iter()
            .find(|(_, device)| device.refresh_token_hash == refresh_hash)
            .map(|(id, _)| id.clone())
        else {
            return Err(AuthError::RefreshToken);
        };
        let device_name = state
            .devices
            .get(&device_id)
            .expect("device id came from auth store")
            .name
            .clone();
        drop(state);

        Ok(self.issue_tokens(&device_name, Some(device_id), now))
    }

    fn devices(&self) -> Value {
        let state = self.inner.lock().expect("auth store mutex should lock");
        json!(
            state
                .devices
                .values()
                .map(|device| {
                    json!({
                        "id": device.id,
                        "name": device.name,
                        "createdAt": device.created_at,
                        "lastSeenAt": device.last_seen_at
                    })
                })
                .collect::<Vec<_>>()
        )
    }

    fn revoke_device(&self, device_id: &str) {
        let mut state = self.inner.lock().expect("auth store mutex should lock");
        state.devices.remove(device_id);
    }

    fn revoke_refresh_token(&self, refresh_token: &str) {
        let refresh_hash = token_hash(refresh_token);
        let mut state = self.inner.lock().expect("auth store mutex should lock");
        state
            .devices
            .retain(|_, device| device.refresh_token_hash != refresh_hash);
    }

    fn verify_password(&self, username: &str, password: &str) -> bool {
        let Some(configured_username) = self.config.username.as_deref() else {
            return true;
        };
        if username != configured_username {
            return false;
        }
        if let Some(hash) = self.config.password_hash.as_deref() {
            return PasswordHash::new(hash).ok().is_some_and(|parsed| {
                Argon2::default()
                    .verify_password(password.as_bytes(), &parsed)
                    .is_ok()
            });
        }
        self.config
            .dev_plain_password
            .as_deref()
            .is_some_and(|expected| password == expected)
    }

    fn issue_tokens(
        &self,
        device_name: &str,
        existing_device_id: Option<String>,
        now: &str,
    ) -> AuthTokens {
        let dev_mode = self.config.username.is_none();
        let access_token = random_token(if dev_mode {
            "dev_access_"
        } else {
            "fw_access_"
        });
        let refresh_token = random_token(if dev_mode {
            "dev_refresh_"
        } else {
            "fw_refresh_"
        });
        let expires_at = (OffsetDateTime::now_utc() + Duration::hours(1))
            .format(&Rfc3339)
            .expect("RFC3339 formatting should succeed");
        let mut state = self.inner.lock().expect("auth store mutex should lock");
        let device_id = existing_device_id.unwrap_or_else(|| next_local_id("dev_auth_device"));
        let created_at = state
            .devices
            .get(&device_id)
            .map(|device| device.created_at.clone())
            .unwrap_or_else(|| now.to_string());
        state.devices.insert(
            device_id.clone(),
            AuthDevice {
                id: device_id.clone(),
                name: device_name.to_string(),
                refresh_token_hash: token_hash(&refresh_token),
                created_at,
                last_seen_at: now.to_string(),
            },
        );

        AuthTokens {
            access_token,
            refresh_token,
            expires_at,
            device_id,
        }
    }
}

/// Dev-only LedgerCore facade.
///
/// This is deliberately in-memory and deterministic. It is the seam where the
/// future encrypted local ledger / SQLite store can replace virtual dev data
/// without changing HTTP route signatures.
#[derive(Clone)]
struct DevLedgerCore {
    proposals: Arc<Mutex<DevProposalStore>>,
}

#[derive(Default)]
struct DevProposalStore {
    created_proposals: BTreeMap<String, Value>,
    edited_groups: BTreeMap<String, Value>,
    group_statuses: BTreeMap<String, String>,
    next_proposal_number: u64,
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum DevScenario {
    Empty,
    Degraded,
}

impl DevScenario {
    fn from_query(query: &HashMap<String, String>) -> Self {
        if query
            .get("scenario")
            .is_some_and(|value| value == "degraded")
        {
            Self::Degraded
        } else {
            Self::Empty
        }
    }

    fn is_degraded(self) -> bool {
        self == Self::Degraded
    }
}

impl DevLedgerCore {
    fn new() -> Self {
        Self {
            proposals: Arc::new(Mutex::new(DevProposalStore {
                next_proposal_number: 1,
                ..DevProposalStore::default()
            })),
        }
    }

    fn with_store<T>(&self, f: impl FnOnce(&mut DevProposalStore) -> T) -> T {
        let mut store = self
            .proposals
            .lock()
            .expect("dev proposal store mutex should not be poisoned");
        f(&mut store)
    }

    fn portfolio_overview(&self, scenario: DevScenario) -> Value {
        match scenario {
            DevScenario::Empty => example_data(OVERVIEW_EMPTY),
            DevScenario::Degraded => example_data(OVERVIEW_DEGRADED),
        }
    }

    fn accounts(&self, scenario: DevScenario) -> Value {
        if scenario.is_degraded() {
            dev_accounts()
        } else {
            json!([])
        }
    }

    fn account(&self, scenario: DevScenario, account_id: &str) -> Option<Value> {
        find_by_id(self.accounts(scenario), account_id)
    }

    fn account_anomalies(&self, scenario: DevScenario) -> Value {
        if scenario.is_degraded() {
            dev_account_anomalies()
        } else {
            json!([])
        }
    }

    fn holdings(&self, scenario: DevScenario) -> Value {
        if scenario.is_degraded() {
            dev_holdings()
        } else {
            json!([])
        }
    }

    fn holdings_by_account(&self, scenario: DevScenario, account_id: &str) -> Value {
        let items = self
            .holdings(scenario)
            .as_array()
            .expect("dev holdings should be an array")
            .iter()
            .filter(|item| item.get("accountId").and_then(Value::as_str) == Some(account_id))
            .cloned()
            .collect::<Vec<_>>();
        json!(items)
    }

    fn asset_allocation(&self, scenario: DevScenario) -> Value {
        if scenario.is_degraded() {
            dev_asset_allocation()
        } else {
            json!({
                "slices": [],
                "totalAssets": {"amount": "0", "currency": "CNY"},
                "totalLiabilities": {"amount": "0", "currency": "CNY"},
                "netWorth": {"amount": "0", "currency": "CNY"}
            })
        }
    }

    fn movements(&self, scenario: DevScenario) -> Value {
        if scenario.is_degraded() {
            dev_movements()
        } else {
            json!([])
        }
    }

    fn movement(&self, scenario: DevScenario, movement_id: &str) -> Option<Value> {
        find_by_id(self.movements(scenario), movement_id)
    }

    fn dca_plans(&self, scenario: DevScenario) -> Value {
        if scenario.is_degraded() {
            dev_dca_plans()
        } else {
            json!([])
        }
    }

    fn dca_due_reminders(&self, scenario: DevScenario) -> Value {
        if scenario.is_degraded() {
            dev_dca_reminders()
        } else {
            json!([])
        }
    }

    fn ai_pending(&self, scenario: DevScenario) -> Value {
        let mut proposals = Vec::new();

        self.with_store(|store| {
            if scenario.is_degraded() {
                let proposal = proposal_with_group_overrides(example_data(AI_DIFF), store);
                if proposal_has_pending_group(&proposal) {
                    proposals.push(proposal);
                }
            }

            proposals.extend(
                store
                    .created_proposals
                    .values()
                    .cloned()
                    .map(|proposal| proposal_with_group_overrides(proposal, store))
                    .filter(proposal_has_pending_group),
            );
        });

        json!(proposals)
    }

    fn ai_proposal(&self, scenario: DevScenario, proposal_id: &str) -> Option<Value> {
        self.with_store(|store| {
            if let Some(proposal) = store.created_proposals.get(proposal_id) {
                return Some(proposal_with_group_overrides(proposal.clone(), store));
            }

            if !scenario.is_degraded() {
                return None;
            }

            let proposal = proposal_with_group_overrides(example_data(AI_DIFF), store);
            (proposal.get("id").and_then(Value::as_str) == Some(proposal_id)).then_some(proposal)
        })
    }

    fn create_ai_proposal(&self, source_kind: &str) -> Value {
        self.with_store(|store| {
            let n = store.next_proposal_number;
            store.next_proposal_number += 1;

            let proposal_id = format!("proposal_ai_dev_{n:03}");
            let group_id = format!("ag_ai_dev_{n:03}");
            let mut proposal = example_data(AI_DIFF);

            proposal["id"] = json!(proposal_id);
            proposal["source"]["kind"] = json!(source_kind);
            proposal["atomicGroups"][0]["id"] = json!(group_id);
            proposal["atomicGroups"][0]["status"] = json!("pending");

            store.created_proposals.insert(
                proposal["id"]
                    .as_str()
                    .expect("generated proposal id should be string")
                    .to_string(),
                proposal.clone(),
            );

            proposal
        })
    }

    fn mark_dca_executed_as_proposal(&self, reminder_id: &str) -> Option<Value> {
        if !matches!(
            reminder_id,
            "reminder_001" | "dca_reminder_001" | "rem_csi300_20260710"
        ) {
            return None;
        }

        let mut proposal = example_data(DCA_PROPOSAL);
        proposal["requestedReminderId"] = json!(reminder_id);
        if let Some(group_id) = proposal.get("id").and_then(Value::as_str) {
            self.with_store(|store| {
                store
                    .group_statuses
                    .insert(group_id.to_string(), "pending".to_string());
                store
                    .edited_groups
                    .insert(group_id.to_string(), proposal.clone());
            });
        }
        Some(proposal)
    }

    fn atomic_group(&self, atomic_group_id: &str) -> Option<Value> {
        if let Some(group) = self.with_store(|store| {
            if let Some(group) = store.edited_groups.get(atomic_group_id) {
                return Some(group_with_status_override(group.clone(), store));
            }

            for proposal in store.created_proposals.values() {
                if let Some(group) = proposal["atomicGroups"]
                    .as_array()
                    .and_then(|groups| find_group(groups, atomic_group_id))
                {
                    return Some(group_with_status_override(group, store));
                }
            }

            None
        }) {
            return Some(group);
        }

        if let Some(group) = example_data(AI_DIFF)["atomicGroups"]
            .as_array()?
            .iter()
            .find(|group| group.get("id").and_then(Value::as_str) == Some(atomic_group_id))
        {
            return Some(self.with_store(|store| group_with_status_override(group.clone(), store)));
        }

        let dca_group = example_data(DCA_PROPOSAL);
        (dca_group.get("id").and_then(Value::as_str) == Some(atomic_group_id))
            .then(|| self.with_store(|store| group_with_status_override(dca_group, store)))
    }

    fn approve_atomic_group(&self, atomic_group_id: &str) -> Option<Value> {
        self.atomic_group(atomic_group_id)?;
        self.with_store(|store| {
            store
                .group_statuses
                .insert(atomic_group_id.to_string(), "approved".to_string());
        });
        Some(json!({
            "atomicGroupId": atomic_group_id,
            "confirmedMovementIds": [],
            "snapshotInvalidated": false,
            "ledgerWrite": false,
            "devOnly": true,
            "warnings": [
                {
                    "code": "dev_no_persistence",
                    "message": "Dev server approval validates the flow but does not write the confirmed ledger.",
                    "severity": "info"
                }
            ]
        }))
    }

    fn reject_atomic_group(&self, atomic_group_id: &str) -> bool {
        if self.atomic_group(atomic_group_id).is_none() {
            return false;
        }

        self.with_store(|store| {
            store
                .group_statuses
                .insert(atomic_group_id.to_string(), "rejected".to_string());
        });
        true
    }

    fn edit_atomic_group(&self, atomic_group_id: &str) -> Option<Value> {
        let mut group = self.atomic_group(atomic_group_id)?;
        group["status"] = json!("edited");
        group["validation"] = json!({
            "isValid": true,
            "errors": []
        });

        if let Some(warnings) = group.get_mut("warnings").and_then(Value::as_array_mut) {
            warnings.push(json!({
                "code": "dev_edit_not_persisted",
                "message": "Dev server edit returns an edited atomic group but does not persist proposal state.",
                "severity": "info"
            }));
        } else {
            group["warnings"] = json!([
                {
                    "code": "dev_edit_not_persisted",
                    "message": "Dev server edit returns an edited atomic group but does not persist proposal state.",
                    "severity": "info"
                }
            ]);
        }

        self.with_store(|store| {
            store
                .group_statuses
                .insert(atomic_group_id.to_string(), "edited".to_string());
            store
                .edited_groups
                .insert(atomic_group_id.to_string(), group.clone());
        });

        Some(group)
    }

    fn quote_summary(&self, scenario: DevScenario) -> Value {
        if scenario.is_degraded() {
            let overview = self.portfolio_overview(scenario);
            overview["quoteStatusSummary"].clone()
        } else {
            json!({
                "freshCount": 0,
                "staleCount": 0,
                "offlineCachedCount": 0,
                "unpriceableCount": 0,
                "errorCount": 0
            })
        }
    }

    fn latest_snapshot(&self, scenario: DevScenario) -> Value {
        if scenario.is_degraded() {
            let overview = self.portfolio_overview(scenario);
            overview["latestSnapshot"].clone()
        } else {
            Value::Null
        }
    }

    fn snapshots(&self, scenario: DevScenario) -> Value {
        if scenario.is_degraded() {
            let overview = self.portfolio_overview(scenario);
            json!([
                overview["latestSnapshot"].clone(),
                overview["previousSnapshot"].clone()
            ])
        } else {
            json!([])
        }
    }
}

#[tokio::main]
async fn main() {
    if should_hash_password_from_stdin(env::args()) {
        print_password_hash_from_stdin();
        return;
    }
    if let Some(command) = read_ledger_command_from(env::args()) {
        run_ledger_command(command).expect("ledger command failed");
        return;
    }

    let addr = read_addr();
    assert_loopback(addr);
    let state = read_ledger_path(env::args())
        .map(|path| {
            local_ledger::load_or_initialize(&path).expect("real_local ledger should initialize");
            println!("real_local ledger enabled at {}", path.display());
            AppState::local(path)
        })
        .unwrap_or_else(AppState::dev);
    let local_ledger_enabled = state.local_ledger_path.is_some();

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("bind finwealth rust server");
    println!("finwealth rust server listening on http://{addr}");
    if local_ledger_enabled {
        println!(
            "dev server: real_local JSON persistence enabled; configurable auth and Yahoo quotes available; no real AI or sync merge effects"
        );
    } else {
        println!(
            "dev server: in-memory data; configurable auth available; no persistence, real AI, or sync merge effects"
        );
    }

    axum::serve(listener, app_with_state(state))
        .await
        .expect("serve finwealth rust server");
}

#[derive(Debug, PartialEq, Eq)]
enum LedgerCommand {
    Init(PathBuf),
    Validate(PathBuf),
    CheckPaths {
        real_path: PathBuf,
        fixture_path: PathBuf,
    },
}

fn should_hash_password_from_stdin<I, S>(args: I) -> bool
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    args.into_iter()
        .map(Into::into)
        .skip(1)
        .any(|arg| arg == "--hash-password-stdin")
}

fn print_password_hash_from_stdin() {
    let mut password = String::new();
    if let Err(error) = io::stdin().read_to_string(&mut password) {
        eprintln!("failed to read password from stdin: {error}");
        process::exit(2);
    }
    let password = password.trim_end_matches(['\r', '\n']);
    if password.is_empty() {
        eprintln!("password must not be empty");
        process::exit(2);
    }
    match hash_password(password) {
        Ok(hash) => println!("{hash}"),
        Err(error) => {
            eprintln!("failed to hash password: {error}");
            process::exit(2);
        }
    }
}

fn read_ledger_command_from<I, S>(args: I) -> Option<LedgerCommand>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let mut args = args.into_iter().map(Into::into).skip(1);

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--init-ledger" => {
                return Some(LedgerCommand::Init(PathBuf::from(
                    args.next().expect("--init-ledger requires a file path"),
                )));
            }
            "--validate-ledger" => {
                return Some(LedgerCommand::Validate(PathBuf::from(
                    args.next().expect("--validate-ledger requires a file path"),
                )));
            }
            "--check-ledger-paths" => {
                let real_path = PathBuf::from(
                    args.next()
                        .expect("--check-ledger-paths requires a real ledger path"),
                );
                let fixture_path = PathBuf::from(
                    args.next()
                        .expect("--check-ledger-paths requires a fixture ledger path"),
                );
                return Some(LedgerCommand::CheckPaths {
                    real_path,
                    fixture_path,
                });
            }
            _ => {}
        }
    }

    None
}

fn run_ledger_command(command: LedgerCommand) -> std::io::Result<()> {
    match command {
        LedgerCommand::Init(path) => {
            let document = local_ledger::load_or_initialize(&path)?;
            println!(
                "initialized real_local ledger at {} (version {}, base {})",
                path.display(),
                document["ledgerVersion"],
                document["baseCurrency"]
            );
            Ok(())
        }
        LedgerCommand::Validate(path) => {
            let document = local_ledger::read_document(&path)?;
            println!(
                "validated real_local ledger at {} (version {}, base {})",
                path.display(),
                document["ledgerVersion"],
                document["baseCurrency"]
            );
            Ok(())
        }
        LedgerCommand::CheckPaths {
            real_path,
            fixture_path,
        } => {
            local_ledger::ensure_real_and_fixture_paths_separate(&real_path, &fixture_path)
                .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidInput, error))?;
            println!(
                "ledger paths are separate: real={} fixture={}",
                real_path.display(),
                fixture_path.display()
            );
            Ok(())
        }
    }
}

fn read_ledger_path<I, S>(args: I) -> Option<PathBuf>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let mut args = args.into_iter().map(Into::into).skip(1);
    let mut cli_path: Option<PathBuf> = None;

    while let Some(arg) = args.next() {
        if arg == "--ledger-path" {
            cli_path = Some(PathBuf::from(
                args.next()
                    .expect("--ledger-path requires a local ledger file path"),
            ));
        }
    }

    cli_path.or_else(|| env::var("FINWEALTH_LEDGER_PATH").ok().map(PathBuf::from))
}

#[cfg(test)]
fn app() -> Router {
    app_with_state(AppState::dev())
}

fn app_with_state(state: AppState) -> Router {
    Router::new()
        .route("/v1/health", get(health))
        .route("/v1/auth/login", post(auth_login))
        .route("/v1/auth/refresh", post(auth_refresh))
        .route("/v1/auth/logout", post(auth_logout))
        .route("/v1/auth/devices", get(auth_devices))
        .route("/v1/auth/devices/{device_id}/revoke", post(revoke_device))
        .route("/v1/ledger/bootstrap", get(ledger_bootstrap))
        .route("/v1/accounts", get(accounts).post(create_account))
        .route("/v1/accounts/anomalies", get(account_anomalies))
        .route(
            "/v1/accounts/{account_id}",
            get(account_detail).patch(update_account),
        )
        .route("/v1/accounts/{account_id}/archive", post(archive_account))
        .route("/v1/accounts/{account_id}/holdings", get(account_holdings))
        .route("/v1/portfolio/overview", get(portfolio_overview))
        .route("/v1/portfolio/holdings", get(holdings))
        .route("/v1/holdings", get(holdings))
        .route("/v1/portfolio/allocation", get(asset_allocation))
        .route("/v1/movements", get(movements))
        .route("/v1/movements/recent", get(movements))
        .route("/v1/movements/drafts", post(create_movement_draft))
        .route("/v1/movements/{movement_id}", get(movement_detail))
        .route(
            "/v1/movements/{movement_id}/submit-review",
            post(submit_movement_review),
        )
        .route("/v1/movements/corrections", post(create_correction))
        .route(
            "/v1/atomic-groups/{atomic_group_id}/confirm",
            post(confirm_atomic_group),
        )
        .route(
            "/v1/atomic-groups/{atomic_group_id}/reject",
            post(reject_atomic_group),
        )
        .route("/v1/dca/plans", get(dca_plans).post(create_dca_plan))
        .route("/v1/dca/plans/{plan_id}", patch(update_dca_plan))
        .route("/v1/dca/reminders/due", get(dca_due_reminders))
        .route(
            "/v1/dca/reminders/{reminder_id}/mark-executed-as-proposal",
            post(mark_dca_executed_as_proposal),
        )
        .route(
            "/v1/dca/reminders/{reminder_id}/skip",
            post(skip_dca_reminder),
        )
        .route(
            "/v1/dca/reminders/{reminder_id}/snooze",
            post(snooze_dca_reminder),
        )
        .route("/v1/ai/proposals/from-text", post(ai_proposal_from_text))
        .route("/v1/ai/proposals/from-image", post(ai_proposal_from_image))
        .route("/v1/ai/proposals/from-csv", post(ai_proposal_from_csv))
        .route("/v1/ai/proposals/pending", get(ai_pending))
        .route("/v1/ai/proposals/{proposal_id}", get(ai_proposal))
        .route(
            "/v1/ai/atomic-groups/{atomic_group_id}/approve",
            post(confirm_atomic_group),
        )
        .route(
            "/v1/ai/atomic-groups/{atomic_group_id}/reject",
            post(reject_atomic_group),
        )
        .route(
            "/v1/ai/atomic-groups/{atomic_group_id}/edit",
            post(edit_atomic_group),
        )
        .route("/v1/quotes/summary", get(quote_summary))
        .route("/v1/quotes", get(quotes))
        .route("/v1/fx-rates", get(fx_rates))
        .route("/v1/quotes/refresh", post(refresh_quotes))
        .route("/v1/instruments", get(instruments).post(create_instrument))
        .route(
            "/v1/instruments/{instrument_id}",
            get(instrument_detail).patch(update_instrument),
        )
        .route(
            "/v1/instruments/{instrument_id}/historical-prices",
            get(historical_prices),
        )
        .route("/v1/snapshots/latest", get(snapshot_latest))
        .route("/v1/snapshots", get(snapshots))
        .route("/v1/snapshots/manual", post(create_manual_snapshot))
        .route("/v1/snapshots/invalidate", post(no_content))
        .route("/v1/categories", get(categories).post(create_category))
        .route(
            "/v1/categories/{category_id}",
            get(category_detail).patch(update_category),
        )
        .route(
            "/v1/counterparties",
            get(counterparties).post(create_counterparty),
        )
        .route(
            "/v1/counterparties/{counterparty_id}",
            get(counterparty_detail).patch(update_counterparty),
        )
        .route(
            "/v1/counterparties/merge-proposal",
            post(create_counterparty_merge_proposal),
        )
        .route("/v1/sync/bootstrap", get(sync_bootstrap))
        .route("/v1/sync/changes", get(sync_changes))
        .route("/v1/sync/push", post(sync_push))
        .route("/v1/sync/ack", post(no_content))
        .route("/v1/transfers/execute", any(forbidden))
        .route("/v1/broker/orders", any(forbidden))
        .route("/v1/broker/buy", any(forbidden))
        .route("/v1/broker/sell", any(forbidden))
        .route("/v1/ai/auto-approve", any(forbidden))
        .route("/v1/ai/write-ledger-directly", any(forbidden))
        .route("/v1/coupons/plan", any(forbidden))
        .with_state(state)
}

fn read_addr() -> SocketAddr {
    read_addr_from(env::args())
}

fn read_addr_from<I, S>(args: I) -> SocketAddr
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let mut args = args.into_iter().map(Into::into).skip(1);
    let mut cli_addr: Option<String> = None;
    let mut cli_port: Option<String> = None;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--addr" => {
                cli_addr = Some(
                    args.next()
                        .expect("--addr requires a socket address, e.g. 127.0.0.1:8791"),
                );
            }
            "--port" => {
                cli_port = Some(args.next().expect("--port requires a port, e.g. 8791"));
            }
            _ => {}
        }
    }

    cli_addr
        .or_else(|| cli_port.map(|port| format!("127.0.0.1:{port}")))
        .or_else(|| env::var("FINWEALTH_RS_ADDR").ok())
        .unwrap_or_else(|| "127.0.0.1:8790".to_string())
        .parse()
        .expect("server address must be a socket address")
}

fn assert_loopback(addr: SocketAddr) {
    if !addr.ip().is_loopback() {
        panic!("refusing to bind Rust server to a non-localhost address");
    }
}

async fn health() -> Json<Value> {
    envelope(json!({
        "status": "ok",
        "serverTime": "2026-06-25T12:00:00+08:00",
        "version": "rust-dev-skeleton-0.1.0"
    }))
}

async fn auth_login(State(state): State<AppState>, Json(input): Json<Value>) -> Response {
    match state.auth.login(input, &current_timestamp()) {
        Ok(tokens) => envelope(auth_tokens_json(tokens)).into_response(),
        Err(error) => auth_error_response(error),
    }
}

async fn auth_refresh(State(state): State<AppState>, Json(input): Json<Value>) -> Response {
    match state.auth.refresh(input, &current_timestamp()) {
        Ok(tokens) => envelope(auth_tokens_json(tokens)).into_response(),
        Err(error) => auth_error_response(error),
    }
}

async fn auth_logout(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Option<JsonExtractor<Value>>,
) -> StatusCode {
    if let Some(refresh_token) = body
        .as_ref()
        .and_then(|JsonExtractor(value)| value.get("refreshToken").and_then(Value::as_str))
    {
        state.auth.revoke_refresh_token(refresh_token);
    } else if let Some(token) = bearer_token(&headers) {
        state.auth.revoke_refresh_token(&token);
    }
    StatusCode::NO_CONTENT
}

async fn auth_devices(State(state): State<AppState>) -> Json<Value> {
    envelope(state.auth.devices())
}

async fn revoke_device(State(state): State<AppState>, Path(device_id): Path<String>) -> StatusCode {
    state.auth.revoke_device(&device_id);
    StatusCode::NO_CONTENT
}

async fn portfolio_overview(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::portfolio_overview(path, &current_timestamp()) {
            Ok(overview) => envelope(overview).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(
        state
            .ledger
            .portfolio_overview(DevScenario::from_query(&query)),
    )
    .into_response()
}

async fn accounts(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_accounts(path) {
            Ok(accounts) => envelope(accounts).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(state.ledger.accounts(DevScenario::from_query(&query))).into_response()
}

async fn create_account(State(state): State<AppState>, Json(input): Json<Value>) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let account_id = next_local_account_id();

    match local_ledger::create_account(path, input, &account_id, &now) {
        Ok(account) => (StatusCode::CREATED, envelope(account)).into_response(),
        Err(error) => local_ledger_error(error, "invalid_account_input"),
    }
}

async fn update_account(
    State(state): State<AppState>,
    Path(account_id): Path<String>,
    Json(patch): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::update_account(path, &account_id, patch, &current_timestamp()) {
        Ok(account) => envelope(account).into_response(),
        Err(error) => local_ledger_error(error, "invalid_account_patch"),
    }
}

async fn archive_account(
    State(state): State<AppState>,
    Path(account_id): Path<String>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::archive_account(path, &account_id, &current_timestamp()) {
        Ok(account) => envelope(account).into_response(),
        Err(error) => local_ledger_error(error, "invalid_account_archive"),
    }
}

async fn account_detail(
    State(state): State<AppState>,
    Path(account_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::get_account(path, &account_id) {
            Ok(Some(account)) => envelope(account).into_response(),
            Ok(None) => not_found(
                "account_not_found",
                "Account does not exist in local ledger.",
            ),
            Err(error) => ledger_io_error(error),
        };
    }

    match state
        .ledger
        .account(DevScenario::from_query(&query), &account_id)
    {
        Some(account) => envelope(account).into_response(),
        None => not_found(
            "account_not_found",
            "Account does not exist in this dev scenario.",
        ),
    }
}

async fn account_anomalies(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    envelope(
        state
            .ledger
            .account_anomalies(DevScenario::from_query(&query)),
    )
}

async fn holdings(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_holdings(path) {
            Ok(holdings) => envelope(holdings).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(state.ledger.holdings(DevScenario::from_query(&query))).into_response()
}

async fn account_holdings(
    State(state): State<AppState>,
    Path(account_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_holdings_by_account(path, &account_id) {
            Ok(holdings) => envelope(holdings).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(
        state
            .ledger
            .holdings_by_account(DevScenario::from_query(&query), &account_id),
    )
    .into_response()
}

async fn asset_allocation(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::asset_allocation(path, &current_timestamp()) {
            Ok(allocation) => envelope(allocation).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(
        state
            .ledger
            .asset_allocation(DevScenario::from_query(&query)),
    )
    .into_response()
}

async fn movements(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_movements(path) {
            Ok(movements) => envelope(movements).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(state.ledger.movements(DevScenario::from_query(&query))).into_response()
}

async fn movement_detail(
    State(state): State<AppState>,
    Path(movement_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::get_movement(path, &movement_id) {
            Ok(Some(movement)) => envelope(movement).into_response(),
            Ok(None) => not_found(
                "movement_not_found",
                "Movement does not exist in local ledger.",
            ),
            Err(error) => ledger_io_error(error),
        };
    }

    match state
        .ledger
        .movement(DevScenario::from_query(&query), &movement_id)
    {
        Some(movement) => envelope(movement).into_response(),
        None => not_found(
            "movement_not_found",
            "Movement does not exist in this dev scenario.",
        ),
    }
}

async fn create_movement_draft(
    State(state): State<AppState>,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let movement_id = next_local_movement_id();
    let atomic_group_id = next_local_atomic_group_id();

    match local_ledger::create_movement_draft(path, input, &movement_id, &atomic_group_id, &now) {
        Ok(movement) => (StatusCode::CREATED, envelope(movement)).into_response(),
        Err(error) => local_ledger_error(error, "invalid_movement_draft_input"),
    }
}

async fn submit_movement_review(
    State(state): State<AppState>,
    Path(movement_id): Path<String>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::submit_movement_review(path, &movement_id, &current_timestamp()) {
        Ok(group) => envelope(group).into_response(),
        Err(error) => local_ledger_error(error, "invalid_movement_review_submit"),
    }
}

async fn create_correction(State(state): State<AppState>, Json(input): Json<Value>) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let movement_id = next_local_movement_id();
    let atomic_group_id = next_local_atomic_group_id();

    match local_ledger::create_correction_proposal(
        path,
        input,
        &movement_id,
        &atomic_group_id,
        &now,
    ) {
        Ok(group) => envelope(group).into_response(),
        Err(error) => local_ledger_error(error, "invalid_correction_input"),
    }
}

async fn dca_plans(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_dca_plans(path) {
            Ok(plans) => envelope(plans).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(state.ledger.dca_plans(DevScenario::from_query(&query))).into_response()
}

async fn create_dca_plan(State(state): State<AppState>, Json(input): Json<Value>) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let plan_id = next_local_dca_plan_id();
    let reminder_id = next_local_dca_reminder_id();

    match local_ledger::create_dca_plan(path, input, &plan_id, &reminder_id, &now) {
        Ok(plan) => (StatusCode::CREATED, envelope(plan)).into_response(),
        Err(error) => local_ledger_error(error, "invalid_dca_plan_input"),
    }
}

async fn update_dca_plan(
    State(state): State<AppState>,
    Path(plan_id): Path<String>,
    Json(patch): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::update_dca_plan(path, &plan_id, patch, &current_timestamp()) {
        Ok(plan) => envelope(plan).into_response(),
        Err(error) => local_ledger_error(error, "invalid_dca_plan_patch"),
    }
}

async fn dca_due_reminders(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_due_dca_reminders(path) {
            Ok(reminders) => envelope(reminders).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(
        state
            .ledger
            .dca_due_reminders(DevScenario::from_query(&query)),
    )
    .into_response()
}

async fn ai_pending(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_pending_ai_proposals(path) {
            Ok(proposals) => envelope(proposals).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(state.ledger.ai_pending(DevScenario::from_query(&query))).into_response()
}

async fn ai_proposal(
    State(state): State<AppState>,
    Path(proposal_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::get_ai_proposal(path, &proposal_id) {
            Ok(Some(proposal)) => envelope(proposal).into_response(),
            Ok(None) => not_found(
                "ai_proposal_not_found",
                "AI proposal does not exist in local ledger.",
            ),
            Err(error) => ledger_io_error(error),
        };
    }

    match state
        .ledger
        .ai_proposal(DevScenario::from_query(&query), &proposal_id)
    {
        Some(proposal) => envelope(proposal).into_response(),
        None => not_found(
            "ai_proposal_not_found",
            "AI proposal does not exist in this dev scenario.",
        ),
    }
}

async fn ai_proposal_from_text(
    State(state): State<AppState>,
    Json(input): Json<Value>,
) -> Response {
    create_ai_import_proposal(state, input, "user_text").await
}

async fn ai_proposal_from_image(
    State(state): State<AppState>,
    Json(input): Json<Value>,
) -> Response {
    create_ai_import_proposal(state, input, "user_image").await
}

async fn ai_proposal_from_csv(State(state): State<AppState>, Json(input): Json<Value>) -> Response {
    create_ai_import_proposal(state, input, "csv_import").await
}

async fn create_ai_import_proposal(state: AppState, input: Value, source_kind: &str) -> Response {
    if let Some(path) = state.local_ledger_path.as_ref() {
        return match local_ledger::create_ai_import_proposal(
            path,
            input,
            source_kind,
            &next_local_ai_proposal_id(),
            &next_local_atomic_group_id(),
            &next_local_movement_id(),
            &current_timestamp(),
        ) {
            Ok(proposal) => envelope(proposal).into_response(),
            Err(error) => local_ledger_error(error, "invalid_ai_import_proposal"),
        };
    }

    envelope(state.ledger.create_ai_proposal(source_kind)).into_response()
}

async fn mark_dca_executed_as_proposal(
    State(state): State<AppState>,
    Path(reminder_id): Path<String>,
) -> Response {
    if let Some(path) = state.local_ledger_path.as_ref() {
        let now = current_timestamp();
        let movement_id = next_local_movement_id();
        let atomic_group_id = next_local_atomic_group_id();
        return match local_ledger::mark_dca_executed_as_proposal(
            path,
            &reminder_id,
            &movement_id,
            &atomic_group_id,
            &now,
        ) {
            Ok(group) => envelope(group).into_response(),
            Err(error) => local_ledger_error(error, "invalid_dca_mark_executed"),
        };
    }

    match state.ledger.mark_dca_executed_as_proposal(&reminder_id) {
        Some(proposal) => envelope(proposal).into_response(),
        None => not_found(
            "dca_reminder_not_found",
            "DCA reminder does not exist in this dev scenario.",
        ),
    }
}

async fn skip_dca_reminder(
    State(state): State<AppState>,
    Path(reminder_id): Path<String>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::skip_dca_reminder(path, &reminder_id, &current_timestamp()) {
        Ok(reminder) => envelope(reminder).into_response(),
        Err(error) => local_ledger_error(error, "invalid_dca_reminder_skip"),
    }
}

async fn snooze_dca_reminder(
    State(state): State<AppState>,
    Path(reminder_id): Path<String>,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::snooze_dca_reminder(path, &reminder_id, input, &current_timestamp()) {
        Ok(reminder) => envelope(reminder).into_response(),
        Err(error) => local_ledger_error(error, "invalid_dca_reminder_snooze"),
    }
}

async fn confirm_atomic_group(
    State(state): State<AppState>,
    Path(atomic_group_id): Path<String>,
) -> Response {
    if let Some(path) = state.local_ledger_path.as_ref() {
        return match local_ledger::confirm_atomic_group(
            path,
            &atomic_group_id,
            &current_timestamp(),
        ) {
            Ok(result) => envelope(result).into_response(),
            Err(error) => local_ledger_error(error, "invalid_atomic_group_confirm"),
        };
    }

    match state.ledger.approve_atomic_group(&atomic_group_id) {
        Some(result) => envelope(result).into_response(),
        None => not_found(
            "atomic_group_not_found",
            "Atomic group does not exist in this dev scenario.",
        ),
    }
}

async fn reject_atomic_group(
    State(state): State<AppState>,
    Path(atomic_group_id): Path<String>,
) -> Response {
    if let Some(path) = state.local_ledger_path.as_ref() {
        return match local_ledger::reject_atomic_group(path, &atomic_group_id, &current_timestamp())
        {
            Ok(()) => StatusCode::NO_CONTENT.into_response(),
            Err(error) => local_ledger_error(error, "invalid_atomic_group_reject"),
        };
    }

    if state.ledger.reject_atomic_group(&atomic_group_id) {
        StatusCode::NO_CONTENT.into_response()
    } else {
        not_found(
            "atomic_group_not_found",
            "Atomic group does not exist in this dev scenario.",
        )
    }
}

async fn edit_atomic_group(
    State(state): State<AppState>,
    Path(atomic_group_id): Path<String>,
    Json(patch): Json<Value>,
) -> Response {
    if let Some(path) = state.local_ledger_path.as_ref() {
        return match local_ledger::edit_ai_atomic_group(
            path,
            &atomic_group_id,
            patch,
            &next_local_movement_id(),
            &current_timestamp(),
        ) {
            Ok(group) => envelope(group).into_response(),
            Err(error) => local_ledger_error(error, "invalid_ai_atomic_group_edit"),
        };
    }

    match state.ledger.edit_atomic_group(&atomic_group_id) {
        Some(group) => envelope(group).into_response(),
        None => not_found(
            "atomic_group_not_found",
            "Atomic group does not exist in this dev scenario.",
        ),
    }
}

async fn ledger_bootstrap(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger_bootstrap(path, &current_timestamp()) {
            Ok(payload) => envelope(payload).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    example_json(EMPTY_BOOTSTRAP).into_response()
}

async fn quotes(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_quotes(path, &current_timestamp()) {
            Ok(quotes) => envelope(quotes).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(json!([])).into_response()
}

async fn fx_rates(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_fx_rates(path, &current_timestamp()) {
            Ok(rates) => envelope(rates).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(json!([])).into_response()
}

async fn refresh_quotes(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
    Json(input): Json<Value>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        let now = current_timestamp();
        let input = match enrich_quote_refresh_with_yahoo(path, input, &now).await {
            Ok(input) => input,
            Err(error_result) => return envelope(error_result).into_response(),
        };
        let provider_errors = quote_provider_errors(&input);
        if input.get("quotes").is_none()
            && input.get("fxRates").is_none()
            && !provider_errors.is_empty()
        {
            return envelope(json!({
                "status": "offline",
                "quotes": [],
                "fxRates": [],
                "errors": provider_errors,
                "completedAt": now
            }))
            .into_response();
        }
        return match local_ledger::refresh_quotes(path, input, &now) {
            Ok(result) => {
                envelope(merge_quote_provider_errors(result, provider_errors)).into_response()
            }
            Err(error) => local_ledger_error(error, "invalid_quote_refresh_input"),
        };
    }

    example_json(QUOTE_STALE).into_response()
}

fn quote_provider_errors(input: &Value) -> Vec<Value> {
    input
        .get("_providerErrors")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

fn merge_quote_provider_errors(mut result: Value, provider_errors: Vec<Value>) -> Value {
    if provider_errors.is_empty() {
        return result;
    }
    let had_errors = result
        .get("errors")
        .and_then(Value::as_array)
        .is_some_and(|errors| !errors.is_empty());
    if let Some(errors) = result.get_mut("errors").and_then(Value::as_array_mut) {
        errors.extend(provider_errors);
    }
    if !had_errors && result.get("status").and_then(Value::as_str) == Some("success") {
        result["status"] = json!("partial_success");
    }
    result
}

async fn enrich_quote_refresh_with_yahoo(
    path: &FsPath,
    mut input: Value,
    now: &str,
) -> Result<Value, Value> {
    if input.get("quotes").is_some() || input.get("fxRates").is_some() {
        return Ok(input);
    }

    let quote_targets = match local_ledger::quote_refresh_targets(path, &input) {
        Ok(targets) => targets,
        Err(error) => {
            return Err(json!({
                "status": "failed",
                "quotes": [],
                "fxRates": [],
                "errors": [{
                    "targetType": "request",
                    "message": format!("failed to read quote refresh targets: {error}"),
                    "retryable": true
                }],
                "completedAt": now
            }));
        }
    };
    let fx_targets = match local_ledger::fx_refresh_targets(path, &input) {
        Ok(targets) => targets,
        Err(error) => {
            return Err(json!({
                "status": "failed",
                "quotes": [],
                "fxRates": [],
                "errors": [{
                    "targetType": "request",
                    "message": format!("failed to read FX refresh targets: {error}"),
                    "retryable": true
                }],
                "completedAt": now
            }));
        }
    };

    if quote_targets.is_empty() && fx_targets.is_empty() {
        return Ok(input);
    }

    if quote_provider_disabled() {
        return Err(json!({
            "status": "offline",
            "quotes": [],
            "fxRates": [],
            "errors": [{
                "targetType": "request",
                "message": "quote provider disabled by FINWEALTH_QUOTE_PROVIDER=none; pass quotes/fxRates payload or keep using cache",
                "retryable": false
            }],
            "completedAt": now
        }));
    }

    let provider = match yahoo::YahooConnector::new() {
        Ok(provider) => provider,
        Err(error) => {
            return Err(json!({
                "status": "offline",
                "quotes": [],
                "fxRates": [],
                "errors": [{
                    "targetType": "request",
                    "message": format!("Yahoo provider unavailable: {error}"),
                    "retryable": true
                }],
                "completedAt": now
            }));
        }
    };

    let mut quotes = Vec::new();
    let mut fx_rates = Vec::new();
    let mut errors = Vec::new();
    for target in quote_targets {
        let instrument_id = target
            .get("instrumentId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let Some(symbol) = target.get("symbol").and_then(Value::as_str) else {
            errors.push(json!({
                "targetType": "instrument",
                "targetId": instrument_id,
                "message": "instrument has no Yahoo symbol; add symbol or pass manual quote payload",
                "retryable": false
            }));
            continue;
        };
        match yahoo_latest_quote(&provider, instrument_id, symbol, &target, now).await {
            Ok(quote) => quotes.push(quote),
            Err(message) => errors.push(json!({
                "targetType": "instrument",
                "targetId": instrument_id,
                "message": message,
                "retryable": true
            })),
        }
    }
    for target in fx_targets {
        let base_currency = target
            .get("baseCurrency")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let quote_currency = target
            .get("quoteCurrency")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let Some(symbol) = target.get("symbol").and_then(Value::as_str) else {
            errors.push(json!({
                "targetType": "fx_pair",
                "targetId": format!("{base_currency}/{quote_currency}"),
                "message": "FX pair has no Yahoo symbol",
                "retryable": false
            }));
            continue;
        };
        match yahoo_latest_fx_rate(&provider, base_currency, quote_currency, symbol).await {
            Ok(rate) => fx_rates.push(rate),
            Err(message) => errors.push(json!({
                "targetType": "fx_pair",
                "targetId": format!("{base_currency}/{quote_currency}"),
                "message": message,
                "retryable": true
            })),
        }
    }

    if let Some(object) = input.as_object_mut() {
        if !quotes.is_empty() {
            object.insert("quotes".to_string(), json!(quotes));
        }
        if !fx_rates.is_empty() {
            object.insert("fxRates".to_string(), json!(fx_rates));
        }
        if !errors.is_empty() {
            object.insert("_providerErrors".to_string(), json!(errors));
        }
    }
    Ok(input)
}

fn quote_provider_disabled() -> bool {
    env::var("FINWEALTH_QUOTE_PROVIDER")
        .map(|value| {
            matches!(
                value.to_ascii_lowercase().as_str(),
                "none" | "off" | "disabled"
            )
        })
        .unwrap_or(false)
}

async fn yahoo_latest_quote(
    provider: &yahoo::YahooConnector,
    instrument_id: &str,
    symbol: &str,
    target: &Value,
    _now: &str,
) -> Result<Value, String> {
    let response = provider
        .get_latest_quotes(symbol, "1d")
        .await
        .map_err(|error| format!("Yahoo quote fetch failed for {symbol}: {error}"))?;
    let quote = response
        .last_quote()
        .map_err(|error| format!("Yahoo returned no usable quote for {symbol}: {error}"))?;
    let currency = response
        .chart
        .result
        .as_ref()
        .and_then(|items| items.first())
        .and_then(|item| item.meta.currency.as_deref())
        .or_else(|| target.get("quoteCurrency").and_then(Value::as_str))
        .unwrap_or(local_ledger::DEFAULT_BASE_CURRENCY);
    let as_of = OffsetDateTime::from_unix_timestamp(quote.timestamp)
        .unwrap_or_else(|_| OffsetDateTime::now_utc())
        .format(&Rfc3339)
        .expect("RFC3339 formatting should succeed");
    let expires_at = (OffsetDateTime::now_utc() + Duration::minutes(15))
        .format(&Rfc3339)
        .expect("RFC3339 formatting should succeed");

    Ok(json!({
        "instrumentId": instrument_id,
        "price": quote.close.to_string(),
        "currency": currency,
        "asOf": as_of,
        "source": "yahoo_finance_api",
        "sourceUrl": format!("https://finance.yahoo.com/quote/{symbol}"),
        "status": "fresh",
        "expiresAt": expires_at
    }))
}

async fn yahoo_latest_fx_rate(
    provider: &yahoo::YahooConnector,
    base_currency: &str,
    quote_currency: &str,
    symbol: &str,
) -> Result<Value, String> {
    let response = provider
        .get_latest_quotes(symbol, "1d")
        .await
        .map_err(|error| format!("Yahoo FX fetch failed for {symbol}: {error}"))?;
    let quote = response
        .last_quote()
        .map_err(|error| format!("Yahoo returned no usable FX quote for {symbol}: {error}"))?;
    let as_of = OffsetDateTime::from_unix_timestamp(quote.timestamp)
        .unwrap_or_else(|_| OffsetDateTime::now_utc())
        .format(&Rfc3339)
        .expect("RFC3339 formatting should succeed");
    let expires_at = (OffsetDateTime::now_utc() + Duration::hours(24))
        .format(&Rfc3339)
        .expect("RFC3339 formatting should succeed");

    Ok(json!({
        "baseCurrency": base_currency,
        "quoteCurrency": quote_currency,
        "rate": quote.close.to_string(),
        "asOf": as_of,
        "source": "yahoo_finance_api",
        "sourceUrl": format!("https://finance.yahoo.com/quote/{symbol}"),
        "status": "fresh",
        "expiresAt": expires_at
    }))
}

fn parse_historical_price_dates(
    query: &HashMap<String, String>,
) -> Result<(Date, Date), Vec<String>> {
    let mut errors = Vec::new();
    let from_date = parse_iso_date_query(query, "from", &mut errors);
    let to_date = parse_iso_date_query(query, "to", &mut errors);
    if !errors.is_empty() {
        return Err(errors);
    }

    let from_date = from_date.expect("validated from date");
    let to_date = to_date.expect("validated to date");
    if to_date < from_date {
        return Err(vec!["to must be on or after from".to_string()]);
    }
    let span_days = (to_date - from_date).whole_days();
    if span_days > 366 {
        return Err(vec![
            "historical price range must not exceed one year".to_string(),
        ]);
    }

    Ok((from_date, to_date))
}

fn parse_iso_date_query(
    query: &HashMap<String, String>,
    key: &str,
    errors: &mut Vec<String>,
) -> Option<Date> {
    match query.get(key) {
        Some(value) => match Date::parse(value, &Iso8601::DATE) {
            Ok(date) => Some(date),
            Err(_) => {
                errors.push(format!("{key} must be an ISO date in YYYY-MM-DD format"));
                None
            }
        },
        None => {
            errors.push(format!("{key} is required"));
            None
        }
    }
}

fn yahoo_symbol_for_instrument(instrument_id: &str, instrument: &Value) -> Option<String> {
    instrument
        .get("symbol")
        .and_then(Value::as_str)
        .filter(|symbol| !symbol.trim().is_empty())
        .map(str::to_string)
        .or_else(|| infer_yahoo_symbol_from_instrument_id(instrument_id))
}

fn infer_yahoo_symbol_from_instrument_id(instrument_id: &str) -> Option<String> {
    let value = instrument_id.trim();
    if value.is_empty() || value.starts_with("inst_") || value.len() > 16 {
        return None;
    }
    value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-' | '='))
        .then(|| value.to_ascii_uppercase())
}

async fn yahoo_historical_prices(
    provider: &yahoo::YahooConnector,
    instrument_id: &str,
    symbol: &str,
    fallback_currency: &str,
    from_date: Date,
    to_date: Date,
) -> Result<Vec<Value>, String> {
    let start = from_date.midnight().assume_utc();
    let end = to_date
        .next_day()
        .unwrap_or(to_date)
        .midnight()
        .assume_utc();
    let response = provider
        .get_quote_history(symbol, start, end)
        .await
        .map_err(|error| format!("Yahoo historical fetch failed for {symbol}: {error}"))?;
    let currency = response
        .metadata()
        .ok()
        .and_then(|metadata| metadata.currency)
        .filter(|currency| !currency.trim().is_empty())
        .unwrap_or_else(|| fallback_currency.to_string());
    let quotes = response
        .quotes()
        .map_err(|error| format!("Yahoo returned no usable history for {symbol}: {error}"))?;

    Ok(historical_price_points_from_yahoo_quotes(
        instrument_id,
        symbol,
        &currency,
        &quotes,
    ))
}

fn historical_price_points_from_yahoo_quotes(
    instrument_id: &str,
    symbol: &str,
    currency: &str,
    quotes: &[yahoo::Quote],
) -> Vec<Value> {
    quotes
        .iter()
        .filter(|quote| quote.close.is_finite())
        .filter_map(|quote| {
            let date = OffsetDateTime::from_unix_timestamp(quote.timestamp)
                .ok()?
                .date()
                .format(&Iso8601::DATE)
                .ok()?;
            Some(json!({
                "instrumentId": instrument_id,
                "price": quote.close.to_string(),
                "currency": currency,
                "date": date,
                "source": "yahoo_finance_api",
                "sourceUrl": format!("https://finance.yahoo.com/quote/{symbol}/history")
            }))
        })
        .collect()
}

fn local_ledger_bootstrap(path: &FsPath, now: &str) -> io::Result<Value> {
    let document = local_ledger::read_document(path)?;
    let mut payload = json!({
        "ledgerVersion": document
            .get("ledgerVersion")
            .and_then(Value::as_i64)
            .unwrap_or(local_ledger::LEDGER_VERSION),
        "syncCursor": sync_cursor_from_document(&document),
        "baseCurrency": document
            .get("baseCurrency")
            .and_then(Value::as_str)
            .unwrap_or(local_ledger::DEFAULT_BASE_CURRENCY),
        "accounts": local_ledger::list_accounts(path)?,
        "categories": local_ledger::list_categories(path)?,
        "counterparties": local_ledger::list_counterparties(path)?
    });
    let overview = local_ledger::portfolio_overview(path, now)?;
    if let Some(snapshot) = overview
        .get("latestSnapshot")
        .filter(|value| !value.is_null())
    {
        payload["snapshot"] = snapshot.clone();
    }
    Ok(payload)
}

fn sync_cursor_from_document(document: &Value) -> String {
    document
        .get("syncState")
        .and_then(|sync_state| sync_state.get("cursor"))
        .and_then(Value::as_str)
        .filter(|cursor| !cursor.trim().is_empty())
        .unwrap_or("local_cursor_0000")
        .to_string()
}

fn current_sync_cursor(state: &AppState, query: &HashMap<String, String>) -> String {
    if state.should_use_local_ledger(query)
        && let Some(path) = state.local_ledger_path.as_ref()
        && let Ok(document) = local_ledger::read_document(path)
    {
        return sync_cursor_from_document(&document);
    }
    "rust_dev_cursor_0001".to_string()
}

fn contains_forbidden_sync_marker(value: &Value) -> bool {
    match value {
        Value::String(value) => {
            let lower = value.to_ascii_lowercase();
            lower == "debug_fixture" || lower == "fixture" || lower == "demo"
        }
        Value::Array(items) => items.iter().any(contains_forbidden_sync_marker),
        Value::Object(object) => object
            .iter()
            .any(|(key, value)| key == "debugFixture" || contains_forbidden_sync_marker(value)),
        _ => false,
    }
}

async fn quote_summary(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::portfolio_overview(path, &current_timestamp()) {
            Ok(overview) => envelope(overview["quoteStatusSummary"].clone()).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(state.ledger.quote_summary(DevScenario::from_query(&query))).into_response()
}

async fn snapshot_latest(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::latest_snapshot(path, &current_timestamp()) {
            Ok(snapshot) => envelope(snapshot).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(
        state
            .ledger
            .latest_snapshot(DevScenario::from_query(&query)),
    )
    .into_response()
}

async fn snapshots(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_snapshots(path) {
            Ok(snapshots) => envelope(snapshots).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(state.ledger.snapshots(DevScenario::from_query(&query))).into_response()
}

async fn create_manual_snapshot(
    State(state): State<AppState>,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::create_manual_snapshot(path, input, &current_timestamp()) {
        Ok(snapshot) => envelope(snapshot).into_response(),
        Err(error) => local_ledger_error(error, "invalid_manual_snapshot"),
    }
}

async fn instruments(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_instruments(path) {
            Ok(instruments) => envelope(instruments).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(json!([])).into_response()
}

async fn create_instrument(State(state): State<AppState>, Json(input): Json<Value>) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::create_instrument(path, input, &next_local_instrument_id()) {
        Ok(instrument) => (StatusCode::CREATED, envelope(instrument)).into_response(),
        Err(error) => local_ledger_error(error, "invalid_instrument_input"),
    }
}

async fn instrument_detail(
    State(state): State<AppState>,
    Path(instrument_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::get_instrument(path, &instrument_id) {
            Ok(Some(instrument)) => envelope(instrument).into_response(),
            Ok(None) => not_found(
                "instrument_not_found",
                "Instrument does not exist in local ledger.",
            ),
            Err(error) => ledger_io_error(error),
        };
    }

    not_found(
        "instrument_not_found",
        "Instrument does not exist in this dev scenario.",
    )
}

async fn update_instrument(
    State(state): State<AppState>,
    Path(instrument_id): Path<String>,
    Json(patch): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::update_instrument(path, &instrument_id, patch) {
        Ok(instrument) => envelope(instrument).into_response(),
        Err(error) => local_ledger_error(error, "invalid_instrument_patch"),
    }
}

async fn historical_prices(
    State(state): State<AppState>,
    Path(instrument_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if !state.should_use_local_ledger(&query) {
        return envelope(json!([])).into_response();
    }

    let (from_date, to_date) = match parse_historical_price_dates(&query) {
        Ok(range) => range,
        Err(errors) => {
            return bad_request(
                "invalid_historical_price_range",
                "Historical price date range is invalid.",
                json!({ "errors": errors }),
            );
        }
    };
    let path = state
        .local_ledger_path
        .as_ref()
        .expect("local ledger path should exist when local ledger is selected");
    let instrument = match local_ledger::get_instrument(path, &instrument_id) {
        Ok(Some(instrument)) => instrument,
        Ok(None) => {
            return not_found(
                "instrument_not_found",
                "Instrument does not exist in local ledger.",
            );
        }
        Err(error) => return ledger_io_error(error),
    };
    let Some(symbol) = yahoo_symbol_for_instrument(&instrument_id, &instrument) else {
        return bad_request(
            "missing_instrument_symbol",
            "Instrument has no Yahoo symbol; add symbol before requesting historical prices.",
            json!({ "instrumentId": instrument_id }),
        );
    };
    if quote_provider_disabled() {
        return service_unavailable(
            "quote_provider_disabled",
            "Quote provider is disabled; historical prices require a configured provider.",
            json!({ "instrumentId": instrument_id, "symbol": symbol }),
            false,
        );
    }
    let fallback_currency = instrument
        .get("quoteCurrency")
        .and_then(Value::as_str)
        .unwrap_or(local_ledger::DEFAULT_BASE_CURRENCY);
    let provider = match yahoo::YahooConnector::new() {
        Ok(provider) => provider,
        Err(error) => {
            return service_unavailable(
                "quote_provider_unavailable",
                "Quote provider could not be initialized.",
                json!({ "error": error.to_string() }),
                true,
            );
        }
    };

    match yahoo_historical_prices(
        &provider,
        &instrument_id,
        &symbol,
        fallback_currency,
        from_date,
        to_date,
    )
    .await
    {
        Ok(points) => envelope(json!(points)).into_response(),
        Err(message) => service_unavailable(
            "historical_price_fetch_failed",
            "Historical prices could not be fetched from the configured provider.",
            json!({ "instrumentId": instrument_id, "symbol": symbol, "error": message }),
            true,
        ),
    }
}

async fn categories(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_categories(path) {
            Ok(categories) => envelope(categories).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(json!([])).into_response()
}

async fn create_category(State(state): State<AppState>, Json(input): Json<Value>) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::create_category(path, input, &next_local_category_id()) {
        Ok(category) => (StatusCode::CREATED, envelope(category)).into_response(),
        Err(error) => local_ledger_error(error, "invalid_category_input"),
    }
}

async fn category_detail(
    State(state): State<AppState>,
    Path(category_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_categories(path) {
            Ok(categories) => match find_by_id(categories, &category_id) {
                Some(category) => envelope(category).into_response(),
                None => not_found("category_not_found", "Category does not exist."),
            },
            Err(error) => ledger_io_error(error),
        };
    }

    not_found(
        "category_not_found",
        "Category does not exist in this dev scenario.",
    )
}

async fn update_category(
    State(state): State<AppState>,
    Path(category_id): Path<String>,
    Json(patch): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::update_category(path, &category_id, patch) {
        Ok(category) => envelope(category).into_response(),
        Err(error) => local_ledger_error(error, "invalid_category_patch"),
    }
}

async fn counterparties(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_counterparties(path) {
            Ok(counterparties) => envelope(counterparties).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(json!([])).into_response()
}

async fn create_counterparty(State(state): State<AppState>, Json(input): Json<Value>) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::create_counterparty(path, input, &next_local_counterparty_id()) {
        Ok(counterparty) => (StatusCode::CREATED, envelope(counterparty)).into_response(),
        Err(error) => local_ledger_error(error, "invalid_counterparty_input"),
    }
}

async fn counterparty_detail(
    State(state): State<AppState>,
    Path(counterparty_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_counterparties(path) {
            Ok(counterparties) => match find_by_id(counterparties, &counterparty_id) {
                Some(counterparty) => envelope(counterparty).into_response(),
                None => not_found("counterparty_not_found", "Counterparty does not exist."),
            },
            Err(error) => ledger_io_error(error),
        };
    }

    not_found(
        "counterparty_not_found",
        "Counterparty does not exist in this dev scenario.",
    )
}

async fn update_counterparty(
    State(state): State<AppState>,
    Path(counterparty_id): Path<String>,
    Json(patch): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::update_counterparty(path, &counterparty_id, patch) {
        Ok(counterparty) => envelope(counterparty).into_response(),
        Err(error) => local_ledger_error(error, "invalid_counterparty_patch"),
    }
}

async fn create_counterparty_merge_proposal(
    State(state): State<AppState>,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    match local_ledger::create_counterparty_merge_proposal(
        path,
        input,
        &next_local_ai_proposal_id(),
        &next_local_atomic_group_id(),
        &current_timestamp(),
    ) {
        Ok(group) => envelope(group).into_response(),
        Err(error) => local_ledger_error(error, "invalid_counterparty_merge_proposal"),
    }
}

async fn sync_bootstrap(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    envelope(json!({ "cursor": current_sync_cursor(&state, &query) })).into_response()
}

async fn sync_changes(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    envelope(json!({
        "cursor": current_sync_cursor(&state, &query),
        "changes": [],
        "conflicts": []
    }))
}

async fn sync_push(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
    Json(input): Json<Value>,
) -> Response {
    let Some(object) = input.as_object() else {
        return bad_request(
            "invalid_sync_push",
            "Sync push request is invalid.",
            json!({ "errors": ["sync push request must be a JSON object"] }),
        );
    };
    let mut errors = Vec::new();
    match object.get("deviceId").and_then(Value::as_str) {
        Some(value) if !value.trim().is_empty() => {}
        _ => errors.push("deviceId must be a non-empty string"),
    }
    match object.get("changes").and_then(Value::as_array) {
        Some(_) => {}
        None => errors.push("changes must be an array"),
    }
    if contains_forbidden_sync_marker(&input) {
        errors.push("debug fixture, fixture, and demo payloads must not be synced");
    }
    if !errors.is_empty() {
        return bad_request(
            "invalid_sync_push",
            "Sync push request is invalid.",
            json!({ "errors": errors }),
        );
    }

    envelope(json!({
        "cursor": current_sync_cursor(&state, &query),
        "conflicts": []
    }))
    .into_response()
}

async fn no_content() -> StatusCode {
    StatusCode::NO_CONTENT
}

async fn not_implemented() -> Response {
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(json!({
            "ok": false,
            "error": {
                "code": "rust_dev_route_not_implemented",
                "message": "This endpoint exists in the API contract but is not implemented in the Rust skeleton yet.",
                "severity": "warning",
                "retryable": false
            }
        })),
    )
        .into_response()
}

async fn forbidden() -> Response {
    (
        StatusCode::FORBIDDEN,
        Json(json!({
            "ok": false,
            "error": {
                "code": "forbidden_product_boundary",
                "message": "This product does not expose transfer, broker order, coupon planning, or AI auto-write endpoints.",
                "severity": "critical",
                "retryable": false
            }
        })),
    )
        .into_response()
}

fn envelope(data: Value) -> Json<Value> {
    Json(json!({
        "ok": true,
        "data": data
    }))
}

fn current_timestamp() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .expect("RFC3339 formatting should succeed")
}

fn next_local_account_id() -> String {
    next_local_id("acct_local")
}

fn next_local_movement_id() -> String {
    next_local_id("mov_local")
}

fn next_local_atomic_group_id() -> String {
    next_local_id("ag_local")
}

fn next_local_dca_plan_id() -> String {
    next_local_id("plan_local")
}

fn next_local_dca_reminder_id() -> String {
    next_local_id("rem_local")
}

fn next_local_category_id() -> String {
    next_local_id("cat_local")
}

fn next_local_counterparty_id() -> String {
    next_local_id("cp_local")
}

fn next_local_instrument_id() -> String {
    next_local_id("inst_local")
}

fn next_local_ai_proposal_id() -> String {
    next_local_id("proposal_local")
}

fn next_local_id(prefix: &str) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be after unix epoch")
        .as_nanos();
    format!("{prefix}_{nanos}")
}

fn auth_tokens_json(tokens: AuthTokens) -> Value {
    json!({
        "accessToken": tokens.access_token,
        "refreshToken": tokens.refresh_token,
        "expiresAt": tokens.expires_at,
        "deviceId": tokens.device_id
    })
}

fn auth_error_response(error: AuthError) -> Response {
    match error {
        AuthError::Request(errors) => bad_request(
            "invalid_auth_request",
            "Authentication request is invalid.",
            json!({ "errors": errors }),
        ),
        AuthError::Credentials | AuthError::RefreshToken => unauthorized(
            "invalid_credentials",
            "Username, password, or refresh token is invalid.",
        ),
    }
}

fn required_auth_string(
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

fn random_token(prefix: &str) -> String {
    let mut bytes = [0_u8; 32];
    OsRng.fill_bytes(&mut bytes);
    format!("{prefix}{}", URL_SAFE_NO_PAD.encode(bytes))
}

fn token_hash(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    URL_SAFE_NO_PAD.encode(digest)
}

fn bearer_token(headers: &HeaderMap) -> Option<String> {
    let header = headers.get("authorization")?.to_str().ok()?;
    let token = header.strip_prefix("Bearer ")?;
    (!token.trim().is_empty()).then(|| token.to_string())
}

fn hash_password(password: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(|error| error.to_string())
}

#[cfg(test)]
fn hash_password_for_test(password: &str) -> String {
    hash_password(password).expect("test password should hash")
}

fn example_json(raw: &str) -> Json<Value> {
    Json(serde_json::from_str(raw).expect("contract example JSON must parse"))
}

fn example_data(raw: &str) -> Value {
    let parsed: Value = serde_json::from_str(raw).expect("contract example JSON must parse");
    parsed["data"].clone()
}

fn find_by_id(items: Value, id: &str) -> Option<Value> {
    items
        .as_array()?
        .iter()
        .find(|item| item.get("id").and_then(Value::as_str) == Some(id))
        .cloned()
}

fn find_group(groups: &[Value], atomic_group_id: &str) -> Option<Value> {
    groups
        .iter()
        .find(|group| group.get("id").and_then(Value::as_str) == Some(atomic_group_id))
        .cloned()
}

fn group_with_status_override(mut group: Value, store: &DevProposalStore) -> Value {
    if let Some(group_id) = group.get("id").and_then(Value::as_str)
        && let Some(status) = store.group_statuses.get(group_id)
    {
        group["status"] = json!(status);
    }
    group
}

fn proposal_with_group_overrides(mut proposal: Value, store: &DevProposalStore) -> Value {
    if let Some(groups) = proposal["atomicGroups"].as_array_mut() {
        for group in groups {
            let Some(group_id) = group.get("id").and_then(Value::as_str).map(str::to_string) else {
                continue;
            };

            if let Some(edited) = store.edited_groups.get(&group_id) {
                *group = edited.clone();
            }

            if let Some(status) = store.group_statuses.get(&group_id) {
                group["status"] = json!(status);
            }
        }
    }
    proposal
}

fn proposal_has_pending_group(proposal: &Value) -> bool {
    proposal["atomicGroups"].as_array().is_some_and(|groups| {
        groups.iter().any(|group| {
            matches!(
                group.get("status").and_then(Value::as_str),
                Some("pending" | "edited")
            )
        })
    })
}

fn not_found(code: &str, message: &str) -> Response {
    (
        StatusCode::NOT_FOUND,
        Json(json!({
            "ok": false,
            "error": {
                "code": code,
                "message": message,
                "severity": "warning",
                "retryable": false
            }
        })),
    )
        .into_response()
}

fn bad_request(code: &str, message: &str, details: Value) -> Response {
    (
        StatusCode::BAD_REQUEST,
        Json(json!({
            "ok": false,
            "error": {
                "code": code,
                "message": message,
                "severity": "warning",
                "retryable": false,
                "details": details
            }
        })),
    )
        .into_response()
}

fn unauthorized(code: &str, message: &str) -> Response {
    (
        StatusCode::UNAUTHORIZED,
        Json(json!({
            "ok": false,
            "error": {
                "code": code,
                "message": message,
                "severity": "warning",
                "retryable": false
            }
        })),
    )
        .into_response()
}

fn service_unavailable(code: &str, message: &str, details: Value, retryable: bool) -> Response {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(json!({
            "ok": false,
            "error": {
                "code": code,
                "message": message,
                "severity": "warning",
                "retryable": retryable,
                "details": details
            }
        })),
    )
        .into_response()
}

fn ledger_io_error(error: std::io::Error) -> Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({
            "ok": false,
            "error": {
                "code": "local_ledger_io_error",
                "message": error.to_string(),
                "severity": "error",
                "retryable": false
            }
        })),
    )
        .into_response()
}

fn local_ledger_error(error: local_ledger::LedgerError, invalid_code: &str) -> Response {
    match error {
        local_ledger::LedgerError::InvalidInput(errors) => bad_request(
            invalid_code,
            "Local ledger request is invalid.",
            json!({ "errors": errors }),
        ),
        local_ledger::LedgerError::Conflict(message) => {
            bad_request("local_ledger_conflict", &message, json!({}))
        }
        local_ledger::LedgerError::NotFound(message) => {
            not_found("local_ledger_not_found", &message)
        }
        local_ledger::LedgerError::Io(error) => ledger_io_error(error),
    }
}

fn dev_accounts() -> Value {
    json!([
        {
            "id": "acct_cmb_cny",
            "displayName": "招行储蓄卡",
            "institutionName": "招商银行",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "visibility": "normal",
            "status": "active",
            "balanceMode": "cash_balance",
            "cashBalances": [
                {
                    "currency": "CNY",
                    "amount": "38240.00",
                    "asOf": "2026-06-25T09:30:00+08:00",
                    "quality": "exact"
                }
            ],
            "value": {
                "amount": "38240.00",
                "currency": "CNY",
                "asOf": "2026-06-25T09:30:00+08:00",
                "quality": "exact"
            },
            "tags": [],
            "createdAt": "2026-06-25T08:00:00+08:00",
            "updatedAt": "2026-06-25T09:30:00+08:00"
        },
        {
            "id": "acct_us_broker",
            "displayName": "美股券商",
            "institutionName": "US Broker",
            "accountType": "brokerage",
            "defaultCurrency": "USD",
            "supportedCurrencies": ["USD", "CNY"],
            "includeInNetWorth": true,
            "visibility": "normal",
            "status": "active",
            "balanceMode": "holdings",
            "cashBalances": [],
            "value": {
                "amount": "110320.00",
                "currency": "CNY",
                "asOf": "2026-06-25T09:30:00+08:00",
                "quality": "estimated"
            },
            "tags": [],
            "createdAt": "2026-06-25T08:00:00+08:00",
            "updatedAt": "2026-06-25T09:30:00+08:00"
        },
        {
            "id": "acct_crypto",
            "displayName": "数字资产",
            "institutionName": "Crypto Exchange",
            "accountType": "exchange",
            "defaultCurrency": "USDT",
            "supportedCurrencies": ["USDT", "BTC", "ETH"],
            "includeInNetWorth": true,
            "visibility": "normal",
            "status": "active",
            "balanceMode": "holdings",
            "cashBalances": [],
            "value": {
                "amount": "31870.00",
                "currency": "CNY",
                "asOf": "2026-06-25T09:30:00+08:00",
                "quality": "estimated"
            },
            "tags": [],
            "createdAt": "2026-06-25T08:00:00+08:00",
            "updatedAt": "2026-06-25T09:30:00+08:00"
        },
        {
            "id": "acct_psbc_student_loan",
            "displayName": "邮储助学贷款",
            "institutionName": "中国邮政储蓄银行",
            "accountType": "loan",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "visibility": "normal",
            "status": "active",
            "balanceMode": "liability",
            "cashBalances": [
                {
                    "currency": "CNY",
                    "amount": "-9620.00",
                    "asOf": "2026-06-25T09:30:00+08:00",
                    "quality": "exact"
                }
            ],
            "value": {
                "amount": "-9620.00",
                "currency": "CNY",
                "asOf": "2026-06-25T09:30:00+08:00",
                "quality": "exact"
            },
            "tags": ["student_loan"],
            "note": "在校贴息；负数是正常负债，不触发 negative_balance。",
            "createdAt": "2026-06-25T08:00:00+08:00",
            "updatedAt": "2026-06-25T09:30:00+08:00"
        }
    ])
}

fn dev_holdings() -> Value {
    let overview = example_data(OVERVIEW_DEGRADED);
    let mut holdings = overview["primaryHoldings"]
        .as_array()
        .expect("primaryHoldings should be an array")
        .clone();
    holdings.push(json!({
        "id": "holding_btc_crypto",
        "accountId": "acct_crypto",
        "instrumentId": "inst_btc",
        "instrument": {
            "id": "inst_btc",
            "type": "crypto",
            "symbol": "BTC",
            "displayName": "Bitcoin",
            "quoteCurrency": "USDT",
            "market": "CRYPTO"
        },
        "quantity": "0.0300",
        "costBasisTotal": {"amount": "17770.00", "currency": "CNY"},
        "marketValue": {
            "amount": "18870.00",
            "currency": "CNY",
            "asOf": "2026-06-25T09:30:00+08:00",
            "quality": "estimated"
        },
        "unrealizedPnl": {"amount": "1100.00", "currency": "CNY"},
        "unrealizedPnlRate": "0.0619",
        "quoteStatus": "fresh",
        "asOf": "2026-06-25T09:30:00+08:00"
    }));
    json!(holdings)
}

fn dev_movements() -> Value {
    let overview = example_data(OVERVIEW_DEGRADED);
    let mut movements = overview["recentMovements"]
        .as_array()
        .expect("recentMovements should be an array")
        .clone();
    movements.push(json!({
        "id": "mov_luckin_001",
        "atomicGroupId": "ag_luckin_001",
        "type": "expense",
        "occurredAt": "2026-06-24T18:40:00+08:00",
        "recordedAt": "2026-06-24T18:41:00+08:00",
        "status": "confirmed",
        "title": "瑞幸咖啡",
        "entries": [
            {
                "id": "entry_luckin_paid",
                "accountId": "acct_cmb_cny",
                "amount": "18.00",
                "currency": "CNY",
                "direction": "out",
                "role": "source"
            }
        ],
        "amountBreakdown": {
            "grossAmount": {"amount": "28.00", "currency": "CNY"},
            "savingsAmount": {"amount": "10.00", "currency": "CNY"},
            "paidAmount": {"amount": "18.00", "currency": "CNY"},
            "savingsKind": "merchant_discount"
        },
        "tags": ["coffee"],
        "source": {"kind": "manual", "createdBy": "user"},
        "createdAt": "2026-06-24T18:41:00+08:00",
        "updatedAt": "2026-06-24T18:41:00+08:00"
    }));
    json!(movements)
}

fn dev_account_anomalies() -> Value {
    json!([
        {
            "id": "anom_broker_quote_stale",
            "accountId": "acct_us_broker",
            "accountName": "美股券商",
            "kind": "quote_stale",
            "severity": "warning",
            "detail": "NVDA 报价已过期，当前使用本地缓存估值。",
            "action": "refresh",
            "createdAt": "2026-06-25T09:30:00+08:00"
        }
    ])
}

fn dev_asset_allocation() -> Value {
    json!({
        "slices": [
            {
                "category": "现金与活期",
                "percent": "30.5",
                "value": {"amount": "77900.45", "currency": "CNY"}
            },
            {
                "category": "美股",
                "percent": "43.2",
                "value": {"amount": "110320.00", "currency": "CNY"}
            },
            {
                "category": "数字资产",
                "percent": "12.5",
                "value": {"amount": "31870.00", "currency": "CNY"}
            },
            {
                "category": "其他资产",
                "percent": "13.8",
                "value": {"amount": "35208.45", "currency": "CNY"}
            }
        ],
        "totalAssets": {"amount": "255298.90", "currency": "CNY"},
        "totalLiabilities": {"amount": "9620.00", "currency": "CNY"},
        "netWorth": {"amount": "245678.90", "currency": "CNY"}
    })
}

fn dev_dca_plans() -> Value {
    json!([
        {
            "id": "plan_csi300",
            "displayName": "沪深300ETF",
            "targetInstrumentId": "inst_csi300_fund",
            "fundingAccountId": "acct_cmb_cny",
            "plannedAmount": {"amount": "1000.00", "currency": "CNY"},
            "frequency": "monthly",
            "nextDueDate": "2026-07-10",
            "reminderStatus": "active",
            "note": "只提醒与记录，不下单。",
            "lastActionAt": null
        },
        {
            "id": "plan_nasdaq",
            "displayName": "纳指ETF",
            "targetInstrumentId": "inst_nasdaq_fund",
            "fundingAccountId": "acct_cmb_cny",
            "plannedAmount": {"amount": "800.00", "currency": "CNY"},
            "frequency": "monthly",
            "nextDueDate": "2026-07-25",
            "reminderStatus": "active",
            "note": "只提醒与记录，不下单。",
            "lastActionAt": null
        }
    ])
}

fn dev_dca_reminders() -> Value {
    json!([
        {
            "id": "rem_csi300_20260710",
            "planId": "plan_csi300",
            "displayName": "沪深300ETF",
            "plannedAmount": {"amount": "1000.00", "currency": "CNY"},
            "dueDate": "2026-07-10",
            "status": "due"
        }
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::{Body, to_bytes},
        http::{Method, Request},
    };
    use tower::ServiceExt;

    #[test]
    fn refuses_non_loopback_addresses() {
        let result = std::panic::catch_unwind(|| {
            assert_loopback("0.0.0.0:8790".parse().expect("valid socket addr"));
        });
        assert!(result.is_err());
    }

    #[test]
    fn reads_cli_port_and_addr() {
        assert_eq!(
            read_addr_from(["finwealth-server", "--port", "8791"]),
            "127.0.0.1:8791".parse().expect("valid socket addr")
        );
        assert_eq!(
            read_addr_from(["finwealth-server", "--addr", "127.0.0.1:8792"]),
            "127.0.0.1:8792".parse().expect("valid socket addr")
        );
    }

    #[test]
    fn reads_local_ledger_cli_commands() {
        assert_eq!(
            read_ledger_command_from(["finwealth-server", "--init-ledger", "ledger.json"]),
            Some(LedgerCommand::Init(PathBuf::from("ledger.json")))
        );
        assert_eq!(
            read_ledger_command_from(["finwealth-server", "--validate-ledger", "ledger.json"]),
            Some(LedgerCommand::Validate(PathBuf::from("ledger.json")))
        );
        assert_eq!(
            read_ledger_command_from([
                "finwealth-server",
                "--check-ledger-paths",
                "ledger.json",
                "ledger.fixture.json"
            ]),
            Some(LedgerCommand::CheckPaths {
                real_path: PathBuf::from("ledger.json"),
                fixture_path: PathBuf::from("ledger.fixture.json")
            })
        );
        assert_eq!(
            read_ledger_command_from(["finwealth-server", "--port", "8791"]),
            None
        );
    }

    #[test]
    fn reads_hash_password_stdin_flag() {
        assert!(should_hash_password_from_stdin([
            "finwealth-server",
            "--hash-password-stdin"
        ]));
        assert!(!should_hash_password_from_stdin(["finwealth-server"]));
    }

    #[test]
    fn reads_local_ledger_server_path() {
        assert_eq!(
            read_ledger_path(["finwealth-server", "--ledger-path", "ledger.json"]),
            Some(PathBuf::from("ledger.json"))
        );
        assert_eq!(
            read_ledger_path([
                "finwealth-server",
                "--port",
                "8791",
                "--ledger-path",
                "ledger.json"
            ]),
            Some(PathBuf::from("ledger.json"))
        );
    }

    #[test]
    fn examples_parse() {
        for raw in [
            EMPTY_BOOTSTRAP,
            OVERVIEW_EMPTY,
            OVERVIEW_DEGRADED,
            AI_DIFF,
            DCA_PROPOSAL,
            QUOTE_STALE,
        ] {
            let parsed: Value = serde_json::from_str(raw).expect("example should parse");
            assert_eq!(parsed["ok"], true);
        }
    }

    #[test]
    fn dev_ledger_core_separates_empty_and_degraded_scenarios() {
        let core = DevLedgerCore::new();

        assert_eq!(core.accounts(DevScenario::Empty), json!([]));
        assert_eq!(core.holdings(DevScenario::Empty), json!([]));
        assert_eq!(core.movements(DevScenario::Empty), json!([]));
        assert_eq!(core.ai_pending(DevScenario::Empty), json!([]));

        assert_eq!(
            core.accounts(DevScenario::Degraded)
                .as_array()
                .expect("degraded accounts should be an array")
                .len(),
            4
        );
        assert_eq!(
            core.quote_summary(DevScenario::Degraded)["staleCount"],
            json!(2)
        );
        assert!(
            core.ai_proposal(DevScenario::Degraded, "proposal_ai_001")
                .is_some()
        );
    }

    async fn request_json(method: Method, uri: &str) -> (StatusCode, Value) {
        request_json_from(app(), method, uri).await
    }

    async fn request_json_from(router: Router, method: Method, uri: &str) -> (StatusCode, Value) {
        request_json_body_from(router, method, uri, json!({})).await
    }

    async fn request_json_body_from(
        router: Router,
        method: Method,
        uri: &str,
        body: Value,
    ) -> (StatusCode, Value) {
        let response = router
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(uri)
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::to_vec(&body).expect("request body should serialize"),
                    ))
                    .expect("request should build"),
            )
            .await
            .expect("router should respond");
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 1024 * 1024)
            .await
            .expect("response body should read");
        let body = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).expect("response body should be JSON")
        };
        (status, body)
    }

    #[tokio::test]
    async fn auth_login_refresh_devices_and_revoke_use_hashed_passwords() {
        let auth = AuthStore::configured("wu", hash_password_for_test("correct horse"));
        let router = app_with_state(AppState::dev().with_auth(auth));

        let (wrong_status, wrong_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/auth/login",
            json!({
                "username": "wu",
                "password": "wrong",
                "deviceName": "Windows"
            }),
        )
        .await;
        assert_eq!(wrong_status, StatusCode::UNAUTHORIZED);
        assert_eq!(wrong_body["error"]["code"], "invalid_credentials");
        assert!(
            !wrong_body.to_string().contains("wrong"),
            "auth errors must not echo password material"
        );

        let (login_status, login_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/auth/login",
            json!({
                "username": "wu",
                "password": "correct horse",
                "deviceName": "Windows"
            }),
        )
        .await;
        assert_eq!(login_status, StatusCode::OK);
        assert!(
            login_body["data"]["accessToken"]
                .as_str()
                .unwrap()
                .starts_with("fw_access_")
        );
        assert!(
            login_body["data"]["refreshToken"]
                .as_str()
                .unwrap()
                .starts_with("fw_refresh_")
        );
        let refresh_token = login_body["data"]["refreshToken"]
            .as_str()
            .expect("refresh token should be string")
            .to_string();
        let device_id = login_body["data"]["deviceId"]
            .as_str()
            .expect("device id should be string")
            .to_string();

        let (devices_status, devices_body) =
            request_json_from(router.clone(), Method::GET, "/v1/auth/devices").await;
        assert_eq!(devices_status, StatusCode::OK);
        assert_eq!(devices_body["data"][0]["id"], device_id);
        assert_eq!(devices_body["data"][0]["name"], "Windows");
        assert!(!devices_body.to_string().contains("refreshToken"));
        assert!(!devices_body.to_string().contains("accessToken"));

        let (refresh_status, refresh_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/auth/refresh",
            json!({ "refreshToken": refresh_token }),
        )
        .await;
        assert_eq!(refresh_status, StatusCode::OK);
        let rotated_refresh_token = refresh_body["data"]["refreshToken"]
            .as_str()
            .expect("rotated refresh token should be string")
            .to_string();
        assert_ne!(rotated_refresh_token, refresh_token);

        let (old_refresh_status, _) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/auth/refresh",
            json!({ "refreshToken": refresh_token }),
        )
        .await;
        assert_eq!(old_refresh_status, StatusCode::UNAUTHORIZED);

        let (logout_status, logout_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/auth/logout",
            json!({ "refreshToken": rotated_refresh_token }),
        )
        .await;
        assert_eq!(logout_status, StatusCode::NO_CONTENT);
        assert_eq!(logout_body, Value::Null);

        let (devices_after_logout_status, devices_after_logout_body) =
            request_json_from(router.clone(), Method::GET, "/v1/auth/devices").await;
        assert_eq!(devices_after_logout_status, StatusCode::OK);
        assert_eq!(devices_after_logout_body["data"], json!([]));

        let (login_again_status, login_again_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/auth/login",
            json!({
                "username": "wu",
                "password": "correct horse",
                "deviceName": "Android"
            }),
        )
        .await;
        assert_eq!(login_again_status, StatusCode::OK);
        let second_device_id = login_again_body["data"]["deviceId"]
            .as_str()
            .expect("device id should be string")
            .to_string();
        let (revoke_status, revoke_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/auth/devices/{second_device_id}/revoke"),
        )
        .await;
        assert_eq!(revoke_status, StatusCode::NO_CONTENT);
        assert_eq!(revoke_body, Value::Null);

        let (_, final_devices_body) =
            request_json_from(router, Method::GET, "/v1/auth/devices").await;
        assert_eq!(final_devices_body["data"], json!([]));
    }

    #[tokio::test]
    async fn local_ledger_bootstrap_and_sync_cursor_use_real_local_state() {
        let path = unique_test_ledger_path("bootstrap_sync_cursor");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let account_input = json!({
            "displayName": "同步账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "88.00"}
            ]
        });
        let (account_status, _) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", account_input)
                .await;
        assert_eq!(account_status, StatusCode::CREATED);

        let mut document = local_ledger::read_document(&path).expect("ledger should be readable");
        document["syncState"]["cursor"] = json!("cursor_test_001");
        local_ledger::write_document(&path, &document).expect("ledger cursor should persist");

        let (bootstrap_status, bootstrap_body) =
            request_json_from(router.clone(), Method::GET, "/v1/ledger/bootstrap").await;
        assert_eq!(bootstrap_status, StatusCode::OK);
        assert_eq!(bootstrap_body["data"]["ledgerVersion"], 1);
        assert_eq!(bootstrap_body["data"]["syncCursor"], "cursor_test_001");
        assert_eq!(
            bootstrap_body["data"]["accounts"][0]["displayName"],
            "同步账户"
        );
        assert_eq!(
            bootstrap_body["data"]["snapshot"]["netWorth"]["amount"],
            "88.00"
        );

        let (sync_status, sync_body) =
            request_json_from(router.clone(), Method::GET, "/v1/sync/changes").await;
        assert_eq!(sync_status, StatusCode::OK);
        assert_eq!(sync_body["data"]["cursor"], "cursor_test_001");
        assert_eq!(sync_body["data"]["changes"], json!([]));

        let (push_status, push_body) = request_json_body_from(
            router,
            Method::POST,
            "/v1/sync/push",
            json!({
                "deviceId": "device_test",
                "changes": [
                    {
                        "id": "change_demo",
                        "deviceId": "device_test",
                        "entityType": "account",
                        "entityId": "acct_demo",
                        "operation": "create",
                        "payload": {"source": "demo"},
                        "createdAt": "2026-06-28T00:00:00Z"
                    }
                ]
            }),
        )
        .await;
        assert_eq!(push_status, StatusCode::BAD_REQUEST);
        assert_eq!(push_body["error"]["code"], "invalid_sync_push");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_accounts_route_reads_creates_and_persists_accounts() {
        let path = unique_test_ledger_path("route_accounts");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (empty_status, empty_body) =
            request_json_from(router.clone(), Method::GET, "/v1/accounts").await;
        assert_eq!(empty_status, StatusCode::OK);
        assert_eq!(empty_body["data"], json!([]));

        let create_input = json!({
            "displayName": "建行卡",
            "institutionName": "中国建设银行",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {
                    "currency": "CNY",
                    "amount": "123.45"
                }
            ]
        });
        let (create_status, create_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", create_input)
                .await;
        assert_eq!(create_status, StatusCode::CREATED);
        assert_eq!(create_body["data"]["displayName"], "建行卡");
        assert_eq!(create_body["data"]["value"]["amount"], "123.45");
        assert_eq!(create_body["data"]["value"]["currency"], "CNY");
        let account_id = create_body["data"]["id"]
            .as_str()
            .expect("created account id should be string")
            .to_string();

        let (list_status, list_body) =
            request_json_from(router.clone(), Method::GET, "/v1/accounts").await;
        assert_eq!(list_status, StatusCode::OK);
        assert_eq!(
            list_body["data"]
                .as_array()
                .expect("accounts should be an array")
                .len(),
            1
        );
        assert_eq!(list_body["data"][0]["id"], account_id);
        assert_eq!(list_body["data"][0]["value"]["amount"], "123.45");

        let (detail_status, detail_body) =
            request_json_from(router, Method::GET, &format!("/v1/accounts/{account_id}")).await;
        assert_eq!(detail_status, StatusCode::OK);
        assert_eq!(detail_body["data"]["id"], account_id);

        let persisted = local_ledger::read_document(&path).expect("ledger should persist account");
        assert_eq!(persisted["accounts"][0]["displayName"], "建行卡");
        assert!(
            persisted["accounts"][0].get("value").is_none(),
            "derived account value must not be persisted into the ledger file"
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_account_patch_and_archive_update_persisted_summary() {
        let path = unique_test_ledger_path("patch_archive_account");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let create_input = json!({
            "displayName": "建行卡",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "100.00"}
            ]
        });
        let (create_status, create_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", create_input)
                .await;
        assert_eq!(create_status, StatusCode::CREATED);
        let account_id = create_body["data"]["id"]
            .as_str()
            .expect("account id should be string")
            .to_string();

        let patch = json!({
            "displayName": "建行工资卡",
            "cashBalances": [
                {"currency": "CNY", "amount": "200.50"}
            ],
            "tags": ["工资卡"],
            "note": "手动校准余额"
        });
        let (patch_status, patch_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/accounts/{account_id}"),
            patch,
        )
        .await;
        assert_eq!(patch_status, StatusCode::OK);
        assert_eq!(patch_body["data"]["displayName"], "建行工资卡");
        assert_eq!(patch_body["data"]["value"]["amount"], "200.50");
        assert_eq!(patch_body["data"]["tags"][0], "工资卡");

        let (overview_status, overview_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_status, StatusCode::OK);
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["netWorth"]["amount"],
            "200.50"
        );

        let invalid_patch = json!({"id": "acct_should_not_change"});
        let (invalid_status, invalid_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/accounts/{account_id}"),
            invalid_patch,
        )
        .await;
        assert_eq!(invalid_status, StatusCode::BAD_REQUEST);
        assert_eq!(invalid_body["error"]["code"], "invalid_account_patch");

        let (archive_status, archive_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/accounts/{account_id}/archive"),
        )
        .await;
        assert_eq!(archive_status, StatusCode::OK);
        assert_eq!(archive_body["data"]["status"], "archived");
        assert_eq!(archive_body["data"]["visibility"], "archived");

        let (after_archive_status, after_archive_body) =
            request_json_from(router, Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(after_archive_status, StatusCode::OK);
        assert_eq!(after_archive_body["data"]["latestSnapshot"], Value::Null);

        let persisted = local_ledger::read_document(&path).expect("ledger should persist patch");
        assert_eq!(persisted["accounts"][0]["displayName"], "建行工资卡");
        assert_eq!(
            persisted["accounts"][0]["cashBalances"][0]["amount"],
            "200.50"
        );
        assert_eq!(persisted["accounts"][0]["status"], "archived");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_overview_and_allocation_are_computed_from_accounts() {
        let path = unique_test_ledger_path("route_overview");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let asset_input = json!({
            "displayName": "建行卡",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "123.45"}
            ]
        });
        let liability_input = json!({
            "displayName": "助学贷款",
            "accountType": "loan",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "liability",
            "openingBalances": [
                {"currency": "CNY", "amount": "-20.00"}
            ]
        });

        let (asset_status, _) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", asset_input).await;
        assert_eq!(asset_status, StatusCode::CREATED);
        let (liability_status, _) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            liability_input,
        )
        .await;
        assert_eq!(liability_status, StatusCode::CREATED);

        let (overview_status, overview_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_status, StatusCode::OK);
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["grossAssets"]["amount"],
            "123.45"
        );
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["totalLiabilities"]["amount"],
            "20.00"
        );
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["netWorth"]["amount"],
            "103.45"
        );
        assert_eq!(overview_body["data"]["latestSnapshot"]["quality"], "exact");
        assert_eq!(
            overview_body["data"]["pendingSummary"]["quoteProblemCount"],
            0
        );

        let (allocation_status, allocation_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/allocation").await;
        assert_eq!(allocation_status, StatusCode::OK);
        assert_eq!(allocation_body["data"]["totalAssets"]["amount"], "123.45");
        assert_eq!(
            allocation_body["data"]["totalLiabilities"]["amount"],
            "20.00"
        );
        assert_eq!(allocation_body["data"]["netWorth"]["amount"], "103.45");
        assert_eq!(allocation_body["data"]["slices"][0]["category"], "现金");
        assert_eq!(allocation_body["data"]["slices"][0]["percent"], "100.0");

        let (snapshot_status, snapshot_body) =
            request_json_from(router.clone(), Method::GET, "/v1/snapshots/latest").await;
        assert_eq!(snapshot_status, StatusCode::OK);
        assert_eq!(snapshot_body["data"]["netWorth"]["amount"], "103.45");

        let (quote_status, quote_body) =
            request_json_from(router, Method::GET, "/v1/quotes/summary").await;
        assert_eq!(quote_status, StatusCode::OK);
        assert_eq!(quote_body["data"]["unpriceableCount"], 0);

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_movement_draft_review_and_confirm_updates_balances() {
        let path = unique_test_ledger_path("movement_confirm");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let create_account_input = json!({
            "displayName": "招行卡",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "100.00"}
            ]
        });
        let (account_status, account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            create_account_input,
        )
        .await;
        assert_eq!(account_status, StatusCode::CREATED);
        let account_id = account_body["data"]["id"]
            .as_str()
            .expect("account id should be a string")
            .to_string();

        let draft_input = json!({
            "type": "expense",
            "occurredAt": "2026-06-26T10:00:00+08:00",
            "title": "瑞幸咖啡",
            "entries": [
                {
                    "accountId": account_id,
                    "amount": "18.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                }
            ],
            "amountBreakdown": {
                "grossAmount": {"amount": "28.00", "currency": "CNY"},
                "savingsAmount": {"amount": "10.00", "currency": "CNY"},
                "paidAmount": {"amount": "18.00", "currency": "CNY"},
                "benefitSource": "merchant_discount"
            },
            "tags": ["coffee"]
        });
        let (draft_status, draft_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            draft_input,
        )
        .await;
        assert_eq!(draft_status, StatusCode::CREATED);
        assert_eq!(draft_body["data"]["status"], "draft");
        assert_eq!(draft_body["data"]["displayAmount"]["amount"], "18.00");
        let movement_id = draft_body["data"]["id"]
            .as_str()
            .expect("movement id should be a string")
            .to_string();
        let atomic_group_id = draft_body["data"]["atomicGroupId"]
            .as_str()
            .expect("atomic group id should be a string")
            .to_string();

        let (overview_before_status, overview_before_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_before_status, StatusCode::OK);
        assert_eq!(
            overview_before_body["data"]["latestSnapshot"]["netWorth"]["amount"],
            "100.00"
        );

        let (submit_status, submit_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/movements/{movement_id}/submit-review"),
        )
        .await;
        assert_eq!(submit_status, StatusCode::OK);
        assert_eq!(submit_body["data"]["id"], atomic_group_id);
        assert_eq!(submit_body["data"]["status"], "pending");
        assert_eq!(
            submit_body["data"]["proposedMovements"][0]["status"],
            "pending_review"
        );

        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{atomic_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK);
        assert_eq!(confirm_body["data"]["ledgerWrite"], true);
        assert_eq!(confirm_body["data"]["confirmedMovementIds"][0], movement_id);

        let (account_after_status, account_after_body) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{account_id}"),
        )
        .await;
        assert_eq!(account_after_status, StatusCode::OK);
        assert_eq!(account_after_body["data"]["value"]["amount"], "82.00");

        let (movement_after_status, movement_after_body) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/movements/{movement_id}"),
        )
        .await;
        assert_eq!(movement_after_status, StatusCode::OK);
        assert_eq!(movement_after_body["data"]["status"], "confirmed");

        let persisted = local_ledger::read_document(&path).expect("ledger should persist movement");
        assert_eq!(
            persisted["movementEntries"][0]["movementId"],
            movement_after_body["data"]["id"]
        );
        assert_eq!(
            persisted["accounts"][0]["cashBalances"][0]["amount"],
            "82.00"
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_confirmed_buy_updates_holdings_without_distorting_net_worth() {
        let path = unique_test_ledger_path("buy_holding");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let cash_input = json!({
            "displayName": "现金账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "1000.00"}
            ]
        });
        let (cash_status, cash_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", cash_input).await;
        assert_eq!(cash_status, StatusCode::CREATED);
        let cash_account_id = cash_body["data"]["id"]
            .as_str()
            .expect("cash account id should be string")
            .to_string();

        let brokerage_input = json!({
            "displayName": "基金账户",
            "accountType": "brokerage",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "holdings",
            "openingBalances": [
                {"currency": "CNY", "amount": "0.00"}
            ]
        });
        let (brokerage_status, brokerage_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            brokerage_input,
        )
        .await;
        assert_eq!(brokerage_status, StatusCode::CREATED);
        let brokerage_account_id = brokerage_body["data"]["id"]
            .as_str()
            .expect("brokerage account id should be string")
            .to_string();

        let draft_input = json!({
            "type": "buy",
            "occurredAt": "2026-06-26T11:00:00+08:00",
            "title": "记录沪深300定投",
            "entries": [
                {
                    "accountId": cash_account_id,
                    "amount": "100.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": brokerage_account_id,
                    "instrumentId": "inst_csi300_fund",
                    "amount": "100.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                }
            ],
            "tags": ["dca"]
        });
        let (draft_status, draft_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            draft_input,
        )
        .await;
        assert_eq!(draft_status, StatusCode::CREATED);
        let atomic_group_id = draft_body["data"]["atomicGroupId"]
            .as_str()
            .expect("atomic group id should be string")
            .to_string();

        let (before_status, before_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(before_status, StatusCode::OK);
        assert_eq!(
            before_body["data"]["latestSnapshot"]["netWorth"]["amount"],
            "1000.00"
        );
        assert_eq!(before_body["data"]["primaryHoldings"], json!([]));

        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{atomic_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK);
        assert_eq!(confirm_body["data"]["ledgerWrite"], true);

        let (cash_after_status, cash_after_body) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{cash_account_id}"),
        )
        .await;
        assert_eq!(cash_after_status, StatusCode::OK);
        assert_eq!(cash_after_body["data"]["value"]["amount"], "900.00");

        let (all_holdings_status, all_holdings_body) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(all_holdings_status, StatusCode::OK);
        assert_eq!(
            all_holdings_body["data"][0]["instrumentId"],
            "inst_csi300_fund"
        );
        assert_eq!(all_holdings_body["data"][0]["quantity"], "100");
        assert_eq!(
            all_holdings_body["data"][0]["marketValue"]["amount"],
            "100.00"
        );
        assert_eq!(all_holdings_body["data"][0]["quoteStatus"], "stale");

        let (brokerage_holdings_status, brokerage_holdings_body) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{brokerage_account_id}/holdings"),
        )
        .await;
        assert_eq!(brokerage_holdings_status, StatusCode::OK);
        assert_eq!(
            brokerage_holdings_body["data"]
                .as_array()
                .expect("holdings")
                .len(),
            1
        );

        let (after_status, after_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(after_status, StatusCode::OK);
        assert_eq!(
            after_body["data"]["latestSnapshot"]["netWorth"]["amount"],
            "1000.00"
        );
        assert_eq!(
            after_body["data"]["latestSnapshot"]["quoteStatusSummary"]["staleCount"],
            1
        );
        assert_eq!(
            after_body["data"]["primaryHoldings"][0]["quoteStatus"],
            "stale"
        );

        let persisted = local_ledger::read_document(&path).expect("ledger should persist holding");
        assert_eq!(persisted["instruments"][0]["id"], "inst_csi300_fund");
        assert_eq!(persisted["holdings"][0]["quantity"], "100");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_movement_draft_rejects_unknown_account() {
        let path = unique_test_ledger_path("movement_invalid_account");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let draft_input = json!({
            "type": "expense",
            "occurredAt": "2026-06-26T10:00:00+08:00",
            "title": "不存在账户消费",
            "entries": [
                {
                    "accountId": "acct_missing",
                    "amount": "18.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                }
            ]
        });
        let (status, body) =
            request_json_body_from(router, Method::POST, "/v1/movements/drafts", draft_input).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"]["code"], "invalid_movement_draft_input");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_quote_refresh_revalues_holdings_from_cache() {
        let path = unique_test_ledger_path("quote_refresh_holding");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let cash_input = json!({
            "displayName": "现金账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "1000.00"}
            ]
        });
        let (cash_status, cash_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", cash_input).await;
        assert_eq!(cash_status, StatusCode::CREATED);
        let cash_account_id = cash_body["data"]["id"].as_str().expect("cash id");

        let brokerage_input = json!({
            "displayName": "基金账户",
            "accountType": "brokerage",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "holdings",
            "openingBalances": [
                {"currency": "CNY", "amount": "0.00"}
            ]
        });
        let (brokerage_status, brokerage_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            brokerage_input,
        )
        .await;
        assert_eq!(brokerage_status, StatusCode::CREATED);
        let brokerage_account_id = brokerage_body["data"]["id"].as_str().expect("brokerage id");

        let draft_input = json!({
            "type": "buy",
            "occurredAt": "2026-06-26T11:00:00+08:00",
            "title": "记录沪深300定投",
            "entries": [
                {
                    "accountId": cash_account_id,
                    "amount": "100.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": brokerage_account_id,
                    "instrumentId": "inst_csi300_fund",
                    "amount": "100.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                }
            ]
        });
        let (_, draft_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            draft_input,
        )
        .await;
        let atomic_group_id = draft_body["data"]["atomicGroupId"]
            .as_str()
            .expect("atomic group id");
        let (confirm_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{atomic_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK);

        let (refresh_status, refresh_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/quotes/refresh",
            json!({
                "mode": "manual",
                "quotes": [{
                    "instrumentId": "inst_csi300_fund",
                    "price": "2.00",
                    "currency": "CNY",
                    "asOf": "2026-06-28T09:30:00Z",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "source": "test"
                }]
            }),
        )
        .await;
        assert_eq!(refresh_status, StatusCode::OK);
        assert_eq!(refresh_body["data"]["status"], "success");
        assert_eq!(
            refresh_body["data"]["quotes"]
                .as_array()
                .expect("quotes")
                .len(),
            1
        );

        let (holdings_status, holdings_body) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(holdings_status, StatusCode::OK);
        assert_eq!(holdings_body["data"][0]["marketValue"]["amount"], "200.00");
        assert_eq!(holdings_body["data"][0]["quoteStatus"], "fresh");

        let (overview_status, overview_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_status, StatusCode::OK);
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["netWorth"]["amount"],
            "1100.00"
        );
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["quoteStatusSummary"]["freshCount"],
            1
        );
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["quoteStatusSummary"]["staleCount"],
            0
        );

        let persisted =
            local_ledger::read_document(&path).expect("ledger should persist refreshed quote");
        assert_eq!(persisted["quotes"][0]["instrumentId"], "inst_csi300_fund");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_quote_refresh_reports_missing_symbol_without_fabricating_price() {
        let path = unique_test_ledger_path("quote_refresh_missing_symbol");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let cash_input = json!({
            "displayName": "现金账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "1000.00"}
            ]
        });
        let (_, cash_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", cash_input).await;
        let cash_account_id = cash_body["data"]["id"].as_str().expect("cash id");

        let brokerage_input = json!({
            "displayName": "基金账户",
            "accountType": "brokerage",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "holdings",
            "openingBalances": [
                {"currency": "CNY", "amount": "0.00"}
            ]
        });
        let (_, brokerage_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            brokerage_input,
        )
        .await;
        let brokerage_account_id = brokerage_body["data"]["id"].as_str().expect("brokerage id");

        let draft_input = json!({
            "type": "buy",
            "occurredAt": "2026-06-26T11:00:00+08:00",
            "title": "记录自定义基金",
            "entries": [
                {
                    "accountId": cash_account_id,
                    "amount": "100.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": brokerage_account_id,
                    "instrumentId": "inst_custom_fund",
                    "amount": "100.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                }
            ]
        });
        let (_, draft_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            draft_input,
        )
        .await;
        let atomic_group_id = draft_body["data"]["atomicGroupId"]
            .as_str()
            .expect("atomic group id");
        let (confirm_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{atomic_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK);

        let (refresh_status, refresh_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/quotes/refresh",
            json!({"mode": "manual"}),
        )
        .await;
        assert_eq!(refresh_status, StatusCode::OK);
        assert_eq!(refresh_body["data"]["status"], "offline");
        assert_eq!(refresh_body["data"]["quotes"], json!([]));
        assert_eq!(
            refresh_body["data"]["errors"][0]["message"],
            "instrument has no Yahoo symbol; add symbol or pass manual quote payload"
        );

        let persisted = local_ledger::read_document(&path).expect("ledger should be readable");
        assert_eq!(persisted["quotes"], json!([]));

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_instrument_patch_supplies_quote_refresh_symbol() {
        let path = unique_test_ledger_path("instrument_patch_symbol");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let cash_input = json!({
            "displayName": "现金账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "1000.00"}
            ]
        });
        let (_, cash_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", cash_input).await;
        let cash_account_id = cash_body["data"]["id"].as_str().expect("cash id");

        let brokerage_input = json!({
            "displayName": "美股券商",
            "accountType": "brokerage",
            "defaultCurrency": "USD",
            "supportedCurrencies": ["USD", "CNY"],
            "includeInNetWorth": true,
            "balanceMode": "holdings",
            "openingBalances": [
                {"currency": "USD", "amount": "0.00"}
            ]
        });
        let (_, brokerage_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            brokerage_input,
        )
        .await;
        let brokerage_account_id = brokerage_body["data"]["id"].as_str().expect("brokerage id");

        let draft_input = json!({
            "type": "buy",
            "occurredAt": "2026-06-26T11:00:00+08:00",
            "title": "记录自定义美股",
            "entries": [
                {
                    "accountId": cash_account_id,
                    "amount": "100.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": brokerage_account_id,
                    "instrumentId": "inst_custom_stock",
                    "amount": "10.00",
                    "currency": "USD",
                    "direction": "in",
                    "role": "destination"
                }
            ]
        });
        let (_, draft_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            draft_input,
        )
        .await;
        let atomic_group_id = draft_body["data"]["atomicGroupId"]
            .as_str()
            .expect("atomic group id");
        let (confirm_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{atomic_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK);

        let (detail_before_status, detail_before_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/instruments/inst_custom_stock",
        )
        .await;
        assert_eq!(detail_before_status, StatusCode::OK);
        assert_eq!(detail_before_body["data"]["id"], "inst_custom_stock");
        assert!(detail_before_body["data"].get("symbol").is_none());

        let patch = json!({
            "type": "equity",
            "symbol": "AAPL",
            "displayName": "Apple Inc.",
            "quoteCurrency": "USD",
            "market": "US"
        });
        let (patch_status, patch_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            "/v1/instruments/inst_custom_stock",
            patch,
        )
        .await;
        assert_eq!(patch_status, StatusCode::OK);
        assert_eq!(patch_body["data"]["symbol"], "AAPL");
        assert_eq!(patch_body["data"]["quoteCurrency"], "USD");

        let targets = local_ledger::quote_refresh_targets(
            &path,
            &json!({"instruments": ["inst_custom_stock"]}),
        )
        .expect("quote targets should be readable");
        assert_eq!(targets[0]["instrumentId"], "inst_custom_stock");
        assert_eq!(targets[0]["symbol"], "AAPL");
        assert_eq!(targets[0]["quoteCurrency"], "USD");

        let (holdings_status, holdings_body) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(holdings_status, StatusCode::OK);
        assert_eq!(holdings_body["data"][0]["instrument"]["symbol"], "AAPL");
        assert_eq!(
            holdings_body["data"][0]["instrument"]["displayName"],
            "Apple Inc."
        );

        let create_input = json!({
            "id": "inst_manual_btc",
            "type": "crypto",
            "symbol": "BTC-USD",
            "displayName": "Bitcoin",
            "quoteCurrency": "USD",
            "market": "CRYPTO"
        });
        let (create_status, create_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/instruments",
            create_input,
        )
        .await;
        assert_eq!(create_status, StatusCode::CREATED);
        assert_eq!(create_body["data"]["id"], "inst_manual_btc");

        let invalid_patch = json!({"id": "inst_should_not_change"});
        let (invalid_status, invalid_body) = request_json_body_from(
            router,
            Method::PATCH,
            "/v1/instruments/inst_custom_stock",
            invalid_patch,
        )
        .await;
        assert_eq!(invalid_status, StatusCode::BAD_REQUEST);
        assert_eq!(invalid_body["error"]["code"], "invalid_instrument_patch");

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn historical_price_mapping_formats_yahoo_quotes() {
        let timestamp = OffsetDateTime::parse("2026-06-28T00:00:00Z", &Rfc3339)
            .expect("test timestamp should parse")
            .unix_timestamp();
        let points = historical_price_points_from_yahoo_quotes(
            "inst_aapl",
            "AAPL",
            "USD",
            &[yahoo::Quote {
                timestamp,
                open: 122.0,
                high: 124.0,
                low: 121.0,
                volume: 100,
                close: 123.45,
                adjclose: 123.45,
            }],
        );

        assert_eq!(points.len(), 1);
        assert_eq!(points[0]["instrumentId"], "inst_aapl");
        assert_eq!(points[0]["price"], "123.45");
        assert_eq!(points[0]["currency"], "USD");
        assert_eq!(points[0]["date"], "2026-06-28");
        assert_eq!(
            points[0]["sourceUrl"],
            "https://finance.yahoo.com/quote/AAPL/history"
        );
    }

    #[tokio::test]
    async fn local_ledger_historical_prices_validate_range_and_symbol() {
        let path = unique_test_ledger_path("historical_price_validation");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let create_input = json!({
            "id": "inst_no_symbol",
            "type": "fund",
            "displayName": "无代码基金",
            "quoteCurrency": "CNY"
        });
        let (create_status, _) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/instruments",
            create_input,
        )
        .await;
        assert_eq!(create_status, StatusCode::CREATED);

        let (range_status, range_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/instruments/inst_no_symbol/historical-prices?from=2026-06-28&to=2026-06-27",
        )
        .await;
        assert_eq!(range_status, StatusCode::BAD_REQUEST);
        assert_eq!(
            range_body["error"]["code"],
            "invalid_historical_price_range"
        );

        let (symbol_status, symbol_body) = request_json_from(
            router,
            Method::GET,
            "/v1/instruments/inst_no_symbol/historical-prices?from=2026-06-27&to=2026-06-28",
        )
        .await;
        assert_eq!(symbol_status, StatusCode::BAD_REQUEST);
        assert_eq!(symbol_body["error"]["code"], "missing_instrument_symbol");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_fx_refresh_values_non_base_cash() {
        let path = unique_test_ledger_path("fx_refresh_cash");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let usd_account = json!({
            "displayName": "美元虚拟卡",
            "accountType": "virtual_card",
            "defaultCurrency": "USD",
            "supportedCurrencies": ["USD"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "USD", "amount": "10.00"}
            ]
        });
        let (account_status, account_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", usd_account).await;
        assert_eq!(account_status, StatusCode::CREATED);
        let account_id = account_body["data"]["id"].as_str().expect("account id");

        let (refresh_status, refresh_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/quotes/refresh",
            json!({
                "mode": "manual",
                "fxRates": [{
                    "baseCurrency": "USD",
                    "quoteCurrency": "CNY",
                    "rate": "7.00",
                    "asOf": "2026-06-28T09:30:00Z",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "source": "test"
                }]
            }),
        )
        .await;
        assert_eq!(refresh_status, StatusCode::OK);
        assert_eq!(refresh_body["data"]["status"], "success");
        assert_eq!(
            refresh_body["data"]["fxRates"]
                .as_array()
                .expect("rates")
                .len(),
            1
        );

        let (account_after_status, account_after_body) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{account_id}"),
        )
        .await;
        assert_eq!(account_after_status, StatusCode::OK);
        assert_eq!(account_after_body["data"]["value"]["amount"], "70.00");
        assert_eq!(account_after_body["data"]["value"]["currency"], "CNY");

        let (overview_status, overview_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_status, StatusCode::OK);
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["netWorth"]["amount"],
            "70.00"
        );
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["quoteStatusSummary"]["freshCount"],
            1
        );

        let (rates_status, rates_body) =
            request_json_from(router.clone(), Method::GET, "/v1/fx-rates").await;
        assert_eq!(rates_status, StatusCode::OK);
        assert_eq!(rates_body["data"][0]["baseCurrency"], "USD");
        assert_eq!(rates_body["data"][0]["quoteCurrency"], "CNY");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_dca_plan_create_due_skip_and_snooze() {
        let path = unique_test_ledger_path("dca_plan");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let account_input = json!({
            "displayName": "定投资金账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "3000.00"}
            ]
        });
        let (account_status, account_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", account_input)
                .await;
        assert_eq!(account_status, StatusCode::CREATED);
        let account_id = account_body["data"]["id"]
            .as_str()
            .expect("account id should be string")
            .to_string();

        let create_plan_input = json!({
            "displayName": "沪深300ETF",
            "targetInstrumentId": "inst_csi300_fund",
            "fundingAccountId": account_id,
            "plannedAmount": {"amount": "1000.00", "currency": "CNY"},
            "frequency": "monthly",
            "nextDueDate": "2026-07-10",
            "note": "只提醒与记录，不下单。"
        });
        let (create_status, create_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/dca/plans",
            create_plan_input,
        )
        .await;
        assert_eq!(create_status, StatusCode::CREATED);
        assert_eq!(create_body["data"]["displayName"], "沪深300ETF");
        assert_eq!(create_body["data"]["reminderStatus"], "active");

        let (plans_status, plans_body) =
            request_json_from(router.clone(), Method::GET, "/v1/dca/plans").await;
        assert_eq!(plans_status, StatusCode::OK);
        assert_eq!(plans_body["data"][0]["plannedAmount"]["amount"], "1000.00");

        let (due_status, due_body) =
            request_json_from(router.clone(), Method::GET, "/v1/dca/reminders/due").await;
        assert_eq!(due_status, StatusCode::OK);
        assert_eq!(due_body["data"][0]["displayName"], "沪深300ETF");
        assert_eq!(due_body["data"][0]["status"], "due");
        let reminder_id = due_body["data"][0]["id"]
            .as_str()
            .expect("reminder id should be string")
            .to_string();

        let (overview_status, overview_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_status, StatusCode::OK);
        assert_eq!(overview_body["data"]["pendingSummary"]["dcaDueCount"], 1);

        let (skip_status, skip_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/dca/reminders/{reminder_id}/skip"),
        )
        .await;
        assert_eq!(skip_status, StatusCode::OK);
        assert_eq!(skip_body["data"]["status"], "skipped");

        let (due_after_skip_status, due_after_skip_body) =
            request_json_from(router.clone(), Method::GET, "/v1/dca/reminders/due").await;
        assert_eq!(due_after_skip_status, StatusCode::OK);
        assert_eq!(due_after_skip_body["data"], json!([]));

        let second_plan_input = json!({
            "displayName": "纳指ETF",
            "targetInstrumentId": "inst_nasdaq_fund",
            "plannedAmount": {"amount": "800.00", "currency": "CNY"},
            "frequency": "monthly",
            "nextDueDate": "2026-07-25"
        });
        let (second_status, _) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/dca/plans",
            second_plan_input,
        )
        .await;
        assert_eq!(second_status, StatusCode::CREATED);
        let (_, due_after_second_body) =
            request_json_from(router.clone(), Method::GET, "/v1/dca/reminders/due").await;
        let second_reminder_id = due_after_second_body["data"][0]["id"]
            .as_str()
            .expect("second reminder id should be string")
            .to_string();

        let (snooze_status, snooze_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &format!("/v1/dca/reminders/{second_reminder_id}/snooze"),
            json!({"until": "2026-07-26T09:00:00+08:00"}),
        )
        .await;
        assert_eq!(snooze_status, StatusCode::OK);
        assert_eq!(snooze_body["data"]["status"], "snoozed");
        assert_eq!(
            snooze_body["data"]["snoozedUntil"],
            "2026-07-26T09:00:00+08:00"
        );

        let persisted = local_ledger::read_document(&path).expect("ledger should persist DCA");
        assert_eq!(persisted["dcaPlans"].as_array().expect("plans").len(), 2);
        assert_eq!(persisted["dcaReminders"][0]["status"], "skipped");
        assert_eq!(persisted["dcaReminders"][1]["status"], "snoozed");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_dca_plan_patch_controls_due_reminders() {
        let path = unique_test_ledger_path("dca_plan_patch");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let account_input = json!({
            "displayName": "定投资金账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "3000.00"}
            ]
        });
        let (account_status, account_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", account_input)
                .await;
        assert_eq!(account_status, StatusCode::CREATED);
        let account_id = account_body["data"]["id"]
            .as_str()
            .expect("account id should be string")
            .to_string();

        let plan_input = json!({
            "displayName": "沪深300ETF",
            "targetInstrumentId": "inst_csi300_fund",
            "fundingAccountId": account_id,
            "plannedAmount": {"amount": "1000.00", "currency": "CNY"},
            "frequency": "monthly",
            "nextDueDate": "2026-07-10",
            "note": "只提醒与记录，不下单。"
        });
        let (create_status, create_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/dca/plans", plan_input).await;
        assert_eq!(create_status, StatusCode::CREATED);
        let plan_id = create_body["data"]["id"]
            .as_str()
            .expect("plan id should be string")
            .to_string();

        let (_, due_before_body) =
            request_json_from(router.clone(), Method::GET, "/v1/dca/reminders/due").await;
        assert_eq!(due_before_body["data"].as_array().expect("due").len(), 1);

        let (pause_status, pause_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/dca/plans/{plan_id}"),
            json!({"reminderStatus": "paused"}),
        )
        .await;
        assert_eq!(pause_status, StatusCode::OK);
        assert_eq!(pause_body["data"]["reminderStatus"], "paused");

        let (due_paused_status, due_paused_body) =
            request_json_from(router.clone(), Method::GET, "/v1/dca/reminders/due").await;
        assert_eq!(due_paused_status, StatusCode::OK);
        assert_eq!(due_paused_body["data"], json!([]));

        let (overview_status, overview_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_status, StatusCode::OK);
        assert_eq!(overview_body["data"]["pendingSummary"]["dcaDueCount"], 0);

        let (resume_status, resume_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/dca/plans/{plan_id}"),
            json!({
                "displayName": "沪深300增强",
                "plannedAmount": {"amount": "1200.00", "currency": "CNY"},
                "nextDueDate": "2026-08-10",
                "reminderStatus": "active",
                "note": null
            }),
        )
        .await;
        assert_eq!(resume_status, StatusCode::OK);
        assert_eq!(resume_body["data"]["displayName"], "沪深300增强");
        assert_eq!(resume_body["data"]["plannedAmount"]["amount"], "1200.00");
        assert_eq!(resume_body["data"]["nextDueDate"], "2026-08-10");
        assert!(resume_body["data"].get("note").is_none());

        let (due_resumed_status, due_resumed_body) =
            request_json_from(router.clone(), Method::GET, "/v1/dca/reminders/due").await;
        assert_eq!(due_resumed_status, StatusCode::OK);
        assert_eq!(due_resumed_body["data"].as_array().expect("due").len(), 1);
        assert_eq!(due_resumed_body["data"][0]["displayName"], "沪深300增强");
        assert_eq!(
            due_resumed_body["data"][0]["plannedAmount"]["amount"],
            "1200.00"
        );
        assert_eq!(due_resumed_body["data"][0]["dueDate"], "2026-08-10");

        let persisted =
            local_ledger::read_document(&path).expect("ledger should persist DCA patch");
        assert_eq!(persisted["dcaPlans"][0]["reminderStatus"], "active");
        assert_eq!(
            persisted["dcaPlans"][0]["plannedAmount"]["amount"],
            "1200.00"
        );
        assert_eq!(persisted["dcaReminders"][0]["displayName"], "沪深300增强");
        assert_eq!(persisted["dcaReminders"][0]["dueDate"], "2026-08-10");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_dca_mark_executed_creates_confirmable_holding_proposal() {
        let path = unique_test_ledger_path("dca_mark_executed");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let account_input = json!({
            "displayName": "基金现金账户",
            "accountType": "brokerage",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "mixed",
            "openingBalances": [
                {"currency": "CNY", "amount": "1000.00"}
            ]
        });
        let (account_status, account_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", account_input)
                .await;
        assert_eq!(account_status, StatusCode::CREATED);
        let account_id = account_body["data"]["id"]
            .as_str()
            .expect("account id should be string")
            .to_string();

        let plan_input = json!({
            "displayName": "沪深300ETF",
            "targetInstrumentId": "inst_csi300_fund",
            "fundingAccountId": account_id,
            "plannedAmount": {"amount": "200.00", "currency": "CNY"},
            "frequency": "monthly",
            "nextDueDate": "2026-07-10"
        });
        let (plan_status, _) =
            request_json_body_from(router.clone(), Method::POST, "/v1/dca/plans", plan_input).await;
        assert_eq!(plan_status, StatusCode::CREATED);
        let (_, due_body) =
            request_json_from(router.clone(), Method::GET, "/v1/dca/reminders/due").await;
        let reminder_id = due_body["data"][0]["id"]
            .as_str()
            .expect("reminder id should be string")
            .to_string();

        let (mark_status, mark_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/dca/reminders/{reminder_id}/mark-executed-as-proposal"),
        )
        .await;
        assert_eq!(mark_status, StatusCode::OK);
        assert_eq!(mark_body["data"]["status"], "pending");
        assert_eq!(
            mark_body["data"]["proposedMovements"][0]["status"],
            "pending_review"
        );
        let atomic_group_id = mark_body["data"]["id"]
            .as_str()
            .expect("atomic group id should be string")
            .to_string();

        let (holdings_before_status, holdings_before_body) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(holdings_before_status, StatusCode::OK);
        assert_eq!(holdings_before_body["data"], json!([]));

        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{atomic_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK);
        assert_eq!(confirm_body["data"]["ledgerWrite"], true);

        let (account_after_status, account_after_body) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{account_id}"),
        )
        .await;
        assert_eq!(account_after_status, StatusCode::OK);
        assert_eq!(account_after_body["data"]["value"]["amount"], "1000.00");

        let (holdings_after_status, holdings_after_body) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(holdings_after_status, StatusCode::OK);
        assert_eq!(
            holdings_after_body["data"][0]["instrumentId"],
            "inst_csi300_fund"
        );
        assert_eq!(
            holdings_after_body["data"][0]["marketValue"]["amount"],
            "200.00"
        );

        let (due_after_status, due_after_body) =
            request_json_from(router.clone(), Method::GET, "/v1/dca/reminders/due").await;
        assert_eq!(due_after_status, StatusCode::OK);
        assert_eq!(due_after_body["data"], json!([]));

        let persisted =
            local_ledger::read_document(&path).expect("ledger should persist DCA execution");
        assert_eq!(persisted["dcaReminders"][0]["status"], "recorded");
        assert_eq!(persisted["holdings"][0]["quantity"], "200");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_taxonomy_routes_create_update_and_persist() {
        let path = unique_test_ledger_path("taxonomy");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let category_input = json!({
            "displayName": "咖啡",
            "kind": "expense",
            "aiDescription": "咖啡、饮品类消费"
        });
        let (category_status, category_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/categories",
            category_input,
        )
        .await;
        assert_eq!(category_status, StatusCode::CREATED);
        assert_eq!(category_body["data"]["displayName"], "咖啡");
        assert_eq!(category_body["data"]["isSystem"], false);
        let category_id = category_body["data"]["id"]
            .as_str()
            .expect("category id should be string")
            .to_string();

        let (category_patch_status, category_patch_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/categories/{category_id}"),
            json!({"displayName": "咖啡饮品", "kind": "expense"}),
        )
        .await;
        assert_eq!(category_patch_status, StatusCode::OK);
        assert_eq!(category_patch_body["data"]["displayName"], "咖啡饮品");

        let counterparty_input = json!({
            "displayName": "瑞幸咖啡",
            "aliases": ["瑞幸", "luckin"],
            "categoryHintId": category_id
        });
        let (counterparty_status, counterparty_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/counterparties",
            counterparty_input,
        )
        .await;
        assert_eq!(counterparty_status, StatusCode::CREATED);
        assert_eq!(counterparty_body["data"]["normalizedName"], "瑞幸咖啡");
        let counterparty_id = counterparty_body["data"]["id"]
            .as_str()
            .expect("counterparty id should be string")
            .to_string();

        let (counterparty_patch_status, counterparty_patch_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/counterparties/{counterparty_id}"),
            json!({"aliases": ["瑞幸", "Luckin Coffee"], "isUserMerged": true}),
        )
        .await;
        assert_eq!(counterparty_patch_status, StatusCode::OK);
        assert_eq!(counterparty_patch_body["data"]["isUserMerged"], true);

        let (categories_status, categories_body) =
            request_json_from(router.clone(), Method::GET, "/v1/categories").await;
        assert_eq!(categories_status, StatusCode::OK);
        assert_eq!(
            categories_body["data"]
                .as_array()
                .expect("categories")
                .len(),
            1
        );

        let (counterparty_detail_status, counterparty_detail_body) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/counterparties/{counterparty_id}"),
        )
        .await;
        assert_eq!(counterparty_detail_status, StatusCode::OK);
        assert_eq!(
            counterparty_detail_body["data"]["aliases"][1],
            "Luckin Coffee"
        );

        let persisted = local_ledger::read_document(&path).expect("ledger should persist taxonomy");
        assert_eq!(persisted["categories"][0]["displayName"], "咖啡饮品");
        assert_eq!(persisted["counterparties"][0]["isUserMerged"], true);

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_counterparty_merge_proposal_requires_confirmation() {
        let path = unique_test_ledger_path("counterparty_merge");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (first_status, first_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/counterparties",
            json!({"displayName": "瑞幸", "aliases": ["luckin"]}),
        )
        .await;
        assert_eq!(first_status, StatusCode::CREATED);
        let first_id = first_body["data"]["id"]
            .as_str()
            .expect("first counterparty id should be string")
            .to_string();

        let (second_status, second_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/counterparties",
            json!({"displayName": "瑞幸咖啡", "aliases": ["Luckin Coffee"]}),
        )
        .await;
        assert_eq!(second_status, StatusCode::CREATED);
        let second_id = second_body["data"]["id"]
            .as_str()
            .expect("second counterparty id should be string")
            .to_string();

        let account_input = json!({
            "displayName": "消费账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "100.00"}
            ]
        });
        let (account_status, account_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", account_input)
                .await;
        assert_eq!(account_status, StatusCode::CREATED);
        let account_id = account_body["data"]["id"]
            .as_str()
            .expect("account id should be string")
            .to_string();

        let draft_input = json!({
            "type": "expense",
            "occurredAt": "2026-06-27T09:00:00+08:00",
            "title": "瑞幸咖啡",
            "counterpartyId": second_id.clone(),
            "entries": [
                {
                    "accountId": account_id,
                    "amount": "18.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                }
            ]
        });
        let (draft_status, draft_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            draft_input,
        )
        .await;
        assert_eq!(draft_status, StatusCode::CREATED);
        let movement_id = draft_body["data"]["id"]
            .as_str()
            .expect("movement id should be string")
            .to_string();
        let movement_group_id = draft_body["data"]["atomicGroupId"]
            .as_str()
            .expect("movement group id should be string")
            .to_string();
        let (movement_confirm_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{movement_group_id}/confirm"),
        )
        .await;
        assert_eq!(movement_confirm_status, StatusCode::OK);

        let (merge_status, merge_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/counterparties/merge-proposal",
            json!({
                "sourceCounterpartyIds": [first_id.clone(), second_id.clone()],
                "targetDisplayName": "瑞幸咖啡"
            }),
        )
        .await;
        assert_eq!(merge_status, StatusCode::OK);
        assert_eq!(merge_body["data"]["operation"], "merge");
        assert_eq!(merge_body["data"]["targetType"], "counterparty");
        assert_eq!(merge_body["data"]["status"], "pending");
        let merge_group_id = merge_body["data"]["id"]
            .as_str()
            .expect("merge group id should be string")
            .to_string();
        let merged_id = merge_body["data"]["mergeMeta"]["targetCounterpartyId"]
            .as_str()
            .expect("target counterparty id should be string")
            .to_string();

        let (counterparties_before_status, counterparties_before_body) =
            request_json_from(router.clone(), Method::GET, "/v1/counterparties").await;
        assert_eq!(counterparties_before_status, StatusCode::OK);
        assert_eq!(
            counterparties_before_body["data"]
                .as_array()
                .expect("counterparties")
                .len(),
            2
        );

        let (pending_status, pending_body) =
            request_json_from(router.clone(), Method::GET, "/v1/ai/proposals/pending").await;
        assert_eq!(pending_status, StatusCode::OK);
        assert_eq!(
            pending_body["data"][0]["atomicGroups"][0]["id"],
            merge_group_id
        );

        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{merge_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK);
        assert_eq!(confirm_body["data"]["ledgerWrite"], true);
        assert_eq!(confirm_body["data"]["mergedCounterpartyId"], merged_id);

        let (counterparties_after_status, counterparties_after_body) =
            request_json_from(router.clone(), Method::GET, "/v1/counterparties").await;
        assert_eq!(counterparties_after_status, StatusCode::OK);
        assert_eq!(
            counterparties_after_body["data"]
                .as_array()
                .expect("counterparties")
                .len(),
            1
        );
        assert_eq!(
            counterparties_after_body["data"][0]["displayName"],
            "瑞幸咖啡"
        );
        assert_eq!(counterparties_after_body["data"][0]["isUserMerged"], true);

        let (movement_after_status, movement_after_body) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/movements/{movement_id}"),
        )
        .await;
        assert_eq!(movement_after_status, StatusCode::OK);
        assert_eq!(movement_after_body["data"]["counterpartyId"], merged_id);

        let (pending_after_status, pending_after_body) =
            request_json_from(router.clone(), Method::GET, "/v1/ai/proposals/pending").await;
        assert_eq!(pending_after_status, StatusCode::OK);
        assert_eq!(pending_after_body["data"], json!([]));

        let persisted = local_ledger::read_document(&path).expect("ledger should persist merge");
        assert_eq!(
            persisted["counterparties"]
                .as_array()
                .expect("counterparties")
                .len(),
            1
        );
        assert_eq!(
            persisted["aiProposals"][0]["atomicGroups"][0]["status"],
            "approved"
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_correction_proposal_adds_adjustment_without_rewriting_original() {
        let path = unique_test_ledger_path("correction");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let account_input = json!({
            "displayName": "消费账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "100.00"}
            ]
        });
        let (account_status, account_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", account_input)
                .await;
        assert_eq!(account_status, StatusCode::CREATED);
        let account_id = account_body["data"]["id"]
            .as_str()
            .expect("account id should be string")
            .to_string();

        let draft_input = json!({
            "type": "expense",
            "occurredAt": "2026-06-26T12:00:00+08:00",
            "title": "午餐",
            "entries": [
                {
                    "accountId": account_id,
                    "amount": "20.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                }
            ],
            "amountBreakdown": {
                "paidAmount": {"amount": "20.00", "currency": "CNY"}
            }
        });
        let (draft_status, draft_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            draft_input,
        )
        .await;
        assert_eq!(draft_status, StatusCode::CREATED);
        let original_movement_id = draft_body["data"]["id"]
            .as_str()
            .expect("movement id should be string")
            .to_string();
        let original_group_id = draft_body["data"]["atomicGroupId"]
            .as_str()
            .expect("atomic group id should be string")
            .to_string();
        let (confirm_original_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{original_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_original_status, StatusCode::OK);

        let correction_input = json!({
            "targetMovementId": original_movement_id,
            "reason": "实际支付是 18 元",
            "proposedDiffs": [
                {
                    "fieldPath": "amountBreakdown.paidAmount.amount",
                    "oldValue": "20.00",
                    "newValue": "18.00",
                    "severity": "danger",
                    "reason": "用户复核账单"
                }
            ]
        });
        let (correction_status, correction_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/corrections",
            correction_input,
        )
        .await;
        assert_eq!(correction_status, StatusCode::OK);
        assert_eq!(correction_body["data"]["operation"], "correction");
        assert_eq!(
            correction_body["data"]["proposedMovements"][0]["entries"][0]["direction"],
            "in"
        );
        assert_eq!(
            correction_body["data"]["proposedMovements"][0]["entries"][0]["amount"],
            "2.00"
        );
        let correction_group_id = correction_body["data"]["id"]
            .as_str()
            .expect("correction group id should be string")
            .to_string();

        let (confirm_correction_status, confirm_correction_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{correction_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_correction_status, StatusCode::OK);
        assert_eq!(confirm_correction_body["data"]["ledgerWrite"], true);

        let (account_after_status, account_after_body) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{account_id}"),
        )
        .await;
        assert_eq!(account_after_status, StatusCode::OK);
        assert_eq!(account_after_body["data"]["value"]["amount"], "82.00");

        let (original_status, original_body) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/movements/{original_movement_id}"),
        )
        .await;
        assert_eq!(original_status, StatusCode::OK);
        assert_eq!(original_body["data"]["status"], "confirmed");
        assert_eq!(original_body["data"]["entries"][0]["amount"], "20.00");

        let persisted =
            local_ledger::read_document(&path).expect("ledger should persist correction");
        assert_eq!(
            persisted["movements"].as_array().expect("movements").len(),
            2
        );
        assert_eq!(persisted["movements"][1]["type"], "correction");
        assert_eq!(persisted["movements"][1]["status"], "confirmed");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_manual_snapshot_persists_current_net_worth() {
        let path = unique_test_ledger_path("manual_snapshot");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let account_input = json!({
            "displayName": "快照账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "100.00"}
            ]
        });
        let (account_status, account_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", account_input)
                .await;
        assert_eq!(account_status, StatusCode::CREATED);
        let account_id = account_body["data"]["id"]
            .as_str()
            .expect("account id should be string")
            .to_string();

        let (empty_status, empty_body) =
            request_json_from(router.clone(), Method::GET, "/v1/snapshots").await;
        assert_eq!(empty_status, StatusCode::OK);
        assert_eq!(empty_body["data"], json!([]));

        let (create_status, create_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/snapshots/manual",
            json!({"reason": "baseline"}),
        )
        .await;
        assert_eq!(create_status, StatusCode::OK);
        assert_eq!(create_body["data"]["reason"], "baseline");
        assert_eq!(create_body["data"]["netWorth"]["amount"], "100.00");

        let (list_status, list_body) =
            request_json_from(router.clone(), Method::GET, "/v1/snapshots").await;
        assert_eq!(list_status, StatusCode::OK);
        assert_eq!(list_body["data"][0]["netWorth"]["amount"], "100.00");

        let patch = json!({
            "cashBalances": [
                {"currency": "CNY", "amount": "120.00"}
            ]
        });
        let (patch_status, _) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/accounts/{account_id}"),
            patch,
        )
        .await;
        assert_eq!(patch_status, StatusCode::OK);

        let (overview_status, overview_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_status, StatusCode::OK);
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["netWorth"]["amount"],
            "120.00"
        );

        let (latest_status, latest_body) =
            request_json_from(router, Method::GET, "/v1/snapshots/latest").await;
        assert_eq!(latest_status, StatusCode::OK);
        assert_eq!(latest_body["data"]["netWorth"]["amount"], "100.00");

        let persisted = local_ledger::read_document(&path).expect("ledger should persist snapshot");
        assert_eq!(persisted["snapshots"][0]["netWorth"]["amount"], "100.00");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_create_account_rejects_invalid_input() {
        let path = unique_test_ledger_path("invalid_account");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (status, body) =
            request_json_body_from(router, Method::POST, "/v1/accounts", json!({})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"]["code"], "invalid_account_input");
        assert!(
            body["error"]["details"]["errors"]
                .as_array()
                .expect("validation errors should be an array")
                .iter()
                .any(|error| error
                    .as_str()
                    .is_some_and(|text| text.contains("displayName")))
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn health_route_returns_ok() {
        let (status, body) = request_json(Method::GET, "/v1/health").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["ok"], true);
        assert_eq!(body["data"]["status"], "ok");
    }

    #[tokio::test]
    async fn degraded_overview_keeps_pending_summary_shape() {
        let (status, body) =
            request_json(Method::GET, "/v1/portfolio/overview?scenario=degraded").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["data"]["pendingSummary"]["aiPendingCount"], 2);
        assert_eq!(body["data"]["pendingSummary"]["dcaDueCount"], 1);
    }

    #[tokio::test]
    async fn default_list_routes_stay_empty() {
        for uri in [
            "/v1/accounts",
            "/v1/portfolio/holdings",
            "/v1/movements",
            "/v1/dca/plans",
            "/v1/dca/reminders/due",
            "/v1/ai/proposals/pending",
            "/v1/snapshots",
        ] {
            let (status, body) = request_json(Method::GET, uri).await;
            assert_eq!(status, StatusCode::OK, "{uri}");
            assert_eq!(body["data"], json!([]), "{uri}");
        }
    }

    #[tokio::test]
    async fn degraded_routes_expose_consistent_frontend_dataset() {
        let (status, accounts) = request_json(Method::GET, "/v1/accounts?scenario=degraded").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            accounts["data"].as_array().expect("accounts array").len(),
            4
        );
        assert_eq!(accounts["data"][3]["accountType"], "loan");
        assert_eq!(
            accounts["data"][3]["note"],
            "在校贴息；负数是正常负债，不触发 negative_balance。"
        );

        let (status, account) =
            request_json(Method::GET, "/v1/accounts/acct_us_broker?scenario=degraded").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(account["data"]["displayName"], "美股券商");

        let (status, account_holdings) = request_json(
            Method::GET,
            "/v1/accounts/acct_us_broker/holdings?scenario=degraded",
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(account_holdings["data"][0]["accountId"], "acct_us_broker");

        let (status, movements) =
            request_json(Method::GET, "/v1/movements?scenario=degraded").await;
        assert_eq!(status, StatusCode::OK);
        assert!(movements["data"].as_array().expect("movements array").len() >= 2);

        let (status, holdings_alias) =
            request_json(Method::GET, "/v1/holdings?scenario=degraded").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(holdings_alias["data"][0]["id"], "holding_nvda_us_broker");

        let (status, movements_alias) =
            request_json(Method::GET, "/v1/movements/recent?scenario=degraded").await;
        assert_eq!(status, StatusCode::OK);
        assert!(
            movements_alias["data"]
                .as_array()
                .expect("movements alias array")
                .len()
                >= 2
        );

        let (status, movement) = request_json(
            Method::GET,
            "/v1/movements/mov_luckin_001?scenario=degraded",
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            movement["data"]["amountBreakdown"]["paidAmount"]["amount"],
            "18.00"
        );

        let (status, dca_plans) =
            request_json(Method::GET, "/v1/dca/plans?scenario=degraded").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(dca_plans["data"][0]["note"], "只提醒与记录，不下单。");

        let (status, dca_due) =
            request_json(Method::GET, "/v1/dca/reminders/due?scenario=degraded").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(dca_due["data"][0]["status"], "due");

        let (status, ai_pending) =
            request_json(Method::GET, "/v1/ai/proposals/pending?scenario=degraded").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(ai_pending["data"][0]["id"], "proposal_ai_001");

        let (status, latest_snapshot) =
            request_json(Method::GET, "/v1/snapshots/latest?scenario=degraded").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(latest_snapshot["data"]["quality"], "estimated");

        let (status, quote_summary) =
            request_json(Method::GET, "/v1/quotes/summary?scenario=degraded").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(quote_summary["data"]["staleCount"], 2);
    }

    #[tokio::test]
    async fn dca_mark_executed_only_returns_pending_proposal() {
        let (status, body) = request_json(
            Method::POST,
            "/v1/dca/reminders/reminder_001/mark-executed-as-proposal",
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            body["data"]["proposedMovements"][0]["status"],
            "pending_review"
        );
        let warnings = body["data"]["warnings"]
            .as_array()
            .expect("warnings should be an array");
        let warning_text = serde_json::to_string(warnings).expect("warnings should stringify");
        assert!(warning_text.contains("不下单"));
        assert!(warning_text.contains("不转账"));
    }

    #[tokio::test]
    async fn dca_mark_executed_rejects_unknown_reminder() {
        let (status, body) = request_json(
            Method::POST,
            "/v1/dca/reminders/missing_reminder/mark-executed-as-proposal",
        )
        .await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(body["ok"], false);
        assert_eq!(body["error"]["code"], "dca_reminder_not_found");
    }

    #[tokio::test]
    async fn local_ledger_ai_text_import_requires_structured_edit_before_approval() {
        let path = unique_test_ledger_path("ai_text_requires_edit");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (proposal_status, proposal_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/ai/proposals/from-text",
            json!({"text": "午餐 18 元"}),
        )
        .await;
        assert_eq!(proposal_status, StatusCode::OK);
        assert_eq!(proposal_body["data"]["source"]["kind"], "user_text");
        assert_eq!(proposal_body["data"]["status"], "pending");
        assert_eq!(
            proposal_body["data"]["atomicGroups"][0]["validation"]["isValid"],
            false
        );
        let group_id = proposal_body["data"]["atomicGroups"][0]["id"]
            .as_str()
            .expect("AI group id should be string")
            .to_string();

        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/ai/atomic-groups/{group_id}/approve"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::BAD_REQUEST);
        assert_eq!(
            confirm_body["error"]["code"],
            "invalid_atomic_group_confirm"
        );

        let (pending_status, pending_body) =
            request_json_from(router.clone(), Method::GET, "/v1/ai/proposals/pending").await;
        assert_eq!(pending_status, StatusCode::OK);
        assert_eq!(
            pending_body["data"]
                .as_array()
                .expect("pending proposals should be an array")
                .len(),
            1
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_ai_text_import_edit_then_approve_writes_movement() {
        let path = unique_test_ledger_path("ai_text_edit_approve");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (account_status, account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "消费账户",
                "accountType": "bank",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [
                    {"currency": "CNY", "amount": "100.00"}
                ]
            }),
        )
        .await;
        assert_eq!(account_status, StatusCode::CREATED);
        let account_id = account_body["data"]["id"]
            .as_str()
            .expect("account id should be string")
            .to_string();

        let (proposal_status, proposal_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/ai/proposals/from-text",
            json!({"text": "午餐 18 元"}),
        )
        .await;
        assert_eq!(proposal_status, StatusCode::OK);
        let group_id = proposal_body["data"]["atomicGroups"][0]["id"]
            .as_str()
            .expect("AI group id should be string")
            .to_string();

        let edit_body = json!({
            "proposedMovements": [
                {
                    "type": "expense",
                    "occurredAt": "2026-06-27T12:00:00+08:00",
                    "title": "AI 整理：午餐",
                    "entries": [
                        {
                            "accountId": account_id,
                            "amount": "18.00",
                            "currency": "CNY",
                            "direction": "out",
                            "role": "source"
                        }
                    ],
                    "amountBreakdown": {
                        "paidAmount": {"amount": "18.00", "currency": "CNY"}
                    },
                    "tags": ["ai_import"]
                }
            ]
        });
        let (edit_status, edit_response) = request_json_body_from(
            router.clone(),
            Method::POST,
            &format!("/v1/ai/atomic-groups/{group_id}/edit"),
            edit_body,
        )
        .await;
        assert_eq!(edit_status, StatusCode::OK);
        assert_eq!(edit_response["data"]["status"], "edited");
        assert_eq!(edit_response["data"]["validation"]["isValid"], true);

        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/ai/atomic-groups/{group_id}/approve"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK);
        assert_eq!(confirm_body["data"]["ledgerWrite"], true);
        assert_eq!(
            confirm_body["data"]["confirmedMovementIds"]
                .as_array()
                .expect("confirmed movement ids should be an array")
                .len(),
            1
        );

        let (account_after_status, account_after_body) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{account_id}"),
        )
        .await;
        assert_eq!(account_after_status, StatusCode::OK);
        assert_eq!(
            account_after_body["data"]["cashBalances"][0]["amount"],
            "82.00"
        );

        let (pending_after_status, pending_after_body) =
            request_json_from(router.clone(), Method::GET, "/v1/ai/proposals/pending").await;
        assert_eq!(pending_after_status, StatusCode::OK);
        assert_eq!(pending_after_body["data"], json!([]));

        let persisted = local_ledger::read_document(&path).expect("ledger should persist AI write");
        assert_eq!(persisted["movements"][0]["source"]["kind"], "ai_proposal");
        assert_eq!(persisted["aiProposals"][0]["status"], "approved");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_csv_import_creates_confirmable_groups_per_row() {
        let path = unique_test_ledger_path("csv_import");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (account_status, account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "CSV 账户",
                "accountType": "bank",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [
                    {"currency": "CNY", "amount": "100.00"}
                ]
            }),
        )
        .await;
        assert_eq!(account_status, StatusCode::CREATED);
        let account_id = account_body["data"]["id"]
            .as_str()
            .expect("account id should be string")
            .to_string();

        let csv = "occurredAt,title,amount,currency\n2026-06-27T08:00:00+08:00,早餐,-18.00,CNY\n2026-06-27T18:00:00+08:00,报销,+50.00,CNY\n";
        let (proposal_status, proposal_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/ai/proposals/from-csv",
            json!({
                "csv": csv,
                "selectedAccountIds": [account_id]
            }),
        )
        .await;
        assert_eq!(proposal_status, StatusCode::OK);
        assert_eq!(proposal_body["data"]["source"]["kind"], "csv_import");
        assert_eq!(
            proposal_body["data"]["atomicGroups"]
                .as_array()
                .expect("CSV proposal groups should be an array")
                .len(),
            2
        );
        assert_eq!(
            proposal_body["data"]["atomicGroups"][0]["proposedMovements"][0]["type"],
            "expense"
        );
        assert_eq!(
            proposal_body["data"]["atomicGroups"][1]["proposedMovements"][0]["type"],
            "income"
        );

        let (overview_pending_status, overview_pending_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_pending_status, StatusCode::OK);
        assert_eq!(
            overview_pending_body["data"]["pendingSummary"]["aiPendingCount"],
            1
        );

        let first_group_id = proposal_body["data"]["atomicGroups"][0]["id"]
            .as_str()
            .expect("first group id should be string")
            .to_string();
        let second_group_id = proposal_body["data"]["atomicGroups"][1]["id"]
            .as_str()
            .expect("second group id should be string")
            .to_string();

        let (first_confirm_status, first_confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/ai/atomic-groups/{first_group_id}/approve"),
        )
        .await;
        assert_eq!(first_confirm_status, StatusCode::OK);
        assert_eq!(first_confirm_body["data"]["ledgerWrite"], true);

        let (pending_mid_status, pending_mid_body) =
            request_json_from(router.clone(), Method::GET, "/v1/ai/proposals/pending").await;
        assert_eq!(pending_mid_status, StatusCode::OK);
        assert_eq!(pending_mid_body["data"][0]["status"], "partially_reviewed");
        assert_eq!(
            pending_mid_body["data"][0]["atomicGroups"][1]["status"],
            "pending"
        );

        let (second_confirm_status, second_confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/ai/atomic-groups/{second_group_id}/approve"),
        )
        .await;
        assert_eq!(second_confirm_status, StatusCode::OK);
        assert_eq!(second_confirm_body["data"]["ledgerWrite"], true);

        let (account_after_status, account_after_body) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{account_id}"),
        )
        .await;
        assert_eq!(account_after_status, StatusCode::OK);
        assert_eq!(
            account_after_body["data"]["cashBalances"][0]["amount"],
            "132.00"
        );

        let (pending_after_status, pending_after_body) =
            request_json_from(router.clone(), Method::GET, "/v1/ai/proposals/pending").await;
        assert_eq!(pending_after_status, StatusCode::OK);
        assert_eq!(pending_after_body["data"], json!([]));

        let (overview_done_status, overview_done_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_done_status, StatusCode::OK);
        assert_eq!(
            overview_done_body["data"]["pendingSummary"]["aiPendingCount"],
            0
        );

        let persisted =
            local_ledger::read_document(&path).expect("ledger should persist CSV import");
        assert_eq!(
            persisted["movements"]
                .as_array()
                .expect("persisted movements should be an array")
                .len(),
            2
        );
        assert_eq!(persisted["aiProposals"][0]["status"], "approved");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn ai_proposal_sources_keep_diff_and_do_not_write_ledger() {
        for (uri, source_kind) in [
            ("/v1/ai/proposals/from-text", "user_text"),
            ("/v1/ai/proposals/from-image", "user_image"),
            ("/v1/ai/proposals/from-csv", "csv_import"),
        ] {
            let (status, body) = request_json(Method::POST, uri).await;
            assert_eq!(status, StatusCode::OK, "{uri}");
            assert_eq!(body["data"]["source"]["kind"], source_kind, "{uri}");
            assert_eq!(body["data"]["status"], "pending", "{uri}");
            assert!(
                body["data"]["atomicGroups"][0]["diffs"]
                    .as_array()
                    .expect("diffs should be an array")
                    .len()
                    >= 2,
                "{uri}"
            );
        }
    }

    #[tokio::test]
    async fn ai_atomic_group_approve_reject_edit_are_dev_only() {
        let (approve_status, approve_body) = request_json(
            Method::POST,
            "/v1/ai/atomic-groups/ag_ai_modify_001/approve",
        )
        .await;
        assert_eq!(approve_status, StatusCode::OK);
        assert_eq!(approve_body["data"]["atomicGroupId"], "ag_ai_modify_001");
        assert_eq!(approve_body["data"]["confirmedMovementIds"], json!([]));
        assert_eq!(approve_body["data"]["snapshotInvalidated"], false);
        assert_eq!(approve_body["data"]["ledgerWrite"], false);

        let (edit_status, edit_body) =
            request_json(Method::POST, "/v1/ai/atomic-groups/ag_ai_modify_001/edit").await;
        assert_eq!(edit_status, StatusCode::OK);
        assert_eq!(edit_body["data"]["id"], "ag_ai_modify_001");
        assert_eq!(edit_body["data"]["status"], "edited");
        assert_eq!(edit_body["data"]["validation"]["isValid"], true);

        let (reject_status, reject_body) =
            request_json(Method::POST, "/v1/ai/atomic-groups/ag_ai_modify_001/reject").await;
        assert_eq!(reject_status, StatusCode::NO_CONTENT);
        assert_eq!(reject_body, Value::Null);
    }

    #[tokio::test]
    async fn dev_proposal_store_tracks_review_state_across_requests() {
        let router = app();

        let (initial_status, initial_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/ai/proposals/pending?scenario=degraded",
        )
        .await;
        assert_eq!(initial_status, StatusCode::OK);
        assert_eq!(
            initial_body["data"]
                .as_array()
                .expect("pending array")
                .len(),
            1
        );

        let (create_status, create_body) =
            request_json_from(router.clone(), Method::POST, "/v1/ai/proposals/from-text").await;
        assert_eq!(create_status, StatusCode::OK);
        assert_eq!(create_body["data"]["id"], "proposal_ai_dev_001");
        assert_eq!(
            create_body["data"]["atomicGroups"][0]["id"],
            "ag_ai_dev_001"
        );

        let (after_create_status, after_create_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/ai/proposals/pending?scenario=degraded",
        )
        .await;
        assert_eq!(after_create_status, StatusCode::OK);
        assert_eq!(
            after_create_body["data"]
                .as_array()
                .expect("pending after create array")
                .len(),
            2
        );

        let (approve_status, approve_body) = request_json_from(
            router.clone(),
            Method::POST,
            "/v1/ai/atomic-groups/ag_ai_dev_001/approve",
        )
        .await;
        assert_eq!(approve_status, StatusCode::OK);
        assert_eq!(approve_body["data"]["ledgerWrite"], false);

        let (after_approve_status, after_approve_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/ai/proposals/pending?scenario=degraded",
        )
        .await;
        assert_eq!(after_approve_status, StatusCode::OK);
        assert_eq!(
            after_approve_body["data"]
                .as_array()
                .expect("pending after approve array")
                .len(),
            1
        );

        let (edit_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            "/v1/ai/atomic-groups/ag_ai_modify_001/edit",
        )
        .await;
        assert_eq!(edit_status, StatusCode::OK);

        let (after_edit_status, after_edit_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/ai/proposals/pending?scenario=degraded",
        )
        .await;
        assert_eq!(after_edit_status, StatusCode::OK);
        assert_eq!(
            after_edit_body["data"][0]["atomicGroups"][0]["status"],
            "edited"
        );

        let (reject_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            "/v1/ai/atomic-groups/ag_ai_modify_001/reject",
        )
        .await;
        assert_eq!(reject_status, StatusCode::NO_CONTENT);

        let (after_reject_status, after_reject_body) = request_json_from(
            router,
            Method::GET,
            "/v1/ai/proposals/pending?scenario=degraded",
        )
        .await;
        assert_eq!(after_reject_status, StatusCode::OK);
        assert_eq!(after_reject_body["data"], json!([]));
    }

    #[tokio::test]
    async fn atomic_group_alias_confirm_reject_use_same_guardrails() {
        let (confirm_status, confirm_body) = request_json(
            Method::POST,
            "/v1/atomic-groups/ag_dca_recorded_001/confirm",
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK);
        assert_eq!(confirm_body["data"]["atomicGroupId"], "ag_dca_recorded_001");
        assert_eq!(confirm_body["data"]["ledgerWrite"], false);

        let (reject_status, reject_body) =
            request_json(Method::POST, "/v1/atomic-groups/missing_group/reject").await;
        assert_eq!(reject_status, StatusCode::NOT_FOUND);
        assert_eq!(reject_body["error"]["code"], "atomic_group_not_found");
    }

    #[tokio::test]
    async fn forbidden_product_boundary_routes_return_403() {
        for uri in [
            "/v1/transfers/execute",
            "/v1/broker/orders",
            "/v1/broker/buy",
            "/v1/broker/sell",
            "/v1/ai/auto-approve",
            "/v1/ai/write-ledger-directly",
            "/v1/coupons/plan",
        ] {
            let (status, body) = request_json(Method::POST, uri).await;
            assert_eq!(status, StatusCode::FORBIDDEN, "{uri}");
            assert_eq!(body["ok"], false, "{uri}");
            assert_eq!(body["error"]["code"], "forbidden_product_boundary", "{uri}");
        }
    }

    #[tokio::test]
    async fn ai_proposal_contains_old_to_new_diff() {
        let (status, body) = request_json(Method::POST, "/v1/ai/proposals/from-text").await;
        assert_eq!(status, StatusCode::OK);
        let diffs = body["data"]["atomicGroups"][0]["diffs"]
            .as_array()
            .expect("diffs should be present");
        assert!(!diffs.is_empty());
        assert!(diffs[0].get("oldValue").is_some());
        assert!(diffs[0].get("newValue").is_some());
    }

    fn unique_test_ledger_path(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be after unix epoch")
            .as_nanos();
        std::env::temp_dir()
            .join(format!("finwealth_server_{label}_{nanos}"))
            .join("ledger.json")
    }
}
