BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $dependencies = Import-PowerShellDataFile (Join-Path $repoRoot 'config/dependencies.psd1')
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
    New-Item -Path $fixtureRoot -ItemType Directory | Out-Null

    @{
        subscriptionId              = '00000000-0000-0000-0000-000000000001'
        tenantId                    = '00000000-0000-0000-0000-000000000002'
        resourceGroupName           = 'rg-azure-local-contract-test'
        azureLocation               = 'eastus'
        hciResourceProviderObjectId = '00000000-0000-0000-0000-000000000003'
    } | ConvertTo-Json | Set-Content (Join-Path $fixtureRoot 'context.json')

    @{
        phase    = 'AzureLocalNodesArcConnected'
        machines = @(
            @{
                Name       = 'AzLHOST1'
                ResourceId = '/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.HybridCompute/machines/AzLHOST1'
                Status     = 'Connected'
            }
            @{
                Name       = 'AzLHOST2'
                ResourceId = '/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.HybridCompute/machines/AzLHOST2'
                Status     = 'Connected'
            }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $fixtureRoot 'arc.json')

    @{
        phase               = 'ManagementPlaneReady'
        ouDistinguishedName = 'OU=hcioudocs,DC=jumpstart,DC=local'
    } | ConvertTo-Json | Set-Content (Join-Path $fixtureRoot 'management.json')

    $plainTextFixturePassword = 'Validation-Only-42!'
    $secureFixturePassword = ConvertTo-SecureString $plainTextFixturePassword -AsPlainText -Force
    $localCredential = [PSCredential]::new('Administrator', $secureFixturePassword)
    $lcmCredential = [PSCredential]::new('LocalBoxDeployUser', $secureFixturePassword)

    $generatedParameters = & (Join-Path $repoRoot 'scripts/Deploy-AzureLocal.ps1') `
        -Mode Validate `
        -LocalAdministratorCredential $localCredential `
        -LcmCredential $lcmCredential `
        -ConfigurationPath (Join-Path $repoRoot 'config/lab.psd1') `
        -DeploymentContextPath (Join-Path $fixtureRoot 'context.json') `
        -ArcStatePath (Join-Path $fixtureRoot 'arc.json') `
        -ManagementStatePath (Join-Path $fixtureRoot 'management.json') `
        -ArtifactsPath (Join-Path $fixtureRoot 'artifacts') `
        -GenerateParametersOnly

    $quickstartDependency = $dependencies.AzureLocalQuickstart
    $maintainedTemplateUri = "https://raw.githubusercontent.com/$($quickstartDependency.Repository)/$($quickstartDependency.Commit)/$($quickstartDependency.TemplatePath)"
    $templateDownloadPath = Join-Path $fixtureRoot 'pinned-template.json'
    Invoke-WebRequest -Uri $maintainedTemplateUri -OutFile $templateDownloadPath
    $maintainedTemplateHash = (Get-FileHash -LiteralPath $templateDownloadPath -Algorithm SHA256).Hash
    $maintainedTemplate = Get-Content -LiteralPath $templateDownloadPath -Raw | ConvertFrom-Json
}

AfterAll {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Maintained Azure Local Quickstart contract' {
    It 'uses the reviewed immutable template revision' {
        $quickstartDependency.Commit | Should -Match '^[0-9a-f]{40}$'
        $quickstartDependency.Sha256 | Should -Match '^[A-F0-9]{64}$'
        $maintainedTemplateHash | Should -Be $quickstartDependency.Sha256
        $maintainedTemplate.parameters.PSObject.Properties.Name | Should -Contain 'deploymentMode'
    }

    It 'generates every template parameter and no unknown parameters' {
        $expectedNames = @($maintainedTemplate.parameters.PSObject.Properties.Name | Sort-Object)
        $actualNames = @($generatedParameters.Keys | Sort-Object)

        @($expectedNames | Where-Object { $_ -notin $actualNames }).Count | Should -Be 0
        @($actualNames | Where-Object { $_ -notin $expectedNames }).Count | Should -Be 0
    }

    It 'uses exactly two connected Arc node resource IDs' {
        @($generatedParameters.arcNodeResourceIds).Count | Should -Be 2
        $generatedParameters.arcNodeResourceIds[0] | Should -Match 'AzLHOST1$'
        $generatedParameters.arcNodeResourceIds[1] | Should -Match 'AzLHOST2$'
    }

    It 'generates the expected physical node topology' {
        @($generatedParameters.physicalNodesSettings).Count | Should -Be 2
        $generatedParameters.physicalNodesSettings[0].name | Should -Be 'AzLHOST1'
        $generatedParameters.physicalNodesSettings[0].ipv4Address | Should -Be '192.168.1.12'
        $generatedParameters.physicalNodesSettings[1].name | Should -Be 'AzLHOST2'
        $generatedParameters.physicalNodesSettings[1].ipv4Address | Should -Be '192.168.1.13'
    }

    It 'uses a file share witness and switchless two-node networking' {
        # A cloud witness needs the storage account key, so the generated data selects no witness and the
        # template is patched to FileShare after its hash is verified.
        $generatedParameters.witnessType | Should -Be 'No Witness'
        $generatedParameters.networkingType | Should -Be 'switchlessMultiServerDeployment'
        $generatedParameters.networkingPattern | Should -Be 'convergedManagementCompute'
        @($generatedParameters.storageNetworkList).Count | Should -Be 2
    }

    It 'pins a template that still exposes the witness fields the deployment patches' {
        $templateText = Get-Content -LiteralPath $templateDownloadPath -Raw
        $templateText.Contains('"witnessType": "[variables(''witnessTypeVar'')]"') | Should -BeTrue
        $templateText.Contains('"witnessPath": ""') | Should -BeTrue
    }

    It 'uses the nested-lab WDAC profile' {
        $generatedParameters.securityLevel | Should -Be 'Recommended'
        $generatedParameters.wdacEnforced | Should -BeFalse
    }

    It 'redacts both credentials from generated validation output' {
        $generatedParameters.localAdminPassword | Should -Be '<secure>'
        $generatedParameters.AzureStackLCMAdminPassword | Should -Be '<secure>'
        ($generatedParameters | ConvertTo-Json -Depth 20) | Should -Not -Match ([regex]::Escape($plainTextFixturePassword))
    }
}