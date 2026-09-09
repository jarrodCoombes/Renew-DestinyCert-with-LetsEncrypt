# Destiny Let's Encrypt Auto-Renewal

Automates Let's Encrypt certificate renewal for [Follett Destiny](https://www.follettsoftware.com/products/destiny-library-manager/)
running on WildFly/JBoss on Windows: requests/renews via
[Posh-ACME](https://github.com/rmbolger/Posh-ACME), converts the result to
a Java Keystore, deploys it into Destiny's `FSC-Cert` folder, restarts the
service, and alerts you (email and/or Google Chat) on success or failure.
No DNS server changes, no separate listener process — the HTTP-01
challenge is served directly by WildFly itself.

**Who this is for**: anyone running Destiny on-prem on Windows who's tired
of Destiny's certificate expiring and wants free, automated renewal
instead of a paid cert and a calendar reminder.

**A Note of Paths used in this Repo:** Whenever you see a path starting with ..\ then it 
is a place holder, and you will need to replace it with the actual path in your prod environment. 
Wherever possible I have tried to use at least part of the typical path Destiny uses.

**Files:**
- `Renew-DestinyCert.ps1` — the renewal/convert/deploy/restart/alert script
- `Save-Secret.ps1` — one-time helper to store secrets (DPAPI-protected)
- `Grant-DestinyCertAccountPermissions.ps1` — one-time setup granting the
  service account minimal rights (no local admin)
- `Register-ScheduledTask.ps1` — sets up the biweekly scheduled task
- `RUNBOOK.md` — a phase-by-phase go-live checklist with test gates
  between each step

## Prerequisite: get WildFly serving `/.well-known` from disk

Destiny's default `destiny.xml` doesn't serve anything at
`/.well-known/acme-challenge/`, which is where Let's Encrypt's HTTP-01
validator looks. You need to add a handler for it once, by hand, before
any of this works.

In `destiny.xml` (typically
`..\FSC-Destiny\wildfly\standalone\configuration\destiny.xml`),
find the `<host name="default-host">` block and add a `<location>` line,
and find the `<handlers>` block and add a matching `<file>` handler:

```xml
<host name="default-host" alias="localhost">
    <location name="/" handler="welcome-content"/>
    <location name="/.well-known" handler="well-known-handler"/>   <!-- add this line -->
    ...
</host>
```

```xml
<handlers>
    <file name="welcome-content" path="${jboss.home.dir}/welcome-content-custom"/>
    <file name="well-known-handler" path="${jboss.home.dir}/.well-known" directory-listing="false"/>   <!-- add this line -->
</handlers>
```
**NOTE** The path variable uses the Linux / rather than the Windows \, 
using the wrong slash won't break anything, it just won't server up the folder via the web.

Restart the Destiny service after editing, then confirm it worked before
going any further — drop a test file in the folder this now maps to
(`<jboss.home.dir>\.well-known\test.txt`) and confirm you can fetch it
over plain HTTP, both from the server itself and from outside your
network (a mobile hotspot works, or `curl --resolve` against your public
IP directly):

```powershell
curl -Iv http://destiny.yourdistrict.org/.well-known/test.txt
```

You should get a direct `200 OK`, not a redirect — `.well-known` isn't
subject to Destiny's default HTTPS-redirect behavior, since that only
applies to locations under a `CONFIDENTIAL` transport-guarantee
constraint. If you get anything else, don't move on until this part
works — everything downstream depends on it, and a broken challenge path
is the single most common reason this will fail.

## Why this approach

Why not just put Destiny behind a reverse proxy? While this would probably work, it is an
unsupported setup and Follett support will most likely insist on a direct connection in order to
troubleshoot or fix things. This method requires a neglible change to the Destiny install itself,
leaving the bulk of the process at the OS level.

Posh-ACME's built-in `WebRoot` plugin does nothing more than write a file
to that path and delete it after — no DNS API, no TSIG key, no
credentials beyond what's already on the filesystem.

Some thing worth keeping in mind long-term: 
* This all depends on port 80 staying forwarded to this server from the internet, even 
  though nothing else here needs it. If that forwarding ever gets "cleaned up" later (reasoning 
  "we only need 443, right?"), renewals will silently start failing at the next attempt.
* Editing the XML file is risky, but also fragile as there is no guarantee that Follett 
  will respect your changes in upcoming updates. So make a backup of the original file as 
  well as your edited one.

## 1. Confirm the webroot path

Filesystem path serving `/.well-known/acme-challenge/`:
`<jboss.home.dir>\.well-known\acme-challenge` (typically
`..\FSC-Destiny\wildfly\.well-known\acme-challenge`).
`WebRootPath` in `Renew-DestinyCert.ps1` should be set to its **parent**
(e.g. `..\FSC-Destiny\wildfly`), since the `WebRoot` plugin
appends `\.well-known\acme-challenge` itself by default.

## 2. Windows setup — one time

```powershell
# As Administrator
Install-Module -Name Posh-ACME -Scope AllUsers -Force
Import-Module Posh-ACME

New-Item -ItemType Directory -Path ..\Scripts\DestinyCertRenew -Force
New-Item -ItemType Directory -Path ..\Scripts\DestinyCertRenew\secrets -Force
```

Copy `Renew-DestinyCert.ps1` and `Save-Secret.ps1` into
`..\Scripts\DestinyCertRenew\`.

**Confirm and edit these values at the top of `Renew-DestinyCert.ps1`**
before running anything (marked `# CONFIRM` in the script):

| Setting | How to find it |
|---|---|
| `WebRootPath` | Step 1 above |
| `KeytoolPath` | `Get-ChildItem ... -Recurse -Filter keytool.exe` |
| `KeystorePath` | Confirmed from `destiny.xml`: `../FSC-Cert/destiny.keystore` |
| `KeystoreAlias` | `& $KeytoolPath -list -keystore <path> -storepass <pass>` — look for the `PrivateKeyEntry` alias |
| `ServiceName` | `Get-Service *destiny*, *wildfly*` |
| `SmtpServer` / `MailTo` | Your relay + who should get alerts |

Note on `destiny.xml`'s TLS config: it uses `credential-reference
clear-text="<password>"` for both the keystore-level and key-level password
under `applicationKS`/`applicationKM`. In a Java keystore these are two
separate values (`storepass` and `keypass`) — for the purposes of these 
scripts we will keep them the same. `Renew-DestinyCert.ps1` sets both from the one
value you save via `Save-Secret.ps1 -SecretName KeystorePass`, matching
that.

**Decide who runs this.** See the "Service account & minimal permissions"
section below — create a dedicated low-privilege account there before
continuing, rather than using your own admin login.

Log in **as that account** (or `runas.exe /user:<account> powershell`) and save secrets — this matters
because the secrets are DPAPI-protected to the exact account that saves
them:

```powershell
.\Save-Secret.ps1 -SecretName PfxPass        # any strong password Posh-ACME will use internally for the PFX
.\Save-Secret.ps1 -SecretName KeystorePass   # Destiny's EXISTING java keystore password (see note above)
.\Save-Secret.ps1 -SecretName SmtpCred       # only if your relay requires auth
.\Save-Secret.ps1 -SecretName GoogleChatWebhook   # only if using the Google Chat alert channel, see below
```

## Alert channels: email and/or Google Chat

Two independent channels, toggled separately in the `$Config` block:

```powershell
AlertViaEmail        = $true
AlertViaGoogleChat   = $false
```

Both, either one alone, or neither can be enabled. Both a success and a
failure alert (when they fire) go out through every channel currently
toggled on.

**Setting up Google Chat**: in the target Space, go to the Space name ▸
**Apps & integrations** ▸ **Webhooks** ▸ **Add a webhook**, name it
something like "Destiny Cert Renewal," and copy the generated URL. Save
it the same way as the other secrets:

```powershell
.\Save-Secret.ps1 -SecretName GoogleChatWebhook
```

Treat that URL as a credential — anyone holding it can post into that
Space, which is why it's stored the same DPAPI-protected way as the
passwords rather than sitting in the config in plain text.

### Testing a channel without running a renewal

`-TestAlert` sends a test message and exits immediately — no Posh-ACME,
no keystore, no pre-flight checks, no service restart, nothing else
touched. It also **ignores** the `AlertViaEmail`/`AlertViaGoogleChat`
toggles, so you can verify a channel works before deciding whether to
turn it on for real alerts:

```powershell
.\Renew-DestinyCert.ps1 -TestAlert -TestChannel Email
.\Renew-DestinyCert.ps1 -TestAlert -TestChannel GoogleChat
.\Renew-DestinyCert.ps1 -TestAlert                          # both (default)
```

Check the log for a per-channel success/failure line — a channel can
fail independently of the other, so `Both` will tell you exactly which
one has a problem if only one does.

## 3. Dry run against LE staging

Always test against the staging CA first — production LE has real rate
limits (5 failed validations/hour, 5 duplicate certs/week).

```powershell
.\Renew-DestinyCert.ps1 -Staging -Force -Verbose
```

Check the log in `..\Scripts\DestinyCertRenew\Logs\`. A staging cert isn't
trusted by browsers, so this will show a scary warning if you browse to
Destiny during the test — that's expected. Confirm:
- Posh-ACME's log shows the challenge file being written and the
  authorization going `valid`
- `keytool` converted and the alias matches
- The service restarted cleanly
- You got the success email

## 4. Go live

```powershell
.\Renew-DestinyCert.ps1 -Force -Verbose
```

This issues a real cert and deploys it. Browse to
`https://destiny.yourdistrict.org` and confirm the padlock shows a valid Let's
Encrypt certificate.

## Service account & minimal permissions

This is deliberately **not** run as local admin. The account that runs
the scheduled task gets exactly five things, nothing more:

| Resource | Access | Why |
|---|---|---|
| `..\Scripts\DestinyCertRenew\` | Modify | Its own working directory |
| `..\FSC-Cert\` | Modify | Overwrite `destiny.keystore` |
| `..\FSC-Destiny\wildfly\.well-known\` | Modify | Write the ACME challenge + pre-flight canary files |
| `destiny.xml` | Read only | Pre-flight config-drift check |
| `..\FSC-Destiny\java\` | Read + Execute | Run `keytool.exe` |
| The Destiny/WildFly service | Start + Stop only (not reconfigure) | `Restart-Service` |
| Logon type | "Log on as a batch job" only | Unattended scheduled task |

Explicitly **not** granted: local admin, Domain Admins, interactive
logon, RDP, `SERVICE_CHANGE_CONFIG` on the service (so it can't be used
to repoint the service at a different binary), or write access to
anything outside the five paths above.

### 1. Create the account

Local account (simplest, if you don't need it centrally managed via AD):

```powershell
# On your Destiny server, as admin
$pw = Read-Host -AsSecureString -Prompt 'Password for svc-destiny-cert'
New-LocalUser -Name 'svc-destiny-cert' -Password $pw `
    -FullName 'Destiny Cert Renewal Service Account' `
    -Description 'Automated LE cert renewal -- scheduled task only, do not use interactively' `
    -PasswordNeverExpires -UserMayNotChangePassword
```

Or a domain account (if you'd rather manage it via AD) — create it
however you normally provision service accounts, just don't add it to
any group beyond the default `Domain Users`.

Either way: **do not** add it to `Administrators`, `Domain Admins`, or
any other privileged group. It doesn't need to be, and that's the whole
point of the rest of this section.

### 2. Grant it exactly the rights above

```powershell
# On your Destiny server, as admin -- run once
.\Grant-DestinyCertAccountPermissions.ps1 -AccountName 'YOURDOMAIN\svc-destiny-cert'
# or, for a local account:
.\Grant-DestinyCertAccountPermissions.ps1 -AccountName '.\svc-destiny-cert'
```

Add `-DenyInteractiveLogon` if you want the extra hardening of explicitly
blocking this account from ever logging in interactively or over RDP —
recommended, since it means a leaked password is only useful for running
the scheduled task, nothing else.

This script backs up the Destiny service's current ACL to
`%TEMP%\<ServiceName>.sddl.backup.txt` before touching it, in case you
ever need to revert with `sc.exe sdset <name> "<saved SDDL>"`.

### 3. Verify

```powershell
# Confirm no group memberships beyond the defaults
Get-LocalGroupMember Administrators | Where-Object Name -like '*svc-destiny-cert*'
# (should return nothing)

# Confirm the service ACL now includes the account without SERVICE_CHANGE_CONFIG
sc.exe sdshow FollettDestinyService
```

Then log in **as** `svc-destiny-cert` (or `runas /user:YOURDOMAIN\svc-destiny-cert powershell`),
run `Save-Secret.ps1`, and do the staging dry run from that session — if
any permission is missing, it'll surface there rather than silently in
the middle of the night.

## 5. Schedule it

```powershell
.\Register-ScheduledTask.ps1 -ServiceAccount 'YOURDOMAIN\svc-destiny-cert'
```

Default: every 2 weeks, Mondays at 3:15 AM (`-WeeksInterval`/`-DayOfWeek`/
`-RunTime` are all overridable). Because `New-PACertificate` only renews
within its ~30-day-before-expiry window, most of these runs are cheap
no-ops (logged as `SKIPPED`) — a biweekly cadence still leaves 2+ check-in
opportunities before expiry even if one run fails for some reason, while
generating a fraction of the log files a daily trigger would.

## Pre-flight check (config-drift protection)

Since the `.well-known` handler in `destiny.xml` is a hand-edit on top of
Destiny's shipped config, a Destiny/WildFly update could overwrite the
file and silently drop it — you'd only find out when the cert actually
expired. Every run now checks this **before** touching Posh-ACME at all:

1. **Config check** — confirms `destiny.xml` still contains the
   `well-known-handler` entry and the `/.well-known` location mapping.
2. **Live check** — writes a random canary file into
   `..\wildfly\.well-known\acme-challenge\` and fetches it back over
   `http://localhost/...`. This catches things the config check alone
   would miss — e.g. the XML is fine but the service wasn't restarted
   after some other change, or the folder's permissions got reset.

If either fails, the script **aborts before calling Let's Encrypt at
all** (so a config regression doesn't burn failed-validation attempts
against LE's rate limits) and sends the same failure alert email as any
other failure, with the specific reason in the body and log. Fix is
usually: re-apply the `destiny.xml` edit, restart the service, re-run.

## Reporting

Every run appends a row to
`..\Scripts\DestinyCertRenew\Logs\renewal-history.csv` (`SUCCESS`,
`SKIPPED`, `FAILURE`, or `REPORT`, with expiry date). Open it in Excel, or
pull a quick status any time without renewing anything:

```powershell
.\Renew-DestinyCert.ps1 -ReportOnly
```

Email alerts fire automatically on any `FAILURE`, and (optionally) on
every `SUCCESS` — edit the `Send-AlertEmail` calls near the bottom of the
script if you'd rather only be notified on failure.

## Troubleshooting

- **"PRECHECK FAILED" in the alert email/log** — see the "Pre-flight
  check" section above; the message tells you whether it was the XML
  config or the live serve test that failed.
- **Challenge validation fails / "Invalid response"** — the pre-flight
  check should catch this before it gets this far, but if it doesn't:
  almost always either (a) port 80 isn't actually forwarded externally
  anymore, or (b) `WebRootPath` doesn't match `jboss.home.dir`. Re-confirm
  with the `--resolve` curl command above.
- **`keytool importkeystore` fails on alias** — run `keytool -list -v
  -keystore destiny.keystore` on the *old* keystore to see the alias
  Destiny's config actually expects, and adjust `KeystoreAlias` if it
  differs from `destiny`.
- **Service won't restart** — check WildFly's own logs
  (`..\FSC-Destiny\wildfly\standalone\log\destiny-server.log`) —
  usually a keystore password mismatch between what's in `destiny.xml`'s
  `credential-reference` and what you saved via `Save-Secret.ps1`.
- **Secrets file "cannot decrypt"** — the scheduled task is running as a
  different account than the one that ran `Save-Secret.ps1`. Re-run
  `Save-Secret.ps1` logged in as the actual task account.

## A security note on `destiny.xml`

Destiny's own default `destiny.xml` stores the SQL Server datasource
password in plaintext under `<security><password>`, and the keystore's
`credential-reference clear-text="..."` in the TLS section is also
plaintext by default. Neither is something this tooling touches, but if
you're pasting your own `destiny.xml` anywhere for troubleshooting (a
support ticket, an AI assistant, a chat with a colleague), redact those
values first — they're real, live credentials, not placeholders. WildFly's
Elytron credential-store (`elytron:add-secret`) is worth looking at if
you'd rather get these out of plaintext XML entirely. This repo's own
secrets (PFX/keystore passwords, SMTP creds, the Google Chat webhook URL)
never touch plaintext files or version control — see `Save-Secret.ps1`
and this repo's `.gitignore`.

## Tested against

Windows Server 2022, Destiny 23.5.0-RC5 running on WildFly/JBoss (the modern
Destiny stack — this won't apply to older Tomcat-based installs without
adaptation), Posh-ACME 4.34.0. Built and hardened through a real
production rollout, including the mistakes made along the way — see
`RUNBOOK.md` for the actual go-live process this was validated against.

If you hit something that doesn't match your install (different default
paths, a different Destiny version's `destiny.xml` structure, etc.),
issues and PRs are welcome.

## License

MIT — see `LICENSE`.
