# Shared helpers for the Conditional Access / Zero Trust lab scripts.
# Dot-source from the other scripts:   . "$PSScriptRoot/_common.ps1"
#
# Everything talks to Microsoft Graph through Invoke-MgGraphRequest, so the only
# module required is Microsoft.Graph.Authentication.

$ErrorActionPreference = 'Stop'

$script:LabPrefix = 'ZTLAB'
$script:RepoRoot  = Split-Path -Parent $PSScriptRoot
$script:StatePath = Join-Path $script:RepoRoot '.lab-state.json'
$script:GraphBase = 'https://graph.microsoft.com/v1.0'

function Connect-Lab {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph (delegated, interactive) with the requested scopes.
    #>
    param([Parameter(Mandatory)][string[]]$Scopes)

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph.Authentication module not found. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $ctx = Get-MgContext
    $missing = @()
    if ($ctx) { $missing = @($Scopes | Where-Object { $_ -notin $ctx.Scopes }) }

    if (-not $ctx -or $missing.Count -gt 0) {
        Connect-MgGraph -Scopes $Scopes -NoWelcome | Out-Null
    }
}

function Invoke-Graph {
    <#
    .SYNOPSIS
        Thin wrapper over Invoke-MgGraphRequest. -Uri may be relative to /v1.0.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [object]$Body
    )

    $full = if ($Uri -match '^https?://') { $Uri } else { "$($script:GraphBase)$Uri" }
    $req = @{ Method = $Method; Uri = $full; OutputType = 'PSObject' }

    if ($null -ne $Body) {
        $req.Body = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 20 -Compress }
        $req.ContentType = 'application/json'
    }
    Invoke-MgGraphRequest @req
}

function Get-GraphAll {
    <#
    .SYNOPSIS
        GET a collection and follow @odata.nextLink. Wrap the call in @() at the call site.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$MaxItems = 0
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $page = Invoke-Graph -Method GET -Uri $next
        if ($page.value) {
            foreach ($i in $page.value) { $items.Add($i) }
        }
        if ($MaxItems -gt 0 -and $items.Count -ge $MaxItems) { break }
        $next = $page.'@odata.nextLink'
    }
    return $items
}

function Confirm-Tenant {
    <#
    .SYNOPSIS
        Safety guard: shows the tenant you are about to change and makes you type its name.
    #>
    param([switch]$Force)

    $ctx = Get-MgContext
    $org = @((Invoke-Graph -Method GET -Uri '/organization?$select=id,displayName').value) | Select-Object -First 1

    Write-Host ''
    Write-Host "  Tenant       : $($org.displayName)" -ForegroundColor Yellow
    Write-Host "  Tenant ID    : $($org.id)" -ForegroundColor Yellow
    Write-Host "  Signed in as : $($ctx.Account)" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Conditional Access can lock users out - including you.' -ForegroundColor Red
    Write-Host '  Only run this lab against a TEST tenant.' -ForegroundColor Red
    Write-Host ''

    if ($Force) { return }

    $answer = Read-Host "  Type the tenant name ($($org.displayName)) to continue"
    if ($answer -ne $org.displayName) { throw 'Tenant name did not match - aborting.' }
}

function Get-LabState {
    if (-not (Test-Path $script:StatePath)) {
        throw "State file not found ($($script:StatePath)). Run scripts/01-Initialize-Lab.ps1 first."
    }
    Get-Content -Path $script:StatePath -Raw | ConvertFrom-Json
}

function Save-LabState {
    param([Parameter(Mandatory)]$State)
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $script:StatePath -Encoding utf8
}

function New-LabPassword {
    <#
    .SYNOPSIS
        Random password built with a cryptographic RNG (PowerShell 7 / .NET Core 3+).
    #>
    param([int]$Length = 32)

    $rng  = [System.Security.Cryptography.RandomNumberGenerator]
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%*+-=?@')
    $all  = ($sets -join '').ToCharArray()

    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($s in $sets) { $chars.Add($s[$rng::GetInt32($s.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[$rng::GetInt32($all.Length)]) }

    # Fisher-Yates shuffle so the guaranteed characters are not always first
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = $rng::GetInt32($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    -join $chars
}

function Get-ErrorText {
    # Invoke-MgGraphRequest puts the useful Graph error text in ErrorDetails, not Exception.Message.
    param($ErrorRecord)
    "$($ErrorRecord.Exception.Message) $($ErrorRecord.ErrorDetails.Message)"
}
