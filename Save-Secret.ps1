<#
.SYNOPSIS
    One-time helper to save secrets used by Renew-DestinyCert.ps1, protected
    with Windows DPAPI (Export-Clixml on a SecureString).

.DESCRIPTION
    DPAPI-protected files can only be decrypted by the same Windows user
    account, on the same machine, that created them. Run this script
    logged in AS (or via "Run as") the exact account that will run the
    scheduled task -- typically a dedicated low-privilege service account
    (see Grant-DestinyCertAccountPermissions.ps1), not your own admin
    login -- or the scheduled renewal will fail to read the secrets.

    Only needs write access to ..\Scripts\DestinyCertRenew\secrets, which
    the service account already has -- no admin rights required.

.EXAMPLE
    .\Save-Secret.ps1 -SecretName PfxPass
    .\Save-Secret.ps1 -SecretName KeystorePass
    .\Save-Secret.ps1 -SecretName SmtpCred
    .\Save-Secret.ps1 -SecretName GoogleChatWebhook
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('PfxPass', 'KeystorePass', 'SmtpCred', 'GoogleChatWebhook')]
    [string]$SecretName
)

$secretDir = '..\Scripts\DestinyCertRenew\secrets'    # Needs to be replaced with real folder, not the place holder.
if (-not (Test-Path $secretDir)) { New-Item -ItemType Directory -Path $secretDir -Force | Out-Null }

switch ($SecretName) {
    'PfxPass' {
        $val = Read-Host -Prompt 'Enter a password Posh-ACME should use to export the PFX' -AsSecureString
        $val | Export-Clixml -Path (Join-Path $secretDir 'pfx-pass.xml')
    }
    'KeystorePass' {
        $val = Read-Host -Prompt 'Enter the EXISTING Java Keystore password used by Destiny' -AsSecureString
        $val | Export-Clixml -Path (Join-Path $secretDir 'keystore-pass.xml')
    }
    'SmtpCred' {
        $cred = Get-Credential -Message 'Enter SMTP credentials (leave blank/cancel if your relay allows anonymous internal relay)'
        $cred | Export-Clixml -Path (Join-Path $secretDir 'smtp-cred.xml')
    }
    'GoogleChatWebhook' {
        # From the target Space: Apps & integrations > Webhooks > Add webhook > copy URL.
        # Treat this URL as a credential -- anyone holding it can post into that Space.
        $val = Read-Host -Prompt 'Enter the Google Chat incoming webhook URL' -AsSecureString
        $val | Export-Clixml -Path (Join-Path $secretDir 'googlechat-webhook.xml')
    }
}

Write-Host "Saved. This file is only readable by $(whoami) on this machine." -ForegroundColor Green
