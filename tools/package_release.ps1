param(
  [string]$OutputDir = "dist",
  [switch]$SkipBuild,
  [switch]$WindowsOnly,
  [switch]$AndroidOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($WindowsOnly -and $AndroidOnly) {
  throw "-WindowsOnly and -AndroidOnly cannot be used together."
}

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([System.IO.Path]::IsPathRooted($OutputDir)) {
  $Dist = $OutputDir
} else {
  $Dist = Join-Path $Root $OutputDir
}
New-Item -ItemType Directory -Force -Path $Dist | Out-Null

$Flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (!$Flutter) {
  $candidate = Join-Path $env:USERPROFILE "tools\flutter\bin\flutter.bat"
  if (Test-Path $candidate) {
    $FlutterExe = $candidate
  } else {
    throw "flutter not found. Install Flutter or add it to PATH."
  }
} else {
  $FlutterExe = $Flutter.Source
}

$VersionLine = (Select-String -Path (Join-Path $Root "pubspec.yaml") -Pattern "^version:\s*(.+)$").Matches.Groups[1].Value.Trim()
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$PackageName = "finwealth-$VersionLine-$Stamp"

if (!$AndroidOnly) {
  if (!$SkipBuild) {
    & $FlutterExe build windows
  }
  $WindowsRelease = Join-Path $Root "build\windows\x64\runner\Release"
  if (!(Test-Path (Join-Path $WindowsRelease "finwealth.exe"))) {
    throw "Windows release build not found: $WindowsRelease"
  }
  $ZipPath = Join-Path $Dist "$PackageName-windows-x64.zip"
  if (Test-Path $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
  }
  Compress-Archive -Path (Join-Path $WindowsRelease "*") -DestinationPath $ZipPath
  Write-Host "Windows package: $ZipPath"
}

if (!$WindowsOnly) {
  if (!$SkipBuild) {
    & $FlutterExe build apk --debug
  }
  $ApkSource = Join-Path $Root "build\app\outputs\flutter-apk\app-debug.apk"
  if (!(Test-Path $ApkSource)) {
    throw "Android debug APK not found: $ApkSource"
  }
  $ApkTarget = Join-Path $Dist "$PackageName-android-debug.apk"
  Copy-Item -LiteralPath $ApkSource -Destination $ApkTarget -Force
  Write-Host "Android package: $ApkTarget"
}
