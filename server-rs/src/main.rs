use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{any, get, post},
};
mod local_ledger;

use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    env,
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

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
}

impl AppState {
    fn dev() -> Self {
        Self {
            ledger: DevLedgerCore::new(),
            local_ledger_path: None,
        }
    }

    fn local(path: PathBuf) -> Self {
        Self {
            ledger: DevLedgerCore::new(),
            local_ledger_path: Some(path),
        }
    }

    fn should_use_local_ledger(&self, query: &HashMap<String, String>) -> bool {
        self.local_ledger_path.is_some() && !query.contains_key("scenario")
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
            "dev skeleton only: real_local JSON persistence for accounts; no real auth, real AI, real quotes, or sync effects"
        );
    } else {
        println!(
            "dev skeleton only: no persistence, real auth, real AI, real quotes, or sync effects"
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
        .route("/v1/auth/logout", post(no_content))
        .route("/v1/auth/devices", get(empty_array))
        .route("/v1/auth/devices/{device_id}/revoke", post(no_content))
        .route("/v1/ledger/bootstrap", get(example_empty_bootstrap))
        .route("/v1/accounts", get(accounts).post(create_account))
        .route("/v1/accounts/anomalies", get(account_anomalies))
        .route(
            "/v1/accounts/{account_id}",
            get(account_detail).patch(not_implemented),
        )
        .route("/v1/accounts/{account_id}/archive", post(not_implemented))
        .route("/v1/accounts/{account_id}/holdings", get(account_holdings))
        .route("/v1/portfolio/overview", get(portfolio_overview))
        .route("/v1/portfolio/holdings", get(holdings))
        .route("/v1/holdings", get(holdings))
        .route("/v1/portfolio/allocation", get(asset_allocation))
        .route("/v1/movements", get(movements))
        .route("/v1/movements/recent", get(movements))
        .route("/v1/movements/drafts", post(not_implemented))
        .route("/v1/movements/{movement_id}", get(movement_detail))
        .route(
            "/v1/movements/{movement_id}/submit-review",
            post(not_implemented),
        )
        .route("/v1/movements/corrections", post(not_implemented))
        .route(
            "/v1/atomic-groups/{atomic_group_id}/confirm",
            post(confirm_atomic_group),
        )
        .route(
            "/v1/atomic-groups/{atomic_group_id}/reject",
            post(reject_atomic_group),
        )
        .route("/v1/dca/plans", get(dca_plans).post(not_implemented))
        .route("/v1/dca/plans/{plan_id}", any(not_implemented))
        .route("/v1/dca/reminders/due", get(dca_due_reminders))
        .route(
            "/v1/dca/reminders/{reminder_id}/mark-executed-as-proposal",
            post(mark_dca_executed_as_proposal),
        )
        .route(
            "/v1/dca/reminders/{reminder_id}/skip",
            post(not_implemented),
        )
        .route(
            "/v1/dca/reminders/{reminder_id}/snooze",
            post(not_implemented),
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
        .route("/v1/quotes", get(empty_array))
        .route("/v1/fx-rates", get(empty_array))
        .route("/v1/quotes/refresh", post(example_quote_stale))
        .route(
            "/v1/instruments/{instrument_id}/historical-prices",
            get(empty_array),
        )
        .route("/v1/snapshots/latest", get(snapshot_latest))
        .route("/v1/snapshots", get(snapshots))
        .route("/v1/snapshots/manual", post(not_implemented))
        .route("/v1/snapshots/invalidate", post(no_content))
        .route("/v1/categories", get(empty_array).post(not_implemented))
        .route("/v1/categories/{category_id}", any(not_implemented))
        .route("/v1/counterparties", get(empty_array).post(not_implemented))
        .route("/v1/counterparties/{counterparty_id}", any(not_implemented))
        .route("/v1/counterparties/merge-proposal", post(not_implemented))
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

async fn auth_login() -> Json<Value> {
    envelope(json!({
        "accessToken": "dev_access_token_not_for_production",
        "refreshToken": "dev_refresh_token_not_for_production",
        "expiresAt": "2026-06-25T13:00:00+08:00",
        "deviceId": "dev_device_001"
    }))
}

async fn auth_refresh() -> Json<Value> {
    auth_login().await
}

async fn portfolio_overview(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    envelope(
        state
            .ledger
            .portfolio_overview(DevScenario::from_query(&query)),
    )
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
        Err(local_ledger::LedgerError::InvalidInput(errors)) => bad_request(
            "invalid_account_input",
            "Create account input is invalid.",
            json!({ "errors": errors }),
        ),
        Err(local_ledger::LedgerError::Conflict(message)) => {
            bad_request("account_conflict", &message, json!({}))
        }
        Err(local_ledger::LedgerError::Io(error)) => ledger_io_error(error),
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
) -> Json<Value> {
    envelope(state.ledger.holdings(DevScenario::from_query(&query)))
}

async fn account_holdings(
    State(state): State<AppState>,
    Path(account_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    envelope(
        state
            .ledger
            .holdings_by_account(DevScenario::from_query(&query), &account_id),
    )
}

async fn asset_allocation(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    envelope(
        state
            .ledger
            .asset_allocation(DevScenario::from_query(&query)),
    )
}

async fn movements(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    envelope(state.ledger.movements(DevScenario::from_query(&query)))
}

async fn movement_detail(
    State(state): State<AppState>,
    Path(movement_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
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

async fn dca_plans(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    envelope(state.ledger.dca_plans(DevScenario::from_query(&query)))
}

async fn dca_due_reminders(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    envelope(
        state
            .ledger
            .dca_due_reminders(DevScenario::from_query(&query)),
    )
}

async fn ai_pending(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    envelope(state.ledger.ai_pending(DevScenario::from_query(&query)))
}

async fn ai_proposal(
    State(state): State<AppState>,
    Path(proposal_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
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

async fn ai_proposal_from_text(State(state): State<AppState>) -> Json<Value> {
    envelope(state.ledger.create_ai_proposal("user_text"))
}

async fn ai_proposal_from_image(State(state): State<AppState>) -> Json<Value> {
    envelope(state.ledger.create_ai_proposal("user_image"))
}

async fn ai_proposal_from_csv(State(state): State<AppState>) -> Json<Value> {
    envelope(state.ledger.create_ai_proposal("csv_import"))
}

async fn mark_dca_executed_as_proposal(
    State(state): State<AppState>,
    Path(reminder_id): Path<String>,
) -> Response {
    match state.ledger.mark_dca_executed_as_proposal(&reminder_id) {
        Some(proposal) => envelope(proposal).into_response(),
        None => not_found(
            "dca_reminder_not_found",
            "DCA reminder does not exist in this dev scenario.",
        ),
    }
}

async fn confirm_atomic_group(
    State(state): State<AppState>,
    Path(atomic_group_id): Path<String>,
) -> Response {
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
) -> Response {
    match state.ledger.edit_atomic_group(&atomic_group_id) {
        Some(group) => envelope(group).into_response(),
        None => not_found(
            "atomic_group_not_found",
            "Atomic group does not exist in this dev scenario.",
        ),
    }
}

async fn example_empty_bootstrap() -> Json<Value> {
    example_json(EMPTY_BOOTSTRAP)
}

async fn example_quote_stale() -> Json<Value> {
    example_json(QUOTE_STALE)
}

async fn empty_array() -> Json<Value> {
    envelope(json!([]))
}

async fn quote_summary(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    envelope(state.ledger.quote_summary(DevScenario::from_query(&query)))
}

async fn snapshot_latest(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    envelope(
        state
            .ledger
            .latest_snapshot(DevScenario::from_query(&query)),
    )
}

async fn snapshots(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Json<Value> {
    envelope(state.ledger.snapshots(DevScenario::from_query(&query)))
}

async fn sync_bootstrap() -> Json<Value> {
    envelope(json!({"cursor": "rust_dev_cursor_0001"}))
}

async fn sync_changes() -> Json<Value> {
    envelope(json!({
        "cursor": "rust_dev_cursor_0001",
        "changes": [],
        "conflicts": []
    }))
}

async fn sync_push() -> Json<Value> {
    envelope(json!({
        "cursor": "rust_dev_cursor_0001",
        "conflicts": []
    }))
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
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be after unix epoch")
        .as_nanos();
    format!("acct_local_{nanos}")
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
