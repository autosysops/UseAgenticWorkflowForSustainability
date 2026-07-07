<#
.SYNOPSIS
    Gets the network latency between two Azure regions using the AzNetworkLatency module.

.DESCRIPTION
    This script wraps the AzNetworkLatency PowerShell module to determine the expected
    network latency (in milliseconds) between two Azure regions. This data is used to
    validate that dependent resources (e.g., App Service and Database) are deployed
    close enough to meet latency requirements.

    The module uses pre-measured latency data from:
    https://github.com/autosysops/azure_network_latency

.PARAMETER Source
    The source Azure region ID (e.g., "westeurope").

.PARAMETER Destination
    The destination Azure region ID (e.g., "polandcentral").

.PARAMETER Online
    If specified, retrieves the most up-to-date latency data from the online source.
    Without this switch, embedded (potentially outdated) data is used.

.EXAMPLE
    .\Get-RegionLatency.ps1 -Source "westeurope" -Destination "polandcentral"

.EXAMPLE
    .\Get-RegionLatency.ps1 -Source "westeurope" -Destination "swedencentral" -Online

.NOTES
    Requires: AzNetworkLatency module (Install-Module -Name AzNetworkLatency)
    Source: https://github.com/autosysops/PowerShell_AzNetworkLatency
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [Parameter(Mandatory = $false)]
    [switch]$Online
)

# ============================================================================
# ENSURE MODULE IS AVAILABLE
# ============================================================================

# Check if the AzNetworkLatency module is installed, if not install it
if (-not (Get-Module -ListAvailable -Name AzNetworkLatency)) {
    Write-Verbose "Installing AzNetworkLatency module from PSGallery..."
    Install-Module -Name AzNetworkLatency -Force -Scope CurrentUser -AllowClobber
}

# Import the module
Import-Module AzNetworkLatency -Force

# ============================================================================
# QUERY LATENCY
# ============================================================================

Write-Verbose "Querying latency from '$Source' to '$Destination' (Online: $Online)"

try {
    # Get the latency between the two regions
    # The module returns the latency in milliseconds as an integer
    if ($Online) {
        $latency = Get-AzNetworkLatency -Source $Source -Destination $Destination -Online
    }
    else {
        $latency = Get-AzNetworkLatency -Source $Source -Destination $Destination -IgnoreWarning
    }

    # Build result object
    $result = [PSCustomObject]@{
        Source      = $Source
        Destination = $Destination
        LatencyMs   = $latency
        Status      = if ($latency -le 10) { "OK" }
                      elseif ($latency -le 30) { "Warning" }
                      else { "Critical" }
        Message     = if ($latency -le 10) { "Latency is within acceptable range for dependent resources." }
                      elseif ($latency -le 30) { "Latency is elevated. Consider co-locating dependent resources." }
                      else { "Latency is too high for latency-sensitive workloads. Resources should be in the same or adjacent region." }
    }

    # Output as JSON
    $result | ConvertTo-Json -Depth 3
}
catch {
    # Return error as structured JSON
    [PSCustomObject]@{
        Source      = $Source
        Destination = $Destination
        LatencyMs   = -1
        Status      = "Error"
        Message     = "Failed to retrieve latency: $($_.Exception.Message)"
    } | ConvertTo-Json -Depth 3
}
