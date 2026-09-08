#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers (or re-registers) the scheduled task that runs
    Renew-DestinyCert.ps1 every N weeks on a given day.

.DESCRIPTION
    Default: every 2 weeks, Monday at 3:15 AM. Posh-ACME's
    New-PACertificate only actually renews when the cert is within its
    renewal window (~30 days before expiry), so a biweekly cadence still
    gives 2+ check-in opportunities before expiry even if one run fails
    for some reason -- while cutting the log-file count to about 1/7th of
    a daily trigger.

    Uses New-ScheduledTaskTrigger's native -Weekly -WeeksInterval, which
    handles "every N weeks" directly -- unlike a specific-days-of-month
    schedule (e.g. "1st and 15th"), which has no native trigger type and
    would otherwise require building one against the undocumented, known
    to be inconsistently-typed MSFT_TaskMonthlyTrigger CIM class. Weekly
    is both simpler and more reliably supported, so it's the better
    default here even though it drifts slightly against calendar dates
    over the year (see note below).

    You'll be prompted for the service account's password so the task can
    run whether or not anyone is logged in. Use a dedicated low-privilege
    account -- see Grant-DestinyCertAccountPermissions.ps1 -- delegated
    just start/stop on the Destiny service plus write access to the
    specific folders it needs. It should NOT be a member of local
    Administrators.

.PARAMETER WeeksInterval
    1 for weekly, 2 for every other week (default), etc.

.NOTES
    The "every N weeks" cadence is anchored to when the trigger is
    created (or -RunTime's date), not to any fixed calendar reference --
    Task Scheduler counts N-week intervals forward from that point. If
    you ever re-register this task, the anchor resets to that day.

    IMPORTANT: Run Save-Secret.ps1 (all secrets you're using) while
    logged in AS this same service account BEFORE the first scheduled
    run, since the secrets are DPAPI-protected to that specific account.

    Registered with -RunLevel Limited (standard user token), matching a
    non-admin service account. Requesting -RunLevel Highest for an
    account that isn't a local admin doesn't grant it elevation -- it
    just adds a UAC-style expectation the account can't satisfy -- so
    this deliberately does not use it.
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'Destiny Certificate Renewal',
    [string]$ScriptPath = '..\Scripts\DestinyCertRenew\Renew-DestinyCert.ps1',   #Needs to be set as a real folder no a place holder.
    [Parameter(Mandatory)]
    [string]$ServiceAccount,   # e.g. YOURDOMAIN\svc-destiny-cert
    [string]$RunTime = '03:15',
    [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
    [string]$DayOfWeek = 'Monday',
    [ValidateRange(1, 52)]
    [int]$WeeksInterval = 2
)

$ErrorActionPreference = 'Stop'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

$trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval $WeeksInterval `
    -DaysOfWeek $DayOfWeek -At $RunTime

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 30) `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$cred = Get-Credential -UserName $ServiceAccount -Message "Password for $ServiceAccount"

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $trigger -Settings $settings `
    -User $cred.UserName -Password $cred.GetNetworkCredential().Password `
    -RunLevel Limited -Force

$cadence = if ($WeeksInterval -eq 1) { "every $DayOfWeek" } else { "every $WeeksInterval weeks on $DayOfWeek" }
Write-Host "Scheduled task '$TaskName' registered to run $cadence at $RunTime, as $($cred.UserName)." -ForegroundColor Green
Write-Host "Test it immediately with: Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Yellow
