# Technical Decisions

This file records all technical choices made during development. It serves as memory
so these decisions don't need to be re-discussed in future conversations.

---

## Language: PowerShell Only

**Decision:** All scripts are written in PowerShell.
**Reason:** User's preferred language. Also, the `AzNetworkLatency` module is a native
PowerShell module, and the ENTSO-E API parsing pattern was already proven in PowerShell
by the user's existing automation script.
**Impact:** MCP scripts in the gh-aw workflow use `run:` blocks with `pwsh` invocation
rather than `py:` blocks.

---

## Scope: EU Only

**Decision:** Only European Azure regions are supported.
**Reason:** Customer data residency requirements limit deployments to EU datacenters.
**Impact:** Only ENTSO-E API is used (covers EU bidding zones). No need for Electricity
Maps, WattTime, or Azure Carbon Optimization (which would be needed for global coverage).
Only EU regions are included in `data/azure-region-eic-mapping.json`.

---

## Data Source: ENTSO-E Only

**Decision:** Use ENTSO-E Transparency Platform as the sole energy data source.
**Reason:** EU-only scope, user already has an API token, proven approach from existing script.
**Alternatives considered:**
- Electricity Maps API — global coverage but unnecessary for EU-only scope
- WattTime API — US-focused, not relevant
- Azure Carbon Optimization — preview, limited access
- Green Software Foundation Carbon Aware SDK — overkill for this demo

---

## Trigger: workflow_dispatch Only

**Decision:** The workflow is only triggered manually.
**Reason:** User wants full control over when the analysis runs. No automatic triggers
on push or PR events.
**Impact:** No `pull_request` or `push` triggers. User must explicitly trigger from
the Actions tab or via `gh aw run`.

---

## Output: GitHub Issue

**Decision:** Results are created as a GitHub Issue (not PR comment).
**Reason:** workflow_dispatch doesn't have a PR context. Issues provide a persistent,
searchable record of analysis results. Uses gh-aw's `safe-outputs` mechanism.

---

## Bicep Template: Not Deployed

**Decision:** The Bicep template is never deployed. It's purely a static analysis target.
**Reason:** This is a demonstration repository. The template intentionally contains issues
that would cause problems if deployed (HTTP backends, high-fossil regions, etc.).
**Impact:** No Azure subscription or deployment credentials needed.

---

## Nuclear Energy Classification

**Decision:** Nuclear (PSR type B14) is classified as "green/low-carbon" alongside renewables.
**Reason:** For sustainability scoring, the relevant metric is carbon emissions, not whether
the source is technically "renewable." Nuclear produces near-zero operational carbon.
This aligns with the EU taxonomy (conditional inclusion) and the user's original script
which counted nuclear as part of green energy.

---

## Latency Thresholds

**Decision:**
- <2ms: Same region (optimal)
- <10ms: Acceptable for dependent resources
- 10-30ms: Warning — consider co-location
- >30ms: Critical — should not be used for latency-sensitive dependencies

**Reason:** Based on typical Azure inter-region measurements and application performance
requirements. A database query adding >10ms per round-trip significantly impacts
web application response times at scale.

---

## Region-to-EIC Mapping: Static File

**Decision:** The mapping from Azure regions to ENTSO-E EIC codes is stored as a static
JSON file rather than computed dynamically.
**Reason:**
- Azure region coordinates don't change
- EIC bidding zone codes don't change
- Haversine calculation at runtime would add complexity without value
- Easy to maintain and extend by editing the JSON file
- Pre-computed from the user's original `$geoDataEICRegions` data

---

## Front Door as "Over-Provisioned" Example

**Decision:** Used Front Door Premium (instead of Standard) as the SKU over-provisioning example.
**Reason:** Front Door Premium vs Standard is a clear, well-documented difference where
Premium features (Private Link, bot protection rules) are easily verifiable. If those
features aren't used in the Bicep, it's clearly over-provisioned. This makes it easy
for the AI agent to detect and explain.

---

## Poland Central as "High Fossil" Region

**Decision:** Used `polandcentral` as the example of a high-fossil-fuel region.
**Reason:** Poland's electricity grid is historically one of the most coal-dependent in
the EU (typically 70-80% fossil fuel). This makes it a clear, consistent example that
will reliably trigger RULE-006 regardless of when the analysis is run. Other options
(like Germany) fluctuate more based on time of day and season.

---

## Secrets Management

**Decision:** Use `.env` file locally (git-ignored) and GitHub Repository Secrets for CI.
**Reason:** Standard practice. The `.env` file pattern is simple and well-understood.
Repository Secrets are the native GitHub way to handle sensitive values in Actions.
**Files affected:**
- `.env.example` — template showing required variables (committed)
- `.env` — actual secrets (in .gitignore, never committed)
- Workflow `env:` blocks reference `${{ secrets.ENTSOE_TOKEN }}`

---

## AzNetworkLatency Module: Installed at Runtime

**Decision:** The `AzNetworkLatency` module is installed on-the-fly in the MCP script
rather than requiring it as a pre-installed dependency.
**Reason:** GitHub Actions runners don't have this module pre-installed. Using
`Install-Module -Force -Scope CurrentUser` is fast (small module) and ensures the
latest version is always used. The `-Online` flag fetches the most recent latency data.

---

## Test-BicepLocally.ps1: Parses Bicep Dynamically

**Decision:** The local test script parses the Bicep file to extract regions rather than
having them hardcoded.
**Reason:** Hardcoded regions would make the script useless for any Bicep file other than
the sample. By parsing the file (matching known EU region IDs from the mapping JSON),
the script works with any Bicep template pointed at it via `-BicepFilePath`.
**How it works:**
- Loads the list of known EU region IDs from `data/azure-region-eic-mapping.json`
- Scans the Bicep file content for string literals matching those region IDs
- Any unique regions found are passed to `Get-RegionEnergy.ps1`
- All cross-region pairs are checked for latency
**Limitation:** This is a simple regex-based approach (finds region strings in quotes).
The AI agent in the workflow does deeper semantic analysis of the Bicep structure.
The local script is a quick validation tool, not a replacement for the full workflow.
