param(
  [int]$Port = 8791,
  [string]$LedgerPath = "tmp\ledger.json"
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

& $CargoExe run --manifest-path $ManifestPath -- --port $Port --ledger-path $LedgerFullPath
