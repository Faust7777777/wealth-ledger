param(
  [int]$ServerPort = 18990,
  [int]$AgentPort = 18992
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$temp = Join-Path $tempRoot "finwealth-agent-smoke-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temp | Out-Null
$server = $null
$agent = $null
$savedModelEnvironment = @{}
$token = [Convert]::ToHexString(
  [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
).ToLowerInvariant()
$serverExecutable = Join-Path $root "server-rs\target\debug\finwealth-server.exe"
& cargo build --quiet --manifest-path (Join-Path $root "server-rs\Cargo.toml")
if ($LASTEXITCODE -ne 0) { throw "cargo build failed." }
$agentExecutable = Join-Path $root "agent-service\dist\main.js"
& npm --prefix (Join-Path $root "agent-service") run build
if ($LASTEXITCODE -ne 0) { throw "Agent TypeScript build failed." }

try {
  $env:FINWEALTH_AGENT_BASE_URL = "http://127.0.0.1:$AgentPort"
  $env:FINWEALTH_AGENT_INTERNAL_TOKEN = $token
  $env:FINWEALTH_RS_ADDR = "127.0.0.1:$ServerPort"
  $server = Start-Process `
    -FilePath $serverExecutable `
    -ArgumentList @("--ledger-path", (Join-Path $temp "ledger.json")) `
    -WorkingDirectory $root `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput (Join-Path $temp "server.out") `
    -RedirectStandardError (Join-Path $temp "server.err")

  $env:FINWEALTH_AGENT_ADDR = "127.0.0.1:$AgentPort"
  $env:FINWEALTH_SERVER_BASE_URL = "http://127.0.0.1:$ServerPort"
  $env:FINWEALTH_AGENT_STATE_DIR = Join-Path $temp "agent-state"
  $env:PI_CODING_AGENT_DIR = Join-Path $temp "pi"
  Get-ChildItem Env: | Where-Object {
    $_.Name -match "(_API_KEY|_AUTH_TOKEN|_OAUTH_TOKEN)$"
  } | ForEach-Object {
    $savedModelEnvironment[$_.Name] = $_.Value
    Remove-Item "Env:$($_.Name)"
  }
  $agent = Start-Process `
    -FilePath "node" `
    -ArgumentList @($agentExecutable) `
    -WorkingDirectory (Join-Path $root "agent-service") `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput (Join-Path $temp "agent.out") `
    -RedirectStandardError (Join-Path $temp "agent.err")

  $status = $null
  for ($attempt = 0; $attempt -lt 80; $attempt += 1) {
    try {
      $status = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$ServerPort/v1/agent/status" `
        -TimeoutSec 2
      break
    } catch {
      Start-Sleep -Milliseconds 100
    }
  }
  if ($null -eq $status) { throw "Agent status did not become ready." }
  if ($status.data.configured -ne $false) {
    throw "Empty Pi configuration must report configured=false."
  }

  $conversation = Invoke-RestMethod `
    -Method Post `
    -Uri "http://127.0.0.1:$ServerPort/v1/agent/conversations" `
    -Headers @{ "Idempotency-Key" = "smoke-conversation" } `
    -ContentType "application/json" `
    -Body '{"title":"Smoke"}'

  $image = Join-Path $temp "bill.png"
  [IO.File]::WriteAllBytes(
    $image,
    [Convert]::FromBase64String(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )
  )
  $http = [Net.Http.HttpClient]::new()
  $multipart = [Net.Http.MultipartFormDataContent]::new()
  $fileContent = [Net.Http.ByteArrayContent]::new([IO.File]::ReadAllBytes($image))
  $fileContent.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new("image/png")
  $multipart.Add($fileContent, "file", "bill.png")
  $uploadRequest = [Net.Http.HttpRequestMessage]::new(
    [Net.Http.HttpMethod]::Post,
    "http://127.0.0.1:$ServerPort/v1/agent/attachments"
  )
  $uploadRequest.Headers.Add("Idempotency-Key", "smoke-upload")
  $uploadRequest.Content = $multipart
  $uploadResponse = $http.Send($uploadRequest)
  if (!$uploadResponse.IsSuccessStatusCode) {
    throw "Attachment upload failed with $([int]$uploadResponse.StatusCode)."
  }
  $upload = $uploadResponse.Content.ReadAsStringAsync().Result | ConvertFrom-Json
  $attachmentId = $upload.data.id
  $uploadRequest.Dispose()
  $multipart.Dispose()
  if (!$attachmentId) { throw "Attachment upload did not return an ID." }

  $metadata = Invoke-RestMethod `
    -Method Get `
    -Uri "http://127.0.0.1:$ServerPort/v1/agent/attachments/$attachmentId"
  if ($metadata.data.mimeType -ne "image/png") {
    throw "Attachment metadata did not pass through the Rust proxy."
  }
  if ($metadata.data.PSObject.Properties.Name -contains "originalPath" -or
      $metadata.data.PSObject.Properties.Name -contains "workingPath") {
    throw "Attachment metadata exposed a storage path."
  }

  $contentResponse = $http.GetAsync(
    "http://127.0.0.1:$ServerPort/v1/agent/attachments/$attachmentId/content"
  ).Result
  if (!$contentResponse.IsSuccessStatusCode) {
    throw "Attachment download failed with $([int]$contentResponse.StatusCode)."
  }
  $allContentHeaders = $contentResponse.Headers.ToString() +
    $contentResponse.Content.Headers.ToString()
  if ($contentResponse.Content.Headers.ContentType.MediaType -ne "image/png" -or
      !$contentResponse.Headers.ETag -or
      $allContentHeaders -notmatch "(?im)^X-Content-Type-Options:\s*nosniff\s*$" -or
      $contentResponse.Headers.CacheControl.Private -ne $true -or
      $contentResponse.Headers.CacheControl.NoStore -ne $true) {
    throw "Attachment download headers did not pass through the Rust proxy."
  }
  $downloaded = $contentResponse.Content.ReadAsByteArrayAsync().Result
  if ([Convert]::ToBase64String($downloaded) -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes($image))) {
    throw "Attachment download bytes differ from the upload."
  }
  $contentResponse.Dispose()
  $http.Dispose()

  $messageBody = @{
    text = "hello"
    attachmentIds = @($attachmentId)
  } | ConvertTo-Json -Compress
  try {
    Invoke-WebRequest `
      -Method Post `
      -Uri "http://127.0.0.1:$ServerPort/v1/agent/conversations/$($conversation.data.id)/messages" `
      -Headers @{ "Idempotency-Key" = "smoke-message" } `
      -ContentType "application/json" `
      -Body $messageBody | Out-Null
    throw "Message unexpectedly succeeded without a configured model."
  } catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 503) { throw }
  }
  Write-Host "OK: Rust-to-Pi sidecar smoke passed."
} finally {
  if ($agent -and !$agent.HasExited) { Stop-Process -Id $agent.Id -Force }
  if ($server -and !$server.HasExited) { Stop-Process -Id $server.Id -Force }
  @(
    "FINWEALTH_AGENT_BASE_URL",
    "FINWEALTH_AGENT_INTERNAL_TOKEN",
    "FINWEALTH_RS_ADDR",
    "FINWEALTH_AGENT_ADDR",
    "FINWEALTH_SERVER_BASE_URL",
    "FINWEALTH_AGENT_STATE_DIR",
    "PI_CODING_AGENT_DIR"
  ) | ForEach-Object { Remove-Item "Env:$_" -ErrorAction SilentlyContinue }
  foreach ($entry in $savedModelEnvironment.GetEnumerator()) {
    Set-Item "Env:$($entry.Key)" $entry.Value
  }
  $resolvedTemp = [System.IO.Path]::GetFullPath($temp)
  if (
    $resolvedTemp.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $resolvedTemp).StartsWith("finwealth-agent-smoke-") -and
    (Test-Path -LiteralPath $resolvedTemp)
  ) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
