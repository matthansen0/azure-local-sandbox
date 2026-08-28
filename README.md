# Azure Local Sandbox

Deploy a two-node Azure Local learning environment inside one Azure VM. The outer
Windows Server 2025 VM runs Hyper-V and hosts two Azure Local nodes plus a nested
management host for Active Directory, DNS, and routing.

## Project Origin

This project was inspired by [Arc Jumpstart](https://jumpstart.azure.com/) and
specifically [Jumpstart LocalBox](https://jumpstart.azure.com/azure_jumpstart_localbox).
Jumpstart remains available for use and exploration, but the program is now in
maintenance mode. This repository is an independent implementation and does not import
or execute Jumpstart code.

This project is intended for labs and demonstrations. Virtual Azure Local is not
supported by Microsoft Support and the environment is not suitable for production
workloads.

![Azure Local Sandbox architecture](docs/azure-local-sandbox-architecture.svg)

[Deployment guide](docs/DEPLOYMENT.md) |
[Troubleshooting](docs/TROUBLESHOOTING.md) |
[Technical reference](docs/TECHNICAL.md) |
[Stage contract](docs/STAGE-CONTRACT.md)

## What It Builds

- A private `Standard_E32s_v6` Azure VM with Bastion and NAT Gateway.
- `AzLHOST1` and `AzLHOST2` as nested Azure Local nodes.
- `AzLMGMT` as a nested Hyper-V host running `JumpstartDC` and `Vm-Router`.
- Active Directory, DNS, routing, Azure Arc registration, and Azure Local cloud deployment.
- A sandbox-owned Log Analytics workspace with a capped daily ingestion budget.
- A guided desktop setup for selecting licensed ISO media and resuming failed stages.

## Prerequisites

- An Azure subscription with sufficient permissions and `E32s` quota.
- PowerShell 7.2+, Azure CLI, and Git on the deployment workstation.
- Windows Server 2025 and Azure Local ISO media downloaded from authorized Microsoft sources.
- A clean Git commit containing the exact source being deployed.

The lab is expensive while running and continues to incur disk, Bastion, and NAT
charges while the VM is deallocated. The default `centralus` host region offers
the free Azure Bastion Developer SKU, which the deployment selects automatically.

Approximate pay-as-you-go costs (Central US, `Standard_E32s_v6` with 8× 1 TiB
Premium SSD data disks):

| State | Cost |
|---|---|
| Running | ~$3.90/hour |
| Deallocated | ~$1.70/hour |

Deallocated cost is disk charges only (9× P30). Deallocate the VM when not in use
and delete the resource group when the lab is no longer needed.

End-to-End, the deployment takes ~6 hours due to the serialized nature of an Azure Local deployment.

## Quick Start

Authenticate and select the subscription:

```powershell
az login
az account set --subscription '<subscription-id>'
```

Set the outer VM administrator password and deploy:

```powershell
$env:AZURE_LOCAL_SANDBOX_ADMIN_PASSWORD = '<strong-password>'

./scripts/Deploy.ps1 `
  -Mode Deploy `
  -Location centralus `
  -AzureLocalLocation eastus
```

The deployment installs Hyper-V, creates storage and networking, stages the exact
Git commit through temporary private Azure Storage, and reboots the VM once.

### Preflight, Validate, and Deploy

These are separate parts of the in-VM workflow:

| Action | When it runs | What it does |
| --- | --- | --- |
| **Preflight** | Automatically at the start of every **Validate** or **Deploy** run | Performs fast prerequisite checks for host readiness, configuration, managed-identity access, Azure Local region support, resource-group access, and a conflicting soft-deleted key vault. It does not build the nested environment. |
| **Validate** | Recommended for the first full in-VM run | Runs preflight, builds and configures the nested environment, registers the nodes with Arc, invokes Azure Local cloud validation, and runs live checks. It stops before Azure Local deployment. |
| **Deploy** | After a successful **Validate** run | Reuses the validated environment and completes Azure Local cloud deployment. If selected on the first run, it automatically performs **Validate** before deployment. |

**Validate** is therefore more than a prerequisite check. Running it separately creates
a review point before the additional 2.5-to-3-hour Azure Local deployment. Command-line
users can run only the prerequisite checks by passing `-PreflightOnly` to
`Invoke-SandboxDeployment.ps1`; see the [deployment guide](docs/DEPLOYMENT.md#command-line-alternative).

After deployment:

1. Connect to `LocalBox-Client` through Azure Bastion.
2. Download the Windows Server 2025 and Azure Local ISOs inside the VM.
3. Double-click **Azure Local Sandbox Setup** on the desktop.
4. Select both ISOs, choose their image indexes, and enter the requested credentials.
   The Windows Server index must be a `(Desktop Experience)` image.
5. Choose **Validate** first.
6. After validation succeeds, launch setup again and choose **Deploy**.

Cloud deployment normally takes 2.5 to 3 hours. Completed stages and verified
images are reused when setup is launched again.

See the [deployment guide](docs/DEPLOYMENT.md) for media requirements, regional
options, command-line setup, and validation commands.

## Project Status

[![repologbook.com](https://repoanalyticsprod4rquhaw.z19.web.core.windows.net/badges/N-oTHIKR4bsdkuh0IUTsHA.svg)](https://repologbook.com/)


## License

Licensed under the [MIT License](LICENSE). Microsoft products, services,
trademarks, operating-system media, and third-party dependencies remain subject
to their respective terms.
