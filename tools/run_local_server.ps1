param(
  [int]$Port = 8791,
  [string]$LedgerPath = "tmp\ledger.json",
  [switch]$NoAuth
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([System.IO.Path]::IsPathRooted($LedgerPath)) {
  $LedgerFullPath = $LedgerPath
} else {
  $LedgerFullPath = Join-Path $Root $LedgerPath
}

$LedgerDir = Split-Path -Parent $LedgerFullPath
if ($LedgerDir) {
  New-Item -ItemType Directory -Force -Path $LedgerDir | Out-Null
}

$Cargo = Get-Command cargo -ErrorAction SilentlyContinue
if ($Cargo) {
  $CargoExe = $Cargo.Source
} else {
  $CargoExe = Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe"
}
if (!(Test-Path $CargoExe)) {
  throw "cargo not found. Expected cargo on PATH or at $CargoExe"
}

$ManifestPath = Join-Path $Root "server-rs\Cargo.toml"
Write-Host "Starting Finwealth local server"
Write-Host "  API:    http://127.0.0.1:$Port"
Write-Host "  Ledger: $LedgerFullPath"
Write-Host "  Auth:   $(if ($NoAuth) { 'disabled (explicit -NoAuth)' } else { 'required' })"

if ($NoAuth) {
  $env:FINWEALTH_REQUIRE_AUTH = "false"
  Write-Warning "Starting a writable local ledger without auth. Use only for isolated development."
} else {
  $env:FINWEALTH_REQUIRE_AUTH = "true"
  if ([string]::IsNullOrWhiteSpace($env:FINWEALTH_AUTH_USERNAME) -or [string]::IsNullOrWhiteSpace($env:FINWEALTH_AUTH_PASSWORD_HASH)) {
    throw "Auth is required by default. Set FINWEALTH_AUTH_USERNAME and FINWEALTH_AUTH_PASSWORD_HASH, use tools\run_self_use_windows.ps1, or pass -NoAuth for explicit isolated development."
  }
}

& $CargoExe run --manifest-path $ManifestPath -- --port $Port --ledger-path $LedgerFullPath
