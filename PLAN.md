# Project Plan

This file documents the plan for this demonstration repository. It serves as memory
for the AI assistant so decisions don't need to be re-explained in future conversations.

## Goal

Create a GitHub Agentic Workflow that analyzes Bicep templates for sustainability
(EU energy grid data) and best-practice conformance, producing advisory reports
without deploying any infrastructure.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                GitHub Agentic Workflow                        │
│  (.github/workflows/sustainability-analyzer.md)              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. Reads bicep/main.bicep (static analysis)                │
│  2. Reads best-practices.md (rules to check)                │
│  3. Calls MCP Scripts:                                       │
│     ├── get-region-energy → scripts/Get-RegionEnergy.ps1    │
│     │   └── Queries ENTSO-E API for energy mix              │
│     └── get-region-latency → scripts/Get-RegionLatency.ps1  │
│         └── Uses AzNetworkLatency module                     │
│  4. AI Agent produces structured analysis                    │
│  5. Creates GitHub Issue via safe-outputs                    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Scope

- **EU-only** — Limited to European Azure datacenters (customer requirement)
- **Advisory only** — No resources are deployed; purely static analysis
- **Manual trigger** — workflow_dispatch only, for controlled execution
- **PowerShell** — All scripts written in PowerShell (preferred language)

## Data Flow

1. ENTSO-E Transparency Platform → `documentType=A75&processType=A16` → XML response
2. Azure region → mapped to nearest EIC bidding zone via `data/azure-region-eic-mapping.json`
3. PSR types classified: renewable (B01,B09-B19 excl B14=nuclear counted as green) vs fossil (B02-B08,B20)
4. AzNetworkLatency module → pre-measured latency data between Azure regions

## Script Roles

| Script | Called by | Purpose |
|--------|-----------|--------|
| `Get-RegionEnergy.ps1` | MCP script (workflow) + Test-BicepLocally | Queries ENTSO-E, returns JSON |
| `Get-RegionLatency.ps1` | MCP script (workflow) + Test-BicepLocally | Queries AzNetworkLatency, returns JSON |
| `Test-BicepLocally.ps1` | Developer (manual) | Parses Bicep → extracts regions → calls the above scripts |

The workflow's AI agent reads the Bicep file directly and decides which tools to call.
`Test-BicepLocally.ps1` approximates this locally by parsing region strings from the Bicep file.

## Best Practices Rules (7 total)

| Rule | Category | What it checks |
|------|----------|---------------|
| RULE-001 | Reliability | LRS storage in ZRS/GRS architecture |
| RULE-002 | Cost | Over-provisioned LB/Front Door SKUs |
| RULE-003 | Cost | Over-sized App Service Plans |
| RULE-004 | Security | HTTP instead of HTTPS internally |
| RULE-005 | Security | Database TLS enforcement |
| RULE-006 | Sustainability | High-fossil-fuel regions |
| RULE-007 | Performance | Latency between dependent resources |

## Sample Bicep Issues (intentional, for demo)

The bicep/main.bicep has 7 planted issues — one for each rule.
See DECISIONS.md for why each was chosen.
