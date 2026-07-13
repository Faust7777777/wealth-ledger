param(
  [string]$LedgerPath = "tmp\ledger.json",
  [string]$BackupDir = "backups",
  [string]$ServerExecutable = "",
  [switch]$SkipValidate
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-RepoPath {
  param([string]$Root, [string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Assert-RegularFile {
  param([string]$Path, [string]$Label)
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Label must be a regular file: $Path"
  }
  $item = Get-Item -LiteralPath $Path -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "$Label must not be a symlink or reparse point: $Path"
  }
}

function Invoke-ServerValidation {
  param(
    [ValidateSet("ledger", "auth")]
    [string]$Kind,
    [string]$Path,
    [string]$Root,
    [string]$ServerExecutable
  )

  $argument = if ($Kind -eq "ledger") { "--validate-ledger" } else { "--validate-auth-state" }
  if ($ServerExecutable) {
    Assert-RegularFile -Path $ServerExecutable -Label "server executable"
    & $ServerExecutable $argument $Path
  } else {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    $cargoExe = if ($cargo) { $cargo.Source } else { Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe" }
    if (!(Test-Path -LiteralPath $cargoExe -PathType Leaf)) {
      throw "cargo not found; cannot validate $Kind state. Re-run with -SkipValidate only for an emergency copy."
    }
    & $cargoExe run --quiet --manifest-path (Join-Path $Root "server-rs\Cargo.toml") -- $argument $Path
  }
  if ($LASTEXITCODE -ne 0) {
    throw "$Kind validation failed: $Path"
  }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ledgerFullPath = Resolve-RepoPath $root $LedgerPath
$backupRoot = Resolve-RepoPath $root $BackupDir
$authPath = [System.IO.Path]::ChangeExtension($ledgerFullPath, "auth.json")

Assert-RegularFile -Path $ledgerFullPath -Label "ledger"
if (Test-Path -LiteralPath $authPath) {
  Assert-RegularFile -Path $authPath -Label "auth state"
}

New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
$backupRootItem = Get-Item -LiteralPath $backupRoot -Force
if (($backupRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
  throw "backup root must not be a symlink or reparse point: $backupRoot"
}

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmssZ")
$staging = Join-Path $backupRoot ".$timestamp-$([Guid]::NewGuid().ToString('N')).staging"
$target = Join-Path $backupRoot $timestamp
$suffix = 1
while (Test-Path -LiteralPath $target) {
  $target = Join-Path $backupRoot "$timestamp-$suffix"
  $suffix += 1
}

$published = $false
try {
  New-Item -ItemType Directory -Path $staging | Out-Null
  $sourceAuthExistsBefore = Test-Path -LiteralPath $authPath -PathType Leaf
  $sourceLedgerHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $ledgerFullPath).Hash
  $sourceAuthHashBefore = if ($sourceAuthExistsBefore) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $authPath).Hash
  } else {
    ""
  }

  $ledgerCopy = Join-Path $staging "ledger.json"
  Copy-Item -LiteralPath $ledgerFullPath -Destination $ledgerCopy

  $includesAuth = $sourceAuthExistsBefore
  $authCopy = Join-Path $staging "ledger.auth.json"
  if ($includesAuth) {
    Copy-Item -LiteralPath $authPath -Destination $authCopy
  }

  $sourceAuthExistsAfter = Test-Path -LiteralPath $authPath -PathType Leaf
  $sourceLedgerHashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $ledgerFullPath).Hash
  $sourceAuthHashAfter = if ($sourceAuthExistsAfter) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $authPath).Hash
  } else {
    ""
  }
  if (
    $sourceLedgerHashBefore -ne $sourceLedgerHashAfter -or
    $sourceAuthExistsBefore -ne $sourceAuthExistsAfter -or
    $sourceAuthHashBefore -ne $sourceAuthHashAfter
  ) {
    throw "ledger or auth state changed while the backup was being copied; close the app and retry"
  }

  $validatedLedger = "false"
  $validatedAuth = if ($includesAuth) { "false" } else { "not_present" }
  if (!$SkipValidate) {
    Invoke-ServerValidation -Kind ledger -Path $ledgerCopy -Root $root -ServerExecutable $ServerExecutable
    $validatedLedger = "true"
    if ($includesAuth) {
      Invoke-ServerValidation -Kind auth -Path $authCopy -Root $root -ServerExecutable $ServerExecutable
      $validatedAuth = "true"
    }
  }

  $checksumLines = @()
  foreach ($name in @("ledger.json", "ledger.auth.json")) {
    $file = Join-Path $staging $name
    if (Test-Path -LiteralPath $file -PathType Leaf) {
      $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
      $checksumLines += "$hash  $name"
    }
  }
  $checksumLines | Set-Content -LiteralPath (Join-Path $staging "SHA256SUMS") -Encoding ASCII

  @(
    "backupFormat=1"
    "createdAt=$((Get-Date).ToUniversalTime().ToString('o'))"
    "ledgerFile=ledger.json"
    "includesAuth=$($includesAuth.ToString().ToLowerInvariant())"
    $(if ($includesAuth) { "authFile=ledger.auth.json" })
    "validatedLedger=$validatedLedger"
    "validatedAuth=$validatedAuth"
  ) | Where-Object { $_ -ne $null } | Set-Content -LiteralPath (Join-Path $staging "manifest.txt") -Encoding ASCII

  Move-Item -LiteralPath $staging -Destination $target
  $published = $true
} finally {
  if (!$published -and (Test-Path -LiteralPath $staging)) {
    Remove-Item -LiteralPath $staging -Recurse -Force
  }
}

Write-Host "Backup created: $target"
