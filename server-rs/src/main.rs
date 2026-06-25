use axum::{
    Json, Router,
    extract::Query,
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
    Router::new()
        .route("/v1/health", get(health))
        .route("/v1/auth/login", post(auth_login))
        .route("/v1/auth/refresh", post(auth_refresh))
        .route("/v1/auth/logout", post(no_content))
        .route("/v1/auth/devices", get(empty_array))
        .route("/v1/auth/devices/{device_id}/revoke", post(no_content))
        .route("/v1/ledger/bootstrap", get(example_empty_bootstrap))
        .route("/v1/accounts", get(empty_array).post(not_implemented))
        .route("/v1/accounts/anomalies", get(empty_array))
        .route(
            "/v1/accounts/{account_id}",
            get(not_implemented).patch(not_implemented),
        )
        .route("/v1/accounts/{account_id}/archive", post(not_implemented))
        .route("/v1/accounts/{account_id}/holdings", get(empty_array))
        .route("/v1/portfolio/overview", get(portfolio_overview))
        .route("/v1/portfolio/holdings", get(empty_array))
        .route("/v1/portfolio/allocation", get(empty_object))
        .route("/v1/movements", get(empty_array))
        .route("/v1/movements/drafts", post(not_implemented))
        .route("/v1/movements/{movement_id}", get(not_implemented))
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
        .route("/v1/dca/plans", get(empty_array).post(not_implemented))
        .route("/v1/dca/plans/{plan_id}", any(not_implemented))
        .route("/v1/dca/reminders/due", get(empty_array))
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
        .route("/v1/ai/proposals/pending", get(empty_array))
        .route("/v1/ai/proposals/{proposal_id}", get(not_implemented))
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
        .route("/v1/snapshots/latest", get(null_data))
        .route("/v1/snapshots", get(empty_array))
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
}

fn read_addr() -> SocketAddr {
    env::var("FINWEALTH_RS_ADDR")
        .unwrap_or_else(|_| "127.0.0.1:8790".to_string())
        .parse()
        .expect("FINWEALTH_RS_ADDR must be a socket address")
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

async fn portfolio_overview(Query(query): Query<HashMap<String, String>>) -> Json<Value> {
    if query
        .get("scenario")
        .is_some_and(|value| value == "degraded")
    {
        example_json(OVERVIEW_DEGRADED)
    } else {
        example_json(OVERVIEW_EMPTY)
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

async fn empty_object() -> Json<Value> {
    envelope(json!({}))
}

async fn null_data() -> Json<Value> {
    envelope(Value::Null)
}

async fn quote_summary() -> Json<Value> {
    envelope(json!({
        "freshCount": 0,
        "staleCount": 0,
        "offlineCachedCount": 0,
        "unpriceableCount": 0,
        "errorCount": 0
    }))
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
