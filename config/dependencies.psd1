@{
    SchemaVersion = 1

    AzureLocalQuickstart = @{
        Repository   = 'Azure/azure-quickstart-templates'
        Commit       = '227c21dce8cbf9c4d786a7b6bc5acd418dd113e9'
        TemplatePath = 'quickstarts/microsoft.azurestackhci/create-cluster/azuredeploy.json'
        Sha256       = 'A95BF9A734CC7433F171A31685193EA053941B24F33111BDDC9552CE20195F58'
    }

    PowerShellModules = @{
        AzAccounts                       = @{ Name = 'Az.Accounts'; Version = '5.5.1' }
        AzConnectedMachine               = @{ Name = 'Az.ConnectedMachine'; Version = '1.1.1' }
        AzResources                      = @{ Name = 'Az.Resources'; Version = '10.0.1' }
        AsHciADArtifactsPreCreationTool  = @{ Name = 'AsHciADArtifactsPreCreationTool'; Version = '10.2402' }
        Pester                           = @{ Name = 'Pester'; Version = '6.0.1' }
        PSScriptAnalyzer                 = @{ Name = 'PSScriptAnalyzer'; Version = '1.25.0' }
    }

    Bicep = @{
        Version     = '0.45.15'
        DownloadUri = 'https://github.com/Azure/bicep/releases/download/v0.45.15/bicep-linux-x64'
        Sha256      = 'FF5B194B042C220DF4A50D6768ED1D6C39A32894BFDC4FF83D62B115D966A7CE'
    }

    OuterHostImage = @{
        Publisher = 'MicrosoftWindowsServer'
        Offer     = 'WindowsServer'
        Sku       = '2025-datacenter-g2'
    }

    AzureLocal = @{
        # The Arc bootstrap service rejects any other region, and it only reports this once the
        # nodes are already built and registering, hours into a deployment.
        SupportedRegions = @(
            'australiaeast'
            'canadacentral'
            'centralindia'
            'eastus'
            'eastus2euap'
            'germanywestcentral'
            'japaneast'
            'southcentralus'
            'southeastasia'
            'westeurope'
        )
    }

    AzureBastion = @{
        # Regions offering the free Developer SKU, from includes/bastion-developer-regions.md in MicrosoftDocs/azure-docs.
        # Deploy.ps1 falls back to the Standard SKU for any other region, and also if Azure rejects the Developer SKU.
        DeveloperSkuRegions = @(
            'australiacentral'
            'australiaeast'
            'australiasoutheast'
            'brazilsouth'
            'canadacentral'
            'canadaeast'
            'centralindia'
            'centralus'
            'eastasia'
            'eastus2'
            'francecentral'
            'germanywestcentral'
            'italynorth'
            'japaneast'
            'japanwest'
            'koreacentral'
            'koreasouth'
            'mexicocentral'
            'northcentralus'
            'northeurope'
            'norwayeast'
            'southafricanorth'
            'southeastasia'
            'southindia'
            'spaincentral'
            'swedencentral'
            'switzerlandnorth'
            'uaenorth'
            'uksouth'
            'ukwest'
            'westcentralus'
            'westeurope'
            'westus'
        )
    }
}