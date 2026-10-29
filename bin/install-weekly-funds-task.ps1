param(
  [string]$TaskName = "Stock Stave Weekly Fund Refresh",
  [string]$Day = "Saturday",
  [string]$At = "09:00"
)

# Registers a weekly Windows task that refreshes the fund checkup data
# (bin\funds-refresh.ps1). Missed runs start when the computer is next on.

$ErrorActionPreference = "Stop"
$runner = Join-Path $PSScriptRoot "funds-refresh.ps1"
$time = [DateTime]::ParseExact($At, "HH:mm", [Globalization.CultureInfo]::InvariantCulture)
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source

$action = New-ScheduledTaskAction `
  -Execute $pwsh `
  -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runner`""
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $time
$settings = New-ScheduledTaskSettingsSet `
  -StartWhenAvailable `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Hours 3)
$principal = New-ScheduledTaskPrincipal `
  -UserId $env:USERNAME `
  -LogonType Interactive `
  -RunLevel Limited

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Principal $principal `
  -Description "Refresh the Stock Stave fund checkup data every week." `
  -Force | Out-Null

Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
