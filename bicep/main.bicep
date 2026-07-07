// =============================================================================
// SAMPLE BICEP TEMPLATE - EU Redundant Architecture
// =============================================================================
// This template is for DEMONSTRATION PURPOSES ONLY. It is NOT meant to be deployed.
// It intentionally contains several issues that the sustainability analyzer should detect:
//
// INTENTIONAL ISSUES:
// 1. Storage Account uses LRS while the rest of the architecture uses ZRS/GRS (RULE-001)
// 2. Front Door uses Premium SKU when Standard would suffice (RULE-002)
// 3. Internal Load Balancer uses Standard with HA Ports - over-provisioned (RULE-002)
// 4. App Service Plan is P3v3 - oversized for a basic web app (RULE-003)
// 5. Front Door backend uses HTTP instead of HTTPS (RULE-004)
// 6. SQL Database primary is in polandcentral - high fossil fuel region (RULE-006)
// 7. SQL in polandcentral, App in westeurope - high latency between dependent resources (RULE-007)
// =============================================================================

// --------------------------------------------------------------------------
// PARAMETERS
// --------------------------------------------------------------------------

@description('Primary location for the web application tier')
param primaryLocation string = 'westeurope'

@description('Location for the database tier - INTENTIONALLY in a high-fossil-fuel region')
param databaseLocation string = 'polandcentral'

@description('Environment name used for resource naming')
param environmentName string = 'production'

@description('The administrator login for the SQL server')
param sqlAdminLogin string = 'sqladmin'

@secure()
@description('The administrator password for the SQL server')
param sqlAdminPassword string

// --------------------------------------------------------------------------
// VARIABLES
// --------------------------------------------------------------------------

// Naming convention for resources
var prefix = 'sustdemo'
var uniqueSuffix = uniqueString(resourceGroup().id)
var appServicePlanName = '${prefix}-asp-${uniqueSuffix}'
var webAppName = '${prefix}-web-${uniqueSuffix}'
var sqlServerName = '${prefix}-sql-${uniqueSuffix}'
var sqlDatabaseName = '${prefix}-db'
var storageAccountName = '${prefix}st${uniqueSuffix}'
var frontDoorName = '${prefix}-fd-${uniqueSuffix}'
var loadBalancerName = '${prefix}-ilb-${uniqueSuffix}'
var vnetName = '${prefix}-vnet-${uniqueSuffix}'

// --------------------------------------------------------------------------
// VIRTUAL NETWORK
// --------------------------------------------------------------------------

@description('Virtual network for internal resources')
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: primaryLocation
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'app-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          delegations: [
            {
              name: 'appServiceDelegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: 'ilb-subnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
      {
        name: 'data-subnet'
        properties: {
          addressPrefix: '10.0.3.0/24'
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

// --------------------------------------------------------------------------
// STORAGE ACCOUNT
// --------------------------------------------------------------------------
// ISSUE: Uses LRS (Locally Redundant Storage) while the rest of the architecture
// is designed for zone/geo redundancy. This creates a single point of failure
// that drags down the overall availability of the solution.
// FIX: Should use ZRS (Zone-Redundant Storage) to match the redundancy level.

@description('Storage account for application diagnostics and logs')
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: primaryLocation
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'  // ISSUE: Should be Standard_ZRS to match architecture redundancy
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
  }
}

// --------------------------------------------------------------------------
// APP SERVICE PLAN
// --------------------------------------------------------------------------
// ISSUE: Uses Premium P3v3 tier which is significantly over-provisioned for
// a basic web application. P3v3 provides 8 vCPUs and 32GB RAM.
// A P1v3 (2 vCPU, 8GB) or even S1 would suffice for this workload.
// No deployment slots or heavy compute features are utilized.

@description('App Service Plan for hosting the web application')
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: primaryLocation
  sku: {
    name: 'P3v3'   // ISSUE: Over-provisioned - P1v3 or S1 would suffice
    tier: 'PremiumV3'
    capacity: 3     // 3 instances for zone redundancy (this part is correct)
  }
  properties: {
    zoneRedundant: true  // Correctly configured for zone redundancy
    reserved: false
  }
}

// --------------------------------------------------------------------------
// WEB APP
// --------------------------------------------------------------------------

@description('Web application hosted on the App Service Plan')
resource webApp 'Microsoft.Web/sites@2023-01-01' = {
  name: webAppName
  location: primaryLocation
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      alwaysOn: true
      http20Enabled: true
      // VNet integration for internal communication
      vnetName: vnet.name
      vnetRouteAllEnabled: true
    }
  }
}

// --------------------------------------------------------------------------
// SQL SERVER & DATABASE
// --------------------------------------------------------------------------
// ISSUE: Deployed in 'polandcentral' which has a high percentage of fossil fuel
// in its energy mix (Poland's grid is heavily coal-dependent, typically <30% renewable).
// ISSUE: Located far from the App Service in 'westeurope', creating unnecessary
// latency (~20ms) between the application and its primary database.
// FIX: Should be deployed in 'westeurope' (same region as the App Service) or
// 'swedencentral'/'norwayeast' for better sustainability with acceptable latency.

@description('SQL Server hosting the application database')
resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' = {
  name: sqlServerName
  location: databaseLocation  // ISSUE: polandcentral - high fossil fuel, far from app
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
  }
}

@description('Application database with zone-redundant backups')
resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-05-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: databaseLocation
  sku: {
    name: 'GP_Gen5'
    tier: 'GeneralPurpose'
    capacity: 2
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    zoneRedundant: true  // Correctly configured for zone redundancy
    requestedBackupStorageRedundancy: 'Zone'
  }
}

// --------------------------------------------------------------------------
// INTERNAL LOAD BALANCER
// --------------------------------------------------------------------------
// ISSUE: Uses Standard SKU with HA Ports enabled. For this workload (simple web app
// behind Front Door), an internal load balancer with HA ports is over-provisioned.
// HA Ports are designed for NVAs (Network Virtual Appliances) handling all traffic
// on all ports. A basic load balancing rule on port 443 would suffice.
// The Standard SKU itself is fine for zone-redundancy, but the HA Ports config is overkill.

@description('Internal Load Balancer for backend traffic distribution')
resource loadBalancer 'Microsoft.Network/loadBalancers@2023-09-01' = {
  name: loadBalancerName
  location: primaryLocation
  sku: {
    name: 'Standard'  // Standard is needed for zone-redundancy (correct)
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'internal-frontend'
        properties: {
          subnet: {
            id: vnet.properties.subnets[1].id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'ha-ports-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, 'internal-frontend')
          }
          protocol: 'All'       // ISSUE: HA Ports - routes ALL protocols on ALL ports
          frontendPort: 0       // ISSUE: Port 0 = HA Ports (all ports)
          backendPort: 0
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          loadDistribution: 'Default'
        }
      }
    ]
  }
}

// --------------------------------------------------------------------------
// AZURE FRONT DOOR
// --------------------------------------------------------------------------
// ISSUE: Uses Premium_AzureFrontDoor SKU when Standard would suffice.
// Premium adds: WAF with bot protection, Private Link origins, enhanced reports.
// This deployment does NOT use:
//   - Managed WAF rule sets with bot protection
//   - Private Link to origins
//   - Enhanced analytics
// Standard_AzureFrontDoor would provide the same functionality at lower cost.

@description('Azure Front Door for global load balancing and CDN')
resource frontDoor 'Microsoft.Cdn/profiles@2023-05-01' = {
  name: frontDoorName
  location: 'global'
  sku: {
    name: 'Premium_AzureFrontDoor'  // ISSUE: Standard would suffice - no premium features used
  }
}

@description('Front Door endpoint for the web application')
resource frontDoorEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2023-05-01' = {
  parent: frontDoor
  name: 'web-endpoint'
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
}

@description('Origin group for backend App Service instances')
resource originGroup 'Microsoft.Cdn/profiles/originGroups@2023-05-01' = {
  parent: frontDoor
  name: 'app-backend-group'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: '/health'
      probeRequestType: 'HEAD'
      probeProtocol: 'Http'       // ISSUE: Health probe uses HTTP instead of HTTPS
      probeIntervalInSeconds: 30
    }
  }
}

@description('Origin pointing to the App Service backend')
resource origin 'Microsoft.Cdn/profiles/originGroups/origins@2023-05-01' = {
  parent: originGroup
  name: 'primary-app-origin'
  properties: {
    hostName: webApp.properties.defaultHostName
    httpPort: 80
    httpsPort: 443
    originHostHeader: webApp.properties.defaultHostName
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    // ISSUE: No enforceCertificateNameCheck, and health probe uses HTTP
    // This means traffic from Front Door to the backend is not guaranteed to be encrypted
  }
}

// --------------------------------------------------------------------------
// FRONT DOOR ROUTE
// --------------------------------------------------------------------------
// ISSUE: The route forwards to the origin group but the origin group's health probe
// uses HTTP (not HTTPS). This violates Zero Trust principles where all internal
// communication should be encrypted, even between Azure services.

@description('Route from Front Door endpoint to the backend origin group')
resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2023-05-01' = {
  parent: frontDoorEndpoint
  name: 'default-route'
  properties: {
    originGroup: {
      id: originGroup.id
    }
    supportedProtocols: [
      'Http'    // ISSUE: Should only support HTTPS
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpOnly'  // ISSUE: Should be 'HttpsOnly' - violates Zero Trust
    httpsRedirect: 'Disabled'       // ISSUE: Should redirect HTTP to HTTPS
    linkToDefaultDomain: 'Enabled'
  }
}

// --------------------------------------------------------------------------
// OUTPUTS
// --------------------------------------------------------------------------

@description('The default hostname of the web application')
output webAppHostName string = webApp.properties.defaultHostName

@description('The Front Door endpoint hostname')
output frontDoorHostName string = frontDoorEndpoint.properties.hostName

@description('The SQL Server FQDN')
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
