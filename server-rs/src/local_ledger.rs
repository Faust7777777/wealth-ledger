use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs, io,
    ops::{Add, AddAssign, Neg, Sub},
    path::{Path, PathBuf},
};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

pub const LEDGER_VERSION: i64 = 1;
pub const DEFAULT_BASE_CURRENCY: &str = "CNY";

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
            "pendingChangeIds": []
        },
        "migrations": []
    })
}

pub fn load_or_initialize(path: &Path) -> io::Result<Value> {
    if path.exists() {
        return read_document(path);
    }

    let document = empty_document(DEFAULT_BASE_CURRENCY);
    write_document(path, &document)?;
    Ok(document)
}

pub fn read_document(path: &Path) -> io::Result<Value> {
    let raw = fs::read_to_string(path)?;
    let document: Value = serde_json::from_str(&raw).map_err(invalid_data)?;
    validate_document(&document).map_err(validation_error)?;
    Ok(document)
}

pub fn write_document(path: &Path, document: &Value) -> io::Result<()> {
    validate_document(document).map_err(validation_error)?;

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let tmp_path = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec_pretty(document).map_err(invalid_data)?;
    fs::write(&tmp_path, bytes)?;
    fs::rename(tmp_path, path)?;
    Ok(())
}

#[derive(Debug)]
pub enum LedgerError {
    InvalidInput(Vec<String>),
    Conflict(String),
    NotFound(String),
    Io(io::Error),
}

impl From<io::Error> for LedgerError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

pub fn list_accounts(path: &Path) -> io::Result<Value> {
    let document = load_or_initialize(path)?;
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

pub fn create_account(
    path: &Path,
    input: Value,
    account_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
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

    write_document(path, &document)?;
    Ok(project_account_for_api(&account))
}

pub fn update_account(
    path: &Path,
    account_id: &str,
    patch: Value,
    now: &str,
) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
    let account = find_account_mut(&mut document, account_id)
        .ok_or_else(|| LedgerError::NotFound(format!("account does not exist: {account_id}")))?;
    apply_account_patch(account, &patch, now)?;
    let projected = project_account_for_api(account);
    write_document(path, &document)?;
    Ok(projected)
}

pub fn archive_account(path: &Path, account_id: &str, now: &str) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
    let account = find_account_mut(&mut document, account_id)
        .ok_or_else(|| LedgerError::NotFound(format!("account does not exist: {account_id}")))?;
    account["status"] = json!("archived");
    account["visibility"] = json!("archived");
    account["updatedAt"] = json!(now);
    let projected = project_account_for_api(account);
    write_document(path, &document)?;
    Ok(projected)
}

pub fn list_holdings(path: &Path) -> io::Result<Value> {
    let document = load_or_initialize(path)?;
    Ok(json!(project_holdings_for_api(&document)))
}

pub fn list_holdings_by_account(path: &Path, account_id: &str) -> io::Result<Value> {
    let document = load_or_initialize(path)?;
    Ok(json!(
        project_holdings_for_api(&document)
            .into_iter()
            .filter(|holding| holding.get("accountId").and_then(Value::as_str) == Some(account_id))
            .collect::<Vec<_>>()
    ))
}

pub fn list_movements(path: &Path) -> io::Result<Value> {
    let document = load_or_initialize(path)?;
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
) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
    let movement =
        movement_from_create_input(&document, &input, movement_id, atomic_group_id, now)?;

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

    write_document(path, &document)?;
    Ok(project_movement_for_api(&movement))
}

pub fn create_correction_proposal(
    path: &Path,
    input: Value,
    movement_id: &str,
    atomic_group_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
    let Some(object) = input.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "correction input must be a JSON object".to_string(),
        ]));
    };

    let mut errors = Vec::new();
    let target_movement_id = required_string(object, "targetMovementId", &mut errors);
    let reason = required_string(object, "reason", &mut errors);
    let proposed_diffs = object
        .get("proposedDiffs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

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

    let correction_entry = correction_entry_from_diffs(&target, &proposed_diffs, movement_id)?;
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
        "entries": [correction_entry],
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

    write_document(path, &document)?;
    Ok(group)
}

pub fn submit_movement_review(
    path: &Path,
    movement_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
    let movement = find_movement_mut(&mut document, movement_id)
        .ok_or_else(|| LedgerError::NotFound(format!("movement does not exist: {movement_id}")))?;

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
    write_document(path, &document)?;
    Ok(group)
}

pub fn confirm_atomic_group(
    path: &Path,
    atomic_group_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
    if let Some(result) = confirm_counterparty_merge_atomic_group(&mut document, atomic_group_id)? {
        write_document(path, &document)?;
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
                let entries = movement
                    .get("entries")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                apply_movement_entries(&mut document, &entries, now)?;
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
            }
        }
        mark_dca_reminders_recorded_for_movements(&mut document, &candidate_movements, now);
    }

    write_document(path, &document)?;
    Ok(json!({
        "atomicGroupId": atomic_group_id,
        "confirmedMovementIds": confirmed_movement_ids,
        "snapshotInvalidated": !confirmed_movement_ids.is_empty(),
        "ledgerWrite": !confirmed_movement_ids.is_empty(),
        "devOnly": false
    }))
}

pub fn reject_atomic_group(
    path: &Path,
    atomic_group_id: &str,
    now: &str,
) -> Result<(), LedgerError> {
    let mut document = load_or_initialize(path)?;
    if reject_ai_atomic_group(&mut document, atomic_group_id)? {
        write_document(path, &document)?;
        return Ok(());
    }

    let mut found = false;
    let movements = document["movements"]
        .as_array_mut()
        .expect("validated local ledger movements should be an array");

    for movement in movements.iter_mut().filter(|movement| {
        movement.get("atomicGroupId").and_then(Value::as_str) == Some(atomic_group_id)
    }) {
        found = true;
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

    if !found {
        return Err(LedgerError::NotFound(format!(
            "atomic group does not exist: {atomic_group_id}"
        )));
    }

    write_document(path, &document)?;
    Ok(())
}

pub fn list_dca_plans(path: &Path) -> io::Result<Value> {
    let document = load_or_initialize(path)?;
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
) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
    let plan = dca_plan_from_create_input(&document, &input, plan_id, now)?;
    let reminder = dca_reminder_from_plan(&plan, reminder_id);

    document["dcaPlans"]
        .as_array_mut()
        .expect("validated local ledger dcaPlans should be an array")
        .push(plan.clone());
    document["dcaReminders"]
        .as_array_mut()
        .expect("validated local ledger dcaReminders should be an array")
        .push(reminder);

    write_document(path, &document)?;
    Ok(plan)
}

pub fn list_due_dca_reminders(path: &Path) -> io::Result<Value> {
    let document = load_or_initialize(path)?;
    let reminders = document["dcaReminders"]
        .as_array()
        .expect("validated local ledger dcaReminders should be an array")
        .iter()
        .filter(|reminder| {
            matches!(
                reminder.get("status").and_then(Value::as_str),
                Some("due" | "overdue")
            )
        })
        .cloned()
        .collect::<Vec<_>>();
    Ok(json!(reminders))
}

pub fn skip_dca_reminder(path: &Path, reminder_id: &str, now: &str) -> Result<Value, LedgerError> {
    update_dca_reminder_status(path, reminder_id, "skipped", None, now)
}

pub fn snooze_dca_reminder(
    path: &Path,
    reminder_id: &str,
    input: Value,
    now: &str,
) -> Result<Value, LedgerError> {
    let Some(object) = input.as_object() else {
        return Err(LedgerError::InvalidInput(vec![
            "snooze input must be a JSON object".to_string(),
        ]));
    };
    let mut errors = Vec::new();
    let until = required_string(object, "until", &mut errors);
    if !errors.is_empty() {
        return Err(LedgerError::InvalidInput(errors));
    }

    update_dca_reminder_status(path, reminder_id, "snoozed", until, now)
}

pub fn mark_dca_executed_as_proposal(
    path: &Path,
    reminder_id: &str,
    movement_id: &str,
    atomic_group_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
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
    if !active_account_exists(&document, funding_account_id) {
        return Err(LedgerError::NotFound(format!(
            "DCA funding account does not exist or is archived: {funding_account_id}"
        )));
    }
    let target_instrument_id = plan
        .get("targetInstrumentId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec!["DCA plan.targetInstrumentId is required".to_string()])
        })?;
    let planned_amount = plan.get("plannedAmount").ok_or_else(|| {
        LedgerError::InvalidInput(vec!["DCA plan.plannedAmount is required".to_string()])
    })?;
    let amount = planned_amount
        .get("amount")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec![
                "DCA plan.plannedAmount.amount is required".to_string(),
            ])
        })?;
    let currency = planned_amount
        .get("currency")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            LedgerError::InvalidInput(vec![
                "DCA plan.plannedAmount.currency is required".to_string(),
            ])
        })?;
    if !is_positive_decimal_string(amount) {
        return Err(LedgerError::InvalidInput(vec![
            "DCA plan.plannedAmount.amount must be a positive decimal string".to_string(),
        ]));
    }

    let display_name = plan
        .get("displayName")
        .and_then(Value::as_str)
        .unwrap_or(target_instrument_id);
    let movement = json!({
        "id": movement_id,
        "atomicGroupId": atomic_group_id,
        "type": "buy",
        "occurredAt": now,
        "recordedAt": now,
        "status": "pending_review",
        "title": format!("记录{display_name}定投"),
        "description": "用户点击“记录已执行”后生成的候选记录；不下单、不转账。",
        "entries": [
            {
                "id": format!("entry_{movement_id}_cash_out"),
                "accountId": funding_account_id,
                "amount": amount,
                "currency": currency,
                "direction": "out",
                "role": "source"
            },
            {
                "id": format!("entry_{movement_id}_holding_in"),
                "accountId": funding_account_id,
                "instrumentId": target_instrument_id,
                "amount": amount,
                "currency": currency,
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
    write_document(path, &document)?;
    Ok(group)
}

pub fn portfolio_overview(path: &Path, now: &str) -> io::Result<Value> {
    let document = load_or_initialize(path)?;
    let summary = summarize_accounts(&document, now)?;
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
            )
        })
        .count();

    Ok(json!({
        "latestSnapshot": summary.latest_snapshot,
        "previousSnapshot": Value::Null,
        "pendingSummary": {
            "aiPendingCount": 0,
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
    let document = load_or_initialize(path)?;
    let summary = summarize_accounts(&document, now)?;
    Ok(json!({
        "slices": summary.allocation_slices,
        "totalAssets": money(summary.gross_assets, &summary.base_currency),
        "totalLiabilities": money(summary.total_liabilities, &summary.base_currency),
        "netWorth": money(summary.net_worth(), &summary.base_currency)
    }))
}

pub fn latest_snapshot(path: &Path, now: &str) -> io::Result<Value> {
    let document = load_or_initialize(path)?;
    if let Some(snapshot) = latest_persisted_snapshot(&document) {
        return Ok(snapshot);
    }
    Ok(summarize_accounts(&document, now)?.latest_snapshot)
}

pub fn list_snapshots(path: &Path) -> io::Result<Value> {
    let document = load_or_initialize(path)?;
    Ok(json!(
        document["snapshots"]
            .as_array()
            .expect("validated local ledger snapshots should be an array")
            .clone()
    ))
}

pub fn create_manual_snapshot(path: &Path, input: Value, now: &str) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
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

    let mut snapshot = summarize_accounts(&document, now)?.latest_snapshot;
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
    write_document(path, &document)?;
    Ok(snapshot)
}

pub fn list_categories(path: &Path) -> io::Result<Value> {
    let document = load_or_initialize(path)?;
    Ok(json!(
        document["categories"]
            .as_array()
            .expect("validated local ledger categories should be an array")
            .clone()
    ))
}

pub fn create_category(path: &Path, input: Value, category_id: &str) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
    let category = category_from_input(&input, category_id)?;
    document["categories"]
        .as_array_mut()
        .expect("validated local ledger categories should be an array")
        .push(category.clone());
    write_document(path, &document)?;
    Ok(category)
}

pub fn update_category(path: &Path, category_id: &str, patch: Value) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
    let category = document["categories"]
        .as_array_mut()
        .expect("validated local ledger categories should be an array")
        .iter_mut()
        .find(|category| category.get("id").and_then(Value::as_str) == Some(category_id))
        .ok_or_else(|| LedgerError::NotFound(format!("category does not exist: {category_id}")))?;
    apply_category_patch(category, &patch)?;
    let projected = category.clone();
    write_document(path, &document)?;
    Ok(projected)
}

pub fn list_counterparties(path: &Path) -> io::Result<Value> {
    let document = load_or_initialize(path)?;
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
) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
    let counterparty = counterparty_from_input(&input, counterparty_id)?;
    document["counterparties"]
        .as_array_mut()
        .expect("validated local ledger counterparties should be an array")
        .push(counterparty.clone());
    write_document(path, &document)?;
    Ok(counterparty)
}

pub fn update_counterparty(
    path: &Path,
    counterparty_id: &str,
    patch: Value,
) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
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
    write_document(path, &document)?;
    Ok(projected)
}

pub fn create_counterparty_merge_proposal(
    path: &Path,
    input: Value,
    proposal_id: &str,
    atomic_group_id: &str,
    now: &str,
) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
    let group = counterparty_merge_group_from_input(&document, &input, atomic_group_id)?;
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
    write_document(path, &document)?;
    Ok(group)
}

pub fn list_pending_ai_proposals(path: &Path) -> io::Result<Value> {
    let document = load_or_initialize(path)?;
    Ok(json!(
        document["aiProposals"]
            .as_array()
            .expect("validated local ledger aiProposals should be an array")
            .iter()
            .filter(|proposal| {
                proposal.get("status").and_then(Value::as_str) == Some("pending")
                    && proposal_has_pending_group(proposal)
            })
            .cloned()
            .collect::<Vec<_>>()
    ))
}

pub fn get_ai_proposal(path: &Path, proposal_id: &str) -> io::Result<Option<Value>> {
    let document = load_or_initialize(path)?;
    Ok(document["aiProposals"]
        .as_array()
        .expect("validated local ledger aiProposals should be an array")
        .iter()
        .find(|proposal| proposal.get("id").and_then(Value::as_str) == Some(proposal_id))
        .cloned())
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
    let mut errors = Vec::new();

    let Some(object) = document.as_object() else {
        return Err(vec!["ledger document must be a JSON object".to_string()]);
    };

    if object.get("ledgerVersion").and_then(Value::as_i64) != Some(LEDGER_VERSION) {
        errors.push(format!("ledgerVersion must be {LEDGER_VERSION}"));
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
        "categories",
        "counterparties",
        "quotes",
        "fxRates",
        "snapshots",
        "aiProposals",
        "evidenceRefs",
        "anomalies",
        "migrations",
    ] {
        require_array(object, key, &mut errors);
    }

    if contains_fixture_marker(document) {
        errors.push("real local ledger must not contain debug fixture markers".to_string());
    }

    validate_accounts(object.get("accounts"), &mut errors);

    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
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
            if balance.get("currency").and_then(Value::as_str) != Some(base_currency.as_str()) {
                unpriceable_count += 1;
                quality = combine_quality(quality, "incomplete");
                continue;
            }

            let amount = parse_decimal(
                balance
                    .get("amount")
                    .and_then(Value::as_str)
                    .expect("validated cash balance amount should be a string"),
            )?;
            has_base_value = true;
            account_total += amount;
            let balance_quality = balance
                .get("quality")
                .and_then(Value::as_str)
                .unwrap_or("exact");
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

        if is_liability {
            total_liabilities += absolute_decimal(account_total);
        } else if account_total.is_negative() {
            account_anomaly_count += 1;
            total_liabilities += absolute_decimal(account_total);
            quality = combine_quality(quality, "anomaly");
        } else {
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
    let frequency = required_enum(
        object,
        "frequency",
        &["weekly", "monthly", "custom"],
        &mut errors,
    );
    let next_due_date = required_string(object, "nextDueDate", &mut errors);
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
    let account_id = account.get("id").and_then(Value::as_str)?;
    let mut total = DecimalAmount::ZERO;
    let mut has_value = false;
    let mut quality = "exact";

    for balance in account
        .get("cashBalances")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|balance| balance.get("currency").and_then(Value::as_str) == Some(currency))
    {
        let amount = parse_decimal(balance.get("amount")?.as_str()?).ok()?;
        total += amount;
        has_value = true;
        quality = combine_quality(
            quality,
            balance
                .get("quality")
                .and_then(Value::as_str)
                .unwrap_or("exact"),
        );
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
            "asOf": OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .expect("RFC3339 formatting should succeed"),
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
        let cents = round_div(self.0, Self::SCALE / 100);
        signed_fixed_string(cents, 2)
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

            if let Some(instrument_id) = optional_string(item, "instrumentId", errors) {
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
    document["accounts"]
        .as_array()
        .expect("validated local ledger accounts should be an array")
        .iter()
        .any(|account| {
            account.get("id").and_then(Value::as_str) == Some(account_id)
                && account.get("status").and_then(Value::as_str) != Some("archived")
        })
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
            proposal["status"] = json!(status_to_proposal_status(status));
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

fn status_to_proposal_status(status: &str) -> &'static str {
    match status {
        "approved" => "approved",
        "rejected" => "rejected",
        "edited" => "edited",
        _ => "pending",
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
    path: &Path,
    reminder_id: &str,
    status: &str,
    snoozed_until: Option<String>,
    now: &str,
) -> Result<Value, LedgerError> {
    let mut document = load_or_initialize(path)?;
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

    write_document(path, &document)?;
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
        Some(value) => !value.is_empty() && value.chars().all(|c| c.is_ascii_digit()),
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
        assert_eq!(document["aiProposals"], json!([]));
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
