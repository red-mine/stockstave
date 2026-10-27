param(
  [string]$RubyPath = "C:\Ruby34-x64\bin\ruby.exe",
  [string]$DatabasePath = "",
  [int]$Port = 3000
)

$ErrorActionPreference = "Stop"
$repository = Split-Path -Parent $PSScriptRoot
$database = if ($DatabasePath) {
  [System.IO.Path]::GetFullPath($DatabasePath)
} else {
  Join-Path $repository "tmp\ui-stock.sqlite3"
}
$isolatedDatabase = [System.IO.Path]::GetFullPath((Join-Path $repository "tmp\ui-stock.sqlite3"))
$cloudflared = Join-Path $repository "tmp\cloudflared\cloudflared.exe"
$tunnelOut = Join-Path $repository "tmp\cloudflared-out.log"
$tunnelError = Join-Path $repository "tmp\cloudflared-err.log"
$serverOut = Join-Path $repository "tmp\public-preview-server-out.log"
$serverError = Join-Path $repository "tmp\public-preview-server-err.log"
$statusPath = Join-Path $repository "tmp\public-preview.json"
$startLockPath = Join-Path $repository "tmp\public-preview-start.lock"

function New-PreviewStartLock {
  try {
    return [System.IO.File]::Open(
      $startLockPath,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )
  } catch [System.IO.IOException] {
    $existingLock = Get-Item -LiteralPath $startLockPath -ErrorAction SilentlyContinue
    if ($existingLock -and ((Get-Date) - $existingLock.LastWriteTime).TotalMinutes -gt 5) {
      Remove-Item -LiteralPath $startLockPath -Force
      return [System.IO.File]::Open(
        $startLockPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
      )
    }
    throw "A public preview start is already running"
  }
}

$startLock = New-PreviewStartLock
$tunnel = $null
$server = $null
try {

if ([System.IO.Path]::GetFullPath($database) -ne $isolatedDatabase) {
  throw "Public preview must use the isolated database: $isolatedDatabase"
}

foreach ($file in @($RubyPath, $database, $cloudflared)) {
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
    throw "Required file not found: $file"
  }
}

$env:Path = "$(Split-Path -Parent $RubyPath);$env:Path"
$env:STOCK_DATABASE = $database
$env:RAILS_ENV = "production"
$env:RACK_ENV = "production"
$env:RAILS_LOG_LEVEL = "warn"
$env:RAILS_SERVE_STATIC_FILES = "1"
# Production insists on a secret_key_base, but nothing in this app signs a
# session or a cookie and no route writes, so a per-run value satisfies the boot
# check without leaving a secret on disk or anywhere near the repository.
$env:SECRET_KEY_BASE = "$(New-Guid)$(New-Guid)".Replace("-", "")

# Production turns off config.assets.compile, so no page renders until the
# fingerprinted bundle exists. The monitor re-runs this script whenever the
# preview looks unhealthy, so rebuild only when the bundle is missing or older
# than its sources rather than on every restart.
$assetDirectory = Join-Path $repository "public\assets"
$manifest = Get-ChildItem -LiteralPath $assetDirectory -Force -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -eq ".manifest.json" -or $_.Name -like ".sprockets-manifest-*" } |
  Select-Object -First 1
$sources = @(Join-Path $repository "app\assets", (Join-Path $repository "app\javascript"), (Join-Path $repository "config\importmap.rb")) |
  Where-Object { Test-Path -LiteralPath $_ }
$assetsStale = -not $manifest
if ($manifest -and -not $assetsStale) {
  $newer = foreach ($source in $sources) {
    Get-ChildItem -LiteralPath $source -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -gt $manifest.LastWriteTime }
  }
  $assetsStale = @($newer).Count -gt 0
}
if ($assetsStale) {
  Write-Output "Precompiling assets for the production preview"
  & $RubyPath bin/rails assets:precompile
  if ($LASTEXITCODE -ne 0) { throw "assets:precompile failed with exit code $LASTEXITCODE" }
}

function Stop-VerifiedProcess([int]$ProcessId, [string]$Name, [string]$CommandPattern) {
  $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if (-not $process) { return }
  $command = (Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId").CommandLine
  if ($process.ProcessName -ne $Name -or $command -notmatch $CommandPattern) {
    throw "Refusing to stop unexpected process $ProcessId ($($process.ProcessName))"
  }
  Stop-Process -Id $ProcessId -Force
}

$existingTunnel = Get-CimInstance Win32_Process |
  Where-Object { $_.Name -eq "cloudflared.exe" -and $_.CommandLine -like "*$cloudflared*" }
foreach ($process in $existingTunnel) {
  Stop-VerifiedProcess $process.ProcessId "cloudflared" "cloudflared\.exe.*tunnel"
}

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
  Select-Object -First 1
if ($listener) {
  Stop-VerifiedProcess $listener.OwningProcess "ruby" "bin[/\\]rails server"
}
Start-Sleep -Seconds 2

Remove-Item -LiteralPath $tunnelOut, $tunnelError, $serverOut, $serverError -Force -ErrorAction SilentlyContinue
$tunnel = Start-Process -FilePath $cloudflared `
  -ArgumentList "tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:$Port", "--http-host-header", "localhost" `
  -WorkingDirectory $repository -WindowStyle Hidden `
  -RedirectStandardOutput $tunnelOut -RedirectStandardError $tunnelError -PassThru

$deadline = (Get-Date).AddSeconds(60)
do {
  Start-Sleep -Seconds 2
  $tunnelLog = ((Get-Content $tunnelOut -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content $tunnelError -Raw -ErrorAction SilentlyContinue))
  # The issued URL is the only trycloudflare.com address that is not followed
  # by a path. A failed request logs "https://api.trycloudflare.com/tunnel",
  # and reading that as the preview's address sends every later check to the
  # Cloudflare API instead of the preview -- which is how a tunnel that never
  # started looked like a preview that would not answer.
  $urlMatch = [regex]::Match($tunnelLog, "https://[a-z0-9-]+\.trycloudflare\.com(?![/\w-])")
} while (-not $urlMatch.Success -and (Get-Date) -lt $deadline)
if (-not $urlMatch.Success) {
  Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue
  throw "Cloudflare did not issue a public URL within 60 seconds"
}

$publicUrl = $urlMatch.Value
$server = Start-Process -FilePath $RubyPath `
  -ArgumentList "bin/rails", "server", "-p", $Port, "-b", "127.0.0.1" `
  -WorkingDirectory $repository -WindowStyle Hidden `
  -RedirectStandardOutput $serverOut -RedirectStandardError $serverError -PassThru

$deadline = (Get-Date).AddSeconds(120)
do {
  Start-Sleep -Seconds 3
  $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
} while (-not $listener -and (Get-Date) -lt $deadline)
if (-not $listener) {
  Stop-Process -Id $server.Id, $tunnel.Id -Force -ErrorAction SilentlyContinue
  throw "Rails did not listen on port $Port within 120 seconds"
}

$areas = @("sz", "sh", "bj")
function Test-ApplicationHealth([string]$Uri) {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 15
    $body = $response.Content | ConvertFrom-Json
    $marketsReady = @($areas | Where-Object {
      $market = $body.markets.PSObject.Properties[$_].Value
      -not $market -or -not $market.ready -or -not $market.date -or [int]$market.rows -le 0 -or
        $market.snapshot_date -ne $market.date -or [int]$market.snapshot_rows -ne [int]$market.rows
    }).Count -eq 0
    return $response.StatusCode -eq 200 -and $body.status -eq "ready" -and $body.environment -eq "production" -and $body.log_level -eq "warn" -and $body.dates_aligned -and $marketsReady
  } catch {
    return $false
  }
}

$healthDeadline = (Get-Date).AddSeconds(90)
do {
  $applicationFailures = @()
  if (-not (Test-ApplicationHealth "http://127.0.0.1:$Port/preview-health")) { $applicationFailures += "local application data" }
  if (-not (Test-ApplicationHealth "$publicUrl/preview-health")) { $applicationFailures += "public application data" }
  $failedChecks = foreach ($area in $areas) {
    $localResponse = try {
      Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/$area" -TimeoutSec 15
    } catch {
      $null
    }
    $publicResponse = try {
      Invoke-WebRequest -UseBasicParsing -Uri "$publicUrl/$area" -TimeoutSec 15
    } catch {
      $null
    }
    $localCode = if ($localResponse) { $localResponse.StatusCode } else { 0 }
    $publicCode = if ($publicResponse) { $publicResponse.StatusCode } else { 0 }
    if ($localCode -ne 200 -or $publicCode -ne 200) {
      "$area(local=$localCode, public=$publicCode)"
    }
  }
  $failedChecks = @($applicationFailures) + @($failedChecks)
  if ($failedChecks.Count -gt 0 -and (Get-Date) -lt $healthDeadline) {
    Start-Sleep -Seconds 5
  }
} while ($failedChecks.Count -gt 0 -and (Get-Date) -lt $healthDeadline)
if ($failedChecks.Count -gt 0) {
  throw "Preview market health check failed: $($failedChecks -join '; ')"
}

$status = @{
  url = $publicUrl
  started_at = (Get-Date).ToUniversalTime().ToString("o")
  rails_pid = ($listener | Select-Object -First 1).OwningProcess
  tunnel_pid = $tunnel.Id
  database = $database
  port = $Port
  environment = "production"
  log_level = "warn"
}
$status | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding utf8
Write-Output ([pscustomobject]$status)
} catch {
  if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  if ($tunnel) { Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue }
  throw
} finally {
  $startLock.Dispose()
  Remove-Item -LiteralPath $startLockPath -Force -ErrorAction SilentlyContinue
}
