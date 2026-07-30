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
$savedNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Process")
$env:NO_PROXY = @("127.0.0.1", "localhost", "::1", $savedNoProxy) `
  | Where-Object { $_ } `
  | Select-Object -Unique `
  | Join-String -Separator ","
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

  $account = Invoke-RestMethod `
    -Method Post `
    -Uri "http://127.0.0.1:$ServerPort/v1/accounts" `
    -Headers @{ "Idempotency-Key" = "smoke-crypto-account" } `
    -ContentType "application/json" `
    -Body '{"displayName":"Smoke Exchange","accountType":"exchange","defaultCurrency":"USDT","supportedCurrencies":["USDT"],"includeInNetWorth":true,"balanceMode":"holdings","openingBalances":[]}'
  $ensured = Invoke-RestMethod `
    -Method Post `
    -Uri "http://127.0.0.1:$ServerPort/v1/accounts/$($account.data.id)/crypto-instruments/ensure" `
    -Headers @{ "Idempotency-Key" = "smoke-crypto-instruments" } `
    -ContentType "application/json" `
    -Body '{"symbols":["BTC","ETH","USDT","SOL"]}'
  if ($ensured.data.createdCount -ne 4 -or $ensured.data.instruments.Count -ne 4) {
    throw "Crypto instrument registration did not return four deterministic instruments."
  }
  $sol = $ensured.data.instruments | Where-Object { $_.symbol -eq "SOL" } | Select-Object -First 1
  if (!$sol -or $sol.market -ne "crypto" -or $sol.sourceRef -ne "finwealth_agent_discovered_crypto") {
    throw "Discovered crypto instrument metadata was not normalized by the server."
  }
  $holdingsBeforeSnapshot = Invoke-RestMethod `
    -Method Get `
    -Uri "http://127.0.0.1:$ServerPort/v1/accounts/$($account.data.id)/holdings"
  if ($holdingsBeforeSnapshot.data.Count -ne 0) {
    throw "Crypto instrument registration unexpectedly created holdings."
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

  # WeChat JPEGs can contain a short private trailer after the FF D9 end marker.
  # Exercise the complete Rust proxy -> sidecar archive -> byte-for-byte readback path.
  [byte[]]$wechatJpeg = @(
    0xFF,0xD8,0xFF,0xE0,0x00,0x04,0x4A,0x46,0xFF,0xD9,
    0x17,0x4D,0xA1,0x01,0x00,0x00,0x00,0x00,0x42,0xCD,0xF2,0xE4,
    0x03,0xC5,0xBF,0x2F,0x8D,0x87,0x5C,0x01,0xEB,0xFC,0x4B,0x5E
  )
  $jpegMultipart = [Net.Http.MultipartFormDataContent]::new()
  $jpegContent = [Net.Http.ByteArrayContent]::new($wechatJpeg)
  $jpegContent.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new("image/jpeg")
  $jpegMultipart.Add($jpegContent, "file", "wechat.jpg")
  $jpegRequest = [Net.Http.HttpRequestMessage]::new(
    [Net.Http.HttpMethod]::Post,
    "http://127.0.0.1:$ServerPort/v1/agent/attachments"
  )
  $jpegRequest.Headers.Add("Idempotency-Key", "smoke-upload-wechat-jpeg")
  $jpegRequest.Content = $jpegMultipart
  $jpegUploadResponse = $http.Send($jpegRequest)
  if (!$jpegUploadResponse.IsSuccessStatusCode) {
    throw "WeChat JPEG upload failed with $([int]$jpegUploadResponse.StatusCode)."
  }
  $jpegUpload = $jpegUploadResponse.Content.ReadAsStringAsync().Result | ConvertFrom-Json
  $jpegAttachmentId = $jpegUpload.data.id
  $jpegRequest.Dispose()
  $jpegMultipart.Dispose()
  if (!$jpegAttachmentId) { throw "WeChat JPEG upload did not return an ID." }
  $jpegDownload = $http.GetAsync(
    "http://127.0.0.1:$ServerPort/v1/agent/attachments/$jpegAttachmentId/content"
  ).Result
  if (!$jpegDownload.IsSuccessStatusCode -or
      $jpegDownload.Content.Headers.ContentType.MediaType -ne "image/jpeg" -or
      [Convert]::ToBase64String($jpegDownload.Content.ReadAsByteArrayAsync().Result) -ne
        [Convert]::ToBase64String($wechatJpeg)) {
    throw "WeChat JPEG archive/readback did not preserve the original image."
  }
  $jpegDownload.Dispose()
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
  if ($null -eq $savedNoProxy) {
    Remove-Item Env:NO_PROXY -ErrorAction SilentlyContinue
  } else {
    $env:NO_PROXY = $savedNoProxy
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
