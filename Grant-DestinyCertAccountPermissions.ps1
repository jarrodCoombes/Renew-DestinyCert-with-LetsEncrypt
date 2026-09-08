#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Grants a service account the minimum rights needed to run
    Renew-DestinyCert.ps1 -- without local admin.

.DESCRIPTION
    Run this ONCE, as an actual administrator, after creating the service
    account (see README.md "Service account" section for account creation
    itself -- this script only grants permissions to an account that
    already exists).

    Grants exactly:
      1. "Log on as a batch job" right (required for a Scheduled Task to
         run unattended) -- via secedit, no third-party tools.
      2. NTFS Modify on the working directory, the FSC-Cert folder, and
         the .well-known webroot.
      3. NTFS Read+Execute on destiny.xml and the keytool/JRE folder.
      4. Start+Stop (NOT reconfigure) on the Destiny/WildFly service
         itself, via that service's own ACL -- this is what lets
         Restart-Service work without the account being a local admin.

    Does NOT add the account to any administrative group, grant
    interactive/RDP logon, or grant rights to anything outside the five
    paths above.

.PARAMETER AccountName
    The service account, e.g. 'YOURDOMAIN\svc-destiny-cert' or
    '.\svc-destiny-cert' for a local account.

.EXAMPLE
    .\Grant-DestinyCertAccountPermissions.ps1 -AccountName 'YOURDOMAIN\svc-destiny-cert'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AccountName,
     # These all need to be set to real folder paths.
    [string]$WorkDir        = '..\Scripts\DestinyCertRenew',
    [string]$KeystoreDir    = '..\FSC-Cert',
    [string]$WebRootWellKnown = '..\FSC-Destiny\wildfly\.well-known',
    [string]$DestinyXmlPath = '..\FSC-Destiny\wildfly\standalone\configuration\destiny.xml',
    [string]$KeytoolDir     = '..\FSC-Destiny\java',
    [string]$ServiceName    = 'Destiny',  # Need to verify this and make sure it's correct. 

    # Optional hardening: block this account from any interactive or RDP
    # logon, so a leaked password can only be used to run the scheduled
    # task, not to log in as a user.
    [switch]$DenyInteractiveLogon
)

$ErrorActionPreference = 'Stop'

function Resolve-Sid {
    param([string]$Account)
    (New-Object System.Security.Principal.NTAccount($Account)).
        Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function Grant-UserRight {
    # Adds $Sid to a local security policy user right (e.g. SeBatchLogonRight)
    # without disturbing any other accounts already holding that right.
    param([string]$Sid, [string]$Right)

    $cfgPath = Join-Path $env:TEMP "secpol-$Right-$(Get-Random).cfg"
    $dbPath  = Join-Path $env:TEMP "secpol-$Right-$(Get-Random).sdb"

    secedit /export /cfg $cfgPath /areas USER_RIGHTS | Out-Null
    $content = @(Get-Content $cfgPath)

    $lineIndex = -1
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match "^$Right\s*=") { $lineIndex = $i; break }
    }

    if ($lineIndex -ge 0) {
        $existingValue = ($content[$lineIndex] -split '=', 2)[1].Trim()
        if ($existingValue -match [regex]::Escape("*$Sid")) {
            Write-Host "  $Right already includes this account -- skipping." -ForegroundColor DarkGray
            Remove-Item $cfgPath -ErrorAction SilentlyContinue
            return
        }
        $newValue = if ($existingValue) { "$existingValue,*$Sid" } else { "*$Sid" }
        $content[$lineIndex] = "$Right = $newValue"
    }
    else {
        $content += "$Right = *$Sid"
    }

    $content | Set-Content $cfgPath
    secedit /configure /db $dbPath /cfg $cfgPath /areas USER_RIGHTS | Out-Null
    Remove-Item $cfgPath, $dbPath -ErrorAction SilentlyContinue
}

function Grant-ServiceControlAccess {
    # Appends a minimal ACE to a service's own security descriptor:
    # SERVICE_QUERY_CONFIG, SERVICE_QUERY_STATUS, SERVICE_ENUMERATE_DEPENDENTS,
    # SERVICE_START, SERVICE_STOP, SERVICE_PAUSE_CONTINUE, SERVICE_INTERROGATE,
    # SERVICE_USER_DEFINED_CONTROL, READ_CONTROL.
    # Deliberately EXCLUDES SERVICE_CHANGE_CONFIG, WRITE_DAC, WRITE_OWNER --
    # this account can restart the service but cannot repoint its binary,
    # change its logon account, or alter who else has access to it.
    param([string]$Sid, [string]$ServiceName)

    $before = (& sc.exe sdshow $ServiceName) -join ''
    if ([string]::IsNullOrWhiteSpace($before)) {
        throw "Could not read current SDDL for service '$ServiceName'. Confirm the service name with Get-Service."
    }

    $backupFile = Join-Path $env:TEMP "$ServiceName.sddl.backup.txt"
    $before | Out-File $backupFile
    Write-Host "  Backed up current service SDDL to $backupFile" -ForegroundColor DarkGray

    $ace = "(A;;CCLCSWRPWPDTLOCRRC;;;$Sid)"
    if ($before.Contains($Sid)) {
        Write-Host "  Service ACL already references this account -- skipping." -ForegroundColor DarkGray
        return
    }

    # Insert the new ACE right after the DACL flags, before the first
    # existing ACE, rather than rebuilding the whole string.
    $firstAceIndex = $before.IndexOf('(A;')
    if ($firstAceIndex -lt 0) {
        throw "Unexpected SDDL format for service '$ServiceName': $before"
    }
    $newSddl = $before.Insert($firstAceIndex, $ace)

    & sc.exe sdset $ServiceName $newSddl | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "sc.exe sdset failed for '$ServiceName'. Restore from $backupFile with: sc.exe sdset $ServiceName `"$before`""
    }
}

Write-Host "=== Granting minimal permissions to $AccountName ===" -ForegroundColor Cyan
$sid = Resolve-Sid -Account $AccountName
Write-Host "Resolved SID: $sid"

Write-Host "`n[1/4] Granting 'Log on as a batch job'..." -ForegroundColor Cyan
Grant-UserRight -Sid $sid -Right 'SeBatchLogonRight'

if ($DenyInteractiveLogon) {
    Write-Host "`n[1b/4] Denying interactive + RDP logon (hardening)..." -ForegroundColor Cyan
    Grant-UserRight -Sid $sid -Right 'SeDenyInteractiveLogonRight'
    Grant-UserRight -Sid $sid -Right 'SeDenyRemoteInteractiveLogonRight'
}

Write-Host "`n[2/4] Granting NTFS permissions..." -ForegroundColor Cyan
foreach ($dir in @($WorkDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
Write-Host "  Modify: $WorkDir (recursive)"
icacls $WorkDir /grant "${AccountName}:(OI)(CI)M" /T | Out-Null

Write-Host "  Modify: $KeystoreDir"
icacls $KeystoreDir /grant "${AccountName}:(OI)(CI)M" | Out-Null

Write-Host "  Modify: $WebRootWellKnown (recursive -- needs to create acme-challenge subfolder)"
if (-not (Test-Path $WebRootWellKnown)) {
    throw "$WebRootWellKnown not found. Confirm this matches the well-known-handler path in destiny.xml before continuing."
}
icacls $WebRootWellKnown /grant "${AccountName}:(OI)(CI)M" /T | Out-Null

Write-Host "  Read+Execute: $DestinyXmlPath (read-only -- config drift check)"
icacls $DestinyXmlPath /grant "${AccountName}:(RX)" | Out-Null

Write-Host "  Read+Execute: $KeytoolDir (recursive -- needs to run keytool.exe)"
icacls $KeytoolDir /grant "${AccountName}:(OI)(CI)RX" /T | Out-Null

Write-Host "`n[3/4] Granting service start/stop on '$ServiceName' (not reconfigure)..." -ForegroundColor Cyan
Grant-ServiceControlAccess -Sid $sid -ServiceName $ServiceName

Write-Host "`n[4/4] Sanity checks..." -ForegroundColor Cyan
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) { Write-Host "  WARNING: service '$ServiceName' not found -- confirm the name." -ForegroundColor Yellow }
else { Write-Host "  Service found: $($svc.DisplayName) [$($svc.Status)]" -ForegroundColor DarkGray }

Write-Host "`nDone. This account still needs no group membership changes -- do NOT add it to" -ForegroundColor Green
Write-Host "Administrators or any other privileged group." -ForegroundColor Green
Write-Host "`nNext: log in AS $AccountName and run Save-Secret.ps1, then test with a -Staging run." -ForegroundColor Yellow
