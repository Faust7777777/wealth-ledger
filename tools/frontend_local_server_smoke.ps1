param(
  [string]$ServerExecutable = "",
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "finwealth-frontend-local-$([Guid]::NewGuid().ToString('N'))"
$ledgerPath = Join-Path $tempRoot "ledger.json"
$stdout = Join-Path $tempRoot "server.out.log"
$stderr = Join-Path $tempRoot "server.err.log"
$process = $null

function Get-FreeTcpPort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try {
    return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  } finally {
    $listener.Stop()
  }
}

try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  if (!$ServerExecutable) {
    if (!$SkipBuild) {
      & cargo build --quiet --manifest-path (Join-Path $root "server-rs\Cargo.toml")
      if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed"
      }
    }
    $ServerExecutable = Join-Path $root "server-rs\target\debug\finwealth-server.exe"
  }
  if (!(Test-Path -LiteralPath $ServerExecutable -PathType Leaf)) {
    throw "server executable not found: $ServerExecutable"
  }

  $port = Get-FreeTcpPort
  $baseUrl = "http://127.0.0.1:$port"
  $quotedLedgerPath = '"' + $ledgerPath + '"'
  $process = Start-Process `
    -FilePath $ServerExecutable `
    -ArgumentList @("--ledger-path", $quotedLedgerPath, "--addr", "127.0.0.1:$port") `
    -WorkingDirectory $root `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr

  $ready = $false
  for ($attempt = 0; $attempt -lt 80; $attempt += 1) {
    if ($process.HasExited) {
      throw "server exited before readiness: $(Get-Content -Raw $stderr)"
    }
    try {
      $health = Invoke-RestMethod -Uri "$baseUrl/v1/health" -TimeoutSec 2
      if ($health.ok -eq $true) {
        $ready = $true
        break
      }
    } catch {
      Start-Sleep -Milliseconds 250
    }
  }
  if (!$ready) {
    throw "server did not become ready"
  }

  $flutterExitCode = 1
  Push-Location $root
  try {
    # 联调文件共享同一账本进程：--concurrency=1 串行执行，避免写入交错。
    & flutter test "--dart-define=LOCAL_SERVER_API_BASE=$baseUrl" --concurrency=1 `
      test/local_server_subscription_integration_test.dart `
      test/local_server_account_integration_test.dart `
      test/local_server_dca_integration_test.dart `
      test/local_server_investment_trade_integration_test.dart `
      test/local_server_holding_adjustment_integration_test.dart `
      test/local_server_loan_interest_integration_test.dart `
      test/local_server_ai_text_integration_test.dart
    $flutterExitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  if ($flutterExitCode -ne 0) {
    throw "Flutter local-server integration tests failed"
  }
  Write-Host "OK: Flutter local-server integration smoke passed (subscriptions + accounts + dca + trades + holdings + loans + ai-text)"
} catch {
  Write-Host "FAILED: $($_.Exception.Message)"
  foreach ($logPath in @($stdout, $stderr)) {
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
      Write-Host "Server log: $([System.IO.Path]::GetFileName($logPath))"
      Get-Content -LiteralPath $logPath | Write-Host
    }
  }
  throw
} finally {
  if ($process -and !$process.HasExited) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    try {
      $process.WaitForExit(5000) | Out-Null
    } catch {
      Write-Warning "Could not wait for the local test server to exit: $($_.Exception.Message)"
    }
  }
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
