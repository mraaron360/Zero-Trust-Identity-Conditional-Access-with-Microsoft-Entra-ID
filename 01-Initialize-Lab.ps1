#Requires -Version 7.2
<#
.SYNOPSIS
    Creates the lab scaffolding in a TEST tenant: groups, test users, an emergency-access
    (break-glass) account and the allowed-countries named location.

.DESCRIPTION
    Objects created (all prefixed ZTLAB / ztlab- so 99-Remove-Lab.ps1 can find them):

      Groups          ZTLAB-BreakGlass        excluded from every policy
                      ZTLAB-Pilot-Users       scope of the device-compliance policy (CA007)
      Users           ztlab-breakglass01      emergency access account
                      ztlab-user01            standard test user
                      ztlab-pilot01           standard user in the pilot group
                      ztlab-admin01           holds Helpdesk Administrator (CA003 target)
      Named location  ZTLAB-Allowed-Countries country-based location used by CA004

    IDs are written to .lab-state.json (git-ignored) for the other scripts.
    Passwords are generated randomly and printed ONCE at the end - store them in a password manager.

.PARAMETER Domain
    Verified domain used for the UPNs (e.g. contoso.onmicrosoft.com). Defaults to the tenant default domain.

.PARAMETER AllowedCountries
    ISO 3166-1 alpha-2 country codes that are allowed to sign in (CA004). Default: US.

.PARAMETER LicenseSkuPartNumber
    Optional SKU to assign to the test users, e.g. AAD_PREMIUM_P2 (Entra ID P2) or SPE_E5 (Microsoft 365 E5).

.PARAMETER UsageLocation
    Usage location for the users (needed for licensing). Default: US.

.PARAMETER SkipAdminRoleAssignment
    Do not assign Helpdesk Administrator to ztlab-admin01.

.PARAMETER Force
    Skip the "type the tenant name" confirmation.

.EXAMPLE
    ./01-Initialize-Lab.ps1 -AllowedCountries US,CA -LicenseSkuPartNumber AAD_PREMIUM_P2
#>
[CmdletBinding()]
param(
    [string]$Domain,
    [string[]]$AllowedCountries = @('US'),
    [string]$LicenseSkuPartNumber,
    [string]$UsageLocation = 'US',
    [switch]$SkipAdminRoleAssignment,
    [switch]$Force
)

. "$PSScriptRoot/_common.ps1"

Connect-Lab -Scopes @(
    'User.ReadWrite.All',
    'Group.ReadWrite.All',
    'Policy.ReadWrite.ConditionalAccess',
    'Policy.Read.All',
    'Directory.Read.All',
    'RoleManagement.ReadWrite.Directory'
)
Confirm-Tenant -Force:$Force

$P        = $script:LabPrefix
$tenantId = (Get-MgContext).TenantId

if (-not $Domain) {
    $Domain = (@(Get-GraphAll -Uri '/domains') | Where-Object { $_.isDefault } | Select-Object -First 1).id
}
Write-Host "Using domain: $Domain" -ForegroundColor Cyan

# ------------------------------------------------------------------ helpers
function Initialize-LabGroup {
    param([string]$Name, [string]$Description)

    $filter = [uri]::EscapeDataString("displayName eq '$Name'")
    $found = @((Invoke-Graph -Method GET -Uri "/groups?`$filter=$filter&`$select=id,displayName").value)
    if ($found.Count -gt 0) {
        Write-Host "  = group exists  : $Name"
        return $found[0].id
    }

    $body = @{
        displayName     = $Name
        description     = $Description
        mailEnabled     = $false
        mailNickname    = ($Name -replace '[^A-Za-z0-9]', '')
        securityEnabled = $true
        groupTypes      = @()
    }
    $g = Invoke-Graph -Method POST -Uri '/groups' -Body $body
    Write-Host "  + group created : $Name"
    return $g.id
}

function Initialize-LabUser {
    param([string]$Alias, [string]$DisplayName)

    $upn = "$Alias@$Domain"
    $filter = [uri]::EscapeDataString("userPrincipalName eq '$upn'")
    $found = @((Invoke-Graph -Method GET -Uri "/users?`$filter=$filter&`$select=id,userPrincipalName").value)
    if ($found.Count -gt 0) {
        Write-Host "  = user exists   : $upn"
        return [pscustomobject]@{ Id = $found[0].id; Upn = $upn; Password = $null }
    }

    $password = New-LabPassword
    $body = @{
        accountEnabled    = $true
        displayName       = $DisplayName
        mailNickname      = $Alias
        userPrincipalName = $upn
        usageLocation     = $UsageLocation
        passwordProfile   = @{ forceChangePasswordNextSignIn = $false; password = $password }
    }
    $u = Invoke-Graph -Method POST -Uri '/users' -Body $body
    Write-Host "  + user created  : $upn"
    return [pscustomobject]@{ Id = $u.id; Upn = $upn; Password = $password }
}

function Add-LabGroupMember {
    param([string]$GroupId, [string]$UserId)

    $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$UserId" }
    try {
        Invoke-Graph -Method POST -Uri "/groups/$GroupId/members/`$ref" -Body $body | Out-Null
    }
    catch {
        if ((Get-ErrorText $_) -notmatch 'already exist') { throw }
    }
}

# ------------------------------------------------------------------ groups
Write-Host "`n[1/5] Groups" -ForegroundColor Cyan
$bgGroupId    = Initialize-LabGroup -Name "$P-BreakGlass"   -Description 'Emergency access accounts - excluded from all lab Conditional Access policies.'
$pilotGroupId = Initialize-LabGroup -Name "$P-Pilot-Users"  -Description 'Pilot users for the device-compliance policy (CA007).'

# ------------------------------------------------------------------ users
Write-Host "`n[2/5] Users" -ForegroundColor Cyan
$lp    = $P.ToLower()
$bg    = Initialize-LabUser -Alias "$lp-breakglass01" -DisplayName "$P Emergency Access 01"
$user  = Initialize-LabUser -Alias "$lp-user01"       -DisplayName "$P Test User 01"
$pilot = Initialize-LabUser -Alias "$lp-pilot01"      -DisplayName "$P Pilot User 01"
$admin = Initialize-LabUser -Alias "$lp-admin01"      -DisplayName "$P Test Admin 01"

Add-LabGroupMember -GroupId $bgGroupId    -UserId $bg.Id
Add-LabGroupMember -GroupId $pilotGroupId -UserId $pilot.Id

# ------------------------------------------------------------------ licences (optional)
if ($LicenseSkuPartNumber) {
    Write-Host "`n[3/5] Licences ($LicenseSkuPartNumber)" -ForegroundColor Cyan
    $skus = @((Invoke-Graph -Method GET -Uri '/subscribedSkus').value)
    $sku  = $skus | Where-Object { $_.skuPartNumber -eq $LicenseSkuPartNumber } | Select-Object -First 1
    if (-not $sku) {
        throw "SKU '$LicenseSkuPartNumber' not found in this tenant. Available: $($skus.skuPartNumber -join ', ')"
    }
    foreach ($u in @($user, $pilot, $admin)) {
        try {
            Invoke-Graph -Method POST -Uri "/users/$($u.Id)/assignLicense" `
                -Body @{ addLicenses = @(@{ skuId = $sku.skuId }); removeLicenses = @() } | Out-Null
            Write-Host "  + licensed      : $($u.Upn)"
        }
        catch {
            Write-Warning "  Could not license $($u.Upn): $(Get-ErrorText $_)"
        }
    }
}
else {
    Write-Host "`n[3/5] Licences - skipped (assign Entra ID P1/P2 to the test users yourself, see README)" -ForegroundColor DarkGray
}

# ------------------------------------------------------------------ admin role
Write-Host "`n[4/5] Admin role" -ForegroundColor Cyan
if ($SkipAdminRoleAssignment) {
    Write-Host '  skipped'
}
else {
    $filter = [uri]::EscapeDataString("displayName eq 'Helpdesk Administrator'")
    $role = @((Invoke-Graph -Method GET -Uri "/roleManagement/directory/roleDefinitions?`$filter=$filter").value) | Select-Object -First 1
    if (-not $role) { throw 'Could not resolve the Helpdesk Administrator role definition.' }

    try {
        Invoke-Graph -Method POST -Uri '/roleManagement/directory/roleAssignments' -Body @{
            principalId      = $admin.Id
            roleDefinitionId = $role.id
            directoryScopeId = '/'
        } | Out-Null
        Write-Host "  + Helpdesk Administrator -> $($admin.Upn)"
    }
    catch {
        if ((Get-ErrorText $_) -match 'already exist') { Write-Host '  = role assignment exists' }
        else { throw }
    }
}

# ------------------------------------------------------------------ named location
Write-Host "`n[5/5] Named location" -ForegroundColor Cyan
$locName = "$P-Allowed-Countries"
$loc = @(Get-GraphAll -Uri '/identity/conditionalAccess/namedLocations') | Where-Object { $_.displayName -eq $locName } | Select-Object -First 1
if ($loc) {
    Write-Host "  = location exists: $locName"
    $locId = $loc.id
}
else {
    $created = Invoke-Graph -Method POST -Uri '/identity/conditionalAccess/namedLocations' -Body @{
        '@odata.type'                     = '#microsoft.graph.countryNamedLocation'
        displayName                       = $locName
        countriesAndRegions               = @($AllowedCountries)
        includeUnknownCountriesAndRegions = $false
    }
    $locId = $created.id
    Write-Host "  + location created: $locName ($($AllowedCountries -join ', '))"
}

# ------------------------------------------------------------------ state
Save-LabState ([ordered]@{
        tenantId       = $tenantId
        domain         = $Domain
        prefix         = $P
        groups         = [ordered]@{ breakGlass = $bgGroupId; pilotUsers = $pilotGroupId }
        users          = [ordered]@{ breakGlass = $bg.Id; user = $user.Id; pilot = $pilot.Id; admin = $admin.Id }
        namedLocations = [ordered]@{ allowedCountries = $locId }
    })
Write-Host "`nState written to $($script:StatePath)" -ForegroundColor Green

# ------------------------------------------------------------------ credentials (shown once)
$new = @($bg, $user, $pilot, $admin) | Where-Object { $_.Password }
if ($new.Count -gt 0) {
    Write-Host "`n=== Credentials for NEWLY created users - shown once, store them now ===" -ForegroundColor Yellow
    $new | Select-Object Upn, Password | Format-Table -AutoSize | Out-String | Write-Host
}

Write-Host 'Next: ./scripts/02-Deploy-CAPolicies.ps1 -Mode ReportOnly' -ForegroundColor Cyan
