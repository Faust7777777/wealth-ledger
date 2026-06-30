param(
  [switch]$Deep,
  [string]$LedgerPath = "tmp\ledger.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Failures = New-Object System.Collections.Generic.List[string]
$Warnings = New-Object System.Collections.Generic.List[string]

function Write-Check {
  param(
    [ValidateSet("OK", "WARN", "FAIL", "INFO")]
    [string]$Status,
    [string]$Message
  )

  $color = switch ($Status) {
    "OK" { "Green" }
    "WARN" { "Yellow" }
    "FAIL" { "Red" }
    default { "Cyan" }
  }
  Write-Host ("[{0}] {1}" -f $Status, $Message) -ForegroundColor $color
}

function Add-Fail {
  param([string]$Message)
  $Failures.Add($Message) | Out-Null
  Write-Check -Status "FAIL" -Message $Message
}

function Add-Warn {
  param([string]$Message)
  $Warnings.Add($Message) | Out-Null
  Write-Check -Status "WARN" -Message $Message
}

function Add-Ok {
  param([string]$Message)
  Write-Check -Status "OK" -Message $Message
}

function Add-Info {
  param([string]$Message)
  Write-Check -Status "INFO" -Message $Message
}

function Resolve-CommandPath {
  param(
    [string]$Name,
    [string]$Fallback
  )

  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }
  if (![string]::IsNullOrWhiteSpace($Fallback) -and (Test-Path $Fallback)) {
    return $Fallback
  }
  return $null
}

function Test-RequiredFile {
  param([string]$RelativePath)
  $path = Join-Path $Root $RelativePath
  if (Test-Path $path) {
    Add-Ok "$RelativePath found"
  } else {
    Add-Fail "$RelativePath missing"
  }
}

function Get-VersionLine {
  param(
    [string]$Executable,
    [string[]]$Arguments
  )

  try {
    $output = & $Executable @Arguments 2>$null
    return ($output | Select-Object -First 1)
  } catch {
    return $null
  }
}

Write-Host "Finwealth local readiness doctor"
Write-Host "  Root:   $Root"
Write-Host "  Ledger: $LedgerPath"
Write-Host ""

Test-RequiredFile "pubspec.yaml"
Test-RequiredFile "server-rs\Cargo.toml"
Test-RequiredFile "tools\run_self_use_windows.ps1"
Test-RequiredFile "tools\backup_local_ledger.ps1"
Test-RequiredFile "tools\restore_local_ledger.ps1"
Test-RequiredFile ".github\workflows\ci.yml"
Test-RequiredFile ".github\workflows\package.yml"

$CargoExe = Resolve-CommandPath -Name "cargo" -Fallback (Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe")
if ($CargoExe) {
  $version = Get-VersionLine -Executable $CargoExe -Arguments @("--version")
  Add-Ok "cargo found: $version"
} else {
  Add-Fail "cargo not found; install Rust with rustup and reopen the terminal"
}

$FlutterExe = Resolve-CommandPath -Name "flutter" -Fallback (Join-Path $env:USERPROFILE "tools\flutter\bin\flutter.bat")
if ($FlutterExe) {
  $version = Get-VersionLine -Executable $FlutterExe -Arguments @("--version")
  Add-Ok "flutter found: $version"
} else {
  Add-Fail "flutter not found; install Flutter or add flutter.bat to PATH"
}

$GitExe = Resolve-CommandPath -Name "git" -Fallback ""
if ($GitExe) {
  $version = Get-VersionLine -Executable $GitExe -Arguments @("--version")
  Add-Ok "git found: $version"
} else {
  Add-Warn "git not found; development workflow will be limited"
}

$LedgerFullPath = if ([System.IO.Path]::IsPathRooted($LedgerPath)) {
  $LedgerPath
} else {
  Join-Path $Root $LedgerPath
}

if (Test-Path $LedgerFullPath) {
  Add-Ok "local ledger exists: $LedgerFullPath"
} else {
  Add-Warn "local ledger does not exist yet; first self-use run will create it"
}

$WindowsExe = Join-Path $Root "build\windows\x64\runner\Release\finwealth.exe"
if (Test-Path $WindowsExe) {
  Add-Ok "Windows build output found"
} else {
  Add-Warn "Windows build output not found; run flutter build windows or tools\package_release.ps1"
}

$AndroidApk = Join-Path $Root "build\app\outputs\flutter-apk\app-debug.apk"
if (Test-Path $AndroidApk) {
  Add-Ok "Android debug APK found"
} else {
  Add-Warn "Android debug APK not found; run flutter build apk --debug or tools\package_release.ps1"
}

if ($Deep) {
  Write-Host ""
  Add-Info "Running deep checks"

  if ($CargoExe) {
    & $CargoExe test --manifest-path (Join-Path $Root "server-rs\Cargo.toml")
    Add-Ok "Rust tests passed"
  }

  if ($FlutterExe) {
    Push-Location $Root
    try {
      & $FlutterExe analyze
      Add-Ok "Flutter analyze passed"
      & $FlutterExe test
      Add-Ok "Flutter tests passed"
    } finally {
      Pop-Location
    }
  }
}

Write-Host ""
Write-Host ("Summary: {0} failure(s), {1} warning(s)" -f $Failures.Count, $Warnings.Count)

if ($Failures.Count -gt 0) {
  exit 1
}
