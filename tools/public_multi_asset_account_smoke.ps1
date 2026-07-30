param(
  [int]$Port = 18887
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$server = Join-Path $root "server-rs\target\debug\finwealth-server.exe"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("finwealth-public-multi-asset-" + [guid]::NewGuid().ToString("N"))
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
    -Body ($Body | ConvertTo-Json -Depth 12 -Compress) `
    -TimeoutSec 60
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

  $account = Invoke-JsonPost `
    -Uri "$base/v1/accounts" `
    -IdempotencyKey "multi-asset-smoke-account" `
    -Body @{
      displayName = "OKX Quote Smoke"
      accountType = "exchange"
      defaultCurrency = "CNY"
      supportedCurrencies = @("CNY")
      includeInNetWorth = $true
      balanceMode = "holdings"
      openingBalances = @()
    }
  $accountId = [string]$account.data.id
  if (!$accountId) { throw "account creation returned no id" }

  $ensured = Invoke-JsonPost `
    -Uri "$base/v1/accounts/$accountId/crypto-instruments/ensure" `
    -IdempotencyKey "multi-asset-smoke-instruments" `
    -Body @{ symbols = @("BTC", "ETH", "USDT", "SOL") }
  $instruments = @($ensured.data.instruments)
  if ($instruments.Count -ne 4) { throw "crypto ensure did not return four instruments" }
  $bySymbol = @{}
  foreach ($instrument in $instruments) {
    $bySymbol[[string]$instrument.symbol] = $instrument
  }
  foreach ($symbol in @("BTC", "ETH", "USDT", "SOL")) {
    if (!$bySymbol.ContainsKey($symbol) -or ![string]$bySymbol[$symbol].id) {
      throw "crypto ensure omitted $symbol"
    }
  }
  if ($bySymbol["SOL"].quoteCurrency -ne "USDT") {
    throw "discovered crypto must retain its USDT market quote unit"
  }

  $instrumentIds = @($instruments | ForEach-Object { [string]$_.id })
  $lookup = Invoke-JsonPost `
    -Uri "$base/v1/quotes/lookup" `
    -Body @{
      instruments = $instrumentIds
      currencyPairs = @(@{ baseCurrency = "USDT"; quoteCurrency = "CNY" })
    }
  if ($lookup.data.status -ne "success") {
    throw "multi-asset lookup was not a complete success"
  }
  $quotes = @($lookup.data.quotes)
  $fxRates = @($lookup.data.fxRates)
  if ($quotes.Count -ne 4 -or @($lookup.data.errors).Count -ne 0) {
    throw "multi-asset lookup shape mismatch: quotes=$($quotes.Count), fxRates=$($fxRates.Count), errors=$(@($lookup.data.errors).Count)"
  }
  if ((@($quotes | ForEach-Object { [string]$_.instrumentId }) -join "|") -ne ($instrumentIds -join "|")) {
    throw "multi-asset lookup did not preserve instrument order"
  }
  $fxPairKeys = @($fxRates | ForEach-Object {
    "$([string]$_.baseCurrency)/$([string]$_.quoteCurrency)"
  } | Sort-Object -Unique)
  $directPath = $fxPairKeys.Count -eq 1 -and $fxPairKeys[0] -eq "USDT/CNY"
  $bridgePath = `
    $fxPairKeys.Count -eq 2 -and `
    $fxPairKeys -contains "USDT/USD" -and `
    $fxPairKeys -contains "USD/CNY"
  if (!$directPath -and !$bridgePath) {
    throw "multi-asset lookup returned no usable USDT-to-CNY FX path"
  }
  foreach ($item in @($quotes) + @($fxRates)) {
    $number = if ($null -ne $item.price) { $item.price } else { $item.rate }
    if ([decimal]::Parse([string]$number, [Globalization.CultureInfo]::InvariantCulture) -le 0) {
      throw "provider returned a non-positive quote or FX rate"
    }
  }
  if (@((Invoke-RestMethod -Uri "$base/v1/quotes").data).Count -ne 0) {
    throw "read-only lookup changed authoritative quotes"
  }

  $requestedAt = [DateTimeOffset]::UtcNow.ToString("o")
  $refresh = Invoke-JsonPost `
    -Uri "$base/v1/quotes/refresh" `
    -IdempotencyKey "multi-asset-smoke-apply-quotes" `
    -Body @{
      mode = "manual"
      requestedAt = $requestedAt
      quotes = $quotes
      fxRates = $fxRates
    }
  if ($refresh.data.status -ne "success") { throw "confirmed provider values were not stored" }

  $quantities = [ordered]@{ BTC = "0.25"; ETH = "3.2"; USDT = "1250"; SOL = "12" }
  $positions = @($quantities.GetEnumerator() | ForEach-Object {
    @{ instrumentId = [string]$bySymbol[$_.Key].id; targetQuantity = $_.Value }
  })
  $proposal = Invoke-JsonPost `
    -Uri "$base/v1/accounts/$accountId/holding-snapshot-proposals" `
    -IdempotencyKey "multi-asset-smoke-snapshot" `
    -Body @{ asOf = $requestedAt; positions = $positions; note = "multi-asset smoke" }
  $groupId = [string]$proposal.data.id
  if (!$groupId) { throw "holding snapshot returned no group id" }
  Invoke-JsonPost `
    -Uri "$base/v1/atomic-groups/$groupId/confirm" `
    -IdempotencyKey "multi-asset-smoke-confirm" `
    -Body @{} | Out-Null

  $holdings = @((Invoke-RestMethod -Uri "$base/v1/accounts/$accountId/holdings").data)
  if ($holdings.Count -ne 4) { throw "confirmed account did not retain four holdings" }
  foreach ($holding in $holdings) {
    $symbol = [string]$holding.instrument.symbol
    if (!$quantities.Contains($symbol) -or [string]$holding.quantity -ne $quantities[$symbol]) {
      throw "confirmed holding did not retain the original $symbol quantity"
    }
    if ($holding.accountMarketValue.currency -ne "CNY") {
      throw "$symbol was not valued in the account display currency"
    }
  }

  Write-Host "Public multi-asset smoke passed: BTC/ETH/USDT/SOL quantities retained and valued in CNY."
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
