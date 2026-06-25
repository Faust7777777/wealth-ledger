use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs, io,
    ops::{Add, AddAssign, Neg, Sub},
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

pub fn portfolio_overview(path: &Path, now: &str) -> io::Result<Value> {
    let document = load_or_initialize(path)?;
    let summary = summarize_accounts(&document, now)?;

    Ok(json!({
        "latestSnapshot": summary.latest_snapshot,
        "previousSnapshot": Value::Null,
        "pendingSummary": {
            "aiPendingCount": 0,
            "accountAnomalyCount": summary.account_anomaly_count,
            "dcaDueCount": 0,
            "inTransitCount": 0,
            "quoteProblemCount": summary.unpriceable_count,
            "syncProblemCount": 0
        },
        "quoteStatusSummary": {
            "freshCount": 0,
            "staleCount": 0,
            "offlineCachedCount": 0,
            "unpriceableCount": summary.unpriceable_count,
            "errorCount": 0
        },
        "primaryHoldings": [],
        "recentMovements": []
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
    Ok(summarize_accounts(&document, now)?.latest_snapshot)
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

struct AccountSummary {
    base_currency: String,
    gross_assets: DecimalAmount,
    total_liabilities: DecimalAmount,
    unpriceable_count: u64,
    account_anomaly_count: u64,
    latest_snapshot: Value,
    allocation_slices: Vec<Value>,
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
    let mut unpriceable_count = 0_u64;
    let mut account_anomaly_count = 0_u64;
    let mut included_account_count = 0_u64;
    let mut account_values = Vec::new();
    let mut allocation_by_category: BTreeMap<String, DecimalAmount> = BTreeMap::new();
    let mut quality = "exact";

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
            quality = combine_quality(
                quality,
                balance
                    .get("quality")
                    .and_then(Value::as_str)
                    .unwrap_or("exact"),
            );
        }

        if !has_base_value {
            continue;
        }

        let account_id = account
            .get("id")
            .and_then(Value::as_str)
            .expect("validated account id should be a string");
        account_values.push(json!({
            "accountId": account_id,
            "value": {
                "amount": money_amount(account_total),
                "currency": base_currency,
                "asOf": now,
                "quality": quality
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
                "freshCount": 0,
                "staleCount": 0,
                "offlineCachedCount": 0,
                "unpriceableCount": unpriceable_count,
                "errorCount": 0
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
        unpriceable_count,
        account_anomaly_count,
        latest_snapshot,
        allocation_slices,
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
