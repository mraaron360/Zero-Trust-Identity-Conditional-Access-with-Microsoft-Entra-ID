#Requires -Version 7.2
<#
.SYNOPSIS
    Deploys (creates or updates) the ZTLAB Conditional Access policies from ../policies/*.json.

.DESCRIPTION
    Each JSON file is a plain Microsoft Graph conditionalAccessPolicy body with {{TOKENS}}:

      {{STATE}}                 replaced from -Mode
      {{BREAKGLASS_GROUP_ID}}   from .lab-state.json
      {{PILOT_GROUP_ID}}        from .lab-state.json
      {{ALLOWED_LOCATION_ID}}   from .lab-state.json
      {{ROLE:<display name>}}   resolved to the directory role definition ID at run time

    Policies are matched by displayName, so re-running the script updates in place.
    Only policies whose name starts with ZTLAB are ever touched.

.PARAMETER Mode
    ReportOnly (default) | Enabled | Disabled

.PARAMETER Only
    Deploy only these policy IDs, e.g. -Only CA001,CA002

.PARAMETER SkipRiskPolicies
    Skip CA005/CA006 (need Entra ID P2 / ID Protection).

.PARAMETER SkipDevicePolicy
    Skip CA007 (needs Intune-managed or hybrid-joined devices to test).

.EXAMPLE
    ./02-Deploy-CAPolicies.ps1                                  # everything, report-only
.EXAMPLE
    ./02-Deploy-CAPolicies.ps1 -Mode Enabled -Only CA001,CA002  # enforce two policies
.EXAMPLE
    ./02-Deploy-CAPolicies.ps1 -SkipRiskPolicies -WhatIf        # dry run without P2 policies
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('ReportOnly', 'Enabled', 'Disabled')]
    [string]$Mode = 'ReportOnly',
    [string[]]$Only,
    [switch]$SkipRiskPolicies,
    [switch]$SkipDevicePolicy,
    [string]$PolicyPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'policies'),
    [switch]$Force
)

. "$PSScriptRoot/_common.ps1"

$state = Get-LabState

Connect-Lab -Scopes @(
    'Policy.ReadWrite.ConditionalAccess',
    'Policy.Read.All',
    'Application.Read.All',
    'Directory.Read.All',
    'RoleManagement.Read.Directory'
)

if ((Get-MgContext).TenantId -ne $state.tenantId) {
    throw "Connected tenant ($((Get-MgContext).TenantId)) differs from the lab tenant in .lab-state.json ($($state.tenantId)). Disconnect-MgGraph and sign in to the lab tenant."
}
Confirm-Tenant -Force:$Force

if ($Mode -eq 'Enabled') {
    Write-Warning 'Mode=Enabled ENFORCES the policies. Review the report-only results (sign-in logs / What If) first.'
}

$stateMap = @{
    ReportOnly = 'enabledForReportingButNotEnforced'
    Enabled    = 'enabled'
    Disabled   = 'disabled'
}
$riskIds   = @('CA005', 'CA006')
$deviceIds = @('CA007')
$roleCache = @{}

function Resolve-RoleId {
    param([string]$Name)
    if (-not $roleCache.ContainsKey($Name)) {
        $filter = [uri]::EscapeDataString("displayName eq '$Name'")
        $role = @((Invoke-Graph -Method GET -Uri "/roleManagement/directory/roleDefinitions?`$filter=$filter").value) | Select-Object -First 1
        if (-not $role) { throw "Directory role '$Name' not found." }
        $roleCache[$Name] = $role.id
    }
    return $roleCache[$Name]
}

function Expand-PolicyTokens {
    param([string]$Json)

    $Json = $Json.Replace('{{STATE}}', $stateMap[$Mode])
    $Json = $Json.Replace('{{BREAKGLASS_GROUP_ID}}', $state.groups.breakGlass)
    $Json = $Json.Replace('{{PILOT_GROUP_ID}}', $state.groups.pilotUsers)
    $Json = $Json.Replace('{{ALLOWED_LOCATION_ID}}', $state.namedLocations.allowedCountries)

    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) Resolve-RoleId $m.Groups['name'].Value }
    return [regex]::Replace($Json, '\{\{ROLE:(?<name>[^}]+)\}\}', $evaluator)
}

$existing = @(Get-GraphAll -Uri '/identity/conditionalAccess/policies')
$results  = [System.Collections.Generic.List[object]]::new()

$files = Get-ChildItem -Path $PolicyPath -Filter 'CA*.json' | Sort-Object Name
foreach ($file in $files) {
    $id = $file.BaseName.Split('-')[0]

    if ($Only -and ($id -notin $Only)) { continue }
    if ($SkipRiskPolicies -and ($id -in $riskIds)) { Write-Host "skip   $id (risk-based, needs P2)" -ForegroundColor DarkGray; continue }
    if ($SkipDevicePolicy -and ($id -in $deviceIds)) { Write-Host "skip   $id (device compliance)" -ForegroundColor DarkGray; continue }

    $body = Expand-PolicyTokens -Json (Get-Content -Path $file.FullName -Raw)
    $name = ($body | ConvertFrom-Json).displayName   # also acts as a JSON syntax check

    if (-not $name.StartsWith($script:LabPrefix)) {
        throw "Refusing to deploy '$name': lab policies must start with '$($script:LabPrefix)'."
    }

    $current = $existing | Where-Object { $_.displayName -eq $name } | Select-Object -First 1
    $action  = if ($current) { 'update' } else { 'create' }

    if ($PSCmdlet.ShouldProcess($name, "$action ($Mode)")) {
        if ($current) {
            Invoke-Graph -Method PATCH -Uri "/identity/conditionalAccess/policies/$($current.id)" -Body $body | Out-Null
        }
        else {
            Invoke-Graph -Method POST -Uri '/identity/conditionalAccess/policies' -Body $body | Out-Null
        }
        Write-Host ("{0,-7} {1}" -f $action, $name) -ForegroundColor Green
    }
    $results.Add([pscustomobject]@{ Policy = $id; Name = $name; Action = $action; State = $stateMap[$Mode] })
}

Write-Host ''
$results | Format-Table -AutoSize
Write-Host 'Review results: Entra admin center > Protection > Conditional Access > Policies, then Monitoring > Sign-in logs > Report-only tab.' -ForegroundColor Cyan
