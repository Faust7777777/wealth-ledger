param(
  [string]$ServerExecutable = "",
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "finwealth-local-backup-$([Guid]::NewGuid().ToString('N'))"
$dataDir = Join-Path $tempRoot "data"
$backupRoot = Join-Path $tempRoot "backups"
$preRestoreRoot = Join-Path $tempRoot "pre-restore"
$ledgerPath = Join-Path $dataDir "ledger.json"
$authPath = Join-Path $dataDir "ledger.auth.json"
$lockPath = "$ledgerPath.lock"

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (!$Condition) {
    throw $Message
  }
}

function Get-FreeTcpPort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try {
    return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  } finally {
    $listener.Stop()
  }
}

function Invoke-WithServer {
  param(
    [string]$ServerExecutable,
    [string]$LedgerPath,
    [scriptblock]$Action
  )

  $port = Get-FreeTcpPort
  $stdout = Join-Path $tempRoot "server-$port.out.log"
  $stderr = Join-Path $tempRoot "server-$port.err.log"
  $process = Start-Process `
    -FilePath $ServerExecutable `
    -ArgumentList @("--ledger-path", $LedgerPath, "--addr", "127.0.0.1:$port") `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr
  try {
    $ready = $false
    for ($attempt = 0; $attempt -lt 80; $attempt += 1) {
      if ($process.HasExited) {
        $detail = if (Test-Path -LiteralPath $stderr) { Get-Content -Raw $stderr } else { "" }
        throw "test server exited before readiness: $detail"
      }
      try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/v1/health" -TimeoutSec 2
        if ($health.ok -eq $true) {
          $ready = $true
          break
        }
      } catch {
        Start-Sleep -Milliseconds 250
      }
    }
    if (!$ready) {
      throw "test server did not become ready"
    }
    & $Action "http://127.0.0.1:$port"
  } finally {
    if (!$process.HasExited) {
      Stop-Process -Id $process.Id -Force
      $process.WaitForExit(5000) | Out-Null
    }
  }
}

function Add-TestAccount {
  param([string]$ServerExecutable, [string]$LedgerPath, [string]$DisplayName)
  Invoke-WithServer -ServerExecutable $ServerExecutable -LedgerPath $LedgerPath -Action {
    param($baseUrl)
    $body = @{
      displayName = $DisplayName
      accountType = "bank"
      defaultCurrency = "CNY"
      supportedCurrencies = @("CNY")
      includeInNetWorth = $true
      balanceMode = "cash_balance"
      openingBalances = @(@{ currency = "CNY"; amount = "1.00"; quality = "exact" })
    } | ConvertTo-Json -Depth 8
    Invoke-RestMethod `
      -Uri "$baseUrl/v1/accounts" `
      -Method Post `
      -ContentType "application/json" `
      -Headers @{ "Idempotency-Key" = "backup-smoke-$([Guid]::NewGuid().ToString('N'))" } `
      -Body $body | Out-Null
  }
}

function Get-LatestBackup {
  param([string]$Path)
  return Get-ChildItem -LiteralPath $Path -Directory |
    Where-Object { !$_.Name.StartsWith(".") } |
    Sort-Object Name |
    Select-Object -Last 1 -ExpandProperty FullName
}

function Invoke-Backup {
  param([string]$Destination)
  & (Join-Path $root "tools\backup_local_ledger.ps1") `
    -LedgerPath $ledgerPath `
    -BackupDir $Destination `
    -ServerExecutable $ServerExecutable
}

function Invoke-Restore {
  param([string]$Source, [switch]$AllowUnverified)
  & (Join-Path $root "tools\restore_local_ledger.ps1") `
    -BackupPath $Source `
    -LedgerPath $ledgerPath `
    -PreRestoreBackupDir $preRestoreRoot `
    -ServerExecutable $ServerExecutable `
    -AllowUnverified:$AllowUnverified `
    -Force
}

try {
  New-Item -ItemType Directory -Force -Path $dataDir, $backupRoot | Out-Null

  if (!$ServerExecutable) {
    if (!$SkipBuild) {
      & cargo build --quiet --manifest-path (Join-Path $root "server-rs\Cargo.toml")
      if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed"
      }
    }
    $ServerExecutable = Join-Path $root "server-rs\target\debug\finwealth-server.exe"
  }
  Assert-True (Test-Path -LiteralPath $ServerExecutable -PathType Leaf) "server executable not found: $ServerExecutable"

  Invoke-WithServer -ServerExecutable $ServerExecutable -LedgerPath $ledgerPath -Action { param($baseUrl) }
  '{"version":1,"devices":[]}' | Set-Content -LiteralPath $authPath -Encoding ASCII

  Invoke-Backup -Destination $backupRoot
  $firstBackup = Get-LatestBackup -Path $backupRoot
  Assert-True ($null -ne $firstBackup) "backup directory was not published"
  foreach ($name in @("ledger.json", "ledger.auth.json", "manifest.txt", "SHA256SUMS")) {
    Assert-True (Test-Path -LiteralPath (Join-Path $firstBackup $name) -PathType Leaf) "backup missing $name"
  }
  $firstManifest = @(Get-Content -LiteralPath (Join-Path $firstBackup "manifest.txt"))
  Assert-True ($firstManifest -contains "includesAuth=true") "manifest must include auth"
  Assert-True ($firstManifest -contains "validatedLedger=true") "ledger validation must be recorded"
  Assert-True ($firstManifest -contains "validatedAuth=true") "auth validation must be recorded"

  Add-TestAccount -ServerExecutable $ServerExecutable -LedgerPath $ledgerPath -DisplayName "changed before restore"
  $liveHashBeforeLockedRestore = (Get-FileHash $ledgerPath).Hash
  $lockLease = [System.IO.FileStream]::new(
    $lockPath,
    [System.IO.FileMode]::OpenOrCreate,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
  )
  $lockLease.Lock(0, 1)
  $lockedRestoreRejected = $false
  try {
    Invoke-Restore -Source $firstBackup
  } catch {
    $lockedRestoreRejected = $true
  } finally {
    try {
      $lockLease.Unlock(0, 1)
    } finally {
      $lockLease.Dispose()
    }
  }
  Assert-True $lockedRestoreRejected "restore unexpectedly replaced a ledger while its lock was held"
  Assert-True ((Get-FileHash $ledgerPath).Hash -eq $liveHashBeforeLockedRestore) "lock-rejected restore changed live ledger"
  Assert-True (Test-Path -LiteralPath $lockPath -PathType Leaf) "restore removed the permanent ledger lock sidecar"

  Invoke-Restore -Source $firstBackup
  Assert-True ((Get-FileHash $ledgerPath).Hash -eq (Get-FileHash (Join-Path $firstBackup "ledger.json")).Hash) "verified restore did not reproduce ledger"
  Assert-True ((Get-FileHash $authPath).Hash -eq (Get-FileHash (Join-Path $firstBackup "ledger.auth.json")).Hash) "verified restore did not reproduce auth"

  $corruptBackup = Join-Path $tempRoot "corrupt-backup"
  Copy-Item -LiteralPath $firstBackup -Destination $corruptBackup -Recurse
  Add-Content -LiteralPath (Join-Path $corruptBackup "ledger.json") -Value "tampered"
  $liveHashBeforeCorruptRestore = (Get-FileHash $ledgerPath).Hash
  $corruptRejected = $false
  try {
    Invoke-Restore -Source $corruptBackup
  } catch {
    $corruptRejected = $true
  }
  Assert-True $corruptRejected "restore unexpectedly accepted a checksum mismatch"
  Assert-True ((Get-FileHash $ledgerPath).Hash -eq $liveHashBeforeCorruptRestore) "rejected restore changed live ledger"

  $noAuthBackupRoot = Join-Path $tempRoot "no-auth-backups"
  Remove-Item -LiteralPath $authPath -Force
  Invoke-Backup -Destination $noAuthBackupRoot
  $noAuthBackup = Get-LatestBackup -Path $noAuthBackupRoot
  Assert-True (@(Get-Content -LiteralPath (Join-Path $noAuthBackup "manifest.txt")) -contains "includesAuth=false") "no-auth backup manifest is wrong"
  '{"version":1,"devices":[]}' | Set-Content -LiteralPath $authPath -Encoding ASCII
  Invoke-Restore -Source $noAuthBackup
  Assert-True (!(Test-Path -LiteralPath $authPath)) "verified no-auth restore kept stale auth state"

  Add-TestAccount -ServerExecutable $ServerExecutable -LedgerPath $ledgerPath -DisplayName "rollback original"
  '{"version":1,"devices":[]}' | Set-Content -LiteralPath $authPath -Encoding ASCII
  $rollbackLedgerHash = (Get-FileHash $ledgerPath).Hash
  $rollbackAuthHash = (Get-FileHash $authPath).Hash
  $env:FINWEALTH_TEST_FAIL_AFTER_LEDGER_REPLACE = "1"
  $rollbackTriggered = $false
  try {
    Invoke-Restore -Source $firstBackup
  } catch {
    $rollbackTriggered = $true
  } finally {
    Remove-Item Env:FINWEALTH_TEST_FAIL_AFTER_LEDGER_REPLACE -ErrorAction SilentlyContinue
  }
  Assert-True $rollbackTriggered "restore failure injection did not trigger"
  Assert-True ((Get-FileHash $ledgerPath).Hash -eq $rollbackLedgerHash) "failed restore did not roll back ledger"
  Assert-True ((Get-FileHash $authPath).Hash -eq $rollbackAuthHash) "failed restore did not roll back auth"

  $directRejected = $false
  try {
    Invoke-Restore -Source (Join-Path $firstBackup "ledger.json")
  } catch {
    $directRejected = $true
  }
  Assert-True $directRejected "direct ledger restore unexpectedly bypassed -AllowUnverified"

  Write-Host "OK: local Windows backup/restore smoke passed"
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
