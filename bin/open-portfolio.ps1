# Opens the local "My allocation" page, starting the Rails server first when
# it is not already running. Meant for a desktop shortcut:
#
#   pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File bin\open-portfolio.ps1
#
# The server runs hidden; bin\stop-portfolio.ps1 stops it. Its log is
# log\development.log.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$port = 3000
$page = "http://localhost:$port/portfolio"

function Test-Server {
    try {
        (Invoke-WebRequest -Uri "http://127.0.0.1:$port/portfolio" -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200
    } catch {
        $false
    }
}

if (-not (Test-Server)) {
    # A server that died without cleaning up leaves its pid file behind, and
    # Rails then refuses to start, claiming one is already running.
    $pidFile = Join-Path $root "tmp\pids\server.pid"
    if (Test-Path $pidFile) { Remove-Item $pidFile -Force }

    $ruby = (Get-Command ruby -ErrorAction SilentlyContinue)?.Source
    if (-not $ruby) { $ruby = "C:\Ruby34-x64\bin\ruby.exe" }
    Start-Process -FilePath $ruby -ArgumentList "bin/rails", "server", "-p", "$port" `
        -WorkingDirectory $root -WindowStyle Hidden

    $ready = $false
    for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
        Start-Sleep -Seconds 1
        $ready = Test-Server
    }
    if (-not $ready) {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show("Stock Stave did not start within a minute. See log\development.log.", "Stock Stave") | Out-Null
        exit 1
    }
}

Start-Process $page
