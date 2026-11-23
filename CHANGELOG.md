# Changelog

Releases are tagged with the MIS-DataCenter schema version the script
provisions. The Handoff 365 setup guide references a specific release, so that
the instructions match the script they describe.

## v1.4.9

- `MIS_HandoffActivity.ActivityType` gains the choice `Exchange`, used by the
  Handoff 365 "Exchange" link (receive and share files in one link, Enterprise).
  On an existing site the script adds the choice to the current ones.

Upgrading: run the new script against your existing DataCenter site. It is
idempotent and adds only what is missing; no data is changed.

## v1.4.8

Includes the changes of schema 1.4.7, which was not released separately.

New in 1.4.8:

- `MIS_HandoffActivity` gains the column `PartnerCanClose`, and
  `MIS_HandoffEnabledLibraries` gains `SharePartnerCanClose` -- both Yes/No
  with no default. They store whether your partner may close a shared link
  ("Partner can close the link", Handoff 365 app package 1.15.0). An empty value
  keeps the previous behaviour.
- `MIS_HandoffEnabledLibraries`: the status choice `Requested` is now reliably
  added on existing sites (earlier versions reported it but did not add it).
- The `-WhatIf` dry run no longer changes that status column.

From 1.4.7:

- The script grants the Handoff 365 service access to its four lists on the
  DataCenter site itself (read `MIS_Config`, write the three Handoff lists). If
  the account running the script cannot grant it, the script warns and
  continues; Malach IS support can complete the grant remotely.
- The script no longer creates the shared master-data lists (`MIS_Customers`,
  `MIS_Suppliers`, `MIS_Contacts`, `MIS_CatalogItems`, `MIS_InvoicingDetails`,
  `MIS_Locations`, `MIS_Departments`) -- Handoff 365 does not use them. Existing
  lists are left untouched.
- The script no longer registers the site as a hub site.
- `-WhatIf` works on a brand-new site.

Upgrading: run the new script against your existing DataCenter site. It is
idempotent and adds only what is missing; no data is changed.

## v1.4.6

Initial public release.

Provisions:

- shared MIS core lists — `MIS_Config`, `MIS_SchemaVersion`, `MIS_Customers`,
  `MIS_Suppliers`, `MIS_Contacts`, `MIS_CatalogItems`, `MIS_InvoicingDetails`,
  `MIS_Locations`, `MIS_Departments`
- Handoff 365 lists — `MIS_HandoffAuditLog`, `MIS_HandoffActivity`,
  `MIS_HandoffEnabledLibraries`
- list permissions, versioning and configuration defaults

Requires PnP.PowerShell. Supports `-WhatIf` for a dry run. Idempotent —
running it again fills in only what is missing.
