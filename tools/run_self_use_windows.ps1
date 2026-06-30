param(
  [int]$Port = 8791,
  [string]$LedgerPath = "tmp\ledger.json",
  [string]$LogDir = "tmp\logs",
  [string]$Device = "windows",
  [string]$Username = $env:FINWEALTH_AUTH_USERNAME,
  [string]$PasswordHash = $env:FINWEALTH_AUTH_PASSWORD_HASH,
  [switch]$NoAuth,
  [switch]$SmokeOnly,
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-RepoRoot {
  return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function Resolve-Executable {
  param(
    [string]$Name,
    [string]$Fallback,
    [string]$InstallHint
  )
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) {
    return $cmd.Source
  }
  if (![string]::IsNullOrWhiteSpace($Fallback) -and (Test-Path $Fallback)) {
    return $Fallback
  }
  throw "$Name not found. $InstallHint"
}

function Resolve-LedgerPath {
  param([string]$Root, [string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return Join-Path $Root $Path
}

function ConvertTo-PlainText {
  param([System.Security.SecureString]$Secure)
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function New-PasswordHash {
  param([string]$CargoExe, [string]$ManifestPath)
  $secure = Read-Host "Local auth password (will not be echoed or stored)" -AsSecureString
  $plain = ConvertTo-PlainText $secure
  try {
    $output = $plain | & $CargoExe run --manifest-path $ManifestPath -- --hash-password-stdin
    $hash = ($output | Where-Object { $_ -like '$argon2*' } | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($hash)) {
      throw "server did not print an Argon2 password hash"
    }
    return $hash
  } finally {
    $plain = $null
  }
}

function Wait-Health {
  param(
    [string]$BaseUrl,
    [System.Diagnostics.Process]$Process,
    [string]$ErrorLog
  )
  $lastError = $null
  for ($i = 0; $i -lt 80; $i++) {
    if ($Process.HasExited) {
      $tail = ""
      if (Test-Path $ErrorLog) {
        $tail = (Get-Content -LiteralPath $ErrorLog -Tail 20) -join [Environment]::NewLine
      }
      throw "server exited early with code $($Process.ExitCode). Last stderr lines:$([Environment]::NewLine)$tail"
    }
    try {
      Invoke-RestMethod -Uri "$BaseUrl/v1/health" -Method Get | Out-Null
      return
    } catch {
      $lastError = $_.Exception.Message
      Start-Sleep -Milliseconds 250
    }
  }
  $tail = ""
  if (Test-Path $ErrorLog) {
    $tail = (Get-Content -LiteralPath $ErrorLog -Tail 20) -join [Environment]::NewLine
  }
  throw "server did not become ready: $lastError$([Environment]::NewLine)$tail"
}

function Set-ProcessEnv {
  param([hashtable]$Values)
  $old = @{}
  foreach ($key in $Values.Keys) {
    $old[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
    [Environment]::SetEnvironmentVariable($key, [string]$Values[$key], "Process")
  }
  return $old
}

function Restore-ProcessEnv {
  param([hashtable]$OldValues)
  foreach ($key in $OldValues.Keys) {
    [Environment]::SetEnvironmentVariable($key, $OldValues[$key], "Process")
  }
}

$Root = Resolve-RepoRoot
$LedgerFullPath = Resolve-LedgerPath $Root $LedgerPath
$LedgerDir = Split-Path -Parent $LedgerFullPath
if ($LedgerDir) {
  New-Item -ItemType Directory -Force -Path $LedgerDir | Out-Null
}
if ([System.IO.Path]::IsPathRooted($LogDir)) {
  $LogFullDir = $LogDir
} else {
  $LogFullDir = Join-Path $Root $LogDir
}
New-Item -ItemType Directory -Force -Path $LogFullDir | Out-Null

$CargoExe = Resolve-Executable `
  -Name "cargo" `
  -Fallback (Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe") `
  -InstallHint "Install Rust with rustup, then reopen the terminal."

$FlutterExe = Resolve-Executable `
  -Name "flutter" `
  -Fallback (Join-Path $env:USERPROFILE "tools\flutter\bin\flutter.bat") `
  -InstallHint "Install Flutter or add flutter.bat to PATH."

$ManifestPath = Join-Path $Root "server-rs\Cargo.toml"
$ServerExe = Join-Path $Root "server-rs\target\debug\finwealth-server.exe"
$ApiBase = "http://127.0.0.1:$Port"
$ServerOutLog = Join-Path $LogFullDir "finwealth-server.out.log"
$ServerErrLog = Join-Path $LogFullDir "finwealth-server.err.log"

if (!$NoAuth) {
  if ([string]::IsNullOrWhiteSpace($Username)) {
    if ($CheckOnly) {
      $Username = "<prompt>"
    } else {
      $Username = Read-Host "Local auth username"
    }
  }
  if ([string]::IsNullOrWhiteSpace($PasswordHash)) {
    if ($CheckOnly) {
      $PasswordHash = "<prompt-and-hash>"
    } else {
      $PasswordHash = New-PasswordHash -CargoExe $CargoExe -ManifestPath $ManifestPath
    }
  }
}

Write-Host "Finwealth self-use local run"
Write-Host "  API:        $ApiBase"
Write-Host "  Ledger:     $LedgerFullPath"
Write-Host "  Logs:       $LogFullDir"
Write-Host "  Device:     $Device"
Write-Host "  Auth:       $(if ($NoAuth) { 'disabled' } else { 'required' })"
Write-Host "  Username:   $(if ($NoAuth) { '-' } else { $Username })"
Write-Host "  Mode:       $(if ($SmokeOnly) { 'server smoke only' } else { 'server + Flutter' })"

if ($CheckOnly) {
  Write-Host "CheckOnly: paths and configuration resolved; no process started."
  return
}

Write-Host "Building Rust server..."
& $CargoExe build --manifest-path $ManifestPath

if (!(Test-Path $ServerExe)) {
  throw "server binary not found after build: $ServerExe"
}

$serverEnv = @{
  FINWEALTH_REQUIRE_AUTH = $(if ($NoAuth) { "false" } else { "true" })
}
if (!$NoAuth) {
  $serverEnv["FINWEALTH_AUTH_USERNAME"] = $Username
  $serverEnv["FINWEALTH_AUTH_PASSWORD_HASH"] = $PasswordHash
}

$oldEnv = Set-ProcessEnv $serverEnv
$server = $null
try {
  Write-Host "Starting Rust server..."
  $server = Start-Process `
    -FilePath $ServerExe `
    -ArgumentList @("--port", $Port, "--ledger-path", $LedgerFullPath) `
    -WorkingDirectory $Root `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $ServerOutLog `
    -RedirectStandardError $ServerErrLog
} finally {
  Restore-ProcessEnv $oldEnv
}

try {
  Wait-Health -BaseUrl $ApiBase -Process $server -ErrorLog $ServerErrLog
  if ($SmokeOnly) {
    Write-Host "SmokeOnly: server health check passed."
    return
  }
  Write-Host "Starting Flutter app. Close the app/stop flutter to stop the server."
  & $FlutterExe run -d $Device `
    --dart-define=DATA_SOURCE=local_server `
    --dart-define=API_BASE=$ApiBase
} finally {
  if ($server -and !$server.HasExited) {
    Stop-Process -Id $server.Id -Force
    Write-Host "Stopped Rust server."
  }
}
