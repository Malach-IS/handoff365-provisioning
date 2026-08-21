# Changelog

Releases are tagged with the MIS-DataCenter schema version the script
provisions. The Handoff 365 setup guide references a specific release, so that
the instructions match the script they describe.

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
