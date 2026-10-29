# Refreshes the fund checkup data (bin/rails funds:refresh) and keeps a log:
# log\funds-refresh\latest.log plus timestamped copies of the last 10 runs.
# Run weekly by the task bin\install-weekly-funds-task.ps1 registers.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $root "log\funds-refresh"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$log = Join-Path $logDir "$stamp.log"

$ruby = (Get-Command ruby -ErrorAction SilentlyContinue)?.Source
if (-not $ruby) { $ruby = "C:\Ruby34-x64\bin\ruby.exe" }

Push-Location $root
try {
    "started $(Get-Date -Format o)" | Set-Content -LiteralPath $log -Encoding utf8
    & $ruby bin/rails funds:refresh *>> $log
    $code = $LASTEXITCODE
    "finished $(Get-Date -Format o) exit $code" | Add-Content -LiteralPath $log -Encoding utf8
} finally {
    Pop-Location
}

Copy-Item -LiteralPath $log -Destination (Join-Path $logDir "latest.log") -Force
Get-ChildItem -LiteralPath $logDir -Filter "2*.log" | Sort-Object Name -Descending |
    Select-Object -Skip 10 | Remove-Item -Force
exit $code
