use argon2::{
    Argon2,
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
};
use axum::{
    Extension, Json, Router,
    body::{Body, to_bytes},
    extract::{DefaultBodyLimit, Json as JsonExtractor, Path, Query, Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, Uri},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{any, get, patch, post},
};
use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
mod ledger_lease;
mod ledger_migrations;
mod local_ledger;

use rand_core::{OsRng, RngCore};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    env, fs,
    io::{self, Read, Write},
    net::SocketAddr,
    path::{Path as FsPath, PathBuf},
    process,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};
use subtle::ConstantTimeEq;
use time::{
    Date, Duration, OffsetDateTime,
    format_description::well_known::{Iso8601, Rfc3339},
};
use yahoo_finance_api as yahoo;

const EMPTY_BOOTSTRAP: &str =
    include_str!("../../docs/contracts/examples/ledger_bootstrap_empty.response.json");
const REFRESH_TOKEN_TTL_DAYS: i64 = 30;
const IDEMPOTENCY_KEY_MAX_BYTES: usize = 128;
const IDEMPOTENCY_RETENTION_DAYS: i64 = 30;
const DEV_UNAUTHENTICATED_DEVICE_ID: &str = "dev_unauthenticated_device";
const AGENT_INTERNAL_DEVICE_ID: &str = "dev_agent_sidecar";
const OWNER_USER_ID: &str = "usr_owner";
const OWNER_LEDGER_ID: &str = "ledger_default";
const AGENT_PROXY_BODY_LIMIT: usize = 55 * 1024 * 1024;
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
static LOCAL_ID_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Clone)]
struct AppState {
    ledger: DevLedgerCore,
    local_ledger_path: Option<PathBuf>,
    _ledger_lease: Option<Arc<ledger_lease::LedgerLease>>,
    auth: AuthStore,
    allow_ledger_scenario: bool,
    allowed_hosts: Vec<String>,
    agent_gateway: AgentGateway,
}

#[derive(Clone)]
struct AgentGateway {
    base_url: Option<String>,
    internal_token: Option<String>,
    client: reqwest::Client,
}

impl AgentGateway {
    fn from_env() -> Self {
        Self::new(
            env::var("FINWEALTH_AGENT_BASE_URL").ok(),
            env::var("FINWEALTH_AGENT_INTERNAL_TOKEN").ok(),
        )
    }

    fn new(base_url: Option<String>, internal_token: Option<String>) -> Self {
        Self {
            base_url: base_url.map(|value| value.trim_end_matches('/').to_string()),
            internal_token,
            client: reqwest::Client::new(),
        }
    }
}

impl AppState {
    fn dev() -> Self {
        Self {
            ledger: DevLedgerCore::new(),
            local_ledger_path: None,
            _ledger_lease: None,
            auth: AuthStore::from_env_or_dev_with_default_state_path(None),
            allow_ledger_scenario: env_flag("FINWEALTH_ALLOW_LEDGER_SCENARIO"),
            allowed_hosts: allowed_hosts_from_env(),
            agent_gateway: AgentGateway::from_env(),
        }
    }

    fn local_with_lease(path: PathBuf, lease: Arc<ledger_lease::LedgerLease>) -> Self {
        Self::local_state(path, Some(lease))
    }

    #[cfg(test)]
    fn local(path: PathBuf) -> Self {
        Self::local_state(path, None)
    }

    fn local_state(path: PathBuf, lease: Option<Arc<ledger_lease::LedgerLease>>) -> Self {
        let auth_state_path = default_auth_state_path(&path);
        Self {
            ledger: DevLedgerCore::new(),
            local_ledger_path: Some(path),
            _ledger_lease: lease,
            auth: AuthStore::from_env_or_dev_with_default_state_path(Some(auth_state_path)),
            allow_ledger_scenario: env_flag("FINWEALTH_ALLOW_LEDGER_SCENARIO"),
            allowed_hosts: allowed_hosts_from_env(),
            agent_gateway: AgentGateway::from_env(),
        }
    }

    #[cfg(test)]
    fn with_auth(mut self, auth: AuthStore) -> Self {
        self.auth = auth;
        self
    }

    #[cfg(test)]
    fn with_allow_ledger_scenario(mut self, allow: bool) -> Self {
        self.allow_ledger_scenario = allow;
        self
    }

    #[cfg(test)]
    fn with_agent_gateway(mut self, base_url: String, internal_token: &str) -> Self {
        self.agent_gateway = AgentGateway::new(Some(base_url), Some(internal_token.to_string()));
        self
    }

    fn should_use_local_ledger(&self, _query: &HashMap<String, String>) -> bool {
        self.local_ledger_path.is_some()
    }

    fn rejects_ledger_scenario(&self, query: Option<&str>) -> bool {
        self.local_ledger_path.is_some()
            && !self.allow_ledger_scenario
            && query_has_non_empty_scenario(query)
    }

    fn rejects_host_header(&self, headers: &HeaderMap) -> bool {
        self.local_ledger_path.is_some() && !host_header_is_allowed(headers, &self.allowed_hosts)
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
    require_auth: bool,
    state_path: Option<PathBuf>,
}

#[derive(Clone, Default)]
struct AuthState {
    devices: BTreeMap<String, AuthDevice>,
}

#[derive(Clone)]
struct AuthDevice {
    id: String,
    name: String,
    refresh_token_hash: String,
    access_token_hash: String,
    access_expires_at: String,
    refresh_expires_at: String,
    created_at: String,
    last_seen_at: String,
}

#[derive(Debug)]
enum AuthError {
    Request(Vec<String>),
    Credentials,
    RefreshToken,
    Storage,
}

struct AuthTokens {
    access_token: String,
    refresh_token: String,
    expires_at: String,
    refresh_expires_at: String,
    device_id: String,
}

#[derive(Clone)]
struct AuthenticatedDevice {
    id: String,
}

#[derive(Clone)]
struct AuthenticatedPrincipal {
    user_id: String,
    ledger_id: String,
    device_id: String,
}

impl AuthStore {
    fn from_env_or_dev_with_default_state_path(default_state_path: Option<PathBuf>) -> Self {
        let state_path = env::var("FINWEALTH_AUTH_STATE_PATH")
            .ok()
            .map(PathBuf::from)
            .or(default_state_path);
        let state = state_path
            .as_ref()
            .map(|path| match read_auth_state(path) {
                Ok(state) => state,
                // The test fixture uses a regular file as the would-be parent.
                // Windows reports its missing child as NotFound while Unix
                // reports NotADirectory. Production startup does not use this
                // helper and continues to fail closed for NotADirectory.
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::NotFound | io::ErrorKind::NotADirectory
                    ) =>
                {
                    AuthState::default()
                }
                Err(error) => panic!(
                    "failed to read auth state {}; refusing to start: {error}",
                    path.display()
                ),
            })
            .unwrap_or_default();
        let config = AuthConfig {
            username: env::var("FINWEALTH_AUTH_USERNAME").ok(),
            password_hash: env::var("FINWEALTH_AUTH_PASSWORD_HASH").ok(),
            dev_plain_password: env::var("FINWEALTH_AUTH_PASSWORD").ok(),
            require_auth: env_flag("FINWEALTH_REQUIRE_AUTH"),
            state_path,
        };
        validate_auth_config(&config).unwrap_or_else(|errors| {
            panic!(
                "invalid Finwealth auth configuration: {}",
                errors.join("; ")
            )
        });
        Self {
            inner: Arc::new(Mutex::new(state)),
            config,
        }
    }

    #[cfg(test)]
    fn configured(username: &str, password_hash: String, require_auth: bool) -> Self {
        Self::configured_with_state_path(username, password_hash, require_auth, None)
    }

    #[cfg(test)]
    fn configured_with_state_path(
        username: &str,
        password_hash: String,
        require_auth: bool,
        state_path: Option<PathBuf>,
    ) -> Self {
        let state = state_path
            .as_ref()
            .map(|path| match read_auth_state(path) {
                Ok(state) => state,
                Err(error) if error.kind() == io::ErrorKind::NotFound => AuthState::default(),
                Err(error) => panic!(
                    "failed to read auth state {}; refusing to start: {error}",
                    path.display()
                ),
            })
            .unwrap_or_default();
        Self {
            inner: Arc::new(Mutex::new(state)),
            config: AuthConfig {
                username: Some(username.to_string()),
                password_hash: Some(password_hash),
                dev_plain_password: None,
                require_auth,
                state_path,
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

        self.issue_tokens(&device_name, None, now)
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
        let mut state = self.inner.lock().expect("auth store mutex should lock");
        let Some((device_id, device)) = state
            .devices
            .iter()
            .find(|(_, device)| token_hash_eq(&device.refresh_token_hash, &refresh_hash))
            .map(|(id, device)| (id.clone(), device.clone()))
        else {
            return Err(AuthError::RefreshToken);
        };
        if token_expired(&device.refresh_expires_at) {
            let mut updated = state.clone();
            updated.devices.remove(&device_id);
            self.persist_state(&updated)?;
            *state = updated;
            return Err(AuthError::RefreshToken);
        }
        let device_name = device.name;
        drop(state);

        self.issue_tokens(&device_name, Some(device_id), now)
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

    fn revoke_device(&self, device_id: &str) -> Result<(), AuthError> {
        let mut state = self.inner.lock().expect("auth store mutex should lock");
        let mut updated = state.clone();
        updated.devices.remove(device_id);
        self.persist_state(&updated)?;
        *state = updated;
        Ok(())
    }

    fn revoke_refresh_token(&self, refresh_token: &str) -> Result<(), AuthError> {
        let refresh_hash = token_hash(refresh_token);
        let mut state = self.inner.lock().expect("auth store mutex should lock");
        let mut updated = state.clone();
        updated
            .devices
            .retain(|_, device| !token_hash_eq(&device.refresh_token_hash, &refresh_hash));
        self.persist_state(&updated)?;
        *state = updated;
        Ok(())
    }

    fn revoke_access_token(&self, access_token: &str) -> Result<(), AuthError> {
        let access_hash = token_hash(access_token);
        let mut state = self.inner.lock().expect("auth store mutex should lock");
        let mut updated = state.clone();
        updated
            .devices
            .retain(|_, device| !token_hash_eq(&device.access_token_hash, &access_hash));
        self.persist_state(&updated)?;
        *state = updated;
        Ok(())
    }

    fn should_require_auth(&self) -> bool {
        self.config.require_auth
    }

    fn device_id_for_access_token(&self, access_token: &str) -> Option<String> {
        let access_hash = token_hash(access_token);
        let mut state = self.inner.lock().expect("auth store mutex should lock");
        if let Some(device) = state
            .devices
            .values_mut()
            .find(|device| token_hash_eq(&device.access_token_hash, &access_hash))
        {
            if access_token_expired(&device.access_expires_at) {
                return None;
            }
            device.last_seen_at = current_timestamp();
            let device_id = device.id.clone();
            if let Err(error) = self.persist_state(&state) {
                eprintln!("failed to persist auth last-seen metadata: {error:?}");
            }
            return Some(device_id);
        }
        None
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
    ) -> Result<AuthTokens, AuthError> {
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
        let refresh_expires_at = (OffsetDateTime::now_utc()
            + Duration::days(REFRESH_TOKEN_TTL_DAYS))
        .format(&Rfc3339)
        .expect("RFC3339 formatting should succeed");
        let mut state = self.inner.lock().expect("auth store mutex should lock");
        let device_id = existing_device_id.unwrap_or_else(|| next_local_id("dev_auth_device"));
        let created_at = state
            .devices
            .get(&device_id)
            .map(|device| device.created_at.clone())
            .unwrap_or_else(|| now.to_string());
        let mut updated = state.clone();
        updated.devices.insert(
            device_id.clone(),
            AuthDevice {
                id: device_id.clone(),
                name: device_name.to_string(),
                refresh_token_hash: token_hash(&refresh_token),
                access_token_hash: token_hash(&access_token),
                access_expires_at: expires_at.clone(),
                refresh_expires_at: refresh_expires_at.clone(),
                created_at,
                last_seen_at: now.to_string(),
            },
        );
        self.persist_state(&updated)?;
        *state = updated;

        Ok(AuthTokens {
            access_token,
            refresh_token,
            expires_at,
            refresh_expires_at,
            device_id,
        })
    }

    fn persist_state(&self, state: &AuthState) -> Result<(), AuthError> {
        let Some(path) = self.config.state_path.as_ref() else {
            return Ok(());
        };
        write_auth_state(path, state).map_err(|_| AuthError::Storage)
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

    fn mark_dca_executed_as_proposal(&self, reminder_id: &str, input: &Value) -> Option<Value> {
        if !matches!(
            reminder_id,
            "reminder_001" | "dca_reminder_001" | "rem_csi300_20260710"
        ) {
            return None;
        }

        let mut proposal = example_data(DCA_PROPOSAL);
        proposal["requestedReminderId"] = json!(reminder_id);
        proposal["proposedMovements"][0]["occurredAt"] = input
            .get("executedAt")
            .cloned()
            .unwrap_or_else(|| proposal["proposedMovements"][0]["occurredAt"].clone());
        proposal["proposedMovements"][0]["entries"][0]["amount"] =
            input["totalCost"]["amount"].clone();
        proposal["proposedMovements"][0]["entries"][0]["currency"] =
            input["totalCost"]["currency"].clone();
        proposal["proposedMovements"][0]["entries"][1]["accountId"] =
            input["holdingAccountId"].clone();
        proposal["proposedMovements"][0]["entries"][1]["amount"] = input["quantity"].clone();
        proposal["proposedMovements"][0]["entries"][1]["currency"] = input["quoteCurrency"].clone();
        proposal["proposedMovements"][0]["source"]["sourceId"] = json!(reminder_id);
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
    if should_check_production_config(env::args()) {
        check_production_config_from_env().unwrap_or_else(|errors| {
            eprintln!("invalid Finwealth production configuration:");
            for error in errors {
                eprintln!("- {error}");
            }
            process::exit(2);
        });
        println!(
            "production configuration validated: loopback bind, required auth, and public Host allow-list"
        );
        return;
    }
    if let Some(command) = read_ledger_command_from(env::args()) {
        run_ledger_command(command).expect("ledger command failed");
        return;
    }

    let addr = read_addr();
    assert_loopback(addr);
    let state = read_ledger_path(env::args())
        .map(|requested_path| {
            let lease =
                ledger_lease::acquire_ledger_lease(&requested_path).unwrap_or_else(|error| {
                    eprintln!(
                        "failed to acquire exclusive local-ledger lease for {}: {error}",
                        requested_path.display()
                    );
                    process::exit(2);
                });
            let path = lease.ledger_path().to_path_buf();
            local_ledger::load_or_initialize(&path).expect("real_local ledger should initialize");
            println!("real_local ledger enabled at {}", path.display());
            println!(
                "exclusive local-ledger lease held at {}",
                lease.lock_path().display()
            );
            AppState::local_with_lease(path, Arc::new(lease))
        })
        .unwrap_or_else(AppState::dev);
    let local_ledger_enabled = state.local_ledger_path.is_some();

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("bind finwealth rust server");
    println!("finwealth rust server listening on http://{addr}");
    if local_ledger_enabled {
        println!(
            "dev server: real_local JSON persistence enabled; configurable auth and opt-in quote providers available; no real AI or sync merge effects"
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

fn should_check_production_config<I, S>(args: I) -> bool
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    args.into_iter()
        .map(Into::into)
        .skip(1)
        .any(|arg| arg == "--check-production-config")
}

fn check_production_config_from_env() -> Result<(), Vec<String>> {
    let config = AuthConfig {
        username: env::var("FINWEALTH_AUTH_USERNAME").ok(),
        password_hash: env::var("FINWEALTH_AUTH_PASSWORD_HASH").ok(),
        dev_plain_password: env::var("FINWEALTH_AUTH_PASSWORD").ok(),
        require_auth: env_flag("FINWEALTH_REQUIRE_AUTH"),
        state_path: None,
    };
    let addr = env::var("FINWEALTH_RS_ADDR")
        .unwrap_or_else(|_| "127.0.0.1:8790".to_string())
        .parse::<SocketAddr>()
        .map_err(|_| vec!["FINWEALTH_RS_ADDR must be a valid socket address".to_string()])?;
    let quote_provider = env::var("FINWEALTH_QUOTE_PROVIDER").ok();
    let errors = production_config_errors(
        &config,
        addr,
        &allowed_hosts_from_env(),
        env_flag("FINWEALTH_ALLOW_LEDGER_SCENARIO"),
        quote_provider.as_deref(),
        env::var("FINWEALTH_AGENT_BASE_URL").ok().as_deref(),
        env::var("FINWEALTH_AGENT_INTERNAL_TOKEN").ok().as_deref(),
    );
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
    }
}

fn production_config_errors(
    config: &AuthConfig,
    addr: SocketAddr,
    allowed_hosts: &[String],
    allow_ledger_scenario: bool,
    quote_provider: Option<&str>,
    agent_base_url: Option<&str>,
    agent_internal_token: Option<&str>,
) -> Vec<String> {
    let mut errors = validate_auth_config(config).err().unwrap_or_default();
    if !config.require_auth {
        errors.push("FINWEALTH_REQUIRE_AUTH must be true for server deployment".to_string());
    }
    if !addr.ip().is_loopback() {
        errors.push("FINWEALTH_RS_ADDR must bind to a loopback address".to_string());
    }
    if !allowed_hosts
        .iter()
        .any(|host| !matches!(host.as_str(), "127.0.0.1" | "localhost" | "[::1]" | "::1"))
    {
        errors
            .push("FINWEALTH_ALLOWED_HOSTS must include the public reverse-proxy host".to_string());
    }
    if allow_ledger_scenario {
        errors.push("FINWEALTH_ALLOW_LEDGER_SCENARIO must be disabled in production".to_string());
    }
    if !matches!(
        quote_provider.map(str::trim),
        None | Some("") | Some("none") | Some("yahoo") | Some("public")
    ) {
        errors.push("FINWEALTH_QUOTE_PROVIDER must be none, yahoo, or public".to_string());
    }
    match (
        agent_base_url.map(str::trim).filter(|value| !value.is_empty()),
        agent_internal_token
            .map(str::trim)
            .filter(|value| !value.is_empty()),
    ) {
        (None, None) => {}
        (Some(base_url), Some(token)) => {
            let valid_url = reqwest::Url::parse(base_url).ok().is_some_and(|url| {
                url.scheme() == "http"
                    && url.port().is_some()
                    && url.username().is_empty()
                    && url.password().is_none()
                    && matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "::1"))
            });
            if !valid_url {
                errors.push(
                    "FINWEALTH_AGENT_BASE_URL must be an explicit loopback http URL with a port"
                        .to_string(),
                );
            }
            if token.len() < 32 || token == "change-me" {
                errors.push(
                    "FINWEALTH_AGENT_INTERNAL_TOKEN must be a non-placeholder value of at least 32 characters"
                        .to_string(),
                );
            }
        }
        _ => errors.push(
            "FINWEALTH_AGENT_BASE_URL and FINWEALTH_AGENT_INTERNAL_TOKEN must be configured together"
                .to_string(),
        ),
    }
    errors
}

#[derive(Debug, PartialEq, Eq)]
enum LedgerCommand {
    Init(PathBuf),
    Validate(PathBuf),
    ValidateAuthState(PathBuf),
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
            "--validate-auth-state" => {
                return Some(LedgerCommand::ValidateAuthState(PathBuf::from(
                    args.next()
                        .expect("--validate-auth-state requires a file path"),
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
        LedgerCommand::Init(requested_path) => {
            let lease = ledger_lease::acquire_ledger_lease(&requested_path)?;
            let path = lease.ledger_path().to_path_buf();
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
            let document = local_ledger::validate_supported_ledger(&path)?;
            println!(
                "validated real_local ledger at {} (version {}, base {})",
                path.display(),
                document["ledgerVersion"],
                document["baseCurrency"]
            );
            Ok(())
        }
        LedgerCommand::ValidateAuthState(path) => {
            let state = read_auth_state(&path)?;
            println!(
                "validated auth state at {} (devices {})",
                path.display(),
                state.devices.len()
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
    let middleware_state = state.clone();
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
        .route("/v1/liability-positions", get(liability_positions))
        .route(
            "/v1/accounts/{account_id}/repayment-schedule",
            get(loan_repayment_schedule),
        )
        .route(
            "/v1/accounts/{account_id}/liability-terms",
            patch(update_account_liability_terms),
        )
        .route(
            "/v1/accounts/{account_id}/loan-interest-proposals",
            post(create_loan_interest_proposal),
        )
        .route(
            "/v1/accounts/{account_id}/loan-payment-proposals",
            post(create_loan_payment_proposal),
        )
        .route(
            "/v1/accounts/{account_id}/holding-adjustment-proposals",
            post(create_holding_adjustment_proposal),
        )
        .route("/v1/portfolio/overview", get(portfolio_overview))
        .route("/v1/portfolio/valuation-issues", get(valuation_issues))
        .route("/v1/portfolio/holdings", get(holdings))
        .route("/v1/holdings", get(holdings))
        .route("/v1/yield-positions", get(yield_positions))
        .route(
            "/v1/holdings/{holding_id}/yield-terms",
            patch(update_holding_yield_terms),
        )
        .route(
            "/v1/holdings/{holding_id}/interest-proposals",
            post(create_holding_interest_proposal),
        )
        .route("/v1/portfolio/allocation", get(asset_allocation))
        .route("/v1/movements", get(movements))
        .route("/v1/movements/recent", get(recent_movements))
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
        .route(
            "/v1/subscriptions",
            get(subscriptions).post(create_subscription),
        )
        .route("/v1/subscriptions/upcoming", get(upcoming_subscriptions))
        .route(
            "/v1/subscriptions/charge-proposals/due-scan",
            post(create_due_subscription_charge_proposals),
        )
        .route(
            "/v1/subscriptions/{subscription_id}",
            get(subscription_detail).patch(update_subscription),
        )
        .route(
            "/v1/subscriptions/{subscription_id}/cancel",
            post(cancel_subscription),
        )
        .route(
            "/v1/subscriptions/{subscription_id}/charge-proposal",
            post(create_subscription_charge_proposal),
        )
        .route("/v1/ai/proposals/from-text", post(ai_proposal_from_text))
        .route(
            "/v1/ai/proposals/from-image",
            post(ai_proposal_from_image).layer(DefaultBodyLimit::max(15 * 1024 * 1024)),
        )
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
        .route("/v1/snapshots/invalidate", post(invalidate_snapshots))
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
        .route("/v1/sync/ack", post(sync_ack))
        .route("/v1/agent", any(agent_proxy))
        .route("/v1/agent/{*path}", any(agent_proxy))
        .route("/v1/transfers/execute", any(forbidden))
        .route("/v1/broker/orders", any(forbidden))
        .route("/v1/broker/buy", any(forbidden))
        .route("/v1/broker/sell", any(forbidden))
        .route("/v1/ai/auto-approve", any(forbidden))
        .route("/v1/ai/write-ledger-directly", any(forbidden))
        .route("/v1/coupons/plan", any(forbidden))
        .layer(middleware::from_fn_with_state(
            middleware_state,
            require_auth_middleware,
        ))
        .with_state(state)
}

async fn require_auth_middleware(
    State(state): State<AppState>,
    mut request: Request,
    next: Next,
) -> Response {
    if state.rejects_host_header(request.headers()) {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({
                "ok": false,
                "error": {
                    "code": "host_header_forbidden",
                    "message": "Host header is not allowed for a mounted local ledger.",
                    "severity": "critical",
                    "retryable": false
                }
            })),
        )
            .into_response();
    }
    if state.rejects_ledger_scenario(request.uri().query()) {
        return bad_request(
            "ledger_scenario_forbidden",
            "Scenario query parameters are disabled when a real local ledger is mounted.",
            json!({
                "reason": "scenario data must not be mixed with --ledger-path real ledger data",
                "override": "set FINWEALTH_ALLOW_LEDGER_SCENARIO=true only for explicit dev-only diagnostics"
            }),
        );
    }
    if is_public_auth_path(request.uri().path()) {
        return next.run(request).await;
    }
    if agent_internal_token_matches(&state, request.headers()) {
        if request.uri().path().starts_with("/v1/agent") {
            return forbidden().await;
        }
        insert_authenticated_principal(&mut request, AGENT_INTERNAL_DEVICE_ID.to_string());
        return next.run(request).await;
    }
    if !state.auth.should_require_auth() {
        insert_authenticated_principal(&mut request, DEV_UNAUTHENTICATED_DEVICE_ID.to_string());
        return next.run(request).await;
    }
    let Some(token) = bearer_token(request.headers()) else {
        return unauthorized("auth_required", "Bearer access token is required.");
    };
    let Some(device_id) = state.auth.device_id_for_access_token(&token) else {
        return unauthorized("auth_required", "Bearer access token is required.");
    };
    insert_authenticated_principal(&mut request, device_id);
    next.run(request).await
}

fn agent_internal_token_matches(state: &AppState, headers: &HeaderMap) -> bool {
    let Some(expected) = state.agent_gateway.internal_token.as_deref() else {
        return false;
    };
    let Some(candidate) = headers
        .get("x-finwealth-internal-token")
        .and_then(|value| value.to_str().ok())
    else {
        return false;
    };
    expected.len() == candidate.len() && bool::from(expected.as_bytes().ct_eq(candidate.as_bytes()))
}

fn insert_authenticated_principal(request: &mut Request, device_id: String) {
    request.extensions_mut().insert(AuthenticatedDevice {
        id: device_id.clone(),
    });
    request.extensions_mut().insert(AuthenticatedPrincipal {
        user_id: OWNER_USER_ID.to_string(),
        ledger_id: OWNER_LEDGER_ID.to_string(),
        device_id,
    });
}

async fn agent_proxy(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthenticatedPrincipal>,
    request: Request,
) -> Response {
    let Some(base_url) = state.agent_gateway.base_url.as_deref() else {
        return service_unavailable(
            "agent_service_unavailable",
            "Agent service is not configured.",
            json!({}),
            true,
        );
    };
    let Some(internal_token) = state.agent_gateway.internal_token.as_deref() else {
        return service_unavailable(
            "agent_service_unavailable",
            "Agent service authentication is not configured.",
            json!({}),
            false,
        );
    };

    let path_and_query = request
        .uri()
        .path_and_query()
        .map(|value| value.as_str())
        .unwrap_or(request.uri().path());
    let upstream_url = format!("{base_url}{path_and_query}");
    let method = request.method().clone();
    let forwarded_headers = request.headers().clone();
    let body = match to_bytes(request.into_body(), AGENT_PROXY_BODY_LIMIT).await {
        Ok(body) => body,
        Err(_) => {
            return bad_request(
                "agent_request_too_large",
                "Agent request body is too large.",
                json!({ "maxBytes": AGENT_PROXY_BODY_LIMIT }),
            );
        }
    };

    let mut upstream = state
        .agent_gateway
        .client
        .request(method, &upstream_url)
        .header("x-finwealth-internal-token", internal_token)
        .header("x-finwealth-user-id", &principal.user_id)
        .header("x-finwealth-ledger-id", &principal.ledger_id)
        .header("x-finwealth-device-id", &principal.device_id)
        .body(body);
    for header_name in [
        axum::http::header::ACCEPT,
        axum::http::header::CONTENT_TYPE,
        axum::http::header::IF_MATCH,
        axum::http::HeaderName::from_static("last-event-id"),
    ] {
        if let Some(value) = forwarded_headers.get(&header_name) {
            upstream = upstream.header(header_name, value);
        }
    }
    if let Some(value) = forwarded_headers.get("idempotency-key") {
        upstream = upstream.header("idempotency-key", value);
    }

    let upstream_response = match upstream.send().await {
        Ok(response) => response,
        Err(_) => {
            return service_unavailable(
                "agent_service_unavailable",
                "Agent service could not be reached.",
                json!({}),
                true,
            );
        }
    };
    let status = upstream_response.status();
    let response_headers = upstream_response.headers().clone();
    let mut response = Response::new(Body::from_stream(upstream_response.bytes_stream()));
    *response.status_mut() = status;
    for header_name in [
        axum::http::header::CONTENT_TYPE,
        axum::http::header::CACHE_CONTROL,
        axum::http::header::ETAG,
        axum::http::header::RETRY_AFTER,
        axum::http::HeaderName::from_static("idempotency-replayed"),
        axum::http::HeaderName::from_static("x-content-type-options"),
    ] {
        if let Some(value) = response_headers.get(&header_name) {
            response.headers_mut().insert(header_name, value.clone());
        }
    }
    response
}

fn is_public_auth_path(path: &str) -> bool {
    matches!(
        path,
        "/v1/health" | "/v1/auth/login" | "/v1/auth/refresh" | "/v1/auth/logout"
    )
}

fn query_has_non_empty_scenario(query: Option<&str>) -> bool {
    query.is_some_and(|query| {
        query.split('&').any(|part| match part.split_once('=') {
            Some(("scenario", value)) => !value.trim().is_empty(),
            Some(_) => false,
            None => part == "scenario",
        })
    })
}

fn allowed_hosts_from_env() -> Vec<String> {
    let mut hosts = vec![
        "127.0.0.1".to_string(),
        "localhost".to_string(),
        "[::1]".to_string(),
        "::1".to_string(),
    ];
    if let Ok(extra_hosts) = env::var("FINWEALTH_ALLOWED_HOSTS") {
        hosts.extend(
            extra_hosts
                .split(',')
                .filter_map(normalized_host_without_port),
        );
    }
    hosts.sort();
    hosts.dedup();
    hosts
}

fn host_header_is_allowed(headers: &HeaderMap, allowed_hosts: &[String]) -> bool {
    let Some(host) = headers.get("host").and_then(|value| value.to_str().ok()) else {
        return false;
    };
    normalized_host_without_port(host).is_some_and(|host| allowed_hosts.contains(&host))
}

fn normalized_host_without_port(value: &str) -> Option<String> {
    let value = value.trim().trim_end_matches('.').to_ascii_lowercase();
    if value.is_empty() {
        return None;
    }

    if let Some(without_opening_bracket) = value.strip_prefix('[') {
        let (host, suffix) = without_opening_bracket.split_once(']')?;
        if suffix.is_empty() || suffix.starts_with(':') {
            return Some(format!("[{host}]"));
        }
        return None;
    }

    if value.matches(':').count() == 1 {
        return value.split_once(':').map(|(host, _)| host.to_string());
    }

    Some(value)
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
        "serverTime": current_timestamp(),
        "version": env!("CARGO_PKG_VERSION")
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
) -> Response {
    if let Some(refresh_token) = body
        .as_ref()
        .and_then(|JsonExtractor(value)| value.get("refreshToken").and_then(Value::as_str))
    {
        if let Err(error) = state.auth.revoke_refresh_token(refresh_token) {
            return auth_error_response(error);
        }
    } else if let Some(token) = bearer_token(&headers)
        && let Err(error) = state.auth.revoke_access_token(&token)
    {
        return auth_error_response(error);
    }
    StatusCode::NO_CONTENT.into_response()
}

async fn auth_devices(State(state): State<AppState>) -> Json<Value> {
    envelope(state.auth.devices())
}

async fn revoke_device(State(state): State<AppState>, Path(device_id): Path<String>) -> Response {
    match state.auth.revoke_device(&device_id) {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(error) => auth_error_response(error),
    }
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

async fn create_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let idempotency = match idempotency_request(&headers, "POST /v1/accounts", &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    let account_id = next_local_account_id();

    match local_ledger::create_account(path, input, &account_id, &now, &idempotency) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_account_input"),
    }
}

async fn update_account(
    State(state): State<AppState>,
    Path(account_id): Path<String>,
    headers: HeaderMap,
    Json(patch): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let operation = format!("PATCH /v1/accounts/{account_id}");
    let idempotency = match idempotency_request(&headers, &operation, &patch, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::update_account(path, &account_id, patch, &now, &idempotency) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_account_patch"),
    }
}

async fn archive_account(
    State(state): State<AppState>,
    Path(account_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let operation = format!("POST /v1/accounts/{account_id}/archive");
    let idempotency = match idempotency_request(&headers, &operation, &Value::Null, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::archive_account(path, &account_id, &now, &idempotency) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_account_archive"),
    }
}

async fn create_holding_adjustment_proposal(
    State(state): State<AppState>,
    Path(account_id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let operation = format!("POST /v1/accounts/{account_id}/holding-adjustment-proposals");
    let idempotency = match idempotency_request(&headers, &operation, &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::create_holding_adjustment_proposal(
        path,
        &account_id,
        &input,
        &next_local_movement_id(),
        &next_local_atomic_group_id(),
        &now,
        &idempotency,
    ) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_holding_adjustment_input"),
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
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_account_anomalies(path, &current_timestamp()) {
            Ok(anomalies) => envelope(anomalies).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(
        state
            .ledger
            .account_anomalies(DevScenario::from_query(&query)),
    )
    .into_response()
}

async fn valuation_issues(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_valuation_issues(path, &current_timestamp()) {
            Ok(issues) => envelope(issues).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(json!([])).into_response()
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

async fn yield_positions(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return envelope(json!([])).into_response();
    };
    match local_ledger::list_yield_positions(path, query.get("throughDate").map(String::as_str)) {
        Ok(positions) => envelope(positions).into_response(),
        Err(error) => local_ledger_error(error, "invalid_yield_position_query"),
    }
}

async fn update_holding_yield_terms(
    State(state): State<AppState>,
    Path(holding_id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };
    let now = current_timestamp();
    let operation = format!("PATCH /v1/holdings/{holding_id}/yield-terms");
    let idempotency = match idempotency_request(&headers, &operation, &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::update_holding_yield_terms(path, &holding_id, &input, &now, &idempotency) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_yield_terms_input"),
    }
}

async fn create_holding_interest_proposal(
    State(state): State<AppState>,
    Path(holding_id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };
    let now = current_timestamp();
    let operation = format!("POST /v1/holdings/{holding_id}/interest-proposals");
    let idempotency = match idempotency_request(&headers, &operation, &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::create_holding_interest_proposal(
        path,
        &holding_id,
        &input,
        &next_local_movement_id(),
        &next_local_atomic_group_id(),
        &now,
        &idempotency,
    ) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_interest_proposal_input"),
    }
}

async fn liability_positions(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return envelope(json!([])).into_response();
    };
    match local_ledger::list_liability_positions(path, query.get("throughDate").map(String::as_str))
    {
        Ok(positions) => envelope(positions).into_response(),
        Err(error) => local_ledger_error(error, "invalid_liability_position_query"),
    }
}

async fn loan_repayment_schedule(
    State(state): State<AppState>,
    Path(account_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };
    match local_ledger::loan_repayment_schedule(
        path,
        &account_id,
        query.get("limit").map(String::as_str),
    ) {
        Ok(schedule) => envelope(schedule).into_response(),
        Err(error) => local_ledger_error(error, "invalid_loan_repayment_schedule_query"),
    }
}

async fn update_account_liability_terms(
    State(state): State<AppState>,
    Path(account_id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };
    let now = current_timestamp();
    let operation = format!("PATCH /v1/accounts/{account_id}/liability-terms");
    let idempotency = match idempotency_request(&headers, &operation, &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::update_account_liability_terms(
        path,
        &account_id,
        &input,
        &now,
        &idempotency,
    ) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_liability_terms_input"),
    }
}

async fn create_loan_interest_proposal(
    State(state): State<AppState>,
    Path(account_id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };
    let now = current_timestamp();
    let operation = format!("POST /v1/accounts/{account_id}/loan-interest-proposals");
    let idempotency = match idempotency_request(&headers, &operation, &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::create_loan_interest_proposal(
        path,
        &account_id,
        &input,
        &next_local_movement_id(),
        &next_local_atomic_group_id(),
        &now,
        &idempotency,
    ) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_loan_interest_proposal_input"),
    }
}

async fn create_loan_payment_proposal(
    State(state): State<AppState>,
    Path(account_id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };
    let now = current_timestamp();
    let operation = format!("POST /v1/accounts/{account_id}/loan-payment-proposals");
    let idempotency = match idempotency_request(&headers, &operation, &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::create_loan_payment_proposal(
        path,
        &account_id,
        &input,
        &next_local_movement_id(),
        &next_local_movement_id(),
        &next_local_atomic_group_id(),
        &now,
        &idempotency,
    ) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_loan_payment_proposal_input"),
    }
}

async fn movements(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let (status, limit) = match parse_movement_list_query(&query, None) {
        Ok(options) => options,
        Err(errors) => {
            return bad_request(
                "invalid_movement_query",
                "Movement list query is invalid.",
                json!({ "errors": errors }),
            );
        }
    };
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_movements(path) {
            Ok(movements) => envelope(filter_and_order_movements(
                movements,
                status.as_deref(),
                limit,
                false,
            ))
            .into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(filter_and_order_movements(
        state.ledger.movements(DevScenario::from_query(&query)),
        status.as_deref(),
        limit,
        false,
    ))
    .into_response()
}

async fn recent_movements(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let (status, limit) = match parse_movement_list_query(&query, Some(20)) {
        Ok(options) => options,
        Err(errors) => {
            return bad_request(
                "invalid_movement_query",
                "Recent movement query is invalid.",
                json!({ "errors": errors }),
            );
        }
    };
    let movements = if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        match local_ledger::list_movements(path) {
            Ok(movements) => movements,
            Err(error) => return ledger_io_error(error),
        }
    } else {
        state.ledger.movements(DevScenario::from_query(&query))
    };
    envelope(filter_and_order_movements(
        movements,
        status.as_deref(),
        limit,
        true,
    ))
    .into_response()
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
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let idempotency = match idempotency_request(&headers, "POST /v1/movements/drafts", &input, &now)
    {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    let movement_id = next_local_movement_id();
    let atomic_group_id = next_local_atomic_group_id();

    match local_ledger::create_movement_draft(
        path,
        input,
        &movement_id,
        &atomic_group_id,
        &now,
        &idempotency,
    ) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_movement_draft_input"),
    }
}

async fn submit_movement_review(
    State(state): State<AppState>,
    Path(movement_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let operation = format!("POST /v1/movements/{movement_id}/submit-review");
    let idempotency = match idempotency_request(&headers, &operation, &Value::Null, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::submit_movement_review(path, &movement_id, &now, &idempotency) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_movement_review_submit"),
    }
}

async fn create_correction(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let idempotency =
        match idempotency_request(&headers, "POST /v1/movements/corrections", &input, &now) {
            Ok(request) => request,
            Err(_) => return invalid_idempotency_key(),
        };
    let movement_id = next_local_movement_id();
    let atomic_group_id = next_local_atomic_group_id();

    match local_ledger::create_correction_proposal(
        path,
        input,
        &movement_id,
        &atomic_group_id,
        &now,
        &idempotency,
    ) {
        Ok(response) => idempotent_response(response),
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

async fn create_dca_plan(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let idempotency = match idempotency_request(&headers, "POST /v1/dca/plans", &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    let plan_id = next_local_dca_plan_id();
    let reminder_id = next_local_dca_reminder_id();

    match local_ledger::create_dca_plan(path, input, &plan_id, &reminder_id, &now, &idempotency) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_dca_plan_input"),
    }
}

async fn update_dca_plan(
    State(state): State<AppState>,
    Path(plan_id): Path<String>,
    headers: HeaderMap,
    Json(patch): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let operation = format!("PATCH /v1/dca/plans/{plan_id}");
    let idempotency = match idempotency_request(&headers, &operation, &patch, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::update_dca_plan(path, &plan_id, patch, &now, &idempotency) {
        Ok(response) => idempotent_response(response),
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
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    create_ai_import_proposal(state, headers, input, "user_text").await
}

async fn ai_proposal_from_image(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    create_ai_import_proposal(state, headers, input, "user_image").await
}

async fn ai_proposal_from_csv(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    create_ai_import_proposal(state, headers, input, "csv_import").await
}

async fn create_ai_import_proposal(
    state: AppState,
    headers: HeaderMap,
    input: Value,
    source_kind: &str,
) -> Response {
    if let Some(path) = state.local_ledger_path.as_ref() {
        let now = current_timestamp();
        let operation = match source_kind {
            "user_text" => "POST /v1/ai/proposals/from-text",
            "user_image" => "POST /v1/ai/proposals/from-image",
            "csv_import" => "POST /v1/ai/proposals/from-csv",
            _ => "POST /v1/ai/proposals",
        };
        let idempotency = match idempotency_request(&headers, operation, &input, &now) {
            Ok(request) => request,
            Err(_) => return invalid_idempotency_key(),
        };
        match local_ledger::replay_idempotency(path, &idempotency) {
            Ok(Some(response)) => return idempotent_response(response),
            Ok(None) => {}
            Err(error) => return local_ledger_error(error, "ai_import_idempotency_failed"),
        }
        let input = if matches!(source_kind, "user_text" | "user_image") {
            let image_url = if source_kind == "user_image" {
                match validated_ai_image_data_url(&input) {
                    Ok(image_url) => Some(image_url),
                    Err(failure) => {
                        return bad_request(
                            failure.code,
                            failure.message,
                            json!({"source": "user_image"}),
                        );
                    }
                }
            } else {
                None
            };
            match ai_provider_config() {
                Ok(Some(config)) => {
                    let accounts = match local_ledger::list_accounts(path) {
                        Ok(accounts) => accounts,
                        Err(error) => return ledger_io_error(error),
                    };
                    let organized = if source_kind == "user_text" {
                        organize_ai_text_with_provider(&config, input, &accounts, &now).await
                    } else {
                        organize_ai_image_with_provider(
                            &config,
                            input,
                            image_url.expect("validated image URL"),
                            &accounts,
                            &now,
                        )
                        .await
                    };
                    match organized {
                        Ok(input) => input,
                        Err(failure) => {
                            return service_unavailable(
                                failure.code,
                                failure.message,
                                json!({"provider": "openai_responses"}),
                                failure.retryable,
                            );
                        }
                    }
                }
                Ok(None) => input,
                Err(message) => {
                    return service_unavailable(
                        "ai_provider_configuration_invalid",
                        "AI provider configuration is incomplete or invalid.",
                        json!({"reason": message}),
                        false,
                    );
                }
            }
        } else {
            input
        };
        let context = local_ledger::AiImportContext {
            proposal_id: next_local_ai_proposal_id(),
            atomic_group_id: next_local_atomic_group_id(),
            movement_id: next_local_movement_id(),
            now,
        };
        return match local_ledger::create_ai_import_proposal(
            path,
            input,
            source_kind,
            &context,
            &idempotency,
        ) {
            Ok(response) => idempotent_response(response),
            Err(error) => local_ledger_error(error, "invalid_ai_import_proposal"),
        };
    }

    envelope(state.ledger.create_ai_proposal(source_kind)).into_response()
}

struct AiProviderConfig {
    endpoint: String,
    api_key: String,
    model: String,
}

#[derive(Debug)]
struct AiProviderFailure {
    code: &'static str,
    message: &'static str,
    retryable: bool,
}

fn ai_provider_config() -> Result<Option<AiProviderConfig>, String> {
    let provider = env::var("FINWEALTH_AI_PROVIDER").ok();
    let api_key = env::var("FINWEALTH_AI_API_KEY").ok();
    let model = env::var("FINWEALTH_AI_MODEL").ok();
    let base_url = env::var("FINWEALTH_AI_BASE_URL").ok();
    ai_provider_config_from(
        provider.as_deref(),
        api_key.as_deref(),
        model.as_deref(),
        base_url.as_deref(),
    )
}

fn ai_provider_config_from(
    provider: Option<&str>,
    api_key: Option<&str>,
    model: Option<&str>,
    base_url: Option<&str>,
) -> Result<Option<AiProviderConfig>, String> {
    match provider
        .unwrap_or("none")
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "" | "none" | "disabled" => return Ok(None),
        "openai" | "openai_responses" => {}
        _ => return Err("FINWEALTH_AI_PROVIDER must be none or openai_responses".to_string()),
    }
    let api_key = api_key
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| "FINWEALTH_AI_API_KEY is required".to_string())?
        .to_string();
    let model = model
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| "FINWEALTH_AI_MODEL is required".to_string())?
        .to_string();
    let mut url = reqwest::Url::parse(base_url.unwrap_or("https://api.openai.com/v1").trim())
        .map_err(|_| "FINWEALTH_AI_BASE_URL must be an absolute URL".to_string())?;
    let loopback_http =
        url.scheme() == "http" && matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "::1"));
    if url.scheme() != "https" && !loopback_http {
        return Err("FINWEALTH_AI_BASE_URL must use HTTPS or loopback HTTP".to_string());
    }
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(
            "FINWEALTH_AI_BASE_URL must not contain credentials, query, or fragment".to_string(),
        );
    }
    let path = format!("{}/responses", url.path().trim_end_matches('/'));
    url.set_path(&path);
    Ok(Some(AiProviderConfig {
        endpoint: url.to_string(),
        api_key,
        model,
    }))
}

async fn organize_ai_text_with_provider(
    config: &AiProviderConfig,
    mut input: Value,
    accounts: &Value,
    now: &str,
) -> Result<Value, AiProviderFailure> {
    let text = input
        .get("text")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or(AiProviderFailure {
            code: "ai_input_invalid",
            message: "Text input is required for AI organization.",
            retryable: false,
        })?;
    if text.len() > 20_000 {
        return Err(AiProviderFailure {
            code: "ai_input_too_large",
            message: "Text input is too large for AI organization.",
            retryable: false,
        });
    }
    let account_context = ai_provider_account_context(accounts);
    let account_ids = account_context
        .iter()
        .filter_map(|account| account.get("id").and_then(Value::as_str))
        .map(str::to_string)
        .collect::<Vec<_>>();
    let currencies = account_context
        .iter()
        .filter_map(|account| account.get("supportedCurrencies").and_then(Value::as_array))
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_string)
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    if account_ids.is_empty() || currencies.is_empty() {
        return Err(AiProviderFailure {
            code: "ai_context_unavailable",
            message: "No active cash account is available for AI organization.",
            retryable: false,
        });
    }
    let schema = ai_text_organization_schema(&account_ids, &currencies);
    let body = json!({
        "model": config.model,
        "store": false,
        "max_output_tokens": 1200,
        "instructions": concat!(
            "Convert one Chinese personal-finance note into at most one cash movement. ",
            "Return usable=false and movement=null when amount, direction, currency, or account cannot be determined from the note and account context. ",
            "Never invent an account or amount. Use the supplied current timestamp only when the note omits a date. ",
            "Income means cash in; expense means cash out. Keep the title short and factual."
        ),
        "input": format!(
            "Current timestamp: {now}\nAccounts: {}\nUser note: {text}",
            serde_json::to_string(&account_context).expect("account context should serialize")
        ),
        "text": {
            "format": {
                "type": "json_schema",
                "name": "finwealth_cash_movement",
                "strict": true,
                "schema": schema
            }
        }
    });
    let response = request_ai_structured_output(config, &body).await?;
    apply_ai_provider_output(
        &mut input,
        config,
        response,
        &account_context,
        now,
        "finwealth_cash_movement_text_v1",
    )?;
    Ok(input)
}

async fn organize_ai_image_with_provider(
    config: &AiProviderConfig,
    mut input: Value,
    image_url: String,
    accounts: &Value,
    now: &str,
) -> Result<Value, AiProviderFailure> {
    let account_context = ai_provider_account_context(accounts);
    let account_ids = account_context
        .iter()
        .filter_map(|account| account.get("id").and_then(Value::as_str))
        .map(str::to_string)
        .collect::<Vec<_>>();
    let currencies = account_context
        .iter()
        .filter_map(|account| account.get("supportedCurrencies").and_then(Value::as_array))
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_string)
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    if account_ids.is_empty() || currencies.is_empty() {
        return Err(AiProviderFailure {
            code: "ai_context_unavailable",
            message: "No active cash account is available for AI organization.",
            retryable: false,
        });
    }
    let schema = ai_text_organization_schema(&account_ids, &currencies);
    let context = format!(
        "Current timestamp: {now}\nAccounts: {}\nExtract at most one completed cash transaction from this image.",
        serde_json::to_string(&account_context).expect("account context should serialize")
    );
    let body = json!({
        "model": config.model,
        "store": false,
        "max_output_tokens": 1200,
        "instructions": concat!(
            "Read one receipt, payment screenshot, or transaction image and return at most one cash movement. ",
            "Return usable=false and movement=null unless amount, direction, currency, and a matching account are supported by visible evidence. ",
            "Never invent an account, amount, merchant, currency, or date. Use the supplied timestamp only when the image omits a date. ",
            "Income means cash in; expense means cash out. Keep the title short and factual."
        ),
        "input": [{
            "role": "user",
            "content": [
                {"type": "input_text", "text": context},
                {"type": "input_image", "image_url": image_url, "detail": "high"}
            ]
        }],
        "text": {
            "format": {
                "type": "json_schema",
                "name": "finwealth_cash_movement",
                "strict": true,
                "schema": schema
            }
        }
    });
    let response = request_ai_structured_output(config, &body).await?;
    apply_ai_provider_output(
        &mut input,
        config,
        response,
        &account_context,
        now,
        "finwealth_cash_movement_image_v1",
    )?;
    Ok(input)
}

fn validated_ai_image_data_url(input: &Value) -> Result<String, AiProviderFailure> {
    const MAX_IMAGE_BYTES: usize = 10 * 1024 * 1024;
    const MAX_ENCODED_BYTES: usize = 14 * 1024 * 1024;
    let object = input.as_object().ok_or(AiProviderFailure {
        code: "ai_image_input_invalid",
        message: "Image input is invalid.",
        retryable: false,
    })?;
    if object.keys().any(|key| {
        !matches!(
            key.as_str(),
            "fileName" | "mimeType" | "imageBase64" | "contextScope" | "selectedAccountIds"
        )
    }) {
        return Err(AiProviderFailure {
            code: "ai_image_input_invalid",
            message: "Image input contains unsupported fields.",
            retryable: false,
        });
    }
    let _file_name = object
        .get("fileName")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| {
            !value.is_empty()
                && value.chars().count() <= 255
                && !value.chars().any(char::is_control)
        })
        .ok_or(AiProviderFailure {
            code: "ai_image_input_file_name_invalid",
            message: "Image file name is missing or invalid.",
            retryable: false,
        })?;
    let mime_type = input
        .get("mimeType")
        .and_then(Value::as_str)
        .map(str::trim)
        .ok_or(AiProviderFailure {
            code: "ai_image_input_mime_invalid",
            message: "Choose a PNG, JPEG, or WEBP image.",
            retryable: false,
        })?;
    if !matches!(mime_type, "image/png" | "image/jpeg" | "image/webp") {
        return Err(AiProviderFailure {
            code: "ai_image_input_mime_invalid",
            message: "Choose a PNG, JPEG, or WEBP image.",
            retryable: false,
        });
    }
    let encoded = input
        .get("imageBase64")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty() && value.len() <= MAX_ENCODED_BYTES)
        .ok_or(AiProviderFailure {
            code: "ai_image_input_data_invalid",
            message: "Image data is missing or invalid.",
            retryable: false,
        })?;
    let bytes = STANDARD.decode(encoded).map_err(|_| AiProviderFailure {
        code: "ai_image_input_data_invalid",
        message: "Image data is missing or invalid.",
        retryable: false,
    })?;
    if bytes.is_empty()
        || bytes.len() > MAX_IMAGE_BYTES
        || !ai_image_magic_matches(mime_type, &bytes)
    {
        return Err(AiProviderFailure {
            code: if bytes.len() > MAX_IMAGE_BYTES {
                "ai_image_input_too_large"
            } else {
                "ai_image_input_data_invalid"
            },
            message: if bytes.len() > MAX_IMAGE_BYTES {
                "Image exceeds the 10 MiB limit."
            } else {
                "Image data does not match its declared format."
            },
            retryable: false,
        });
    }
    Ok(format!("data:{mime_type};base64,{encoded}"))
}

fn ai_image_magic_matches(mime_type: &str, bytes: &[u8]) -> bool {
    match mime_type {
        "image/png" => {
            bytes.len() >= 24
                && bytes.starts_with(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR")
                && bytes[16..20] != [0, 0, 0, 0]
                && bytes[20..24] != [0, 0, 0, 0]
        }
        "image/jpeg" => {
            bytes.len() >= 4
                && bytes.starts_with(&[0xff, 0xd8, 0xff])
                && bytes.ends_with(&[0xff, 0xd9])
        }
        "image/webp" => {
            bytes.len() >= 16
                && bytes.starts_with(b"RIFF")
                && &bytes[8..12] == b"WEBP"
                && matches!(&bytes[12..16], b"VP8 " | b"VP8L" | b"VP8X")
                && u32::from_le_bytes(bytes[4..8].try_into().expect("WEBP size bytes")) as usize + 8
                    == bytes.len()
        }
        _ => false,
    }
}

async fn request_ai_structured_output(
    config: &AiProviderConfig,
    body: &Value,
) -> Result<Value, AiProviderFailure> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(45))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("finwealth/0.1 self-use AI organizer")
        .build()
        .map_err(|_| AiProviderFailure {
            code: "ai_provider_client_failed",
            message: "AI provider client could not be initialized.",
            retryable: true,
        })?;
    let mut response = client
        .post(&config.endpoint)
        .bearer_auth(&config.api_key)
        .json(&body)
        .send()
        .await
        .map_err(|_| AiProviderFailure {
            code: "ai_provider_unavailable",
            message: "AI provider request failed.",
            retryable: true,
        })?;
    if !response.status().is_success() {
        return Err(AiProviderFailure {
            code: "ai_provider_rejected_request",
            message: "AI provider rejected the request.",
            retryable: response.status().is_server_error() || response.status().as_u16() == 429,
        });
    }
    const MAX_AI_RESPONSE_BYTES: usize = 1_048_576;
    if response
        .content_length()
        .is_some_and(|length| length > MAX_AI_RESPONSE_BYTES as u64)
    {
        return Err(AiProviderFailure {
            code: "ai_provider_response_too_large",
            message: "AI provider response exceeded the allowed size.",
            retryable: false,
        });
    }
    let mut response_bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| AiProviderFailure {
        code: "ai_provider_response_invalid",
        message: "AI provider returned an invalid response.",
        retryable: true,
    })? {
        if response_bytes.len().saturating_add(chunk.len()) > MAX_AI_RESPONSE_BYTES {
            return Err(AiProviderFailure {
                code: "ai_provider_response_too_large",
                message: "AI provider response exceeded the allowed size.",
                retryable: false,
            });
        }
        response_bytes.extend_from_slice(&chunk);
    }
    let response: Value =
        serde_json::from_slice(&response_bytes).map_err(|_| AiProviderFailure {
            code: "ai_provider_response_invalid",
            message: "AI provider returned an invalid response.",
            retryable: true,
        })?;
    Ok(response)
}

fn apply_ai_provider_output(
    input: &mut Value,
    config: &AiProviderConfig,
    response: Value,
    account_context: &[Value],
    now: &str,
    prompt_version: &str,
) -> Result<(), AiProviderFailure> {
    let structured = ai_structured_output(&response)?;
    if structured.get("usable").and_then(Value::as_bool) == Some(true) {
        let movement = ai_provider_movement_input(&structured, account_context, now)?;
        input["movement"] = movement;
    }
    input["_aiProvider"] = json!({
        "kind": "openai_responses",
        "model": config.model,
        "promptVersion": prompt_version,
        "responseId": response.get("id").cloned().unwrap_or(Value::Null),
        "usable": structured.get("usable").cloned().unwrap_or(json!(false)),
        "confidence": structured.get("confidence").cloned().unwrap_or(json!(0))
    });
    Ok(())
}

fn ai_provider_account_context(accounts: &Value) -> Vec<Value> {
    accounts
        .as_array()
        .into_iter()
        .flatten()
        .filter(|account| {
            account.get("status").and_then(Value::as_str) == Some("active")
                && matches!(
                    account.get("balanceMode").and_then(Value::as_str),
                    Some("cash_balance" | "mixed")
                )
                && !matches!(
                    account.get("accountType").and_then(Value::as_str),
                    Some("loan" | "credit_card")
                )
                && account
                    .get("supportedCurrencies")
                    .and_then(Value::as_array)
                    .is_some_and(|currencies| !currencies.is_empty())
        })
        .map(|account| {
            json!({
                "id": account["id"],
                "displayName": account["displayName"],
                "accountType": account["accountType"],
                "defaultCurrency": account["defaultCurrency"],
                "supportedCurrencies": account["supportedCurrencies"]
            })
        })
        .collect()
}

fn ai_text_organization_schema(account_ids: &[String], currencies: &[String]) -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["usable", "reason", "confidence", "movement"],
        "properties": {
            "usable": {"type": "boolean"},
            "reason": {"type": "string"},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
            "movement": {
                "anyOf": [
                    {
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["type", "occurredAt", "title", "accountId", "amount", "currency"],
                        "properties": {
                            "type": {"type": "string", "enum": ["income", "expense"]},
                            "occurredAt": {"type": "string", "format": "date-time"},
                            "title": {"type": "string"},
                            "accountId": {"type": "string", "enum": account_ids},
                            "amount": {"type": "string", "pattern": "^[0-9]+(?:\\.[0-9]{1,8})?$"},
                            "currency": {"type": "string", "enum": currencies}
                        }
                    },
                    {"type": "null"}
                ]
            }
        }
    })
}

fn ai_structured_output(response: &Value) -> Result<Value, AiProviderFailure> {
    if response.get("status").and_then(Value::as_str) != Some("completed") {
        return Err(AiProviderFailure {
            code: "ai_provider_response_incomplete",
            message: "AI provider response was incomplete.",
            retryable: true,
        });
    }
    for content in response
        .get("output")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| item.get("content").and_then(Value::as_array))
        .flatten()
    {
        if content.get("type").and_then(Value::as_str) == Some("refusal") {
            return Err(AiProviderFailure {
                code: "ai_provider_refused",
                message: "AI provider refused to organize this input.",
                retryable: false,
            });
        }
        if content.get("type").and_then(Value::as_str) == Some("output_text")
            && let Some(text) = content.get("text").and_then(Value::as_str)
        {
            let structured: Value = serde_json::from_str(text).map_err(|_| AiProviderFailure {
                code: "ai_provider_output_invalid",
                message: "AI provider output did not match the required structure.",
                retryable: true,
            })?;
            let confidence = structured.get("confidence").and_then(Value::as_f64);
            if structured.get("usable").and_then(Value::as_bool).is_none()
                || structured.get("reason").and_then(Value::as_str).is_none()
                || confidence
                    .is_none_or(|value| !value.is_finite() || !(0.0..=1.0).contains(&value))
                || !matches!(
                    structured.get("movement"),
                    Some(Value::Object(_) | Value::Null)
                )
            {
                return Err(AiProviderFailure {
                    code: "ai_provider_output_invalid",
                    message: "AI provider output did not match the required structure.",
                    retryable: true,
                });
            }
            return Ok(structured);
        }
    }
    Err(AiProviderFailure {
        code: "ai_provider_output_missing",
        message: "AI provider returned no structured output.",
        retryable: true,
    })
}

fn ai_provider_movement_input(
    structured: &Value,
    accounts: &[Value],
    now: &str,
) -> Result<Value, AiProviderFailure> {
    let movement = structured
        .get("movement")
        .and_then(Value::as_object)
        .ok_or(AiProviderFailure {
            code: "ai_provider_output_invalid",
            message: "AI provider marked output usable without a movement.",
            retryable: true,
        })?;
    let movement_type = movement.get("type").and_then(Value::as_str);
    let account_id = movement.get("accountId").and_then(Value::as_str);
    let currency = movement.get("currency").and_then(Value::as_str);
    let account = account_id.and_then(|id| {
        accounts
            .iter()
            .find(|account| account.get("id").and_then(Value::as_str) == Some(id))
    });
    let valid_currency = account.is_some_and(|account| {
        account
            .get("supportedCurrencies")
            .and_then(Value::as_array)
            .is_some_and(|items| items.iter().any(|item| item.as_str() == currency))
    });
    let amount = movement.get("amount").and_then(Value::as_str);
    let valid_amount = amount.is_some_and(local_decimal_is_positive);
    let occurred_at = movement
        .get("occurredAt")
        .and_then(Value::as_str)
        .filter(|value| OffsetDateTime::parse(value, &Rfc3339).is_ok());
    let title = movement
        .get("title")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty() && value.chars().count() <= 120);
    if !matches!(movement_type, Some("income" | "expense"))
        || account.is_none()
        || !valid_currency
        || !valid_amount
        || occurred_at.is_none()
        || title.is_none()
    {
        return Err(AiProviderFailure {
            code: "ai_provider_output_invalid",
            message: "AI provider output failed ledger validation.",
            retryable: true,
        });
    }
    let movement_type = movement_type.expect("validated movement type");
    let amount = amount.expect("validated amount");
    let currency = currency.expect("validated currency");
    Ok(json!({
        "type": movement_type,
        "occurredAt": occurred_at.unwrap_or(now),
        "title": title.expect("validated title"),
        "entries": [{
            "accountId": account_id.expect("validated account"),
            "amount": amount,
            "currency": currency,
            "direction": if movement_type == "income" {"in"} else {"out"},
            "role": "source"
        }],
        "amountBreakdown": {
            "paidAmount": {"amount": amount, "currency": currency}
        },
        "tags": ["ai_organized"]
    }))
}

fn local_decimal_is_positive(value: &str) -> bool {
    if value.is_empty()
        || value.len() > 32
        || value
            .as_bytes()
            .first()
            .is_some_and(|byte| matches!(byte, b'-' | b'+'))
    {
        return false;
    }
    let mut parts = value.split('.');
    let integer = parts.next().unwrap_or_default();
    let fraction = parts.next();
    if parts.next().is_some()
        || integer.is_empty()
        || !integer.bytes().all(|byte| byte.is_ascii_digit())
        || fraction.is_some_and(|fraction| {
            fraction.is_empty()
                || fraction.len() > 8
                || !fraction.bytes().all(|byte| byte.is_ascii_digit())
        })
    {
        return false;
    }
    integer.bytes().any(|byte| byte != b'0')
        || fraction.is_some_and(|fraction| fraction.bytes().any(|byte| byte != b'0'))
}

async fn mark_dca_executed_as_proposal(
    State(state): State<AppState>,
    Path(reminder_id): Path<String>,
    headers: HeaderMap,
    body: Option<Json<Value>>,
) -> Response {
    let input = body.map(|Json(value)| value).unwrap_or(Value::Null);
    if let Some(path) = state.local_ledger_path.as_ref() {
        let now = current_timestamp();
        let operation = format!("POST /v1/dca/reminders/{reminder_id}/mark-executed-as-proposal");
        let idempotency = match idempotency_request(&headers, &operation, &input, &now) {
            Ok(request) => request,
            Err(_) => return invalid_idempotency_key(),
        };
        let movement_id = next_local_movement_id();
        let atomic_group_id = next_local_atomic_group_id();
        return match local_ledger::mark_dca_executed_as_proposal(
            path,
            &reminder_id,
            &movement_id,
            &atomic_group_id,
            &input,
            &now,
            &idempotency,
        ) {
            Ok(response) => idempotent_response(response),
            Err(error) => local_ledger_error(error, "invalid_dca_mark_executed"),
        };
    }

    let Some(object) = input.as_object() else {
        return bad_request(
            "invalid_dca_mark_executed",
            "DCA execution input must be a JSON object.",
            json!({}),
        );
    };
    let missing = ["holdingAccountId", "quantity", "totalCost", "quoteCurrency"]
        .into_iter()
        .filter(|key| !object.contains_key(*key))
        .collect::<Vec<_>>();
    if !missing.is_empty() {
        return bad_request(
            "invalid_dca_mark_executed",
            "DCA execution input is incomplete.",
            json!({"missingFields": missing}),
        );
    }

    match state
        .ledger
        .mark_dca_executed_as_proposal(&reminder_id, &input)
    {
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
    headers: HeaderMap,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let operation = format!("POST /v1/dca/reminders/{reminder_id}/skip");
    let idempotency = match idempotency_request(&headers, &operation, &Value::Null, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::skip_dca_reminder(path, &reminder_id, &now, &idempotency) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_dca_reminder_skip"),
    }
}

async fn snooze_dca_reminder(
    State(state): State<AppState>,
    Path(reminder_id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let operation = format!("POST /v1/dca/reminders/{reminder_id}/snooze");
    let idempotency = match idempotency_request(&headers, &operation, &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::snooze_dca_reminder(path, &reminder_id, input, &now, &idempotency) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_dca_reminder_snooze"),
    }
}

async fn subscriptions(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when selected");
        return match local_ledger::list_subscriptions(path) {
            Ok(items) => envelope(items).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }
    envelope(json!([])).into_response()
}

async fn subscription_detail(
    State(state): State<AppState>,
    Path(subscription_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when selected");
        return match local_ledger::get_subscription(path, &subscription_id) {
            Ok(Some(item)) => envelope(item).into_response(),
            Ok(None) => not_found(
                "subscription_not_found",
                "Subscription does not exist in the local ledger.",
            ),
            Err(error) => ledger_io_error(error),
        };
    }
    not_found(
        "subscription_not_found",
        "Subscription does not exist in deterministic dev mode.",
    )
}

async fn upcoming_subscriptions(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let days = match query.get("days") {
        None => 30_i64,
        Some(value) => match value.parse::<i64>() {
            Ok(value @ 1..=365) => value,
            _ => {
                return bad_request(
                    "invalid_subscription_window",
                    "days must be an integer from 1 to 365",
                    json!({"field": "days"}),
                );
            }
        },
    };
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when selected");
        let through_date = (OffsetDateTime::now_utc().date() + Duration::days(days)).to_string();
        return match local_ledger::list_upcoming_subscriptions(path, &through_date) {
            Ok(items) => envelope(items).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }
    envelope(json!([])).into_response()
}

async fn create_subscription(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };
    let now = current_timestamp();
    let idempotency = match idempotency_request(&headers, "POST /v1/subscriptions", &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::create_subscription(
        path,
        input,
        &next_local_subscription_id(),
        &now,
        &idempotency,
    ) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_subscription_input"),
    }
}

async fn update_subscription(
    State(state): State<AppState>,
    Path(subscription_id): Path<String>,
    headers: HeaderMap,
    Json(patch): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };
    let now = current_timestamp();
    let operation = format!("PATCH /v1/subscriptions/{subscription_id}");
    let idempotency = match idempotency_request(&headers, &operation, &patch, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::update_subscription(path, &subscription_id, patch, &now, &idempotency) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_subscription_patch"),
    }
}

async fn cancel_subscription(
    State(state): State<AppState>,
    Path(subscription_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };
    let now = current_timestamp();
    let operation = format!("POST /v1/subscriptions/{subscription_id}/cancel");
    let idempotency = match idempotency_request(&headers, &operation, &Value::Null, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::cancel_subscription(path, &subscription_id, &now, &idempotency) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_subscription_cancel"),
    }
}

async fn create_subscription_charge_proposal(
    State(state): State<AppState>,
    Path(subscription_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };
    let now = current_timestamp();
    let operation = format!("POST /v1/subscriptions/{subscription_id}/charge-proposal");
    let idempotency = match idempotency_request(&headers, &operation, &Value::Null, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::create_subscription_charge_proposal(
        path,
        &subscription_id,
        &next_local_movement_id(),
        &next_local_atomic_group_id(),
        &now,
        &idempotency,
    ) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_subscription_charge_proposal"),
    }
}

async fn create_due_subscription_charge_proposals(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };
    let now = current_timestamp();
    let operation = "POST /v1/subscriptions/charge-proposals/due-scan";
    let idempotency = match idempotency_request(&headers, operation, &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::create_due_subscription_charge_proposals(
        path,
        input,
        &now,
        &idempotency,
        || (next_local_movement_id(), next_local_atomic_group_id()),
    ) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_subscription_due_scan"),
    }
}

async fn confirm_atomic_group(
    State(state): State<AppState>,
    Path(atomic_group_id): Path<String>,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    if let Some(path) = state.local_ledger_path.as_ref() {
        let now = current_timestamp();
        let operation = format!("POST {}", uri.path());
        let idempotency = match idempotency_request(&headers, &operation, &Value::Null, &now) {
            Ok(request) => request,
            Err(_) => return invalid_idempotency_key(),
        };
        return match local_ledger::confirm_atomic_group(path, &atomic_group_id, &now, &idempotency)
        {
            Ok(response) => idempotent_response(response),
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
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    if let Some(path) = state.local_ledger_path.as_ref() {
        let now = current_timestamp();
        let operation = format!("POST {}", uri.path());
        let idempotency = match idempotency_request(&headers, &operation, &Value::Null, &now) {
            Ok(request) => request,
            Err(_) => return invalid_idempotency_key(),
        };
        return match local_ledger::reject_atomic_group(path, &atomic_group_id, &now, &idempotency) {
            Ok(response) => idempotent_response(response),
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
    headers: HeaderMap,
    Json(patch): Json<Value>,
) -> Response {
    if let Some(path) = state.local_ledger_path.as_ref() {
        let now = current_timestamp();
        let operation = format!("POST /v1/ai/atomic-groups/{atomic_group_id}/edit");
        let idempotency = match idempotency_request(&headers, &operation, &patch, &now) {
            Ok(request) => request,
            Err(_) => return invalid_idempotency_key(),
        };
        return match local_ledger::edit_ai_atomic_group(
            path,
            &atomic_group_id,
            patch,
            &next_local_movement_id(),
            &now,
            &idempotency,
        ) {
            Ok(response) => idempotent_response(response),
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
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        let now = current_timestamp();
        let idempotency =
            match idempotency_request(&headers, "POST /v1/quotes/refresh", &input, &now) {
                Ok(request) => request,
                Err(_) => return invalid_idempotency_key(),
            };
        match local_ledger::replay_idempotency(path, &idempotency) {
            Ok(Some(response)) => return idempotent_response(response),
            Ok(None) => {}
            Err(error) => return local_ledger_error(error, "invalid_quote_refresh_input"),
        }
        let input = match enrich_quote_refresh_with_yahoo(path, input, &now).await {
            Ok(input) => input,
            Err(error_result) => {
                return match local_ledger::persist_idempotent_result(
                    path,
                    200,
                    error_result,
                    &idempotency,
                ) {
                    Ok(response) => idempotent_response(response),
                    Err(error) => local_ledger_error(error, "invalid_quote_refresh_input"),
                };
            }
        };
        return match local_ledger::refresh_quotes(path, input, &now, &idempotency) {
            Ok(response) => idempotent_response(response),
            Err(error) => local_ledger_error(error, "invalid_quote_refresh_input"),
        };
    }

    example_json(QUOTE_STALE).into_response()
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
                "message": "quote provider is disabled; explicitly configure public or yahoo, or pass quotes/fxRates payload",
                "retryable": false
            }],
            "completedAt": now
        }));
    }

    if quote_provider_public() {
        return enrich_quote_refresh_with_public(input, quote_targets, fx_targets, now).await;
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
    let value = env::var("FINWEALTH_QUOTE_PROVIDER").ok();
    quote_provider_disabled_value(value.as_deref())
}

fn quote_provider_disabled_value(value: Option<&str>) -> bool {
    !value.is_some_and(|value| {
        matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "yahoo" | "public"
        )
    })
}

fn quote_provider_public() -> bool {
    env::var("FINWEALTH_QUOTE_PROVIDER")
        .ok()
        .is_some_and(|value| value.trim().eq_ignore_ascii_case("public"))
}

fn quote_provider_yahoo() -> bool {
    env::var("FINWEALTH_QUOTE_PROVIDER")
        .ok()
        .is_some_and(|value| value.trim().eq_ignore_ascii_case("yahoo"))
}

async fn enrich_quote_refresh_with_public(
    mut input: Value,
    quote_targets: Vec<Value>,
    fx_targets: Vec<Value>,
    now: &str,
) -> Result<Value, Value> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .user_agent("finwealth/0.1 self-use quote refresh")
        .build()
        .map_err(|error| public_provider_failure(now, format!("HTTP client failed: {error}")))?;
    let needs_coingecko = quote_targets.iter().any(public_crypto_coin_id_for_target)
        || fx_targets.iter().any(public_fx_uses_coingecko);
    let coingecko = if needs_coingecko {
        match fetch_coingecko_prices(&client).await {
            Ok(value) => Some(value),
            Err(error) => {
                let mut errors = Vec::new();
                for target in &quote_targets {
                    if public_crypto_coin_id_for_target(target) {
                        errors.push(public_provider_error(
                            "instrument",
                            target.get("instrumentId").and_then(Value::as_str),
                            &error,
                            true,
                        ));
                    }
                }
                for target in &fx_targets {
                    if public_fx_uses_coingecko(target) {
                        errors.push(public_provider_error(
                            "fx_pair",
                            public_fx_target_id(target).as_deref(),
                            &error,
                            true,
                        ));
                    }
                }
                if let Some(object) = input.as_object_mut() {
                    object.insert("_providerErrors".to_string(), json!(errors));
                }
                return Ok(input);
            }
        }
    } else {
        None
    };

    let mut quotes = Vec::new();
    let mut fx_rates = Vec::new();
    let mut errors = Vec::new();
    for target in &quote_targets {
        match public_latest_quote(target, coingecko.as_ref(), now) {
            Ok(quote) => quotes.push(quote),
            Err(message) => errors.push(public_provider_error(
                "instrument",
                target.get("instrumentId").and_then(Value::as_str),
                &message,
                false,
            )),
        }
    }
    for target in &fx_targets {
        let result = if public_fx_uses_coingecko(target) {
            public_crypto_fx_rate(target, coingecko.as_ref(), now)
        } else {
            public_fiat_fx_rate(&client, target, now).await
        };
        match result {
            Ok(rate) => fx_rates.push(rate),
            Err(message) => errors.push(public_provider_error(
                "fx_pair",
                public_fx_target_id(target).as_deref(),
                &message,
                true,
            )),
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

fn public_provider_failure(now: &str, message: String) -> Value {
    json!({
        "status": "offline",
        "quotes": [],
        "fxRates": [],
        "errors": [{
            "targetType": "request",
            "message": message,
            "retryable": true
        }],
        "completedAt": now
    })
}

fn public_provider_error(
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

async fn fetch_coingecko_prices(client: &reqwest::Client) -> Result<Value, String> {
    client
        .get("https://api.coingecko.com/api/v3/simple/price")
        .query(&[
            ("ids", "bitcoin,ethereum,tether"),
            ("vs_currencies", "usd,cny"),
            ("include_last_updated_at", "true"),
        ])
        .send()
        .await
        .map_err(|error| format!("CoinGecko request failed: {error}"))?
        .error_for_status()
        .map_err(|error| format!("CoinGecko returned an error: {error}"))?
        .json::<Value>()
        .await
        .map_err(|error| format!("CoinGecko response was invalid: {error}"))
}

fn public_crypto_coin_id_for_target(target: &Value) -> bool {
    target
        .get("symbol")
        .and_then(Value::as_str)
        .and_then(public_coin_id_for_symbol)
        .is_some()
}

fn public_coin_id_for_symbol(symbol: &str) -> Option<&'static str> {
    let asset = symbol
        .split(['-', '/', '_'])
        .next()
        .unwrap_or(symbol)
        .to_ascii_uppercase();
    match asset.as_str() {
        "BTC" => Some("bitcoin"),
        "ETH" => Some("ethereum"),
        "USDT" => Some("tether"),
        _ => None,
    }
}

fn public_latest_quote(
    target: &Value,
    coingecko: Option<&Value>,
    now: &str,
) -> Result<Value, String> {
    let instrument_id = target
        .get("instrumentId")
        .and_then(Value::as_str)
        .ok_or_else(|| "quote target has no instrumentId".to_string())?;
    let symbol = target
        .get("symbol")
        .and_then(Value::as_str)
        .ok_or_else(|| "instrument has no public-provider symbol".to_string())?;
    let coin_id = public_coin_id_for_symbol(symbol)
        .ok_or_else(|| format!("public provider does not support instrument symbol: {symbol}"))?;
    let quote_currency = target
        .get("quoteCurrency")
        .and_then(Value::as_str)
        .ok_or_else(|| "quote target has no quoteCurrency".to_string())?;
    let data = coingecko.ok_or_else(|| "CoinGecko data is unavailable".to_string())?;
    let price = public_coin_price(data, coin_id, quote_currency)?;
    let price = provider_decimal_string(price)?;
    let as_of = public_coin_as_of(data, coin_id).unwrap_or_else(|| now.to_string());
    let expires_at = (OffsetDateTime::now_utc() + Duration::minutes(5))
        .format(&Rfc3339)
        .expect("RFC3339 formatting should succeed");
    Ok(json!({
        "instrumentId": instrument_id,
        "price": price,
        "currency": quote_currency,
        "asOf": as_of,
        "source": "coingecko",
        "sourceUrl": "https://www.coingecko.com/",
        "status": "fresh",
        "expiresAt": expires_at
    }))
}

fn public_coin_price(data: &Value, coin_id: &str, quote_currency: &str) -> Result<f64, String> {
    let direct_currency = quote_currency.to_ascii_lowercase();
    let price = if matches!(direct_currency.as_str(), "usd" | "cny") {
        data.get(coin_id)
            .and_then(|coin| coin.get(&direct_currency))
            .and_then(Value::as_f64)
    } else if direct_currency == "usdt" {
        let asset_usd = data
            .get(coin_id)
            .and_then(|coin| coin.get("usd"))
            .and_then(Value::as_f64);
        let tether_usd = data
            .get("tether")
            .and_then(|coin| coin.get("usd"))
            .and_then(Value::as_f64);
        asset_usd
            .zip(tether_usd)
            .map(|(asset, tether)| asset / tether)
    } else {
        None
    }
    .filter(|price| price.is_finite() && *price > 0.0)
    .ok_or_else(|| format!("CoinGecko has no usable {coin_id}/{quote_currency} price"))?;
    Ok(price)
}

fn public_coin_as_of(data: &Value, coin_id: &str) -> Option<String> {
    let timestamp = data.get(coin_id)?.get("last_updated_at")?.as_i64()?;
    OffsetDateTime::from_unix_timestamp(timestamp)
        .ok()?
        .format(&Rfc3339)
        .ok()
}

fn public_fx_uses_coingecko(target: &Value) -> bool {
    let base = target.get("baseCurrency").and_then(Value::as_str);
    let quote = target.get("quoteCurrency").and_then(Value::as_str);
    matches!(base, Some("USDT")) || matches!(quote, Some("USDT"))
}

fn public_fx_target_id(target: &Value) -> Option<String> {
    Some(format!(
        "{}/{}",
        target.get("baseCurrency")?.as_str()?,
        target.get("quoteCurrency")?.as_str()?
    ))
}

fn public_crypto_fx_rate(
    target: &Value,
    coingecko: Option<&Value>,
    now: &str,
) -> Result<Value, String> {
    let base = target
        .get("baseCurrency")
        .and_then(Value::as_str)
        .ok_or_else(|| "FX target has no baseCurrency".to_string())?;
    let quote = target
        .get("quoteCurrency")
        .and_then(Value::as_str)
        .ok_or_else(|| "FX target has no quoteCurrency".to_string())?;
    let data = coingecko.ok_or_else(|| "CoinGecko data is unavailable".to_string())?;
    let (currency, inverted) = if base == "USDT" {
        (quote, false)
    } else if quote == "USDT" {
        (base, true)
    } else {
        return Err(format!("unsupported crypto FX pair: {base}/{quote}"));
    };
    let direct = public_coin_price(data, "tether", currency)?;
    let rate = if inverted { 1.0 / direct } else { direct };
    let rate = provider_decimal_string(rate)?;
    let as_of = public_coin_as_of(data, "tether").unwrap_or_else(|| now.to_string());
    let expires_at = (OffsetDateTime::now_utc() + Duration::minutes(5))
        .format(&Rfc3339)
        .expect("RFC3339 formatting should succeed");
    Ok(json!({
        "baseCurrency": base,
        "quoteCurrency": quote,
        "rate": rate,
        "asOf": as_of,
        "source": "coingecko",
        "sourceUrl": "https://www.coingecko.com/",
        "status": "fresh",
        "expiresAt": expires_at
    }))
}

async fn public_fiat_fx_rate(
    client: &reqwest::Client,
    target: &Value,
    _now: &str,
) -> Result<Value, String> {
    let base = target
        .get("baseCurrency")
        .and_then(Value::as_str)
        .ok_or_else(|| "FX target has no baseCurrency".to_string())?;
    let quote = target
        .get("quoteCurrency")
        .and_then(Value::as_str)
        .ok_or_else(|| "FX target has no quoteCurrency".to_string())?;
    let response = client
        .get("https://api.frankfurter.app/latest")
        .query(&[("from", base), ("to", quote)])
        .send()
        .await
        .map_err(|error| format!("Frankfurter request failed for {base}/{quote}: {error}"))?
        .error_for_status()
        .map_err(|error| format!("Frankfurter returned an error for {base}/{quote}: {error}"))?
        .json::<Value>()
        .await
        .map_err(|error| format!("Frankfurter response was invalid: {error}"))?;
    public_fiat_fx_rate_from_response(base, quote, &response)
}

fn public_fiat_fx_rate_from_response(
    base: &str,
    quote: &str,
    response: &Value,
) -> Result<Value, String> {
    let rate = response
        .get("rates")
        .and_then(|rates| rates.get(quote))
        .and_then(Value::as_f64)
        .filter(|rate| rate.is_finite() && *rate > 0.0)
        .ok_or_else(|| format!("Frankfurter has no usable {base}/{quote} rate"))?;
    let rate = provider_decimal_string(rate)?;
    let date = response
        .get("date")
        .and_then(Value::as_str)
        .ok_or_else(|| "Frankfurter response has no date".to_string())?;
    let as_of = format!("{date}T00:00:00Z");
    let expires_at = (OffsetDateTime::now_utc() + Duration::hours(24))
        .format(&Rfc3339)
        .expect("RFC3339 formatting should succeed");
    Ok(json!({
        "baseCurrency": base,
        "quoteCurrency": quote,
        "rate": rate,
        "asOf": as_of,
        "source": "frankfurter_ecb",
        "sourceUrl": "https://frankfurter.app/",
        "status": "fresh",
        "expiresAt": expires_at
    }))
}

fn provider_decimal_string(value: f64) -> Result<String, String> {
    if !value.is_finite() || value <= 0.0 {
        return Err("provider value must be finite and positive".to_string());
    }
    let fixed = format!("{value:.8}");
    let normalized = fixed.trim_end_matches('0').trim_end_matches('.');
    if normalized.is_empty() || normalized == "0" {
        Err("provider value is below ledger precision".to_string())
    } else {
        Ok(normalized.to_string())
    }
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

fn parse_movement_list_query(
    query: &HashMap<String, String>,
    default_limit: Option<usize>,
) -> Result<(Option<String>, Option<usize>), Vec<String>> {
    const STATUSES: &[&str] = &[
        "draft",
        "pending_review",
        "confirmed",
        "in_transit",
        "cancelled",
        "reversed",
    ];
    let mut errors = Vec::new();
    let status = query.get("status").and_then(|value| {
        if STATUSES.contains(&value.as_str()) {
            Some(value.clone())
        } else {
            errors.push(format!("status must be one of: {}", STATUSES.join(", ")));
            None
        }
    });
    let limit = match query.get("limit") {
        Some(value) => match value.parse::<usize>() {
            Ok(value @ 1..=200) => Some(value),
            _ => {
                errors.push("limit must be an integer from 1 to 200".to_string());
                None
            }
        },
        None => default_limit,
    };

    if errors.is_empty() {
        Ok((status, limit))
    } else {
        Err(errors)
    }
}

fn filter_and_order_movements(
    movements: Value,
    status: Option<&str>,
    limit: Option<usize>,
    recent_first: bool,
) -> Value {
    let mut items = movements.as_array().cloned().unwrap_or_default();
    if let Some(status) = status {
        items.retain(|movement| movement.get("status").and_then(Value::as_str) == Some(status));
    }
    if recent_first {
        items.sort_by(|left, right| {
            let left_occurred = left
                .get("occurredAt")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let right_occurred = right
                .get("occurredAt")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let left_recorded = left
                .get("recordedAt")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let right_recorded = right
                .get("recordedAt")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let left_id = left.get("id").and_then(Value::as_str).unwrap_or_default();
            let right_id = right.get("id").and_then(Value::as_str).unwrap_or_default();
            right_occurred
                .cmp(left_occurred)
                .then_with(|| right_recorded.cmp(left_recorded))
                .then_with(|| right_id.cmp(left_id))
        });
    }
    if let Some(limit) = limit {
        items.truncate(limit);
    }
    json!(items)
}

fn parse_optional_snapshot_range(
    query: &HashMap<String, String>,
) -> Result<Option<(Date, Date)>, Vec<String>> {
    match (query.get("from"), query.get("to")) {
        (None, None) => Ok(None),
        (Some(_), None) | (None, Some(_)) => {
            Err(vec!["from and to must be provided together".to_string()])
        }
        (Some(from), Some(to)) => {
            let mut errors = Vec::new();
            let from_date = Date::parse(from, &Iso8601::DATE).map_err(|_| {
                errors.push("from must be an ISO date in YYYY-MM-DD format".to_string());
            });
            let to_date = Date::parse(to, &Iso8601::DATE).map_err(|_| {
                errors.push("to must be an ISO date in YYYY-MM-DD format".to_string());
            });
            if !errors.is_empty() {
                return Err(errors);
            }
            let from_date = from_date.expect("validated from date");
            let to_date = to_date.expect("validated to date");
            if to_date < from_date {
                return Err(vec!["to must be on or after from".to_string()]);
            }
            Ok(Some((from_date, to_date)))
        }
    }
}

fn filter_and_order_snapshots(snapshots: Value, range: Option<(Date, Date)>) -> Value {
    let mut items = snapshots.as_array().cloned().unwrap_or_default();
    if let Some((from, to)) = range {
        items.retain(|snapshot| {
            snapshot
                .get("snapshotAt")
                .and_then(Value::as_str)
                .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
                .map(OffsetDateTime::date)
                .is_some_and(|date| date >= from && date <= to)
        });
    }
    items.sort_by(|left, right| {
        right
            .get("snapshotAt")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .cmp(
                left.get("snapshotAt")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            )
    });
    json!(items)
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
        "syncCursor": local_ledger::sync_cursor_from_document(&document),
        "baseCurrency": document
            .get("baseCurrency")
            .and_then(Value::as_str)
            .unwrap_or(local_ledger::DEFAULT_BASE_CURRENCY),
        "accounts": local_ledger::list_accounts(path)?,
        "categories": local_ledger::list_categories(path)?,
        "counterparties": local_ledger::list_counterparties(path)?,
        "subscriptions": local_ledger::list_subscriptions(path)?,
        "capabilities": ledger_capabilities(
            "real_local",
            true,
            "file",
            !quote_provider_disabled()
        )
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

fn ledger_capabilities(
    data_source_mode: &str,
    can_write_confirmed_ledger: bool,
    proposal_persistence: &str,
    can_use_outbound_quote_provider: bool,
) -> Value {
    json!({
        "dataSourceMode": data_source_mode,
        "canWriteConfirmedLedger": can_write_confirmed_ledger,
        "canCreateAccount": can_write_confirmed_ledger,
        "canRecordMovement": can_write_confirmed_ledger,
        "canManageSubscriptions": can_write_confirmed_ledger,
        "canConfirmProposal": true,
        "canPersistPendingProposal": proposal_persistence != "none",
        "proposalPersistence": proposal_persistence,
        "canRefreshQuotes": can_write_confirmed_ledger,
        "canUseOutboundQuoteProvider": can_use_outbound_quote_provider,
        "canSync": false,
        "canUseRealAiProvider": false
    })
}

fn current_sync_cursor(state: &AppState, query: &HashMap<String, String>) -> String {
    if state.should_use_local_ledger(query)
        && let Some(path) = state.local_ledger_path.as_ref()
        && let Ok(document) = local_ledger::read_document(path)
    {
        return local_ledger::sync_cursor_from_document(&document);
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
    let range = match parse_optional_snapshot_range(&query) {
        Ok(range) => range,
        Err(errors) => {
            return bad_request(
                "invalid_snapshot_range",
                "Snapshot date range is invalid.",
                json!({ "errors": errors }),
            );
        }
    };
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        return match local_ledger::list_snapshots(path) {
            Ok(snapshots) => envelope(filter_and_order_snapshots(snapshots, range)).into_response(),
            Err(error) => ledger_io_error(error),
        };
    }

    envelope(filter_and_order_snapshots(
        state.ledger.snapshots(DevScenario::from_query(&query)),
        range,
    ))
    .into_response()
}

async fn create_manual_snapshot(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let idempotency = match idempotency_request(&headers, "POST /v1/snapshots/manual", &input, &now)
    {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::create_manual_snapshot(path, input, &now, &idempotency) {
        Ok(response) => idempotent_response(response),
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

async fn create_instrument(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let idempotency = match idempotency_request(&headers, "POST /v1/instruments", &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::create_instrument(path, input, &next_local_instrument_id(), &idempotency) {
        Ok(response) => idempotent_response(response),
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
    headers: HeaderMap,
    Json(patch): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let operation = format!("PATCH /v1/instruments/{instrument_id}");
    let idempotency = match idempotency_request(&headers, &operation, &patch, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::update_instrument(path, &instrument_id, patch, &idempotency) {
        Ok(response) => idempotent_response(response),
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
    if !quote_provider_yahoo() {
        return service_unavailable(
            "historical_prices_provider_unsupported",
            "The configured quote provider does not supply historical prices.",
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

async fn create_category(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let idempotency = match idempotency_request(&headers, "POST /v1/categories", &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::create_category(path, input, &next_local_category_id(), &idempotency) {
        Ok(response) => idempotent_response(response),
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
    headers: HeaderMap,
    Json(patch): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let operation = format!("PATCH /v1/categories/{category_id}");
    let idempotency = match idempotency_request(&headers, &operation, &patch, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::update_category(path, &category_id, patch, &idempotency) {
        Ok(response) => idempotent_response(response),
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

async fn create_counterparty(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let idempotency = match idempotency_request(&headers, "POST /v1/counterparties", &input, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::create_counterparty(
        path,
        input,
        &next_local_counterparty_id(),
        &idempotency,
    ) {
        Ok(response) => idempotent_response(response),
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
    headers: HeaderMap,
    Json(patch): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let operation = format!("PATCH /v1/counterparties/{counterparty_id}");
    let idempotency = match idempotency_request(&headers, &operation, &patch, &now) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::update_counterparty(path, &counterparty_id, patch, &idempotency) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_counterparty_patch"),
    }
}

async fn create_counterparty_merge_proposal(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return not_implemented().await;
    };

    let now = current_timestamp();
    let idempotency = match idempotency_request(
        &headers,
        "POST /v1/counterparties/merge-proposal",
        &input,
        &now,
    ) {
        Ok(request) => request,
        Err(_) => return invalid_idempotency_key(),
    };
    match local_ledger::create_counterparty_merge_proposal(
        path,
        input,
        &next_local_ai_proposal_id(),
        &next_local_atomic_group_id(),
        &now,
        &idempotency,
    ) {
        Ok(response) => idempotent_response(response),
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
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        let since = query.get("since").map(String::as_str);
        return match local_ledger::list_sync_changes(path, since) {
            Ok((cursor, changes)) => envelope(json!({
                "cursor": cursor,
                "changes": changes,
                "conflicts": []
            }))
            .into_response(),
            Err(error) => local_ledger_error(error, "invalid_sync_cursor"),
        };
    }

    envelope(json!({
        "cursor": current_sync_cursor(&state, &query),
        "changes": [],
        "conflicts": []
    }))
    .into_response()
}

async fn sync_push(
    State(state): State<AppState>,
    Extension(authenticated_device): Extension<AuthenticatedDevice>,
    Query(query): Query<HashMap<String, String>>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    let now = current_timestamp();
    let local_idempotency = if state.should_use_local_ledger(&query) {
        let idempotency = match idempotency_request(&headers, "POST /v1/sync/push", &input, &now) {
            Ok(request) => request,
            Err(_) => return invalid_idempotency_key(),
        };
        Some(idempotency)
    } else {
        None
    };
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
    if let Err(error) =
        local_ledger::validate_sync_push_input(&input, &authenticated_device.id, &now)
    {
        return local_ledger_error(error, "invalid_sync_push");
    }

    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        let idempotency =
            local_idempotency.expect("local idempotency should exist for local ledger");
        return match local_ledger::ingest_sync_push(
            path,
            input,
            &authenticated_device.id,
            &now,
            &idempotency,
        ) {
            Ok(response) => idempotent_response(response),
            Err(error) => local_ledger_error(error, "invalid_sync_push"),
        };
    }

    envelope(json!({
        "cursor": current_sync_cursor(&state, &query),
        "acceptedChangeIds": [],
        "appliedChangeIds": [],
        "skippedChangeIds": [],
        "conflicts": []
    }))
    .into_response()
}

async fn sync_ack(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> Response {
    if state.should_use_local_ledger(&query) {
        let path = state
            .local_ledger_path
            .as_ref()
            .expect("local ledger path should exist when local ledger is selected");
        let now = current_timestamp();
        let idempotency = match idempotency_request(&headers, "POST /v1/sync/ack", &input, &now) {
            Ok(request) => request,
            Err(_) => return invalid_idempotency_key(),
        };
        return match local_ledger::ack_sync_changes(path, input, &idempotency) {
            Ok(response) => idempotent_response(response),
            Err(error) => local_ledger_error(error, "invalid_sync_ack"),
        };
    }

    StatusCode::NO_CONTENT.into_response()
}

async fn invalidate_snapshots(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Option<JsonExtractor<Value>>,
) -> Response {
    let Some(path) = state.local_ledger_path.as_ref() else {
        return StatusCode::NO_CONTENT.into_response();
    };
    let body = body.map_or(Value::Null, |JsonExtractor(value)| value);
    let now = current_timestamp();
    let idempotency =
        match idempotency_request(&headers, "POST /v1/snapshots/invalidate", &body, &now) {
            Ok(request) => request,
            Err(_) => return invalid_idempotency_key(),
        };
    match local_ledger::persist_idempotent_result(path, 204, Value::Null, &idempotency) {
        Ok(response) => idempotent_response(response),
        Err(error) => local_ledger_error(error, "invalid_snapshot_invalidation"),
    }
}

async fn not_implemented() -> Response {
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(json!({
            "ok": false,
            "error": {
                "code": "rust_dev_route_not_implemented",
                "message": "This write endpoint requires --ledger-path and is unavailable in deterministic Rust dev mode.",
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

#[derive(Debug)]
struct InvalidIdempotencyKey;

fn idempotency_request(
    headers: &HeaderMap,
    operation: &str,
    body: &Value,
    now: &str,
) -> Result<local_ledger::IdempotencyRequest, InvalidIdempotencyKey> {
    let mut values = headers.get_all("idempotency-key").iter();
    let Some(value) = values.next() else {
        return Err(InvalidIdempotencyKey);
    };
    if values.next().is_some() {
        return Err(InvalidIdempotencyKey);
    }
    let Ok(key) = value.to_str() else {
        return Err(InvalidIdempotencyKey);
    };
    if key.is_empty()
        || key.len() > IDEMPOTENCY_KEY_MAX_BYTES
        || !key.bytes().all(|byte| matches!(byte, 0x21..=0x7e))
    {
        return Err(InvalidIdempotencyKey);
    }

    let canonical = canonical_json(body);
    let request_material = serde_json::to_vec(&json!({
        "operation": operation,
        "body": canonical
    }))
    .expect("canonical idempotency request should serialize");
    let created_at =
        OffsetDateTime::parse(now, &Rfc3339).expect("server timestamp should parse as RFC3339");
    let expires_at = (created_at + Duration::days(IDEMPOTENCY_RETENTION_DAYS))
        .format(&Rfc3339)
        .expect("idempotency expiry should format as RFC3339");

    Ok(local_ledger::IdempotencyRequest::new(
        token_hash(key),
        URL_SAFE_NO_PAD.encode(Sha256::digest(request_material)),
        operation.to_string(),
        now.to_string(),
        expires_at,
    ))
}

fn canonical_json(value: &Value) -> Value {
    match value {
        Value::Array(items) => Value::Array(items.iter().map(canonical_json).collect()),
        Value::Object(object) => {
            let mut entries = object.iter().collect::<Vec<_>>();
            entries.sort_unstable_by_key(|(key, _)| *key);
            let mut canonical = serde_json::Map::new();
            for (key, value) in entries {
                canonical.insert(key.clone(), canonical_json(value));
            }
            Value::Object(canonical)
        }
        _ => value.clone(),
    }
}

fn invalid_idempotency_key() -> Response {
    bad_request(
        "invalid_idempotency_key",
        "Idempotency-Key must be supplied exactly once as 1-128 visible ASCII characters.",
        json!({ "header": "Idempotency-Key" }),
    )
}

fn idempotent_response(result: local_ledger::IdempotentResponse) -> Response {
    let status = StatusCode::from_u16(result.status_code)
        .expect("validated idempotency response status should be an HTTP status");
    let mut response = if result.body.is_null() {
        status.into_response()
    } else {
        (status, Json(result.body)).into_response()
    };
    if result.replayed {
        response
            .headers_mut()
            .insert("idempotency-replayed", HeaderValue::from_static("true"));
    }
    response
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

fn next_local_subscription_id() -> String {
    next_local_id("sub_local")
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
    let sequence = LOCAL_ID_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}_{nanos}_{sequence}")
}

fn auth_tokens_json(tokens: AuthTokens) -> Value {
    json!({
        "accessToken": tokens.access_token,
        "refreshToken": tokens.refresh_token,
        "expiresAt": tokens.expires_at,
        "refreshExpiresAt": tokens.refresh_expires_at,
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
        AuthError::Storage => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({
                "ok": false,
                "error": {
                    "code": "auth_state_io_error",
                    "message": "Authentication state could not be persisted.",
                    "severity": "error",
                    "retryable": false
                }
            })),
        )
            .into_response(),
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

fn validate_auth_config(config: &AuthConfig) -> Result<(), Vec<String>> {
    let mut errors = Vec::new();
    if config.require_auth {
        match config.username.as_deref() {
            Some(value) if !value.trim().is_empty() => {}
            _ => errors
                .push("FINWEALTH_REQUIRE_AUTH=true requires FINWEALTH_AUTH_USERNAME".to_string()),
        }
        match config.password_hash.as_deref() {
            Some(value) if is_argon2_password_hash(value) => {}
            Some(_) => errors.push(
                "FINWEALTH_AUTH_PASSWORD_HASH must be a valid Argon2 password hash".to_string(),
            ),
            None => errors.push(
                "FINWEALTH_REQUIRE_AUTH=true requires FINWEALTH_AUTH_PASSWORD_HASH".to_string(),
            ),
        }
        if config
            .dev_plain_password
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty())
        {
            errors.push(
                "FINWEALTH_AUTH_PASSWORD plaintext fallback is not allowed when FINWEALTH_REQUIRE_AUTH=true".to_string(),
            );
        }
    } else if config
        .password_hash
        .as_deref()
        .is_some_and(|value| !value.trim().is_empty() && !is_argon2_password_hash(value))
    {
        errors
            .push("FINWEALTH_AUTH_PASSWORD_HASH must be a valid Argon2 password hash".to_string());
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
    }
}

fn is_argon2_password_hash(value: &str) -> bool {
    PasswordHash::new(value)
        .is_ok_and(|hash| matches!(hash.algorithm.as_str(), "argon2d" | "argon2i" | "argon2id"))
}

fn random_token(prefix: &str) -> String {
    let mut bytes = [0_u8; 32];
    OsRng.fill_bytes(&mut bytes);
    format!("{prefix}{}", URL_SAFE_NO_PAD.encode(bytes))
}

fn env_flag(name: &str) -> bool {
    env::var(name)
        .map(|value| {
            matches!(
                value.to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

fn token_hash(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    URL_SAFE_NO_PAD.encode(digest)
}

fn token_hash_eq(stored_hash: &str, candidate_hash: &str) -> bool {
    bool::from(stored_hash.as_bytes().ct_eq(candidate_hash.as_bytes()))
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

fn default_auth_state_path(ledger_path: &FsPath) -> PathBuf {
    ledger_path.with_extension("auth.json")
}

fn read_auth_state(path: &FsPath) -> io::Result<AuthState> {
    let raw = fs::read_to_string(path)?;
    let parsed: Value = serde_json::from_str(&raw).map_err(invalid_auth_state_data)?;
    auth_state_from_json(&parsed).map_err(invalid_auth_state_message)
}

fn write_auth_state(path: &FsPath, state: &AuthState) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp_path = path.with_extension("auth.json.tmp");
    let bytes =
        serde_json::to_vec_pretty(&auth_state_to_json(state)).map_err(invalid_auth_state_data)?;
    let mut temporary = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&tmp_path)?;
    temporary.write_all(&bytes)?;
    temporary.sync_all()?;
    drop(temporary);
    fs::rename(&tmp_path, path)?;
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)?
        .sync_all()?;
    sync_auth_parent_directory(path)?;
    Ok(())
}

#[cfg(unix)]
fn sync_auth_parent_directory(path: &FsPath) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::OpenOptions::new().read(true).open(parent)?.sync_all()?;
    }
    Ok(())
}

#[cfg(not(unix))]
fn sync_auth_parent_directory(_path: &FsPath) -> io::Result<()> {
    Ok(())
}

fn auth_state_to_json(state: &AuthState) -> Value {
    json!({
        "version": 1,
        "devices": state
            .devices
            .values()
            .map(|device| {
                json!({
                    "id": device.id,
                    "name": device.name,
                    "refreshTokenHash": device.refresh_token_hash,
                    "accessTokenHash": device.access_token_hash,
                    "accessExpiresAt": device.access_expires_at,
                    "refreshExpiresAt": device.refresh_expires_at,
                    "createdAt": device.created_at,
                    "lastSeenAt": device.last_seen_at
                })
            })
            .collect::<Vec<_>>()
    })
}

fn auth_state_from_json(value: &Value) -> Result<AuthState, String> {
    let Some(object) = value.as_object() else {
        return Err("auth state must be a JSON object".to_string());
    };
    if object.get("version").and_then(Value::as_i64) != Some(1) {
        return Err("auth state version must be 1".to_string());
    }
    let devices = object
        .get("devices")
        .and_then(Value::as_array)
        .ok_or_else(|| "auth state devices must be an array".to_string())?;
    let mut state = AuthState::default();
    for (index, item) in devices.iter().enumerate() {
        let Some(device) = item.as_object() else {
            return Err(format!("devices[{index}] must be an object"));
        };
        let id = required_auth_state_string(device, "id", index)?;
        let name = required_auth_state_string(device, "name", index)?;
        let refresh_token_hash = required_auth_state_string(device, "refreshTokenHash", index)?;
        let access_token_hash = required_auth_state_string(device, "accessTokenHash", index)?;
        let access_expires_at = required_auth_state_string(device, "accessExpiresAt", index)?;
        let created_at = required_auth_state_string(device, "createdAt", index)?;
        let refresh_expires_at = optional_auth_state_string(device, "refreshExpiresAt")
            .unwrap_or_else(|| default_refresh_expires_at(&created_at));
        let last_seen_at = required_auth_state_string(device, "lastSeenAt", index)?;
        if state.devices.contains_key(&id) {
            return Err(format!("devices[{index}].id must be unique"));
        }
        for (key, hash) in [
            ("refreshTokenHash", refresh_token_hash.as_str()),
            ("accessTokenHash", access_token_hash.as_str()),
        ] {
            if !is_sha256_urlsafe_hash(hash) {
                return Err(format!(
                    "devices[{index}].{key} must be a SHA-256 URL-safe hash"
                ));
            }
        }
        let created = parse_auth_state_timestamp(&created_at, index, "createdAt")?;
        let access_expires =
            parse_auth_state_timestamp(&access_expires_at, index, "accessExpiresAt")?;
        let refresh_expires =
            parse_auth_state_timestamp(&refresh_expires_at, index, "refreshExpiresAt")?;
        let last_seen = parse_auth_state_timestamp(&last_seen_at, index, "lastSeenAt")?;
        if access_expires <= created {
            return Err(format!(
                "devices[{index}].accessExpiresAt must be after createdAt"
            ));
        }
        if refresh_expires <= created {
            return Err(format!(
                "devices[{index}].refreshExpiresAt must be after createdAt"
            ));
        }
        if last_seen < created {
            return Err(format!(
                "devices[{index}].lastSeenAt must not be before createdAt"
            ));
        }
        state.devices.insert(
            id.clone(),
            AuthDevice {
                id,
                name,
                refresh_token_hash,
                access_token_hash,
                access_expires_at,
                refresh_expires_at,
                created_at,
                last_seen_at,
            },
        );
    }
    Ok(state)
}

fn is_sha256_urlsafe_hash(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn parse_auth_state_timestamp(
    value: &str,
    index: usize,
    key: &str,
) -> Result<OffsetDateTime, String> {
    OffsetDateTime::parse(value, &Rfc3339)
        .map_err(|_| format!("devices[{index}].{key} must be an RFC3339 timestamp"))
}

fn required_auth_state_string(
    object: &serde_json::Map<String, Value>,
    key: &str,
    index: usize,
) -> Result<String, String> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .ok_or_else(|| format!("devices[{index}].{key} must be a non-empty string"))
}

fn optional_auth_state_string(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Option<String> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
}

fn default_refresh_expires_at(created_at: &str) -> String {
    let created_at =
        OffsetDateTime::parse(created_at, &Rfc3339).unwrap_or_else(|_| OffsetDateTime::now_utc());
    (created_at + Duration::days(REFRESH_TOKEN_TTL_DAYS))
        .format(&Rfc3339)
        .expect("RFC3339 formatting should succeed")
}

fn invalid_auth_state_data(error: impl std::error::Error + Send + Sync + 'static) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error)
}

fn invalid_auth_state_message(message: String) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn access_token_expired(expires_at: &str) -> bool {
    token_expired(expires_at)
}

fn token_expired(expires_at: &str) -> bool {
    OffsetDateTime::parse(expires_at, &Rfc3339)
        .map(|expires_at| expires_at <= OffsetDateTime::now_utc())
        .unwrap_or(true)
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

fn conflict(code: &str, message: &str, details: Value) -> Response {
    (
        StatusCode::CONFLICT,
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
            conflict("local_ledger_conflict", &message, json!({}))
        }
        local_ledger::LedgerError::IdempotencyKeyReused => conflict(
            "idempotency_key_reused",
            "Idempotency-Key was already used for a different request.",
            json!({ "header": "Idempotency-Key" }),
        ),
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

    async fn test_response_json(response: Response) -> Value {
        let bytes = to_bytes(response.into_body(), 1024 * 1024)
            .await
            .expect("response body");
        serde_json::from_slice(&bytes).expect("JSON response")
    }

    #[tokio::test]
    async fn agent_gateway_injects_owner_principal_and_streams_upstream_response() {
        async fn upstream(headers: HeaderMap) -> Json<Value> {
            Json(json!({
                "ok": true,
                "data": {
                    "userId": headers
                        .get("x-finwealth-user-id")
                        .and_then(|value| value.to_str().ok()),
                    "ledgerId": headers
                        .get("x-finwealth-ledger-id")
                        .and_then(|value| value.to_str().ok()),
                    "deviceId": headers
                        .get("x-finwealth-device-id")
                        .and_then(|value| value.to_str().ok()),
                    "internalToken": headers
                        .get("x-finwealth-internal-token")
                        .and_then(|value| value.to_str().ok()),
                }
            }))
        }

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("agent gateway listener");
        let address = listener.local_addr().expect("agent gateway address");
        tokio::spawn(async move {
            axum::serve(
                listener,
                Router::new().route("/v1/agent/status", get(upstream)),
            )
            .await
            .expect("agent gateway server");
        });

        let response = app_with_state(
            AppState::dev().with_agent_gateway(format!("http://{address}"), "test-internal-token"),
        )
        .oneshot(
            Request::builder()
                .uri("/v1/agent/status")
                .body(Body::empty())
                .expect("agent status request"),
        )
        .await
        .expect("agent gateway response");
        assert_eq!(response.status(), StatusCode::OK);
        let body = test_response_json(response).await;
        assert_eq!(body["data"]["userId"], OWNER_USER_ID);
        assert_eq!(body["data"]["ledgerId"], OWNER_LEDGER_ID);
        assert_eq!(body["data"]["deviceId"], DEV_UNAUTHENTICATED_DEVICE_ID);
        assert_eq!(body["data"]["internalToken"], "test-internal-token");
    }

    #[tokio::test]
    async fn agent_gateway_is_fail_closed_when_not_configured() {
        let response = app()
            .oneshot(
                Request::builder()
                    .uri("/v1/agent/status")
                    .body(Body::empty())
                    .expect("agent status request"),
            )
            .await
            .expect("agent gateway response");
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        let body = test_response_json(response).await;
        assert_eq!(body["error"]["code"], "agent_service_unavailable");
    }

    #[tokio::test]
    async fn agent_internal_token_authenticates_sidecar_without_a_bearer_token() {
        let auth = AuthStore::configured("wu", hash_password_for_test("correct horse"), true);
        let router = app_with_state(
            AppState::dev()
                .with_auth(auth)
                .with_agent_gateway("http://127.0.0.1:9".to_string(), "sidecar-secret"),
        );

        let allowed = router
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/v1/accounts")
                    .header("x-finwealth-internal-token", "sidecar-secret")
                    .body(Body::empty())
                    .expect("internal request"),
            )
            .await
            .expect("internal response");
        assert_eq!(allowed.status(), StatusCode::OK);

        let denied = router
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/v1/accounts")
                    .header("x-finwealth-internal-token", "wrong-secret")
                    .body(Body::empty())
                    .expect("invalid internal request"),
            )
            .await
            .expect("invalid internal response");
        assert_eq!(denied.status(), StatusCode::UNAUTHORIZED);

        let recursion = router
            .oneshot(
                Request::builder()
                    .uri("/v1/agent/status")
                    .header("x-finwealth-internal-token", "sidecar-secret")
                    .body(Body::empty())
                    .expect("recursive internal request"),
            )
            .await
            .expect("recursive internal response");
        assert_eq!(recursion.status(), StatusCode::FORBIDDEN);
    }

    #[test]
    fn refuses_non_loopback_addresses() {
        let result = std::panic::catch_unwind(|| {
            assert_loopback("0.0.0.0:8790".parse().expect("valid socket addr"));
        });
        assert!(result.is_err());
    }

    #[test]
    fn token_hash_comparison_accepts_only_identical_hashes() {
        let first = token_hash("first-token");
        let same = token_hash("first-token");
        let different = token_hash("different-token");

        assert!(token_hash_eq(&first, &same));
        assert!(!token_hash_eq(&first, &different));
        assert!(!token_hash_eq(&first, "invalid-length"));
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
                "--validate-auth-state",
                "ledger.auth.json"
            ]),
            Some(LedgerCommand::ValidateAuthState(PathBuf::from(
                "ledger.auth.json"
            )))
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
    fn app_state_holds_ledger_lease_for_its_lifetime() {
        let requested_path = unique_test_ledger_path("app_state_lease");
        let lease = ledger_lease::acquire_ledger_lease_with_timeout(
            &requested_path,
            std::time::Duration::from_millis(60),
        )
        .expect("first lease should be acquired");
        let ledger_path = lease.ledger_path().to_path_buf();
        let lock_path = lease.lock_path().to_path_buf();
        let state = AppState::local_with_lease(ledger_path.clone(), Arc::new(lease));

        let error = ledger_lease::acquire_ledger_lease_with_timeout(
            &ledger_path,
            std::time::Duration::from_millis(60),
        )
        .expect_err("AppState must keep the lease held");
        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);

        drop(state);
        let reacquired = ledger_lease::acquire_ledger_lease_with_timeout(
            &ledger_path,
            std::time::Duration::ZERO,
        )
        .expect("dropping AppState should release the OS lease");
        drop(reacquired);
        assert!(lock_path.is_file(), "the permanent sidecar must remain");
        let _ = fs::remove_file(lock_path);
        if let Some(parent) = ledger_path.parent() {
            let _ = fs::remove_dir(parent);
        }
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
    fn auth_state_validation_rejects_duplicate_devices_and_invalid_security_fields() {
        let device = json!({
            "id": "device_duplicate",
            "name": "Test device",
            "refreshTokenHash": token_hash("refresh"),
            "accessTokenHash": token_hash("access"),
            "accessExpiresAt": "2026-07-11T01:00:00Z",
            "refreshExpiresAt": "2026-08-11T00:00:00Z",
            "createdAt": "2026-07-11T00:00:00Z",
            "lastSeenAt": "2026-07-11T00:00:00Z"
        });
        let duplicate = json!({
            "version": 1,
            "devices": [device.clone(), device.clone()]
        });
        let error = auth_state_from_json(&duplicate)
            .err()
            .expect("duplicate device must fail");
        assert!(error.contains("id must be unique"));

        let mut invalid = device;
        invalid["refreshTokenHash"] = json!("not-a-hash");
        invalid["lastSeenAt"] = json!("not-a-time");
        let error = auth_state_from_json(&json!({"version": 1, "devices": [invalid]}))
            .err()
            .expect("invalid auth security fields must fail");
        assert!(error.contains("SHA-256 URL-safe hash"));
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
        let idempotency_key = next_local_id("test_idempotency");
        let (status, _, body) = request_json_body_with_idempotency_from(
            router,
            method,
            uri,
            body,
            Some(&idempotency_key),
        )
        .await;
        (status, body)
    }

    async fn request_json_body_with_idempotency_from(
        router: Router,
        method: Method,
        uri: &str,
        body: Value,
        idempotency_key: Option<&str>,
    ) -> (StatusCode, HeaderMap, Value) {
        let mut builder = Request::builder()
            .method(method)
            .uri(uri)
            .header("content-type", "application/json")
            .header("host", "127.0.0.1");
        if let Some(idempotency_key) = idempotency_key {
            builder = builder.header("idempotency-key", idempotency_key);
        }
        let response = router
            .oneshot(
                builder
                    .body(Body::from(
                        serde_json::to_vec(&body).expect("request body should serialize"),
                    ))
                    .expect("request should build"),
            )
            .await
            .expect("router should respond");
        let status = response.status();
        let headers = response.headers().clone();
        let bytes = to_bytes(response.into_body(), 1024 * 1024)
            .await
            .expect("response body should read");
        let body = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).expect("response body should be JSON")
        };
        (status, headers, body)
    }

    async fn create_test_subscription(
        router: Router,
        account_id: &str,
        display_name: &str,
        next_charge_date: &str,
        status: &str,
    ) -> String {
        let (status_code, body) = request_json_body_from(
            router,
            Method::POST,
            "/v1/subscriptions",
            json!({
                "displayName": display_name,
                "provider": "Integration provider",
                "amount": {"amount": "20.00", "currency": "USD"},
                "paymentAccountId": account_id,
                "billingCycle": {"unit": "month", "interval": 1},
                "startDate": next_charge_date,
                "nextChargeDate": next_charge_date,
                "status": status
            }),
        )
        .await;
        assert_eq!(status_code, StatusCode::CREATED, "{body}");
        body["data"]["id"]
            .as_str()
            .expect("subscription id")
            .to_string()
    }

    fn sync_account_create_change(device_id: &str, change_id: &str, account_id: &str) -> Value {
        json!({
            "id": change_id,
            "deviceId": device_id,
            "entityType": "account",
            "entityId": account_id,
            "operation": "create",
            "baseVersion": 0,
            "payload": {
                "id": account_id,
                "displayName": "远端同步账户",
                "accountType": "bank",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "visibility": "normal",
                "status": "active",
                "balanceMode": "cash_balance",
                "cashBalances": [],
                "tags": [],
                "createdAt": "2026-07-13T00:00:00Z",
                "updatedAt": "2026-07-13T00:00:00Z"
            },
            "createdAt": "2026-07-13T00:00:00Z"
        })
    }

    async fn request_json_with_bearer_from(
        router: Router,
        method: Method,
        uri: &str,
        token: &str,
    ) -> (StatusCode, Value) {
        let response = router
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(uri)
                    .header("authorization", format!("Bearer {token}"))
                    .header("host", "127.0.0.1")
                    .body(Body::empty())
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

    async fn request_json_body_with_bearer_from(
        router: Router,
        method: Method,
        uri: &str,
        token: &str,
        body: Value,
    ) -> (StatusCode, Value) {
        let response = router
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(uri)
                    .header("authorization", format!("Bearer {token}"))
                    .header("content-type", "application/json")
                    .header("idempotency-key", next_local_id("test_idempotency"))
                    .header("host", "127.0.0.1")
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

    #[test]
    fn auth_config_fails_closed_when_require_auth_is_incomplete() {
        let missing_hash = AuthConfig {
            username: Some("wu".to_string()),
            password_hash: None,
            dev_plain_password: None,
            require_auth: true,
            state_path: None,
        };
        let errors = validate_auth_config(&missing_hash).expect_err("hash should be required");
        assert!(errors.iter().any(|error| error.contains("PASSWORD_HASH")));

        let missing_username = AuthConfig {
            username: None,
            password_hash: Some(hash_password_for_test("correct horse")),
            dev_plain_password: None,
            require_auth: true,
            state_path: None,
        };
        let errors =
            validate_auth_config(&missing_username).expect_err("username should be required");
        assert!(errors.iter().any(|error| error.contains("USERNAME")));
    }

    #[test]
    fn auth_config_rejects_plaintext_fallback_when_require_auth_is_enabled() {
        let config = AuthConfig {
            username: Some("wu".to_string()),
            password_hash: Some(hash_password_for_test("correct horse")),
            dev_plain_password: Some("correct horse".to_string()),
            require_auth: true,
            state_path: None,
        };
        let errors = validate_auth_config(&config).expect_err("plaintext fallback is unsafe");
        assert!(
            errors
                .iter()
                .any(|error| error.contains("plaintext fallback"))
        );
    }

    #[test]
    fn auth_config_rejects_a_valid_non_argon2_phc_hash() {
        let non_argon2 = "$pbkdf2-sha256$i=600000,l=32$c29tZXNhbHQxMjM0NTY3OA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        PasswordHash::new(non_argon2).expect("test fixture should be valid PHC syntax");
        let config = AuthConfig {
            username: Some("wu".to_string()),
            password_hash: Some(non_argon2.to_string()),
            dev_plain_password: None,
            require_auth: true,
            state_path: None,
        };

        let errors = validate_auth_config(&config).expect_err("non-Argon2 hash must fail closed");
        assert!(errors.iter().any(|error| error.contains("Argon2")));
    }

    #[test]
    fn production_config_requires_loopback_auth_and_public_host() {
        let secure = AuthConfig {
            username: Some("wu".to_string()),
            password_hash: Some(hash_password_for_test("correct horse")),
            dev_plain_password: None,
            require_auth: true,
            state_path: None,
        };
        let valid = production_config_errors(
            &secure,
            "127.0.0.1:8790".parse().expect("test address"),
            &["127.0.0.1".to_string(), "api.example.com".to_string()],
            false,
            Some("none"),
            None,
            None,
        );
        assert!(valid.is_empty(), "{valid:?}");
        let public_provider = production_config_errors(
            &secure,
            "127.0.0.1:8790".parse().expect("test address"),
            &["127.0.0.1".to_string(), "api.example.com".to_string()],
            false,
            Some("public"),
            Some("http://127.0.0.1:8792"),
            Some("0123456789abcdef0123456789abcdef"),
        );
        assert!(public_provider.is_empty(), "{public_provider:?}");

        let open = AuthConfig {
            username: None,
            password_hash: None,
            dev_plain_password: None,
            require_auth: false,
            state_path: None,
        };
        let errors = production_config_errors(
            &open,
            "0.0.0.0:8790".parse().expect("test address"),
            &["127.0.0.1".to_string(), "localhost".to_string()],
            true,
            Some("typo"),
            Some("https://agent.example.com"),
            None,
        );
        assert!(errors.iter().any(|error| error.contains("REQUIRE_AUTH")));
        assert!(errors.iter().any(|error| error.contains("loopback")));
        assert!(errors.iter().any(|error| error.contains("ALLOWED_HOSTS")));
        assert!(errors.iter().any(|error| error.contains("LEDGER_SCENARIO")));
        assert!(errors.iter().any(|error| error.contains("QUOTE_PROVIDER")));
        assert!(
            errors
                .iter()
                .any(|error| error.contains("configured together"))
        );
    }

    #[test]
    fn auth_config_accepts_hash_only_require_auth_and_open_dev_mode() {
        let require_auth = AuthConfig {
            username: Some("wu".to_string()),
            password_hash: Some(hash_password_for_test("correct horse")),
            dev_plain_password: None,
            require_auth: true,
            state_path: None,
        };
        validate_auth_config(&require_auth).expect("hash-only auth config should be valid");

        let dev_mode = AuthConfig {
            username: None,
            password_hash: None,
            dev_plain_password: None,
            require_auth: false,
            state_path: None,
        };
        validate_auth_config(&dev_mode).expect("open dev mode should remain available");
    }

    #[tokio::test]
    async fn auth_login_refresh_devices_and_revoke_use_hashed_passwords() {
        let auth = AuthStore::configured("wu", hash_password_for_test("correct horse"), false);
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
        assert!(
            login_body["data"]["refreshExpiresAt"].as_str().is_some(),
            "login response should expose refresh token expiry"
        );
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
        assert!(
            refresh_body["data"]["refreshExpiresAt"].as_str().is_some(),
            "refresh response should rotate refresh token expiry"
        );
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
    async fn auth_logout_with_bearer_revokes_matching_access_token_device() {
        let auth = AuthStore::configured("wu", hash_password_for_test("correct horse"), false);
        let router = app_with_state(AppState::dev().with_auth(auth));

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
        let access_token = login_body["data"]["accessToken"]
            .as_str()
            .expect("access token should be string")
            .to_string();
        let refresh_token = login_body["data"]["refreshToken"]
            .as_str()
            .expect("refresh token should be string")
            .to_string();

        let (logout_status, logout_body) = request_json_with_bearer_from(
            router.clone(),
            Method::POST,
            "/v1/auth/logout",
            &access_token,
        )
        .await;
        assert_eq!(logout_status, StatusCode::NO_CONTENT);
        assert_eq!(logout_body, Value::Null);

        let (devices_status, devices_body) =
            request_json_from(router.clone(), Method::GET, "/v1/auth/devices").await;
        assert_eq!(devices_status, StatusCode::OK);
        assert_eq!(devices_body["data"], json!([]));

        let (refresh_status, refresh_body) = request_json_body_from(
            router,
            Method::POST,
            "/v1/auth/refresh",
            json!({ "refreshToken": refresh_token }),
        )
        .await;
        assert_eq!(refresh_status, StatusCode::UNAUTHORIZED);
        assert_eq!(refresh_body["error"]["code"], "invalid_credentials");
    }

    #[tokio::test]
    async fn require_auth_protects_non_public_routes_when_enabled() {
        let auth = AuthStore::configured("wu", hash_password_for_test("correct horse"), true);
        let router = app_with_state(AppState::dev().with_auth(auth));

        let (health_status, _) = request_json_from(router.clone(), Method::GET, "/v1/health").await;
        assert_eq!(health_status, StatusCode::OK);

        let (blocked_status, blocked_body) =
            request_json_from(router.clone(), Method::GET, "/v1/accounts").await;
        assert_eq!(blocked_status, StatusCode::UNAUTHORIZED);
        assert_eq!(blocked_body["error"]["code"], "auth_required");

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
        let access_token = login_body["data"]["accessToken"]
            .as_str()
            .expect("access token should be string")
            .to_string();

        let (allowed_status, allowed_body) = request_json_with_bearer_from(
            router.clone(),
            Method::GET,
            "/v1/accounts",
            &access_token,
        )
        .await;
        assert_eq!(allowed_status, StatusCode::OK);
        assert_eq!(allowed_body["data"], json!([]));

        let (devices_status, devices_body) = request_json_with_bearer_from(
            router.clone(),
            Method::GET,
            "/v1/auth/devices",
            &access_token,
        )
        .await;
        assert_eq!(devices_status, StatusCode::OK);
        assert_eq!(devices_body["data"][0]["name"], "Windows");

        let (wrong_token_status, _) =
            request_json_with_bearer_from(router, Method::GET, "/v1/accounts", "fw_access_wrong")
                .await;
        assert_eq!(wrong_token_status, StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn sync_push_binds_account_create_to_authenticated_device() {
        let path = unique_test_ledger_path("sync_authenticated_device");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let auth = AuthStore::configured("wu", hash_password_for_test("correct horse"), true);
        let router = app_with_state(AppState::local(path.clone()).with_auth(auth));

        let (login_status, login_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/auth/login",
            json!({
                "username": "wu",
                "password": "correct horse",
                "deviceName": "Windows sync client"
            }),
        )
        .await;
        assert_eq!(login_status, StatusCode::OK, "{login_body}");
        let access_token = login_body["data"]["accessToken"]
            .as_str()
            .expect("access token should be string");
        let device_id = login_body["data"]["deviceId"]
            .as_str()
            .expect("device id should be string");

        let push = json!({
            "deviceId": device_id,
            "changes": [{
                "id": "authenticated_change_000001",
                "deviceId": device_id,
                "entityType": "account",
                "entityId": "acct_authenticated_remote",
                "operation": "create",
                "baseVersion": 0,
                "payload": {
                    "id": "acct_authenticated_remote",
                    "displayName": "认证远端账户",
                    "accountType": "bank",
                    "defaultCurrency": "CNY",
                    "supportedCurrencies": ["CNY"],
                    "includeInNetWorth": true,
                    "visibility": "normal",
                    "status": "active",
                    "balanceMode": "cash_balance",
                    "cashBalances": [],
                    "tags": [],
                    "createdAt": "2026-07-13T00:00:00Z",
                    "updatedAt": "2026-07-13T00:00:00Z"
                },
                "createdAt": "2026-07-13T00:00:00Z"
            }]
        });
        let mut impersonated_push = push.clone();
        impersonated_push["deviceId"] = json!("dev_auth_device_impersonated");
        impersonated_push["changes"][0]["deviceId"] = json!("dev_auth_device_impersonated");
        let (impersonated_status, impersonated_body) = request_json_body_with_bearer_from(
            router.clone(),
            Method::POST,
            "/v1/sync/push",
            access_token,
            impersonated_push,
        )
        .await;
        assert_eq!(impersonated_status, StatusCode::BAD_REQUEST);
        assert_eq!(impersonated_body["error"]["code"], "invalid_sync_push");
        let unchanged = local_ledger::read_document(&path).expect("rejected push must not mutate");
        assert_eq!(unchanged["accounts"], json!([]));
        assert_eq!(unchanged["syncChanges"], json!([]));

        let (push_status, push_body) = request_json_body_with_bearer_from(
            router,
            Method::POST,
            "/v1/sync/push",
            access_token,
            push,
        )
        .await;
        assert_eq!(push_status, StatusCode::OK, "{push_body}");
        assert_eq!(
            push_body["data"]["appliedChangeIds"],
            json!(["authenticated_change_000001"])
        );
        let document = local_ledger::read_document(&path).expect("push should persist atomically");
        assert_eq!(document["accounts"][0]["id"], "acct_authenticated_remote");
        assert_eq!(document["syncChanges"][0]["sourceDeviceId"], device_id);
        assert_eq!(document["syncState"]["pendingChangeIds"], json!([]));

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn auth_state_persists_refresh_tokens_across_store_restarts() {
        let auth_path = unique_test_ledger_path("auth_state_persistence");
        let password_hash = hash_password_for_test("correct horse");
        let router = app_with_state(AppState::dev().with_auth(
            AuthStore::configured_with_state_path(
                "wu",
                password_hash.clone(),
                true,
                Some(auth_path.clone()),
            ),
        ));

        let (login_status, login_body) = request_json_body_from(
            router,
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
        let access_token = login_body["data"]["accessToken"]
            .as_str()
            .expect("access token should be string")
            .to_string();
        let refresh_token = login_body["data"]["refreshToken"]
            .as_str()
            .expect("refresh token should be string")
            .to_string();

        let raw_auth_state = fs::read_to_string(&auth_path).expect("auth state should persist");
        assert!(raw_auth_state.contains("refreshTokenHash"));
        assert!(raw_auth_state.contains("accessTokenHash"));
        assert!(!raw_auth_state.contains(&access_token));
        assert!(!raw_auth_state.contains(&refresh_token));

        let restarted_router = app_with_state(AppState::dev().with_auth(
            AuthStore::configured_with_state_path(
                "wu",
                password_hash.clone(),
                true,
                Some(auth_path.clone()),
            ),
        ));
        let (refresh_status, refresh_body) = request_json_body_from(
            restarted_router,
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

        let logout_router = app_with_state(AppState::dev().with_auth(
            AuthStore::configured_with_state_path(
                "wu",
                password_hash.clone(),
                true,
                Some(auth_path.clone()),
            ),
        ));
        let (logout_status, _) = request_json_body_from(
            logout_router,
            Method::POST,
            "/v1/auth/logout",
            json!({ "refreshToken": rotated_refresh_token.clone() }),
        )
        .await;
        assert_eq!(logout_status, StatusCode::NO_CONTENT);

        let revoked_router = app_with_state(AppState::dev().with_auth(
            AuthStore::configured_with_state_path(
                "wu",
                password_hash,
                true,
                Some(auth_path.clone()),
            ),
        ));
        let (revoked_status, revoked_body) = request_json_body_from(
            revoked_router,
            Method::POST,
            "/v1/auth/refresh",
            json!({ "refreshToken": rotated_refresh_token }),
        )
        .await;
        assert_eq!(revoked_status, StatusCode::UNAUTHORIZED);
        assert_eq!(revoked_body["error"]["code"], "invalid_credentials");

        let _ = std::fs::remove_file(auth_path);
    }

    #[test]
    fn auth_login_fails_closed_when_device_state_cannot_be_persisted() {
        let parent_file = unique_test_ledger_path("auth_unwritable_parent");
        std::fs::create_dir_all(
            parent_file
                .parent()
                .expect("test parent file should have a parent"),
        )
        .expect("test directory should be created");
        std::fs::write(&parent_file, "not a directory")
            .expect("test parent file should be created");
        let state_path = parent_file.join("ledger.auth.json");
        let auth = AuthStore::configured_with_state_path(
            "wu",
            hash_password_for_test("correct horse"),
            true,
            Some(state_path),
        );

        let result = auth.login(
            json!({
                "username": "wu",
                "password": "correct horse",
                "deviceName": "Windows"
            }),
            "2026-07-14T00:00:00Z",
        );
        assert!(matches!(result, Err(AuthError::Storage)));
        assert!(
            auth.inner
                .lock()
                .expect("auth state should lock")
                .devices
                .is_empty(),
            "failed persistence must not leave a live in-memory session"
        );

        let _ = std::fs::remove_file(parent_file);
    }

    #[test]
    fn corrupt_auth_state_refuses_store_startup() {
        let auth_path = unique_test_ledger_path("auth_corrupt_startup");
        std::fs::create_dir_all(
            auth_path
                .parent()
                .expect("test auth path should have a parent"),
        )
        .expect("test directory should be created");
        std::fs::write(&auth_path, "{not-json").expect("corrupt auth test state should be written");

        let result = std::panic::catch_unwind(|| {
            AuthStore::configured_with_state_path(
                "wu",
                hash_password_for_test("correct horse"),
                true,
                Some(auth_path.clone()),
            )
        });
        assert!(result.is_err(), "corrupt auth state must fail closed");

        let _ = std::fs::remove_file(auth_path);
    }

    #[tokio::test]
    async fn auth_refresh_rejects_expired_refresh_tokens() {
        let auth_path = unique_test_ledger_path("auth_expired_refresh");
        std::fs::create_dir_all(
            auth_path
                .parent()
                .expect("test auth path should have a parent directory"),
        )
        .expect("test auth directory should be created");
        let refresh_token = "fw_refresh_expired_for_test";
        let access_token = "fw_access_for_expired_refresh_test";
        let future_access_expires_at = (OffsetDateTime::now_utc() + Duration::hours(1))
            .format(&Rfc3339)
            .expect("RFC3339 formatting should succeed");
        let expired_refresh_expires_at = (OffsetDateTime::now_utc() - Duration::days(1))
            .format(&Rfc3339)
            .expect("RFC3339 formatting should succeed");
        let auth_state = json!({
            "version": 1,
            "devices": [{
                "id": "dev_auth_device_expired",
                "name": "Windows",
                "refreshTokenHash": token_hash(refresh_token),
                "accessTokenHash": token_hash(access_token),
                "accessExpiresAt": future_access_expires_at,
                "refreshExpiresAt": expired_refresh_expires_at,
                "createdAt": "2026-06-01T00:00:00Z",
                "lastSeenAt": "2026-06-01T00:00:00Z"
            }]
        });
        std::fs::write(
            &auth_path,
            serde_json::to_string_pretty(&auth_state).expect("auth state JSON should encode"),
        )
        .expect("test auth state should be written");

        let router = app_with_state(AppState::dev().with_auth(
            AuthStore::configured_with_state_path(
                "wu",
                hash_password_for_test("correct horse"),
                true,
                Some(auth_path.clone()),
            ),
        ));
        let (refresh_status, refresh_body) = request_json_body_from(
            router,
            Method::POST,
            "/v1/auth/refresh",
            json!({ "refreshToken": refresh_token }),
        )
        .await;
        assert_eq!(refresh_status, StatusCode::UNAUTHORIZED);
        assert_eq!(refresh_body["error"]["code"], "invalid_credentials");

        let persisted = fs::read_to_string(&auth_path).expect("auth state should persist");
        let persisted: Value =
            serde_json::from_str(&persisted).expect("persisted auth state should parse");
        assert_eq!(persisted["devices"], json!([]));

        let _ = std::fs::remove_file(auth_path);
    }

    #[tokio::test]
    async fn empty_local_ledger_sync_genesis_cursor_round_trips() {
        let path = unique_test_ledger_path("sync_genesis_cursor");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (bootstrap_status, bootstrap_body) =
            request_json_from(router.clone(), Method::GET, "/v1/ledger/bootstrap").await;
        assert_eq!(bootstrap_status, StatusCode::OK);
        assert_eq!(
            bootstrap_body["data"]["syncCursor"],
            local_ledger::LOCAL_SYNC_GENESIS_CURSOR
        );

        let (changes_status, changes_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/sync/changes?since=local_cursor_0000",
        )
        .await;
        assert_eq!(changes_status, StatusCode::OK);
        assert_eq!(
            changes_body["data"]["cursor"],
            local_ledger::LOCAL_SYNC_GENESIS_CURSOR
        );
        assert_eq!(changes_body["data"]["changes"], json!([]));

        let (ack_status, ack_body) = request_json_body_from(
            router,
            Method::POST,
            "/v1/sync/ack",
            json!({"cursor": local_ledger::LOCAL_SYNC_GENESIS_CURSOR}),
        )
        .await;
        assert_eq!(ack_status, StatusCode::NO_CONTENT);
        assert_eq!(ack_body, Value::Null);

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn sync_ack_cursor_preserves_later_pending_changes() {
        let path = unique_test_ledger_path("sync_ack_high_water");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        for display_name in ["同步账户一", "同步账户二"] {
            let (status, _) = request_json_body_from(
                router.clone(),
                Method::POST,
                "/v1/accounts",
                json!({
                    "displayName": display_name,
                    "accountType": "bank",
                    "defaultCurrency": "CNY",
                    "supportedCurrencies": ["CNY"],
                    "includeInNetWorth": true,
                    "balanceMode": "cash_balance",
                    "openingBalances": []
                }),
            )
            .await;
            assert_eq!(status, StatusCode::CREATED);
        }

        let (ack_status, _) = request_json_body_from(
            router,
            Method::POST,
            "/v1/sync/ack",
            json!({"cursor": "local_change_000001"}),
        )
        .await;
        assert_eq!(ack_status, StatusCode::NO_CONTENT);

        let document = local_ledger::read_document(&path).expect("ledger should persist ack");
        assert_eq!(
            document["syncState"]["pendingChangeIds"],
            json!(["local_change_000002"])
        );
        assert_eq!(
            document["syncChanges"]
                .as_array()
                .expect("sync log should remain immutable")
                .len(),
            2
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn sync_push_rejects_invalid_account_create_batches_atomically() {
        let path = unique_test_ledger_path("sync_invalid_account_create");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let valid_change = sync_account_create_change(
            DEV_UNAUTHENTICATED_DEVICE_ID,
            "remote_valid_before_invalid",
            "acct_valid_before_invalid",
        );
        let mut unsupported_change = sync_account_create_change(
            DEV_UNAUTHENTICATED_DEVICE_ID,
            "remote_unsupported_update",
            "acct_unsupported_update",
        );
        unsupported_change["operation"] = json!("update");
        let (batch_status, batch_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/sync/push",
            json!({
                "deviceId": DEV_UNAUTHENTICATED_DEVICE_ID,
                "changes": [valid_change, unsupported_change]
            }),
        )
        .await;
        assert_eq!(batch_status, StatusCode::BAD_REQUEST, "{batch_body}");
        let unchanged = local_ledger::read_document(&path).expect("invalid batch must not mutate");
        assert_eq!(unchanged["accounts"], json!([]));
        assert_eq!(unchanged["syncChanges"], json!([]));

        let mut invalid_changes = Vec::new();
        let mut mismatched_payload = sync_account_create_change(
            DEV_UNAUTHENTICATED_DEVICE_ID,
            "remote_payload_mismatch",
            "acct_payload_mismatch",
        );
        mismatched_payload["payload"]["id"] = json!("acct_other");
        invalid_changes.push(mismatched_payload);

        let mut unsupported_entity = sync_account_create_change(
            DEV_UNAUTHENTICATED_DEVICE_ID,
            "remote_unsupported_entity",
            "acct_unsupported_entity",
        );
        unsupported_entity["entityType"] = json!("movement");
        invalid_changes.push(unsupported_entity);

        let mut invalid_base_version = sync_account_create_change(
            DEV_UNAUTHENTICATED_DEVICE_ID,
            "remote_invalid_base_version",
            "acct_invalid_base_version",
        );
        invalid_base_version["baseVersion"] = json!(1);
        invalid_changes.push(invalid_base_version);

        let mut incomplete_payload = sync_account_create_change(
            DEV_UNAUTHENTICATED_DEVICE_ID,
            "remote_incomplete_payload",
            "acct_incomplete_payload",
        );
        incomplete_payload["payload"]
            .as_object_mut()
            .expect("payload object")
            .remove("tags");
        invalid_changes.push(incomplete_payload);

        for invalid_change in invalid_changes {
            let (status, body) = request_json_body_from(
                router.clone(),
                Method::POST,
                "/v1/sync/push",
                json!({
                    "deviceId": DEV_UNAUTHENTICATED_DEVICE_ID,
                    "changes": [invalid_change]
                }),
            )
            .await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
            assert_eq!(body["error"]["code"], "invalid_sync_push");
        }
        let final_document =
            local_ledger::read_document(&path).expect("invalid pushes must remain atomic");
        assert_eq!(final_document["accounts"], json!([]));
        assert_eq!(final_document["syncChanges"], json!([]));

        let _ = std::fs::remove_file(path);
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

        let (bootstrap_status, bootstrap_body) =
            request_json_from(router.clone(), Method::GET, "/v1/ledger/bootstrap").await;
        assert_eq!(bootstrap_status, StatusCode::OK);
        assert_eq!(bootstrap_body["data"]["ledgerVersion"], 1);
        assert_eq!(bootstrap_body["data"]["syncCursor"], "local_change_000001");
        assert_eq!(
            bootstrap_body["data"]["accounts"][0]["displayName"],
            "同步账户"
        );
        assert_eq!(
            bootstrap_body["data"]["snapshot"]["netWorth"]["amount"],
            "88.00"
        );
        assert_eq!(
            bootstrap_body["data"]["capabilities"]["dataSourceMode"],
            "real_local"
        );
        assert_eq!(
            bootstrap_body["data"]["capabilities"]["canWriteConfirmedLedger"],
            true
        );
        assert_eq!(
            bootstrap_body["data"]["capabilities"]["proposalPersistence"],
            "file"
        );
        assert_eq!(
            bootstrap_body["data"]["capabilities"]["canUseOutboundQuoteProvider"],
            false
        );

        let (sync_status, sync_body) =
            request_json_from(router.clone(), Method::GET, "/v1/sync/changes").await;
        assert_eq!(sync_status, StatusCode::OK);
        assert_eq!(sync_body["data"]["cursor"], "local_change_000001");
        assert_eq!(sync_body["data"]["changes"][0]["id"], "local_change_000001");
        assert_eq!(sync_body["data"]["changes"][0]["entityType"], "account");
        assert_eq!(sync_body["data"]["changes"][0]["operation"], "create");
        assert_eq!(
            sync_body["data"]["changes"][0]["payload"]["displayName"],
            "同步账户"
        );

        let (since_status, since_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/sync/changes?since=local_change_000001",
        )
        .await;
        assert_eq!(since_status, StatusCode::OK);
        assert_eq!(since_body["data"]["changes"], json!([]));

        let (unknown_since_status, unknown_since_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/sync/changes?since=local_change_missing",
        )
        .await;
        assert_eq!(unknown_since_status, StatusCode::BAD_REQUEST);
        assert_eq!(unknown_since_body["error"]["code"], "invalid_sync_cursor");

        let (ack_status, ack_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/sync/ack",
            json!({"cursor": "local_change_000001"}),
        )
        .await;
        assert_eq!(ack_status, StatusCode::NO_CONTENT);
        assert_eq!(ack_body, Value::Null);
        let acked_document = local_ledger::read_document(&path).expect("ledger should persist ack");
        assert_eq!(acked_document["syncState"]["pendingChangeIds"], json!([]));
        assert_eq!(
            acked_document["syncChanges"]
                .as_array()
                .expect("syncChanges should stay as immutable log")
                .len(),
            1
        );

        let (ack_retry_status, ack_retry_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/sync/ack",
            json!({"changeIds": ["local_change_000001"]}),
        )
        .await;
        assert_eq!(ack_retry_status, StatusCode::NO_CONTENT);
        assert_eq!(ack_retry_body, Value::Null);

        let (ack_invalid_status, ack_invalid_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/sync/ack",
            json!({"cursor": "local_change_missing"}),
        )
        .await;
        assert_eq!(ack_invalid_status, StatusCode::BAD_REQUEST);
        assert_eq!(ack_invalid_body["error"]["code"], "invalid_sync_ack");

        let remote_push = json!({
            "deviceId": DEV_UNAUTHENTICATED_DEVICE_ID,
            "changes": [
                {
                    "id": "remote_change_000001",
                    "deviceId": DEV_UNAUTHENTICATED_DEVICE_ID,
                    "entityType": "account",
                    "entityId": "acct_remote",
                    "operation": "create",
                    "baseVersion": 0,
                    "payload": {
                        "id": "acct_remote",
                        "displayName": "远端账户",
                        "accountType": "bank",
                        "defaultCurrency": "CNY",
                        "supportedCurrencies": ["CNY"],
                        "includeInNetWorth": true,
                        "visibility": "normal",
                        "status": "active",
                        "balanceMode": "cash_balance",
                        "cashBalances": [],
                        "tags": [],
                        "createdAt": "2026-06-28T00:00:00Z",
                        "updatedAt": "2026-06-28T00:00:00Z"
                    },
                    "createdAt": "2026-06-28T00:00:00Z"
                }
            ]
        });
        let (remote_push_status, remote_push_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/sync/push",
            remote_push.clone(),
        )
        .await;
        assert_eq!(remote_push_status, StatusCode::OK);
        assert_eq!(
            remote_push_body["data"]["acceptedChangeIds"],
            json!(["remote_change_000001"])
        );
        assert_eq!(
            remote_push_body["data"]["appliedChangeIds"],
            json!(["remote_change_000001"])
        );
        assert_eq!(remote_push_body["data"]["skippedChangeIds"], json!([]));
        assert_eq!(remote_push_body["data"]["cursor"], "local_change_000002");

        let pushed_document =
            local_ledger::read_document(&path).expect("ledger should persist remote sync push");
        assert_eq!(
            pushed_document["accounts"]
                .as_array()
                .expect("remote sync push must apply account payload")
                .len(),
            2
        );
        assert_eq!(pushed_document["accounts"][1]["id"], "acct_remote");
        assert_eq!(pushed_document["syncState"]["pendingChangeIds"], json!([]));
        assert_eq!(
            pushed_document["syncChanges"][1]["sourceChangeId"],
            "remote_change_000001"
        );
        assert_eq!(
            pushed_document["syncChanges"][1]["deviceId"],
            DEV_UNAUTHENTICATED_DEVICE_ID
        );
        assert_eq!(
            pushed_document["syncChanges"][1]["payload"]["displayName"],
            "远端账户"
        );

        let (remote_retry_status, remote_retry_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/sync/push", remote_push)
                .await;
        assert_eq!(remote_retry_status, StatusCode::OK);
        assert_eq!(remote_retry_body["data"]["acceptedChangeIds"], json!([]));
        assert_eq!(remote_retry_body["data"]["appliedChangeIds"], json!([]));
        assert_eq!(
            remote_retry_body["data"]["skippedChangeIds"],
            json!(["remote_change_000001"])
        );
        let retried_document =
            local_ledger::read_document(&path).expect("ledger should keep idempotent push stable");
        assert_eq!(
            retried_document["syncChanges"]
                .as_array()
                .expect("duplicate push should not append")
                .len(),
            2
        );
        assert_eq!(
            retried_document["accounts"]
                .as_array()
                .expect("duplicate push should not duplicate accounts")
                .len(),
            2
        );
        assert_eq!(
            retried_document["syncState"]["cursor"],
            "local_change_000002"
        );

        let (conflict_status, conflict_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/sync/push",
            json!({
                "deviceId": DEV_UNAUTHENTICATED_DEVICE_ID,
                "changes": [{
                    "id": "remote_change_000002",
                    "deviceId": DEV_UNAUTHENTICATED_DEVICE_ID,
                    "entityType": "account",
                    "entityId": "acct_remote",
                    "operation": "create",
                    "baseVersion": 0,
                    "payload": {
                        "id": "acct_remote",
                        "displayName": "冲突账户",
                        "accountType": "bank",
                        "defaultCurrency": "CNY",
                        "supportedCurrencies": ["CNY"],
                        "includeInNetWorth": true,
                        "visibility": "normal",
                        "status": "active",
                        "balanceMode": "cash_balance",
                        "cashBalances": [],
                        "tags": [],
                        "createdAt": "2026-06-28T00:00:00Z",
                        "updatedAt": "2026-06-28T00:00:00Z"
                    },
                    "createdAt": "2026-06-28T00:00:00Z"
                }]
            }),
        )
        .await;
        assert_eq!(conflict_status, StatusCode::OK, "{conflict_body}");
        assert_eq!(conflict_body["data"]["acceptedChangeIds"], json!([]));
        assert_eq!(conflict_body["data"]["appliedChangeIds"], json!([]));
        assert_eq!(
            conflict_body["data"]["conflicts"][0]["kind"],
            "entity_already_exists"
        );
        assert_eq!(
            conflict_body["data"]["conflicts"][0]["entityId"],
            "acct_remote"
        );
        let conflicted_document =
            local_ledger::read_document(&path).expect("conflict must keep ledger valid");
        assert_eq!(
            conflicted_document["syncState"]["cursor"],
            "local_change_000002"
        );
        assert_eq!(
            conflicted_document["syncChanges"]
                .as_array()
                .expect("conflict must not append a remote log entry")
                .len(),
            2
        );

        for invalid_push in [
            json!({
                "deviceId": DEV_UNAUTHENTICATED_DEVICE_ID,
                "changes": [{
                    "id": "remote_bad_time",
                    "deviceId": DEV_UNAUTHENTICATED_DEVICE_ID,
                    "entityType": "account",
                    "entityId": "acct_bad_time",
                    "operation": "create",
                    "baseVersion": 0,
                    "payload": {},
                    "createdAt": "not-a-time"
                }]
            }),
            json!({
                "deviceId": "local_device",
                "changes": [{
                    "id": "remote_reserved_device",
                    "deviceId": "local_device",
                    "entityType": "account",
                    "entityId": "acct_reserved",
                    "operation": "create",
                    "payload": {},
                    "createdAt": "2026-06-28T00:00:00Z"
                }]
            }),
        ] {
            let (invalid_status, invalid_body) =
                request_json_body_from(router.clone(), Method::POST, "/v1/sync/push", invalid_push)
                    .await;
            assert_eq!(invalid_status, StatusCode::BAD_REQUEST);
            assert_eq!(invalid_body["error"]["code"], "invalid_sync_push");
        }

        let (push_status, push_body) = request_json_body_from(
            router,
            Method::POST,
            "/v1/sync/push",
            json!({
                "deviceId": DEV_UNAUTHENTICATED_DEVICE_ID,
                "changes": [
                    {
                        "id": "change_demo",
                        "deviceId": DEV_UNAUTHENTICATED_DEVICE_ID,
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
    async fn local_ledger_rejects_scenario_query_to_prevent_demo_real_mixing() {
        let path = unique_test_ledger_path("reject_scenario");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router =
            app_with_state(AppState::local(path.clone()).with_allow_ledger_scenario(false));

        let (read_status, read_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/accounts?scenario=degraded",
        )
        .await;
        assert_eq!(read_status, StatusCode::BAD_REQUEST);
        assert_eq!(read_body["error"]["code"], "ledger_scenario_forbidden");

        let (write_status, write_body) = request_json_body_from(
            router,
            Method::POST,
            "/v1/accounts?scenario=degraded",
            json!({
                "displayName": "不应写入",
                "accountType": "bank",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance"
            }),
        )
        .await;
        assert_eq!(write_status, StatusCode::BAD_REQUEST);
        assert_eq!(write_body["error"]["code"], "ledger_scenario_forbidden");

        let document = local_ledger::read_document(&path).expect("ledger should stay readable");
        assert_eq!(document["accounts"], json!([]));

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_rejects_non_loopback_host_header() {
        let path = unique_test_ledger_path("reject_host_header");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let response = router
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri("/v1/accounts")
                    .header("host", "evil.example")
                    .body(Body::empty())
                    .expect("request should build"),
            )
            .await
            .expect("router should respond");
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 1024 * 1024)
            .await
            .expect("response body should read");
        let body: Value = serde_json::from_slice(&bytes).expect("response body should be JSON");

        assert_eq!(status, StatusCode::FORBIDDEN);
        assert_eq!(body["error"]["code"], "host_header_forbidden");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn account_create_requires_idempotency_key() {
        let path = unique_test_ledger_path("account_idempotency_required");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (status, _, body) = request_json_body_with_idempotency_from(
            router,
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "缺少幂等键",
                "accountType": "bank",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": []
            }),
            None,
        )
        .await;

        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"]["code"], "invalid_idempotency_key");
        assert_eq!(
            local_ledger::read_document(&path).expect("ledger should remain readable")["accounts"],
            json!([])
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn every_local_ledger_write_route_requires_idempotency_key() {
        let path = unique_test_ledger_path("all_idempotency_required");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));
        let routes = [
            (Method::POST, "/v1/accounts"),
            (Method::PATCH, "/v1/accounts/missing"),
            (Method::POST, "/v1/accounts/missing/archive"),
            (Method::POST, "/v1/movements/drafts"),
            (Method::POST, "/v1/movements/missing/submit-review"),
            (Method::POST, "/v1/movements/corrections"),
            (Method::POST, "/v1/atomic-groups/missing/confirm"),
            (Method::POST, "/v1/atomic-groups/missing/reject"),
            (Method::POST, "/v1/dca/plans"),
            (Method::PATCH, "/v1/dca/plans/missing"),
            (
                Method::POST,
                "/v1/dca/reminders/missing/mark-executed-as-proposal",
            ),
            (Method::POST, "/v1/dca/reminders/missing/skip"),
            (Method::POST, "/v1/dca/reminders/missing/snooze"),
            (Method::POST, "/v1/subscriptions"),
            (Method::POST, "/v1/subscriptions/charge-proposals/due-scan"),
            (Method::PATCH, "/v1/subscriptions/missing"),
            (Method::POST, "/v1/subscriptions/missing/cancel"),
            (Method::POST, "/v1/subscriptions/missing/charge-proposal"),
            (Method::POST, "/v1/ai/proposals/from-text"),
            (Method::POST, "/v1/ai/proposals/from-image"),
            (Method::POST, "/v1/ai/proposals/from-csv"),
            (Method::POST, "/v1/ai/atomic-groups/missing/approve"),
            (Method::POST, "/v1/ai/atomic-groups/missing/reject"),
            (Method::POST, "/v1/ai/atomic-groups/missing/edit"),
            (Method::POST, "/v1/quotes/refresh"),
            (Method::POST, "/v1/instruments"),
            (Method::PATCH, "/v1/instruments/missing"),
            (Method::POST, "/v1/snapshots/manual"),
            (Method::POST, "/v1/snapshots/invalidate"),
            (Method::POST, "/v1/categories"),
            (Method::PATCH, "/v1/categories/missing"),
            (Method::POST, "/v1/counterparties"),
            (Method::PATCH, "/v1/counterparties/missing"),
            (Method::POST, "/v1/counterparties/merge-proposal"),
            (Method::POST, "/v1/sync/push"),
            (Method::POST, "/v1/sync/ack"),
        ];

        for (method, uri) in routes {
            let (status, _, body) = request_json_body_with_idempotency_from(
                router.clone(),
                method.clone(),
                uri,
                json!({}),
                None,
            )
            .await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{method} {uri}: {body}");
            assert_eq!(
                body["error"]["code"], "invalid_idempotency_key",
                "{method} {uri}: {body}"
            );
        }

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn account_create_idempotency_replays_across_restart_and_rejects_reuse() {
        let path = unique_test_ledger_path("account_idempotency_replay");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let idempotency_key = "account-create-retry-key";
        let input = json!({
            "displayName": "幂等账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [{"currency": "CNY", "amount": "10.00"}]
        });

        let first_router = app_with_state(AppState::local(path.clone()));
        let (first_status, first_headers, first_body) = request_json_body_with_idempotency_from(
            first_router,
            Method::POST,
            "/v1/accounts",
            input.clone(),
            Some(idempotency_key),
        )
        .await;
        assert_eq!(first_status, StatusCode::CREATED);
        assert!(first_headers.get("idempotency-replayed").is_none());

        let restarted_router = app_with_state(AppState::local(path.clone()));
        let (replay_status, replay_headers, replay_body) = request_json_body_with_idempotency_from(
            restarted_router.clone(),
            Method::POST,
            "/v1/accounts",
            input,
            Some(idempotency_key),
        )
        .await;
        assert_eq!(replay_status, StatusCode::CREATED);
        assert_eq!(replay_body, first_body);
        assert_eq!(
            replay_headers
                .get("idempotency-replayed")
                .and_then(|value| value.to_str().ok()),
            Some("true")
        );

        let (reuse_status, _, reuse_body) = request_json_body_with_idempotency_from(
            restarted_router,
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "不同请求",
                "accountType": "bank",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": []
            }),
            Some(idempotency_key),
        )
        .await;
        assert_eq!(reuse_status, StatusCode::CONFLICT);
        assert_eq!(reuse_body["error"]["code"], "idempotency_key_reused");

        let document = local_ledger::read_document(&path).expect("ledger should remain readable");
        assert_eq!(
            document["accounts"]
                .as_array()
                .expect("accounts should be an array")
                .len(),
            1
        );
        assert_eq!(
            document["idempotencyState"]["records"]
                .as_object()
                .expect("idempotency records should be an object")
                .len(),
            1
        );
        let raw = fs::read_to_string(&path).expect("ledger should be readable as text");
        assert!(!raw.contains(idempotency_key));

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

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn local_ledger_serializes_concurrent_account_creates() {
        let path = unique_test_ledger_path("concurrent_accounts");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let mut handles = Vec::new();
        for index in 0..20 {
            let router = router.clone();
            handles.push(tokio::spawn(async move {
                request_json_body_from(
                    router,
                    Method::POST,
                    "/v1/accounts",
                    json!({
                        "displayName": format!("并发账户 {index}"),
                        "accountType": "bank",
                        "defaultCurrency": "CNY",
                        "supportedCurrencies": ["CNY"],
                        "includeInNetWorth": true,
                        "balanceMode": "cash_balance",
                        "openingBalances": [
                            {
                                "currency": "CNY",
                                "amount": index.to_string()
                            }
                        ]
                    }),
                )
                .await
            }));
        }

        for handle in handles {
            let (status, body) = handle.await.expect("request task should join");
            assert_eq!(status, StatusCode::CREATED, "body={body}");
        }

        let document = local_ledger::read_document(&path).expect("ledger should be readable");
        let accounts = document["accounts"]
            .as_array()
            .expect("validated accounts should be an array");
        assert_eq!(accounts.len(), 20);
        let sync_changes = document["syncChanges"]
            .as_array()
            .expect("validated syncChanges should be an array");
        assert_eq!(sync_changes.len(), 20);
        assert_eq!(document["syncState"]["cursor"], "local_change_000020");

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
        let sync_changes = persisted["syncChanges"]
            .as_array()
            .expect("validated syncChanges should be an array");
        assert_eq!(sync_changes.len(), 3);
        assert_eq!(sync_changes[0]["operation"], "create");
        assert_eq!(sync_changes[1]["operation"], "update");
        assert_eq!(sync_changes[1]["payload"]["displayName"], "建行工资卡");
        assert_eq!(sync_changes[2]["operation"], "update");
        assert_eq!(sync_changes[2]["payload"]["status"], "archived");
        assert_eq!(persisted["syncState"]["cursor"], "local_change_000003");

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
    async fn local_ledger_positive_credit_card_balance_is_an_asset_not_debt() {
        let path = unique_test_ledger_path("positive_credit_card_balance");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let credit_balance_input = json!({
            "displayName": "信用卡溢缴款",
            "accountType": "credit_card",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "liability",
            "openingBalances": [
                {"currency": "CNY", "amount": "5.00"}
            ]
        });
        let (account_status, _) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            credit_balance_input,
        )
        .await;
        assert_eq!(account_status, StatusCode::CREATED);

        let (overview_status, overview_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_status, StatusCode::OK);
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["grossAssets"]["amount"],
            "5.00"
        );
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["totalLiabilities"]["amount"],
            "0.00"
        );
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["netWorth"]["amount"],
            "5.00"
        );
        assert_eq!(
            overview_body["data"]["pendingSummary"]["accountAnomalyCount"],
            0
        );

        let (allocation_status, allocation_body) =
            request_json_from(router, Method::GET, "/v1/portfolio/allocation").await;
        assert_eq!(allocation_status, StatusCode::OK);
        assert_eq!(allocation_body["data"]["totalAssets"]["amount"], "5.00");
        assert_eq!(
            allocation_body["data"]["totalLiabilities"]["amount"],
            "0.00"
        );
        assert_eq!(allocation_body["data"]["netWorth"]["amount"], "5.00");
        assert_eq!(allocation_body["data"]["slices"][0]["category"], "其他");
        assert_eq!(allocation_body["data"]["slices"][0]["percent"], "100.0");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_account_anomalies_use_real_ledger_data() {
        let path = unique_test_ledger_path("account_anomalies");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let asset_input = json!({
            "displayName": "透支钱包",
            "accountType": "wallet",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "-12.34"}
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
                {"currency": "CNY", "amount": "-1000.00"}
            ]
        });
        let (asset_status, asset_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", asset_input).await;
        assert_eq!(asset_status, StatusCode::CREATED);
        let asset_account_id = asset_body["data"]["id"]
            .as_str()
            .expect("asset account id should be string")
            .to_string();
        let (liability_status, _) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            liability_input,
        )
        .await;
        assert_eq!(liability_status, StatusCode::CREATED);

        let (anomaly_status, anomaly_body) =
            request_json_from(router.clone(), Method::GET, "/v1/accounts/anomalies").await;
        assert_eq!(anomaly_status, StatusCode::OK);
        let anomalies = anomaly_body["data"]
            .as_array()
            .expect("anomalies should be an array");
        assert_eq!(anomalies.len(), 1);
        assert_eq!(anomalies[0]["accountId"], asset_account_id);
        assert_eq!(anomalies[0]["kind"], "negative_balance");
        assert_eq!(anomalies[0]["severity"], "critical");

        let (overview_status, overview_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_status, StatusCode::OK);
        assert_eq!(
            overview_body["data"]["pendingSummary"]["accountAnomalyCount"],
            1
        );

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
        let sync_changes = persisted["syncChanges"]
            .as_array()
            .expect("syncChanges should be an array");
        let movement_changes = sync_changes
            .iter()
            .filter(|change| change["entityType"] == "movement")
            .collect::<Vec<_>>();
        assert_eq!(movement_changes.len(), 1);
        assert_eq!(movement_changes[0]["operation"], "create");
        assert_eq!(movement_changes[0]["entityId"], movement_id);
        assert_eq!(movement_changes[0]["payload"]["status"], "confirmed");
        assert_eq!(movement_changes[0]["payload"]["title"], "瑞幸咖啡");

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
    async fn local_ledger_holding_adjustment_proposal_imports_a_current_position() {
        let path = unique_test_ledger_path("holding_adjustment_import");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (account_status, account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "OKX",
                "accountType": "exchange",
                "defaultCurrency": "USDT",
                "supportedCurrencies": ["USDT"],
                "includeInNetWorth": true,
                "balanceMode": "holdings",
                "openingBalances": []
            }),
        )
        .await;
        assert_eq!(account_status, StatusCode::CREATED, "{account_body}");
        let account_id = account_body["data"]["id"].as_str().expect("account id");

        let (instrument_status, instrument_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/instruments",
            json!({
                "id": "inst_btc_usdt",
                "type": "crypto",
                "symbol": "BTC-USDT",
                "displayName": "Bitcoin",
                "quoteCurrency": "USDT",
                "market": "CRYPTO"
            }),
        )
        .await;
        assert_eq!(instrument_status, StatusCode::CREATED, "{instrument_body}");

        let endpoint = format!("/v1/accounts/{account_id}/holding-adjustment-proposals");
        let (proposal_status, proposal_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &endpoint,
            json!({
                "instrumentId": "inst_btc_usdt",
                "targetQuantity": "0.00076078",
                "asOf": "2026-07-18T03:30:00Z",
                "note": "Imported from exchange balance"
            }),
        )
        .await;
        assert_eq!(proposal_status, StatusCode::OK, "{proposal_body}");
        let atomic_group_id = proposal_body["data"]["id"]
            .as_str()
            .expect("atomic group id");

        let (_, holdings_before) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(holdings_before["data"], json!([]));

        let (duplicate_status, duplicate_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &endpoint,
            json!({
                "instrumentId": "inst_btc_usdt",
                "targetQuantity": "0.001"
            }),
        )
        .await;
        assert_eq!(duplicate_status, StatusCode::CONFLICT, "{duplicate_body}");

        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{atomic_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK, "{confirm_body}");
        assert_eq!(confirm_body["data"]["ledgerWrite"], true);

        let (_, holdings_after) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(holdings_after["data"][0]["accountId"], account_id);
        assert_eq!(holdings_after["data"][0]["instrumentId"], "inst_btc_usdt");
        assert_eq!(holdings_after["data"][0]["quantity"], "0.00076078");
        assert_eq!(holdings_after["data"][0]["quoteStatus"], "unpriceable");
        assert_eq!(holdings_after["data"][0]["asOf"], "2026-07-18T03:30:00Z");
        assert!(holdings_after["data"][0].get("costBasisTotal").is_none());

        let (same_status, same_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &endpoint,
            json!({
                "instrumentId": "inst_btc_usdt",
                "targetQuantity": "0.00076078"
            }),
        )
        .await;
        assert_eq!(same_status, StatusCode::CONFLICT, "{same_body}");

        let reduction_key = "holding-adjustment-reduction-retry";
        let reduction_input = json!({
            "instrumentId": "inst_btc_usdt",
            "targetQuantity": "0.0005"
        });
        let (reduction_status, reduction_headers, reduction_body) =
            request_json_body_with_idempotency_from(
                router.clone(),
                Method::POST,
                &endpoint,
                reduction_input.clone(),
                Some(reduction_key),
            )
            .await;
        assert_eq!(reduction_status, StatusCode::OK, "{reduction_body}");
        assert!(reduction_headers.get("idempotency-replayed").is_none());
        let reduction_group_id = reduction_body["data"]["id"]
            .as_str()
            .expect("reduction group id");
        let (replay_status, replay_headers, replay_body) = request_json_body_with_idempotency_from(
            router.clone(),
            Method::POST,
            &endpoint,
            reduction_input,
            Some(reduction_key),
        )
        .await;
        assert_eq!(replay_status, StatusCode::OK, "{replay_body}");
        assert_eq!(replay_body, reduction_body);
        assert_eq!(
            replay_headers
                .get("idempotency-replayed")
                .and_then(|value| value.to_str().ok()),
            Some("true")
        );
        let (confirm_reduction_status, confirm_reduction_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{reduction_group_id}/confirm"),
        )
        .await;
        assert_eq!(
            confirm_reduction_status,
            StatusCode::OK,
            "{confirm_reduction_body}"
        );
        let (_, reduced_holdings) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(reduced_holdings["data"][0]["quantity"], "0.0005");

        let (zero_status, zero_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &endpoint,
            json!({
                "instrumentId": "inst_btc_usdt",
                "targetQuantity": "0"
            }),
        )
        .await;
        assert_eq!(zero_status, StatusCode::OK, "{zero_body}");
        let zero_group_id = zero_body["data"]["id"].as_str().expect("zero group id");
        let (confirm_zero_status, confirm_zero_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{zero_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_zero_status, StatusCode::OK, "{confirm_zero_body}");
        let (_, empty_holdings) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(empty_holdings["data"], json!([]));

        let (unsupported_instrument_status, unsupported_instrument_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/instruments",
            json!({
                "id": "inst_eth_usd",
                "type": "crypto",
                "symbol": "ETH-USD",
                "displayName": "Ethereum",
                "quoteCurrency": "USD",
                "market": "CRYPTO"
            }),
        )
        .await;
        assert_eq!(
            unsupported_instrument_status,
            StatusCode::CREATED,
            "{unsupported_instrument_body}"
        );
        let (unsupported_status, unsupported_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &endpoint,
            json!({
                "instrumentId": "inst_eth_usd",
                "targetQuantity": "1"
            }),
        )
        .await;
        assert_eq!(
            unsupported_status,
            StatusCode::BAD_REQUEST,
            "{unsupported_body}"
        );

        let (draft_status, draft_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            json!({
                "type": "adjustment",
                "occurredAt": "2026-07-18T03:30:00Z",
                "title": "Direct holding adjustment",
                "entries": [{
                    "accountId": account_id,
                    "instrumentId": "inst_btc_usdt",
                    "amount": "1",
                    "currency": "USDT",
                    "direction": "in",
                    "role": "adjustment"
                }]
            }),
        )
        .await;
        assert_eq!(draft_status, StatusCode::BAD_REQUEST, "{draft_body}");
        assert_eq!(draft_body["error"]["code"], "invalid_movement_draft_input");

        let (restore_status, restore_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &endpoint,
            json!({
                "instrumentId": "inst_btc_usdt",
                "targetQuantity": "1"
            }),
        )
        .await;
        assert_eq!(restore_status, StatusCode::OK, "{restore_body}");
        let restore_group_id = restore_body["data"]["id"]
            .as_str()
            .expect("restore group id");
        let (confirm_restore_status, confirm_restore_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{restore_group_id}/confirm"),
        )
        .await;
        assert_eq!(
            confirm_restore_status,
            StatusCode::OK,
            "{confirm_restore_body}"
        );

        let (conflict_proposal_status, conflict_proposal_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &endpoint,
            json!({
                "instrumentId": "inst_btc_usdt",
                "targetQuantity": "2"
            }),
        )
        .await;
        assert_eq!(
            conflict_proposal_status,
            StatusCode::OK,
            "{conflict_proposal_body}"
        );
        let conflict_group_id = conflict_proposal_body["data"]["id"]
            .as_str()
            .expect("conflict group id");
        let mut changed_document =
            local_ledger::read_document(&path).expect("ledger should remain readable");
        changed_document["holdings"][0]["quantity"] = json!("1.5");
        local_ledger::write_document(&path, &changed_document)
            .expect("concurrent holding change should remain a valid ledger");
        let (confirm_conflict_status, confirm_conflict_body) = request_json_from(
            router,
            Method::POST,
            &format!("/v1/atomic-groups/{conflict_group_id}/confirm"),
        )
        .await;
        assert_eq!(
            confirm_conflict_status,
            StatusCode::CONFLICT,
            "{confirm_conflict_body}"
        );
        let unchanged_document = local_ledger::read_document(&path)
            .expect("failed confirmation must not corrupt ledger");
        assert_eq!(unchanged_document["holdings"][0]["quantity"], "1.5");
        assert_eq!(
            unchanged_document["movements"]
                .as_array()
                .expect("movements")
                .iter()
                .find(|movement| {
                    movement.get("atomicGroupId").and_then(Value::as_str) == Some(conflict_group_id)
                })
                .and_then(|movement| movement.get("status"))
                .and_then(Value::as_str),
            Some("pending_review")
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_yield_terms_accrue_and_confirm_interest_without_touching_principal() {
        let path = unique_test_ledger_path("yield_interest_flow");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let mut account_ids = Vec::new();
        for (display_name, account_type, balance_mode, opening_balances) in [
            (
                "利息收款账户",
                "bank",
                "cash_balance",
                json!([{"currency": "CNY", "amount": "100.00"}]),
            ),
            ("定期存款账户", "brokerage", "holdings", json!([])),
        ] {
            let (status, body) = request_json_body_from(
                router.clone(),
                Method::POST,
                "/v1/accounts",
                json!({
                    "displayName": display_name,
                    "accountType": account_type,
                    "defaultCurrency": "CNY",
                    "supportedCurrencies": ["CNY"],
                    "includeInNetWorth": true,
                    "balanceMode": balance_mode,
                    "openingBalances": opening_balances
                }),
            )
            .await;
            assert_eq!(status, StatusCode::CREATED, "{body}");
            account_ids.push(body["data"]["id"].as_str().expect("account id").to_string());
        }
        let payout_account_id = &account_ids[0];
        let holding_account_id = &account_ids[1];

        let (instrument_status, instrument_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/instruments",
            json!({
                "id": "inst_fixed_deposit_cny",
                "type": "fund",
                "displayName": "一年期定期存款",
                "quoteCurrency": "CNY"
            }),
        )
        .await;
        assert_eq!(instrument_status, StatusCode::CREATED, "{instrument_body}");

        let adjustment_endpoint =
            format!("/v1/accounts/{holding_account_id}/holding-adjustment-proposals");
        let (proposal_status, proposal_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &adjustment_endpoint,
            json!({
                "instrumentId": "inst_fixed_deposit_cny",
                "targetQuantity": "10000",
                "asOf": "2026-01-01T00:00:00Z"
            }),
        )
        .await;
        assert_eq!(proposal_status, StatusCode::OK, "{proposal_body}");
        let adjustment_group = proposal_body["data"]["id"]
            .as_str()
            .expect("adjustment group");
        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{adjustment_group}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK, "{confirm_body}");
        let (_, holdings_body) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        let holding_id = holdings_body["data"][0]["id"].as_str().expect("holding id");

        let terms_endpoint = format!("/v1/holdings/{holding_id}/yield-terms");
        let terms_input = json!({
            "principal": {"amount": "10000", "currency": "CNY"},
            "annualRate": "0.0365",
            "rateType": "fixed",
            "interestMethod": "simple",
            "dayCountBasis": 365,
            "compoundingFrequency": "none",
            "interestStartDate": "2026-01-01",
            "maturityDate": "2027-01-01",
            "payoutAccountId": payout_account_id
        });
        let (terms_status, terms_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &terms_endpoint,
            terms_input.clone(),
        )
        .await;
        assert_eq!(terms_status, StatusCode::OK, "{terms_body}");
        assert_eq!(terms_body["data"]["yieldTerms"]["annualRate"], "0.0365");

        let (positions_status, positions_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/yield-positions?throughDate=2026-01-31",
        )
        .await;
        assert_eq!(positions_status, StatusCode::OK, "{positions_body}");
        assert_eq!(positions_body["data"][0]["accrualDays"], 30);
        assert_eq!(positions_body["data"][0]["accruedInterest"]["amount"], "30");
        let (matured_status, matured_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/yield-positions?throughDate=2028-01-01",
        )
        .await;
        assert_eq!(matured_status, StatusCode::OK, "{matured_body}");
        assert_eq!(matured_body["data"][0]["accruedThrough"], "2027-01-01");
        assert_eq!(matured_body["data"][0]["status"], "matured");
        assert_eq!(matured_body["data"][0]["accruedInterest"]["amount"], "365");

        let interest_endpoint = format!("/v1/holdings/{holding_id}/interest-proposals");
        let interest_input = json!({"throughDate": "2026-01-31"});
        let interest_idempotency = next_local_id("yield_interest_replay");
        let (interest_status, _, interest_body) = request_json_body_with_idempotency_from(
            router.clone(),
            Method::POST,
            &interest_endpoint,
            interest_input.clone(),
            Some(&interest_idempotency),
        )
        .await;
        assert_eq!(interest_status, StatusCode::OK, "{interest_body}");
        assert_eq!(
            interest_body["data"]["proposedMovements"][0]["entries"][0]["amount"],
            "30"
        );
        let interest_group = interest_body["data"]["id"]
            .as_str()
            .expect("interest group");
        let (replay_status, _, replay_body) = request_json_body_with_idempotency_from(
            router.clone(),
            Method::POST,
            &interest_endpoint,
            interest_input.clone(),
            Some(&interest_idempotency),
        )
        .await;
        assert_eq!(replay_status, StatusCode::OK, "{replay_body}");
        assert_eq!(replay_body["data"]["id"], interest_body["data"]["id"]);
        let (pending_patch_status, pending_patch_body) =
            request_json_body_from(router.clone(), Method::PATCH, &terms_endpoint, terms_input)
                .await;
        assert_eq!(
            pending_patch_status,
            StatusCode::CONFLICT,
            "{pending_patch_body}"
        );

        let mut broken_link =
            local_ledger::read_document(&path).expect("ledger should remain readable");
        broken_link["holdings"][0]["yieldTerms"]
            .as_object_mut()
            .expect("yield terms")
            .remove("pendingInterestMovementId");
        assert!(
            local_ledger::write_document(&path, &broken_link).is_err(),
            "a pending interest movement without the holding pointer must be rejected"
        );

        let (_, payout_before) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{payout_account_id}"),
        )
        .await;
        assert_eq!(payout_before["data"]["cashBalances"][0]["amount"], "100.00");
        let (duplicate_status, duplicate_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &interest_endpoint,
            interest_input,
        )
        .await;
        assert_eq!(duplicate_status, StatusCode::CONFLICT, "{duplicate_body}");

        let (reject_status, reject_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{interest_group}/reject"),
        )
        .await;
        assert_eq!(reject_status, StatusCode::NO_CONTENT, "{reject_body}");
        let (_, holding_after_reject) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{holding_account_id}/holdings"),
        )
        .await;
        assert!(
            holding_after_reject["data"][0]["yieldTerms"]
                .get("pendingInterestMovementId")
                .is_none(),
            "reject must release the holding for a later proposal"
        );
        let (replacement_status, replacement_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &interest_endpoint,
            json!({"throughDate": "2026-01-31"}),
        )
        .await;
        assert_eq!(replacement_status, StatusCode::OK, "{replacement_body}");
        let replacement_group = replacement_body["data"]["id"]
            .as_str()
            .expect("replacement interest group");

        let mut conflicted_document =
            local_ledger::read_document(&path).expect("ledger should remain readable");
        conflicted_document["holdings"][0]["yieldTerms"]["lastAccruedThrough"] =
            json!("2026-01-02");
        local_ledger::write_document(&path, &conflicted_document)
            .expect("the independently valid concurrent terms change should persist");
        let (conflict_status, conflict_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{replacement_group}/confirm"),
        )
        .await;
        assert_eq!(conflict_status, StatusCode::CONFLICT, "{conflict_body}");
        let (_, payout_after_conflict) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{payout_account_id}"),
        )
        .await;
        assert_eq!(
            payout_after_conflict["data"]["cashBalances"][0]["amount"], "100.00",
            "a failed confirmation must not apply the cash entry"
        );
        conflicted_document["holdings"][0]["yieldTerms"]["lastAccruedThrough"] =
            json!("2026-01-01");
        local_ledger::write_document(&path, &conflicted_document)
            .expect("restored terms should remain valid");

        let (confirm_interest_status, confirm_interest_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{replacement_group}/confirm"),
        )
        .await;
        assert_eq!(
            confirm_interest_status,
            StatusCode::OK,
            "{confirm_interest_body}"
        );
        let (_, payout_after) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{payout_account_id}"),
        )
        .await;
        assert_eq!(payout_after["data"]["cashBalances"][0]["amount"], "130.00");
        let (_, holding_after) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{holding_account_id}/holdings"),
        )
        .await;
        assert_eq!(holding_after["data"][0]["quantity"], "10000");
        assert_eq!(
            holding_after["data"][0]["yieldTerms"]["lastAccruedThrough"],
            "2026-01-31"
        );
        assert!(
            holding_after["data"][0]["yieldTerms"]
                .get("pendingInterestMovementId")
                .is_none()
        );

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
    async fn local_ledger_rejects_unbalanced_same_currency_transfer() {
        let path = unique_test_ledger_path("unbalanced_transfer");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let mut account_ids = Vec::new();
        for display_name in ["转出账户", "转入账户"] {
            let (status, body) = request_json_body_from(
                router.clone(),
                Method::POST,
                "/v1/accounts",
                json!({
                    "displayName": display_name,
                    "accountType": "bank",
                    "defaultCurrency": "CNY",
                    "supportedCurrencies": ["CNY"],
                    "includeInNetWorth": true,
                    "balanceMode": "cash_balance",
                    "openingBalances": [{"currency": "CNY", "amount": "100.00"}]
                }),
            )
            .await;
            assert_eq!(status, StatusCode::CREATED);
            account_ids.push(
                body["data"]["id"]
                    .as_str()
                    .expect("account id should be a string")
                    .to_string(),
            );
        }

        let draft_input = json!({
            "type": "transfer",
            "occurredAt": "2026-07-15T12:00:00Z",
            "title": "不守恒转账",
            "entries": [
                {
                    "accountId": account_ids[0],
                    "amount": "60.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": account_ids[1],
                    "amount": "50.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                }
            ],
            "transferMeta": {
                "fromAccountId": account_ids[0],
                "toAccountId": account_ids[1]
            }
        });
        let (status, body) =
            request_json_body_from(router, Method::POST, "/v1/movements/drafts", draft_input).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"]["code"], "invalid_movement_draft_input");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_rejects_directionally_invalid_or_unsupported_cash_movements() {
        let path = unique_test_ledger_path("movement_semantics");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (account_status, account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "语义校验账户",
                "accountType": "bank",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [{"currency": "CNY", "amount": "100.00"}]
            }),
        )
        .await;
        assert_eq!(account_status, StatusCode::CREATED);
        let account_id = account_body["data"]["id"]
            .as_str()
            .expect("account id should be a string");

        let invalid_inputs = [
            json!({
                "type": "income",
                "occurredAt": "2026-07-15T12:00:00Z",
                "title": "反向收入",
                "entries": [{
                    "accountId": account_id,
                    "amount": "10.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                }]
            }),
            json!({
                "type": "expense",
                "occurredAt": "2026-07-15T12:00:00Z",
                "title": "反向支出",
                "entries": [{
                    "accountId": account_id,
                    "amount": "10.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "source"
                }]
            }),
            json!({
                "type": "adjustment",
                "occurredAt": "2026-07-15T12:00:00Z",
                "title": "错误校准角色",
                "entries": [{
                    "accountId": account_id,
                    "amount": "10.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "source"
                }]
            }),
            json!({
                "type": "income",
                "occurredAt": "2026-07-15T12:00:00Z",
                "title": "账户不支持的币种",
                "entries": [{
                    "accountId": account_id,
                    "amount": "10.00",
                    "currency": "USD",
                    "direction": "in",
                    "role": "source"
                }]
            }),
            json!({
                "type": "correction",
                "occurredAt": "2026-07-15T12:00:00Z",
                "title": "绕过更正入口",
                "entries": [{
                    "accountId": account_id,
                    "amount": "10.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "adjustment"
                }]
            }),
        ];

        for input in invalid_inputs {
            let (status, body) =
                request_json_body_from(router.clone(), Method::POST, "/v1/movements/drafts", input)
                    .await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
            assert_eq!(body["error"]["code"], "invalid_movement_draft_input");
        }

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_buy_and_sell_require_conserved_cash_and_holding_legs() {
        let path = unique_test_ledger_path("buy_sell_semantics");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let mut account_ids = Vec::new();
        for (display_name, account_type, balance_mode, amount) in [
            ("买卖资金账户", "bank", "cash_balance", "1000.00"),
            ("买卖证券账户", "brokerage", "holdings", "0.00"),
        ] {
            let (status, body) = request_json_body_from(
                router.clone(),
                Method::POST,
                "/v1/accounts",
                json!({
                    "displayName": display_name,
                    "accountType": account_type,
                    "defaultCurrency": "CNY",
                    "supportedCurrencies": ["CNY"],
                    "includeInNetWorth": true,
                    "balanceMode": balance_mode,
                    "openingBalances": [{"currency": "CNY", "amount": amount}]
                }),
            )
            .await;
            assert_eq!(status, StatusCode::CREATED);
            account_ids.push(
                body["data"]["id"]
                    .as_str()
                    .expect("account id should be a string")
                    .to_string(),
            );
        }

        let invalid_buy = json!({
            "type": "buy",
            "occurredAt": "2026-07-15T12:00:00Z",
            "title": "缺少持仓标识的买入",
            "entries": [
                {
                    "accountId": account_ids[0],
                    "amount": "100.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": account_ids[1],
                    "amount": "10.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                }
            ]
        });
        let (invalid_status, invalid_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            invalid_buy,
        )
        .await;
        assert_eq!(invalid_status, StatusCode::BAD_REQUEST, "{invalid_body}");

        let invalid_fee = json!({
            "type": "buy",
            "occurredAt": "2026-07-15T12:00:00Z",
            "title": "费用账户错误的买入",
            "entries": [
                {
                    "accountId": account_ids[0],
                    "amount": "100.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": account_ids[1],
                    "instrumentId": "inst_semantic_fund",
                    "amount": "10.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                },
                {
                    "accountId": account_ids[1],
                    "amount": "2.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "fee"
                }
            ]
        });
        let (invalid_fee_status, invalid_fee_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            invalid_fee,
        )
        .await;
        assert_eq!(
            invalid_fee_status,
            StatusCode::BAD_REQUEST,
            "{invalid_fee_body}"
        );

        let buy = json!({
            "type": "buy",
            "occurredAt": "2026-07-15T12:00:00Z",
            "title": "守恒买入",
            "entries": [
                {
                    "accountId": account_ids[0],
                    "amount": "100.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": account_ids[1],
                    "instrumentId": "inst_semantic_fund",
                    "amount": "10.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                },
                {
                    "accountId": account_ids[0],
                    "amount": "2.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "fee"
                },
                {
                    "accountId": account_ids[0],
                    "amount": "1.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "tax"
                }
            ]
        });
        let (buy_status, buy_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/movements/drafts", buy).await;
        assert_eq!(buy_status, StatusCode::CREATED, "{buy_body}");
        let buy_id = buy_body["data"]["id"].as_str().expect("buy movement id");
        let buy_group = buy_body["data"]["atomicGroupId"]
            .as_str()
            .expect("buy atomic group id");
        let (confirm_buy_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{buy_group}/confirm"),
        )
        .await;
        assert_eq!(confirm_buy_status, StatusCode::OK);
        let (_, cash_after_buy) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}", account_ids[0]),
        )
        .await;
        assert_eq!(
            cash_after_buy["data"]["cashBalances"][0]["amount"],
            "897.00"
        );
        let (_, holdings_after_buy) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(
            holdings_after_buy["data"][0]["costBasisTotal"]["amount"],
            "103.00"
        );

        let (correction_status, correction_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/corrections",
            json!({
                "targetMovementId": buy_id,
                "reason": "投资成本更正尚未定义",
                "proposedDiffs": [{
                    "fieldPath": "entries[0].amount",
                    "oldValue": "100.00",
                    "newValue": "90.00",
                    "severity": "danger"
                }]
            }),
        )
        .await;
        assert_eq!(
            correction_status,
            StatusCode::BAD_REQUEST,
            "{correction_body}"
        );

        let excessive_sell_fee = json!({
            "type": "sell",
            "occurredAt": "2026-07-15T13:00:00Z",
            "title": "费用超过回款的卖出",
            "entries": [
                {
                    "accountId": account_ids[1],
                    "instrumentId": "inst_semantic_fund",
                    "amount": "1.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": account_ids[0],
                    "amount": "1.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                },
                {
                    "accountId": account_ids[0],
                    "amount": "2.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "fee"
                }
            ]
        });
        let (excessive_fee_status, excessive_fee_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            excessive_sell_fee,
        )
        .await;
        assert_eq!(
            excessive_fee_status,
            StatusCode::BAD_REQUEST,
            "{excessive_fee_body}"
        );

        let sell = json!({
            "type": "sell",
            "occurredAt": "2026-07-15T13:00:00Z",
            "title": "守恒卖出",
            "entries": [
                {
                    "accountId": account_ids[1],
                    "instrumentId": "inst_semantic_fund",
                    "amount": "4.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": account_ids[0],
                    "amount": "40.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                },
                {
                    "accountId": account_ids[0],
                    "amount": "1.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "fee"
                },
                {
                    "accountId": account_ids[0],
                    "amount": "1.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "tax"
                }
            ]
        });
        let (sell_status, sell_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/movements/drafts", sell)
                .await;
        assert_eq!(sell_status, StatusCode::CREATED, "{sell_body}");
        let sell_id = sell_body["data"]["id"].as_str().expect("sell movement id");
        let sell_group = sell_body["data"]["atomicGroupId"]
            .as_str()
            .expect("sell atomic group id");
        let (confirm_sell_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{sell_group}/confirm"),
        )
        .await;
        assert_eq!(confirm_sell_status, StatusCode::OK);

        let (_, overview) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(
            overview["data"]["latestSnapshot"]["netWorth"]["amount"],
            "996.80"
        );
        let (_, cash_after_sell) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}", account_ids[0]),
        )
        .await;
        assert_eq!(
            cash_after_sell["data"]["cashBalances"][0]["amount"],
            "935.00"
        );
        let (_, holdings) = request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(holdings["data"][0]["quantity"], "6");
        assert_eq!(holdings["data"][0]["costBasisTotal"]["amount"], "61.80");
        let (_, confirmed_sell) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/movements/{sell_id}"),
        )
        .await;
        let sale_result = &confirmed_sell["data"]["saleResult"];
        assert_eq!(sale_result["costBasisMethod"], "average_cost");
        assert_eq!(sale_result["grossProceeds"]["amount"], "40.00");
        assert_eq!(sale_result["feeAndTaxTotal"]["amount"], "2.00");
        assert_eq!(sale_result["netProceeds"]["amount"], "38.00");
        assert_eq!(sale_result["costBasisReleased"]["amount"], "41.20");
        assert_eq!(sale_result["realizedPnl"]["amount"], "-3.20");
        assert_eq!(sale_result["realizedPnlStatus"], "calculated");

        let (refresh_status, refresh_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/quotes/refresh",
            json!({
                "mode": "manual",
                "quotes": [{
                    "instrumentId": "inst_semantic_fund",
                    "price": "12.00",
                    "currency": "CNY",
                    "asOf": "2026-07-15T14:00:00Z",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "source": "test"
                }]
            }),
        )
        .await;
        assert_eq!(refresh_status, StatusCode::OK, "{refresh_body}");
        let (_, quoted_holdings) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(quoted_holdings["data"][0]["marketValue"]["amount"], "72.00");
        assert_eq!(
            quoted_holdings["data"][0]["unrealizedPnl"]["amount"],
            "10.20"
        );
        let (_, quoted_overview) =
            request_json_from(router, Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(
            quoted_overview["data"]["latestSnapshot"]["netWorth"]["amount"],
            "1007.00"
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_investment_replacement_correction_preserves_cost_basis() {
        let path = unique_test_ledger_path("investment_replacement_correction");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let mut account_ids = Vec::new();
        for (display_name, account_type, balance_mode, amount) in [
            ("更正资金账户", "bank", "cash_balance", "1000.00"),
            ("更正证券账户", "brokerage", "holdings", "0.00"),
        ] {
            let (status, body) = request_json_body_from(
                router.clone(),
                Method::POST,
                "/v1/accounts",
                json!({
                    "displayName": display_name,
                    "accountType": account_type,
                    "defaultCurrency": "CNY",
                    "supportedCurrencies": ["CNY"],
                    "includeInNetWorth": true,
                    "balanceMode": balance_mode,
                    "openingBalances": [{"currency": "CNY", "amount": amount}]
                }),
            )
            .await;
            assert_eq!(status, StatusCode::CREATED, "{body}");
            account_ids.push(body["data"]["id"].as_str().unwrap().to_string());
        }

        let (buy_status, buy_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            json!({
                "type": "buy",
                "occurredAt": "2026-07-16T10:00:00Z",
                "title": "待更正买入",
                "entries": [
                    {"accountId": account_ids[0], "amount": "100.00", "currency": "CNY", "direction": "out", "role": "source"},
                    {"accountId": account_ids[1], "instrumentId": "inst_correction_fund", "amount": "10", "currency": "CNY", "direction": "in", "role": "destination"},
                    {"accountId": account_ids[0], "amount": "2.00", "currency": "CNY", "direction": "out", "role": "fee"},
                    {"accountId": account_ids[0], "amount": "1.00", "currency": "CNY", "direction": "out", "role": "tax"}
                ]
            }),
        )
        .await;
        assert_eq!(buy_status, StatusCode::CREATED, "{buy_body}");
        let buy_id = buy_body["data"]["id"].as_str().unwrap().to_string();
        let buy_group = buy_body["data"]["atomicGroupId"].as_str().unwrap();
        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{buy_group}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK, "{confirm_body}");

        let replacement_buy = json!({
            "targetMovementId": buy_id,
            "reason": "成交回单显示数量和费用录入错误",
            "replacementEntries": [
                {"accountId": account_ids[0], "amount": "120.00", "currency": "CNY", "direction": "out", "role": "source"},
                {"accountId": account_ids[1], "instrumentId": "inst_correction_fund", "amount": "12", "currency": "CNY", "direction": "in", "role": "destination"},
                {"accountId": account_ids[0], "amount": "4.00", "currency": "CNY", "direction": "out", "role": "fee"},
                {"accountId": account_ids[0], "amount": "1.00", "currency": "CNY", "direction": "out", "role": "tax"}
            ]
        });
        let (correction_status, correction_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/corrections",
            replacement_buy.clone(),
        )
        .await;
        assert_eq!(correction_status, StatusCode::OK, "{correction_body}");
        let buy_correction_id = correction_body["data"]["proposedMovements"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();
        let correction_group = correction_body["data"]["id"].as_str().unwrap();

        let (_, pending_cash) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}", account_ids[0]),
        )
        .await;
        let (_, pending_holdings) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(pending_cash["data"]["cashBalances"][0]["amount"], "897.00");
        assert_eq!(pending_holdings["data"][0]["quantity"], "10");
        assert_eq!(
            pending_holdings["data"][0]["costBasisTotal"]["amount"],
            "103.00"
        );

        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{correction_group}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK, "{confirm_body}");
        let (_, corrected_cash) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}", account_ids[0]),
        )
        .await;
        let (_, corrected_holdings) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(
            corrected_cash["data"]["cashBalances"][0]["amount"],
            "875.00"
        );
        assert_eq!(corrected_holdings["data"][0]["quantity"], "12");
        assert_eq!(
            corrected_holdings["data"][0]["costBasisTotal"]["amount"],
            "125.00"
        );
        let (_, original_buy) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/movements/{buy_id}"),
        )
        .await;
        assert_eq!(original_buy["data"]["entries"][0]["amount"], "100.00");
        let (_, confirmed_correction) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/movements/{buy_correction_id}"),
        )
        .await;
        assert_eq!(
            confirmed_correction["data"]["investmentReplacement"]["targetType"],
            "buy"
        );

        let (duplicate_status, duplicate_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/corrections",
            replacement_buy,
        )
        .await;
        assert_eq!(duplicate_status, StatusCode::CONFLICT, "{duplicate_body}");

        let (correction_target_status, correction_target_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/corrections",
            json!({
                "targetMovementId": buy_correction_id,
                "reason": "不得把投资 correction 当普通 adjustment 再更正",
                "replacementEntries": [
                    {"accountId": account_ids[0], "amount": "125.00", "currency": "CNY", "direction": "out", "role": "source"},
                    {"accountId": account_ids[1], "instrumentId": "inst_correction_fund", "amount": "12", "currency": "CNY", "direction": "in", "role": "destination"}
                ]
            }),
        )
        .await;
        assert_eq!(
            correction_target_status,
            StatusCode::BAD_REQUEST,
            "{correction_target_body}"
        );

        let (sell_status, sell_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            json!({
                "type": "sell",
                "occurredAt": "2026-07-16T11:00:00Z",
                "title": "待更正卖出",
                "entries": [
                    {"accountId": account_ids[1], "instrumentId": "inst_correction_fund", "amount": "2", "currency": "CNY", "direction": "out", "role": "source"},
                    {"accountId": account_ids[0], "amount": "30.00", "currency": "CNY", "direction": "in", "role": "destination"},
                    {"accountId": account_ids[0], "amount": "1.00", "currency": "CNY", "direction": "out", "role": "fee"}
                ]
            }),
        )
        .await;
        assert_eq!(sell_status, StatusCode::CREATED, "{sell_body}");
        let sell_id = sell_body["data"]["id"].as_str().unwrap().to_string();
        let sell_group = sell_body["data"]["atomicGroupId"].as_str().unwrap();
        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{sell_group}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK, "{confirm_body}");

        let (stale_status, stale_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/corrections",
            json!({
                "targetMovementId": buy_id,
                "reason": "后续成交后不得回改旧买入",
                "replacementEntries": [
                    {"accountId": account_ids[0], "amount": "110.00", "currency": "CNY", "direction": "out", "role": "source"},
                    {"accountId": account_ids[1], "instrumentId": "inst_correction_fund", "amount": "11", "currency": "CNY", "direction": "in", "role": "destination"}
                ]
            }),
        )
        .await;
        assert_eq!(stale_status, StatusCode::CONFLICT, "{stale_body}");

        let (sell_correction_status, sell_correction_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/corrections",
            json!({
                "targetMovementId": sell_id,
                "reason": "卖出数量和回款更正",
                "replacementEntries": [
                    {"accountId": account_ids[1], "instrumentId": "inst_correction_fund", "amount": "3", "currency": "CNY", "direction": "out", "role": "source"},
                    {"accountId": account_ids[0], "amount": "45.00", "currency": "CNY", "direction": "in", "role": "destination"},
                    {"accountId": account_ids[0], "amount": "1.00", "currency": "CNY", "direction": "out", "role": "fee"},
                    {"accountId": account_ids[0], "amount": "1.00", "currency": "CNY", "direction": "out", "role": "tax"}
                ]
            }),
        )
        .await;
        assert_eq!(
            sell_correction_status,
            StatusCode::OK,
            "{sell_correction_body}"
        );
        let sell_correction_id = sell_correction_body["data"]["proposedMovements"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();
        let sell_correction_group = sell_correction_body["data"]["id"].as_str().unwrap();
        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{sell_correction_group}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK, "{confirm_body}");

        let (_, final_cash) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}", account_ids[0]),
        )
        .await;
        let (_, final_holdings) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(final_cash["data"]["cashBalances"][0]["amount"], "918.00");
        assert_eq!(final_holdings["data"][0]["quantity"], "9");
        assert_eq!(
            final_holdings["data"][0]["costBasisTotal"]["amount"],
            "93.75"
        );
        let (_, final_correction) = request_json_from(
            router,
            Method::GET,
            &format!("/v1/movements/{sell_correction_id}"),
        )
        .await;
        let result = &final_correction["data"]["investmentReplacement"]["saleResult"];
        assert_eq!(result["grossProceeds"]["amount"], "45.00");
        assert_eq!(result["feeAndTaxTotal"]["amount"], "2.00");
        assert_eq!(result["netProceeds"]["amount"], "43.00");
        assert_eq!(result["costBasisReleased"]["amount"], "31.25");
        assert_eq!(result["realizedPnl"]["amount"], "11.75");
        assert_eq!(result["realizedPnlStatus"], "calculated");

        local_ledger::validate_supported_ledger(&path)
            .expect("corrected investment ledger should remain valid");
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_loan_disbursement_and_repayment_preserve_accounting_identity() {
        let path = unique_test_ledger_path("loan_semantics");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let mut account_ids = Vec::new();
        for (display_name, account_type, balance_mode) in [
            ("放款银行卡", "bank", "cash_balance"),
            ("测试贷款", "loan", "liability"),
        ] {
            let (status, body) = request_json_body_from(
                router.clone(),
                Method::POST,
                "/v1/accounts",
                json!({
                    "displayName": display_name,
                    "accountType": account_type,
                    "defaultCurrency": "CNY",
                    "supportedCurrencies": ["CNY"],
                    "includeInNetWorth": true,
                    "balanceMode": balance_mode,
                    "openingBalances": [{"currency": "CNY", "amount": "0.00"}]
                }),
            )
            .await;
            assert_eq!(status, StatusCode::CREATED);
            account_ids.push(
                body["data"]["id"]
                    .as_str()
                    .expect("account id should be a string")
                    .to_string(),
            );
        }

        let invalid_disbursement = json!({
            "type": "loan_disbursement",
            "occurredAt": "2026-07-15T12:00:00Z",
            "title": "反向贷款放款",
            "entries": [
                {
                    "accountId": account_ids[0],
                    "amount": "500.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": account_ids[1],
                    "amount": "500.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                }
            ]
        });
        let (invalid_status, invalid_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            invalid_disbursement,
        )
        .await;
        assert_eq!(invalid_status, StatusCode::BAD_REQUEST, "{invalid_body}");

        let disbursement = json!({
            "type": "loan_disbursement",
            "occurredAt": "2026-07-15T12:00:00Z",
            "title": "贷款放款",
            "entries": [
                {
                    "accountId": account_ids[1],
                    "amount": "500.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": account_ids[0],
                    "amount": "500.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                }
            ]
        });
        let (disbursement_status, disbursement_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            disbursement,
        )
        .await;
        assert_eq!(
            disbursement_status,
            StatusCode::CREATED,
            "{disbursement_body}"
        );
        let disbursement_group = disbursement_body["data"]["atomicGroupId"]
            .as_str()
            .expect("disbursement atomic group id");
        let (confirm_disbursement_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{disbursement_group}/confirm"),
        )
        .await;
        assert_eq!(confirm_disbursement_status, StatusCode::OK);

        let repayment = json!({
            "type": "loan_repayment",
            "occurredAt": "2026-07-15T13:00:00Z",
            "title": "贷款还款",
            "entries": [
                {
                    "accountId": account_ids[0],
                    "amount": "100.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                },
                {
                    "accountId": account_ids[1],
                    "amount": "100.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "destination"
                }
            ]
        });
        let (repayment_status, repayment_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            repayment,
        )
        .await;
        assert_eq!(repayment_status, StatusCode::CREATED, "{repayment_body}");
        let repayment_group = repayment_body["data"]["atomicGroupId"]
            .as_str()
            .expect("repayment atomic group id");
        let (confirm_repayment_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{repayment_group}/confirm"),
        )
        .await;
        assert_eq!(confirm_repayment_status, StatusCode::OK);

        let terms_endpoint = format!("/v1/accounts/{}/liability-terms", account_ids[1]);
        let terms_input = json!({
            "liabilityType": "consumer_loan",
            "annualRate": "0.365",
            "rateType": "fixed",
            "dayCountBasis": 365,
            "interestStartDate": "2026-01-01",
            "maturityDate": "2027-01-01",
            "repaymentStartDate": "2026-02-01",
            "nextDueDate": "2026-02-01",
            "repaymentFrequency": "monthly",
            "scheduledPayment": {"amount": "100", "currency": "CNY"},
            "paymentAccountId": account_ids[0]
        });
        let (terms_status, terms_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &terms_endpoint,
            terms_input.clone(),
        )
        .await;
        assert_eq!(terms_status, StatusCode::OK, "{terms_body}");

        let (positions_status, positions_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/liability-positions?throughDate=2026-01-31",
        )
        .await;
        assert_eq!(positions_status, StatusCode::OK, "{positions_body}");
        assert_eq!(
            positions_body["data"][0]["outstandingPrincipal"]["amount"],
            "400"
        );
        assert_eq!(positions_body["data"][0]["accruedInterest"]["amount"], "12");
        assert_eq!(
            positions_body["data"][0]["nextPayment"]["projectedInterest"]["amount"],
            "12.4"
        );
        assert_eq!(
            positions_body["data"][0]["nextPayment"]["projectedPrincipal"]["amount"],
            "87.6"
        );
        let schedule_endpoint =
            format!("/v1/accounts/{}/repayment-schedule?limit=2", account_ids[1]);
        let (schedule_status, schedule_body) =
            request_json_from(router.clone(), Method::GET, &schedule_endpoint).await;
        assert_eq!(schedule_status, StatusCode::OK, "{schedule_body}");
        assert_eq!(schedule_body["data"]["items"].as_array().unwrap().len(), 2);
        assert_eq!(
            schedule_body["data"]["items"][0]["interest"]["amount"],
            "12.4"
        );
        assert_eq!(
            schedule_body["data"]["items"][0]["principal"]["amount"],
            "87.6"
        );
        assert_eq!(
            schedule_body["data"]["items"][1]["interest"]["amount"],
            "8.7472"
        );
        assert_eq!(
            schedule_body["data"]["remainingBalanceAfterPage"]["amount"],
            "221.1472"
        );
        assert_eq!(schedule_body["data"]["hasMore"], true);
        let (invalid_schedule_status, _) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}/repayment-schedule?limit=0", account_ids[1]),
        )
        .await;
        assert_eq!(invalid_schedule_status, StatusCode::BAD_REQUEST);

        let interest_endpoint = format!("/v1/accounts/{}/loan-interest-proposals", account_ids[1]);
        let interest_idempotency = next_local_id("loan_interest_replay");
        let (interest_status, _, interest_body) = request_json_body_with_idempotency_from(
            router.clone(),
            Method::POST,
            &interest_endpoint,
            json!({"throughDate": "2026-01-31"}),
            Some(&interest_idempotency),
        )
        .await;
        assert_eq!(interest_status, StatusCode::OK, "{interest_body}");
        let interest_group = interest_body["data"]["id"]
            .as_str()
            .expect("loan interest group");
        let (replay_status, _, replay_body) = request_json_body_with_idempotency_from(
            router.clone(),
            Method::POST,
            &interest_endpoint,
            json!({"throughDate": "2026-01-31"}),
            Some(&interest_idempotency),
        )
        .await;
        assert_eq!(replay_status, StatusCode::OK, "{replay_body}");
        assert_eq!(replay_body["data"]["id"], interest_body["data"]["id"]);
        let mut broken_loan_link =
            local_ledger::read_document(&path).expect("loan ledger should remain readable");
        broken_loan_link["accounts"][1]["liabilityTerms"]
            .as_object_mut()
            .expect("liability terms")
            .remove("pendingLoanInterestMovementId");
        assert!(
            local_ledger::write_document(&path, &broken_loan_link).is_err(),
            "a pending loan interest movement without its account pointer must be rejected"
        );
        let (pending_terms_status, pending_terms_body) =
            request_json_body_from(router.clone(), Method::PATCH, &terms_endpoint, terms_input)
                .await;
        assert_eq!(
            pending_terms_status,
            StatusCode::CONFLICT,
            "{pending_terms_body}"
        );
        let (_, loan_before_interest) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}", account_ids[1]),
        )
        .await;
        assert_eq!(
            loan_before_interest["data"]["cashBalances"][0]["amount"],
            "-400.00"
        );
        let (reject_interest_status, reject_interest_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{interest_group}/reject"),
        )
        .await;
        assert_eq!(
            reject_interest_status,
            StatusCode::NO_CONTENT,
            "{reject_interest_body}"
        );
        let (replacement_interest_status, replacement_interest_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &interest_endpoint,
            json!({"throughDate": "2026-01-31"}),
        )
        .await;
        assert_eq!(
            replacement_interest_status,
            StatusCode::OK,
            "{replacement_interest_body}"
        );
        let replacement_interest_group = replacement_interest_body["data"]["id"]
            .as_str()
            .expect("replacement loan interest group");
        let mut conflicted_loan_document =
            local_ledger::read_document(&path).expect("loan ledger should remain readable");
        conflicted_loan_document["accounts"][1]["liabilityTerms"]["lastInterestAccruedThrough"] =
            json!("2026-01-02");
        local_ledger::write_document(&path, &conflicted_loan_document)
            .expect("the independently valid loan terms change should persist");
        let (conflict_status, conflict_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{replacement_interest_group}/confirm"),
        )
        .await;
        assert_eq!(conflict_status, StatusCode::CONFLICT, "{conflict_body}");
        let (_, loan_after_conflict) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}", account_ids[1]),
        )
        .await;
        assert_eq!(
            loan_after_conflict["data"]["cashBalances"][0]["amount"], "-400.00",
            "a failed loan interest confirmation must not change the debt"
        );
        conflicted_loan_document["accounts"][1]["liabilityTerms"]["lastInterestAccruedThrough"] =
            json!("2026-01-01");
        local_ledger::write_document(&path, &conflicted_loan_document)
            .expect("restored loan terms should remain valid");
        let (confirm_interest_status, confirm_interest_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{replacement_interest_group}/confirm"),
        )
        .await;
        assert_eq!(
            confirm_interest_status,
            StatusCode::OK,
            "{confirm_interest_body}"
        );

        let (_, bank) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}", account_ids[0]),
        )
        .await;
        let (_, loan) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}", account_ids[1]),
        )
        .await;
        let (_, overview) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(bank["data"]["cashBalances"][0]["amount"], "400.00");
        assert_eq!(loan["data"]["cashBalances"][0]["amount"], "-412.00");
        assert_eq!(
            loan["data"]["liabilityTerms"]["lastInterestAccruedThrough"],
            "2026-01-31"
        );
        assert_eq!(
            overview["data"]["latestSnapshot"]["grossAssets"]["amount"],
            "400.00"
        );
        assert_eq!(
            overview["data"]["latestSnapshot"]["totalLiabilities"]["amount"],
            "412.00"
        );
        assert_eq!(
            overview["data"]["latestSnapshot"]["netWorth"]["amount"],
            "-12.00"
        );

        let payment_endpoint = format!("/v1/accounts/{}/loan-payment-proposals", account_ids[1]);
        let payment_input = json!({"paymentDate": "2026-02-01"});
        let payment_idempotency = next_local_id("loan_payment_replay");
        let (payment_status, _, payment_body) = request_json_body_with_idempotency_from(
            router.clone(),
            Method::POST,
            &payment_endpoint,
            payment_input.clone(),
            Some(&payment_idempotency),
        )
        .await;
        assert_eq!(payment_status, StatusCode::OK, "{payment_body}");
        assert_eq!(
            payment_body["data"]["proposedMovements"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert_eq!(
            payment_body["data"]["proposedMovements"][1]["loanPayment"]["interestAmount"]["amount"],
            "0.412"
        );
        assert_eq!(
            payment_body["data"]["proposedMovements"][1]["loanPayment"]["principalAmount"]["amount"],
            "99.588"
        );
        let payment_group = payment_body["data"]["id"]
            .as_str()
            .expect("loan payment group");
        let (payment_replay_status, _, payment_replay_body) =
            request_json_body_with_idempotency_from(
                router.clone(),
                Method::POST,
                &payment_endpoint,
                payment_input.clone(),
                Some(&payment_idempotency),
            )
            .await;
        assert_eq!(payment_replay_status, StatusCode::OK);
        assert_eq!(
            payment_replay_body["data"]["id"],
            payment_body["data"]["id"]
        );
        let (reject_payment_status, reject_payment_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{payment_group}/reject"),
        )
        .await;
        assert_eq!(
            reject_payment_status,
            StatusCode::NO_CONTENT,
            "{reject_payment_body}"
        );
        let (replacement_payment_status, replacement_payment_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &payment_endpoint,
            payment_input,
        )
        .await;
        assert_eq!(
            replacement_payment_status,
            StatusCode::OK,
            "{replacement_payment_body}"
        );
        let replacement_payment_group = replacement_payment_body["data"]["id"]
            .as_str()
            .expect("replacement loan payment group");
        let mut conflicted_payment_document =
            local_ledger::read_document(&path).expect("loan payment ledger should remain readable");
        conflicted_payment_document["accounts"][1]["liabilityTerms"]["nextDueDate"] =
            json!("2026-02-02");
        local_ledger::write_document(&path, &conflicted_payment_document)
            .expect("independently valid next due date change should persist");
        let (payment_conflict_status, payment_conflict_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{replacement_payment_group}/confirm"),
        )
        .await;
        assert_eq!(
            payment_conflict_status,
            StatusCode::CONFLICT,
            "{payment_conflict_body}"
        );
        let (_, bank_after_payment_conflict) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}", account_ids[0]),
        )
        .await;
        let (_, loan_after_payment_conflict) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}", account_ids[1]),
        )
        .await;
        assert_eq!(
            bank_after_payment_conflict["data"]["cashBalances"][0]["amount"],
            "400.00"
        );
        assert_eq!(
            loan_after_payment_conflict["data"]["cashBalances"][0]["amount"],
            "-412.00"
        );
        assert_eq!(
            loan_after_payment_conflict["data"]["liabilityTerms"]["lastInterestAccruedThrough"],
            "2026-01-31"
        );
        conflicted_payment_document["accounts"][1]["liabilityTerms"]["nextDueDate"] =
            json!("2026-02-01");
        local_ledger::write_document(&path, &conflicted_payment_document)
            .expect("restored next due date should remain valid");
        let (confirm_payment_status, confirm_payment_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{replacement_payment_group}/confirm"),
        )
        .await;
        assert_eq!(
            confirm_payment_status,
            StatusCode::OK,
            "{confirm_payment_body}"
        );
        let (_, bank_after_payment) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}", account_ids[0]),
        )
        .await;
        let (_, loan_after_payment) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{}", account_ids[1]),
        )
        .await;
        assert_eq!(
            bank_after_payment["data"]["cashBalances"][0]["amount"],
            "300.00"
        );
        assert_eq!(
            loan_after_payment["data"]["cashBalances"][0]["amount"],
            "-312.412"
        );
        assert_eq!(
            loan_after_payment["data"]["liabilityTerms"]["lastInterestAccruedThrough"],
            "2026-02-01"
        );
        assert_eq!(
            loan_after_payment["data"]["liabilityTerms"]["nextDueDate"],
            "2026-03-01"
        );
        assert!(
            loan_after_payment["data"]["liabilityTerms"]
                .get("pendingLoanPaymentMovementId")
                .is_none()
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_credit_card_purchase_and_repayment_preserve_accounting_identity() {
        let path = unique_test_ledger_path("credit_card_repayment");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (bank_status, bank_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "还款银行卡",
                "accountType": "bank",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [{"currency": "CNY", "amount": "1000.00"}]
            }),
        )
        .await;
        assert_eq!(bank_status, StatusCode::CREATED);
        let bank_id = bank_body["data"]["id"]
            .as_str()
            .expect("bank id should be a string")
            .to_string();

        let (card_status, card_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "测试信用卡",
                "accountType": "credit_card",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "balanceMode": "liability",
                "openingBalances": [{"currency": "CNY", "amount": "0.00"}]
            }),
        )
        .await;
        assert_eq!(card_status, StatusCode::CREATED);
        let card_id = card_body["data"]["id"]
            .as_str()
            .expect("credit card id should be a string")
            .to_string();

        let (purchase_status, purchase_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            json!({
                "type": "expense",
                "occurredAt": "2026-07-15T12:00:00Z",
                "title": "信用卡消费",
                "entries": [{
                    "accountId": card_id,
                    "amount": "100.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                }]
            }),
        )
        .await;
        assert_eq!(purchase_status, StatusCode::CREATED);
        let purchase_id = purchase_body["data"]["id"]
            .as_str()
            .expect("purchase id should be a string");
        let purchase_group_id = purchase_body["data"]["atomicGroupId"]
            .as_str()
            .expect("purchase group id should be a string");
        let (submit_purchase_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/movements/{purchase_id}/submit-review"),
        )
        .await;
        assert_eq!(submit_purchase_status, StatusCode::OK);
        let (confirm_purchase_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{purchase_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_purchase_status, StatusCode::OK);

        let (_, after_purchase) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(
            after_purchase["data"]["latestSnapshot"]["grossAssets"]["amount"],
            "1000.00"
        );
        assert_eq!(
            after_purchase["data"]["latestSnapshot"]["totalLiabilities"]["amount"],
            "100.00"
        );
        assert_eq!(
            after_purchase["data"]["latestSnapshot"]["netWorth"]["amount"],
            "900.00"
        );

        let (repayment_status, repayment_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            json!({
                "type": "transfer",
                "occurredAt": "2026-07-15T13:00:00Z",
                "title": "信用卡还款",
                "entries": [
                    {
                        "accountId": bank_id,
                        "amount": "60.00",
                        "currency": "CNY",
                        "direction": "out",
                        "role": "source"
                    },
                    {
                        "accountId": card_id,
                        "amount": "60.0",
                        "currency": "CNY",
                        "direction": "in",
                        "role": "destination"
                    }
                ],
                "transferMeta": {
                    "fromAccountId": bank_id,
                    "toAccountId": card_id
                }
            }),
        )
        .await;
        assert_eq!(repayment_status, StatusCode::CREATED);
        let repayment_id = repayment_body["data"]["id"]
            .as_str()
            .expect("repayment id should be a string");
        let repayment_group_id = repayment_body["data"]["atomicGroupId"]
            .as_str()
            .expect("repayment group id should be a string");
        let (submit_repayment_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/movements/{repayment_id}/submit-review"),
        )
        .await;
        assert_eq!(submit_repayment_status, StatusCode::OK);
        let (confirm_repayment_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{repayment_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_repayment_status, StatusCode::OK);

        let (_, bank_after) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{bank_id}"),
        )
        .await;
        let (_, card_after) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{card_id}"),
        )
        .await;
        assert_eq!(bank_after["data"]["cashBalances"][0]["amount"], "940.00");
        assert_eq!(card_after["data"]["cashBalances"][0]["amount"], "-40.00");

        let (_, after_repayment) =
            request_json_from(router, Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(
            after_repayment["data"]["latestSnapshot"]["grossAssets"]["amount"],
            "940.00"
        );
        assert_eq!(
            after_repayment["data"]["latestSnapshot"]["totalLiabilities"]["amount"],
            "40.00"
        );
        assert_eq!(
            after_repayment["data"]["latestSnapshot"]["netWorth"]["amount"],
            "900.00"
        );
        assert_eq!(
            after_repayment["data"]["pendingSummary"]["accountAnomalyCount"],
            0
        );

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
    async fn local_ledger_quote_refresh_is_disabled_by_default_without_fabricating_price() {
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
            "quote provider is disabled; explicitly configure public or yahoo, or pass quotes/fxRates payload"
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
            "defaultCurrency": "USD",
            "supportedCurrencies": ["USD"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "USD", "amount": "100.00"}
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
                    "amount": "10.00",
                    "currency": "USD",
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

    #[test]
    fn quote_provider_is_private_by_default_and_requires_explicit_opt_in() {
        assert!(quote_provider_disabled_value(None));
        assert!(quote_provider_disabled_value(Some("")));
        assert!(quote_provider_disabled_value(Some("none")));
        assert!(quote_provider_disabled_value(Some("off")));
        assert!(quote_provider_disabled_value(Some("disabled")));
        assert!(quote_provider_disabled_value(Some("unknown")));
        assert!(!quote_provider_disabled_value(Some("yahoo")));
        assert!(!quote_provider_disabled_value(Some(" Yahoo ")));
        assert!(!quote_provider_disabled_value(Some("public")));
    }

    #[tokio::test]
    async fn openai_responses_provider_returns_a_valid_review_only_movement() {
        let captured = Arc::new(Mutex::new(Value::Null));
        let captured_for_route = captured.clone();
        let provider = Router::new().route(
            "/v1/responses",
            post(move |Json(body): Json<Value>| {
                let captured = captured_for_route.clone();
                async move {
                    *captured.lock().expect("capture lock") = body;
                    Json(json!({
                        "id": "resp_test_ai_001",
                        "status": "completed",
                        "output": [{
                            "type": "message",
                            "content": [{
                                "type": "output_text",
                                "text": serde_json::to_string(&json!({
                                    "usable": true,
                                    "reason": "金额和唯一账户明确",
                                    "confidence": 0.98,
                                    "movement": {
                                        "type": "expense",
                                        "occurredAt": "2026-07-18T12:00:00+08:00",
                                        "title": "午餐",
                                        "accountId": "acct_ai_cash",
                                        "amount": "18",
                                        "currency": "CNY"
                                    }
                                })).expect("structured output")
                            }]
                        }]
                    }))
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("provider listener");
        let address = listener.local_addr().expect("provider address");
        let task = tokio::spawn(async move {
            axum::serve(listener, provider)
                .await
                .expect("provider server");
        });
        let config = AiProviderConfig {
            endpoint: format!("http://{address}/v1/responses"),
            api_key: "test-only-key".to_string(),
            model: "test-structured-model".to_string(),
        };
        let accounts = json!([{
            "id": "acct_ai_cash",
            "displayName": "日常账户",
            "accountType": "bank",
            "balanceMode": "cash_balance",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "status": "active",
            "cashBalances": [{"currency": "CNY", "amount": "100"}]
        }]);
        let enriched = organize_ai_text_with_provider(
            &config,
            json!({"text": "午餐 18 元"}),
            &accounts,
            "2026-07-18T12:30:00+08:00",
        )
        .await
        .expect("provider enrichment");
        assert_eq!(enriched["movement"]["type"], "expense");
        assert_eq!(enriched["movement"]["entries"][0]["amount"], "18");
        assert_eq!(enriched["movement"]["entries"][0]["direction"], "out");
        assert_eq!(enriched["_aiProvider"]["responseId"], "resp_test_ai_001");
        let request = captured.lock().expect("captured request").clone();
        assert_eq!(request["store"], false);
        assert_eq!(request["text"]["format"]["type"], "json_schema");
        assert_eq!(request["text"]["format"]["strict"], true);
        assert_eq!(
            request["text"]["format"]["schema"]["additionalProperties"],
            false
        );
        assert_eq!(
            request["text"]["format"]["schema"]["required"],
            json!(["usable", "reason", "confidence", "movement"])
        );
        assert!(
            !request["input"]
                .as_str()
                .expect("provider input")
                .contains("cashBalances")
        );
        task.abort();
    }

    #[tokio::test]
    async fn openai_responses_provider_organizes_validated_image_evidence() {
        let captured = Arc::new(Mutex::new(Value::Null));
        let captured_for_route = captured.clone();
        let provider = Router::new().route(
            "/v1/responses",
            post(move |Json(body): Json<Value>| {
                let captured = captured_for_route.clone();
                async move {
                    *captured.lock().expect("capture lock") = body;
                    Json(json!({
                        "id": "resp_test_image_001",
                        "status": "completed",
                        "output": [{
                            "type": "message",
                            "content": [{
                                "type": "output_text",
                                "text": serde_json::to_string(&json!({
                                    "usable": true,
                                    "reason": "票据金额和账户明确",
                                    "confidence": 0.96,
                                    "movement": {
                                        "type": "expense",
                                        "occurredAt": "2026-07-19T09:15:00+08:00",
                                        "title": "便利店",
                                        "accountId": "acct_ai_cash",
                                        "amount": "26.50",
                                        "currency": "CNY"
                                    }
                                })).expect("structured output")
                            }]
                        }]
                    }))
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("provider listener");
        let address = listener.local_addr().expect("provider address");
        let task = tokio::spawn(async move {
            axum::serve(listener, provider)
                .await
                .expect("provider server");
        });
        let config = AiProviderConfig {
            endpoint: format!("http://{address}/v1/responses"),
            api_key: "test-only-key".to_string(),
            model: "test-vision-model".to_string(),
        };
        let accounts = json!([{
            "id": "acct_ai_cash",
            "displayName": "日常账户",
            "accountType": "bank",
            "balanceMode": "cash_balance",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "status": "active",
            "cashBalances": [{"currency": "CNY", "amount": "100"}]
        }]);
        let png =
            STANDARD.encode(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01");
        let image_url = format!("data:image/png;base64,{png}");
        let enriched = organize_ai_image_with_provider(
            &config,
            json!({
                "fileName": "receipt.png",
                "mimeType": "image/png",
                "imageBase64": png
            }),
            image_url,
            &accounts,
            "2026-07-19T10:00:00+08:00",
        )
        .await
        .expect("image provider enrichment");
        assert_eq!(enriched["movement"]["type"], "expense");
        assert_eq!(enriched["movement"]["entries"][0]["amount"], "26.50");
        assert_eq!(enriched["_aiProvider"]["responseId"], "resp_test_image_001");
        assert_eq!(
            enriched["_aiProvider"]["promptVersion"],
            "finwealth_cash_movement_image_v1"
        );
        let request = captured.lock().expect("captured request").clone();
        assert_eq!(request["store"], false);
        assert_eq!(request["input"][0]["content"][1]["type"], "input_image");
        assert!(
            request["input"][0]["content"][1]["image_url"]
                .as_str()
                .expect("image data URL")
                .starts_with("data:image/png;base64,")
        );
        assert!(
            !request["input"][0]["content"][0]["text"]
                .as_str()
                .expect("provider context")
                .contains("cashBalances")
        );
        task.abort();
    }

    #[test]
    fn openai_responses_provider_detects_refusal_invalid_decimals_and_images() {
        let refusal = json!({
            "status": "completed",
            "output": [{"content": [{"type": "refusal", "refusal": "no"}]}]
        });
        let error = ai_structured_output(&refusal).expect_err("refusal should fail closed");
        assert_eq!(error.code, "ai_provider_refused");
        assert!(local_decimal_is_positive("18.25"));
        assert!(!local_decimal_is_positive("0"));
        assert!(!local_decimal_is_positive("1e3"));
        assert!(!local_decimal_is_positive("-1"));
        assert!(!local_decimal_is_positive("1.123456789"));
        let png =
            STANDARD.encode(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01");
        assert!(
            validated_ai_image_data_url(&json!({
                "fileName": "receipt.png",
                "mimeType": "image/png",
                "imageBase64": png
            }))
            .is_ok()
        );
        assert!(
            validated_ai_image_data_url(&json!({
                "fileName": "receipt.heic",
                "mimeType": "image/heic",
                "imageBase64": "AAAA"
            }))
            .is_err()
        );
        assert!(
            validated_ai_image_data_url(&json!({
                "fileName": "receipt.png",
                "mimeType": "image/png",
                "imageBase64": STANDARD.encode(b"not a png")
            }))
            .is_err()
        );
    }

    #[test]
    fn openai_responses_provider_configuration_is_explicit_and_tls_first() {
        assert!(
            ai_provider_config_from(None, None, None, None)
                .expect("private default")
                .is_none()
        );
        let official = ai_provider_config_from(
            Some("openai_responses"),
            Some("test-key"),
            Some("test-model"),
            None,
        )
        .expect("official config")
        .expect("enabled provider");
        assert_eq!(official.endpoint, "https://api.openai.com/v1/responses");
        assert!(
            ai_provider_config_from(
                Some("openai_responses"),
                Some("test-key"),
                Some("test-model"),
                Some("http://provider.example/v1"),
            )
            .is_err()
        );
        assert!(
            ai_provider_config_from(
                Some("openai_responses"),
                Some("test-key"),
                Some("test-model"),
                Some("http://127.0.0.1:9000/v1"),
            )
            .expect("loopback config")
            .is_some()
        );
        assert!(
            ai_provider_config_from(Some("openai_responses"), None, Some("test-model"), None,)
                .is_err()
        );
    }

    #[test]
    fn public_provider_maps_crypto_quotes_and_fiat_rates_without_fabrication() {
        let now = "2026-07-18T03:30:00Z";
        let prices = json!({
            "bitcoin": {"usd": 64000.0, "cny": 433000.0, "last_updated_at": 1784376947},
            "ethereum": {"usd": 1800.0, "cny": 12174.0, "last_updated_at": 1784376948},
            "tether": {"usd": 0.999, "cny": 6.77, "last_updated_at": 1784376935}
        });
        let quote = public_latest_quote(
            &json!({
                "instrumentId": "inst_btc_usdt",
                "symbol": "BTC-USDT",
                "quoteCurrency": "USDT"
            }),
            Some(&prices),
            now,
        )
        .expect("BTC/USDT quote should map");
        assert_eq!(quote["instrumentId"], "inst_btc_usdt");
        assert_eq!(quote["currency"], "USDT");
        assert_eq!(quote["source"], "coingecko");
        assert!(
            quote["price"]
                .as_str()
                .and_then(|value| value.parse::<f64>().ok())
                .is_some_and(|value| value > 64_000.0)
        );

        let stablecoin_rate = public_crypto_fx_rate(
            &json!({"baseCurrency": "USDT", "quoteCurrency": "USD"}),
            Some(&prices),
            now,
        )
        .expect("USDT/USD should map");
        assert_eq!(stablecoin_rate["rate"], "0.999");

        let fiat_rate = public_fiat_fx_rate_from_response(
            "USD",
            "CNY",
            &json!({"date": "2026-07-17", "rates": {"CNY": 6.7775}}),
        )
        .expect("USD/CNY should map");
        assert_eq!(fiat_rate["rate"], "6.7775");
        assert_eq!(fiat_rate["asOf"], "2026-07-17T00:00:00Z");
        assert_eq!(fiat_rate["source"], "frankfurter_ecb");
        assert_eq!(
            provider_decimal_string(1.234567891).expect("provider decimal"),
            "1.23456789"
        );
        assert!(provider_decimal_string(0.000000001).is_err());

        assert!(
            public_latest_quote(
                &json!({
                    "instrumentId": "inst_unknown",
                    "symbol": "UNKNOWN-USD",
                    "quoteCurrency": "USD"
                }),
                Some(&prices),
                now,
            )
            .is_err(),
            "unknown symbols must not receive a fabricated price"
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

        for rate in ["7.10", "7.20"] {
            let (status, body) = request_json_body_from(
                router.clone(),
                Method::POST,
                "/v1/quotes/refresh",
                json!({
                    "mode": "manual",
                    "fxRates": [{
                        "baseCurrency": "USD",
                        "quoteCurrency": "CNY",
                        "rate": rate,
                        "asOf": "2026-06-29T09:30:00Z",
                        "source": "history_test"
                    }]
                }),
            )
            .await;
            assert_eq!(status, StatusCode::OK, "{body}");
            assert_eq!(body["data"]["status"], "success");
        }
        let (_, historical_rates) =
            request_json_from(router.clone(), Method::GET, "/v1/fx-rates").await;
        assert_eq!(historical_rates["data"].as_array().expect("rates").len(), 2);
        let (_, account_with_latest_rate) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{account_id}"),
        )
        .await;
        assert_eq!(account_with_latest_rate["data"]["value"]["amount"], "72.00");

        let (invalid_time_status, invalid_time_body) = request_json_body_from(
            router,
            Method::POST,
            "/v1/quotes/refresh",
            json!({
                "mode": "manual",
                "fxRates": [{
                    "baseCurrency": "USD",
                    "quoteCurrency": "CNY",
                    "rate": "7.30",
                    "asOf": "not-a-time",
                    "source": "invalid_time_test"
                }]
            }),
        )
        .await;
        assert_eq!(invalid_time_status, StatusCode::OK, "{invalid_time_body}");
        assert_eq!(invalid_time_body["data"]["status"], "offline");
        assert!(
            invalid_time_body["data"]["errors"][0]["message"]
                .as_str()
                .is_some_and(|message| message.contains("RFC3339"))
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_multi_hop_fx_values_a_usdt_quoted_crypto_holding() {
        let path = unique_test_ledger_path("multi_hop_crypto_valuation");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (account_status, account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "OKX",
                "accountType": "exchange",
                "defaultCurrency": "USDT",
                "supportedCurrencies": ["USDT"],
                "includeInNetWorth": true,
                "balanceMode": "holdings",
                "openingBalances": []
            }),
        )
        .await;
        assert_eq!(account_status, StatusCode::CREATED, "{account_body}");
        let account_id = account_body["data"]["id"].as_str().expect("account id");

        let (instrument_status, instrument_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/instruments",
            json!({
                "id": "inst_btc_usdt_multihop",
                "type": "crypto",
                "symbol": "BTC-USDT",
                "displayName": "Bitcoin",
                "quoteCurrency": "USDT",
                "market": "CRYPTO"
            }),
        )
        .await;
        assert_eq!(instrument_status, StatusCode::CREATED, "{instrument_body}");

        let endpoint = format!("/v1/accounts/{account_id}/holding-adjustment-proposals");
        let (proposal_status, proposal_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &endpoint,
            json!({
                "instrumentId": "inst_btc_usdt_multihop",
                "targetQuantity": "0.05",
                "asOf": "2026-07-18T03:30:00Z"
            }),
        )
        .await;
        assert_eq!(proposal_status, StatusCode::OK, "{proposal_body}");
        let group_id = proposal_body["data"]["id"].as_str().expect("group id");
        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK, "{confirm_body}");

        let (missing_quote_status, missing_quote_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/portfolio/valuation-issues",
        )
        .await;
        assert_eq!(missing_quote_status, StatusCode::OK, "{missing_quote_body}");
        assert_eq!(missing_quote_body["data"][0]["accountName"], "OKX");
        assert_eq!(missing_quote_body["data"][0]["assetLabel"], "BTC");
        assert_eq!(missing_quote_body["data"][0]["quantity"], "0.05");
        assert_eq!(missing_quote_body["data"][0]["reason"], "missing_quote");

        let (refresh_status, refresh_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/quotes/refresh",
            json!({
                "mode": "manual",
                "quotes": [{
                    "instrumentId": "inst_btc_usdt_multihop",
                    "price": "100",
                    "currency": "USDT",
                    "asOf": "2026-07-18T03:30:00Z",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "source": "test"
                }]
            }),
        )
        .await;
        assert_eq!(refresh_status, StatusCode::OK, "{refresh_body}");
        assert_eq!(refresh_body["data"]["status"], "success");

        let (missing_fx_status, missing_fx_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/portfolio/valuation-issues",
        )
        .await;
        assert_eq!(missing_fx_status, StatusCode::OK, "{missing_fx_body}");
        assert_eq!(missing_fx_body["data"][0]["reason"], "missing_fx_path");
        assert_eq!(missing_fx_body["data"][0]["sourceCurrency"], "USDT");
        assert_eq!(missing_fx_body["data"][0]["targetCurrency"], "CNY");

        let (fx_refresh_status, fx_refresh_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/quotes/refresh",
            json!({
                "mode": "manual",
                "fxRates": [
                    {
                        "baseCurrency": "USDT",
                        "quoteCurrency": "USD",
                        "rate": "1",
                        "asOf": "2026-07-18T03:30:00Z",
                        "expiresAt": "2099-01-01T00:00:00Z",
                        "source": "test"
                    },
                    {
                        "baseCurrency": "USD",
                        "quoteCurrency": "CNY",
                        "rate": "7.2",
                        "asOf": "2026-07-18T03:30:00Z",
                        "expiresAt": "2099-01-01T00:00:00Z",
                        "source": "test"
                    }
                ]
            }),
        )
        .await;
        assert_eq!(fx_refresh_status, StatusCode::OK, "{fx_refresh_body}");
        assert_eq!(fx_refresh_body["data"]["status"], "success");

        let (valued_issues_status, valued_issues_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/portfolio/valuation-issues",
        )
        .await;
        assert_eq!(valued_issues_status, StatusCode::OK, "{valued_issues_body}");
        assert_eq!(valued_issues_body["data"], json!([]));

        let (holdings_status, holdings_body) =
            request_json_from(router.clone(), Method::GET, "/v1/holdings").await;
        assert_eq!(holdings_status, StatusCode::OK, "{holdings_body}");
        assert_eq!(holdings_body["data"][0]["quantity"], "0.05");
        assert_eq!(holdings_body["data"][0]["marketValue"]["amount"], "36.00");
        assert_eq!(holdings_body["data"][0]["marketValue"]["currency"], "CNY");
        assert_eq!(holdings_body["data"][0]["quoteStatus"], "fresh");

        let (account_after_status, account_after_body) =
            request_json_from(router, Method::GET, &format!("/v1/accounts/{account_id}")).await;
        assert_eq!(account_after_status, StatusCode::OK, "{account_after_body}");
        assert_eq!(account_after_body["data"]["value"]["amount"], "36.00");
        assert_eq!(account_after_body["data"]["value"]["currency"], "CNY");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_quote_problem_count_includes_stale_fx_valuation() {
        let path = unique_test_ledger_path("stale_fx_problem_count");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (account_status, account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "外币账户",
                "accountType": "wallet",
                "defaultCurrency": "USD",
                "supportedCurrencies": ["USD"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [{"currency": "USD", "amount": "10.00"}]
            }),
        )
        .await;
        assert_eq!(account_status, StatusCode::CREATED, "{account_body}");

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
                    "asOf": "2026-07-01T00:00:00Z",
                    "expiresAt": "2026-07-02T00:00:00Z",
                    "source": "stale_test"
                }]
            }),
        )
        .await;
        assert_eq!(refresh_status, StatusCode::OK, "{refresh_body}");

        let (overview_status, overview_body) =
            request_json_from(router.clone(), Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_status, StatusCode::OK, "{overview_body}");
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["quoteStatusSummary"]["staleCount"],
            1
        );
        assert_eq!(
            overview_body["data"]["pendingSummary"]["quoteProblemCount"], 1,
            "a stale valuation still needs the compact quote-status entry"
        );

        let (issues_status, issues_body) =
            request_json_from(router, Method::GET, "/v1/portfolio/valuation-issues").await;
        assert_eq!(issues_status, StatusCode::OK, "{issues_body}");
        assert_eq!(issues_body["data"].as_array().expect("issues").len(), 1);
        assert_eq!(issues_body["data"][0]["assetKind"], "cash");
        assert_eq!(issues_body["data"][0]["assetLabel"], "USD");
        assert_eq!(issues_body["data"][0]["quantity"], "10.00");
        assert_eq!(issues_body["data"][0]["status"], "stale");
        assert_eq!(issues_body["data"][0]["reason"], "stale_fx");

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

        let execution_input = json!({
            "holdingAccountId": account_id,
            "quantity": "10",
            "totalCost": {"amount": "200.00", "currency": "CNY"},
            "quoteCurrency": "CNY",
            "executedAt": "2026-07-15T10:30:00Z"
        });
        for invalid_input in [
            json!({}),
            json!({
                "holdingAccountId": account_id,
                "quantity": "0",
                "totalCost": {"amount": "200.00", "currency": "CNY"},
                "quoteCurrency": "CNY"
            }),
            json!({
                "holdingAccountId": account_id,
                "quantity": "10",
                "totalCost": {"amount": "200.00", "currency": "USD"},
                "quoteCurrency": "CNY"
            }),
            json!({
                "holdingAccountId": account_id,
                "quantity": "10",
                "totalCost": {"amount": "200.00", "currency": "CNY"},
                "quoteCurrency": "USD"
            }),
            json!({
                "holdingAccountId": account_id,
                "quantity": "10",
                "totalCost": {"amount": "200.00", "currency": "CNY"},
                "quoteCurrency": "CNY",
                "unexpected": true
            }),
        ] {
            let (invalid_status, invalid_body) = request_json_body_from(
                router.clone(),
                Method::POST,
                &format!("/v1/dca/reminders/{reminder_id}/mark-executed-as-proposal"),
                invalid_input,
            )
            .await;
            assert_eq!(invalid_status, StatusCode::BAD_REQUEST, "{invalid_body}");
        }

        let idempotency_key = "dca-execution-retry";
        let (mark_status, mark_headers, mark_body) = request_json_body_with_idempotency_from(
            router.clone(),
            Method::POST,
            &format!("/v1/dca/reminders/{reminder_id}/mark-executed-as-proposal"),
            execution_input.clone(),
            Some(idempotency_key),
        )
        .await;
        assert_eq!(mark_status, StatusCode::OK);
        assert!(mark_headers.get("idempotency-replayed").is_none());
        assert_eq!(mark_body["data"]["status"], "pending");
        assert_eq!(
            mark_body["data"]["proposedMovements"][0]["status"],
            "pending_review"
        );
        let atomic_group_id = mark_body["data"]["id"]
            .as_str()
            .expect("atomic group id should be string")
            .to_string();
        assert_eq!(
            mark_body["data"]["proposedMovements"][0]["entries"][0]["amount"],
            "200.00"
        );
        assert_eq!(
            mark_body["data"]["proposedMovements"][0]["entries"][1]["amount"],
            "10"
        );
        assert_eq!(
            mark_body["data"]["proposedMovements"][0]["occurredAt"],
            "2026-07-15T10:30:00Z"
        );

        let (replay_status, replay_headers, replay_body) = request_json_body_with_idempotency_from(
            router.clone(),
            Method::POST,
            &format!("/v1/dca/reminders/{reminder_id}/mark-executed-as-proposal"),
            execution_input.clone(),
            Some(idempotency_key),
        )
        .await;
        assert_eq!(replay_status, StatusCode::OK, "{replay_body}");
        assert_eq!(replay_body, mark_body);
        assert_eq!(
            replay_headers
                .get("idempotency-replayed")
                .and_then(|value| value.to_str().ok()),
            Some("true")
        );

        let (duplicate_status, duplicate_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            &format!("/v1/dca/reminders/{reminder_id}/mark-executed-as-proposal"),
            execution_input,
        )
        .await;
        assert_eq!(duplicate_status, StatusCode::CONFLICT, "{duplicate_body}");

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
        assert_eq!(persisted["holdings"][0]["quantity"], "10");
        assert_eq!(
            persisted["holdings"][0]["costBasisTotal"]["amount"],
            "200.00"
        );

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
    async fn local_ledger_integrity_failures_return_400_without_changing_the_document() {
        let path = unique_test_ledger_path("integrity_fail_closed");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let unchanged_empty = std::fs::read(&path).expect("empty ledger should be readable");
        let (parent_status, parent_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/categories",
            json!({
                "displayName": "悬空分类",
                "kind": "expense",
                "parentId": "cat_missing"
            }),
        )
        .await;
        assert_eq!(parent_status, StatusCode::BAD_REQUEST, "{parent_body}");
        assert_eq!(parent_body["error"]["code"], "invalid_category_input");
        assert_eq!(
            std::fs::read(&path).expect("ledger should remain readable"),
            unchanged_empty
        );

        let (hint_status, hint_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/counterparties",
            json!({
                "displayName": "悬空对手方",
                "aliases": [],
                "categoryHintId": "cat_missing"
            }),
        )
        .await;
        assert_eq!(hint_status, StatusCode::BAD_REQUEST, "{hint_body}");
        assert_eq!(hint_body["error"]["code"], "invalid_counterparty_input");
        assert_eq!(
            std::fs::read(&path).expect("ledger should remain readable"),
            unchanged_empty
        );

        let (instrument_status, instrument_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/instruments",
            json!({
                "id": "inst_integrity",
                "type": "equity",
                "symbol": "SAFE",
                "displayName": "Integrity Equity",
                "quoteCurrency": "USD",
                "market": "US"
            }),
        )
        .await;
        assert_eq!(instrument_status, StatusCode::CREATED, "{instrument_body}");

        let before_invalid_quote = std::fs::read(&path).expect("ledger should be readable");
        let (quote_status, quote_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/quotes/refresh",
            json!({
                "mode": "manual",
                "quotes": [{
                    "instrumentId": "inst_integrity",
                    "price": "12.34",
                    "currency": "CNY",
                    "asOf": "2026-07-17T00:00:00Z",
                    "source": "integrity_test"
                }]
            }),
        )
        .await;
        assert_eq!(quote_status, StatusCode::BAD_REQUEST, "{quote_body}");
        assert_eq!(
            std::fs::read(&path).expect("ledger should remain readable"),
            before_invalid_quote
        );

        let (valid_quote_status, valid_quote_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/quotes/refresh",
            json!({
                "mode": "manual",
                "quotes": [{
                    "instrumentId": "inst_integrity",
                    "price": "12.34",
                    "currency": "USD",
                    "asOf": "2026-07-17T00:00:00Z",
                    "source": "integrity_test"
                }]
            }),
        )
        .await;
        assert_eq!(valid_quote_status, StatusCode::OK, "{valid_quote_body}");

        let before_invalid_patch = std::fs::read(&path).expect("ledger should be readable");
        let (patch_status, patch_body) = request_json_body_from(
            router,
            Method::PATCH,
            "/v1/instruments/inst_integrity",
            json!({"quoteCurrency": "CNY"}),
        )
        .await;
        assert_eq!(patch_status, StatusCode::BAD_REQUEST, "{patch_body}");
        assert_eq!(patch_body["error"]["code"], "invalid_instrument_patch");
        assert_eq!(
            std::fs::read(&path).expect("ledger should remain readable"),
            before_invalid_patch
        );

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
        let correction_movement_id = confirm_correction_body["data"]["confirmedMovementIds"][0]
            .as_str()
            .expect("correction movement id should be string")
            .to_string();

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
        let movement_changes = persisted["syncChanges"]
            .as_array()
            .expect("syncChanges should be an array")
            .iter()
            .filter(|change| change["entityType"] == "movement")
            .collect::<Vec<_>>();
        assert_eq!(movement_changes.len(), 2);
        assert_eq!(movement_changes[0]["operation"], "create");
        assert_eq!(movement_changes[0]["entityId"], original_movement_id);
        assert_eq!(movement_changes[1]["operation"], "correction");
        assert_eq!(movement_changes[1]["entityId"], correction_movement_id);
        assert_eq!(movement_changes[1]["payload"]["type"], "correction");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn local_ledger_multileg_correction_replaces_transfer_effect_atomically() {
        let path = unique_test_ledger_path("multileg_correction");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        async fn create_account_with_balance(router: Router, name: &str, amount: &str) -> String {
            let (status, body) = request_json_body_from(
                router,
                Method::POST,
                "/v1/accounts",
                json!({
                    "displayName": name,
                    "accountType": "bank",
                    "defaultCurrency": "CNY",
                    "supportedCurrencies": ["CNY"],
                    "includeInNetWorth": true,
                    "balanceMode": "cash_balance",
                    "openingBalances": [{"currency": "CNY", "amount": amount}]
                }),
            )
            .await;
            assert_eq!(status, StatusCode::CREATED, "{body}");
            body["data"]["id"].as_str().expect("account id").to_string()
        }

        let source_id = create_account_with_balance(router.clone(), "转出账户", "100.00").await;
        let destination_id = create_account_with_balance(router.clone(), "转入账户", "0.00").await;
        let (draft_status, draft_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            json!({
                "type": "transfer",
                "occurredAt": "2026-07-13T12:00:00+08:00",
                "title": "账户调拨",
                "entries": [
                    {
                        "accountId": source_id,
                        "amount": "40.00",
                        "currency": "CNY",
                        "direction": "out",
                        "role": "source"
                    },
                    {
                        "accountId": destination_id,
                        "amount": "40.00",
                        "currency": "CNY",
                        "direction": "in",
                        "role": "destination"
                    }
                ]
            }),
        )
        .await;
        assert_eq!(draft_status, StatusCode::CREATED, "{draft_body}");
        let original_movement_id = draft_body["data"]["id"]
            .as_str()
            .expect("movement id")
            .to_string();
        let original_group_id = draft_body["data"]["atomicGroupId"]
            .as_str()
            .expect("group id")
            .to_string();
        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{original_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK, "{confirm_body}");

        let (noop_status, noop_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/corrections",
            json!({
                "targetMovementId": original_movement_id,
                "reason": "没有实际变化",
                "replacementEntries": [
                    {
                        "accountId": source_id,
                        "amount": "40.00",
                        "currency": "CNY",
                        "direction": "out",
                        "role": "source"
                    },
                    {
                        "accountId": destination_id,
                        "amount": "40.00",
                        "currency": "CNY",
                        "direction": "in",
                        "role": "destination"
                    }
                ]
            }),
        )
        .await;
        assert_eq!(noop_status, StatusCode::BAD_REQUEST, "{noop_body}");
        assert_eq!(noop_body["error"]["code"], "invalid_correction_input");

        let (correction_status, correction_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/corrections",
            json!({
                "targetMovementId": original_movement_id,
                "reason": "实际只转了 25 元",
                "replacementEntries": [
                    {
                        "accountId": source_id,
                        "amount": "25.00",
                        "currency": "CNY",
                        "direction": "out",
                        "role": "source"
                    },
                    {
                        "accountId": destination_id,
                        "amount": "25.00",
                        "currency": "CNY",
                        "direction": "in",
                        "role": "destination"
                    }
                ]
            }),
        )
        .await;
        assert_eq!(correction_status, StatusCode::OK, "{correction_body}");
        assert_eq!(correction_body["data"]["operation"], "correction");
        assert_eq!(
            correction_body["data"]["proposedMovements"][0]["entries"]
                .as_array()
                .expect("correction entries")
                .len(),
            4
        );

        let (duplicate_status, duplicate_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/corrections",
            json!({
                "targetMovementId": original_movement_id,
                "reason": "重复候选",
                "replacementEntries": [
                    {
                        "accountId": source_id,
                        "amount": "20.00",
                        "currency": "CNY",
                        "direction": "out",
                        "role": "source"
                    },
                    {
                        "accountId": destination_id,
                        "amount": "20.00",
                        "currency": "CNY",
                        "direction": "in",
                        "role": "destination"
                    }
                ]
            }),
        )
        .await;
        assert_eq!(duplicate_status, StatusCode::CONFLICT, "{duplicate_body}");
        assert_eq!(duplicate_body["error"]["code"], "local_ledger_conflict");

        for (account_id, expected) in [(&source_id, "60.00"), (&destination_id, "40.00")] {
            let (status, body) = request_json_from(
                router.clone(),
                Method::GET,
                &format!("/v1/accounts/{account_id}"),
            )
            .await;
            assert_eq!(status, StatusCode::OK, "{body}");
            assert_eq!(body["data"]["value"]["amount"], expected);
        }

        let correction_group_id = correction_body["data"]["id"]
            .as_str()
            .expect("correction group id");
        let (confirm_correction_status, confirm_correction_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{correction_group_id}/confirm"),
        )
        .await;
        assert_eq!(
            confirm_correction_status,
            StatusCode::OK,
            "{confirm_correction_body}"
        );

        for (account_id, expected) in [(&source_id, "75.00"), (&destination_id, "25.00")] {
            let (status, body) = request_json_from(
                router.clone(),
                Method::GET,
                &format!("/v1/accounts/{account_id}"),
            )
            .await;
            assert_eq!(status, StatusCode::OK, "{body}");
            assert_eq!(body["data"]["value"]["amount"], expected);
        }

        let (original_status, original_body) = request_json_from(
            router,
            Method::GET,
            &format!("/v1/movements/{original_movement_id}"),
        )
        .await;
        assert_eq!(original_status, StatusCode::OK, "{original_body}");
        assert_eq!(
            original_body["data"]["entries"]
                .as_array()
                .expect("original entries")
                .len(),
            2
        );
        assert_eq!(original_body["data"]["entries"][0]["amount"], "40.00");
        assert_eq!(original_body["data"]["entries"][1]["amount"], "40.00");

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
    async fn movement_and_snapshot_queries_apply_documented_filters_and_ordering() {
        let path = unique_test_ledger_path("movement_snapshot_queries");
        let mut document = local_ledger::empty_document("CNY");
        document["accounts"] = json!([{
            "id": "acct_query",
            "displayName": "查询测试账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "visibility": "normal",
            "status": "active",
            "balanceMode": "cash_balance",
            "cashBalances": [{
                "currency": "CNY",
                "amount": "100.00",
                "asOf": "2026-01-01T00:00:00Z",
                "quality": "exact"
            }],
            "tags": [],
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z"
        }]);
        document["movements"] = json!([
            {
                "id": "mov_query_1",
                "atomicGroupId": "ag_query_1",
                "type": "expense",
                "occurredAt": "2026-01-01T08:00:00Z",
                "recordedAt": "2026-01-01T09:00:00Z",
                "status": "confirmed",
                "title": "old confirmed",
                "entries": [{
                    "id": "entry_query_1",
                    "accountId": "acct_query",
                    "amount": "1.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                }],
                "tags": [],
                "settlement": {"status": "settled"},
                "source": {"kind": "manual", "createdBy": "user"},
                "createdAt": "2026-01-01T09:00:00Z",
                "updatedAt": "2026-01-01T09:00:00Z"
            },
            {
                "id": "mov_query_2",
                "atomicGroupId": "ag_query_2",
                "type": "expense",
                "occurredAt": "2026-01-03T08:00:00Z",
                "recordedAt": "2026-01-03T09:00:00Z",
                "status": "pending_review",
                "title": "new pending",
                "entries": [{
                    "id": "entry_query_2",
                    "accountId": "acct_query",
                    "amount": "2.00",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                }],
                "tags": [],
                "settlement": {"status": "settled"},
                "source": {"kind": "manual", "createdBy": "user"},
                "createdAt": "2026-01-03T09:00:00Z",
                "updatedAt": "2026-01-03T09:00:00Z"
            },
            {
                "id": "mov_query_3",
                "atomicGroupId": "ag_query_3",
                "type": "income",
                "occurredAt": "2026-01-02T08:00:00Z",
                "recordedAt": "2026-01-02T09:00:00Z",
                "status": "confirmed",
                "title": "middle confirmed",
                "entries": [{
                    "id": "entry_query_3",
                    "accountId": "acct_query",
                    "amount": "3.00",
                    "currency": "CNY",
                    "direction": "in",
                    "role": "source"
                }],
                "tags": [],
                "settlement": {"status": "settled"},
                "source": {"kind": "manual", "createdBy": "user"},
                "createdAt": "2026-01-02T09:00:00Z",
                "updatedAt": "2026-01-02T09:00:00Z"
            }
        ]);
        document["movementEntries"] = json!([
            {
                "id": "entry_query_1",
                "movementId": "mov_query_1",
                "atomicGroupId": "ag_query_1",
                "accountId": "acct_query",
                "amount": "1.00",
                "currency": "CNY",
                "direction": "out",
                "role": "source"
            },
            {
                "id": "entry_query_2",
                "movementId": "mov_query_2",
                "atomicGroupId": "ag_query_2",
                "accountId": "acct_query",
                "amount": "2.00",
                "currency": "CNY",
                "direction": "out",
                "role": "source"
            },
            {
                "id": "entry_query_3",
                "movementId": "mov_query_3",
                "atomicGroupId": "ag_query_3",
                "accountId": "acct_query",
                "amount": "3.00",
                "currency": "CNY",
                "direction": "in",
                "role": "source"
            }
        ]);
        document["snapshots"] = json!([
            {"id": "snap_query_1", "snapshotAt": "2026-01-01T00:00:00Z"},
            {"id": "snap_query_2", "snapshotAt": "2026-01-02T00:00:00Z"},
            {"id": "snap_query_3", "snapshotAt": "2026-01-03T00:00:00Z"}
        ]);
        local_ledger::write_document(&path, &document).expect("query fixture should persist");
        let router = app_with_state(AppState::local(path.clone()));

        let (filtered_status, filtered_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/movements?status=confirmed&limit=1",
        )
        .await;
        assert_eq!(filtered_status, StatusCode::OK);
        assert_eq!(
            filtered_body["data"].as_array().expect("movements").len(),
            1
        );
        assert_eq!(filtered_body["data"][0]["id"], "mov_query_1");

        let (recent_status, recent_body) =
            request_json_from(router.clone(), Method::GET, "/v1/movements/recent?limit=2").await;
        assert_eq!(recent_status, StatusCode::OK);
        assert_eq!(recent_body["data"][0]["id"], "mov_query_2");
        assert_eq!(recent_body["data"][1]["id"], "mov_query_3");

        for uri in [
            "/v1/movements?limit=0",
            "/v1/movements?limit=201",
            "/v1/movements?limit=many",
            "/v1/movements?status=unknown",
        ] {
            let (status, body) = request_json_from(router.clone(), Method::GET, uri).await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{uri}");
            assert_eq!(body["error"]["code"], "invalid_movement_query", "{uri}");
        }

        let (snapshots_status, snapshots_body) =
            request_json_from(router.clone(), Method::GET, "/v1/snapshots").await;
        assert_eq!(snapshots_status, StatusCode::OK);
        assert_eq!(snapshots_body["data"][0]["id"], "snap_query_3");
        assert_eq!(snapshots_body["data"][2]["id"], "snap_query_1");

        let (range_status, range_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/snapshots?from=2026-01-02&to=2026-01-02",
        )
        .await;
        assert_eq!(range_status, StatusCode::OK);
        assert_eq!(
            range_body["data"],
            json!([{"id": "snap_query_2", "snapshotAt": "2026-01-02T00:00:00Z"}])
        );

        for uri in [
            "/v1/snapshots?from=2026-01-01",
            "/v1/snapshots?to=2026-01-03",
            "/v1/snapshots?from=2026-02-01&to=2026-01-01",
            "/v1/snapshots?from=not-a-date&to=2026-01-01",
        ] {
            let (status, body) = request_json_from(router.clone(), Method::GET, uri).await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{uri}");
            assert_eq!(body["error"]["code"], "invalid_snapshot_range", "{uri}");
        }

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
    async fn local_ledger_rejects_decimal_amounts_over_eight_places() {
        let path = unique_test_ledger_path("decimal_scale");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let invalid_account = json!({
            "displayName": "高精度账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "1.123456789"}
            ]
        });
        let (account_status, account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            invalid_account,
        )
        .await;
        assert_eq!(account_status, StatusCode::BAD_REQUEST);
        assert_eq!(account_body["error"]["code"], "invalid_account_input");

        let valid_account = json!({
            "displayName": "有效账户",
            "accountType": "bank",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": true,
            "balanceMode": "cash_balance",
            "openingBalances": [
                {"currency": "CNY", "amount": "10.12345678"}
            ]
        });
        let (create_status, create_body) =
            request_json_body_from(router.clone(), Method::POST, "/v1/accounts", valid_account)
                .await;
        assert_eq!(create_status, StatusCode::CREATED);
        let account_id = create_body["data"]["id"]
            .as_str()
            .expect("created account id should be string")
            .to_string();

        let invalid_draft = json!({
            "type": "expense",
            "occurredAt": "2026-06-26T10:00:00+08:00",
            "title": "高精度支出",
            "entries": [
                {
                    "accountId": account_id,
                    "amount": "1.123456789",
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
            invalid_draft,
        )
        .await;
        assert_eq!(draft_status, StatusCode::BAD_REQUEST);
        assert_eq!(draft_body["error"]["code"], "invalid_movement_draft_input");

        let valid_draft = json!({
            "type": "expense",
            "occurredAt": "2026-06-26T10:01:00+08:00",
            "title": "八位小数支出",
            "entries": [
                {
                    "accountId": account_id,
                    "amount": "0.00000001",
                    "currency": "CNY",
                    "direction": "out",
                    "role": "source"
                }
            ]
        });
        let (valid_status, valid_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/movements/drafts",
            valid_draft,
        )
        .await;
        assert_eq!(valid_status, StatusCode::CREATED, "{valid_body}");
        let valid_group = valid_body["data"]["atomicGroupId"]
            .as_str()
            .expect("valid decimal atomic group");
        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{valid_group}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK, "{confirm_body}");
        let (_, account_after) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{account_id}"),
        )
        .await;
        assert_eq!(
            account_after["data"]["cashBalances"][0]["amount"],
            "10.12345677"
        );

        let (overview_status, overview_body) =
            request_json_from(router, Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview_status, StatusCode::OK);
        assert_eq!(
            overview_body["data"]["latestSnapshot"]["netWorth"]["amount"],
            "10.12345677"
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn subscriptions_schedule_foreign_currency_charges_without_writing_before_confirmation() {
        let path = unique_test_ledger_path("subscription_charge_flow");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (account_status, account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "美元信用卡",
                "accountType": "credit_card",
                "defaultCurrency": "USD",
                "supportedCurrencies": ["USD"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [{"currency": "USD", "amount": "100.00"}]
            }),
        )
        .await;
        assert_eq!(account_status, StatusCode::CREATED);
        let account_id = account_body["data"]["id"]
            .as_str()
            .expect("account id")
            .to_string();

        let (create_status, create_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/subscriptions",
            json!({
                "displayName": "ChatGPT Plus",
                "provider": "OpenAI",
                "planName": "Plus",
                "amount": {"amount": "20.00", "currency": "USD"},
                "paymentAccountId": account_id,
                "billingCycle": {"unit": "month", "interval": 1},
                "startDate": "2026-01-31",
                "duration": {"unit": "month", "count": 3},
                "reminderDaysBefore": 3,
                "autoRenew": false
            }),
        )
        .await;
        assert_eq!(create_status, StatusCode::CREATED, "{create_body}");
        let subscription_id = create_body["data"]["id"]
            .as_str()
            .expect("subscription id")
            .to_string();
        assert_eq!(create_body["data"]["amount"]["currency"], "USD");
        assert_eq!(create_body["data"]["billingAnchorDay"], 31);
        assert_eq!(create_body["data"]["endDate"], "2026-04-29");
        assert_eq!(create_body["data"]["nextChargeDate"], "2026-01-31");

        let (upcoming_status, upcoming_body) = request_json_from(
            router.clone(),
            Method::GET,
            "/v1/subscriptions/upcoming?days=365",
        )
        .await;
        assert_eq!(upcoming_status, StatusCode::OK);
        assert_eq!(upcoming_body["data"][0]["id"], subscription_id);

        let charge_uri = format!("/v1/subscriptions/{subscription_id}/charge-proposal");
        let (proposal_status, proposal_body) =
            request_json_from(router.clone(), Method::POST, &charge_uri).await;
        assert_eq!(proposal_status, StatusCode::CREATED, "{proposal_body}");
        assert_eq!(proposal_body["data"]["status"], "pending");
        assert_eq!(
            proposal_body["data"]["proposedMovements"][0]["displayAmount"]["amount"],
            "20.00"
        );
        let atomic_group_id = proposal_body["data"]["id"]
            .as_str()
            .expect("atomic group id")
            .to_string();

        let (account_before_status, account_before_body) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/accounts/{account_id}"),
        )
        .await;
        assert_eq!(account_before_status, StatusCode::OK);
        assert_eq!(account_before_body["data"]["value"]["amount"], "100.00");

        let (duplicate_status, duplicate_body) =
            request_json_from(router.clone(), Method::POST, &charge_uri).await;
        assert_eq!(duplicate_status, StatusCode::CONFLICT, "{duplicate_body}");

        let (confirm_status, confirm_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{atomic_group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK, "{confirm_body}");
        assert_eq!(confirm_body["data"]["ledgerWrite"], true);

        let (first_detail_status, first_detail) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/subscriptions/{subscription_id}"),
        )
        .await;
        assert_eq!(first_detail_status, StatusCode::OK);
        assert_eq!(first_detail["data"]["lastChargeDate"], "2026-01-31");
        assert_eq!(first_detail["data"]["nextChargeDate"], "2026-02-28");

        let (second_status, second_body) =
            request_json_from(router.clone(), Method::POST, &charge_uri).await;
        assert_eq!(second_status, StatusCode::CREATED);
        let second_group = second_body["data"]["id"].as_str().expect("second group");
        let (second_confirm_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{second_group}/confirm"),
        )
        .await;
        assert_eq!(second_confirm_status, StatusCode::OK);
        let (_, second_detail) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/subscriptions/{subscription_id}"),
        )
        .await;
        assert_eq!(second_detail["data"]["nextChargeDate"], "2026-03-31");

        let (third_status, third_body) =
            request_json_from(router.clone(), Method::POST, &charge_uri).await;
        assert_eq!(third_status, StatusCode::CREATED);
        let third_group = third_body["data"]["id"].as_str().expect("third group");
        let (reject_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{third_group}/reject"),
        )
        .await;
        assert_eq!(reject_status, StatusCode::NO_CONTENT);
        let (_, rejected_detail) = request_json_from(
            router.clone(),
            Method::GET,
            &format!("/v1/subscriptions/{subscription_id}"),
        )
        .await;
        assert_eq!(rejected_detail["data"]["nextChargeDate"], "2026-03-31");
        assert!(
            rejected_detail["data"]
                .get("pendingChargeMovementId")
                .is_none()
        );

        let (cancel_status, cancel_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/subscriptions/{subscription_id}/cancel"),
        )
        .await;
        assert_eq!(cancel_status, StatusCode::OK);
        assert_eq!(cancel_body["data"]["status"], "cancelled");
        assert_eq!(cancel_body["data"]["nextChargeDate"], Value::Null);

        let (account_after_status, account_after_body) =
            request_json_from(router, Method::GET, &format!("/v1/accounts/{account_id}")).await;
        assert_eq!(account_after_status, StatusCode::OK);
        assert_eq!(account_after_body["data"]["value"]["amount"], "60.00");

        let document = local_ledger::read_document(&path).expect("subscription should persist");
        assert!(
            document["syncChanges"]
                .as_array()
                .expect("sync log")
                .iter()
                .any(|change| change["entityType"] == "subscription")
        );
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn standalone_subscription_charge_is_discoverable_in_ai_review_after_restart() {
        let path = unique_test_ledger_path("subscription_ai_review_discovery");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));
        let (_, account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "Review USD card",
                "accountType": "virtual_card",
                "defaultCurrency": "USD",
                "supportedCurrencies": ["USD"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [{"currency": "USD", "amount": "100.00"}]
            }),
        )
        .await;
        let account_id = account_body["data"]["id"].as_str().expect("account id");
        let subscription_id = create_test_subscription(
            router.clone(),
            account_id,
            "Discoverable subscription",
            "2026-01-31",
            "active",
        )
        .await;
        let (proposal_status, proposal_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/subscriptions/{subscription_id}/charge-proposal"),
        )
        .await;
        assert_eq!(proposal_status, StatusCode::CREATED, "{proposal_body}");
        let group_id = proposal_body["data"]["id"]
            .as_str()
            .expect("atomic group id")
            .to_string();

        let restarted_router = app_with_state(AppState::local(path.clone()));
        let (pending_status, pending_body) = request_json_from(
            restarted_router.clone(),
            Method::GET,
            "/v1/ai/proposals/pending",
        )
        .await;
        assert_eq!(pending_status, StatusCode::OK);
        let proposals = pending_body["data"].as_array().expect("pending proposals");
        let proposal = proposals
            .iter()
            .find(|proposal| {
                proposal["atomicGroups"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|group| group["id"] == group_id)
            })
            .expect("subscription proposal should remain discoverable after restart");
        let proposal_id = proposal["id"].as_str().expect("synthetic proposal id");

        let (detail_status, detail_body) = request_json_from(
            restarted_router.clone(),
            Method::GET,
            &format!("/v1/ai/proposals/{proposal_id}"),
        )
        .await;
        assert_eq!(detail_status, StatusCode::OK, "{detail_body}");
        assert_eq!(detail_body["data"], *proposal);

        let (edit_status, edit_body) = request_json_body_from(
            restarted_router.clone(),
            Method::POST,
            &format!("/v1/ai/atomic-groups/{group_id}/edit"),
            json!({
                "type": "expense",
                "occurredAt": "2026-01-31T00:00:00Z",
                "title": "Must reject and regenerate",
                "entries": []
            }),
        )
        .await;
        assert_eq!(edit_status, StatusCode::CONFLICT, "{edit_body}");

        let (reject_status, _) = request_json_from(
            restarted_router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{group_id}/reject"),
        )
        .await;
        assert_eq!(reject_status, StatusCode::NO_CONTENT);
        let (_, after_reject) = request_json_from(
            restarted_router.clone(),
            Method::GET,
            "/v1/ai/proposals/pending",
        )
        .await;
        assert!(
            after_reject["data"]
                .as_array()
                .expect("pending proposals")
                .iter()
                .all(|proposal| {
                    proposal["atomicGroups"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .all(|group| group["id"] != group_id)
                })
        );
        let (_, overview) =
            request_json_from(restarted_router, Method::GET, "/v1/portfolio/overview").await;
        assert_eq!(overview["data"]["pendingSummary"]["aiPendingCount"], 0);

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn subscription_due_scan_is_bounded_idempotent_and_never_auto_confirms() {
        let (unmounted_status, _) = request_json_body_from(
            app(),
            Method::POST,
            "/v1/subscriptions/charge-proposals/due-scan",
            json!({"throughDate": "2026-07-13"}),
        )
        .await;
        assert_eq!(unmounted_status, StatusCode::NOT_IMPLEMENTED);

        let path = unique_test_ledger_path("subscription_due_scan");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (_, account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "Primary USD card",
                "accountType": "virtual_card",
                "defaultCurrency": "USD",
                "supportedCurrencies": ["USD"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [{"currency": "USD", "amount": "100.00"}]
            }),
        )
        .await;
        let account_id = account_body["data"]["id"]
            .as_str()
            .expect("primary account id")
            .to_string();
        let (_, blocked_account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "Archived USD card",
                "accountType": "virtual_card",
                "defaultCurrency": "USD",
                "supportedCurrencies": ["USD"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [{"currency": "USD", "amount": "50.00"}]
            }),
        )
        .await;
        let blocked_account_id = blocked_account_body["data"]["id"]
            .as_str()
            .expect("blocked account id")
            .to_string();
        let (_, currency_account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "Multi-currency card",
                "accountType": "virtual_card",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY", "USD"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [{"currency": "CNY", "amount": "100.00"}]
            }),
        )
        .await;
        let currency_account_id = currency_account_body["data"]["id"]
            .as_str()
            .expect("currency account id")
            .to_string();

        let blocked_id = create_test_subscription(
            router.clone(),
            &blocked_account_id,
            "Blocked due",
            "2026-01-10",
            "active",
        )
        .await;
        let pending_id = create_test_subscription(
            router.clone(),
            &account_id,
            "Already pending",
            "2026-01-15",
            "active",
        )
        .await;
        let currency_blocked_id = create_test_subscription(
            router.clone(),
            &currency_account_id,
            "Unsupported currency",
            "2026-01-20",
            "active",
        )
        .await;
        let first_due_id = create_test_subscription(
            router.clone(),
            &account_id,
            "First due",
            "2026-01-31",
            "active",
        )
        .await;
        let second_due_id = create_test_subscription(
            router.clone(),
            &account_id,
            "Second due",
            "2026-01-31",
            "trial",
        )
        .await;
        let paused_id = create_test_subscription(
            router.clone(),
            &account_id,
            "Paused due",
            "2026-01-05",
            "paused",
        )
        .await;
        let future_id = create_test_subscription(
            router.clone(),
            &account_id,
            "Future charge",
            "2026-08-01",
            "active",
        )
        .await;

        let (archive_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/accounts/{blocked_account_id}/archive"),
        )
        .await;
        assert_eq!(archive_status, StatusCode::OK);
        let (pending_status, _) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/subscriptions/{pending_id}/charge-proposal"),
        )
        .await;
        assert_eq!(pending_status, StatusCode::CREATED);
        let (currency_patch_status, currency_patch_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/accounts/{currency_account_id}"),
            json!({"supportedCurrencies": ["CNY"]}),
        )
        .await;
        assert_eq!(
            currency_patch_status,
            StatusCode::OK,
            "{currency_patch_body}"
        );
        let (blocked_single_status, blocked_single_body) = request_json_from(
            router.clone(),
            Method::POST,
            &format!("/v1/subscriptions/{currency_blocked_id}/charge-proposal"),
        )
        .await;
        assert_eq!(
            blocked_single_status,
            StatusCode::BAD_REQUEST,
            "{blocked_single_body}"
        );
        let mut reordered = local_ledger::read_document(&path).expect("ledger should be readable");
        reordered["subscriptions"]
            .as_array_mut()
            .expect("subscriptions should be an array")
            .reverse();
        local_ledger::write_document(&path, &reordered).expect("reordered ledger should persist");

        for invalid in [
            json!([]),
            json!({}),
            json!({"throughDate": "not-a-date"}),
            json!({"throughDate": "2026-07-13", "limit": 0}),
            json!({"throughDate": "2026-07-13", "limit": 201}),
            json!({"throughDate": "2026-07-13", "limit": 1.5}),
            json!({"throughDate": "2026-07-13", "unexpected": true}),
        ] {
            let (status, body) = request_json_body_from(
                router.clone(),
                Method::POST,
                "/v1/subscriptions/charge-proposals/due-scan",
                invalid,
            )
            .await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
            assert_eq!(body["error"]["code"], "invalid_subscription_due_scan");
        }

        let first_key = "subscription-due-scan-replay";
        let first_input = json!({"throughDate": "2026-07-13", "limit": 1});
        let (first_status, first_headers, first_body) = request_json_body_with_idempotency_from(
            router.clone(),
            Method::POST,
            "/v1/subscriptions/charge-proposals/due-scan",
            first_input.clone(),
            Some(first_key),
        )
        .await;
        assert_eq!(first_status, StatusCode::OK, "{first_body}");
        assert_eq!(first_body["data"]["createdCount"], 1);
        assert_eq!(first_body["data"]["alreadyPendingCount"], 1);
        assert_eq!(first_body["data"]["blockedCount"], 2);
        assert_eq!(first_body["data"]["remainingEligibleCount"], 1);
        assert_eq!(first_body["data"]["hasMore"], true);
        assert_eq!(
            first_body["data"]["created"][0]["subscriptionId"],
            first_due_id
        );
        assert_eq!(
            first_body["data"]["skipped"],
            json!([
                {
                    "subscriptionId": blocked_id,
                    "scheduledChargeDate": "2026-01-10",
                    "reason": "payment_account_unavailable"
                },
                {
                    "subscriptionId": pending_id,
                    "scheduledChargeDate": "2026-01-15",
                    "reason": "already_pending"
                },
                {
                    "subscriptionId": currency_blocked_id,
                    "scheduledChargeDate": "2026-01-20",
                    "reason": "payment_currency_unsupported"
                }
            ])
        );
        assert!(first_headers.get("idempotency-replayed").is_none());

        let restarted_router = app_with_state(AppState::local(path.clone()));
        let (replay_status, replay_headers, replay_body) = request_json_body_with_idempotency_from(
            restarted_router.clone(),
            Method::POST,
            "/v1/subscriptions/charge-proposals/due-scan",
            first_input,
            Some(first_key),
        )
        .await;
        assert_eq!(replay_status, StatusCode::OK);
        assert_eq!(replay_body, first_body);
        assert_eq!(
            replay_headers
                .get("idempotency-replayed")
                .and_then(|value| value.to_str().ok()),
            Some("true")
        );

        let (reuse_status, _, reuse_body) = request_json_body_with_idempotency_from(
            restarted_router.clone(),
            Method::POST,
            "/v1/subscriptions/charge-proposals/due-scan",
            json!({"throughDate": "2026-07-13", "limit": 2}),
            Some(first_key),
        )
        .await;
        assert_eq!(reuse_status, StatusCode::CONFLICT);
        assert_eq!(reuse_body["error"]["code"], "idempotency_key_reused");

        let (second_status, second_body) = request_json_body_from(
            restarted_router.clone(),
            Method::POST,
            "/v1/subscriptions/charge-proposals/due-scan",
            json!({"throughDate": "2026-07-13", "limit": 200}),
        )
        .await;
        assert_eq!(second_status, StatusCode::OK, "{second_body}");
        assert_eq!(second_body["data"]["createdCount"], 1);
        assert_eq!(second_body["data"]["alreadyPendingCount"], 2);
        assert_eq!(second_body["data"]["blockedCount"], 2);
        assert_eq!(second_body["data"]["remainingEligibleCount"], 0);
        assert_eq!(second_body["data"]["hasMore"], false);
        assert_eq!(
            second_body["data"]["created"][0]["subscriptionId"],
            second_due_id
        );

        let (_, account_before_confirm) = request_json_from(
            restarted_router.clone(),
            Method::GET,
            &format!("/v1/accounts/{account_id}"),
        )
        .await;
        assert_eq!(account_before_confirm["data"]["value"]["amount"], "100.00");
        for subscription_id in [
            blocked_id.clone(),
            currency_blocked_id.clone(),
            paused_id,
            future_id,
            first_due_id.clone(),
            second_due_id.clone(),
        ] {
            let (_, detail) = request_json_from(
                restarted_router.clone(),
                Method::GET,
                &format!("/v1/subscriptions/{subscription_id}"),
            )
            .await;
            assert_eq!(detail["data"]["lastChargeDate"], Value::Null);
        }

        let group_id = second_body["data"]["created"][0]["id"]
            .as_str()
            .expect("created group id");
        let (confirm_status, confirm_body) = request_json_from(
            restarted_router.clone(),
            Method::POST,
            &format!("/v1/atomic-groups/{group_id}/confirm"),
        )
        .await;
        assert_eq!(confirm_status, StatusCode::OK, "{confirm_body}");
        assert_eq!(confirm_body["data"]["ledgerWrite"], true);
        let (_, account_after_confirm) = request_json_from(
            restarted_router.clone(),
            Method::GET,
            &format!("/v1/accounts/{account_id}"),
        )
        .await;
        assert_eq!(account_after_confirm["data"]["value"]["amount"], "80.00");
        let (_, confirmed_subscription) = request_json_from(
            restarted_router,
            Method::GET,
            &format!("/v1/subscriptions/{second_due_id}"),
        )
        .await;
        assert_eq!(
            confirmed_subscription["data"]["lastChargeDate"],
            "2026-01-31"
        );
        assert_eq!(
            confirmed_subscription["data"]["nextChargeDate"],
            "2026-02-28"
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn subscriptions_reject_unsupported_payment_currency_on_create_and_patch() {
        let path = unique_test_ledger_path("subscription_payment_currency_validation");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (_, account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "CNY-only card",
                "accountType": "virtual_card",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [{"currency": "CNY", "amount": "500.00"}]
            }),
        )
        .await;
        let account_id = account_body["data"]["id"]
            .as_str()
            .expect("account id")
            .to_string();

        let (invalid_create_status, invalid_create_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/subscriptions",
            json!({
                "displayName": "GPT Plus",
                "provider": "OpenAI",
                "amount": {"amount": "20.00", "currency": "USD"},
                "paymentAccountId": account_id,
                "billingCycle": {"unit": "month", "interval": 1},
                "startDate": "2026-07-13"
            }),
        )
        .await;
        assert_eq!(
            invalid_create_status,
            StatusCode::BAD_REQUEST,
            "{invalid_create_body}"
        );
        assert_eq!(
            invalid_create_body["error"]["code"],
            "invalid_subscription_input"
        );

        let (_, create_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/subscriptions",
            json!({
                "displayName": "国内会员",
                "provider": "Example",
                "amount": {"amount": "88.00", "currency": "CNY"},
                "paymentAccountId": account_id,
                "billingCycle": {"unit": "month", "interval": 1},
                "startDate": "2026-07-13"
            }),
        )
        .await;
        let subscription_id = create_body["data"]["id"]
            .as_str()
            .expect("subscription id")
            .to_string();

        let (patch_status, patch_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/subscriptions/{subscription_id}"),
            json!({"amount": {"amount": "20.00", "currency": "USD"}}),
        )
        .await;
        assert_eq!(patch_status, StatusCode::BAD_REQUEST, "{patch_body}");
        assert_eq!(patch_body["error"]["code"], "invalid_subscription_patch");

        let (detail_status, detail_body) = request_json_from(
            router,
            Method::GET,
            &format!("/v1/subscriptions/{subscription_id}"),
        )
        .await;
        assert_eq!(detail_status, StatusCode::OK);
        assert_eq!(detail_body["data"]["amount"]["amount"], "88.00");
        assert_eq!(detail_body["data"]["amount"]["currency"], "CNY");

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn subscription_patch_accepts_nullable_schedule_replacement_fields() {
        let path = unique_test_ledger_path("subscription_patch_nullable_schedule");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));

        let (_, account_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/accounts",
            json!({
                "displayName": "USD card",
                "accountType": "virtual_card",
                "defaultCurrency": "USD",
                "supportedCurrencies": ["USD"],
                "includeInNetWorth": true,
                "balanceMode": "cash_balance",
                "openingBalances": [{"currency": "USD", "amount": "100.00"}]
            }),
        )
        .await;
        let account_id = account_body["data"]["id"].as_str().expect("account id");

        let (_, create_body) = request_json_body_from(
            router.clone(),
            Method::POST,
            "/v1/subscriptions",
            json!({
                "displayName": "Claude Pro",
                "provider": "Anthropic",
                "amount": {"amount": "20.00", "currency": "USD"},
                "paymentAccountId": account_id,
                "billingCycle": {"unit": "month", "interval": 1},
                "startDate": "2026-01-31",
                "duration": {"unit": "month", "count": 3}
            }),
        )
        .await;
        let subscription_id = create_body["data"]["id"].as_str().expect("subscription id");

        let (empty_status, empty_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/subscriptions/{subscription_id}"),
            json!({}),
        )
        .await;
        assert_eq!(empty_status, StatusCode::BAD_REQUEST, "{empty_body}");
        assert_eq!(
            empty_body["error"]["details"]["errors"][0],
            "subscription patch must contain at least one field"
        );

        let (duration_clear_status, duration_clear_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/subscriptions/{subscription_id}"),
            json!({"duration": null}),
        )
        .await;
        assert_eq!(
            duration_clear_status,
            StatusCode::OK,
            "{duration_clear_body}"
        );
        assert!(duration_clear_body["data"].get("duration").is_none());
        assert_eq!(duration_clear_body["data"]["endDate"], Value::Null);

        let (patch_status, patch_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/subscriptions/{subscription_id}"),
            json!({"duration": null, "endDate": "2026-04-30"}),
        )
        .await;
        assert_eq!(patch_status, StatusCode::OK, "{patch_body}");
        assert!(patch_body["data"].get("duration").is_none());
        assert_eq!(patch_body["data"]["endDate"], "2026-04-30");

        let (duration_status, duration_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/subscriptions/{subscription_id}"),
            json!({
                "duration": {"unit": "month", "count": 2},
                "endDate": null
            }),
        )
        .await;
        assert_eq!(duration_status, StatusCode::OK, "{duration_body}");
        assert_eq!(duration_body["data"]["duration"]["count"], 2);
        assert_eq!(duration_body["data"]["endDate"], "2026-03-30");

        let (end_clear_status, end_clear_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/subscriptions/{subscription_id}"),
            json!({"endDate": null}),
        )
        .await;
        assert_eq!(end_clear_status, StatusCode::OK, "{end_clear_body}");
        assert!(end_clear_body["data"].get("duration").is_none());
        assert_eq!(end_clear_body["data"]["endDate"], Value::Null);

        let (clear_status, clear_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/subscriptions/{subscription_id}"),
            json!({"duration": null, "endDate": null}),
        )
        .await;
        assert_eq!(clear_status, StatusCode::OK, "{clear_body}");
        assert!(clear_body["data"].get("duration").is_none());
        assert_eq!(clear_body["data"]["endDate"], Value::Null);

        let (start_shift_status, start_shift_body) = request_json_body_from(
            router.clone(),
            Method::PATCH,
            &format!("/v1/subscriptions/{subscription_id}"),
            json!({"startDate": "2026-08-17"}),
        )
        .await;
        assert_eq!(start_shift_status, StatusCode::OK, "{start_shift_body}");
        assert_eq!(start_shift_body["data"]["startDate"], "2026-08-17");
        assert_eq!(
            start_shift_body["data"]["nextChargeDate"], "2026-08-17",
            "moving the start beyond an inherited next charge must not create an impossible subscription"
        );

        let (conflict_status, conflict_body) = request_json_body_from(
            router,
            Method::PATCH,
            &format!("/v1/subscriptions/{subscription_id}"),
            json!({
                "duration": {"unit": "month", "count": 2},
                "endDate": "2026-04-30"
            }),
        )
        .await;
        assert_eq!(conflict_status, StatusCode::BAD_REQUEST, "{conflict_body}");
        assert_eq!(
            conflict_body["error"]["details"]["errors"][0],
            "duration and endDate are mutually exclusive"
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn health_route_returns_ok() {
        let (status, body) = request_json(Method::GET, "/v1/health").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["ok"], true);
        assert_eq!(body["data"]["status"], "ok");
        assert_eq!(body["data"]["version"], env!("CARGO_PKG_VERSION"));
        let server_time = body["data"]["serverTime"]
            .as_str()
            .expect("health serverTime should be a string");
        let parsed = OffsetDateTime::parse(server_time, &Rfc3339)
            .expect("health serverTime should be current RFC3339 output");
        let age_seconds = (OffsetDateTime::now_utc() - parsed).whole_seconds().abs();
        assert!(
            age_seconds <= 5,
            "health serverTime should reflect request time, age={age_seconds}s"
        );
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
        let (status, body) = request_json_body_from(
            app(),
            Method::POST,
            "/v1/dca/reminders/reminder_001/mark-executed-as-proposal",
            json!({
                "holdingAccountId": "acct_fund",
                "quantity": "10",
                "totalCost": {"amount": "1000.00", "currency": "CNY"},
                "quoteCurrency": "CNY",
                "executedAt": "2026-07-10T09:00:00+08:00"
            }),
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
        let (status, body) = request_json_body_from(
            app(),
            Method::POST,
            "/v1/dca/reminders/missing_reminder/mark-executed-as-proposal",
            json!({
                "holdingAccountId": "acct_fund",
                "quantity": "10",
                "totalCost": {"amount": "1000.00", "currency": "CNY"},
                "quoteCurrency": "CNY"
            }),
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
        let confirmed_movement_id = confirm_body["data"]["confirmedMovementIds"][0]
            .as_str()
            .expect("confirmed movement id should be string")
            .to_string();
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
        let movement_changes = persisted["syncChanges"]
            .as_array()
            .expect("syncChanges should be an array")
            .iter()
            .filter(|change| change["entityType"] == "movement")
            .collect::<Vec<_>>();
        assert_eq!(movement_changes.len(), 1);
        assert_eq!(movement_changes[0]["operation"], "create");
        assert_eq!(movement_changes[0]["entityId"], confirmed_movement_id);
        assert_eq!(
            movement_changes[0]["payload"]["source"]["kind"],
            "ai_proposal"
        );
        assert_eq!(movement_changes[0]["payload"]["title"], "AI 整理：午餐");

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
    async fn local_ledger_image_import_rejects_mismatched_evidence_before_persistence() {
        let path = unique_test_ledger_path("invalid_image_import");
        local_ledger::load_or_initialize(&path).expect("test ledger should initialize");
        let router = app_with_state(AppState::local(path.clone()));
        let (status, body) = request_json_body_from(
            router,
            Method::POST,
            "/v1/ai/proposals/from-image",
            json!({
                "fileName": "receipt.png",
                "mimeType": "image/png",
                "imageBase64": STANDARD.encode(b"not a png")
            }),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"]["code"], "ai_image_input_data_invalid");
        let persisted = local_ledger::read_document(&path).expect("ledger should remain readable");
        assert_eq!(persisted["aiProposals"], json!([]));
        let _ = std::fs::remove_file(path);
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
