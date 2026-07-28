# Azure Local Sandbox

An independent, infrastructure-as-code implementation of the Azure Arc
Jumpstart LocalBox methodology. One Azure VM runs Hyper-V, two nested VMs act as
Azure Local machines, and a third nested Hyper-V host runs Active Directory and
routing services for the lab.

The end-to-end automation is implemented. It provisions the Azure host, verifies
and specializes user-supplied operating-system images, builds both virtualization
levels, prepares Active Directory, registers the Azure Local machines with Azure
Arc, validates the system with Microsoft's maintained deployment template, and
optionally deploys the Azure Local instance.

The implementation has passed static analysis, Bicep compilation, architecture
tests, secret scans, and contract tests against a pinned Microsoft Quickstart
template. It has **not** yet completed a real paid Azure deployment with licensed
media from this repository. That final integration test requires an Azure
subscription, quota, accepted license terms, downloaded media, and several hours
of billable runtime.

This is a sandbox for learning and testing. It is not an official Microsoft
deliverable and is not intended for production workloads.

## Architecture

![Azure Local Sandbox architecture and guided deployment workflow](docs/azure-local-sandbox-architecture.svg)

[Open the editable Excalidraw scene](docs/azure-local-sandbox-architecture.excalidraw)
| [SVG preview](docs/azure-local-sandbox-architecture.svg)
| [PNG preview](docs/azure-local-sandbox-architecture.png)

```text
Azure subscription
└── Sandbox resource group
    ├── VNet 172.31.0.0/16
    │   ├── Private host subnet + NAT Gateway
    │   └── Azure Bastion subnet (optional)
    └── LocalBox-Client (Windows Server 2025, Hyper-V)
        ├── AzLHOST1 (Azure Local node)
        ├── AzLHOST2 (Azure Local node)
        └── AzLMGMT (Windows Server 2025, nested Hyper-V)
            ├── JumpstartDC (AD DS, DNS, HCI deployment OU)
            └── Vm-Router (RRAS and NAT)
```

The Azure VNet and every nested network are deliberately disjoint:

| Layer | Network | Purpose |
| --- | --- | --- |
| Azure VNet | `172.31.0.0/16` | Outer host and Bastion |
| Hyper-V management | `192.168.1.0/24` | Nodes, `AzLMGMT`, router, and domain controller |
| Host NAT | `192.168.128.0/24` | Bootstrap egress for `AzLMGMT` |
| Inner NAT | `192.168.46.0/24` | Egress for management-plane VMs |
| Provider VLAN 12 | `172.16.0.0/24` | Nested provider network |
| Workload VLAN 110 | `10.10.0.0/24` | AKS and workload network |
| Workload VLAN 200 | `192.168.200.0/24` | VM logical network |
| Simulated Internet VLAN 131 | `131.127.0.0/24` | SDN test network |
| Storage VLANs 711/712 | `10.71.1.0/24`, `10.71.2.0/24` | East-west storage traffic |

## Deployment Stages

The workflow is intentionally staged and resumable:

1. Deploy the private Azure host, managed identity, disks, networking, NAT, and
   optional Bastion with Bicep.
2. Install Hyper-V, combine Azure data disks into a striped ReFS volume, and
   create the outer Hyper-V switches.
3. Download both parent VHDX images over HTTPS and verify mandatory SHA-256
   checksums.
4. Create `AzLMGMT`, `AzLHOST1`, and `AzLHOST2` as generation-2 differencing-disk
   VMs.
5. Install offline Windows features and inject first-boot specialization data.
6. Configure level-one storage, static networking, nested Hyper-V, and copy the
   verified Windows Server parent image into `AzLMGMT`.
7. Create `JumpstartDC` and `Vm-Router`; configure RRAS, NAT, AD DS, DNS, time,
   and Azure Local deployment objects with Microsoft's
   `AsHciADArtifactsPreCreationTool`.
8. Check Azure Local node readiness and register both nodes with Azure Arc using
   `Invoke-AzStackHciArcInitialization` and a short-lived managed-identity token.
9. Generate all parameters for Microsoft's maintained `create-cluster`
   Quickstart template and run `Validate`.
10. After validation succeeds, run the template in `Deploy` mode and perform
    live Hyper-V, DNS, Arc, and Azure Local resource checks.

Each successful stage writes nonsecret state under
`C:\AzureLocalSandbox\State`. Rerunning the orchestrator skips completed stages.
These files are resumability markers for administrators, not signed security
evidence. Protect local administrator access to `LocalBox-Client`; the live final
validator queries Hyper-V and Azure rather than treating state alone as proof.

## Prerequisites

### Azure

- An Azure subscription where the deploying user can register resource
  providers, create role assignments, and deploy resources. Subscription
  `Owner` without restrictive assignment conditions is the simplest sandbox
  permission model.
- Quota and availability for `Standard_E32s_v5` or `Standard_E32s_v6` in the
  outer host region.
- An Azure Local-supported registration region. The examples use `eastus`.
- Policies that permit VM extensions, managed identities, Key Vault, storage,
  Hybrid Compute, Azure Local, and role assignments.
- Direct outbound HTTPS access. Proxy and Azure Arc Gateway modes are not yet
  implemented by this sandbox workflow.

The host deployment registers the Microsoft resource-provider baseline required
by the current Azure Local documentation.

### Deployment workstation

- Azure CLI with Bicep support.
- PowerShell 7.2 or later for `scripts/Deploy.ps1`.
- An authenticated Azure CLI session targeting the intended subscription.

### Operating-system media

Microsoft distributes Azure Local lab media as an ISO from the Azure portal after
you select a subscription, accept the license terms, and choose a supported
version. This repository cannot accept those terms or download that licensed
media on your behalf.

The workflow accepts either:

- Locally downloaded Windows Server and Azure Local ISO files. The automation
  verifies trusted expected SHA-256 values and converts selected image
  indexes into generalized generation-2 UEFI VHDX parent disks.
- Authorized, already generalized generation-2 VHDX images available over HTTPS,
  each with a publisher-provided SHA-256 value.

Provide media for:

- Windows Server 2025 Datacenter.
- A supported Azure Local release, preferably the current 2604 release.

The repository does not redistribute operating-system images, product keys, or
licenses. Obtain media through Microsoft-authorized channels. Use an authoritative
publisher SHA-256 when one is supplied; otherwise calculate and record the digest
on the trusted download workstation before transferring media to the host. Image
URLs may be short-lived SAS URLs.

For Azure Local ISO media, use **Azure portal > Azure Local > Get started >
Download software**, select a supported release, accept the license terms, and
download the ISO. Obtain Windows Server 2025 through your licensed Microsoft
channel or the [Microsoft Evaluation Center](https://www.microsoft.com/evalcenter/download-windows-server-2025),
then record the published checksums before copying media to the host. Microsoft's
virtual-deployment guidance states that virtual Azure Local is
educational/demo-only and unsupported by Microsoft Support.

### Credentials

The nested workflow prompts for three credentials and does not store their plain
text values in configuration or state:

| Credential | Username | Requirements and use |
| --- | --- | --- |
| Local administrator | `Administrator` | At least 14 characters; used by `AzLMGMT`, both Azure Local nodes, and `Vm-Router` |
| Domain administrator | `JUMPSTART\Administrator` | At least 14 characters; initializes `JumpstartDC`, then becomes the forest Administrator password |
| LCM deployment user | `LocalBoxDeployUser` | At least 14 characters with Azure Local complexity requirements; created by Microsoft's AD preparation tool |

The LCM username is configurable in `config/lab.psd1`, but it must be 1-20
characters, cannot contain `admin`, and cannot begin with a number or hyphen.

Windows unattended setup temporarily receives the applicable administrator
password in Microsoft's encoded unattend format. `SetupComplete.cmd` deletes the
source unattend files after first boot. Deployment scripts retain credentials
only in memory and do not include them in state JSON or deployment outputs.

## Deploy The Azure Host

Authenticate and select the subscription:

```powershell
az login
az account set --subscription '<subscription-id>'
```

Set the outer Azure VM administrator password in the current process. Bicep
reads it as a `secureString`; it is not passed to host bootstrap or emitted as an
output.

```powershell
$env:AZURE_LOCAL_SANDBOX_ADMIN_PASSWORD = '<strong-password>'
```

Preview the deployment:

```powershell
./scripts/Deploy.ps1 -Mode WhatIf -Location eastus
```

On a subscription where `Microsoft.AzureStackHCI` has never been registered,
the tenant-specific resource-provider service principal might not exist yet.
Register that provider before the first side-effect-free preview, pass
`-HciResourceProviderObjectId`, or proceed with `-Mode Deploy`, which registers
the complete provider baseline before resolving the identity.

Deploy the host:

```powershell
./scripts/Deploy.ps1 -Mode Deploy -Location eastus
```

If the outer VM region differs from the Azure Local registration region, pass
both explicitly:

```powershell
./scripts/Deploy.ps1 `
  -Mode Deploy `
  -Location westus3 `
  -AzureLocalLocation eastus
```

The wrapper resolves the tenant-specific Azure Local resource-provider object ID
and supplies it to Bicep automatically. In tenants that restrict service
principal lookup, retrieve the object ID through an approved administrator and
pass `-HciResourceProviderObjectId '<guid>'`. The lookup uses Microsoft's Azure
Local resource-provider application ID
`1412d89f-b8a8-4111-b4fd-e82905cbd85d`.

`scripts/Deploy.ps1` packages the exact clean Git commit locally and refuses a
dirty worktree. In `Deploy` mode it uploads `Bootstrap.ps1` and the commit archive
to a temporary private Azure Storage account, supplies 24-hour read-only SAS URLs
to the VM extension through secure Bicep parameters, and removes the staging
account when deployment finishes. SAS URLs are not passed as Azure CLI arguments
or retained as readable deployment parameters.
This works with the private GitHub repository and does not require Git on the
host. `WhatIf` and `Validate` remain nonpersistent. Private or custom artifact
hosting can instead be supplied with both `-BootstrapScriptUri` and
`-SourceArchiveUri`. Direct Bicep use requires setting the four artifact URI/hash
environment variables consumed by `infra/main.bicepparam`.

Bootstrap installs Hyper-V and schedules one reboot. Azure deployment completion
means the extension successfully scheduled host preparation; post-reboot work
can still be running. Connect through Azure Bastion and verify:

```powershell
./scripts/Test-HostReadiness.ps1
Get-Content C:\AzureLocalSandbox\State\bootstrap.json
```

The expected phase is `HostReady`. Bootstrap logs are written to
`C:\AzureLocalSandbox\Logs\Bootstrap.log`.
Host readiness also checks Windows Server 2025, virtualization firmware exposure,
at least 256 GiB RAM, at least 1.5 TiB free on the nested VM volume, required
switches/NAT, and the staged source tree.

## Run The Sandbox Workflow

### Recommended: guided desktop setup

After `Test-HostReadiness.ps1` passes:

1. Connect to `LocalBox-Client` through Azure Bastion.
2. Download the Windows Server 2025 ISO from your licensed Microsoft channel or
  Evaluation Center.
3. In Azure portal, go to **Azure Local > Get started > Download software**,
  select the deployment subscription and version, accept the license terms, and
  download the Azure Local ISO.
4. Double-click **Azure Local Sandbox Setup** on the public desktop.
5. Approve the elevation prompt and select both ISO files. The wizard calculates
  their SHA-256 digests, asks you to confirm their trusted origin, lists the
  installation image indexes, and prompts for the three nested credentials.
6. Choose **Validate** for the recommended first run. After reviewing successful
  cloud validation, launch the shortcut again and choose **Deploy**. Verified
  images and completed stages are reused.

The guided script is `scripts/Start-SandboxSetup.ps1`. Bootstrap stages the
source under `C:\AzureLocalSandbox\Source`, creates
`C:\AzureLocalSandbox\Media`, and installs the public desktop shortcut. The
wizard opens Microsoft download guidance when media paths are not supplied.

### Command-line setup

For automation or troubleshooting, open an elevated Windows PowerShell 5.1
session in the source directory staged by bootstrap, then collect credentials
without putting passwords on the command line:

```powershell
Set-Location C:\AzureLocalSandbox\Source
$localCredential = Get-Credential -UserName 'Administrator'
$domainCredential = Get-Credential -UserName 'JUMPSTART\Administrator'
$lcmCredential = Get-Credential -UserName 'LocalBoxDeployUser'
```

### Use local ISO media

Copy both downloaded ISO files onto `LocalBox-Client`. List the available image
indexes before conversion:

```powershell
./scripts/Convert-LabIsoMedia.ps1 `
  -WindowsServerIsoPath 'C:\Media\WindowsServer2025.iso' `
  -AzureLocalIsoPath 'C:\Media\AzureLocal.iso' `
  -ListImages
```

Then run through verified ISO conversion, both virtualization layers, management
services, Arc registration, and Azure Local validation:

```powershell
./scripts/Invoke-SandboxDeployment.ps1 `
  -LocalAdministratorCredential $localCredential `
  -DomainAdministratorCredential $domainCredential `
  -LcmCredential $lcmCredential `
  -WindowsServerIsoPath 'C:\Media\WindowsServer2025.iso' `
  -WindowsServerIsoSha256 '<64-character-trusted-sha256>' `
  -WindowsServerImageIndex <index> `
  -AzureLocalIsoPath 'C:\Media\AzureLocal.iso' `
  -AzureLocalIsoSha256 '<64-character-trusted-sha256>' `
  -AzureLocalImageIndex <index>
```

ISO conversion is a clean installation-image application suitable for this lab;
it does not replace an OEM golden image for supported physical hardware.

### Use prebuilt VHDX media

Alternatively, run through VHDX download/verification and the remaining stages:

```powershell
./scripts/Invoke-SandboxDeployment.ps1 `
  -LocalAdministratorCredential $localCredential `
  -DomainAdministratorCredential $domainCredential `
  -LcmCredential $lcmCredential `
  -WindowsServerUri 'https://<authorized-windows-server-vhdx-url>' `
  -WindowsServerSha256 '<64-character-sha256>' `
  -AzureLocalUri 'https://<authorized-azure-local-vhdx-url>' `
  -AzureLocalSha256 '<64-character-sha256>'
```

Validation creates prerequisite Azure resources and normally takes at least ten
minutes. Review its result before starting the destructive, long-running cluster
deployment. Then rerun with `-Deploy`; completed stages are skipped:

```powershell
./scripts/Invoke-SandboxDeployment.ps1 `
  -LocalAdministratorCredential $localCredential `
  -DomainAdministratorCredential $domainCredential `
  -LcmCredential $lcmCredential `
  -Deploy
```

Microsoft documents Azure Local cloud deployment as a 2.5-3 hour operation.
Several individual deployment steps can take 40-50 minutes without being stuck.

If Arc registration should update the nodes to a specific supported solution
version, supply `-TargetSolutionVersion '<version>'` on the first run.

## Resume And Repair

On failure, correct the reported condition and rerun the same orchestrator
command. Successful stages are discovered from state files and skipped.

To deliberately rerun a convergent stage, use one or more `-ForceStage` values:

```powershell
./scripts/Invoke-SandboxDeployment.ps1 `
  -LocalAdministratorCredential $localCredential `
  -DomainAdministratorCredential $domainCredential `
  -LcmCredential $lcmCredential `
  -ForceStage ManagementPlane,ArcRegistration
```

Available stages are `Images`, `NestedVMs`, `GuestDisks`, `LevelOne`,
`ManagementPlane`, `ArcRegistration`, `Validation`, and `Deployment`.

The orchestrator refuses to force `Images` after differencing disks exist and
refuses to force `GuestDisks` after first boot. Rebuild the nested VMs for either
case. Do not rerun Azure Local `Validate` after Microsoft reports the system in a
deployment-failed state unless the documented recovery procedure calls for it.
The deployment script intentionally requires a successful deterministic
`azure-local-validate` deployment before `Deploy`.

Useful diagnostics:

```powershell
Get-ChildItem C:\AzureLocalSandbox\State\*.json |
  ForEach-Object { Get-Content $_ -Raw | ConvertFrom-Json }

Get-Content C:\AzureLocalSandbox\Logs\Bootstrap.log
Get-AzResourceGroupDeployment -ResourceGroupName 'rg-azure-local-sandbox'
```

## Validation

Run host-only checks before creating nested VMs:

```powershell
./scripts/Test-HostReadiness.ps1
```

Run full live checks after validation or deployment:

```powershell
./scripts/Test-SandboxDeployment.ps1 `
  -LocalAdministratorCredential $localCredential

./scripts/Test-SandboxDeployment.ps1 `
  -LocalAdministratorCredential $localCredential `
  -RequireAzureLocalDeployment
```

The full validator checks stage state, VM power and processor configuration,
network adapters, workgroup/domain state, DNS, Azure egress, RRAS, live Arc
machine status, and the live Azure Local cluster provisioning state.

Repository validation compiles all Bicep, runs PSScriptAnalyzer, checks topology
and CIDR invariants, and compares all generated cloud parameters with Microsoft's
pinned, reviewed Quickstart schema:

```powershell
Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module Pester -RequiredVersion 6.0.1 -Scope CurrentUser -Force
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
./tests/Invoke-Tests.ps1
```

Validation is intentionally local and is not configured as a GitHub Actions
workflow. Run `tests/Invoke-Tests.ps1` before each release or dependency update.

These checks validate source correctness and current API/template contracts. They
cannot prove that Azure quota, policies, regional capacity, Microsoft service
behavior, a particular ISO build, or a multi-hour Azure Local deployment will
succeed in your tenant. `Validate` and then a real `Deploy` are the integration
tests for those environment-specific conditions.

## Runtime Dependencies

There is no runtime download, import, or execution from the retired
`microsoft/azure_arc` or `Azure/arc_jumpstart_docs` repositories. Those links are
attribution and methodology references only. Names such as `LocalBox-Client` and
`jumpstart.local` are local defaults, not upstream dependencies.

Current runtime dependencies are:

- An immutable local Git commit packaged and staged by `scripts/Deploy.ps1`, or
  equivalent HTTPS URLs supplied in `infra/main.bicepparam`.
- Azure Resource Manager, Microsoft Entra ID, Azure Arc, and Azure Local service
  endpoints.
- Microsoft's Azure Local cmdlet `Invoke-AzStackHciArcInitialization`, included
  with the Azure Local OS image.
- PowerShell Gallery for pinned `Az.Accounts`, `Az.Resources`,
  `Az.ConnectedMachine`, and `AsHciADArtifactsPreCreationTool` versions.
- A pinned commit and SHA-256 of Microsoft's maintained Azure Local Quickstart
  template.
- Azure CLI and Bicep for outer-host deployment. Local tests pin and verify the
  Bicep binary; `scripts/Deploy.ps1` installs and verifies that same pinned Bicep
  version through Azure CLI before validation.
  The wrapper also resolves an exact Windows Server marketplace image version
  and passes that immutable version to Bicep instead of using `latest`.
- User-supplied, licensed Windows Server and Azure Local ISO or generalized VHDX
  media with SHA-256 values.

Reviewed versions and hashes live in `config/dependencies.psd1`. Updating one is
an explicit maintenance action followed by `./tests/Invoke-Tests.ps1` and a live
Azure `Validate` deployment.

## Security And Cost

- `LocalBox-Client` has no public IP. Azure Bastion is enabled by default.
- The host identity receives `Owner`, Key Vault Data Access Administrator, and
  Key Vault Secrets Officer only on the sandbox resource group. These permissions
  are required for Azure Local registration and the maintained cluster template.
- Arc initialization uses a short-lived ARM token obtained by the host managed
  identity. The token is sent through PowerShell Direct and is not written to
  state.
- Cloud deployment passes local and LCM passwords as in-memory `SecureString`
  template parameters. No generated parameter JSON contains their values.
- The lab is expensive: a 32-vCPU host, 1-TiB OS disk, eight Premium SSDs,
  Bastion, and NAT Gateway. Deallocating the VM does not stop disk, Bastion, or
  NAT charges.
- Spot pricing is intentionally unsupported because eviction can corrupt a
  multi-layer cluster lab.

Delete the entire sandbox resource group when the environment is no longer
needed:

```powershell
az group delete --name rg-azure-local-sandbox --yes --no-wait
```

## Configuration

`config/lab.psd1` owns VM sizing, network ranges, VLANs, domain naming, parent
image paths, and Azure Local node topology. Changes are validated but are not
guaranteed to be supported by Azure Local. In particular:

- Keep all outer and nested CIDRs disjoint.
- Keep two Azure Local nodes for this template profile.
- Keep `FABRIC`, `StorageA`, and `StorageB` adapter names aligned with the cloud
  deployment intents.
- Keep WDAC disabled for this nested lab profile, matching the proven LocalBox
  deployment parameters. This is one reason the environment is not production.
- Ensure the three nested VMs leave at least 16 GiB for the outer host.
- Use a unique LCM account and OU for each Azure Local instance.

## Methodology And Attribution

The architecture and deployment sequencing are informed by:

- [Azure Jumpstart LocalBox](https://jumpstart.azure.com/azure_jumpstart_localbox)
- [Azure Arc Jumpstart documentation](https://github.com/Azure/arc_jumpstart_docs)
- [Jumpstart implementation](https://github.com/microsoft/azure_arc/tree/main/azure_jumpstart_localbox)
- [Azure Local ARM template deployment](https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template)
- [Download Azure Local software](https://learn.microsoft.com/azure/azure-local/deploy/download-23h2-software)
- [Deploy a virtual Azure Local system](https://learn.microsoft.com/azure/azure-local/deploy/deployment-virtual)
- [Maintained Azure Local Quickstart template](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.azurestackhci/create-cluster)

This repository is a clean-room, smaller implementation of the documented
methodology. It uses supported Microsoft product cmdlets for AD preparation, Arc
initialization, and cluster deployment rather than copying the retired LocalBox
PowerShell Gallery module.

## License

The source code and documentation in this repository are available under the
[MIT License](LICENSE). Microsoft products, services, trademarks, operating-system
media, and third-party dependencies remain subject to their respective terms.
