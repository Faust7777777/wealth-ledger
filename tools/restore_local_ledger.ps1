param(
  [Parameter(Mandatory = $true)]
  [string]$BackupPath,
  [string]$LedgerPath = "tmp\ledger.json",
  [string]$PreRestoreBackupDir = "backups\pre-restore",
  [switch]$SkipValidate,
  [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-RepoPath {
  param([string]$Root, [string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path $Root $Path
}

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$BackupFullPath = Resolve-RepoPath $Root $BackupPath
$LedgerFullPath = Resolve-RepoPath $Root $LedgerPath
$PreRestoreFullDir = Resolve-RepoPath $Root $PreRestoreBackupDir

if (!(Test-Path $BackupFullPath)) {
  throw "backup path not found: $BackupFullPath"
}

if ((Get-Item $BackupFullPath).PSIsContainer) {
  $BackupLedger = Join-Path $BackupFullPath "ledger.json"
  $BackupAuth = Join-Path $BackupFullPath "ledger.auth.json"
} else {
  $BackupLedger = $BackupFullPath
  $BackupAuth = $null
}

if (!(Test-Path $BackupLedger)) {
  throw "backup ledger not found: $BackupLedger"
}

$Cargo = Get-Command cargo -ErrorAction SilentlyContinue
$CargoExe = if ($Cargo) { $Cargo.Source } else { Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe" }
$ManifestPath = Join-Path $Root "server-rs\Cargo.toml"

if (!$SkipValidate) {
  if (!(Test-Path $CargoExe)) {
    throw "cargo not found; cannot validate backup ledger. Re-run with -SkipValidate to copy only."
  }
  & $CargoExe run --manifest-path $ManifestPath -- --validate-ledger $BackupLedger
}

if (!$Force) {
  Write-Host "About to restore:"
  Write-Host "  from: $BackupLedger"
  Write-Host "  to:   $LedgerFullPath"
  Write-Host "Current ledger will be backed up first."
  $answer = Read-Host "Type RESTORE to continue"
  if ($answer -ne "RESTORE") {
    Write-Host "Restore cancelled."
    return
  }
}

if (Test-Path $LedgerFullPath) {
  & (Join-Path $PSScriptRoot "backup_local_ledger.ps1") `
    -LedgerPath $LedgerFullPath `
    -BackupDir $PreRestoreFullDir `
    -SkipValidate:$SkipValidate
}

$LedgerDir = Split-Path -Parent $LedgerFullPath
if ($LedgerDir) {
  New-Item -ItemType Directory -Force -Path $LedgerDir | Out-Null
}

Copy-Item -LiteralPath $BackupLedger -Destination $LedgerFullPath -Force

if ($BackupAuth -and (Test-Path $BackupAuth)) {
  $AuthTarget = [System.IO.Path]::ChangeExtension($LedgerFullPath, "auth.json")
  Copy-Item -LiteralPath $BackupAuth -Destination $AuthTarget -Force
}

Write-Host "Restore complete: $LedgerFullPath"
