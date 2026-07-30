# Troubleshooting

Return to the [project overview](../README.md) or the [deployment guide](DEPLOYMENT.md).

## Resume A Failed Run

The workflow is staged and resumable. Correct the reported problem, then launch **Azure Local Sandbox Setup** again or rerun `Invoke-SandboxDeployment.ps1` with the same credentials. Completed stages are skipped.

State markers are stored in:

```text
C:\AzureLocalSandbox\State
```

They are administrative resume markers, not signed security evidence. Final validation queries live Hyper-V and Azure state.

## Logs And State

Inspect state:

```powershell
Get-ChildItem C:\AzureLocalSandbox\State\*.json |
  ForEach-Object { Get-Content $_ -Raw | ConvertFrom-Json }
```

Important logs and checks:

```powershell
Get-Content C:\AzureLocalSandbox\Logs\Bootstrap.log
./scripts/Test-HostReadiness.ps1
Get-AzResourceGroupDeployment -ResourceGroupName 'rg-azure-local-sandbox'
```

## Force A Convergent Stage

Use `-ForceStage` only after understanding the stage boundary:

```powershell
./scripts/Invoke-SandboxDeployment.ps1 `
  -LocalAdministratorCredential $localCredential `
  -DomainAdministratorCredential $domainCredential `
  -LcmCredential $lcmCredential `
  -ForceStage ManagementPlane,ArcRegistration
```

Available values:

- `Images`
- `NestedVMs`
- `GuestDisks`
- `LevelOne`
- `ManagementPlane`
- `ArcRegistration`
- `Validation`
- `Deployment`

The orchestrator blocks unsafe image replacement after differencing disks exist and blocks guest-disk specialization after first boot. Rebuild the nested VMs in those cases.

## Common Problems

### Host readiness fails

Confirm:

- The VM uses Windows Server 2025.
- The selected SKU exposes nested virtualization.
- At least 256 GiB RAM is available.
- At least 1.5 TiB remains free on `V:`.
- Hyper-V, `InternalSwitch`, `InternalNAT`, and host NAT are present.
- `C:\AzureLocalSandbox\Source` contains the staged scripts and configuration.

Rerun:

```powershell
./scripts/Test-HostReadiness.ps1
Get-Content C:\AzureLocalSandbox\State\bootstrap.json
```

### Desktop launcher is missing

Run the guided setup directly from an elevated Windows PowerShell session:

```powershell
Set-Location C:\AzureLocalSandbox\Source
./scripts/Start-SandboxSetup.ps1
```

If the source directory is missing, inspect `Bootstrap.log` and the VM extension status in Azure.

### ISO is rejected

- Ensure the file contains `sources\install.wim` or `sources\install.esd`.
- Run `Convert-LabIsoMedia.ps1 -ListImages` and choose the correct indexes.
- Windows media must match `Windows Server 2025`.
- Azure Local media must identify as `Azure Stack HCI` or `Azure Local`.
- Verify the expected SHA-256 before retrying.

### Azure Local provider principal is not found

Register `Microsoft.AzureStackHCI`, then retry, or provide the tenant-specific object ID:

```powershell
./scripts/Deploy.ps1 `
  -Mode Deploy `
  -HciResourceProviderObjectId '<guid>'
```

The resource-provider application ID is `1412d89f-b8a8-4111-b4fd-e82905cbd85d`.

### Public IP creation fails with SubscriptionNotRegisteredForFeature

The `localbox-network` module fails with:

```text
SubscriptionNotRegisteredForFeature ... is not registered for feature
Microsoft.Network/AllowBringYourOwnPublicIpAddress
```

The template requests ordinary Azure-allocated Standard public IPs, so this is a subscription restriction rather than a template problem. `Deploy.ps1 -Mode Deploy` registers that feature during preflight, waits for the `Registered` state, and re-registers `Microsoft.Network` so the flag propagates. Rerun the deployment.

Registration requires subscription-level rights. If preflight reports that it cannot register the feature, have a subscription owner run:

```powershell
az feature register --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress
az provider register --namespace Microsoft.Network
```

Passing `deployBastion = false` in `infra/main.bicepparam` is not a workaround. It removes only the Bastion public IP, which the Developer SKU does not create anyway; the NAT Gateway still requires one for outbound access.

### Bastion deployment fails on the Developer SKU

The Developer SKU is offered only in the regions listed in `config/dependencies.psd1`. `Deploy.ps1 -BastionSku Auto` picks Standard elsewhere and retries once with Standard if Azure rejects the Developer SKU. If the region list is stale, deploy with an explicit `-BastionSku Standard` and update the list.

The Developer SKU also allows only one VM session at a time and does not support virtual network peering. Use `-BastionSku Standard` when either limit matters.

### Arc registration waits or times out

Check from each Azure Local node:

- DNS resolves the lab domain.
- `management.azure.com:443` is reachable.
- Time is synchronized.
- The node still belongs to `WORKGROUP` before cloud deployment.
- `Invoke-AzStackHciArcInitialization` is available in the Azure Local image.

The registration script prints each node's current Arc status while polling.

### Cloud validation fails

Review the deterministic `azure-local-validate` deployment in the sandbox resource group. Do not repeatedly rerun validation after Microsoft reports the environment in a deployment-failed state unless the documented recovery procedure requires it.

`Deploy-AzureLocal.ps1 -Mode Deploy` requires a successful validation and the exact same pinned Quickstart template hash.

### Commit has not been pushed

`Deploy.ps1` pins the artifact URLs to the current commit SHA and the host downloads them from GitHub, so the commit must exist on a remote branch. Push the branch, or pass `-BootstrapScriptUri` and `-SourceArchiveUri` to use your own immutable HTTPS artifacts.

### Source archive SHA-256 mismatch on the VM

`Deploy.ps1` hashes the GitHub archive at deployment time and the VM re-verifies it. A mismatch means GitHub regenerated the archive for that commit between the two downloads. Rerun `Deploy.ps1` to recompute the hash.

## Cleanup

The environment remains expensive while deallocated because disks, Bastion, and NAT Gateway still incur charges. Delete the complete resource group when finished:

```powershell
az group delete --name rg-azure-local-sandbox --yes --no-wait
```
