use serde_json::{Value, json};
use std::{
    fs, io,
    path::{Path, PathBuf},
};

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
        }
    }
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
