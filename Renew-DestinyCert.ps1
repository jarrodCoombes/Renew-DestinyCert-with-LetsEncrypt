<#
.SYNOPSIS
    Renews the Let's Encrypt certificate for your Destiny installation, converts it to a
    Java Keystore, deploys it to Follett Destiny, and restarts the service.

.DESCRIPTION
    Uses the Posh-ACME module to request/renew a Let's Encrypt cert via HTTP-01
    challenge, using the WebRoot plugin to drop the challenge file directly
    into WildFly's .well-known folder (..\FSC-Destiny\wildfly\.well-known,
    already mapped to /.well-known by the well-known-handler in destiny.xml).
    No DNS changes, no separate listener, no port 80 exposure beyond what's
    already required for the redirect-to-HTTPS behavior WildFly already has.
    Posh-ACME's New-PACertificate is idempotent -- if the current cert isn't
    within its renewal window, it does nothing -- so this script is safe to
    run on any recurring schedule (this repo's default is every 2 weeks via
    Scheduled Task).

    On success: converts the PFX to JKS, backs up the existing keystore,
    deploys the new one, restarts the Destiny service, and writes a log +
    CSV report row. On any failure: emails an alert and exits non-zero.

.NOTES
    Run once manually (see README.md) to register the ACME account and do
    a staging-server dry run before pointing this at production and a
    scheduled task.

    Deliberately does NOT require local admin. It's designed to run as a
    low-privilege service account that has been delegated exactly the
    NTFS + service-control rights it needs -- see
    Grant-DestinyCertAccountPermissions.ps1 and the "Service account"
    section of README.md. If a step fails with Access Denied, that's a
    permissions gap to fix on the account, not a reason to run this as
    admin.

    Every value under "# CONFIRM" MUST be verified against your actual
    Destiny install before running against production.
#>

[CmdletBinding()]
param(
    # Use the LE staging server (no real cert issued, no rate limits) for testing.
    [switch]$Staging,

    # Force a renewal even if the current cert isn't near expiry.
    [switch]$Force,

    # Only report current cert/keystore status; do not renew or deploy anything.
    [switch]$ReportOnly,

    # Send a test message and exit -- no Posh-ACME, no keystore, no service
    # restart touched at all. Tests the channel(s) directly, ignoring the
    # AlertViaEmail/AlertViaGoogleChat config toggles, so you can verify a
    # channel works before deciding whether to enable it for real alerts.
    [switch]$TestAlert,

    [ValidateSet('Email', 'GoogleChat', 'Both')]
    [string]$TestChannel = 'Both'
)

$ErrorActionPreference = 'Stop'

#region ===================== CONFIGURATION =====================
# Anything in here that starts with ..\ should be checked and verified and changed to an actual path, not a place holder.
$Config = @{
    # --- Certificate ---
    Domain        = 'destiny.yourdistrict.org'  # Your Destiny Server's Domain
    ContactEmail  = 'email@yourdistrict.org'    # LE Registration Email 

    # --- HTTP-01 / WebRoot ---
    # The folder that WildFly's well-known-handler serves at /.well-known
    # (jboss.home.dir in destiny.xml -- the WebRoot plugin will create the
    # \.well-known\acme-challenge\ subfolder under this automatically).
    WebRootPath    = '..\FSC-Destiny\wildfly'   # May vary by server

    # Config file where the custom well-known-handler/location was added.
    # A Destiny/WildFly update can overwrite this and silently revert the
    # edit -- see Test-WellKnownConfig below.
    DestinyXmlPath = '..\FSC-Destiny\wildfly\standalone\configuration\destiny.xml'  # May vary by server

    # --- keytool / Java Keystore ---
    # Bundled with Destiny's JRE
    KeytoolPath    = '..\FSC-Destiny\java\bin\keytool.exe'

    # Confirmed from destiny.xml's <key-store><file path="..."/>
    KeystorePath   = '..\FSC-Cert\destiny.keystore'
    KeystoreAlias  = 'destiny'				# Might be different in your environment, needs to be verified.
    KeystorePassFile = '..\Scripts\DestinyCertRenew\secrets\keystore-pass.xml'

    # PFX export password Posh-ACME will use (also secured via Save-Secret.ps1)
    PfxPassFile    = '..\Scripts\DestinyCertRenew\secrets\pfx-pass.xml'

    # --- Service ---
    ServiceName    = 'Destiny'
    # How long to wait for Destiny/WildFly to actually finish deploying and
    # bind port 443 after the service reports Running, before giving up on
    # the (non-fatal) TLS verification step. Destiny can take a few minutes.
    TlsVerifyTimeoutMinutes  = 5
    TlsVerifyIntervalSeconds = 10

    # --- Paths ---
    WorkDir        = '..\Scripts\DestinyCertRenew'
    BackupDir      = '..\Scripts\DestinyCertRenew\Backups'
    LogDir         = '..\Scripts\DestinyCertRenew\Logs'
    ReportCsv      = '..\Scripts\DestinyCertRenew\Logs\renewal-history.csv'

    # --- Email alerts ---
    # CHANGE ME: your outbound SMTP relay. Common gotchas:
    #  - Google Workspace: use smtp-relay.gmail.com, NOT aspmx.l.google.com
    #    (that's the inbound MX record and won't accept relayed mail).
    #    Needs your server's IP authorized -- or SmtpCredFile set up for
    #    authenticated submission -- under Admin console > Gmail > Routing
    #    > SMTP relay service.
    #  - Microsoft 365: typically smtp.office365.com, port 587, with an
    #    authenticated mailbox via SmtpCredFile (or a configured connector
    #    for anonymous relay from your server's IP).
    #  - Internal relay: whatever your mail team already has for
    #    application/no-reply mail.
    SmtpServer     = 'smtp.yourdistrict.org'
    SmtpPort       = 587
    SmtpUseSsl     = $true
    SmtpCredFile   = '..\Scripts\DestinyCertRenew\secrets\smtp-cred.xml'  # optional, see README
    MailFrom       = 'email@yourdistrict.org'
    MailTo         = @('you@yourdistrict.org')

    # --- Alert channels ---
    # Toggle independently -- both on, either one alone, or neither
    # (though neither means failures only ever show up in the log/CSV).
    # Test either one directly with: .\Renew-DestinyCert.ps1 -TestAlert -TestChannel Email
    AlertViaEmail        = $true
    AlertViaGoogleChat   = $true
    GoogleChatWebhookUrlFile = '..\Scripts\DestinyCertRenew\secrets\googlechat-webhook.xml'
}
#endregion

#region ===================== SETUP =====================

foreach ($dir in @($Config.WorkDir, $Config.BackupDir, $Config.LogDir, (Split-Path $Config.KeystorePassFile))) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

$RunStamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$LogFile  = Join-Path $Config.LogDir "renew-$RunStamp.log"

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

function Get-SecureValue {
    param([string]$Path, [string]$FriendlyName)
    if (-not (Test-Path $Path)) {
        throw "Secret file not found: $Path (expected $FriendlyName). Run Save-Secret.ps1 first -- see README."
    }
    # Files created with Export-Clixml on a SecureString are DPAPI-protected
    # to the user + machine that created them. Must run as the same account.
    return Import-Clixml -Path $Path
}

function Send-AlertEmail {
    param([string]$Subject, [string]$Body)
    try {
        $mailParams = @{
            SmtpServer = $Config.SmtpServer
            Port       = $Config.SmtpPort
            UseSsl     = $Config.SmtpUseSsl
            From       = $Config.MailFrom
            To         = $Config.MailTo
            Subject    = $Subject
            Body       = $Body
        }
        if (Test-Path $Config.SmtpCredFile) {
            $mailParams.Credential = Import-Clixml -Path $Config.SmtpCredFile
        }
        # Send-MailMessage is deprecated but still functional in Windows PowerShell 5.1/7.
        # Swap for Send-MailKitMessage (Install-Module Send-MailKitMessage) if you'd rather
        # not rely on a deprecated cmdlet -- see README.
        Send-MailMessage @mailParams
        Write-Log "Alert email sent: $Subject"
    }
    catch {
        Write-Log "Failed to send alert email: $($_.Exception.Message)" -Level ERROR
    }
}

function Send-GoogleChatAlert {
    param([string]$Subject, [string]$Body)
    $webhookUrlPlain = $null
    try {
        $webhookUrl = Get-SecureValue -Path $Config.GoogleChatWebhookUrlFile -FriendlyName 'Google Chat webhook URL'
        $webhookUrlPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($webhookUrl))

        $payload = @{ text = "*$Subject*`n$Body" } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri $webhookUrlPlain -Method Post `
            -ContentType 'application/json; charset=UTF-8' -Body $payload | Out-Null
        Write-Log "Google Chat alert sent: $Subject"
    }
    catch {
        Write-Log "Failed to send Google Chat alert: $($_.Exception.Message)" -Level ERROR
    }
    finally {
        Remove-Variable webhookUrlPlain -ErrorAction SilentlyContinue
    }
}

function Send-Alert {
    # Dispatches to whichever channel(s) are enabled in $Config. Each
    # channel fails independently -- one being down/misconfigured doesn't
    # block the other from still notifying you.
    param([string]$Subject, [string]$Body)

    $sentAny = $false
    if ($Config.AlertViaEmail) {
        Send-AlertEmail -Subject $Subject -Body $Body
        $sentAny = $true
    }
    if ($Config.AlertViaGoogleChat) {
        Send-GoogleChatAlert -Subject $Subject -Body $Body
        $sentAny = $true
    }
    if (-not $sentAny) {
        Write-Log "No alert channels enabled (AlertViaEmail/AlertViaGoogleChat both false) -- not sent: $Subject" -Level WARN
    }
}

function Add-ReportRow {
    param([string]$Status, [string]$Detail, [Nullable[datetime]]$NotAfter)
    $row = [pscustomobject]@{
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Status    = $Status
        NotAfter  = $NotAfter
        Detail    = $Detail
    }
    $writeHeader = -not (Test-Path $Config.ReportCsv)
    $row | Export-Csv -Path $Config.ReportCsv -Append -NoTypeInformation -Force
}

function Test-WellKnownConfig {
    <#
    Confirms destiny.xml still contains the custom well-known-handler and
    location entries. A Destiny/WildFly update can overwrite destiny.xml
    wholesale and silently drop hand-edited additions like this one.
    #>
    param([string]$XmlPath)

    if (-not (Test-Path $XmlPath)) {
        Write-Log "destiny.xml not found at $XmlPath" -Level ERROR
        return $false
    }

    $content = Get-Content -Path $XmlPath -Raw

    $hasHandler  = $content.Contains('well-known-handler') -and
                   $content.Contains('${jboss.home.dir}/.well-known')
    $hasLocation = $content.Contains('name="/.well-known"') -and
                   $content.Contains('handler="well-known-handler"')

    if (-not $hasHandler)  { Write-Log "destiny.xml is missing the well-known-handler <file> entry." -Level ERROR }
    if (-not $hasLocation) { Write-Log "destiny.xml is missing the /.well-known <location> entry." -Level ERROR }

    return ($hasHandler -and $hasLocation)
}

function Test-ChallengeWebroot {
    <#
    Round-trips a random canary file through the actual webroot and fetches
    it back over HTTP from WildFly itself (via localhost, so this doesn't
    depend on external DNS/firewall -- those were already confirmed
    separately). Catches cases the XML check alone wouldn't: WildFly not
    yet restarted after some other change, folder permissions changed,
    the acme-challenge subfolder deleted, etc.
    #>
    param($Config)

    $canaryName  = [guid]::NewGuid().ToString('N') + '.txt'
    $canaryValue = [guid]::NewGuid().ToString('N')
    $acmeDir     = Join-Path $Config.WebRootPath '.well-known\acme-challenge'
    $canaryPath  = Join-Path $acmeDir $canaryName

    try {
        if (-not (Test-Path $acmeDir)) { New-Item -ItemType Directory -Path $acmeDir -Force | Out-Null }
        Set-Content -Path $canaryPath -Value $canaryValue -NoNewline

        $resp = Invoke-WebRequest -Uri "http://localhost/.well-known/acme-challenge/$canaryName" `
            -UseBasicParsing -TimeoutSec 15

        if ($resp.StatusCode -ne 200) {
            Write-Log "Live challenge-path test got HTTP $($resp.StatusCode) instead of 200." -Level ERROR
            return $false
        }
        if ($resp.Content.Trim() -ne $canaryValue) {
            Write-Log "Live challenge-path test got unexpected content back (served an old/wrong file?)." -Level ERROR
            return $false
        }
        return $true
    }
    catch {
        Write-Log "Live challenge-path test failed: $($_.Exception.Message)" -Level ERROR
        return $false
    }
    finally {
        Remove-Item $canaryPath -Force -ErrorAction SilentlyContinue
    }
}
#endregion

#region ===================== MAIN =====================
try {
    Write-Log "=== Destiny cert renewal run started (Staging=$($Staging.IsPresent) Force=$($Force.IsPresent) ReportOnly=$($ReportOnly.IsPresent) TestAlert=$($TestAlert.IsPresent)) ==="

    if ($TestAlert) {
        $subject = "[TEST] Destiny cert renewal alert channel test"
        $body = "This is a test alert from Renew-DestinyCert.ps1 on $env:COMPUTERNAME, sent $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by $env:USERDOMAIN\$env:USERNAME.`n`nIf you received this, this channel is configured correctly."

        # Deliberately bypasses the AlertViaEmail/AlertViaGoogleChat toggles
        # -- this is for testing a channel's configuration directly,
        # independent of whether it's currently enabled for real alerts.
        if ($TestChannel -in @('Email', 'Both')) {
            Write-Log "Sending test email..."
            Send-AlertEmail -Subject $subject -Body $body
        }
        if ($TestChannel -in @('GoogleChat', 'Both')) {
            Write-Log "Sending test Google Chat message..."
            Send-GoogleChatAlert -Subject $subject -Body $body
        }
        Write-Log "Test alert(s) attempted for channel(s): $TestChannel -- check the log lines above for per-channel success/failure."
        return
    }

    Import-Module Posh-ACME -ErrorAction Stop

    # Set-PAServer must run before ANY other Posh-ACME cmdlet, including
    # read-only ones like Get-PACertificate used by -ReportOnly -- it's
    # what tells Posh-ACME which server's local config/order state to look
    # at. Belongs above the ReportOnly branch, not after it.
    Set-PAServer $(if ($Staging) { 'LE_STAGE' } else { 'LE_PROD' })

    # An ACME account is a prerequisite for ANY account-scoped Posh-ACME
    # cmdlet for this server context -- including read-only ones like
    # Get-PACertificate used by -ReportOnly. Registering is idempotent and
    # side-effect-free (just contact info + ToS acceptance, no domain
    # validation), so it's safe to ensure unconditionally, before the
    # ReportOnly branch, rather than only inside the real-renewal path.
    if (-not (Get-PAAccount)) {
        Write-Log "No ACME account found for this server -- registering one now."
        New-PAAccount -Contact $Config.ContactEmail -AcceptTOS | Out-Null
    }

    if ($ReportOnly) {
        $existing = Get-PACertificate -MainDomain $Config.Domain
        if ($existing) {
            $daysLeft = ($existing.NotAfter - (Get-Date)).Days
            Write-Log "Current cert for $($Config.Domain) expires $($existing.NotAfter) ($daysLeft days left)."
            Add-ReportRow -Status 'REPORT' -Detail "Report-only check, $daysLeft days left" -NotAfter $existing.NotAfter
        }
        else {
            Write-Log "No existing Posh-ACME cert found for $($Config.Domain)." -Level WARN
        }
        return
    }

    # --- Pre-flight: confirm the ACME HTTP-01 challenge path still works ---
    # before attempting a renewal. A Destiny/WildFly update can silently
    # revert the destiny.xml edit that makes this whole approach work.
    Write-Log "Pre-flight: checking destiny.xml still has the well-known-handler config..."
    if (-not (Test-WellKnownConfig -XmlPath $Config.DestinyXmlPath)) {
        throw "PRECHECK FAILED: destiny.xml no longer contains the well-known-handler/.well-known config -- likely reverted by a Destiny/WildFly update. Aborting before attempting renewal (avoids burning Let's Encrypt failed-validation rate limits). Re-apply the destiny.xml edit and restart the service, then re-run."
    }

    Write-Log "Pre-flight: round-tripping a canary file through the live challenge path..."
    if (-not (Test-ChallengeWebroot -Config $Config)) {
        throw "PRECHECK FAILED: destiny.xml config looks intact, but a live test file placed in $($Config.WebRootPath)\.well-known\acme-challenge\ was not served correctly (service may need a restart, or folder permissions changed). Aborting before attempting renewal."
    }
    Write-Log "Pre-flight checks passed."

    $pfxPass = Get-SecureValue -Path $Config.PfxPassFile -FriendlyName 'PFX export password'

    $pluginArgs = @{
        WRPath = $Config.WebRootPath   # WRExactPath omitted -> plugin appends \.well-known\acme-challenge
    }

    Write-Log "Requesting/renewing certificate for $($Config.Domain) via HTTP-01 (WebRoot)..."
    $certParams = @{
        Domain    = $Config.Domain
        Contact   = $Config.ContactEmail
        Plugin    = 'WebRoot'
        PluginArgs = $pluginArgs
        PfxPassSecure = $pfxPass
        AcceptTOS = $true
        Install   = $false   # we handle deployment ourselves (JKS, not Windows cert store)
    }
    if ($Force) { $certParams.Force = $true }

    $cert = New-PACertificate @certParams

    if (-not $cert) {
        # No object returned but no exception either usually means "not yet due for renewal"
        $cert = Get-PACertificate -MainDomain $Config.Domain
        Write-Log "No renewal was necessary. Current cert expires $($cert.NotAfter)."
        Add-ReportRow -Status 'SKIPPED' -Detail 'Not within renewal window' -NotAfter $cert.NotAfter
        return
    }

    Write-Log "Certificate obtained. NotAfter=$($cert.NotAfter). PfxFile=$($cert.PfxFullChain)"

    # --- Convert PFX (with full chain) to JKS ---
    $tempJks = Join-Path $Config.WorkDir "destiny-$RunStamp.jks"
    if (Test-Path $tempJks) { Remove-Item $tempJks -Force }

    $pfxPassPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pfxPass))
    $ksPass = Get-SecureValue -Path $Config.KeystorePassFile -FriendlyName 'Java keystore password'
    $ksPassPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ksPass))

    try {
        Write-Log "Converting PFX to JKS via keytool..."

        # keytool writes routine progress text to STDERR even on success
        # (e.g. "Importing keystore X to Y..."). With $ErrorActionPreference
        # = 'Stop' (set globally above), merging that via 2>&1 would make
        # PowerShell treat each stderr line as a terminating ErrorRecord --
        # throwing on the very first line regardless of the actual exit
        # code. Temporarily relax to 'Continue' for these native calls and
        # rely on $LASTEXITCODE, which is the real signal, exactly like the
        # existing checks below already assume.
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'

        & $Config.KeytoolPath -importkeystore `
            -srckeystore $cert.PfxFullChain -srcstoretype PKCS12 -srcstorepass $pfxPassPlain `
            -destkeystore $tempJks -deststoretype JKS -deststorepass $ksPassPlain -destkeypass $ksPassPlain `
            -noprompt 2>&1 | ForEach-Object { Write-Log "keytool: $_" }

        if ($LASTEXITCODE -ne 0) { throw "keytool importkeystore exited with code $LASTEXITCODE" }

        # keytool imports the PFX's own alias (often "1" or the cert's friendly name).
        # Rename it to the alias Destiny expects.
        $listOutput = & $Config.KeytoolPath -list -keystore $tempJks -storepass $ksPassPlain 2>&1
        $currentAlias = ($listOutput | Select-String -Pattern '^(\S+),.*PrivateKeyEntry').Matches |
            ForEach-Object { $_.Groups[1].Value } | Select-Object -First 1

        if ($currentAlias -and $currentAlias -ne $Config.KeystoreAlias) {
            & $Config.KeytoolPath -changealias -keystore $tempJks -storepass $ksPassPlain `
                -alias $currentAlias -destalias $Config.KeystoreAlias 2>&1 |
                ForEach-Object { Write-Log "keytool: $_" }
            if ($LASTEXITCODE -ne 0) { throw "keytool changealias exited with code $LASTEXITCODE" }
        }
    }
    finally {
        $ErrorActionPreference = $prevEAP
        # Don't linger with plaintext passwords in memory longer than necessary
        Remove-Variable pfxPassPlain, ksPassPlain -ErrorAction SilentlyContinue
    }

    # --- Backup existing keystore, then deploy ---
    if (Test-Path $Config.KeystorePath) {
        $backupPath = Join-Path $Config.BackupDir "destiny.keystore.$RunStamp.bak"
        Copy-Item -Path $Config.KeystorePath -Destination $backupPath -Force
        Write-Log "Backed up existing keystore to $backupPath"
    }
    else {
        Write-Log "No existing keystore found at $($Config.KeystorePath) -- this looks like a first-time deployment." -Level WARN
    }

    Copy-Item -Path $tempJks -Destination $Config.KeystorePath -Force
    Write-Log "Deployed new keystore to $($Config.KeystorePath)"
    Remove-Item $tempJks -Force -ErrorAction SilentlyContinue

    # --- Restart Destiny ---
    Write-Log "Restarting service $($Config.ServiceName)..."
    Restart-Service -Name $Config.ServiceName -Force

    # The Windows Service wrapper typically reports "Running" almost as
    # soon as the process starts -- well before WildFly finishes actually
    # deploying Destiny and binding port 443. A short bounded retry here
    # (not the slow part) just guards against catching it mid-transition.
    $svcDeadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Seconds 5
        $svc = Get-Service -Name $Config.ServiceName
    } while ($svc.Status -ne 'Running' -and (Get-Date) -lt $svcDeadline)
    if ($svc.Status -ne 'Running') {
        throw "Service $($Config.ServiceName) did not return to Running state (currently: $($svc.Status))."
    }
    Write-Log "Service is running."

    # --- Verify the new cert is actually being served ---
    # This is the slow part: Destiny/WildFly can take a few minutes to
    # finish deploying and start actually listening on 443, well after
    # the service itself reports Running. Poll instead of a single fixed
    # sleep, so this is fast on a quick restart and still patient on a
    # slow one, without stretching every successful run out to the worst
    # case. Configurable via TlsVerifyTimeoutMinutes/TlsVerifyIntervalSeconds.
    $tlsDeadline = (Get-Date).AddMinutes($Config.TlsVerifyTimeoutMinutes)
    $verified = $false
    $attempt = 0
    do {
        $attempt++
        Start-Sleep -Seconds $Config.TlsVerifyIntervalSeconds
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient($Config.Domain, 443)
            $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false, { $true })
            $sslStream.AuthenticateAsClient($Config.Domain)
            $servedCert = $sslStream.RemoteCertificate
            $servedExpiry = [datetime]$servedCert.GetExpirationDateString()
            Write-Log "Verified: $($Config.Domain):443 is now serving a cert expiring $servedExpiry (attempt $attempt)"
            $sslStream.Close(); $tcpClient.Close()
            $verified = $true
        }
        catch {
            Write-Log "TLS check attempt $attempt not ready yet ($($_.Exception.Message))" -Level WARN
        }
    } while (-not $verified -and (Get-Date) -lt $tlsDeadline)

    if (-not $verified) {
        Write-Log "Could not verify served certificate over TLS within $($Config.TlsVerifyTimeoutMinutes) minutes (non-fatal)." -Level WARN
    }

    Add-ReportRow -Status 'SUCCESS' -Detail 'Renewed, converted, deployed, service restarted' -NotAfter $cert.NotAfter
    Send-Alert -Subject "[OK] Destiny cert renewed on $($Config.Domain)" `
        -Body "Renewal succeeded.`nNew expiry: $($cert.NotAfter)`nLog: $LogFile"

    Write-Log "=== Run completed successfully ==="
}
catch {
    Write-Log "RENEWAL FAILED: $($_.Exception.Message)" -Level ERROR
    Write-Log ($_.ScriptStackTrace) -Level ERROR
    Add-ReportRow -Status 'FAILURE' -Detail $_.Exception.Message -NotAfter $null
    Send-Alert -Subject "[FAILED] Destiny cert renewal on $($Config.Domain)" `
        -Body "Renewal FAILED.`n`nError: $($_.Exception.Message)`n`nSee log for details: $LogFile"
    exit 1
}
#endregion
