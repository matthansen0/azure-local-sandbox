# Azure Deployment Plan

> **Status:** Validated

Generated: 2026-08-26T15:05:00Z

---

## 1. Project Overview

**Goal:** Resume the existing Azure Local sandbox deployment, complete the monitoring resources, and verify that `LocalBox-Client` is ready for an Azure Bastion login.

**Path:** Modify Existing

---

## 2. Requirements

| Attribute | Value |
|-----------|-------|
| Classification | Development sandbox |
| Scale | One `Standard_E32s_v6` host with nested Azure Local lab capacity |
| Budget | Cost-contained monitoring and free Bastion Developer where available |
| **Subscription** | `ME-MngEnvMCAP176643-mahans-1` (`22f33804-8064-4182-8bc7-a03acb2989ed`) - confirmed from the existing deployment and active CLI context |
| **Location** | Existing resource group in `centralus`; Azure Local registration region `eastus` - confirmed from the existing deployment |

---

## 3. Components Detected

| Component | Type | Technology | Path |
|-----------|------|------------|------|
| Subscription deployment | Infrastructure | Bicep | `infra/main.bicep` |
| Host and bootstrap | Compute | Azure VM, managed identity, VM extensions | `infra/modules/host.bicep` |
| Private access | Network | VNet, NAT Gateway, Azure Bastion | `infra/modules/network.bicep` |
| Host telemetry | Monitoring | Log Analytics, Azure Monitor Agent, DCR | `infra/modules/monitoring.bicep` |
| Deployment wrapper | Orchestration | PowerShell 7 and Azure CLI | `scripts/Deploy.ps1` |

---

## 4. Recipe Selection

**Selected:** Bicep through the repository's Azure CLI deployment wrapper

**Rationale:** The project already has a tested subscription-scoped Bicep deployment and purpose-built wrapper for provider registration, immutable artifacts, quota checks, Bastion fallback, and monitoring propagation retries. Introducing AZD would change the established deployment contract.

---

## 5. Architecture

**Stack:** Nested virtualization development sandbox

### Service Mapping

| Component | Azure Service | SKU |
|-----------|---------------|-----|
| Outer host | Azure Virtual Machines | `Standard_E32s_v6` |
| Private login | Azure Bastion | Developer (`Auto`, Standard fallback) |
| Host disks | Azure Managed Disks | Premium SSD P30 |
| Monitoring | Log Analytics | PerGB2018, 5 GB/day cap |

### Supporting Services

| Service | Purpose |
|---------|---------|
| Managed Identity | Azure Local registration and sandbox-scoped automation |
| Azure Monitor Agent | Filtered host event collection |
| NAT Gateway | Controlled outbound connectivity for bootstrap and nested deployment |

---

## 6. Execution Checklist

### Phase 1: Planning
- [x] Analyze workspace
- [x] Gather requirements from the existing deployment and documentation
- [x] Confirm subscription and location from the user's explicit resume request and existing deployment
- [x] Scan codebase
- [x] Select Bicep recipe
- [x] Plan architecture
- [x] **User approved this plan**

### Phase 2: Execution
- [x] Research components and Azure deployment guidance
- [x] Keep the existing infrastructure and deployment wrapper
- [x] Select the targeted monitoring-module resume so no VM credential is read or reset
- [x] Update plan status to `Ready for Validation`

### Phase 3: Validation
- [x] Invoke azure-validate skill
- [x] Run repository validation and Azure what-if
- [x] Update plan status to `Validated`
- [x] Record validation proof below

### Phase 4: Deployment
- [ ] Invoke azure-deploy skill
- [ ] Deployment successful
- [ ] Verify VM power state, bootstrap extension, Bastion access, and monitoring association
- [ ] Update plan status to `Deployed`

---

## 7. Validation Proof

| Check | Command Run | Result | Timestamp |
|-------|-------------|--------|-----------|
| Repository validation | `.\tests\Invoke-Tests.ps1 -Offline -BicepExecutable $HOME\.azure\bin\bicep.exe` | Pass: 46 tests, 0 failed, 1 environment skip | 2026-08-26T15:08:56Z |
| Monitoring Bicep build | Build `infra/modules/monitoring.bicep` | Pass: no diagnostics | 2026-08-26T15:08:56Z |
| Azure what-if | `az deployment group what-if ... --template-file .\infra\modules\monitoring.bicep` | Pass: no deletes; creates only DCR and DCRA; idempotent deploy of workspace, Event table, and AMA | 2026-08-26T15:08:56Z |

**Validated by:** azure-validate skill
**Validation timestamp:** 2026-08-26T15:08:56Z

---

## 8. Files to Generate

| File | Purpose | Status |
|------|---------|--------|
| `.azure/plan.md` | Deployment workflow source of truth | Complete |
| Existing `infra/*.bicep` | Infrastructure definition | No generation required |
| Existing `scripts/Deploy.ps1` | Validated deployment orchestration | No generation required |

---

## 9. Next Steps

> Current: Validated and ready for deployment

1. Deploy only the validated monitoring module.
2. Verify the VM, bootstrap extension, Bastion route, and monitoring association.
3. Rerun the original subscription deployment from Cloud Shell to record top-level success.