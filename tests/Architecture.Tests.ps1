BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $configuration = Import-PowerShellDataFile (Join-Path $repoRoot 'config/lab.psd1')
    $networkTemplate = Get-Content (Join-Path $repoRoot 'infra/modules/network.bicep') -Raw
    $hostTemplate = Get-Content (Join-Path $repoRoot 'infra/modules/host.bicep') -Raw
    $dependencies = Import-PowerShellDataFile (Join-Path $repoRoot 'config/dependencies.psd1')

    function Get-IPv4Range {
        param([Parameter(Mandatory)][string]$Cidr)

        $cidrParts = $Cidr.Split('/')
        $addressBytes = [Net.IPAddress]::Parse($cidrParts[0]).GetAddressBytes()
        $prefixLength = [int]$cidrParts[1]
        $addressValue =
            ([uint64]$addressBytes[0] * 16777216) +
            ([uint64]$addressBytes[1] * 65536) +
            ([uint64]$addressBytes[2] * 256) +
            [uint64]$addressBytes[3]
        $addressCount = [uint64][math]::Pow(2, 32 - $prefixLength)
        $start = $addressValue - ($addressValue % $addressCount)

        return [pscustomobject]@{
            Cidr  = $Cidr
            Start = $start
            End   = $start + $addressCount - 1
        }
    }

    function Test-RangeOverlap {
        param($First, $Second)

        return -not ($First.End -lt $Second.Start -or $Second.End -lt $First.Start)
    }
}

Describe 'Lab topology contract' {
    It 'uses the current schema' {
        $configuration.SchemaVersion | Should -Be 2
    }

    It 'defines one management host and two Azure Local nodes' {
        @($configuration.VMs).Count | Should -Be 3
        @($configuration.VMs | Where-Object Role -eq 'Management').Count | Should -Be 1
        @($configuration.VMs | Where-Object Role -eq 'AzureLocalNode').Count | Should -Be 2
        @($configuration.VMs.Name | Sort-Object) | Should -Be @('AzLHOST1', 'AzLHOST2', 'AzLMGMT')
    }

    It 'assigns unique VM and adapter names' {
        @($configuration.VMs.Name | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
        foreach ($virtualMachine in @($configuration.VMs)) {
            @($virtualMachine.NetworkAdapters.Name | Group-Object | Where-Object Count -gt 1).Count |
                Should -Be 0 -Because "$($virtualMachine.Name) adapter names must be unique"
        }
    }

    It 'provides enough memory for the intended E32s host' {
        $nestedMemory = (@($configuration.VMs) | ForEach-Object { $_.MemoryStartupBytes } | Measure-Object -Sum).Sum
        $nestedMemory | Should -BeLessOrEqual 240GB
        $nestedMemory | Should -BeGreaterOrEqual 200GB
    }

    It 'defines all Azure Local node adapters and storage disks' {
        foreach ($node in @($configuration.VMs | Where-Object Role -eq 'AzureLocalNode')) {
            @($node.NetworkAdapters.Name | Sort-Object) | Should -Be @('SDN', 'StorageA', 'StorageB')
            @($node.StorageDisks).Count | Should -Be 6
            $node.NestedVirtualization | Should -BeTrue
        }
    }
}

Describe 'Network isolation contract' {
    It 'keeps every nested network disjoint' {
        $nestedRanges = @(
            $configuration.Networks.GetEnumerator() |
                Where-Object { $_.Value.ContainsKey('Prefix') } |
                ForEach-Object { Get-IPv4Range -Cidr $_.Value.Prefix }
        )

        for ($firstIndex = 0; $firstIndex -lt $nestedRanges.Count; $firstIndex++) {
            for ($secondIndex = $firstIndex + 1; $secondIndex -lt $nestedRanges.Count; $secondIndex++) {
                Test-RangeOverlap -First $nestedRanges[$firstIndex] -Second $nestedRanges[$secondIndex] |
                    Should -BeFalse -Because "$($nestedRanges[$firstIndex].Cidr) and $($nestedRanges[$secondIndex].Cidr) must not overlap"
            }
        }
    }

    It 'keeps the outer Azure VNet disjoint from every nested network' {
        $outerPrefixMatch = [regex]::Match(
            $networkTemplate,
            "param\s+virtualNetworkAddressPrefix\s+string\s*=\s*'([^']+)'"
        )
        $outerPrefixMatch.Success | Should -BeTrue
        $outerRange = Get-IPv4Range -Cidr $outerPrefixMatch.Groups[1].Value

        foreach ($network in $configuration.Networks.GetEnumerator() | Where-Object { $_.Value.ContainsKey('Prefix') }) {
            $nestedRange = Get-IPv4Range -Cidr $network.Value.Prefix
            Test-RangeOverlap -First $outerRange -Second $nestedRange |
                Should -BeFalse -Because "outer $($outerRange.Cidr) and nested $($nestedRange.Cidr) must not overlap"
        }
    }

    It 'uses the documented outer network range' {
        $networkTemplate | Should -Match "virtualNetworkAddressPrefix string = '172\.31\.0\.0/16'"
        $networkTemplate | Should -Match "hostSubnetAddressPrefix string = '172\.31\.1\.0/24'"
        $networkTemplate | Should -Match "bastionSubnetAddressPrefix string = '172\.31\.2\.0/26'"
    }

    It 'prefers the free Bastion Developer SKU in a supported default region' {
        $networkTemplate | Should -Match "param bastionSku string = 'Developer'"
        $networkTemplate | Should -Match 'var deployHostedBastion = deployBastion && !useDeveloperBastion'

        $deploymentWrapper = Get-Content (Join-Path $repoRoot 'scripts/Deploy.ps1') -Raw
        $deploymentWrapper | Should -Match "\`$Location = 'centralus'"
        $deploymentWrapper | Should -Match "DeveloperSkuRegions"
        @($dependencies.AzureBastion.DeveloperSkuRegions) | Should -Contain 'centralus'
    }
}

Describe 'Credential and artifact contract' {
    It 'does not put a password in static configuration' {
        $configurationText = Get-Content (Join-Path $repoRoot 'config/lab.psd1') -Raw
        $configurationText | Should -Not -Match '(?i)password\s*='
    }

    It 'does not redistribute parent VHDX images' {
        @(Get-ChildItem $repoRoot -Recurse -File -Include '*.vhd', '*.vhdx').Count | Should -Be 0
    }

    It 'loads the administrator password from the environment' {
        $parameterText = Get-Content (Join-Path $repoRoot 'infra/main.bicepparam') -Raw
        $parameterText | Should -Match "readEnvironmentVariable\('AZURE_LOCAL_SANDBOX_ADMIN_PASSWORD'\)"
        $parameterText | Should -Match "readEnvironmentVariable\('AZURE_LOCAL_RESOURCE_PROVIDER_OBJECT_ID'\)"
        $parameterText | Should -Match "readEnvironmentVariable\('AZURE_LOCAL_SANDBOX_BOOTSTRAP_SHA256'\)"
        $parameterText | Should -Match "readEnvironmentVariable\('AZURE_LOCAL_SANDBOX_SOURCE_SHA256'\)"
        $parameterText | Should -Match "readEnvironmentVariable\('AZURE_LOCAL_SANDBOX_BOOTSTRAP_URI'\)"
        $parameterText | Should -Match "readEnvironmentVariable\('AZURE_LOCAL_SANDBOX_SOURCE_URI'\)"
        $parameterText | Should -Match "readEnvironmentVariable\('AZURE_LOCAL_SANDBOX_HOST_IMAGE_VERSION'\)"
    }

    It 'uses the current Azure Local resource-provider application ID' {
        $deploymentWrapper = Get-Content (Join-Path $repoRoot 'scripts/Deploy.ps1') -Raw
        $deploymentWrapper | Should -Match '1412d89f-b8a8-4111-b4fd-e82905cbd85d'
        $deploymentWrapper | Should -Not -Match '00001111-aaaa-2222-bbbb-3333cccc4444'
    }

    It 'supports verified ISO conversion without redistributing media' {
        $isoConverter = Get-Content (Join-Path $repoRoot 'scripts/Convert-LabIsoMedia.ps1') -Raw
        $isoConverter | Should -Match 'Get-FileHash'
        $isoConverter | Should -Match 'Get-WindowsImage'
        $isoConverter | Should -Match 'dism\.exe'
        $isoConverter | Should -Match 'bcdboot\.exe'
    }

    It 'provides a guided in-VM ISO handoff and desktop launcher' {
        $guidedSetup = Get-Content (Join-Path $repoRoot 'scripts/Start-SandboxSetup.ps1') -Raw
        $bootstrap = Get-Content (Join-Path $repoRoot 'scripts/Bootstrap.ps1') -Raw

        $guidedSetup | Should -Match 'Convert-LabIsoMedia\.ps1'
        $guidedSetup | Should -Match 'Invoke-SandboxDeployment\.ps1'
        $guidedSetup | Should -Match 'Get-Credential'
        $bootstrap | Should -Match 'Azure Local Sandbox Setup\.lnk'
        $bootstrap | Should -Match 'Start-SandboxSetup\.ps1'
    }

    It 'guides and validates the Windows Server Desktop Experience image index' {
        $guidedSetup = Get-Content (Join-Path $repoRoot 'scripts/Start-SandboxSetup.ps1') -Raw
        $isoConverter = Get-Content (Join-Path $repoRoot 'scripts/Convert-LabIsoMedia.ps1') -Raw

        $guidedSetup | Should -Match '\(Desktop Experience\)'
        $guidedSetup | Should -Match "RequiredNamePattern\s+'\\\(Desktop Experience\\\)'"
        $guidedSetup | Should -Match 'function Read-ImageIndex'

        # The image list must cross the Convert-LabIsoMedia.ps1 -> Start-SandboxSetup.ps1 boundary as a
        # JSON file, not captured stdout, because Storage-module cmdlets can leak stray objects into the
        # success stream and silently corrupt a captured array.
        $isoConverter | Should -Match 'ListImagesJsonPath'
        $guidedSetup | Should -Not -Match '@\(&\s*\$converterPath'
        $guidedSetup | Should -Match 'ConvertFrom-Json'
    }

    It 'pins reviewed external dependencies' {
        $dependencies.SchemaVersion | Should -Be 1
        $dependencies.AzureLocalQuickstart.Commit | Should -Match '^[0-9a-f]{40}$'
        $dependencies.AzureLocalQuickstart.Sha256 | Should -Match '^[A-F0-9]{64}$'
        $dependencies.Bicep.Version | Should -Match '^\d+\.\d+\.\d+$'
        foreach ($module in $dependencies.PowerShellModules.Values) {
            $module.Name | Should -Not -BeNullOrEmpty
            $module.Version | Should -Not -BeNullOrEmpty
        }
    }

    It 'stages immutable source through published GitHub artifacts' {
        $deploymentWrapper = Get-Content (Join-Path $repoRoot 'scripts/Deploy.ps1') -Raw
        $mainTemplate = Get-Content (Join-Path $repoRoot 'infra/main.bicep') -Raw
        $hostTemplate = Get-Content (Join-Path $repoRoot 'infra/modules/host.bicep') -Raw
        $deploymentWrapper | Should -Match 'https://raw\.githubusercontent\.com/\$owner/\$repository/\$Revision/scripts/Bootstrap\.ps1'
        $deploymentWrapper | Should -Match 'https://codeload\.github\.com/\$owner/\$repository/zip/\$Revision'
        $deploymentWrapper | Should -Match 'branch --remotes --contains'
        $deploymentWrapper | Should -Not -Match "'storage', 'account', 'create'"
        $deploymentWrapper | Should -Not -Match "'storage', 'blob', 'generate-sas'"
        $deploymentWrapper | Should -Not -Match 'bootstrapScriptUri=\$'
        $deploymentWrapper | Should -Not -Match 'sourceArchiveUri=\$'
        $mainTemplate | Should -Match "@secure\(\)\s*\r?\nparam bootstrapScriptUri string"
        $mainTemplate | Should -Match "@secure\(\)\s*\r?\nparam sourceArchiveUri string"
        $hostTemplate | Should -Match "@secure\(\)\s*\r?\nparam bootstrapScriptUri string"
        $hostTemplate | Should -Match "@secure\(\)\s*\r?\nparam sourceArchiveUri string"
    }

    It 'does not deploy a mutable latest host image' {
        $hostTemplate = Get-Content (Join-Path $repoRoot 'infra/modules/host.bicep') -Raw
        $hostTemplate | Should -Not -Match "version:\s*'latest'"
        $hostTemplate | Should -Match 'version:\s*imageVersion'
    }
}

Describe 'Monitoring containment contract' {
    BeforeAll {
        $monitoringTemplate = Get-Content (Join-Path $repoRoot 'infra/modules/monitoring.bicep') -Raw
        $mainTemplate = Get-Content (Join-Path $repoRoot 'infra/main.bicep') -Raw
        $parameterText = Get-Content (Join-Path $repoRoot 'infra/main.bicepparam') -Raw
        $deploymentWrapper = Get-Content (Join-Path $repoRoot 'scripts/Deploy.ps1') -Raw
        $monitoringModule = [regex]::Match(
            $mainTemplate,
            "module monitoring 'modules/monitoring\.bicep' = if \(deployMonitoring\) \{(?<body>.*?)\r?\n\}",
            'Singleline'
        ).Groups['body'].Value
    }

    It 'sends host telemetry only to the workspace this template creates' {
        # The sandbox must never be able to name an external workspace, which is exactly how a
        # subscription-wide monitoring policy ends up billing lab ingestion somewhere else.
        $destinations = @(
            [regex]::Matches($monitoringTemplate, 'workspaceResourceId:\s*(?<target>[^\r\n]+)') |
                ForEach-Object { $_.Groups['target'].Value.Trim() }
        )
        $destinations | Should -Be @('workspace.id')
        $monitoringTemplate | Should -Match "resource workspace 'Microsoft\.OperationalInsights/workspaces@"
        $monitoringTemplate | Should -Not -Match '(?i)param\s+\w*workspace\w*\s+string'
    }

    It 'materializes the Event table before creating the data collection rule' {
        $monitoringTemplate |
            Should -Match "resource eventTable 'Microsoft\.OperationalInsights/workspaces/tables@"
        $monitoringTemplate | Should -Match "name: 'Event'"
        $monitoringTemplate | Should -Match 'dependsOn:\s*\[\s*eventTable\s*\]'
    }

    It 'caps daily ingestion and keeps retention inside the included allowance' {
        $monitoringTemplate | Should -Match 'dailyQuotaGb: dailyQuotaGb'
        $mainTemplate | Should -Match 'param logAnalyticsDailyQuotaGb int'
        $parameterText | Should -Match 'param logAnalyticsDailyQuotaGb = \d+'
        $parameterText | Should -Match 'param logAnalyticsRetentionInDays = 30'
    }

    It 'never collects the Security channel or Information level events' {
        $monitoringTemplate |
            Should -Match "eventLogSeverityFilter = '\*\[System\[\(Level=1 or Level=2 or Level=3\)\]\]'"

        $xPathBlock = [regex]::Match(
            $monitoringTemplate,
            'xPathQueries:\s*\[(?<queries>[^\]]*)\]'
        ).Groups['queries'].Value
        $queries = @($xPathBlock -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        $queries.Count | Should -BeGreaterThan 0
        foreach ($query in $queries) {
            $query | Should -Match '!\$\{eventLogSeverityFilter\}''$'
            $query | Should -Not -Match "(?i)^'Security!"
        }
    }

    It 'onboards the host with the Azure Monitor agent and a sandbox-owned association' {
        $monitoringTemplate | Should -Match "publisher: 'Microsoft\.Azure\.Monitor'"
        $monitoringTemplate | Should -Match "type: 'AzureMonitorWindowsAgent'"
        $monitoringTemplate | Should -Match 'dataCollectionRuleId: dataCollectionRule\.id'
        $monitoringTemplate | Should -Match 'scope: virtualMachine'
    }

    It 'keeps every monitoring resource in the sandbox region and resource group' {
        $monitoringTemplate | Should -Not -Match "location: '"
        $monitoringModule | Should -Not -BeNullOrEmpty
        $monitoringModule | Should -Match 'scope: sandboxResourceGroup'
        $monitoringModule | Should -Match 'location: location'
        # Consuming the host output sequences the agent after the bootstrap Custom Script Extension.
        $monitoringModule | Should -Match 'virtualMachineName: host\.outputs\.virtualMachineName'
    }

    It 'reports monitoring attached from outside the sandbox after deployment' {
        $deploymentWrapper | Should -Match "'Microsoft\.OperationalInsights'"
        $deploymentWrapper | Should -Match 'function Test-MonitoringContainment'
        $deploymentWrapper | Should -Match 'dataCollectionRuleAssociations\?api-version='
        $deploymentWrapper | Should -Match 'MicrosoftMonitoringAgent'
        $deploymentWrapper | Should -Match 'Test-MonitoringContainment -VirtualMachineId'
    }
}

Describe 'Azure CLI invocation contract' {
    BeforeAll {
        $deployAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot 'scripts/Deploy.ps1'), [ref]$null, [ref]$null)

        $bicepVersionFunction = $deployAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-InstalledBicepVersion'
            }, $true)
        $sandboxCreateFunction = $deployAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Invoke-SandboxCreate'
            }, $true)
        $bicepVersionMatch = $bicepVersionFunction.Body.Find({
                param($node)
                $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                $node.Operator -eq [System.Management.Automation.Language.TokenKind]::Imatch
            }, $true)
        $bicepVersionPattern = $bicepVersionMatch.Right.SafeGetValue()

        $commonArgumentsAssignment = $deployAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$commonArguments'
            }, $true)

        $commonArguments = @(
            $commonArgumentsAssignment.Right.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.ArrayLiteralAst]
                }, $true).Elements | ForEach-Object {
                # Variable elements have no literal value; keep a placeholder so positions stay aligned.
                if ($_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                    $_ -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                    $_.Value
                }
                else {
                    ''
                }
            }
        )
    }

    It 'ignores upgrade notices when reading the installed Bicep version' {
        $output = @(
            'WARNING: A new Bicep release is available: v0.46.1. Upgrade now by running "az bicep upgrade".'
            'Bicep CLI version 0.45.15 (6a4a640fd8)'
        ) -join ' '

        $parsedVersion = if ($output -match $bicepVersionPattern) { $Matches['version'] }
        $parsedVersion | Should -Be '0.45.15'
    }

    It 'keeps --parameters last so appended template overrides are parsed' {
        $parametersIndex = $commonArguments.IndexOf('--parameters')
        $parametersIndex | Should -BeGreaterThan -1

        # az binds --parameters with nargs='+', so any later flag orphans every appended key=value override.
        @($commonArguments |
                Select-Object -Skip ($parametersIndex + 1) |
                Where-Object { $_ -like '--*' }) | Should -BeNullOrEmpty
    }

    It 'retries only while the Event table propagates to the data collection rule service' {
        $sandboxCreateFunction | Should -Not -BeNullOrEmpty
        $sandboxCreateSource = $sandboxCreateFunction.Extent.Text

        $sandboxCreateSource | Should -Match '\[int\]\$MaxAttempts = 5'
        $sandboxCreateSource | Should -Match 'InvalidOutputTable\.\*Microsoft-Event\.\*sandboxWorkspace'
        $sandboxCreateSource |
            Should -Match 'if \(-not \$isEventTablePropagationDelay -or \$attempt -eq \$MaxAttempts\)'
        $sandboxCreateSource | Should -Match 'Start-Sleep -Seconds \$retryDelaySeconds'
    }

    It 'passes the auto-selected Bastion SKU through to the template' {
        $deploySource = Get-Content (Join-Path $repoRoot 'scripts/Deploy.ps1') -Raw
        $deploySource | Should -Match 'bastionSku=\$candidateSku'
        (Get-Content (Join-Path $repoRoot 'infra/main.bicep') -Raw) | Should -Match 'param bastionSku string'
    }

    It 'does not retry the Bastion SKU when the CLI rejects the command itself' {
        $deploySource = Get-Content (Join-Path $repoRoot 'scripts/Deploy.ps1') -Raw
        $deploySource | Should -Match 'unrecognized arguments'
    }
}

Describe 'Windows PowerShell 5.1 compatibility' {
    It 'never binds Measure-Object to a property name' {
        # Host scripts run under 5.1, which cannot resolve hashtable keys as properties the way
        # PowerShell 7 does here, so values must be projected before Measure-Object sees them.
        @(Get-ChildItem (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -Recurse |
                Select-String -Pattern 'Measure-Object\s+(-Property\s+)?[A-Za-z]' |
                ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) | Should -BeNullOrEmpty
    }
}

Describe 'Management plane orchestration contract' {
    It 'restarts the router when feature installation requires it before configuring RRAS' {
        $managementPlaneSource = Get-Content `
            (Join-Path $repoRoot 'scripts/Initialize-ManagementPlane.ps1') `
            -Raw

        $featureInstallIndex = $managementPlaneSource.IndexOf('$routerFeatureResult = Invoke-Command')
        $restartBoundaryIndex = $managementPlaneSource.IndexOf("if (`$routerFeatureResult.RestartNeeded -eq 'Yes')")
        $readinessWaitIndex = $managementPlaneSource.IndexOf(
            'Wait-NestedPowerShellDirect',
            $restartBoundaryIndex
        )
        $rrasConfigurationIndex = $managementPlaneSource.IndexOf('Install-RemoteAccess -VpnType RoutingOnly')

        $featureInstallIndex | Should -BeGreaterOrEqual 0
        $restartBoundaryIndex | Should -BeGreaterThan $featureInstallIndex
        $readinessWaitIndex | Should -BeGreaterThan $restartBoundaryIndex
        $rrasConfigurationIndex | Should -BeGreaterThan $restartBoundaryIndex
        $rrasConfigurationIndex | Should -BeGreaterThan $readinessWaitIndex
        $managementPlaneSource | Should -Match "Restart-VM -Name 'Vm-Router' -Force"
        $managementPlaneSource | Should -Match 'Get-Command -Name Install-RemoteAccess'
    }
}
Describe 'Fail-fast deployment contract' {
    BeforeAll {
        $orchestratorSource = Get-Content (Join-Path $repoRoot 'scripts/Invoke-SandboxDeployment.ps1') -Raw
        $preflightSource = Get-Content (Join-Path $repoRoot 'scripts/Test-DeploymentPreflight.ps1') -Raw
        $cloudDeploymentSource = Get-Content (Join-Path $repoRoot 'scripts/Deploy-AzureLocal.ps1') -Raw
        $arcRegistrationSource = Get-Content (Join-Path $repoRoot 'scripts/Register-AzureLocalNodes.ps1') -Raw
    }

    It 'runs the Azure preflight before any stage that costs time or money' {
        $preflightIndex = $orchestratorSource.IndexOf('Test-DeploymentPreflight.ps1')
        $firstStageIndex = $orchestratorSource.IndexOf("Invoke-Stage -Name 'Images'")

        $preflightIndex | Should -BeGreaterThan 0
        $firstStageIndex | Should -BeGreaterThan $preflightIndex
        $orchestratorSource | Should -Match '\[switch\]\$PreflightOnly'
    }

    It 'checks the soft-deleted key vault before Arc registration, not after it' {
        # Deploy-AzureLocal.ps1 only reaches its own check hours in, so preflight has to own the early one.
        $preflightSource | Should -Match 'deletedVaults'
        $preflightSource | Should -Match 'azlsb-'
    }

    It 'reports preflight results through a file rather than the success stream' {
        $preflightSource | Should -Match 'Set-Content -LiteralPath \$ReportPath'
        $preflightSource | Should -Match "phase\s+=\s+if \(\`$failedChecks\.Count -eq 0\) \{ 'PreflightPassed' \}"
    }

    It 'never purges a key vault unless the caller opts in' {
        foreach ($source in @($preflightSource, $cloudDeploymentSource)) {
            $source | Should -Match '\[switch\]\$PurgeSoftDeletedKeyVault'
            $source | Should -Match "-Method POST"
        }

        # The switch has no default value, so an unattended run reports the collision instead of destroying data.
        $preflightSource | Should -Not -Match '\$PurgeSoftDeletedKeyVault\s*=\s*\$true'
        $cloudDeploymentSource | Should -Not -Match '\$PurgeSoftDeletedKeyVault\s*=\s*\$true'
    }

    It 'retries Arc initialization only for the transient appliance download timeout' {
        $arcRegistrationSource | Should -Match 'PrepareKvaTimeoutError'
        $arcRegistrationSource | Should -Match '\$errorText -notmatch ''PrepareKvaTimeoutError'''
        $arcRegistrationSource | Should -Match '\[int\]\$ArcInitializationAttempts = 3'

        # A retry starts long after the first token was minted, so it has to be re-issued per attempt.
        $tokenIndex = $arcRegistrationSource.IndexOf('$accessTokenResponse = Get-AzAccessToken')
        $loopIndex = $arcRegistrationSource.IndexOf('for ($attempt = 1; $attempt -le $ArcInitializationAttempts')
        $loopIndex | Should -BeGreaterThan 0
        $tokenIndex | Should -BeGreaterThan $loopIndex
    }

    It 'refuses to resume when the parent images no longer back the nested VMs' {
        $orchestratorSource | Should -Match 'Nested VM state exists but the verified parent images are missing'
        $guardIndex = $orchestratorSource.IndexOf('$imagesVerified = Test-ImageState')
        $firstStageIndex = $orchestratorSource.IndexOf("Invoke-Stage -Name 'Images'")
        $guardIndex | Should -BeGreaterThan 0
        $firstStageIndex | Should -BeGreaterThan $guardIndex
    }
}

Describe 'Host performance contract' {
    It 'enables accelerated networking on the host NIC' {
        # Both permitted E32s SKUs support SR-IOV, and it is off unless the template asks for it.
        $hostTemplate | Should -Match 'enableAcceleratedNetworking: true'
    }

    It 'keeps ReadOnly caching on the nested VM data disks' {
        # ReadWrite would risk Storage Spaces data on a crash; None would forfeit the cached read budget.
        $dataDiskBlock = [regex]::Match(
            $hostTemplate,
            'dataDisks: \[for diskIndex in range\(0, dataDiskCount\): \{(?<body>.*?)\n      \}\]',
            'Singleline'
        ).Groups['body'].Value
        $dataDiskBlock | Should -Match "caching: 'ReadOnly'"
        $dataDiskBlock | Should -Not -Match "caching: 'ReadWrite'"
    }

    It 'keeps the disk aggregate inside the uncached ceiling of the default VM size' {
        # 8 x P30 is 40,000 IOPS and 1,600 MB/s; Standard_E32s_v6 allows 51,200 IOPS and 1,696 MB/s
        # uncached, so the disks stay the limit. Standard_E32s_v5 caps throughput at 865 MB/s.
        $hostTemplate | Should -Match "param vmSize string = 'Standard_E32s_v6'"
        $hostTemplate | Should -Match 'param dataDiskCount int = 8'
        $hostTemplate | Should -Match 'param dataDiskSizeGiB int = 1024'
    }

    It 'converts ISO media one at a time in the calling process' {
        # A VHDX mounted from a Start-Job worker, or a second concurrent conversion, drops into
        # ERROR_VHD_INVALID_STATE about 30 seconds into the DISM apply.
        $converterSource = Get-Content (Join-Path $repoRoot 'scripts/Convert-LabIsoMedia.ps1') -Raw
        $converterSource | Should -Not -Match 'Start-Job'
        $converterSource | Should -Match 'foreach \(\$request in \$conversionRequests\)'
        $converterSource | Should -Match 'Convert-InstallImageToVhdx'
    }
}
