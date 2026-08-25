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
- Host RAM covers the configured topology plus a 16 GiB host reserve, which is 236 GiB for the default profile.
- `V:` provides at least 1.5 TiB of capacity.
- `V:` is formatted NTFS.
- Hyper-V, `InternalSwitch`, `InternalNAT`, and host NAT are present.
- `C:\AzureLocalSandbox\Source` contains the staged scripts and configuration.

### Image conversion stalls at ~94% and DISM stops using CPU

Bootstrap versions before this fix formatted `V:` as ReFS. Every disk this lab creates is a dynamically
expanding or differencing VHDX, and ReFS routes each allocating write through copy-on-write metadata.
Throughput collapses, `vhdmp` logs event 129 (`Reset to device ... was issued`) in the System log, and
the DISM apply deadlocks against the mounted VHDX with no CPU and no disk I/O.

Confirm the filesystem and the resets:

```powershell
Get-Volume -DriveLetter V | Select-Object FileSystem
Get-WinEvent -LogName System -MaxEvents 400 |
  Where-Object { $_.ProviderName -eq 'vhdmp' -and $_.Id -eq 129 }
```

`Test-HostReadiness.ps1` now fails on a ReFS `V:`. Reformat it before converting media. This destroys
every nested VM and parent image on the volume, so only do it on a lab that is being rebuilt:

```powershell
Get-VM | Where-Object State -ne 'Off' | Stop-VM -Force
Get-VM | Remove-VM -Force
Get-ChildItem V:\VHDs -Filter *.vhdx | ForEach-Object { Dismount-VHD -Path $_.FullName -ErrorAction SilentlyContinue }
Format-Volume -DriveLetter V -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel 'NestedVMs' -Confirm:$false
New-Item -Path 'V:\VMs', 'V:\VHDs' -ItemType Directory -Force
Remove-Item C:\AzureLocalSandbox\State\images.json -ErrorAction SilentlyContinue
```

A DISM process wedged by the ReFS timeouts cannot always be killed, because its threads are stuck in a
kernel wait. Reboot `LocalBox-Client` if `Dism.exe` still holds the VHDX after `Stop-Process -Force`.

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
- Windows media must match `Windows Server 2025` and must be a `(Desktop Experience)` index. On evaluation media that is usually index 4, not index 3.
- Azure Local media must identify as `Azure Stack HCI` or `Azure Local`.
- Verify the expected SHA-256 before retrying.

### Image conversion sits on "Applying image index"

The apply now prints a progress line every five minutes with the bytes written and the CPU seconds
DISM has consumed. If those numbers keep rising, it is working: expect 10-30 minutes per image.

If Task Manager shows dism.exe with flat CPU *and* flat disk, DISM is hung rather than slow. The
converter stops it after 20 minutes of no progress (`-ApplyStallMinutes` tunes the threshold) and
fails with the log path. Collect evidence and clear the wedged servicing session:

```powershell
Get-Content "$env:TEMP\dism-apply-WindowsServer2025.log" -Tail 60
Get-Process dism, DismHost -ErrorAction SilentlyContinue |
    Select-Object Name, Id, StartTime, TotalProcessorTime
Get-Process dism, DismHost -ErrorAction SilentlyContinue | Stop-Process -Force
Clear-WindowsCorruptMountPoint
```

The last lines of the DISM log identify where it stopped. Runs from before this fix logged to
`C:\Windows\Logs\DISM\dism.log` instead. Rerun the stage afterwards; a partial VHDX is deleted on
failure, so the conversion restarts cleanly.

### Azure Local deployment fails with PrepareKvaTimeoutError

The cloud deployment fails while staging the Arc Resource Bridge:

```text
PrepareKvaTimeoutError: "Appliance Prepare timed out"
az arcappliance prepare hci --config-file ...hci-appliance.yaml
```

`prepare` downloads the appliance images and has a fixed timeout. It expires because every guest
behind `Vm-Router` is limited to roughly `0.01 MB/s`, so the images never finish downloading.

The cause is checksum offload on `Vm-Router`. RRAS NAT rewrites IP and TCP headers, and under nested
virtualisation the offload engines recompute those checksums incorrectly, so translated packets are
discarded upstream. Only *forwarded* traffic is affected, which disguises the fault: the router
itself downloads at full speed while everything behind it stalls, so it looks like a routing,
MTU or vSwitch problem. MTU changes, RRAS restarts and RSC/LSO changes all leave it unchanged.

Confirm it by comparing a guest with the router. `JumpstartDC` is the clearest control, because it
shares the nodes' subnet and default gateway:

```powershell
./scripts/Test-SandboxDeployment.ps1
```

Measured on an affected lab, before and after disabling checksum offload:

| Hop | Before | After |
|---|---|---|
| Host | 40.50 MB/s | 50.13 MB/s |
| `Vm-Router` | 27.70 MB/s | 34.70 MB/s |
| `JumpstartDC` | 0.01 MB/s | 30.25 MB/s |
| `AzLHOST1` | 0.01 MB/s | 22.92 MB/s |
| `AzLHOST2` | 0.01 MB/s | 27.05 MB/s |

`Initialize-ManagementPlane.ps1` now disables checksum offload, LSO and RSC on every `Vm-Router`
interface. On a lab built before this fix, apply it in place and rerun the deployment:

```powershell
$credentials = Import-Clixml -LiteralPath 'C:\AzureLocalSandbox\State\lab-credentials.xml'
Invoke-Command -VMName 'AzLMGMT' -Credential $credentials.Local -ArgumentList $credentials.Local -ScriptBlock {
    param([PSCredential]$Cred)
    Invoke-Command -VMName 'Vm-Router' -Credential $Cred -ScriptBlock {
        foreach ($nic in 'NAT', 'Mgmt', 'Provider', 'VLAN110', 'VLAN200', 'SIMInternet') {
            Disable-NetAdapterChecksumOffload -Name $nic -Confirm:$false -ErrorAction SilentlyContinue
            Disable-NetAdapterLso -Name $nic -Confirm:$false -ErrorAction SilentlyContinue
            Disable-NetAdapterRsc -Name $nic -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}
```

The setting persists across restarts. Note that SMB is a poor probe for this fault: an SMB pull
between guests can report a collapse even when the underlying TCP path is healthy, so measure with
a plain HTTP download or a raw TCP stream.

`Register-AzureLocalNodes.ps1` also retries `Invoke-AzStackHciArcInitialization` up to
`-ArcInitializationAttempts` times, defaulting to 3, when and only when the failure is
`PrepareKvaTimeoutError`. That covers a download that times out for an unrelated transient reason. It is
not a substitute for the offload fix above: if throughput is collapsed, every attempt times out.

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
- `management.azure.com`, `login.microsoftonline.com`, `gbl.his.arc.azure.com`, and `aka.ms` are reachable on port 443. The registration script probes all four before it starts onboarding, so a blocked endpoint fails fast instead of part way through a 20 minute run.
- Time is synchronized.
- The node still belongs to `WORKGROUP` before cloud deployment.
- `Invoke-AzStackHciArcInitialization` is available in the Azure Local image.

The registration script prints each node's current Arc status while polling.

### Cloud validation fails

Review the deterministic `azure-local-validate` deployment in the sandbox resource group. Do not repeatedly rerun validation after Microsoft reports the environment in a deployment-failed state unless the documented recovery procedure requires it.

`Deploy-AzureLocal.ps1 -Mode Deploy` requires a successful validation and the exact same pinned Quickstart template hash.

### Key vault name is already in use after deleting the resource group

The key vault name is derived from the subscription ID and resource group name, so it is identical every time you rebuild the same sandbox. Azure always soft-deletes key vaults, so deleting the resource group leaves the old vault reserving that name for its 30 day retention window and the next validation fails to create it.

`Test-DeploymentPreflight.ps1` checks for this at the start of a run, hours before the cloud deployment
stage would hit it, and prints the vault name to purge. `Deploy-AzureLocal.ps1` repeats the check before
submitting. Purge protection is not enabled, so recovery is:

```powershell
az keyvault purge --name <vault-name> --location <azure-location>
```

Passing `-PurgeSoftDeletedKeyVault` to `Invoke-SandboxDeployment.ps1` purges it automatically instead.
Purging is irreversible, so it never happens without that switch.

The managed identity is scoped to the resource group and may not be able to read subscription-level deleted vaults, in which case the preflight check is skipped and Azure reports the conflict during validation instead. Run `az keyvault list-deleted --resource-type vault` from your workstation to confirm.

### Commit has not been pushed

`Deploy.ps1` pins the artifact URLs to the current commit SHA and the host downloads them from GitHub, so the commit must exist on a remote branch. Push the branch, or pass `-BootstrapScriptUri` and `-SourceArchiveUri` to use your own immutable HTTPS artifacts.

### Source archive SHA-256 mismatch on the VM

`Deploy.ps1` hashes the GitHub archive at deployment time and the VM re-verifies it. A mismatch means GitHub regenerated the archive for that commit between the two downloads. Rerun `Deploy.ps1` to recompute the hash.

## Cleanup

The environment remains expensive while deallocated because disks, Bastion, and NAT Gateway still incur charges. Delete the complete resource group when finished:

```powershell
az group delete --name rg-azure-local-sandbox --yes --no-wait
```
