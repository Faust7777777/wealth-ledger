use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{any, get, post},
};
use serde_json::{Value, json};
use std::{collections::HashMap, env, net::SocketAddr};

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
}

impl AppState {
    fn dev() -> Self {
        Self {
            ledger: DevLedgerCore,
        }
    }
}

/// Dev-only LedgerCore facade.
///
/// This is deliberately in-memory and deterministic. It is the seam where the
/// future encrypted local ledger / SQLite store can replace virtual dev data
/// without changing HTTP route signatures.
#[derive(Clone)]
struct DevLedgerCore;

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
        if scenario.is_degraded() {
            json!([example_data(AI_DIFF)])
        } else {
            json!([])
        }
    }

    fn ai_proposal(&self, scenario: DevScenario, proposal_id: &str) -> Option<Value> {
        if !scenario.is_degraded() {
            return None;
        }
        let proposal = example_data(AI_DIFF);
        (proposal.get("id").and_then(Value::as_str) == Some(proposal_id)).then_some(proposal)
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
    let addr = read_addr();
    assert_loopback(addr);

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("bind finwealth rust server");
    println!("finwealth rust server listening on http://{addr}");
    println!("dev skeleton only: no persistence, real auth, real AI, real quotes, or sync effects");

    axum::serve(listener, app())
        .await
        .expect("serve finwealth rust server");
}

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
        .route("/v1/accounts", get(accounts).post(not_implemented))
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
            post(not_implemented),
        )
        .route(
            "/v1/atomic-groups/{atomic_group_id}/reject",
            post(not_implemented),
        )
        .route("/v1/dca/plans", get(dca_plans).post(not_implemented))
        .route("/v1/dca/plans/{plan_id}", any(not_implemented))
        .route("/v1/dca/reminders/due", get(dca_due_reminders))
        .route(
            "/v1/dca/reminders/{reminder_id}/mark-executed-as-proposal",
            post(example_dca_proposal),
        )
        .route(
            "/v1/dca/reminders/{reminder_id}/skip",
            post(not_implemented),
        )
        .route(
            "/v1/dca/reminders/{reminder_id}/snooze",
            post(not_implemented),
        )
        .route("/v1/ai/proposals/from-text", post(example_ai_diff))
        .route("/v1/ai/proposals/from-image", post(example_ai_diff))
        .route("/v1/ai/proposals/from-csv", post(example_ai_diff))
        .route("/v1/ai/proposals/pending", get(ai_pending))
        .route("/v1/ai/proposals/{proposal_id}", get(ai_proposal))
        .route(
            "/v1/ai/atomic-groups/{atomic_group_id}/approve",
            post(not_implemented),
        )
        .route(
            "/v1/ai/atomic-groups/{atomic_group_id}/reject",
            post(not_implemented),
        )
        .route(
            "/v1/ai/atomic-groups/{atomic_group_id}/edit",
            post(not_implemented),
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
) -> Json<Value> {
    envelope(state.ledger.accounts(DevScenario::from_query(&query)))
}

async fn account_detail(
    State(state): State<AppState>,
    Path(account_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
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

async fn example_empty_bootstrap() -> Json<Value> {
    example_json(EMPTY_BOOTSTRAP)
}

async fn example_ai_diff() -> Json<Value> {
    example_json(AI_DIFF)
}

async fn example_dca_proposal() -> Json<Value> {
    example_json(DCA_PROPOSAL)
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
        let core = DevLedgerCore;

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
        let response = app()
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(uri)
                    .header("content-type", "application/json")
                    .body(Body::from("{}"))
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
}
