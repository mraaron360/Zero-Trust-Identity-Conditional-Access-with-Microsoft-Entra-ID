#Requires -Version 7.2
<#
.SYNOPSIS
    Exports how the ZTLAB Conditional Access policies evaluated recent sign-ins (report-only and enforced).

.DESCRIPTION
    Reads /auditLogs/signIns and flattens appliedConditionalAccessPolicies into one row per
    sign-in x policy. Useful as evidence ("policy CA004 would have blocked this sign-in") and as
    a quick pre-enforcement review.

    Result values you will see:
      success | failure | notApplied | notEnabled
      reportOnlySuccess | reportOnlyFailure | reportOnlyNotApplied | reportOnlyInterrupted

    Sign-in logs can lag a few minutes. Requires Entra ID P1/P2 and the AuditLog.Read.All scope.
    The CSV contains UPNs and IP addresses - it is git-ignored; sanitise before sharing.

.PARAMETER Hours
    Look-back window. Default 24.

.PARAMETER UserPrincipalName
    Optional: only this user.

.PARAMETER MaxItems
    Maximum sign-ins to read. Default 200.

.PARAMETER OutFile
    CSV path. Default: evidence/ca-results.csv in the repo.

.EXAMPLE
    ./03-Export-SignInEvidence.ps1 -Hours 6 -UserPrincipalName ztlab-user01@contoso.onmicrosoft.com
#>
[CmdletBinding()]
param(
    [int]$Hours = 24,
    [string]$UserPrincipalName,
    [int]$MaxItems = 200,
    [string]$OutFile
)

. "$PSScriptRoot/_common.ps1"

if (-not $OutFile) { $OutFile = Join-Path $script:RepoRoot 'evidence/ca-results.csv' }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null

Connect-Lab -Scopes @('AuditLog.Read.All', 'Directory.Read.All')

$since  = (Get-Date).ToUniversalTime().AddHours(-$Hours).ToString('yyyy-MM-ddTHH:mm:ssZ')
$filter = "createdDateTime ge $since"
if ($UserPrincipalName) { $filter += " and userPrincipalName eq '$UserPrincipalName'" }

$uri = '/auditLogs/signIns?$filter=' + [uri]::EscapeDataString($filter) + '&$top=100'
Write-Host "Reading sign-ins since $since ..." -ForegroundColor Cyan
$signIns = @(Get-GraphAll -Uri $uri -MaxItems $MaxItems)
Write-Host "  $($signIns.Count) sign-in(s) read"

$rows = foreach ($s in $signIns) {
    foreach ($p in @($s.appliedConditionalAccessPolicies)) {
        if (-not $p.displayName -or -not $p.displayName.StartsWith($script:LabPrefix)) { continue }
        [pscustomobject]@{
            TimeUtc         = $s.createdDateTime
            User            = $s.userPrincipalName
            App             = $s.appDisplayName
            ClientApp       = $s.clientAppUsed
            IpAddress       = $s.ipAddress
            Country         = $s.location.countryOrRegion
            OverallCAStatus = $s.conditionalAccessStatus
            Policy          = $p.displayName
            Result          = $p.result
            GrantControls   = ($p.enforcedGrantControls -join ';')
            SessionControls = ($p.enforcedSessionControls -join ';')
            ErrorCode       = $s.status.errorCode
        }
    }
}
$rows = @($rows)

if ($rows.Count -eq 0) {
    Write-Warning 'No ZTLAB policy evaluations found in that window. Sign in as a test user, wait a few minutes, and retry.'
    return
}

$rows | Sort-Object TimeUtc | Export-Csv -Path $OutFile -NoTypeInformation -Encoding utf8
Write-Host "Wrote $($rows.Count) row(s) to $OutFile" -ForegroundColor Green

Write-Host "`nPolicy result summary:" -ForegroundColor Cyan
$rows | Group-Object Policy, Result | Sort-Object Name |
    Select-Object @{ n = 'Policy / Result'; e = { $_.Name } }, Count |
    Format-Table -AutoSize
