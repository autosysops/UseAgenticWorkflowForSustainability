<#
.SYNOPSIS
    Local test runner that parses a Bicep file and runs sustainability analysis against it.

.DESCRIPTION
    This script parses a Bicep template to extract Azure regions, then runs the
    Get-RegionEnergy and Get-RegionLatency scripts to produce a local sustainability report.

    It mimics what the AI agent does in the GitHub Agentic Workflow, but runs entirely
    locally so you can validate your ENTSO-E token and preview results before triggering
    the full workflow.

    The script:
    1. Parses the Bicep file to find all location/region references
    2. Queries ENTSO-E for energy mix data per region
    3. Checks latency between regions that have dependent resources

.PARAMETER BicepFilePath
    Path to the Bicep file to analyze. Defaults to ../bicep/main.bicep relative to this script.

.EXAMPLE
    .\Test-BicepLocally.ps1

.EXAMPLE
    .\Test-BicepLocally.ps1 -BicepFilePath "C:\MyProject\infra\main.bicep"

.NOTES
    Requires: .env file with ENTSOE_TOKEN set (copy from .env.example)
    Requires: AzNetworkLatency module (will auto-install if missing)
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $false)]
    [string]$BicepFilePath
)

# ============================================================================
# SETUP
# ============================================================================

$ErrorActionPreference = "Continue"
$scriptRoot = $PSScriptRoot

# Default Bicep file path: ../bicep/main.bicep relative to this script
if (-not $BicepFilePath) {
    $BicepFilePath = Join-Path (Split-Path $scriptRoot -Parent) "bicep\main.bicep"
}

# Validate the Bicep file exists
if (-not (Test-Path $BicepFilePath)) {
    Write-Error "Bicep file not found at: $BicepFilePath"
    exit 1
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Sustainability Bicep Analyzer - Local Test Runner" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Analyzing: $BicepFilePath" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# PARSE BICEP FILE TO EXTRACT REGIONS
# ============================================================================
# We look for:
#   - param declarations with default values that look like Azure regions
#   - Hardcoded location strings (e.g., location: 'westeurope')
#   - Known Azure region identifiers in string literals
# This is a simple regex-based parser; the AI agent in the workflow does deeper analysis.

Write-Host "[1/4] Parsing Bicep file for Azure regions..." -ForegroundColor Yellow

# Read the Bicep file line by line so we can skip comment lines
$bicepLines = Get-Content $BicepFilePath

# Load the mapping file to get the list of known EU region IDs
$mappingFilePath = Join-Path (Split-Path $scriptRoot -Parent) "data\azure-region-eic-mapping.json"
$mappingData = Get-Content $mappingFilePath -Raw | ConvertFrom-Json
$knownRegions = $mappingData.regions | ForEach-Object { $_.azureRegion }

# Find region string literals in non-comment lines only
# This avoids false positives from recommendation comments like "// use swedencentral"
$foundRegions = @()
$codeLines = $bicepLines | Where-Object { $_ -notmatch '^\s*//' }  # Skip full-line comments
$codeContent = $codeLines -join "`n"

foreach ($region in $knownRegions) {
    # Match the region as a string literal (e.g., 'westeurope' or "westeurope")
    if ($codeContent -match "['`"]$region['`"]") {
        $foundRegions += $region
    }
}

# Deduplicate
$regions = $foundRegions | Select-Object -Unique

if ($regions.Count -eq 0) {
    Write-Warning "No known EU Azure regions found in the Bicep file."
    Write-Warning "Known regions: $($knownRegions -join ', ')"
    exit 0
}

Write-Host "  Found regions: $($regions -join ', ')" -ForegroundColor Green
Write-Host ""

# ============================================================================
# DETERMINE DEPENDENT RESOURCE PAIRS
# ============================================================================
# If there are multiple distinct regions, check latency between each pair.
# In a full analysis the AI agent understands resource dependencies from the Bicep;
# here we simply check all unique region pairs since any cross-region communication
# between resources in this template is potentially latency-sensitive.

$dependentPairs = @()
if ($regions.Count -gt 1) {
    for ($i = 0; $i -lt $regions.Count; $i++) {
        for ($j = $i + 1; $j -lt $regions.Count; $j++) {
            $dependentPairs += @{ Source = $regions[$i]; Destination = $regions[$j] }
        }
    }
}

Write-Host "[2/4] Identified $($dependentPairs.Count) cross-region pair(s) to check for latency" -ForegroundColor Yellow
Write-Host ""

# ============================================================================
# TEST 1: ENERGY MIX ANALYSIS
# ============================================================================

Write-Host "[3/4] Querying ENTSO-E for energy mix data..." -ForegroundColor Yellow

try {
    $energyResults = & "$scriptRoot\Get-RegionEnergy.ps1" -Regions $regions -Verbose:$false | ConvertFrom-Json

    Write-Host ""
    Write-Host "  Energy Mix Results:" -ForegroundColor Green
    Write-Host "  -------------------"
    foreach ($result in $energyResults) {
        $color = if ($result.RenewablePercentage -ge 50) { "Green" }
                 elseif ($result.RenewablePercentage -ge 30) { "Yellow" }
                 else { "Red" }

        if ($result.Error) {
            Write-Host "  $($result.Region) ($($result.Country)): ERROR - $($result.Error)" -ForegroundColor Red
        }
        else {
            Write-Host "  $($result.Region) ($($result.Country)): $($result.RenewablePercentage)% renewable" -ForegroundColor $color
        }
    }
}
catch {
    Write-Host "  ERROR: Failed to run energy analysis: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Make sure ENTSOE_TOKEN is set in your .env file." -ForegroundColor Red
}

Write-Host ""

# ============================================================================
# TEST 2: LATENCY ANALYSIS
# ============================================================================

Write-Host "[4/4] Checking inter-region latency..." -ForegroundColor Yellow

if ($dependentPairs.Count -eq 0) {
    Write-Host "  All resources are in the same region - no cross-region latency to check." -ForegroundColor Green
}

foreach ($pair in $dependentPairs) {
    try {
        $latencyResult = & "$scriptRoot\Get-RegionLatency.ps1" -Source $pair.Source -Destination $pair.Destination | ConvertFrom-Json

        $color = switch ($latencyResult.Status) {
            "OK"       { "Green" }
            "Warning"  { "Yellow" }
            "Critical" { "Red" }
            default    { "White" }
        }

        Write-Host ""
        Write-Host "  $($pair.Source) -> $($pair.Destination): $($latencyResult.LatencyMs) ms [$($latencyResult.Status)]" -ForegroundColor $color
        Write-Host "  $($latencyResult.Message)" -ForegroundColor Gray
    }
    catch {
        Write-Host "  ERROR checking $($pair.Source) -> $($pair.Destination): $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Test Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "To trigger the full AI-powered analysis, use:" -ForegroundColor Gray
Write-Host "  gh aw run sustainability-analyzer" -ForegroundColor White
Write-Host "Or trigger manually from the Actions tab on GitHub." -ForegroundColor Gray
