param(
  [string]$LedgerPath = "tmp\ledger.json",
  [string]$BackupDir = "backups",
  [switch]$SkipValidate
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([System.IO.Path]::IsPathRooted($LedgerPath)) {
  $LedgerFullPath = $LedgerPath
} else {
  $LedgerFullPath = Join-Path $Root $LedgerPath
}

if ([System.IO.Path]::IsPathRooted($BackupDir)) {
  $BackupRoot = $BackupDir
} else {
  $BackupRoot = Join-Path $Root $BackupDir
}

if (!(Test-Path $LedgerFullPath)) {
  throw "ledger file not found: $LedgerFullPath"
}

$Cargo = Get-Command cargo -ErrorAction SilentlyContinue
$CargoExe = if ($Cargo) { $Cargo.Source } else { Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe" }
$ManifestPath = Join-Path $Root "server-rs\Cargo.toml"

if (!$SkipValidate) {
  if (!(Test-Path $CargoExe)) {
    throw "cargo not found; cannot validate ledger. Re-run with -SkipValidate to copy only."
  }
  & $CargoExe run --manifest-path $ManifestPath -- --validate-ledger $LedgerFullPath
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$target = Join-Path $BackupRoot $timestamp
New-Item -ItemType Directory -Force -Path $target | Out-Null

$files = @()
$ledgerCopy = Join-Path $target "ledger.json"
Copy-Item -LiteralPath $LedgerFullPath -Destination $ledgerCopy -Force
$files += $ledgerCopy

$authPath = [System.IO.Path]::ChangeExtension($LedgerFullPath, "auth.json")
if (Test-Path $authPath) {
  $authCopy = Join-Path $target "ledger.auth.json"
  Copy-Item -LiteralPath $authPath -Destination $authCopy -Force
  $files += $authCopy
}

$manifestPath = Join-Path $target "manifest.txt"
@(
  "createdAt=$(Get-Date -Format o)"
  "sourceLedger=$LedgerFullPath"
  "sourceAuth=$authPath"
  "validated=$(!$SkipValidate)"
  ""
  "sha256:"
) | Set-Content -LiteralPath $manifestPath -Encoding UTF8

foreach ($file in $files) {
  $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $file
  Add-Content -LiteralPath $manifestPath -Value "$($hash.Hash)  $(Split-Path -Leaf $file)"
}

Write-Host "Backup created: $target"
