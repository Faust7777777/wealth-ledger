param(
  [switch]$ResetAuth,
  [switch]$CheckOnly,
  [switch]$PackageIntegrityOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Port = 8791
$ApiBase = "http://127.0.0.1:$Port"
$InstallDir = $PSScriptRoot
$ServerExe = Join-Path $InstallDir "server\finwealth-server.exe"
$ClientExe = Join-Path $InstallDir "finwealth.exe"
$PackageManifestPath = Join-Path $InstallDir "package-manifest.json"
$BuildConfigPath = Join-Path $InstallDir "finwealth.build-config.json"
$DataDir = Join-Path $env:LOCALAPPDATA "Finwealth"
$LedgerPath = Join-Path $DataDir "ledger.json"
$AuthStatePath = [System.IO.Path]::ChangeExtension($LedgerPath, "auth.json")
$ConfigPath = Join-Path $DataDir "launcher.config.json"
$ServerOutLog = Join-Path $DataDir "finwealth-server.out.log"
$ServerErrLog = Join-Path $DataDir "finwealth-server.err.log"

function ConvertTo-PlainText {
  param([System.Security.SecureString]$Secure)
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Read-NewAuthConfig {
  param([string]$ServerPath)
  $username = Read-Host "Choose a local Finwealth username"
  if ([string]::IsNullOrWhiteSpace($username)) {
    throw "Username must not be empty."
  }
  $first = Read-Host "Choose a local password (not echoed or stored)" -AsSecureString
  $second = Read-Host "Confirm the local password" -AsSecureString
  $plainFirst = ConvertTo-PlainText $first
  $plainSecond = ConvertTo-PlainText $second
  try {
    if ($plainFirst -cne $plainSecond) {
      throw "Passwords do not match."
    }
    if ([string]::IsNullOrWhiteSpace($plainFirst)) {
      throw "Password must not be empty."
    }
    $output = $plainFirst | & $ServerPath --hash-password-stdin
    if ($LASTEXITCODE -ne 0) {
      throw "Server failed to derive the password hash."
    }
    $hash = $output | Where-Object { $_ -like '$argon2*' } | Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($hash)) {
      throw "Server did not return an Argon2 password hash."
    }
    return [pscustomobject]@{
      version = 1
      username = $username.Trim()
      passwordHash = $hash
    }
  } finally {
    $plainFirst = $null
    $plainSecond = $null
  }
}

function Write-AuthConfig {
  param([object]$Config, [string]$Path)
  $temp = "$Path.tmp"
  $json = $Config | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText($temp, $json, [System.Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Read-AuthConfig {
  param([string]$Path)
  $config = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  if ($config.version -ne 1) {
    throw "Unsupported launcher config version in $Path"
  }
  if ([string]::IsNullOrWhiteSpace([string]$config.username)) {
    throw "Launcher config username is missing."
  }
  if ([string]::IsNullOrWhiteSpace([string]$config.passwordHash) -or !([string]$config.passwordHash).StartsWith('$argon2')) {
    throw "Launcher config password hash is invalid."
  }
  return $config
}

function Assert-PackageIntegrity {
  param(
    [string]$ManifestPath,
    [string]$BuildPath,
    [string]$ClientPath,
    [string]$BundledServerPath,
    [string]$LauncherPowerShellPath,
    [string]$LauncherCmdPath
  )
  $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
  $build = Get-Content -Raw -LiteralPath $BuildPath | ConvertFrom-Json
  if (
    $manifest.packageFormat -ne 2 -or
    [string]$manifest.clientVersion -eq "" -or
    [string]$manifest.serverVersion -eq "" -or
    [string]$manifest.sourceCommit -notmatch '^[0-9a-fA-F]{40}$' -or
    $manifest.sourceDirty -isnot [bool] -or
    $manifest.dataSource -cne "local_server" -or
    $manifest.apiBase -cne $ApiBase -or
    $manifest.client -cne "finwealth.exe" -or
    [string]$manifest.clientSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
    $manifest.server -cne "server/finwealth-server.exe" -or
    [string]$manifest.serverSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
    $manifest.launcherPowerShell -cne "Start-Finwealth.ps1" -or
    [string]$manifest.launcherPowerShellSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
    $manifest.launcherCmd -cne "Start-Finwealth.cmd" -or
    [string]$manifest.launcherCmdSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
    $manifest.buildConfig -cne "finwealth.build-config.json" -or
    [string]$manifest.buildConfigSha256 -notmatch '^[0-9a-fA-F]{64}$'
  ) {
    throw "Package manifest is invalid or does not describe this self-use package."
  }
  if (
    $build.buildFormat -ne 2 -or
    $build.dataSource -cne "local_server" -or
    $build.apiBase -cne $ApiBase -or
    $build.serverBundled -ne $true -or
    $build.clientVersion -cne $manifest.clientVersion -or
    $build.serverVersion -cne $manifest.serverVersion -or
    $build.sourceCommit -cne $manifest.sourceCommit -or
    $build.sourceDirty -ne $manifest.sourceDirty
  ) {
    throw "Flutter build metadata is missing or does not match the bundled local server."
  }
  foreach ($check in @(
    @($ClientPath, [string]$manifest.clientSha256, "client"),
    @($BundledServerPath, [string]$manifest.serverSha256, "server"),
    @($LauncherPowerShellPath, [string]$manifest.launcherPowerShellSha256, "PowerShell launcher"),
    @($LauncherCmdPath, [string]$manifest.launcherCmdSha256, "CMD launcher"),
    @($BuildPath, [string]$manifest.buildConfigSha256, "build config")
  )) {
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $check[0]).Hash.ToLowerInvariant()
    if ($actualHash -cne $check[1].ToLowerInvariant()) {
      throw "Packaged $($check[2]) checksum does not match package-manifest.json."
    }
  }
}

function Wait-Health {
  param([System.Diagnostics.Process]$Process)
  $lastError = $null
  for ($i = 0; $i -lt 80; $i++) {
    if ($Process.HasExited) {
      $tail = if (Test-Path $ServerErrLog) {
        (Get-Content -LiteralPath $ServerErrLog -Tail 20) -join [Environment]::NewLine
      } else { "" }
      throw "Local server exited with code $($Process.ExitCode).$([Environment]::NewLine)$tail"
    }
    try {
      $health = Invoke-RestMethod -Uri "$ApiBase/v1/health" -Method Get -TimeoutSec 2
      if ($health.ok -eq $true) {
        return
      }
    } catch {
      $lastError = $_.Exception.Message
    }
    Start-Sleep -Milliseconds 250
  }
  throw "Local server did not become ready: $lastError"
}

foreach ($required in @($ServerExe, $ClientExe, $PackageManifestPath, $BuildConfigPath)) {
  if (!(Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Packaged executable is missing: $required"
  }
}
Assert-PackageIntegrity `
  -ManifestPath $PackageManifestPath `
  -BuildPath $BuildConfigPath `
  -ClientPath $ClientExe `
  -BundledServerPath $ServerExe `
  -LauncherPowerShellPath (Join-Path $InstallDir "Start-Finwealth.ps1") `
  -LauncherCmdPath (Join-Path $InstallDir "Start-Finwealth.cmd")

if ($PackageIntegrityOnly) {
  Write-Host "Package integrity check passed."
  return
}
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

if ($ResetAuth) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  foreach ($path in @($ConfigPath, $AuthStatePath)) {
    if (Test-Path -LiteralPath $path) {
      Move-Item -LiteralPath $path -Destination "$path.reset-$stamp.bak" -Force
    }
  }
  Write-Host "Local auth configuration reset; existing files were retained as timestamped backups."
}

if (!(Test-Path -LiteralPath $ConfigPath)) {
  if ($CheckOnly) {
    Write-Host "Package check passed; first launch will prompt for local auth."
    return
  }
  Write-Host "First launch: create credentials for the loopback-only local ledger server."
  $config = Read-NewAuthConfig -ServerPath $ServerExe
  Write-AuthConfig -Config $config -Path $ConfigPath
} else {
  $config = Read-AuthConfig -Path $ConfigPath
}

if ($CheckOnly) {
  Write-Host "Package check passed; executables and local auth config are valid."
  return
}

$environmentNames = @(
  "FINWEALTH_REQUIRE_AUTH",
  "FINWEALTH_AUTH_USERNAME",
  "FINWEALTH_AUTH_PASSWORD_HASH",
  "FINWEALTH_ALLOWED_HOSTS",
  "FINWEALTH_QUOTE_PROVIDER"
)
$oldEnvironment = @{}
foreach ($name in $environmentNames) {
  $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}
$server = $null
try {
  [Environment]::SetEnvironmentVariable("FINWEALTH_REQUIRE_AUTH", "true", "Process")
  [Environment]::SetEnvironmentVariable("FINWEALTH_AUTH_USERNAME", [string]$config.username, "Process")
  [Environment]::SetEnvironmentVariable("FINWEALTH_AUTH_PASSWORD_HASH", [string]$config.passwordHash, "Process")
  [Environment]::SetEnvironmentVariable("FINWEALTH_ALLOWED_HOSTS", "127.0.0.1,localhost", "Process")
  [Environment]::SetEnvironmentVariable("FINWEALTH_QUOTE_PROVIDER", "none", "Process")

  $server = Start-Process `
    -FilePath $ServerExe `
    -ArgumentList @("--port", $Port, "--ledger-path", $LedgerPath) `
    -WorkingDirectory $InstallDir `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $ServerOutLog `
    -RedirectStandardError $ServerErrLog
} finally {
  foreach ($name in $environmentNames) {
    [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], "Process")
  }
}

try {
  Wait-Health -Process $server
  Write-Host "Starting Finwealth. Ledger data: $LedgerPath"
  $client = Start-Process -FilePath $ClientExe -WorkingDirectory $InstallDir -PassThru
  Wait-Process -Id $client.Id
} finally {
  if ($server -and !$server.HasExited) {
    Stop-Process -Id $server.Id -Force
  }
}
