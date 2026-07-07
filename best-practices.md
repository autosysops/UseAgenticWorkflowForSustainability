# Best Practices Rules for Bicep Analysis

This file defines the rules that the sustainability analyzer checks against.
Each rule has an ID, category, severity, and description. The AI agent reads this file
and validates the Bicep template against each rule.

**You can add, modify, or remove rules to customize the analysis for your needs.**

---

## RULE-001: Redundancy Consistency

- **Category:** Reliability
- **Severity:** Error
- **Scope:** Storage Accounts, any resource with replication settings

**Description:**
All storage and data resources in a redundant architecture must use consistent redundancy levels.
If the overall architecture is designed for zone-redundant or geo-redundant availability
(e.g., zone-redundant App Service Plan, zone-redundant SQL Database), then ALL components
must match that redundancy level.

**What to check:**
- A Storage Account using `Standard_LRS` (Locally Redundant) while other resources use ZRS or GRS
- This creates a single point of failure that drags down the total solution availability
- Even diagnostic/log storage accounts should use ZRS in a zone-redundant architecture

**Recommendation:**
Use `Standard_ZRS` (Zone-Redundant Storage) or `Standard_GRS` (Geo-Redundant Storage)
to match the redundancy level of the rest of the architecture.

---

## RULE-002: SKU Over-Provisioning (Load Balancers & Front Door)

- **Category:** Cost Optimization
- **Severity:** Warning
- **Scope:** Load Balancers, Azure Front Door, Application Gateways

**Description:**
Load balancers and front-end services should be sized to match the expected throughput
and feature requirements. Using a higher SKU than needed wastes resources and increases costs.

**What to check:**
- Azure Front Door using `Premium_AzureFrontDoor` when no Premium-specific features are used
  (Private Link origins, managed WAF bot protection rules, enhanced analytics)
- Internal Load Balancer configured with HA Ports (protocol=All, port=0) when only specific
  ports need load balancing (e.g., just port 443 for HTTPS traffic)
- Standard SKU features that aren't utilized

**Recommendation:**
- Use `Standard_AzureFrontDoor` unless Private Link origins or advanced bot protection is required
- Configure load balancing rules for specific ports instead of HA Ports (unless routing NVA traffic)
- Document why Premium/HA features are needed if they are intentionally chosen

---

## RULE-003: App Service Plan Over-Sizing

- **Category:** Cost Optimization
- **Severity:** Warning
- **Scope:** App Service Plans (Microsoft.Web/serverfarms)

**Description:**
App Service Plans should use the minimum tier that satisfies the workload requirements.
Higher tiers are only justified when their specific features are actively used.

**What to check:**
- P3v3 (8 vCPU, 32GB RAM) for a basic web application that doesn't need heavy compute
- PremiumV3 tier when no deployment slots, VNet integration beyond Basic, or specific
  premium features (custom domains with SNI SSL) are needed beyond what Standard offers
- Plans with capacity > 1 but without zoneRedundant=true (wasted redundancy cost)

**Recommendation:**
- Start with the smallest tier (B1/S1) and scale up based on actual metrics
- Use P1v3 if Premium features are needed (VNet integration, more memory)
- Only use P3v3 if CPU/memory benchmarks justify it

---

## RULE-004: Internal Communication Encryption (Zero Trust)

- **Category:** Security
- **Severity:** Error
- **Scope:** Front Door routes, Load Balancer health probes, backend pool connections

**Description:**
All communication between Azure services must be encrypted using HTTPS/TLS,
even when traffic stays within Azure's network. This follows Zero Trust principles
where no network boundary is trusted.

**What to check:**
- Front Door health probes using `Http` protocol instead of `Https`
- Front Door routes with `forwardingProtocol: 'HttpOnly'` instead of `HttpsOnly`
- Front Door routes supporting `Http` protocol without HTTPS redirect enabled
- Backend origins without certificate verification enabled
- Any internal service-to-service communication over plaintext HTTP

**Recommendation:**
- Set health probe protocol to `Https`
- Use `forwardingProtocol: 'HttpsOnly'` on all routes
- Enable `httpsRedirect: 'Enabled'` to force HTTPS
- Remove `Http` from `supportedProtocols` or ensure redirect is active

---

## RULE-005: Database Connection Encryption

- **Category:** Security
- **Severity:** Error
- **Scope:** SQL Servers, PostgreSQL Servers, MySQL Servers, Cosmos DB

**Description:**
Database servers must enforce encrypted connections with a minimum TLS version of 1.2.
Public network access should be disabled in production, with Private Endpoints used instead.

**What to check:**
- `minimalTlsVersion` not set or set below `1.2`
- `publicNetworkAccess` set to `Enabled` in production environments
- Missing Private Endpoint connections for database resources

**Recommendation:**
- Always set `minimalTlsVersion: '1.2'` (or `1.3` when supported)
- Set `publicNetworkAccess: 'Disabled'` and use Private Endpoints
- The sample template correctly configures TLS 1.2 and disables public access (this is a PASS example)

---

## RULE-006: Sustainable Region Selection

- **Category:** Sustainability
- **Severity:** Warning
- **Scope:** All resources with a `location` property

**Description:**
Resources should be deployed in Azure regions where the electricity grid has a high
percentage of renewable energy (>50%). Regions powered primarily by fossil fuels
(especially coal) have a significantly higher carbon footprint.

**What to check:**
- Resources deployed in regions with known high fossil fuel dependency:
  - `polandcentral` — Poland's grid is ~70-80% coal/fossil
  - `germanywestcentral` — Can be ~40-60% fossil depending on time
- Use the ENTSO-E API data to validate the current renewable percentage

**Recommendation:**
- Prefer Nordic regions: `swedencentral`, `norwayeast`, `finlandcentral` (typically >70% renewable)
- `francecentral` is also excellent (nuclear + renewable = >90% low-carbon)
- `westeurope` (Netherlands) is moderate but improving
- If `polandcentral` is required for data residency, document the justification

---

## RULE-007: Latency Between Dependent Resources

- **Category:** Performance
- **Severity:** Warning
- **Scope:** Resources that communicate frequently (App↔DB, Front Door↔Backend, API↔Cache)

**Description:**
Resources that are latency-dependent should be in the same region or within an acceptable
latency threshold. Cross-region communication adds latency that impacts user experience
and application performance.

**What to check:**
- App Service and its primary database in different regions (adds 10-30ms per request)
- Front Door backends in regions far from each other (affects failover behavior)
- Use the `AzNetworkLatency` module to measure actual inter-region latency
- Threshold: <2ms (same region), <10ms (acceptable), >10ms (needs justification)

**Recommendation:**
- Deploy App Service and its primary database in the same region
- If cross-region is required (e.g., for disaster recovery), ensure it's the secondary replica
- Use the `Get-AzNetworkLatency` cmdlet to validate: acceptable latency is <10ms for dependent resources
- Document any cross-region dependency with latency justification
