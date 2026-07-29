use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

pub(crate) type MigrationApply = fn(&mut Value) -> Result<(), String>;

#[derive(Clone, Copy, Debug)]
pub(crate) struct MigrationSpec {
    pub(crate) id: &'static str,
    pub(crate) from: i64,
    pub(crate) to: i64,
    pub(crate) apply: MigrationApply,
}

pub(crate) const MIGRATION_REGISTRY: &[MigrationSpec] = &[];

pub(crate) fn validate_registry(registry: &[MigrationSpec]) -> Result<(), String> {
    let mut ids = BTreeSet::new();
    let mut by_source = BTreeMap::new();
    let mut by_target = BTreeMap::new();

    for migration in registry {
        if migration.id.trim().is_empty() {
            return Err("migration id must not be empty".to_owned());
        }
        if migration.from < 1 || migration.to < 1 {
            return Err(format!(
                "migration {} versions must be positive ({} -> {})",
                migration.id, migration.from, migration.to
            ));
        }
        if !ids.insert(migration.id) {
            return Err(format!("duplicate migration id: {}", migration.id));
        }
        if let Some(existing) = by_source.insert(migration.from, migration.id) {
            return Err(format!(
                "migration fork at version {}: {} and {}",
                migration.from, existing, migration.id
            ));
        }
        if let Some(existing) = by_target.insert(migration.to, migration.id) {
            return Err(format!(
                "migration merge at version {}: {} and {}",
                migration.to, existing, migration.id
            ));
        }
    }

    for migration in registry {
        if migration.from.checked_add(1) != Some(migration.to) {
            return Err(format!(
                "migration {} must advance exactly one version ({} -> {})",
                migration.id, migration.from, migration.to
            ));
        }
    }

    let mut ordered = registry.iter().collect::<Vec<_>>();
    ordered.sort_by_key(|migration| migration.from);
    for pair in ordered.windows(2) {
        let current = pair[0];
        let next = pair[1];
        if current.to != next.from {
            return Err(format!(
                "migration registry gap between versions {} and {}",
                current.to, next.from
            ));
        }
    }

    Ok(())
}

pub(crate) fn plan_migrations(
    registry: &[MigrationSpec],
    source: i64,
    target: i64,
) -> Result<Vec<MigrationSpec>, String> {
    validate_registry(registry)?;

    if target < source {
        return Err(format!(
            "ledger downgrade is not supported ({source} -> {target})"
        ));
    }
    if target == source {
        return Ok(Vec::new());
    }

    let by_source = registry
        .iter()
        .map(|migration| (migration.from, *migration))
        .collect::<BTreeMap<_, _>>();
    let mut current = source;
    let mut plan = Vec::new();

    while current < target {
        let migration = by_source.get(&current).copied().ok_or_else(|| {
            format!(
                "missing migration step from version {current} while planning {source} -> {target}"
            )
        })?;
        plan.push(migration);
        current = migration.to;
    }

    Ok(plan)
}

pub(crate) fn validate_history(document: &Value, registry: &[MigrationSpec]) -> Result<(), String> {
    validate_registry(registry)?;
    let version = ledger_version(document)?;
    let Some(history) = document.get("migrations") else {
        return Ok(());
    };
    let history = history
        .as_array()
        .ok_or_else(|| "ledger migrations must be an array".to_owned())?;

    let by_id = registry
        .iter()
        .map(|migration| (migration.id, migration))
        .collect::<BTreeMap<_, _>>();
    let mut seen = BTreeSet::new();
    let mut previous_target = None;

    for (index, record) in history.iter().enumerate() {
        let object = record
            .as_object()
            .ok_or_else(|| format!("migrations[{index}] must be an object"))?;
        let id = object
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.trim().is_empty())
            .ok_or_else(|| format!("migrations[{index}].id must be a non-empty string"))?;
        if !seen.insert(id) {
            return Err(format!("migration history contains duplicate id: {id}"));
        }

        let from = object
            .get("fromVersion")
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("migrations[{index}].fromVersion must be an integer"))?;
        let to = object
            .get("toVersion")
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("migrations[{index}].toVersion must be an integer"))?;
        let applied_at = object
            .get("appliedAt")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| format!("migrations[{index}].appliedAt must be a non-empty string"))?;
        OffsetDateTime::parse(applied_at, &Rfc3339)
            .map_err(|_| format!("migrations[{index}].appliedAt must be an RFC3339 timestamp"))?;

        let migration = by_id
            .get(id)
            .ok_or_else(|| format!("migration history references unknown id: {id}"))?;
        if migration.from != from || migration.to != to {
            return Err(format!(
                "migration history version mismatch for {id}: recorded {from} -> {to}, registered {} -> {}",
                migration.from, migration.to
            ));
        }
        if let Some(expected_from) = previous_target
            && from != expected_from
        {
            return Err(format!(
                "migration history is not contiguous at {id}: expected source {expected_from}, got {from}"
            ));
        }
        previous_target = Some(to);
    }

    if let Some(last_target) = previous_target
        && last_target != version
    {
        return Err(format!(
            "migration history ends at version {last_target}, but ledgerVersion is {version}"
        ));
    }

    Ok(())
}

pub(crate) fn apply_migration_plan(
    document: &Value,
    plan: &[MigrationSpec],
    applied_at: &str,
) -> Result<Value, String> {
    if plan.is_empty() {
        return Ok(document.clone());
    }
    validate_plan(plan)?;
    OffsetDateTime::parse(applied_at, &Rfc3339)
        .map_err(|_| "migration appliedAt must be an RFC3339 timestamp".to_owned())?;

    let mut working = document.clone();
    let source = ledger_version(&working)?;
    if source != plan[0].from {
        return Err(format!(
            "migration plan starts at version {}, but ledgerVersion is {source}",
            plan[0].from
        ));
    }

    ensure_history_array(&mut working)?;
    let mut applied_ids = history_ids(&working)?;

    for migration in plan {
        if !applied_ids.insert(migration.id.to_owned()) {
            return Err(format!("migration {} was already applied", migration.id));
        }
        let current = ledger_version(&working)?;
        if current != migration.from {
            return Err(format!(
                "migration {} expected ledgerVersion {}, got {current}",
                migration.id, migration.from
            ));
        }

        (migration.apply)(&mut working)
            .map_err(|error| format!("migration {} failed: {error}", migration.id))?;

        let object = working.as_object_mut().ok_or_else(|| {
            format!(
                "migration {} replaced the ledger root with a non-object value",
                migration.id
            )
        })?;
        object.insert("ledgerVersion".to_owned(), json!(migration.to));
        let history = object
            .get_mut("migrations")
            .and_then(Value::as_array_mut)
            .ok_or_else(|| {
                format!(
                    "migration {} removed or invalidated the migrations history",
                    migration.id
                )
            })?;
        history.push(json!({
            "id": migration.id,
            "fromVersion": migration.from,
            "toVersion": migration.to,
            "appliedAt": applied_at,
        }));
    }

    Ok(working)
}

#[allow(dead_code)]
pub(crate) fn migrate_document(
    document: &Value,
    registry: &[MigrationSpec],
    target: i64,
    applied_at: &str,
) -> Result<Value, String> {
    validate_history(document, registry)?;
    let source = ledger_version(document)?;
    let plan = plan_migrations(registry, source, target)?;
    apply_migration_plan(document, &plan, applied_at)
}

fn validate_plan(plan: &[MigrationSpec]) -> Result<(), String> {
    validate_registry(plan)?;
    for pair in plan.windows(2) {
        if pair[0].to != pair[1].from {
            return Err(format!(
                "migration plan is not ordered: {} ends at {}, but {} starts at {}",
                pair[0].id, pair[0].to, pair[1].id, pair[1].from
            ));
        }
    }
    Ok(())
}

fn ledger_version(document: &Value) -> Result<i64, String> {
    document
        .as_object()
        .ok_or_else(|| "ledger root must be an object".to_owned())?
        .get("ledgerVersion")
        .and_then(Value::as_i64)
        .ok_or_else(|| "ledgerVersion must be an integer".to_owned())
}

fn ensure_history_array(document: &mut Value) -> Result<(), String> {
    let object = document
        .as_object_mut()
        .ok_or_else(|| "ledger root must be an object".to_owned())?;
    if !object.contains_key("migrations") {
        object.insert("migrations".to_owned(), json!([]));
    }
    if !object.get("migrations").is_some_and(Value::is_array) {
        return Err("ledger migrations must be an array".to_owned());
    }
    Ok(())
}

fn history_ids(document: &Value) -> Result<BTreeSet<String>, String> {
    let history = document
        .get("migrations")
        .and_then(Value::as_array)
        .ok_or_else(|| "ledger migrations must be an array".to_owned())?;
    let mut ids = BTreeSet::new();
    for (index, record) in history.iter().enumerate() {
        let id = record
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.trim().is_empty())
            .ok_or_else(|| format!("migrations[{index}].id must be a non-empty string"))?;
        if !ids.insert(id.to_owned()) {
            return Err(format!("migration history contains duplicate id: {id}"));
        }
    }
    Ok(ids)
}

#[cfg(test)]
mod tests {
    use super::*;

    const APPLIED_AT: &str = "2026-07-13T10:00:00Z";

    fn no_op(_: &mut Value) -> Result<(), String> {
        Ok(())
    }

    fn mark_applied(document: &mut Value) -> Result<(), String> {
        let count = document
            .get("testApplyCount")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        document["testApplyCount"] = json!(count + 1);
        Ok(())
    }

    fn mutate_then_fail(document: &mut Value) -> Result<(), String> {
        document["partialMutation"] = json!(true);
        Err("deliberate test failure".to_owned())
    }

    fn spec(id: &'static str, from: i64, to: i64, apply: MigrationApply) -> MigrationSpec {
        MigrationSpec {
            id,
            from,
            to,
            apply,
        }
    }

    #[test]
    fn current_registry_is_empty_and_valid() {
        assert!(MIGRATION_REGISTRY.is_empty());
        validate_registry(MIGRATION_REGISTRY).unwrap();
    }

    #[test]
    fn empty_plan_does_not_change_value() {
        let original = json!({"arbitrary": [1, 2, 3]});

        let migrated = apply_migration_plan(&original, &[], "").unwrap();

        assert_eq!(migrated, original);
    }

    #[test]
    fn registry_rejects_duplicate_ids() {
        let registry = [
            spec("duplicate", 1, 2, no_op),
            spec("duplicate", 2, 3, no_op),
        ];

        let error = validate_registry(&registry).unwrap_err();

        assert!(error.contains("duplicate migration id"), "{error}");
    }

    #[test]
    fn registry_rejects_forks_merges_gaps_and_reverse_steps() {
        let fork = [spec("one", 1, 2, no_op), spec("two", 1, 3, no_op)];
        let merge = [spec("one", 1, 3, no_op), spec("two", 2, 3, no_op)];
        let gap = [spec("one", 1, 2, no_op), spec("three", 3, 4, no_op)];
        let reverse = [spec("reverse", 2, 1, no_op)];

        assert!(validate_registry(&fork).unwrap_err().contains("fork"));
        assert!(validate_registry(&merge).unwrap_err().contains("merge"));
        assert!(validate_registry(&gap).unwrap_err().contains("gap"));
        assert!(
            validate_registry(&reverse)
                .unwrap_err()
                .contains("advance exactly one version")
        );
    }

    #[test]
    fn history_rejects_invalid_applied_at() {
        let registry = [spec("v1_to_v2", 1, 2, no_op)];
        let document = json!({
            "ledgerVersion": 2,
            "migrations": [{
                "id": "v1_to_v2",
                "fromVersion": 1,
                "toVersion": 2,
                "appliedAt": "not-a-timestamp"
            }]
        });

        let error = validate_history(&document, &registry).unwrap_err();

        assert!(error.contains("RFC3339"), "{error}");
    }

    #[test]
    fn migration_from_one_to_two_is_applied_only_once() {
        let registry = [spec("v1_to_v2", 1, 2, mark_applied)];
        let original = json!({"ledgerVersion": 1, "migrations": []});

        let migrated = migrate_document(&original, &registry, 2, APPLIED_AT).unwrap();
        let replayed = migrate_document(&migrated, &registry, 2, APPLIED_AT).unwrap();

        assert_eq!(original["ledgerVersion"], 1);
        assert_eq!(migrated["ledgerVersion"], 2);
        assert_eq!(migrated["testApplyCount"], 1);
        assert_eq!(migrated["migrations"].as_array().unwrap().len(), 1);
        assert_eq!(replayed, migrated);
    }

    #[test]
    fn failed_apply_does_not_change_original_value() {
        let original = json!({"ledgerVersion": 1, "migrations": [], "stable": true});
        let plan = [spec("v1_to_v2", 1, 2, mutate_then_fail)];

        let error = apply_migration_plan(&original, &plan, APPLIED_AT).unwrap_err();

        assert!(error.contains("deliberate test failure"), "{error}");
        assert_eq!(
            original,
            json!({"ledgerVersion": 1, "migrations": [], "stable": true})
        );
    }

    #[test]
    fn planner_orders_a_contiguous_registry_by_source_version() {
        let registry = [spec("v2_to_v3", 2, 3, no_op), spec("v1_to_v2", 1, 2, no_op)];

        let plan = plan_migrations(&registry, 1, 3).unwrap();

        assert_eq!(
            plan.iter()
                .map(|migration| migration.id)
                .collect::<Vec<_>>(),
            ["v1_to_v2", "v2_to_v3"]
        );
    }
}
