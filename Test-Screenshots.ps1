#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-publish check: every screenshot referenced in README.md exists and is no longer a placeholder.

.DESCRIPTION
    The repo ships with clearly-labelled placeholder PNGs. Replace each one with your own capture
    (same file name), then run this script. It exits with code 1 while anything is missing or
    still a placeholder, so you can also wire it into CI.

.EXAMPLE
    ./scripts/Test-Screenshots.ps1
#>
[CmdletBinding()]
param()

$root   = Split-Path -Parent $PSScriptRoot
$shots  = Join-Path $root 'screenshots'
$readme = Get-Content -Path (Join-Path $root 'README.md') -Raw

$refs = [regex]::Matches($readme, 'screenshots/([A-Za-z0-9._-]+\.png)') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

$missing      = [System.Collections.Generic.List[string]]::new()
$placeholders = [System.Collections.Generic.List[string]]::new()

foreach ($name in $refs) {
    $path = Join-Path $shots $name
    if (-not (Test-Path $path)) { $missing.Add($name); continue }

    # Placeholders carry an uncompressed PNG text chunk containing this marker.
    $text = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($path))
    if ($text.Contains('ZTLAB-PLACEHOLDER')) { $placeholders.Add($name) }
}

Write-Host "README references $($refs.Count) screenshot(s)."
Write-Host "  real      : $($refs.Count - $missing.Count - $placeholders.Count)" -ForegroundColor Green

if ($placeholders.Count) {
    Write-Host "  placeholder: $($placeholders.Count)" -ForegroundColor Yellow
    $placeholders | ForEach-Object { Write-Host "     - $_" -ForegroundColor Yellow }
}
if ($missing.Count) {
    Write-Host "  missing   : $($missing.Count)" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "     - $_" -ForegroundColor Red }
}

if ($placeholders.Count -or $missing.Count) { exit 1 }
Write-Host 'All screenshots are in place.' -ForegroundColor Green
