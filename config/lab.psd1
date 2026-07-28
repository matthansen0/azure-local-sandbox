@{
    SchemaVersion = 2
    VmRoot        = 'V:\VMs'
    StateFile     = 'C:\AzureLocalSandbox\State\nested-vms.json'

    Domain = @{
        Fqdn                   = 'jumpstart.local'
        NetBiosName            = 'JUMPSTART'
        DomainControllerName   = 'JumpstartDC'
        DomainControllerIp     = '192.168.1.254'
        DeploymentUserName     = 'LocalBoxDeployUser'
        DeploymentOuName       = 'hcioudocs'
    }

    Networks = @{
        Management = @{ Prefix = '192.168.1.0/24'; PrefixLength = 24; Gateway = '192.168.1.1' }
        HostNat    = @{ Prefix = '192.168.128.0/24'; PrefixLength = 24; Gateway = '192.168.128.1' }
        InnerNat   = @{ Prefix = '192.168.46.0/24'; PrefixLength = 24; Gateway = '192.168.46.1' }
        Provider   = @{ Prefix = '172.16.0.0/24'; PrefixLength = 24; Gateway = '172.16.0.1'; VlanId = 12 }
        Vlan110    = @{ Prefix = '10.10.0.0/24'; PrefixLength = 24; Gateway = '10.10.0.1'; VlanId = 110 }
        Vlan200    = @{ Prefix = '192.168.200.0/24'; PrefixLength = 24; Gateway = '192.168.200.1'; VlanId = 200 }
        SimulatedInternet = @{ Prefix = '131.127.0.0/24'; PrefixLength = 24; Gateway = '131.127.0.1'; VlanId = 131 }
        StorageA   = @{ Prefix = '10.71.1.0/24'; PrefixLength = 24; VlanId = 711 }
        StorageB   = @{ Prefix = '10.71.2.0/24'; PrefixLength = 24; VlanId = 712 }
    }

    VMs = @(
        @{
            Name                  = 'AzLMGMT'
            Role                  = 'Management'
            ParentVhdPath         = 'V:\VHDs\WindowsServer2025.vhdx'
            MemoryStartupBytes    = 28GB
            ProcessorCount        = 20
            NestedVirtualization  = $true
            AutomaticStartDelay   = 0
            ManagementIpAddress   = '192.168.1.11'
            ManagementAdapterName = 'SDN'
            OfflineFeatures       = @('Hyper-V', 'RSAT-Hyper-V-Tools', 'Hyper-V-PowerShell')
            DataDisks             = @(250GB)
            StorageDisks          = @()
            NetworkAdapters       = @(
                @{ Name = 'SDN'; SwitchName = 'InternalSwitch'; VlanMode = 'Trunk'; NativeVlanId = 0; AllowedVlanIdList = '1-200' }
                @{ Name = 'SDN2'; SwitchName = 'InternalSwitch'; VlanMode = 'Trunk'; NativeVlanId = 0; AllowedVlanIdList = '1-200' }
                @{ Name = 'NAT'; SwitchName = 'InternalNAT'; VlanMode = 'Untagged' }
                @{ Name = 'PROVIDER'; SwitchName = 'InternalSwitch'; VlanMode = 'Access'; VlanId = 12 }
                @{ Name = 'VLAN110'; SwitchName = 'InternalSwitch'; VlanMode = 'Access'; VlanId = 110 }
                @{ Name = 'VLAN200'; SwitchName = 'InternalSwitch'; VlanMode = 'Access'; VlanId = 200 }
                @{ Name = 'simInternet'; SwitchName = 'InternalSwitch'; VlanMode = 'Access'; VlanId = 131 }
            )
        }
        @{
            Name                  = 'AzLHOST1'
            Role                  = 'AzureLocalNode'
            ParentVhdPath         = 'V:\VHDs\AzureLocal.vhdx'
            MemoryStartupBytes    = 96GB
            ProcessorCount        = 20
            NestedVirtualization  = $true
            AutomaticStartDelay   = 300
            ManagementIpAddress   = '192.168.1.12'
            ManagementAdapterName = 'SDN'
            OfflineFeatures       = @('Hyper-V', 'RSAT-Hyper-V-Tools', 'Hyper-V-PowerShell', 'Failover-Clustering', 'RSAT-Clustering-PowerShell')
            DataDisks             = @(250GB)
            StorageDisks          = @(170GB, 170GB, 170GB, 170GB, 170GB, 170GB)
            NetworkAdapters       = @(
                @{ Name = 'SDN'; SwitchName = 'InternalSwitch'; VlanMode = 'Trunk'; NativeVlanId = 0; AllowedVlanIdList = '1-200' }
                @{ Name = 'StorageA'; SwitchName = 'InternalSwitch'; VlanMode = 'Trunk'; NativeVlanId = 0; AllowedVlanIdList = '1-800' }
                @{ Name = 'StorageB'; SwitchName = 'InternalSwitch'; VlanMode = 'Trunk'; NativeVlanId = 0; AllowedVlanIdList = '1-800' }
            )
        }
        @{
            Name                  = 'AzLHOST2'
            Role                  = 'AzureLocalNode'
            ParentVhdPath         = 'V:\VHDs\AzureLocal.vhdx'
            MemoryStartupBytes    = 96GB
            ProcessorCount        = 20
            NestedVirtualization  = $true
            AutomaticStartDelay   = 300
            ManagementIpAddress   = '192.168.1.13'
            ManagementAdapterName = 'SDN'
            OfflineFeatures       = @('Hyper-V', 'RSAT-Hyper-V-Tools', 'Hyper-V-PowerShell', 'Failover-Clustering', 'RSAT-Clustering-PowerShell')
            DataDisks             = @(250GB)
            StorageDisks          = @(170GB, 170GB, 170GB, 170GB, 170GB, 170GB)
            NetworkAdapters       = @(
                @{ Name = 'SDN'; SwitchName = 'InternalSwitch'; VlanMode = 'Trunk'; NativeVlanId = 0; AllowedVlanIdList = '1-200' }
                @{ Name = 'StorageA'; SwitchName = 'InternalSwitch'; VlanMode = 'Trunk'; NativeVlanId = 0; AllowedVlanIdList = '1-800' }
                @{ Name = 'StorageB'; SwitchName = 'InternalSwitch'; VlanMode = 'Trunk'; NativeVlanId = 0; AllowedVlanIdList = '1-800' }
            )
        }
    )
}