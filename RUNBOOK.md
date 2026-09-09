# Destiny Cert Renewal — Go-Live Runbook

Follow in order. Each phase has a verification gate — don't move to the
next phase until the current one's checks pass.

## Phase 0 — Before you start

- [ ] Completed the prerequisite `destiny.xml` edit in `README.md` and
      confirmed the challenge path works over plain HTTP, from outside
      your network
- [ ] All 4 `.ps1` files are copied to `..\Scripts\DestinyCertRenew\`:
      `Renew-DestinyCert.ps1`, `Save-Secret.ps1`,
      `Grant-DestinyCertAccountPermissions.ps1`, and
      `Register-ScheduledTask.ps1`
- [ ] All scripts have been edited to remove the placeholder folder (`..\`)
      with the actual folder paths of the target server.
- [ ] Service account (eg `svc-destiny-cert`) created with a strong random password
- [ ] You're logged in as an actual admin on the Destiny server
- [ ] Pick a low-traffic window for **Phase 8** specifically — it swaps
      the live keystore and restarts Destiny for real, briefly serving an
      untrusted cert until Phase 9.

## Phase 1 — Install Posh-ACME machine-wide (as admin)

```powershell
# As Admin
Install-Module -Name Posh-ACME -Scope AllUsers -Force
Import-Module Posh-ACME
Get-Module Posh-ACME -ListAvailable
```

**Scope matters**: `AllUsers`, not `CurrentUser` — the service account
needs to load this module too, and a `CurrentUser`-scoped install would
only be visible to your own admin login.

**Gate**: `Get-Module` shows a version installed.

## Phase 2 — Grant the service account its permissions (as admin)

```powershell
# As Admin
cd ..\Scripts\DestinyCertRenew
.\Grant-DestinyCertAccountPermissions.ps1 -AccountName 'YOURDOMAIN\svc-destiny-cert'
```

Leave off `-DenyInteractiveLogon` for now — you'll need this account to
log on interactively for testing in Phase 5. Add that hardening in
Phase 11, once everything's confirmed working through the scheduled
task instead. This option may not work in an AD environment, you'll set this
via a GPO instead.

**Gate** — verify each grant landed:

```powershell
# As Admin
sc.exe sdshow FollettDestinyService
# Look for an (A;;CCLCSWRPWPDTLOCRRC;;;S-1-5-21-...) entry -- confirm
# it does NOT include DC (SERVICE_CHANGE_CONFIG).

icacls ..\FSC-Cert
icacls ..\FSC-Destiny\wildfly\.well-known
icacls ..\Scripts\DestinyCertRenew
# Confirm YOURDOMAIN\svc-destiny-cert appears with (M) on each.
```

Note the SDDL backup path the script prints — keep it until you're
confident everything works.

## Phase 3 — Confirm the real keystore password (as admin, read-only)

```powershell
# As Admin
& '..\FSC-Destiny\java\bin\keytool.exe' -list -keystore '..\FSC-Cert\destiny.keystore' -storepass '<password>'
```

- **Lists an entry** → that's the confirmed real <password> (matches
  `destiny.xml`'s `credential-reference`); note the alias shown too.
- **"password was incorrect"** → stop here. Get the actual password from
  wherever it's documented before continuing — don't guess in Phase 5.

`-list` is read-only; this can't affect the running service either way.

NOTE: The storepass is also in the `destiny.xml` file, in plain text. If you choose 
to change this password, make sure you update the `destiny.xml` file as well (it will
take effect after the destiny service has been restarted).

## Phase 4 — Confirm the CONFIRM values in Renew-DestinyCert.ps1 (as admin)

Open the script and check each config line against your environment:

```powershell
# As Admin
Get-Service *destiny*, *wildfly*   # confirms ServiceName
Get-ChildItem ..\Follett -Recurse -Filter keytool.exe   # confirms KeytoolPath
```

Also set `ContactEmail`, `SmtpServer`, and `MailTo` to real values if you
haven't already. `KeystorePath`/`KeystoreAlias`/`WebRootPath`/
`DestinyXmlPath` should already be correct from earlier confirmation.

**Gate**: no `..\` or `../` exist in any of the scripts.

## Phase 5 — Log on as the service account, save secrets

From your admin session:

```powershell
runas /user:YOURDOMAIN\svc-destiny-cert powershell
```

If that fails with *"the user has not been granted the requested logon
type"*, this account doesn't have local interactive logon rights on your Destiny server
(common under a hardened GPO).

How to allow this account interactive logon will depend on your
environment. In and AD environment this will most likely mean editing a GPO and
forcing and update via `gpupdate.` For a single unbound server, the `secpol.msc` 
will be were you'd set this policy for this user.

To temporarily grant it on a stand alone server:
* Run `secpol.msc` → Local Policies → User Rights Assignment → **Log on
locally** → add the account
* Retry the `runas` command 

**Remove this right** after Phase 8 — ongoing operation only needs the batch-logon right
already granted in Phase 2, not interactive.

**In the new window (now running as svc-destiny-cert):**

```powershell
# As Service Account
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd ..\Scripts\DestinyCertRenew
.\Save-Secret.ps1 -SecretName PfxPass
.\Save-Secret.ps1 -SecretName KeystorePass    # the password confirmed in Phase 3
.\Save-Secret.ps1 -SecretName SmtpCred        # only if your relay needs auth
```

**Gate**: `dir ..\Scripts\DestinyCertRenew\secrets\` shows the `.xml`
files you just saved.

## Phase 6 — Smoke test: report-only (still as service account)

```powershell
# As Service Account
.\Renew-DestinyCert.ps1 -ReportOnly -Verbose
```

This just confirms Posh-ACME loads and the script runs cleanly under
this account's permissions — no ACME calls, no file changes. First run
will log "no existing Posh-ACME cert found," which is expected.

**Gate**: exits cleanly, no errors, no Access Denied.

## Phase 7 — Prove the pre-flight alert path actually fires (as admin, then service account)

The PRECHECK logic has never actually fired — worth confirming the alert
path works *before* you're relying on it to catch a real Destiny update
reverting your XML edit.

**Note on method**: don't just rename away the `acme-challenge` folder
and expect this to fail — `Test-ChallengeWebroot` calls `New-Item -Force`
on that path if it's missing, so it would silently recreate the folder
and the check would pass right through, proving nothing. Instead, break
something the script *can't* self-heal

# Break Test 1: Stop the Destiny service manually.

```powershell
# As Admin
Stop-Service -Name Destiny
```

Then, as the service account:

```powershell
# As Service Account
.\Renew-DestinyCert.ps1 -Staging -Force -Verbose
```

Then restore immediately:

```powershell
# As Admin
Start-Service -Name Destiny
Get-Service -Name Destiny   # confirm Running before continuing
```

# Break Test 2: Rename the `destiny.xml` file

**Prove the config-drift check itself fires** (the
`destiny.xml`-content check, as distinct from the live-serving check
above). This renames the file itself rather than editing its contents,
so there's nothing to get wrong restoring it:

```powershell
# As admin
Rename-Item ..\FSC-Destiny\wildfly\standalone\configuration\destiny.xml destiny.xml.bak
```

```powershell
# As the service account
.\Renew-DestinyCert.ps1 -Staging -Force -Verbose
# Expect PRECHECK FAILED here too -- this time from the config check,
# since Test-WellKnownConfig can't find the file at all.
```

Restore immediately, then confirm Destiny is still fine
(it wasn't restarted by any of this, so it shouldn't need anything,
but worth a sanity browse to https://destiny.yourdistrict.org anyway).

```powershell
# As admin
Rename-Item ..\FSC-Destiny\wildfly\standalone\configuration\destiny.xml.bak destiny.xml
```

**Gate**, confirm all three:
- Log shows `PRECHECK FAILED` (from the live challenge-path check, since
  `destiny.xml` itself is untouched and its config check will still pass)
- `Logs\renewal-history.csv` has a `FAILURE` row
- Failure alert actually arrived on whichever channel(s) you have
  enabled — if you're testing with `AlertViaEmail` still on and the SMTP
  relay isn't sorted yet, expect that specific delivery to fail
  separately; that's the known SMTP issue, not a sign this test failed.
  `-TestAlert -TestChannel GoogleChat` (see README) is a cleaner way to
  confirm the alert transport itself if you'd rather isolate that from
  this test.


## Phase 8 — Staging dry run (real end-to-end test) ⚠️ maintenance window

This will both restart the Destiny server service, but it will also replace
your production certificate with a LE staging certificate (it backs up the
prod cert first). You can restore the prod cert by overwriting the staged cert
file and restarting the Destiny service again.

```powershell
# As Service Account
.\Renew-DestinyCert.ps1 -Staging -Force -Verbose
```

Tail the log live in another window:

```powershell
# As Admin
Get-Content (Get-ChildItem ..\Scripts\DestinyCertRenew\Logs\renew-*.log |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName -Wait
```

Browse to `https://destiny.yourdistrict.org` — a certificate warning here is
**expected** (staging certs aren't publicly trusted) — that's not a bug.

**Gate** — confirm, in order:
- [ ] Pre-flight checks passed
- [ ] Authorization went `valid` via HTTP-01/WebRoot
- [ ] `keytool` conversion + alias rename succeeded
- [ ] Old keystore backed up under `Backups\`
- [ ] New keystore copied to `..\FSC-Cert\destiny.keystore`
- [ ] Service restarted, back to `Running`
- [ ] TLS verify step logged the new expiry
- [ ] Success email received
- [ ] CSV row shows `SUCCESS`
- [ ] The Destiny website is up and has the staging cert applied to it

## Phase 9 — Go live

```powershell
# As Service Account
.\Renew-DestinyCert.ps1 -Force -Verbose
```

(No `-Staging`.) Same checklist as Phase 8. Then browse to
`https://destiny.yourdistrict.org` and confirm a trusted padlock with a real
Let's Encrypt issuer in the certificate details.

## Phase 10 — Schedule it

```powershell
#As Admin
.\Register-ScheduledTask.ps1 -ServiceAccount 'YOURDOMAIN\svc-destiny-cert'
```

Then test the actual scheduled-task execution path — this uses batch
logon, a different code path than your manual `runas` testing:

```powershell
# As Admin
Start-ScheduledTask -TaskName 'Destiny Certificate Renewal'
Start-Sleep -Seconds 20
Get-ScheduledTaskInfo -TaskName 'Destiny Certificate Renewal'
```
You can also go into the `Task Scheduler` app and look for `Destiny Certificate Renewal` 
in the root of the library. From there you can check the task history to confirm that it ran
as expected. If you see an error her, chances are you need to grant the `Batch Logon` privilege
to your service account.

Check the newest log file. **Expect a `SKIPPED` result** — the cert was
just renewed in Phase 9, so it's not due again. Seeing `SKIPPED` here
confirms both that batch-logon execution works *and* that Posh-ACME's
idempotency will keep the biweekly schedule from doing anything until
renewal is actually due.

## Phase 11 — Final hardening (optional, now safe)

Now that everything's proven working through the scheduled task alone:

For a stand alone server:

```powershell
# As Admin
.\Grant-DestinyCertAccountPermissions.ps1 -AccountName 'YOURDOMAIN\svc-destiny-cert' -DenyInteractiveLogon
```

(Safe to re-run — it skips rights already granted and just adds the two
deny rights.) If you temporarily granted "Log on locally" in Phase 5,
remove that too via `secpol.msc` — it isn't touched by this script. Or if you used
an AD GPO, you can undo the permission there and force another GPO update via `gpupdate`

## Ongoing

- Runs every 2 weeks (Mondays, 3:15 AM by default); no-ops until ~30 days
  before expiry — every run, including no-ops, gets its own log file and
  a row in `renewal-history.csv` (status `SKIPPED`). Only
  `SUCCESS`/`FAILURE` trigger an alert on your enabled channel(s) — a
  `SKIPPED` run is the expected boring case and stays silent there by
  design; check the log or CSV if you want to confirm it actually ran.
- `.\Renew-DestinyCert.ps1 -ReportOnly` any time for a status check with
  zero side effects
- History: `..\Scripts\DestinyCertRenew\Logs\renewal-history.csv`
- A `PRECHECK FAILED` alert after any Destiny/Follett update is your
  signal the `.well-known` handler in `destiny.xml` got reverted —
  re-apply the edit and restart the service.
