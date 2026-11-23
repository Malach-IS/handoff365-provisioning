# Handoff 365 — MIS-DataCenter provisioning

PowerShell script that provisions the MIS-DataCenter site for
**Handoff 365** in your own Microsoft 365 tenant.

MIS-DataCenter is a SharePoint Communication Site in **your** tenant. It holds
the audit trail, the record of active handoffs and the product configuration.
Files exchanged through Handoff 365 never go there — they stay in the document
libraries you enable.

The paid editions of Handoff 365 need it. Handoff 365 Free does not.

---

## Before you start

Read the full setup guide first. This repository holds the script; the guide
explains the steps around it, including the ones this script does not perform.

**https://www.malachis.eu/en-US/setup/handoff365-datacenter**

You will need:

- a SharePoint Communication Site, which you create yourself
- a licensed shared mailbox for sending one-time passcodes
- `PnP.PowerShell`
- permission to create lists on that site

---

## Quick start

```powershell
Install-Module PnP.PowerShell -Scope CurrentUser

# dry run — shows what would be created, changes nothing
.\provision-handoff.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/MIS-DataCenter" -WhatIf

# provision
.\provision-handoff.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/MIS-DataCenter"
```

The script is idempotent — running it again is safe and only fills in what is
missing.

---

## What the script does

Creates the MIS core lists (`MIS_Config`, `MIS_SchemaVersion`) and three
Handoff 365 lists, grants the Handoff 365 service access to those lists, sets
list permissions and versioning, and seeds the configuration list with
defaults. If the account running the script cannot grant that access, the
script warns and continues; Malach IS support can complete it remotely.

It does **not**:

- create the Communication Site — you do that first
- set `MailFrom` — that is your mailbox, you fill it in afterwards
- register your tenant with the Handoff 365 licensing service — that step is
  performed by Malach IS, see the setup guide

---

## Verifying the download

Each release includes a `SHA256` file.

```powershell
Get-FileHash .\provision-handoff.ps1 -Algorithm SHA256
```

Compare the result with the published hash before running the script.

---

## Versions

Releases are tagged with the schema version the script provisions, for example
`v1.4.6`. The setup guide references a specific release rather than the latest
commit, so that the instructions match the script they describe.

See [CHANGELOG.md](CHANGELOG.md).

---

## Support

**support@malachis.eu** — response within one business day.

An onboarding session of up to 30 minutes is included with every Handoff 365
subscription and trial, and can be booked at any time:
https://bookings.cloud.microsoft/book/BKG-MalachISOnboarding@malachis.eu/

If you would rather not run the script yourself, Malach IS can perform the
provisioning remotely. The setup guide describes both paths; neither costs
extra.

---

## Licence

See [LICENSE](LICENSE). The script may be downloaded and run to deploy
Handoff 365 in your own tenant. It may not be redistributed or modified.

© Malach IS s.r.o.
