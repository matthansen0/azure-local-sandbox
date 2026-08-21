# Deployment Guide

This guide covers the supported two-phase workflow:

1. Deploy and bootstrap `LocalBox-Client` in Azure.
2. Connect through Azure Bastion, download licensed ISO media, and continue from the desktop launcher.

Return to the [project overview](../README.md) or see [troubleshooting](TROUBLESHOOTING.md).

## Prerequisites

### Azure

- A subscription where you can register resource providers, create role assignments, and deploy resources. Subscription `Owner` is the simplest sandbox permission model.
- Quota for `Standard_E32s_v5` or `Standard_E32s_v6` in the host region.
- An Azure Local-supported registration region, which can differ from the host region.
- Policies that allow VM extensions, managed identities, Key Vault, Storage, Hybrid Compute, Azure Local, and role assignments.
- Direct outbound HTTPS access. Proxy and Azure Arc Gateway modes are not implemented.

The deployment registers the required Azure resource providers, plus the `Microsoft.Network/AllowBringYourOwnPublicIpAddress` subscription feature that some subscriptions require before any public IP can be allocated.

### Deployment workstation

- PowerShell 7.2 or later.
- Azure CLI.
- Git.
- An authenticated Azure CLI session targeting the intended subscription.
- A clean Git commit, pushed to GitHub, containing the exact source to deploy.

The deployment script pins `Bootstrap.ps1` and the source archive to that commit SHA on GitHub, hashes both, and supplies the URLs and SHA-256 values to the VM extension through secure Bicep parameters. The VM re-verifies both hashes before executing anything. Pass `-BootstrapScriptUri` and `-SourceArchiveUri` to use your own immutable HTTPS artifacts instead.

### Media

The guided workflow uses:

- Windows Server 2025 ISO from a licensed Microsoft channel or the [Microsoft Evaluation Center](https://www.microsoft.com/evalcenter/download-windows-server-2025).
- Azure Local ISO from **Azure portal > Azure Local > Get started > Download software**. Select the subscription and release, accept the license terms, and download the ISO.

The project does not redistribute media or accept license terms for you. Use a publisher-provided SHA-256 when available. Otherwise, calculate and record the digest on the trusted download workstation before transferring the file.

### Nested credentials

The setup wizard prompts for three credentials:

| Credential | Default username | Requirement |
| --- | --- | --- |
| Local administrator | `Administrator` | At least 14 characters |
| Domain administrator | `JUMPSTART\Administrator` | At least 14 characters |
| LCM deployment user | `LocalBoxDeployUser` | At least 14 characters and Azure Local complexity requirements |

Credential values remain in memory and are not written to state files.

## 1. Deploy The Host

Authenticate and select the subscription:

```powershell
az login
az account set --subscription '<subscription-id>'
```

The outer VM administrator username is `localadmin`. Set its password:

```powershell
$env:AZURE_LOCAL_SANDBOX_ADMIN_PASSWORD = '<strong-password>'
```

Preview the deployment:

```powershell
./scripts/Deploy.ps1 -Mode WhatIf -Location centralus
```

If `Microsoft.AzureStackHCI` has never been registered, the tenant resource-provider principal might not exist for a side-effect-free preview. Register that provider, pass `-HciResourceProviderObjectId`, or proceed with `-Mode Deploy`, which registers the provider baseline first.

Deploy:

```powershell
./scripts/Deploy.ps1 `
  -Mode Deploy `
  -Location centralus `
  -AzureLocalLocation centralus
```

Use `-Location` and `-AzureLocalLocation` to control the host and Arc/cluster regions independently:

```powershell
./scripts/Deploy.ps1 `
  -Mode Deploy `
  -Location westus3 `
  -AzureLocalLocation centralus
```

### Azure Bastion SKU

`-BastionSku` defaults to `Auto`:

- `Developer` is selected when the host region offers it. The Developer SKU is free, uses shared infrastructure, needs no `AzureBastionSubnet` or public IP, allows one VM session at a time, and does not support virtual network peering. `centralus` is a Developer region.
- `Standard` is selected in every other region, and the deployment creates the `AzureBastionSubnet` and a Bastion public IP.
- If Azure rejects the auto-selected Developer SKU, the script retries once with `Standard`.

Pass `-BastionSku Developer`, `-BastionSku Basic`, or `-BastionSku Standard` to override the choice. The supported Developer regions are listed in [config/dependencies.psd1](../config/dependencies.psd1).

### Monitoring

The deployment creates its own Log Analytics workspace in the sandbox resource group and region, and onboards `LocalBox-Client` to it with the Azure Monitor Agent. Ingestion is capped at 5 GB per day and the rule collects only Critical, Error, and Warning events, never the `Security` channel. Override `logAnalyticsDailyQuotaGb` and `logAnalyticsRetentionInDays` in [infra/main.bicepparam](../infra/main.bicepparam), or set `deployMonitoring = false` to skip it.

After a `Deploy` run the script reports any data collection rule attached to the host from outside the sandbox resource group. That indicates a subscription-wide monitoring policy or Defender for Cloud auto-provisioning is billing this lab's telemetry to a workspace the sandbox does not own. See [monitoring containment](TECHNICAL.md#monitoring-containment).

The script resolves an exact Windows Server marketplace image, verifies the pinned Bicep version, creates private deployment artifacts, and deploys the resource group.

Bootstrap installs Hyper-V and initiates one reboot. Connect through Bastion as `localadmin`, using the password set in `AZURE_LOCAL_SANDBOX_ADMIN_PASSWORD`, and wait for readiness:

```powershell
Set-Location C:\AzureLocalSandbox\Source
./scripts/Test-HostReadiness.ps1
```

Readiness checks the host OS, virtualization extensions, memory, storage, Hyper-V, switches, NAT, and staged source.

## 2. Continue Inside The VM

1. Connect to `LocalBox-Client` through Azure Bastion.
2. Download these two ISO files inside `LocalBox-Client`:
  - **Windows Server 2025** from a licensed Microsoft channel or the [Microsoft Evaluation Center](https://www.microsoft.com/evalcenter/download-windows-server-2025). This becomes the parent disk for the nested management host, so a `(Desktop Experience)` image index is required.
  - **Azure Local** from **Azure portal > Azure Local > Get started > Download software**. Select the subscription and release, accept the license terms, and download the ISO. This becomes the parent disk for the two Azure Local nodes.
3. Double-click **Azure Local Sandbox Setup** on the public desktop.
4. Approve elevation.
5. Select both ISO files.
6. Confirm their trusted origin and choose the displayed image indexes. For Windows Server, pick a **(Desktop Experience)** index. A Server Core index cannot install the management tools the nested management host needs, and the conversion rejects it.
7. Enter the three nested credentials.
8. Choose **Validate** for the first run.

The wizard converts the ISOs into generation-2 UEFI VHDX parents, creates both Hyper-V levels, configures AD DS, DNS, and routing, registers the Azure Local nodes with Arc, and invokes cloud validation.

After validation succeeds, launch **Azure Local Sandbox Setup** again and choose **Deploy**. Completed stages and verified parent images are reused.

Microsoft documents Azure Local cloud deployment as a 2.5 to 3 hour operation. Individual steps can take 40 to 50 minutes.

## Command-Line Alternative

From an elevated Windows PowerShell 5.1 session on `LocalBox-Client`:

```powershell
Set-Location C:\AzureLocalSandbox\Source

$localCredential = Get-Credential -UserName 'Administrator'
$domainCredential = Get-Credential -UserName 'JUMPSTART\Administrator'
$lcmCredential = Get-Credential -UserName 'LocalBoxDeployUser'
```

To update the staged scripts from GitHub without touching downloaded media or deployment state, run this from an elevated PowerShell session on `LocalBox-Client`:

```powershell
Set-Location C:\AzureLocalSandbox\Source
./scripts/Update-SandboxSource.ps1
```

If the command is not found because the bastion was created before the updater was added, bootstrap it once with:

```powershell
$updater = Join-Path $env:TEMP 'Update-SandboxSource.ps1'
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/matthansen0/azure-local-sandbox/main/scripts/Update-SandboxSource.ps1' -OutFile $updater
& $updater -SourceRoot 'C:\AzureLocalSandbox\Source'
```

The updater downloads the `main` branch, overlays `C:\AzureLocalSandbox\Source`, and preserves `C:\AzureLocalSandbox\Media`, `C:\AzureLocalSandbox\State`, and `C:\AzureLocalSandbox\Artifacts`. Rerun the command after each pushed change, then continue with the normal command-line workflow below.

List ISO image indexes:

```powershell
./scripts/Convert-LabIsoMedia.ps1 `
  -WindowsServerIsoPath 'C:\AzureLocalSandbox\Media\WindowsServer2025.iso' `
  -AzureLocalIsoPath 'C:\AzureLocalSandbox\Media\AzureLocal.iso' `
  -ListImages
```

Choose the Windows Server index whose name ends in `(Desktop Experience)`. On evaluation media that is index 4, not index 3. Server Core indexes are rejected because the nested management host cannot install its Hyper-V management tools from them.

Run validation:

```powershell
./scripts/Invoke-SandboxDeployment.ps1 `
  -LocalAdministratorCredential $localCredential `
  -DomainAdministratorCredential $domainCredential `
  -LcmCredential $lcmCredential `
  -WindowsServerIsoPath 'C:\AzureLocalSandbox\Media\WindowsServer2025.iso' `
  -WindowsServerIsoSha256 '<trusted-sha256>' `
  -WindowsServerImageIndex <index> `
  -AzureLocalIsoPath 'C:\AzureLocalSandbox\Media\AzureLocal.iso' `
  -AzureLocalIsoSha256 '<trusted-sha256>' `
  -AzureLocalImageIndex <index>
```

After successful validation, rerun with credentials and `-Deploy`; media arguments are no longer required because verified images are reused.

Prebuilt generalized VHDX media is also supported through the `WindowsServerUri`, `WindowsServerSha256`, `AzureLocalUri`, and `AzureLocalSha256` parameters.

## Validation

Run repository checks from a development workstation:

```powershell
Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module Pester -RequiredVersion 6.0.1 -Scope CurrentUser -Force
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
./tests/Invoke-Tests.ps1
```

Run live checks inside `LocalBox-Client`:

```powershell
./scripts/Test-SandboxDeployment.ps1 `
  -LocalAdministratorCredential $localCredential

./scripts/Test-SandboxDeployment.ps1 `
  -LocalAdministratorCredential $localCredential `
  -RequireAzureLocalDeployment
```

Repository checks validate source and contracts. A real `Validate` and `Deploy` are still required to prove quota, policy, media, regional capacity, and service behavior in your tenant.
