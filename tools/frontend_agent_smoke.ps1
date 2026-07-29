# 前端 Agent 联调 smoke：按 tools/agent_local_smoke.ps1 的方式起 Rust + Node，
# 然后只跑 Flutter 侧的 Agent 联调用例。不修改后端 smoke，也不配置任何模型凭据。
param(
  [int]$ServerPort = 18994,
  [int]$AgentPort = 18996
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "finwealth-frontend-agent-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temp | Out-Null
$server = $null
$agent = $null
$savedModelEnvironment = @{}
$token = [Convert]::ToHexString(
  [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
).ToLowerInvariant()

try {
  $serverExecutable = Join-Path $root "server-rs\target\debug\finwealth-server.exe"
  & cargo build --quiet --manifest-path (Join-Path $root "server-rs\Cargo.toml")
  if ($LASTEXITCODE -ne 0) { throw "cargo build failed." }
  $agentDir = Join-Path $root "agent-service"
  if (!(Test-Path -LiteralPath (Join-Path $agentDir "node_modules") -PathType Container)) {
    & npm --prefix $agentDir ci --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw "Agent dependency install failed." }
  }
  & npm --prefix $agentDir run build
  if ($LASTEXITCODE -ne 0) { throw "Agent TypeScript build failed." }
  $agentExecutable = Join-Path $root "agent-service\dist\main.js"

  $env:FINWEALTH_AGENT_BASE_URL = "http://127.0.0.1:$AgentPort"
  $env:FINWEALTH_AGENT_INTERNAL_TOKEN = $token
  $server = Start-Process `
    -FilePath $serverExecutable `
    -ArgumentList @(
      "--ledger-path", (Join-Path $temp "ledger.json"),
      "--addr", "127.0.0.1:$ServerPort"
    ) `
    -WorkingDirectory $root `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput (Join-Path $temp "server.out") `
    -RedirectStandardError (Join-Path $temp "server.err")

  $env:FINWEALTH_AGENT_ADDR = "127.0.0.1:$AgentPort"
  $env:FINWEALTH_SERVER_BASE_URL = "http://127.0.0.1:$ServerPort"
  $env:FINWEALTH_AGENT_STATE_DIR = Join-Path $temp "agent-state"
  $env:PI_CODING_AGENT_DIR = Join-Path $temp "pi"
  # 清掉模型凭据：本 smoke 只验证无模型时的 fail-closed 行为。
  Get-ChildItem Env: | Where-Object {
    $_.Name -match "(_API_KEY|_AUTH_TOKEN|_OAUTH_TOKEN)$"
  } | ForEach-Object {
    $savedModelEnvironment[$_.Name] = $_.Value
    Remove-Item "Env:$($_.Name)"
  }
  $agent = Start-Process `
    -FilePath "node" `
    -ArgumentList @($agentExecutable) `
    -WorkingDirectory (Join-Path $root "agent-service") `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput (Join-Path $temp "agent.out") `
    -RedirectStandardError (Join-Path $temp "agent.err")

  $ready = $false
  for ($attempt = 0; $attempt -lt 100; $attempt += 1) {
    try {
      $status = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$ServerPort/v1/agent/status" -TimeoutSec 2
      if ($status.data.service -eq "finwealth-agent") { $ready = $true; break }
    } catch {
      Start-Sleep -Milliseconds 150
    }
  }
  if (!$ready) { throw "Agent proxy did not become ready." }

  $flutterExitCode = 1
  Push-Location $root
  try {
    & flutter test `
      "--dart-define=LOCAL_SERVER_API_BASE=http://127.0.0.1:$ServerPort" `
      --concurrency=1 `
      test/local_server_agent_integration_test.dart
    $flutterExitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  if ($flutterExitCode -ne 0) { throw "Flutter agent integration test failed." }
  Write-Host "OK: Flutter agent integration smoke passed (proxy + conversations + attachments + fail-closed)"
} catch {
  Write-Host "FAILED: $($_.Exception.Message)"
  foreach ($logName in @("server.err", "agent.err", "server.out", "agent.out")) {
    $logPath = Join-Path $temp $logName
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
      $content = Get-Content -Raw -LiteralPath $logPath
      if ($content) { Write-Host "--- $logName ---`n$content" }
    }
  }
  exit 1
} finally {
  foreach ($process in @($agent, $server)) {
    if ($process -and !$process.HasExited) {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
  }
  foreach ($name in $savedModelEnvironment.Keys) {
    Set-Item "Env:$name" $savedModelEnvironment[$name]
  }
  Remove-Item -Recurse -Force -LiteralPath $temp -ErrorAction SilentlyContinue
}
