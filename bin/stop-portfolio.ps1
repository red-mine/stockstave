# Stops the local Rails server that bin\open-portfolio.ps1 started hidden.
# Meant for a desktop shortcut:
#
#   pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File bin\stop-portfolio.ps1

$root = Split-Path -Parent $PSScriptRoot
$pidFile = Join-Path $root "tmp\pids\server.pid"

Add-Type -AssemblyName PresentationFramework
if (Test-Path $pidFile) {
    $serverPid = (Get-Content $pidFile -Raw).Trim()
    # /T takes the process tree, so Puma's children go with it.
    taskkill /PID $serverPid /T /F | Out-Null
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    [System.Windows.MessageBox]::Show("已关闭配置服务。", "Stock Stave") | Out-Null
} else {
    [System.Windows.MessageBox]::Show("配置服务没有在运行。", "Stock Stave") | Out-Null
}
