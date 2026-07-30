param(
  [int]$Port = 18886
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$server = Join-Path $root "server-rs\target\debug\finwealth-server.exe"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("finwealth-public-investment-quotes-" + [guid]::NewGuid().ToString("N"))
$process = $null
$saved = @{}

function Set-SmokeEnvironment([string]$Name, [string]$Value) {
  $script:saved[$Name] = [Environment]::GetEnvironmentVariable($Name, "Process")
  [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
}

function Invoke-JsonPost([string]$Uri, [hashtable]$Body, [string]$IdempotencyKey = "") {
  $headers = @{}
  if ($IdempotencyKey) { $headers["Idempotency-Key"] = $IdempotencyKey }
  Invoke-RestMethod `
    -Method Post `
    -Uri $Uri `
    -Headers $headers `
    -ContentType "application/json" `
    -Body ($Body | ConvertTo-Json -Depth 10 -Compress) `
    -TimeoutSec 30
}

try {
  New-Item -ItemType Directory -Path $temp | Out-Null
  & cargo build --quiet --manifest-path (Join-Path $root "server-rs\Cargo.toml")
  if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }

  Set-SmokeEnvironment "FINWEALTH_RS_ADDR" "127.0.0.1:$Port"
  Set-SmokeEnvironment "FINWEALTH_QUOTE_PROVIDER" "public"
  Set-SmokeEnvironment "FINWEALTH_REQUIRE_AUTH" "false"
  Set-SmokeEnvironment "FINWEALTH_PASSWORD_HASH" ""
  Set-SmokeEnvironment "FINWEALTH_ALLOWED_HOSTS" ""
  $existingNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Process")
  $smokeNoProxy = @("127.0.0.1", "localhost", "::1", $existingNoProxy) |
    Where-Object { $_ } |
    Select-Object -Unique
  Set-SmokeEnvironment "NO_PROXY" ($smokeNoProxy -join ",")

  $process = Start-Process `
    -FilePath $server `
    -ArgumentList @("--ledger-path", (Join-Path $temp "ledger.json")) `
    -WorkingDirectory $root `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput (Join-Path $temp "server.out") `
    -RedirectStandardError (Join-Path $temp "server.err")

  $base = "http://127.0.0.1:$Port"
  $ready = $false
  for ($attempt = 0; $attempt -lt 100; $attempt += 1) {
    try {
      $health = Invoke-RestMethod -Uri "$base/v1/health" -TimeoutSec 2
      if ($health.data.status -eq "ok") { $ready = $true; break }
    } catch {
      Start-Sleep -Milliseconds 100
    }
  }
  if (!$ready) { throw "temporary Rust server did not become ready" }

  $before = Invoke-RestMethod -Uri "$base/v1/quotes" -TimeoutSec 10
  if (@($before.data).Count -ne 0) { throw "temporary ledger unexpectedly contains quotes" }

  $account = Invoke-JsonPost `
    -Uri "$base/v1/accounts" `
    -IdempotencyKey "public-investment-smoke-account" `
    -Body @{
      displayName = "Quote Smoke Brokerage"
      accountType = "brokerage"
      defaultCurrency = "CNY"
      supportedCurrencies = @("CNY", "USD")
      includeInNetWorth = $true
      balanceMode = "holdings"
      openingBalances = @()
    }
  $accountId = [string]$account.data.id
  if (!$accountId) { throw "account creation returned no id" }

  $investmentInstruments = @(
    @("AAPL", "Apple", "NASDAQ"),
    @("MSFT", "Microsoft", "NASDAQ"),
    @("GOOG", "Alphabet", "NASDAQ"),
    @("AMZN", "Amazon", "NASDAQ"),
    @("META", "Meta", "NASDAQ"),
    @("NVDA", "NVIDIA", "NASDAQ"),
    @("TSLA", "Tesla", "NASDAQ"),
    @("JPM", "JPMorgan", "NYSE"),
    @("XOM", "Exxon Mobil", "NYSE")
  ) | ForEach-Object {
    @{
      type = "equity"
      symbol = $_[0]
      displayName = $_[1]
      quoteCurrency = "USD"
      market = $_[2]
    }
  }
  $investmentInstruments += @{
    type = "fund"
    symbol = "510300"
    displayName = "SSE 300 ETF"
    quoteCurrency = "CNY"
    market = "SSE"
  }
  $ensured = Invoke-JsonPost `
    -Uri "$base/v1/accounts/$accountId/investment-instruments/ensure" `
    -IdempotencyKey "public-investment-smoke-instruments" `
    -Body @{ instruments = $investmentInstruments }
  $instrumentIds = @($ensured.data.instruments | ForEach-Object { [string]$_.id })
  if ($instrumentIds.Count -ne 10 -or $instrumentIds -contains "") {
    throw "instrument ensure did not return ten real ids"
  }

  $lookup = Invoke-JsonPost `
    -Uri "$base/v1/quotes/lookup" `
    -Body @{ instruments = $instrumentIds; currencyPairs = @() }
  $quotes = @($lookup.data.quotes)
  if ($quotes.Count -ne 10) {
    throw "public provider did not return all ten investment quotes"
  }
  foreach ($quote in $quotes) {
    if ($quote.source -ne "yahoo_finance_api") { throw "unexpected investment quote source" }
    if ([decimal]::Parse([string]$quote.price, [Globalization.CultureInfo]::InvariantCulture) -le 0) {
      throw "investment quote price is not positive"
    }
  }
  $currencies = @($quotes | ForEach-Object { [string]$_.currency } | Sort-Object -Unique)
  if ($currencies.Count -ne 2 -or $currencies -notcontains "CNY" -or $currencies -notcontains "USD") {
    throw "investment quote currencies do not match registered instruments"
  }

  $after = Invoke-RestMethod -Uri "$base/v1/quotes" -TimeoutSec 10
  if (@($after.data).Count -ne 0) { throw "read-only lookup wrote authoritative quotes" }

  Write-Host "Public investment quote smoke passed: ten structured candidates, ledger unchanged."
} finally {
  if ($process -and !$process.HasExited) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    $process.WaitForExit()
  }
  foreach ($entry in $saved.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
  }
  if (Test-Path -LiteralPath $temp) {
    $resolved = [IO.Path]::GetFullPath($temp)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (!$resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
      throw "refusing to remove a temporary path outside the OS temp directory"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}
