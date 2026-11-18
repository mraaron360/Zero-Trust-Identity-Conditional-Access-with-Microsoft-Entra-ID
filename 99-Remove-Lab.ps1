#Requires -Version 7.2
<#
.SYNOPSIS
    Removes everything the lab created: ZTLAB policies, the named location, ztlab- users and ZTLAB- groups.

.DESCRIPTION
    Order matters - policies first (they reference the location and groups), then the location,
    users, groups. Only objects whose name starts with ZTLAB / ztlab- are touched.
    Deleted users stay in the Entra recycle bin for 30 days.

.PARAMETER Force
    Skip the "type the tenant name" confirmation.

.EXAMPLE
    ./99-Remove-Lab.ps1 -WhatIf     # preview
    ./99-Remove-Lab.ps1             # delete
#>
[CmdletBinding(SupportsShouldProcess)]
param([switch]$Force)

. "$PSScriptRoot/_common.ps1"

Connect-Lab -Scopes @(
    'Policy.ReadWrite.ConditionalAccess',
    'Policy.Read.All',
    'User.ReadWrite.All',
    'Group.ReadWrite.All',
    'Directory.Read.All'
)
Confirm-Tenant -Force:$Force

$P  = $script:LabPrefix
$lp = $P.ToLower()

Write-Host "`n[1/4] Conditional Access policies" -ForegroundColor Cyan
$policies = @(Get-GraphAll -Uri '/identity/conditionalAccess/policies') | Where-Object { $_.displayName -like "$P-*" }
foreach ($pol in $policies) {
    if ($PSCmdlet.ShouldProcess($pol.displayName, 'delete policy')) {
        Invoke-Graph -Method DELETE -Uri "/identity/conditionalAccess/policies/$($pol.id)" | Out-Null
        Write-Host "  - $($pol.displayName)"
    }
}

Write-Host "`n[2/4] Named locations" -ForegroundColor Cyan
$locations = @(Get-GraphAll -Uri '/identity/conditionalAccess/namedLocations') | Where-Object { $_.displayName -like "$P-*" }
foreach ($loc in $locations) {
    if ($PSCmdlet.ShouldProcess($loc.displayName, 'delete named location')) {
        Invoke-Graph -Method DELETE -Uri "/identity/conditionalAccess/namedLocations/$($loc.id)" | Out-Null
        Write-Host "  - $($loc.displayName)"
    }
}

Write-Host "`n[3/4] Users" -ForegroundColor Cyan
$userFilter = [uri]::EscapeDataString("startswith(userPrincipalName,'$lp-')")
$users = @(Get-GraphAll -Uri "/users?`$filter=$userFilter&`$select=id,userPrincipalName")
foreach ($u in $users) {
    if ($PSCmdlet.ShouldProcess($u.userPrincipalName, 'delete user')) {
        Invoke-Graph -Method DELETE -Uri "/users/$($u.id)" | Out-Null
        Write-Host "  - $($u.userPrincipalName)"
    }
}

Write-Host "`n[4/4] Groups" -ForegroundColor Cyan
$groupFilter = [uri]::EscapeDataString("startswith(displayName,'$P-')")
$groups = @(Get-GraphAll -Uri "/groups?`$filter=$groupFilter&`$select=id,displayName")
foreach ($g in $groups) {
    if ($PSCmdlet.ShouldProcess($g.displayName, 'delete group')) {
        Invoke-Graph -Method DELETE -Uri "/groups/$($g.id)" | Out-Null
        Write-Host "  - $($g.displayName)"
    }
}

if (-not $WhatIfPreference -and (Test-Path $script:StatePath)) {
    Remove-Item -Path $script:StatePath -Force
    Write-Host "`nRemoved $($script:StatePath)"
}
Write-Host "`nCleanup complete." -ForegroundColor Green
