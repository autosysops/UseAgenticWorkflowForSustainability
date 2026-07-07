<#
.SYNOPSIS
    Queries the ENTSO-E Transparency Platform API to get the renewable energy percentage
    for one or more EU Azure regions.

.DESCRIPTION
    This script maps Azure region identifiers to their nearest ENTSO-E bidding zone (EIC code),
    then queries the ENTSO-E API for actual generation per production type (document type A75).
    It classifies each production type as renewable or fossil and calculates the percentage
    of renewable energy generation for each region.

    This script is designed to be run standalone for local testing, or called from a
    GitHub Agentic Workflow via MCP scripts.

.PARAMETER Regions
    One or more Azure region identifiers (e.g., "westeurope", "polandcentral").

.PARAMETER EntsoeToken
    The ENTSO-E API security token. If not provided, falls back to $env:ENTSOE_TOKEN.

.PARAMETER MappingFilePath
    Path to the azure-region-eic-mapping.json file. Defaults to ../data/azure-region-eic-mapping.json
    relative to the script location.

.EXAMPLE
    .\Get-RegionEnergy.ps1 -Regions @("westeurope", "polandcentral")

.EXAMPLE
    .\Get-RegionEnergy.ps1 -Regions "swedencentral" -EntsoeToken "your-token-here"

.NOTES
    Requires: Internet access to reach https://web-api.tp.entsoe.eu/api
    API Docs: https://documenter.getpostman.com/view/7009892/2s93JtP3F6
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [string[]]$Regions,

    [Parameter(Mandatory = $false)]
    [string]$EntsoeToken,

    [Parameter(Mandatory = $false)]
    [string]$MappingFilePath
)

# ============================================================================
# CONFIGURATION
# ============================================================================

# If no token was provided as parameter, try environment variable
if (-not $EntsoeToken) {
    # First check if it's already set in the environment
    $EntsoeToken = $env:ENTSOE_TOKEN

    # If not in environment, attempt to load from .env file (for local development)
    # Supports both .env and .env.local naming conventions
    if (-not $EntsoeToken) {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $envFiles = @(
            (Join-Path $repoRoot ".env"),
            (Join-Path $repoRoot ".env.local")
        )

        foreach ($envFile in $envFiles) {
            if (Test-Path $envFile) {
                Write-Verbose "Loading environment from: $envFile"
                Get-Content $envFile | ForEach-Object {
                    if ($_ -match "^\s*([^#][^=]+)=(.+)$") {
                        $varName = $matches[1].Trim()
                        $varValue = $matches[2].Trim().Trim('"').Trim("'")
                        [System.Environment]::SetEnvironmentVariable($varName, $varValue, "Process")
                    }
                }
                break  # Use first .env file found
            }
        }
        $EntsoeToken = $env:ENTSOE_TOKEN
    }
}

# Validate we have a token
if (-not $EntsoeToken) {
    Write-Error "No ENTSO-E token provided. Set ENTSOE_TOKEN in .env / .env.local or pass -EntsoeToken parameter."
    exit 1
}

# Resolve the mapping file path
if (-not $MappingFilePath) {
    $MappingFilePath = Join-Path (Split-Path $PSScriptRoot -Parent) "data\azure-region-eic-mapping.json"
}

# ============================================================================
# PSR TYPE CLASSIFICATION
# ============================================================================
# ENTSO-E Production Source Types (PSR Types):
# Renewable: B01=Biomass, B09=Geothermal, B10=Hydro Pumped Storage (generation),
#            B11=Hydro Run-of-river, B12=Hydro Water Reservoir, B13=Marine,
#            B15=Other renewable, B16=Solar, B17=Waste, B18=Wind Offshore,
#            B19=Wind Onshore
# Fossil:    B02=Fossil Brown coal/Lignite, B03=Fossil Coal-derived gas,
#            B04=Fossil Gas, B05=Fossil Hard coal, B06=Fossil Oil,
#            B07=Fossil Oil shale, B08=Fossil Peat, B20=Other
# Note:      B14=Nuclear is classified separately (low-carbon but not renewable)
#            For sustainability purposes, we count Nuclear as "green" (low-carbon)

$renewablePsrTypes = @("B01", "B09", "B10", "B11", "B12", "B13", "B14", "B15", "B16", "B17", "B18", "B19")
$fossilPsrTypes = @("B02", "B03", "B04", "B05", "B06", "B07", "B08", "B20")

# ============================================================================
# LOAD REGION MAPPING
# ============================================================================

if (-not (Test-Path $MappingFilePath)) {
    Write-Error "Mapping file not found at: $MappingFilePath"
    exit 1
}

$mappingData = Get-Content $MappingFilePath -Raw | ConvertFrom-Json
Write-Verbose "Loaded mapping data with $($mappingData.regions.Count) regions"

# ============================================================================
# QUERY ENTSO-E API FOR EACH REGION
# ============================================================================

$results = @()

foreach ($region in $Regions) {
    Write-Verbose "Processing region: $region"

    # Find the region in our mapping data
    $regionMapping = $mappingData.regions | Where-Object { $_.azureRegion -eq $region }

    if (-not $regionMapping) {
        Write-Warning "Region '$region' not found in mapping data. Skipping."
        $results += [PSCustomObject]@{
            Region              = $region
            Country             = "Unknown"
            EIC                 = "N/A"
            GreenEnergyMW       = 0
            FossilEnergyMW      = 0
            RenewablePercentage = -1
            Error               = "Region not found in EU mapping data"
        }
        continue
    }

    $eicCode = $regionMapping.eicCode

    # Calculate time period: use YESTERDAY's full day (00:00 to 24:00 UTC)
    # ENTSO-E "realised" generation data (processType A16) is published with a delay
    # of several hours, so today's data may not be available yet. Yesterday is always safe.
    # ENTSO-E expects format: yyyyMMddHHmm
    $yesterday = (Get-Date).AddDays(-1).Date.ToUniversalTime()
    $startInterval = $yesterday.ToString("yyyyMMddHHmm")
    $stopInterval = $yesterday.AddDays(1).ToString("yyyyMMddHHmm")

    # Build the ENTSO-E API URL for Actual Generation per Production Type
    # documentType=A75: Actual generation per type
    # processType=A16: Realised
    $uri = "https://web-api.tp.entsoe.eu/api?" +
           "documentType=A75" +
           "&processType=A16" +
           "&in_Domain=$eicCode" +
           "&periodStart=$startInterval" +
           "&periodEnd=$stopInterval" +
           "&securityToken=$EntsoeToken"

    Write-Verbose "Querying ENTSO-E API for EIC: $eicCode (period: $startInterval to $stopInterval)"

    try {
        # Call the ENTSO-E API (returns XML)
        $response = Invoke-RestMethod -Uri $uri -ErrorAction Stop

        # Parse the XML response to extract generation by production type
        # TimeSeries with inBiddingZone_Domain = generation
        # TimeSeries with outBiddingZone_Domain = consumption (we skip these)
        $series = $response.GL_MarketDocument.TimeSeries | Where-Object {
            $_."inBiddingZone_Domain.mRID" -ne $null
        }

        $greenEnergy = 0
        $fossilEnergy = 0

        foreach ($s in $series) {
            $psrType = $s.MktPSRType.psrType

            # Get the last available data point (most recent measurement)
            $lastQuantity = $s.Period.Point.quantity | Select-Object -Last 1

            if ($psrType -in $renewablePsrTypes) {
                $greenEnergy += [int]$lastQuantity
            }
            elseif ($psrType -in $fossilPsrTypes) {
                $fossilEnergy += [int]$lastQuantity
            }
            # Other types (unknown) are ignored
        }

        # Calculate renewable percentage
        $totalEnergy = $greenEnergy + $fossilEnergy
        $percentage = if ($totalEnergy -gt 0) {
            [math]::Round(($greenEnergy / $totalEnergy) * 100, 2)
        } else { 0 }

        $results += [PSCustomObject]@{
            Region              = $region
            Country             = $regionMapping.country
            EIC                 = $eicCode
            GreenEnergyMW       = $greenEnergy
            FossilEnergyMW      = $fossilEnergy
            RenewablePercentage = $percentage
            Error               = $null
        }

        Write-Verbose "  $region -> $percentage% renewable ($greenEnergy MW green, $fossilEnergy MW fossil)"
    }
    catch {
        Write-Warning "Failed to query ENTSO-E for region '$region' (EIC: $eicCode): $($_.Exception.Message)"
        $results += [PSCustomObject]@{
            Region              = $region
            Country             = $regionMapping.country
            EIC                 = $eicCode
            GreenEnergyMW       = 0
            FossilEnergyMW      = 0
            RenewablePercentage = -1
            Error               = $_.Exception.Message
        }
    }

    # Small delay to respect ENTSO-E rate limits (400 requests/minute)
    Start-Sleep -Milliseconds 200
}

# ============================================================================
# OUTPUT RESULTS AS JSON
# ============================================================================

$results | ConvertTo-Json -Depth 3
