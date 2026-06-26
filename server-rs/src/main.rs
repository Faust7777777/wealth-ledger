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
        .route("/v1/movements/corrections", post(not_implemented))
        .route(
            "/v1/atomic-groups/{atomic_group_id}/confirm",
            post(confirm_atomic_group),
        )
        .route(
            "/v1/atomic-groups/{atomic_group_id}/reject",
            post(reject_atomic_group),
        )
        .route("/v1/dca/plans", get(dca_plans).post(create_dca_plan))
        .route("/v1/dca/plans/{plan_id}", any(not_implemented))
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
        .route("/v1/quotes", get(empty_array))
        .route("/v1/fx-rates", get(empty_array))
        .route("/v1/quotes/refresh", post(example_quote_stale))
        .route(
            "/v1/instruments/{instrument_id}/historical-prices",
            get(empty_array),
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

fn next_local_id(prefix: &str) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be after unix epoch")
        .as_nanos();
    format!("{prefix}_{nanos}")
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
