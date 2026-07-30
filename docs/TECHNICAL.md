# Technical Reference

Return to the [project overview](../README.md), [deployment guide](DEPLOYMENT.md), or [troubleshooting](TROUBLESHOOTING.md).

## Architecture

```text
Azure subscription
└── Sandbox resource group
    ├── VNet 172.31.0.0/16
    │   ├── Private host subnet + NAT Gateway
    │   └── Azure Bastion subnet
    └── LocalBox-Client (Windows Server 2025, Hyper-V)
        ├── AzLHOST1 (Azure Local node)
        ├── AzLHOST2 (Azure Local node)
        └── AzLMGMT (Windows Server 2025, nested Hyper-V)
            ├── JumpstartDC (AD DS, DNS, HCI deployment OU)
            └── Vm-Router (RRAS and NAT)
```

The editable diagram is [azure-local-sandbox-architecture.excalidraw](azure-local-sandbox-architecture.excalidraw).

## Networks

| Layer | Network | Purpose |
| --- | --- | --- |
| Azure VNet | `172.31.0.0/16` | Outer host and Bastion |
| Hyper-V management | `192.168.1.0/24` | Nodes, management VM, router, and domain controller |
| Host NAT | `192.168.128.0/24` | Bootstrap egress for `AzLMGMT` |
| Inner NAT | `192.168.46.0/24` | Egress for management-plane VMs |
| Provider VLAN 12 | `172.16.0.0/24` | Nested provider network |
| Workload VLAN 110 | `10.10.0.0/24` | AKS and workload network |
| Workload VLAN 200 | `192.168.200.0/24` | VM logical network |
| Simulated Internet VLAN 131 | `131.127.0.0/24` | SDN test network |
| Storage VLANs 711/712 | `10.71.1.0/24`, `10.71.2.0/24` | East-west storage traffic |

All outer and nested CIDRs must remain disjoint.

## Automation Stages

1. Deploy the Azure resource group, VNet, NAT Gateway, Bastion, host VM, identity, and disks.
2. Install Hyper-V, combine data disks into a ReFS volume, and create host switches.
3. Verify or convert operating-system media.
4. Create `AzLMGMT`, `AzLHOST1`, and `AzLHOST2` with differencing disks.
5. Install offline Windows features and first-boot specialization.
6. Configure level-one networking, storage, and nested Hyper-V.
7. Create and configure `JumpstartDC` and `Vm-Router`.
8. Prepare AD objects and register both Azure Local nodes with Arc.
9. Run the pinned Microsoft Quickstart in `Validate` mode.
10. Run `Deploy` and live validation after review.

## Configuration

[config/lab.psd1](../config/lab.psd1) owns:

- VM sizing and parent disk paths.
- Domain and deployment-user names.
- IP ranges and VLANs.
- Node adapters and storage disks.

Keep:

- Two Azure Local nodes for this profile.
- Adapter names `FABRIC`, `StorageA`, and `StorageB` aligned with cloud intents.
- At least 16 GiB free for the outer host after nested VM allocation.
- WDAC disabled for this unsupported nested lab profile.
- A unique LCM account and OU for each instance.

[config/dependencies.psd1](../config/dependencies.psd1) pins:

- Microsoft Azure Local Quickstart commit and SHA-256.
- Bicep version and binary SHA-256.
- PowerShell module versions.
- Outer host marketplace image coordinates.

Dependency updates are explicit maintenance actions followed by local tests and a real Azure `Validate` deployment.

## Runtime Dependencies

There is no runtime import or execution from the retired `microsoft/azure_arc` or `Azure/arc_jumpstart_docs` repositories. They are methodology references only.

Runtime dependencies include:

- Azure Resource Manager, Microsoft Entra ID, Azure Arc, Azure Local, Storage, Key Vault, and Bastion.
- `Invoke-AzStackHciArcInitialization` from the Azure Local OS image.
- Pinned PowerShell Gallery modules.
- Pinned Microsoft Azure Local Quickstart template.
- Azure CLI, Bicep, Git, and PowerShell on the deployment workstation.
- User-supplied licensed Windows Server and Azure Local media.

## Source Artifact Chain

`scripts/Deploy.ps1` requires a clean Git commit that has been pushed. In `Deploy` mode it:

1. Resolves the exact commit and confirms it exists on a remote branch.
2. Builds immutable `raw.githubusercontent.com` and `codeload.github.com` URLs pinned to that commit SHA.
3. Downloads both artifacts and computes their SHA-256 values.
4. Passes the URLs through secure Bicep parameters.
5. Verifies both hashes again on the VM before executing anything.

Custom immutable HTTPS artifact URLs can be supplied instead.

## Identity And Secrets

- `LocalBox-Client` uses a system-assigned managed identity.
- The identity receives sandbox-resource-group-scoped permissions required for registration and the maintained cluster template.
- Arc initialization uses a short-lived ARM token sent through PowerShell Direct.
- Local and LCM passwords are passed to ARM as in-memory `SecureString` parameters.
- State JSON does not contain credential values.
- State files are resume markers, not a security boundary.

## Security And Cost

- The host has no public IP; Bastion is the default ingress.
- NAT Gateway provides explicit outbound access.
- Bootstrap, source archive, media, and Quickstart artifacts are hash-verified.
- The lab uses a 32-vCPU host, 1-TiB OS disk, eight Premium SSDs, Bastion, and NAT Gateway.
- Deallocating the VM does not stop disk, Bastion, or NAT charges.
- Spot pricing is intentionally unsupported.

This is an educational virtual deployment and is unsupported by Microsoft Support.

## Methodology And Attribution

The implementation is informed by:

- [Azure Jumpstart LocalBox](https://jumpstart.azure.com/azure_jumpstart_localbox)
- [Azure Arc Jumpstart documentation](https://github.com/Azure/arc_jumpstart_docs)
- [Jumpstart implementation](https://github.com/microsoft/azure_arc/tree/main/azure_jumpstart_localbox)
- [Azure Local ARM template deployment](https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template)
- [Download Azure Local software](https://learn.microsoft.com/azure/azure-local/deploy/download-23h2-software)
- [Deploy a virtual Azure Local system](https://learn.microsoft.com/azure/azure-local/deploy/deployment-virtual)
- [Maintained Azure Local Quickstart template](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.azurestackhci/create-cluster)

This repository is an independent clean-room implementation. It uses supported Microsoft product cmdlets for AD preparation, Arc initialization, and cluster deployment rather than copying the retired LocalBox PowerShell Gallery module.
