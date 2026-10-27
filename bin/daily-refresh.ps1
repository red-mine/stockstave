param(
  [string]$RubyPath = "C:\Ruby34-x64\bin\ruby.exe",
  [string]$DatabasePath = "",
  [ValidateSet("manual", "scheduled")]
  [string]$RunSource = "manual",
  [int]$LogRetention = 30,
  [string]$TdxDataPath = $(if ($env:TDX_DATA_PATH) { $env:TDX_DATA_PATH } else { "C:\new_tdx\vipdoc" }),
  [switch]$SkipTdxUpdate
)

$ErrorActionPreference = "Stop"
$repository = Split-Path -Parent $PSScriptRoot
$database = if ($DatabasePath) {
  [System.IO.Path]::GetFullPath($DatabasePath)
} else {
  Join-Path $repository "db\stock.sqlite3"
}
$logDirectory = Join-Path $repository "log\daily-refresh"
$logFile = Join-Path $logDirectory "latest.log"
$archiveLog = Join-Path $logDirectory "refresh-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').log"
# Let a failure that happens before Rails boots still report when the run began.
$env:STOCK_REFRESH_STARTED_AT = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# The whole run has to be serialized, for the same reason bin/daily-refresh.sh
# re-execs under flock: two runs used to share tmp/tdx-update/hsjday.zip.part
# and corrupt each other's archive, and the lock the Rails task takes is only
# held once Rails has booted, too late to protect the download. Windows has no
# flock, so hold the lock file with FileShare.None instead; a second copy then
# fails to open it and skips rather than racing the first one.
$lockPath = if ($env:STOCK_REFRESH_LOCK) { $env:STOCK_REFRESH_LOCK } else { Join-Path $repository "tmp\daily-refresh.lock" }
New-Item -ItemType Directory -Path (Split-Path -Parent $lockPath) -Force | Out-Null
$lockStream = $null
try {
  $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  $lockStream.SetLength(0)
  $lockNote = [System.Text.Encoding]::UTF8.GetBytes("pid=$PID started=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))`n")
  $lockStream.Write($lockNote, 0, $lockNote.Length)
  $lockStream.Flush()
} catch {
  if ($null -ne $lockStream) { $lockStream.Dispose(); $lockStream = $null }
  Write-Output "[$(Get-Date -Format o)] Another Stock Stave refresh already holds $lockPath; skipping this run"
  exit 0
}

if (-not (Test-Path -LiteralPath $RubyPath -PathType Leaf)) {
  throw "Ruby executable not found: $RubyPath"
}
if (-not (Test-Path -LiteralPath $database -PathType Leaf)) {
  throw "Stock database not found: $database"
}

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$env:STOCK_DATABASE = $database
$env:STOCK_REFRESH_SOURCE = $RunSource
$env:TDX_DATA_PATH = [System.IO.Path]::GetFullPath($TdxDataPath)
$env:RAILS_ENV = "development"
$env:RACK_ENV = "development"
$env:Path = "$(Split-Path -Parent $RubyPath);$env:Path"

Push-Location $repository
try {
  "[$(Get-Date -Format o)] Starting daily refresh" | Tee-Object -FilePath $logFile
  if ($SkipTdxUpdate) {
    "[$(Get-Date -Format o)] Skipping TongdaXin download by request" | Tee-Object -FilePath $logFile -Append
  } else {
    & (Join-Path $PSScriptRoot "update-tdx-data.ps1") -DataPath $env:TDX_DATA_PATH 2>&1 |
      Tee-Object -FilePath $logFile -Append
    if ($LASTEXITCODE -ne 0) {
      throw "TongdaXin update failed with exit code $LASTEXITCODE"
    }
  }
  & $RubyPath bin\rails daily_refresh 2>&1 | Tee-Object -FilePath $logFile -Append
  if ($LASTEXITCODE -ne 0) {
    throw "Daily refresh failed with exit code $LASTEXITCODE"
  }
  # The public preview serves an isolated database copy that nothing else
  # writes, so without this mirror the public site keeps serving whatever
  # that copy held when it was seeded. A mirror failure is not a refresh
  # failure: the data is current either way, so it is logged loudly and the
  # run still counts as successful.
  & $RubyPath bin\rails mirror_preview_database 2>&1 | Tee-Object -FilePath $logFile -Append
  if ($LASTEXITCODE -ne 0) {
    "[$(Get-Date -Format o)] WARNING: could not mirror the public preview database; the public site may serve stale data" |
      Tee-Object -FilePath $logFile -Append
  }
  "[$(Get-Date -Format o)] Daily refresh succeeded" | Tee-Object -FilePath $logFile -Append
} catch {
  "[$(Get-Date -Format o)] $($_.Exception.Message)" | Tee-Object -FilePath $logFile -Append
  # Rails records failures itself once it boots; without this a TongdaXin
  # download error would leave the previous success on the website while the
  # data silently aged.
  $env:STOCK_REFRESH_ERROR = $_.Exception.Message
  try {
    & $RubyPath bin\rails record_refresh_failure 2>&1 | Tee-Object -FilePath $logFile -Append
  } catch {
    "[$(Get-Date -Format o)] Could not record the refresh failure in the status files: $($_.Exception.Message)" |
      Tee-Object -FilePath $logFile -Append
  }
  exit 1
} finally {
  if ($null -ne $lockStream) { $lockStream.Dispose() }
  if (Test-Path -LiteralPath $logFile) {
    Copy-Item -LiteralPath $logFile -Destination $archiveLog -Force
  }
  $keep = [Math]::Max($LogRetention, 1)
  Get-ChildItem -LiteralPath $logDirectory -Filter "refresh-*.log" -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $keep |
    Remove-Item -Force
  Pop-Location
}
