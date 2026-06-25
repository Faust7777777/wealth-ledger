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

#[derive(Debug)]
pub enum LedgerError {
    InvalidInput(Vec<String>),
    Conflict(String),
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
        .map(project_account_for_api)
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

fn project_account_for_api(account: &Value) -> Value {
    let mut projected = account.clone();

    if projected.get("value").is_none()
        && let Some(value) = projected_account_value(account)
    {
        projected["value"] = value;
    }

    projected
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
