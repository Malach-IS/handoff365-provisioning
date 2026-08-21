# ============================================================================
#  GENERATED FILE -- DO NOT EDIT.
#  Built from scripts/products/provision-handoff.ps1 + scripts/core/_MISProvisionCore.ps1
#  by build/Build-ProvisionScripts.ps1. Edit the source, then re-run the build.
# ============================================================================
<#
.SYNOPSIS
    Provisions Handoff 365 on an MIS-DataCenter site (self-sufficient).

.DESCRIPTION
    Idempotent. Ensures the shared core (Hub, MIS_Config, MIS_SchemaVersion, master-data
    lists -- via Ensure-MISCoreLists), then creates the Handoff lists and seeds Handoff365
    config:
      - MIS_HandoffAuditLog          (append-only event log)
      - MIS_HandoffActivity          (active requests/shares + revoke state)
      - MIS_HandoffEnabledLibraries  (registry of Handoff-enabled libraries)
    Stamps the Handoff365 schema version.

    This stands up a Handoff-only DataCenter on a brand-new Communication site, or adds
    Handoff to an existing multi-product DataCenter. For the full suite, run each product
    script (or provision-all.ps1).

    All shared logic lives in scripts/core/_MISProvisionCore.ps1. Existing items are detected
    and left as-is; safe to re-run. -Force recreates the Handoff lists (deletes their data).

    After this: register-handoff-tenant.ps1, consent the runtime app, deploy the SPFx
    package, then grant-handoff-list-permissions.ps1.

.PARAMETER SiteUrl
    URL of the MIS-DataCenter site.

.PARAMETER Force
    Drop and recreate the Handoff lists. WARNING: deletes all data in those lists.

.PARAMETER SkipConfig
    Do not seed the Handoff365 MIS_Config entries (provision lists only).

.PARAMETER ClientId / TenantId / CertificateThumbprint / CertificatePath / CertificatePassword
    Auth parameters -- see the core Connect-MISDataCenter contract.

.EXAMPLE
    # Certificate app-only (remote customer tenant)
    .\provision-handoff.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/MIS-DataCenter" `
        -ClientId "7518f849-dbfa-4758-ae27-80929ed1082e" -TenantId "{tenant-id}" `
        -CertificateThumbprint "{thumbprint}"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SiteUrl,

    [switch]$Force,
    [switch]$SkipConfig,
    [switch]$SkipCore,   # skip Hub + Ensure-MISCoreLists (used by provision-all.ps1)

    [string]$ClientId,
    [string]$TenantId,
    [string]$CertificateThumbprint,
    [string]$CertificatePath,
    [SecureString]$CertificatePassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# >>> INLINE-CORE >>> (inlined by build -- DO NOT EDIT this block)
<#
.SYNOPSIS
    MIS-DataCenter shared provisioning core -- functions + per-product schema API.

.DESCRIPTION
    Single source of truth for the provisioning logic that was previously copy-pasted
    across provision-datacenter.ps1, provision-handoff.ps1, migrate-datacenter.ps1 and the
    auto-provision Azure Function. See docs/PROVISIONING-REFACTOR-PROPOSAL.md.

    This file is a LIBRARY of definitions. It contains no param block, no Set-StrictMode,
    and no top-level executable work (only function definitions and a cache init), so it is
    safe to dot-source or inline.

    HOST CONTRACT -- the script that consumes this core MUST provide:
      - [CmdletBinding(SupportsShouldProcess)] on the host script (these helpers call the
        host's $PSCmdlet.ShouldProcess; they intentionally have no ShouldProcess attribute
        of their own).
      - A param block exposing: $SiteUrl, $Force, $ClientId, $TenantId,
        $CertificateThumbprint, $CertificatePath, $CertificatePassword.
      - Set-StrictMode -Version Latest and $ErrorActionPreference = "Stop" (recommended).
      - An active PnP connection (call Connect-MISDataCenter first) before any list/schema
        function is used.

    CONSUMPTION:
      - Dev / source tree:   dot-source this file
            # >>> INLINE-CORE >>>
            . "$PSScriptRoot/../core/_MISProvisionCore.ps1"
            # <<< INLINE-CORE <<<
      - Distribution:        build/Build-ProvisionScripts.ps1 replaces the marker block with
                             this file's verbatim contents to emit a self-contained dist/ script.

    LOCALE: built-in permission levels are resolved by RoleTypeKind (Get-MISRoleName), never
    by hardcoded English names. See docs / the locale-independent provisioning rule.

    PHASE 1 (this file): shared functions + schema API only. The shared master-data LIST
    definitions (Ensure-MISCoreLists) arrive with provision-core.ps1 in Phase 3.
#>

# ============================================================================
#  Connection
# ============================================================================
# Supports three modes:
#   1. Certificate thumbprint:  -ClientId -TenantId -CertificateThumbprint
#   2. Certificate file (.pfx): -ClientId -TenantId -CertificatePath [-CertificatePassword]
#   3. Interactive (fallback):  -ClientId (optional, uses PnP default app)
# See docs/APP-REGISTRATION.md for setup instructions.

function Connect-MISDataCenter {
    param([string]$Url)

    if ($ClientId -and $TenantId -and $CertificateThumbprint) {
        Write-Host "[AUTH] Connecting with certificate thumbprint (app-only)..." -ForegroundColor Cyan
        Connect-PnPOnline -Url $Url -ClientId $ClientId -Tenant $TenantId -Thumbprint $CertificateThumbprint
    }
    elseif ($ClientId -and $TenantId -and $CertificatePath) {
        Write-Host "[AUTH] Connecting with certificate file (app-only)..." -ForegroundColor Cyan
        $params = @{
            Url             = $Url
            ClientId        = $ClientId
            Tenant          = $TenantId
            CertificatePath = $CertificatePath
        }
        if ($CertificatePassword) { $params['CertificatePassword'] = $CertificatePassword }
        Connect-PnPOnline @params
    }
    elseif ($ClientId) {
        Write-Host "[AUTH] Connecting interactively with ClientId..." -ForegroundColor Cyan
        Connect-PnPOnline -Url $Url -Interactive -ClientId $ClientId
    }
    else {
        # PnP PowerShell requires a ClientId on EVERY connection -- fail clearly instead of
        # attempting a ClientId-less connect. (The legacy monolith's bare -Interactive
        # fallback is an inherited bug we deliberately do not repeat. See the SharePoint
        # provisioning rules: Connect-PnPOnline always requires -ClientId.)
        throw "No -ClientId provided. Pass -ClientId for interactive, or -ClientId -TenantId with -CertificateThumbprint/-CertificatePath for app-only. See docs/APP-REGISTRATION.md."
    }
}

# ============================================================================
#  Locale-independent permission levels
# ============================================================================
# Resolve a built-in role-definition name by its locale-independent type so the scripts work
# on non-English tenants (Reader=Read, Contributor=Contribute, Editor=Edit,
# Administrator=Full Control). Hardcoding English names throws "Role definition '...' not
# found" on e.g. Czech/German sites. Cached per run.

$script:MISRoleCache = @{}
function Get-MISRoleName([string]$roleType) {
    if (-not $script:MISRoleCache.ContainsKey($roleType)) {
        $rd = Get-PnPRoleDefinition | Where-Object { $_.RoleTypeKind -eq $roleType } | Select-Object -First 1
        if (-not $rd) { throw "No built-in role definition of type '$roleType' on this site." }
        $script:MISRoleCache[$roleType] = $rd.Name
    }
    return $script:MISRoleCache[$roleType]
}

# ============================================================================
#  List / field primitives
# ============================================================================

function Test-ListExists {
    param([string]$ListName)
    try {
        Get-PnPList -Identity $ListName -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Test-FieldExists {
    param([string]$ListName, [string]$FieldName)
    # Enumerate list-scoped fields and match InternalName. `-Identity` can fall
    # through to site/web-scoped columns and report a false positive - the
    # helper would then skip adding the column to the list while SPFx
    # `$select=X` queries fail with "field or property 'X' does not exist".
    # (Same fix as the product repos' _pnp-helpers.ps1 Ensure-Field.)
    try {
        $fields = Get-PnPField -List $ListName -ErrorAction Stop
        return [bool]($fields | Where-Object { $_.InternalName -eq $FieldName })
    }
    catch {
        return $false
    }
}

function Add-FieldIfMissing {
    param(
        [string]$ListName,
        [string]$FieldName,
        [string]$FieldType,
        [hashtable]$ExtraParams = @{}
    )

    # Separate post-creation properties from Add-PnPField parameters
    $postValues = @{}
    $filteredParams = @{}
    $postCreationKeys = @("DefaultValue", "EnforceUniqueValues", "Indexed")
    foreach ($key in $ExtraParams.Keys) {
        if ($key -in $postCreationKeys) {
            $postValues[$key] = $ExtraParams[$key]
        } else {
            $filteredParams[$key] = $ExtraParams[$key]
        }
    }

    # Create field if it doesn't exist yet
    if (-not (Test-FieldExists -ListName $ListName -FieldName $FieldName)) {
        if ($PSCmdlet.ShouldProcess("$ListName/$FieldName", "Add $FieldType column")) {
            $params = @{
                List         = $ListName
                DisplayName  = $FieldName
                InternalName = $FieldName
                Type         = $FieldType
                AddToDefaultView = $true
            }
            foreach ($key in $filteredParams.Keys) {
                $params[$key] = $filteredParams[$key]
            }
            Add-PnPField @params
            Write-Host "  Added column '$FieldName' ($FieldType) to '$ListName'." -ForegroundColor Green
        }
    }
    else {
        Write-Host "  Column '$FieldName' already exists on '$ListName'." -ForegroundColor DarkGray
    }

    # Always ensure field properties (Indexed, EnforceUniqueValues, DefaultValue)
    # so re-runs fix fields that were created but not fully configured
    if ($postValues.Count -gt 0 -and $PSCmdlet.ShouldProcess("$ListName/$FieldName", "Ensure field properties")) {
        # Indexed must be set before EnforceUniqueValues
        if ($postValues.ContainsKey("Indexed") -and $postValues["Indexed"]) {
            Set-PnPField -List $ListName -Identity $FieldName -Values @{ Indexed = $true }
        }
        if ($postValues.ContainsKey("EnforceUniqueValues") -and $postValues["EnforceUniqueValues"]) {
            Set-PnPField -List $ListName -Identity $FieldName -Values @{ EnforceUniqueValues = $true }
        }
        if ($postValues.ContainsKey("DefaultValue")) {
            Set-PnPField -List $ListName -Identity $FieldName -Values @{ DefaultValue = $postValues["DefaultValue"] }
        }
    }
}

function Add-MISGroupIfMissing {
    param(
        [string]$Name,
        [string]$Description = ""
    )

    try {
        $existing = Get-PnPGroup -Identity $Name -ErrorAction Stop
        Write-Host "  SP group '$Name' already exists." -ForegroundColor DarkGray
        return $existing
    }
    catch {
        if ($PSCmdlet.ShouldProcess($Name, "Create SP group")) {
            $params = @{ Title = $Name }
            if ($Description) { $params['Description'] = $Description }
            $created = New-PnPGroup @params
            Write-Host "  Created SP group '$Name'." -ForegroundColor Green
            return $created
        }
    }
}

function New-MISList {
    param(
        [string]$InternalName,
        [scriptblock]$ColumnsBlock,
        # List template for creation (e.g. 'Events' for calendar-backed lists).
        # Existing lists are never re-templated on re-run.
        [string]$Template = "GenericList"
    )

    $exists = Test-ListExists -ListName $InternalName

    if ($exists -and $Force) {
        Write-Warning "Force mode: removing existing list '$InternalName' and all its data."
        if ($PSCmdlet.ShouldProcess($InternalName, "Remove list (Force)")) {
            Remove-PnPList -Identity $InternalName -Force
            $exists = $false
        }
    }

    if (-not $exists) {
        if ($PSCmdlet.ShouldProcess($InternalName, "Create list '$InternalName' ($Template)")) {
            New-PnPList -Title $InternalName -Template $Template
            Write-Host "Created list '$InternalName' ($Template)." -ForegroundColor Green
        }
    }
    else {
        Write-Host "List '$InternalName' already exists. Checking columns..." -ForegroundColor Cyan
    }

    # Add columns
    & $ColumnsBlock $InternalName

    # Break inheritance and set permissions (Members=Contribute, Owners=Full Control)
    if ($PSCmdlet.ShouldProcess($InternalName, "Set permissions (Members=Contribute, Owners=FullControl)")) {
        Set-PnPList -Identity $InternalName -BreakRoleInheritance -ClearSubscopes | Out-Null
        $membersGroup = Get-PnPGroup -AssociatedMemberGroup
        $ownersGroup  = Get-PnPGroup -AssociatedOwnerGroup
        Set-PnPGroupPermissions -Identity $membersGroup -List $InternalName -AddRole (Get-MISRoleName 'Contributor')
        Set-PnPGroupPermissions -Identity $ownersGroup  -List $InternalName -AddRole (Get-MISRoleName 'Administrator')
        Write-Host "  Permissions set on '$InternalName'." -ForegroundColor Green

        Set-PnPList -Identity $InternalName -EnableVersioning $true | Out-Null
        Write-Host "  Versioning enabled on '$InternalName'." -ForegroundColor Green
    }
}

function Register-MISHubSite {
    param([string]$Url)

    Write-Host "Checking Hub site registration..." -ForegroundColor Cyan
    try {
        Get-PnPHubSite -Identity $Url -ErrorAction Stop | Out-Null
        Write-Host "Site is already registered as a Hub site." -ForegroundColor DarkGray
    }
    catch {
        if ($PSCmdlet.ShouldProcess($Url, "Register as Hub site")) {
            try {
                Register-PnPHubSite -Site $Url
                Write-Host "Registered site as Hub site." -ForegroundColor Green
            }
            catch {
                Write-Warning "Hub registration failed (needs SharePoint Administrator): $($_.Exception.Message)"
            }
        }
    }
}

# ============================================================================
#  Per-product schema API  (MIS_SchemaVersion, one row per product scope)
# ============================================================================
# MIS_SchemaVersion holds one row per product: Title = <ProductScope> (e.g. 'Core',
# 'Handoff365', 'InvoiceFlow365'), SchemaVersion = x.y.z. This replaces the single legacy
# Title = 'current' row. See docs/PROVISIONING-REFACTOR-PROPOSAL.md section 5.

# Internal: fetch the MIS_SchemaVersion list item for a product scope (or $null).
function Get-MISSchemaItem {
    param([Parameter(Mandatory)][string]$Product)
    $q = "<View><Query><Where><Eq><FieldRef Name='Title'/><Value Type='Text'>$Product</Value></Eq></Where></Query></View>"
    return (Get-PnPListItem -List "MIS_SchemaVersion" -Query $q | Select-Object -First 1)
}

# Resolve the current login name for the MigratedBy stamp (falls back to a static label).
function Get-MISMigratedBy {
    try { return (Get-PnPProperty -ClientObject (Get-PnPWeb) -Property CurrentUser).LoginName }
    catch { return "provisioning" }
}

<#
.SYNOPSIS  Returns the [version] currently recorded for a product scope, or $null if absent.
#>
function Get-MISSchema {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Product)
    $item = Get-MISSchemaItem -Product $Product
    if (-not $item) { return $null }
    $raw = $item.FieldValues.SchemaVersion
    try { return [version]$raw } catch { return $null }
}

<#
.SYNOPSIS  Upserts a product's schema version. Raise-only -- never lowers an existing value.
#>
function Set-MISSchema {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Version
    )

    $target = [version]$Version
    $item   = Get-MISSchemaItem -Product $Product

    if (-not $item) {
        if ($PSCmdlet.ShouldProcess("MIS_SchemaVersion '$Product'", "Stamp version $Version")) {
            Add-PnPListItem -List "MIS_SchemaVersion" -Values @{
                Title         = $Product
                SchemaVersion = $Version
                MigratedAt    = (Get-Date).ToUniversalTime().ToString("o")
                MigratedBy    = (Get-MISMigratedBy)
            } | Out-Null
            Write-Host "  Schema '$Product' stamped at $Version." -ForegroundColor Green
        }
        return
    }

    $current = $null
    try { $current = [version]$item.FieldValues.SchemaVersion } catch { }

    if ($current -and $current -ge $target) {
        Write-Host "  Schema '$Product' already at $current (>= $Version). No change." -ForegroundColor DarkGray
        return
    }

    if ($PSCmdlet.ShouldProcess("MIS_SchemaVersion '$Product'", "Raise version $current -> $Version")) {
        Set-PnPListItem -List "MIS_SchemaVersion" -Identity $item.Id -Values @{
            SchemaVersion = $Version
            MigratedAt    = (Get-Date).ToUniversalTime().ToString("o")
            MigratedBy    = (Get-MISMigratedBy)
        } | Out-Null
        Write-Host "  Schema '$Product' raised to $Version." -ForegroundColor Green
    }
}

<#
.SYNOPSIS  Throws if a product's recorded schema is missing or below $Minimum. Returns the
           current [version] on success. Used by product setup / provision-check.
#>
function Assert-MISSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Minimum
    )
    $current = Get-MISSchema -Product $Product
    if (-not $current) {
        throw "Product '$Product' is not provisioned on this DataCenter (no MIS_SchemaVersion row). Run the '$Product' provisioning script first."
    }
    if ($current -lt [version]$Minimum) {
        throw "Product '$Product' schema $current is below the required $Minimum. Run migrate-datacenter.ps1 -Product $Product -TargetVersion $Minimum."
    }
    return $current
}

<#
.SYNOPSIS  One-time legacy migration: converts the single Title='current' row to per-product
           rows, then DELETES it (decision #4: convert-and-remove, no fallback). Idempotent --
           a no-op once the 'current' row is gone. Intended to run first inside
           Ensure-MISCoreLists (Phase 3).
#>
function Convert-MISLegacySchema {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $legacy = Get-MISSchemaItem -Product "current"
    if (-not $legacy) { return }   # already converted / fresh site

    $ver = $legacy.FieldValues.SchemaVersion
    Write-Host "Converting legacy 'current' schema row ($ver) to per-product rows..." -ForegroundColor Yellow

    # Core + InvoiceFlow carry the legacy global version (legacy global == IF schema in
    # practice). provision-core later raises Core to its new 2.0.0 baseline (raise-only).
    Set-MISSchema -Product "Core"           -Version $ver
    Set-MISSchema -Product "InvoiceFlow365" -Version $ver

    # Stamp any other product whose lists are physically present on this site.
    $detect = [ordered]@{
        "Handoff365"    = "MIS_HandoffAuditLog"
        "InvoiceOut365" = "MIS_InvoiceOutAuditLog"
        "Alerts365"     = "MIS_AlertDefinitions"
        "Enroll365"     = "MIS_EnrollEvents"
        "Reserve365"    = "MIS_Reserve_Resources"
    }
    foreach ($product in $detect.Keys) {
        if (Test-ListExists -ListName $detect[$product]) {
            Set-MISSchema -Product $product -Version $ver
        }
    }

    if ($PSCmdlet.ShouldProcess("MIS_SchemaVersion 'current'", "Remove legacy schema row")) {
        Remove-PnPListItem -List "MIS_SchemaVersion" -Identity $legacy.Id -Force | Out-Null
        Write-Host "Removed legacy 'current' row." -ForegroundColor Green
    }
}

# ============================================================================
#  Config seeding
# ============================================================================

<#
.SYNOPSIS  Idempotently seeds one MIS_Config row, keyed by (Title=$Key, ProductScope=$Product).
           Existing rows are never overwritten. Optional -JsonValue for Note-column templates.
           Used by Ensure-MISCoreLists (global scope) and by each product script (its own scope).
#>
function Add-MISConfigDefault {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$Key,
        [string]$Value = "",
        [string]$Description = "",
        [string]$JsonValue
    )
    $q = "<View><Query><Where><And><Eq><FieldRef Name='Title'/><Value Type='Text'>$Key</Value></Eq><Eq><FieldRef Name='ProductScope'/><Value Type='Text'>$Product</Value></Eq></And></Where></Query></View>"
    $existing = Get-PnPListItem -List "MIS_Config" -Query $q | Select-Object -First 1
    if ($existing) {
        Write-Host "  Config '$Key' ($Product) already exists. Skipping." -ForegroundColor DarkGray
        return
    }
    if ($PSCmdlet.ShouldProcess("$Key ($Product)", "Create config entry")) {
        $values = @{ Title = $Key; Value = $Value; Description = $Description; ProductScope = $Product }
        if ($JsonValue) { $values["JsonValue"] = $JsonValue }
        Add-PnPListItem -List "MIS_Config" -Values $values | Out-Null
        Write-Host "  Created config '$Key' (scope: $Product)." -ForegroundColor Green
    }
}

# ============================================================================
#  Shared master-data lists
# ============================================================================
# The lists every product reads: MIS_Config + MIS_SchemaVersion + the master-data layer
# (MIS_Customers, MIS_Suppliers base, MIS_Contacts, MIS_CatalogItems, MIS_InvoicingDetails).
# Owned by Core; products NEVER create these -- they call Ensure-MISCoreLists (idempotent)
# to guarantee their shared dependencies, then add only their own lists. Product-specific
# columns on a master-data list are added by that product's script as idempotent EXTENSIONS
# (e.g. InvoiceFlow adds Verified/VerifiedAt/RegistrySource/ApprovalOrder to MIS_Suppliers).

# Core schema baseline. Bump when the shared master-data shape changes.
# 2.1.0 (2026-08-11): LegalForm added to the shared address/company columns.
$script:MISCoreSchemaVersion = "2.1.0"

# Shared address/company columns used by both MIS_Customers and MIS_Suppliers (base).
$script:MISAddressColumns = {
    param([string]$list)
    Add-FieldIfMissing -ListName $list -FieldName "CompanyName" -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "ICO"         -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "DIC"         -FieldType "Text"
    # Legal form as the registry states it: "s.r.o.", "Spolecnost s rucenim
    # omezenym", "Fyzicka osoba podnikajici dle zivnostenskeho zakona ...".
    # Free text on purpose -- ARES and RPO word it differently and neither
    # vocabulary is closed, so a Choice column would reject valid values.
    #
    # Populated by the ARES / RPO enrichment (NormalizedSubject.legalForm).
    # Its first consumer distinguishes a legal person from a natural person:
    # a company's ICO is public registry data, a sole trader's identifies an
    # individual. Anything reasoning about that MUST treat an empty value as
    # "unknown, assume natural person", never as "company" -- every row
    # predating this column is empty.
    Add-FieldIfMissing -ListName $list -FieldName "LegalForm"   -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "Street"      -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "City"        -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "ZIP"         -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "Country"     -FieldType "Text" -ExtraParams @{ DefaultValue = "CZ" }
    Add-FieldIfMissing -ListName $list -FieldName "Email"       -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "Phone"       -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "State"       -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "WebPage"     -FieldType "URL"
    Add-FieldIfMissing -ListName $list -FieldName "ParentMISId" -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "IBAN"        -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "SWIFT"       -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "IsActive"    -FieldType "Boolean" -ExtraParams @{ DefaultValue = "1" }
    Add-FieldIfMissing -ListName $list -FieldName "Notes"       -FieldType "Note"
    Add-FieldIfMissing -ListName $list -FieldName "MISId"       -FieldType "Text" -ExtraParams @{ EnforceUniqueValues = $true; Indexed = $true }
}

<#
.SYNOPSIS  Ensures the shared scaffolding exists: MIS_Config, MIS_SchemaVersion, the legacy
           schema conversion, the master-data lists, and the Core schema stamp. Idempotent.
           Every product script calls this before creating its own lists.
#>
function Ensure-MISCoreLists {
    # MIS_Config (shared key/value config, partitioned by ProductScope)
    Write-Host "`n--- MIS_Config ---" -ForegroundColor Yellow
    New-MISList -InternalName "MIS_Config" -ColumnsBlock {
        param([string]$list)
        Add-FieldIfMissing -ListName $list -FieldName "Value"        -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "JsonValue"    -FieldType "Note"
        Add-FieldIfMissing -ListName $list -FieldName "Description"  -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "ProductScope" -FieldType "Text"
    }

    # MIS_SchemaVersion (one row per product scope -- see schema API above)
    Write-Host "`n--- MIS_SchemaVersion ---" -ForegroundColor Yellow
    New-MISList -InternalName "MIS_SchemaVersion" -ColumnsBlock {
        param([string]$list)
        Add-FieldIfMissing -ListName $list -FieldName "SchemaVersion" -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "MigratedAt"    -FieldType "DateTime"
        Add-FieldIfMissing -ListName $list -FieldName "MigratedBy"    -FieldType "Text"
    }

    # Convert any legacy single-row schema to per-product rows (no-op on fresh sites).
    # Runs after MIS_SchemaVersion exists so it always has a list to read/write.
    Convert-MISLegacySchema

    # Master-data layer
    Write-Host "`n--- MIS_Customers ---" -ForegroundColor Yellow
    New-MISList -InternalName "MIS_Customers" -ColumnsBlock $script:MISAddressColumns

    Write-Host "`n--- MIS_Suppliers (base) ---" -ForegroundColor Yellow
    New-MISList -InternalName "MIS_Suppliers" -ColumnsBlock $script:MISAddressColumns

    Write-Host "`n--- MIS_Contacts ---" -ForegroundColor Yellow
    New-MISList -InternalName "MIS_Contacts" -ColumnsBlock {
        param([string]$list)
        Add-FieldIfMissing -ListName $list -FieldName "FirstName"     -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "LastName"      -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "Email"         -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "JobTitle"      -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "Phone"         -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "Street"        -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "City"          -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "State"         -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "ZIP"           -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "Country"       -FieldType "Text" -ExtraParams @{ DefaultValue = "CZ" }
        Add-FieldIfMissing -ListName $list -FieldName "CompanyMISId"  -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "IsActive"      -FieldType "Boolean" -ExtraParams @{ DefaultValue = "1" }
        Add-FieldIfMissing -ListName $list -FieldName "Notes"         -FieldType "Note"
        Add-FieldIfMissing -ListName $list -FieldName "MISId"         -FieldType "Text" -ExtraParams @{ EnforceUniqueValues = $true; Indexed = $true }
    }

    Write-Host "`n--- MIS_CatalogItems ---" -ForegroundColor Yellow
    New-MISList -InternalName "MIS_CatalogItems" -ColumnsBlock {
        param([string]$list)
        Add-FieldIfMissing -ListName $list -FieldName "Description" -FieldType "Note"
        Add-FieldIfMissing -ListName $list -FieldName "Unit"        -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "UnitPrice"   -FieldType "Currency"
        Add-FieldIfMissing -ListName $list -FieldName "VATRate"     -FieldType "Number"
        Add-FieldIfMissing -ListName $list -FieldName "Category"    -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "IsActive"    -FieldType "Boolean" -ExtraParams @{ DefaultValue = "1" }
        Add-FieldIfMissing -ListName $list -FieldName "MISId"       -FieldType "Text" -ExtraParams @{ EnforceUniqueValues = $true; Indexed = $true }
    }

    Write-Host "`n--- MIS_InvoicingDetails ---" -ForegroundColor Yellow
    New-MISList -InternalName "MIS_InvoicingDetails" -ColumnsBlock {
        param([string]$list)
        Add-FieldIfMissing -ListName $list -FieldName "Street"        -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "City"          -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "Phone"         -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "Email"         -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "CIN"           -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "VATID"         -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "AccountNumber" -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "BankName"      -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "IBAN"          -FieldType "Text"
        Add-FieldIfMissing -ListName $list -FieldName "IsActive"      -FieldType "Boolean" -ExtraParams @{ DefaultValue = "1" }
        Add-FieldIfMissing -ListName $list -FieldName "Notes"         -FieldType "Note"
        Add-FieldIfMissing -ListName $list -FieldName "MISId"         -FieldType "Text" -ExtraParams @{ EnforceUniqueValues = $true; Indexed = $true }
    }

    # Shared lookups (product-neutral). Locations: first consumer Reserve 365
    # (Resources.LocationMISId); products apply their own additive ACLs. Departments:
    # provisioned empty ahead of its first consumer (cost-center routing, team grouping).
    Write-Host "`n--- MIS_Locations ---" -ForegroundColor Yellow
    New-MISList -InternalName "MIS_Locations" -ColumnsBlock {
        param([string]$list)
        Add-FieldIfMissing -ListName $list -FieldName "MISId"       -FieldType "Text"    -ExtraParams @{ EnforceUniqueValues = $true; Indexed = $true }
        Add-FieldIfMissing -ListName $list -FieldName "Description" -FieldType "Note"
        Add-FieldIfMissing -ListName $list -FieldName "IsActive"    -FieldType "Boolean" -ExtraParams @{ DefaultValue = "1" }
    }

    Write-Host "`n--- MIS_Departments ---" -ForegroundColor Yellow
    New-MISList -InternalName "MIS_Departments" -ColumnsBlock {
        param([string]$list)
        Add-FieldIfMissing -ListName $list -FieldName "MISId"       -FieldType "Text"    -ExtraParams @{ EnforceUniqueValues = $true; Indexed = $true }
        Add-FieldIfMissing -ListName $list -FieldName "Description" -FieldType "Note"
        Add-FieldIfMissing -ListName $list -FieldName "IsActive"    -FieldType "Boolean" -ExtraParams @{ DefaultValue = "1" }
    }

    # Global (product-neutral) default config.
    Write-Host "`n--- Global MIS_Config defaults ---" -ForegroundColor Yellow
    Add-MISConfigDefault -Product "global" -Key "DefaultVATRate"  -Value "21"    -Description "Default VAT rate (%)"
    Add-MISConfigDefault -Product "global" -Key "DefaultCurrency" -Value "CZK"   -Description "Default currency code (ISO 4217)"
    Add-MISConfigDefault -Product "global" -Key "DefaultLocale"   -Value "cs-CZ" -Description "Default locale for formatting"
    Add-MISConfigDefault -Product "global" -Key "DefaultCountry"  -Value "CZ"    -Description "Default country code (ISO 3166-1 alpha-2)"

    # Record the Core schema baseline (raise-only). Stamped here so a Handoff-only site --
    # which never runs provision-core.ps1 -- still gets a Core row.
    Set-MISSchema -Product "Core" -Version $script:MISCoreSchemaVersion
}
# <<< INLINE-CORE <<<

# Handoff product schema version (per-product; independent of the Core baseline).
# 1.4.6: LinkContext on MIS_HandoffActivity (server >= 1.7.0 stores the pre-sign token
#        payload there so links can be reissued/extended; context only, never the token).
$HandoffSchemaVersion = "1.4.6"

# ---- Connect + shared core -------------------------------------------------

Write-Host "`n=== Handoff 365 Provisioning ===" -ForegroundColor Yellow
Write-Host "Site: $SiteUrl`n"

# Connecting is read-only -- always do it (NOT gated by ShouldProcess) so -WhatIf can
# evaluate the rest of the run instead of failing with "no connection".
Connect-MISDataCenter -Url $SiteUrl

# Shared core (Hub + master-data + schema). Skipped when provision-all.ps1 already ran it.
if (-not $SkipCore) {
    Register-MISHubSite -Url $SiteUrl
    # Ensures Hub, MIS_Config, MIS_SchemaVersion, master-data lists, legacy schema conversion,
    # and the Core schema stamp. Idempotent.
    Ensure-MISCoreLists
}

# ---- MIS_HandoffAuditLog ---------------------------------------------------

Write-Host "`n--- MIS_HandoffAuditLog ---" -ForegroundColor Yellow
New-MISList -InternalName "MIS_HandoffAuditLog" -ColumnsBlock {
    param([string]$list)
    Add-FieldIfMissing -ListName $list -FieldName "FlowType"          -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "HandoffId"         -FieldType "Text"   -ExtraParams @{ Indexed = $true }
    Add-FieldIfMissing -ListName $list -FieldName "SiteId"            -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "DriveId"           -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "InternalUserEmail" -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "InternalUserName"  -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "ActorEmail"        -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "ActorName"         -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "ActorType"         -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "TargetFile"        -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "TargetFileSize"    -FieldType "Number"
    Add-FieldIfMissing -ListName $list -FieldName "IPAddress"         -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "Details"           -FieldType "Note"
    Add-FieldIfMissing -ListName $list -FieldName "Timestamp"         -FieldType "DateTime"
}

# ---- MIS_HandoffActivity ---------------------------------------------------
# Current operational state (mutable) for active Handoff requests/shares -- the
# complement to the append-only MIS_HandoffAuditLog. Title holds the RefId.

Write-Host "`n--- MIS_HandoffActivity ---" -ForegroundColor Yellow
New-MISList -InternalName "MIS_HandoffActivity" -ColumnsBlock {
    param([string]$list)
    Add-FieldIfMissing -ListName $list -FieldName "ActivityType"  -FieldType "Choice"   -ExtraParams @{ Choices = @("Request","Share") }
    Add-FieldIfMissing -ListName $list -FieldName "TargetSiteId"  -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "TargetDriveId" -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "TargetItemId"  -FieldType "Text"     -ExtraParams @{ Indexed = $true }
    Add-FieldIfMissing -ListName $list -FieldName "TargetPath"    -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "TargetType"    -FieldType "Choice"   -ExtraParams @{ Choices = @("Folder","File") }
    Add-FieldIfMissing -ListName $list -FieldName "PartnerName"   -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "PartnerEmail"  -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "CreatedBy"     -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "StartsAt"      -FieldType "DateTime"
    Add-FieldIfMissing -ListName $list -FieldName "Expires"       -FieldType "DateTime" -ExtraParams @{ Indexed = $true }
    Add-FieldIfMissing -ListName $list -FieldName "Status"        -FieldType "Choice"   -ExtraParams @{ Choices = @("Active","Completed","Revoked"); DefaultValue = "Active" }
    # Schema 1.4.6: pre-sign token payload JSON written by the Handoff server so an active
    # link can be reissued (copy/resend/extend). Context only -- the signed token is never
    # stored and the payload is worthless without the tenant's jwtSecret.
    Add-FieldIfMissing -ListName $list -FieldName "LinkContext"   -FieldType "Note"
}

# ---- MIS_HandoffEnabledLibraries -------------------------------------------
# Registry of libraries with Handoff enabled. Written by the Handoff server
# (app-only) on "Set for Handoff" / "Remove from Handoff". Title holds the DriveId
# (or a "<siteId>::<listId>" placeholder for a Requested row that has no grant yet).
# Status 'Requested' (schema 1.4.5) = a non-admin asked for enablement; a SharePoint
# admin approves it in the Audit Dashboard, which grants the app + flips it to Enabled.

Write-Host "`n--- MIS_HandoffEnabledLibraries ---" -ForegroundColor Yellow
New-MISList -InternalName "MIS_HandoffEnabledLibraries" -ColumnsBlock {
    param([string]$list)
    Add-FieldIfMissing -ListName $list -FieldName "SiteId"      -FieldType "Text"     -ExtraParams @{ Indexed = $true }
    Add-FieldIfMissing -ListName $list -FieldName "ListId"      -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "DriveId"     -FieldType "Text"     -ExtraParams @{ Indexed = $true }
    Add-FieldIfMissing -ListName $list -FieldName "LibraryName" -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "LibraryUrl"  -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "WebUrl"      -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "EnabledBy"   -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "EnabledAt"   -FieldType "DateTime"
    Add-FieldIfMissing -ListName $list -FieldName "Status"      -FieldType "Choice"   -ExtraParams @{ Choices = @("Enabled","Disabled","Requested"); DefaultValue = "Enabled" }
    Add-FieldIfMissing -ListName $list -FieldName "DisabledAt"  -FieldType "DateTime"
    Add-FieldIfMissing -ListName $list -FieldName "RequestedBy" -FieldType "Text"
    Add-FieldIfMissing -ListName $list -FieldName "RequestedAt" -FieldType "DateTime"
}

# Existing tenants: Add-FieldIfMissing does NOT update an existing Choice field's choices,
# so ensure 'Requested' is present on a field created before schema 1.4.5 (idempotent).
try {
    $statusField = Get-PnPField -List "MIS_HandoffEnabledLibraries" -Identity "Status" -ErrorAction Stop
    if ($statusField.Choices -notcontains "Requested") {
        Set-PnPField -List "MIS_HandoffEnabledLibraries" -Identity "Status" `
            -Values @{ Choices = @("Enabled", "Disabled", "Requested") } | Out-Null
        Write-Host "Status choices updated to include 'Requested'." -ForegroundColor Green
    }
}
catch {
    Write-Warning "Could not verify/update Status choices: $($_.Exception.Message)"
}

# ---- Handoff365 config seeding (optional) ----------------------------------
# Idempotent: existing entries (matched by Title + ProductScope) are never overwritten.
# MIS_Config is guaranteed to exist (Ensure-MISCoreLists created it).

if (-not $SkipConfig) {
    Write-Host "`n--- Handoff365 MIS_Config entries ---" -ForegroundColor Yellow

    $handoffConfig = @(
        @{ Key = "DisplayName";          Value = "";        Description = "Customer display name" }
        @{ Key = "MailFrom";             Value = "";        Description = "Sender email for OTP and notification emails" }
        @{ Key = "NotifyEmail";          Value = "";        Description = "Default upload-notification recipient (blank = the sending user)" }
        @{ Key = "HandoffMaxFileSizeMB"; Value = "50";      Description = "Maximum file size in MB per upload" }
        # Panel pre-fill defaults -- served to the SPFx Send/Request panels via GET /api/handoff/config.
        @{ Key = "HandoffDefaultExpiryDays";     Value = "7";     Description = "Default link expiry in days (1-3650)" }
        @{ Key = "HandoffDefaultAllowDownload";  Value = "true";  Description = "Default 'allow download' for shares (true/false)" }
        @{ Key = "HandoffDefaultMaxFileCount";   Value = "20";    Description = "Default max number of files per request" }
        @{ Key = "HandoffDefaultAllowedFileTypes"; Value = "";    Description = "Default allowed file extensions, comma-separated (blank = any)" }
        @{ Key = "HandoffDefaultEnablePreview";  Value = "true";  Description = "Default in-portal file preview, Enterprise only (true/false)" }
        @{ Key = "HandoffDefaultShowAllUserFiles"; Value = "false"; Description = "Default 'show all user files' in the upload portal (true/false)" }
        @{ Key = "HandoffDefaultLang";           Value = "";      Description = "Default partner language, e.g. cs-CZ (blank = sender's UI culture)" }
        @{ Key = "BrandPrimaryColor";    Value = "#FF7517"; Description = "Primary brand color for email templates" }
        @{ Key = "BrandLogoUrl";         Value = "";        Description = "Company logo URL for email templates" }
        @{ Key = "BrandCompanyName";     Value = "";        Description = "Company name shown in emails" }
        @{ Key = "BrandFooterText";      Value = "";        Description = "Footer text for email templates" }
    )

    foreach ($entry in $handoffConfig) {
        $existing = Get-PnPListItem -List "MIS_Config" -Query "<View><Query><Where><And><Eq><FieldRef Name='Title'/><Value Type='Text'>$($entry.Key)</Value></Eq><Eq><FieldRef Name='ProductScope'/><Value Type='Text'>Handoff365</Value></Eq></And></Where></Query></View>"
        if ($existing) {
            Write-Host "  Config '$($entry.Key)' (Handoff365) already exists. Skipping." -ForegroundColor DarkGray
            continue
        }
        if ($PSCmdlet.ShouldProcess("$($entry.Key) (Handoff365)", "Create config entry")) {
            Add-PnPListItem -List "MIS_Config" -Values @{
                Title        = $entry.Key
                Value        = $entry.Value
                Description  = $entry.Description
                ProductScope = "Handoff365"
            } | Out-Null
            Write-Host "  Created config '$($entry.Key)' = '$($entry.Value)' (Handoff365)." -ForegroundColor Green
        }
    }
}

# ---- Stamp Handoff365 schema -----------------------------------------------

Set-MISSchema -Product "Handoff365" -Version $HandoffSchemaVersion

Write-Host "`n=== Handoff 365 provisioning complete ===" -ForegroundColor Green
