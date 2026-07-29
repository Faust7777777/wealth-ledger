param(
  [Parameter(Mandatory = $true)]
  [string]$BackupPath,
  [string]$LedgerPath = "tmp\ledger.json",
  [string]$PreRestoreBackupDir = "backups\pre-restore",
  [string]$ServerExecutable = "",
  [switch]$SkipValidate,
  [switch]$AllowUnverified,
  [switch]$Force
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

function Assert-NotReparsePoint {
  param([string]$Path, [string]$Label)
  $item = Get-Item -LiteralPath $Path -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "$Label must not be a symlink or reparse point: $Path"
  }
}

function Assert-RegularFile {
  param([string]$Path, [string]$Label)
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Label must be a regular file: $Path"
  }
  Assert-NotReparsePoint -Path $Path -Label $Label
}

function Acquire-LedgerRestoreLease {
  param([string]$LedgerPath)

  $lockPath = "$LedgerPath.lock"
  if (Test-Path -LiteralPath $lockPath) {
    Assert-RegularFile -Path $lockPath -Label "ledger lock sidecar"
  }

  $stream = $null
  try {
    $stream = [System.IO.FileStream]::new(
      $lockPath,
      [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
    $stream.Lock(0, 1)
    return $stream
  } catch {
    if ($null -ne $stream) {
      $stream.Dispose()
    }
    throw "restore refused because the ledger lock is held or cannot be acquired; stop the local server and retry"
  }
}

function Release-LedgerRestoreLease {
  param([System.IO.FileStream]$Lease)

  try {
    $Lease.Unlock(0, 1)
  } catch {
    # Disposing the handle still releases the OS lock. Never delete the
    # permanent sidecar based on PID, age, or unlock outcome.
  } finally {
    $Lease.Dispose()
  }
}

function Read-ManifestValue {
  param([string]$ManifestPath, [string]$Key)
  $prefix = "$Key="
  $matches = @(
    Get-Content -LiteralPath $ManifestPath |
      Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) }
  )
  if ($matches.Count -ne 1) {
    throw "manifest must contain exactly one $Key entry"
  }
  return $matches[0].Substring($prefix.Length)
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
      throw "cargo not found; cannot validate $Kind state. Re-run with -SkipValidate only for emergency recovery."
    }
    & $cargoExe run --quiet --manifest-path (Join-Path $Root "server-rs\Cargo.toml") -- $argument $Path
  }
  if ($LASTEXITCODE -ne 0) {
    throw "$Kind validation failed: $Path"
  }
}

function Install-StagedFile {
  param([string]$StagedPath, [string]$TargetPath)
  if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
    $replaceBackup = "$TargetPath.replace-backup.$([Guid]::NewGuid().ToString('N'))"
    try {
      [System.IO.File]::Replace($StagedPath, $TargetPath, $replaceBackup, $true)
    } finally {
      Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
    }
  } else {
    [System.IO.File]::Move($StagedPath, $TargetPath)
  }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$backupFullPath = Resolve-RepoPath $root $BackupPath
$ledgerFullPath = Resolve-RepoPath $root $LedgerPath
$preRestoreFullDir = Resolve-RepoPath $root $PreRestoreBackupDir
$authTarget = [System.IO.Path]::ChangeExtension($ledgerFullPath, "auth.json")

if (!(Test-Path -LiteralPath $backupFullPath)) {
  throw "backup path not found: $backupFullPath"
}
Assert-NotReparsePoint -Path $backupFullPath -Label "backup path"

$backupIsDirectory = Test-Path -LiteralPath $backupFullPath -PathType Container
$backupLedger = if ($backupIsDirectory) { Join-Path $backupFullPath "ledger.json" } else { $backupFullPath }
$backupAuth = if ($backupIsDirectory) { Join-Path $backupFullPath "ledger.auth.json" } else { $null }
Assert-RegularFile -Path $backupLedger -Label "backup ledger"

if ([System.IO.Path]::GetFullPath($backupLedger).Equals(
    [System.IO.Path]::GetFullPath($ledgerFullPath),
    [StringComparison]::OrdinalIgnoreCase
  )) {
  throw "backup ledger and restore target must be different files"
}

$authAction = "keep"
$expectedLedgerHash = ""
$expectedAuthHash = ""

if ($backupIsDirectory) {
  try {
    $manifestPath = Join-Path $backupFullPath "manifest.txt"
    $checksumsPath = Join-Path $backupFullPath "SHA256SUMS"
    Assert-RegularFile -Path $manifestPath -Label "backup manifest"
    Assert-RegularFile -Path $checksumsPath -Label "backup checksums"

    if ((Read-ManifestValue -ManifestPath $manifestPath -Key "backupFormat") -ne "1") {
      throw "unsupported backupFormat"
    }
    if ((Read-ManifestValue -ManifestPath $manifestPath -Key "ledgerFile") -ne "ledger.json") {
      throw "manifest ledgerFile must be ledger.json"
    }
    $includesAuth = Read-ManifestValue -ManifestPath $manifestPath -Key "includesAuth"
    if ($includesAuth -notin @("true", "false")) {
      throw "manifest includesAuth must be true or false"
    }
    $authFileEntries = @(
      Get-Content -LiteralPath $manifestPath |
        Where-Object { $_.StartsWith("authFile=", [StringComparison]::Ordinal) }
    )
    if ($includesAuth -eq "true") {
      if ($authFileEntries.Count -ne 1 -or $authFileEntries[0] -ne "authFile=ledger.auth.json") {
        throw "manifest with auth must contain exactly authFile=ledger.auth.json"
      }
    } elseif ($authFileEntries.Count -ne 0) {
      throw "manifest without auth must not contain authFile"
    }

    $seen = @{}
    foreach ($line in Get-Content -LiteralPath $checksumsPath) {
      if ($line -notmatch '^([0-9a-fA-F]{64})  (ledger\.json|ledger\.auth\.json)$') {
        throw "SHA256SUMS contains an invalid or unsafe entry"
      }
      $expected = $Matches[1].ToLowerInvariant()
      $name = $Matches[2]
      if ($seen.ContainsKey($name)) {
        throw "SHA256SUMS contains duplicate entry: $name"
      }
      $seen[$name] = $true
      $file = Join-Path $backupFullPath $name
      Assert-RegularFile -Path $file -Label "checksummed backup file"
      $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
      if ($actual -ne $expected) {
        throw "checksum mismatch for backup file: $name"
      }
      if ($name -eq "ledger.json") {
        $expectedLedgerHash = $expected
      } else {
        $expectedAuthHash = $expected
      }
    }

    if (!$expectedLedgerHash) {
      throw "SHA256SUMS must include ledger.json"
    }
    if ($includesAuth -eq "true") {
      if (!$expectedAuthHash) {
        throw "manifest requires a checksummed ledger.auth.json"
      }
      Assert-RegularFile -Path $backupAuth -Label "backup auth state"
      $authAction = "restore"
    } else {
      if ($expectedAuthHash -or (Test-Path -LiteralPath $backupAuth)) {
        throw "manifest excludes auth state but backup contains ledger.auth.json"
      }
      $authAction = "remove"
    }
  } catch {
    if (!$AllowUnverified) {
      throw
    }
    Write-Warning "Proceeding with an unverified backup directory: $($_.Exception.Message)"
    $expectedLedgerHash = ""
    $expectedAuthHash = ""
    if ($backupAuth -and (Test-Path -LiteralPath $backupAuth -PathType Leaf)) {
      Assert-RegularFile -Path $backupAuth -Label "backup auth state"
      $authAction = "restore"
    } else {
      $authAction = "remove"
    }
  }
} elseif (!$AllowUnverified) {
  throw "direct ledger files have no manifest; pass -AllowUnverified to restore one"
} else {
  Write-Warning "Restoring a direct ledger file without a checksum manifest; current auth state will be kept."
}

if (!$SkipValidate) {
  Invoke-ServerValidation -Kind ledger -Path $backupLedger -Root $root -ServerExecutable $ServerExecutable
  if ($authAction -eq "restore") {
    Invoke-ServerValidation -Kind auth -Path $backupAuth -Root $root -ServerExecutable $ServerExecutable
  }
}

if (!$Force) {
  Write-Host "About to restore:"
  Write-Host "  from:        $backupLedger"
  Write-Host "  to:          $ledgerFullPath"
  Write-Host "  auth action: $authAction"
  Write-Host "Current ledger/auth state will be backed up first."
  $answer = Read-Host "Type RESTORE to continue"
  if ($answer -ne "RESTORE") {
    Write-Host "Restore cancelled."
    return
  }
}

$ledgerDir = Split-Path -Parent $ledgerFullPath
if (!$ledgerDir) {
  throw "restore target must have a parent directory"
}
New-Item -ItemType Directory -Force -Path $ledgerDir | Out-Null
Assert-NotReparsePoint -Path $ledgerDir -Label "restore target directory"

$restoreLease = Acquire-LedgerRestoreLease -LedgerPath $ledgerFullPath

try {
  if (Test-Path -LiteralPath $ledgerFullPath -PathType Leaf) {
    & (Join-Path $PSScriptRoot "backup_local_ledger.ps1") `
      -LedgerPath $ledgerFullPath `
      -BackupDir $preRestoreFullDir `
      -ServerExecutable $ServerExecutable `
      -SkipValidate
  }

  $operationId = [Guid]::NewGuid().ToString("N")
  $ledgerStaged = Join-Path $ledgerDir ".ledger.restore.$operationId.tmp"
  $authStaged = Join-Path $ledgerDir ".auth.restore.$operationId.tmp"
  $rollbackDir = Join-Path $ledgerDir ".restore-rollback.$operationId"
  $ledgerExisted = Test-Path -LiteralPath $ledgerFullPath -PathType Leaf
  $authExisted = Test-Path -LiteralPath $authTarget -PathType Leaf
  $commitStarted = $false
  $commitSucceeded = $false

  try {
    New-Item -ItemType Directory -Path $rollbackDir | Out-Null
    if ($ledgerExisted) {
      Assert-RegularFile -Path $ledgerFullPath -Label "current ledger"
      Copy-Item -LiteralPath $ledgerFullPath -Destination (Join-Path $rollbackDir "ledger.json")
    }
    if ($authExisted) {
      Assert-RegularFile -Path $authTarget -Label "current auth state"
      Copy-Item -LiteralPath $authTarget -Destination (Join-Path $rollbackDir "ledger.auth.json")
    }

    Copy-Item -LiteralPath $backupLedger -Destination $ledgerStaged
    if ($authAction -eq "restore") {
      Copy-Item -LiteralPath $backupAuth -Destination $authStaged
    }

    if ($expectedLedgerHash) {
      $stagedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ledgerStaged).Hash.ToLowerInvariant()
      if ($stagedHash -ne $expectedLedgerHash) {
        throw "staged ledger checksum mismatch"
      }
    }
    if ($expectedAuthHash) {
      $stagedAuthHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $authStaged).Hash.ToLowerInvariant()
      if ($stagedAuthHash -ne $expectedAuthHash) {
        throw "staged auth checksum mismatch"
      }
    }
    if (!$SkipValidate) {
      Invoke-ServerValidation -Kind ledger -Path $ledgerStaged -Root $root -ServerExecutable $ServerExecutable
      if ($authAction -eq "restore") {
        Invoke-ServerValidation -Kind auth -Path $authStaged -Root $root -ServerExecutable $ServerExecutable
      }
    }

    $commitStarted = $true
    Install-StagedFile -StagedPath $ledgerStaged -TargetPath $ledgerFullPath
    if ($env:FINWEALTH_TEST_FAIL_AFTER_LEDGER_REPLACE -eq "1") {
      throw "injected restore failure after ledger replacement"
    }
    switch ($authAction) {
      "restore" { Install-StagedFile -StagedPath $authStaged -TargetPath $authTarget }
      "remove" { Remove-Item -LiteralPath $authTarget -Force -ErrorAction SilentlyContinue }
    }

    if (!$SkipValidate) {
      Invoke-ServerValidation -Kind ledger -Path $ledgerFullPath -Root $root -ServerExecutable $ServerExecutable
      if (Test-Path -LiteralPath $authTarget -PathType Leaf) {
        Invoke-ServerValidation -Kind auth -Path $authTarget -Root $root -ServerExecutable $ServerExecutable
      }
    }
    $commitSucceeded = $true
  } catch {
    if ($commitStarted -and !$commitSucceeded) {
      Write-Warning "Restore failed after replacement began; rolling back current state."
      if ($ledgerExisted) {
        Copy-Item -LiteralPath (Join-Path $rollbackDir "ledger.json") -Destination $ledgerFullPath -Force
      } else {
        Remove-Item -LiteralPath $ledgerFullPath -Force -ErrorAction SilentlyContinue
      }
      if ($authExisted) {
        Copy-Item -LiteralPath (Join-Path $rollbackDir "ledger.auth.json") -Destination $authTarget -Force
      } else {
        Remove-Item -LiteralPath $authTarget -Force -ErrorAction SilentlyContinue
      }
    }
    throw
  } finally {
    foreach ($temporaryPath in @($ledgerStaged, $authStaged, $rollbackDir)) {
      if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Recurse -Force
      }
    }
  }
} finally {
  Release-LedgerRestoreLease -Lease $restoreLease
}

Write-Host "Restore complete: $ledgerFullPath (auth: $authAction)"
