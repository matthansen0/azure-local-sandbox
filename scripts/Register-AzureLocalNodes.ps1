#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseUsingScopeModifierInNewRunspaces',
    '',
    Justification = 'PowerShell Direct script blocks receive serialized values through ArgumentList and declare them in local param blocks.'
)]
param(
    [Parameter(Mandatory)]
    [PSCredential]$LocalAdministratorCredential,

    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..\config\lab.psd1'),

    [string]$DeploymentContextPath = 'C:\AzureLocalSandbox\State\deployment-context.json',

    [string]$DependenciesPath = (Join-Path $PSScriptRoot '..\config\dependencies.psd1'),

    [string]$TargetSolutionVersion,

    [ValidateRange(15, 120)]
    [int]$RegistrationTimeoutMinutes = 60,

    [ValidateRange(1, 5)]
    [int]$ArcInitializationAttempts = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-MachineLocalCredential {
    # Azure Local joins the nodes to the domain, after which an unqualified user name authenticates
    # against the domain instead of the node's own SAM database and PowerShell Direct rejects it.
    param([Parameter(Mandatory)][PSCredential]$Credential)

    if ($Credential.UserName -match '[\\@]') {
        return $Credential
    }

    return New-Object System.Management.Automation.PSCredential(".\$($Credential.UserName)", $Credential.Password)
}

$LocalAdministratorCredential = Get-MachineLocalCredential -Credential $LocalAdministratorCredential

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Information "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Message" -InformationAction Continue
}

function Install-NuGetProvider {
    # PowerShellGet raises an interactive bootstrap prompt when the provider binary is older than the
    # version it requires, which deadlocks an unattended run.
    # .NET 4.x defaults to SSL3/TLS1.0 here, and the provider CDN and PSGallery only accept TLS 1.2.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $installedProvider = @(
        Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue |
            Where-Object { $_.Version -ge [version]'2.8.5.208' }
    )
    if ($installedProvider.Count -eq 0) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.208 -Force -ForceBootstrap | Out-Null
        $installedProvider = @(
            Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue |
                Where-Object { $_.Version -ge [version]'2.8.5.208' }
        )
        if ($installedProvider.Count -eq 0) {
            throw 'The NuGet package provider could not be installed, so Install-Module would stop for an interactive prompt.'
        }
    }
}

function Install-RequiredAzModule {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Version
    )

    if (Get-Module -ListAvailable -Name $Name | Where-Object Version -eq ([version]$Version)) {
        return
    }

    Write-Step "Installing PowerShell module $Name $Version from PSGallery..."
    Install-NuGetProvider
    $originalPolicy = (Get-PSRepository -Name PSGallery).InstallationPolicy
    try {
        if ($originalPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
        Install-Module `
            -Name $Name `
            -RequiredVersion $Version `
            -Repository PSGallery `
            -Scope CurrentUser `
            -Force
    }
    finally {
        if ($originalPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy $originalPolicy
        }
    }
}

function ConvertFrom-SecureToken {
    param(
        [Parameter(Mandatory)]
        $Token
    )

    if ($Token -is [SecureString]) {
        return [Net.NetworkCredential]::new('', $Token).Password
    }

    return [string]$Token
}

function Get-ConnectedMachine {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )

    return Get-AzConnectedMachine `
        -Name $Name `
        -ResourceGroupName $ResourceGroupName `
        -SubscriptionId $SubscriptionId `
        -ErrorAction SilentlyContinue
}

# The credential is qualified as .\Administrator above, so the guard compares the account name.
if (($LocalAdministratorCredential.UserName -replace '^\.\\', '') -ne 'Administrator') {
    throw "LocalAdministratorCredential must use the built-in 'Administrator' account."
}
if ($LocalAdministratorCredential.Password.Length -lt 14) {
    throw 'The nested local Administrator password must be at least 14 characters long.'
}

$configuration = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $ConfigurationPath)
$dependencies = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $DependenciesPath)
$context = Get-Content -LiteralPath $DeploymentContextPath -Raw | ConvertFrom-Json
$managementStatePath = 'C:\AzureLocalSandbox\State\management-plane.json'
if (-not (Test-Path -LiteralPath $managementStatePath)) {
    throw 'Management-plane state was not found. Run Initialize-ManagementPlane.ps1 first.'
}
$managementState = Get-Content -LiteralPath $managementStatePath -Raw | ConvertFrom-Json
if ($managementState.phase -ne 'ManagementPlaneReady') {
    throw "Management-plane phase is '$($managementState.phase)', not 'ManagementPlaneReady'."
}

$nodeConfigurations = @($configuration.VMs | Where-Object Role -eq 'AzureLocalNode')
if ($nodeConfigurations.Count -ne 2) {
    throw "Exactly two Azure Local node definitions are required; found $($nodeConfigurations.Count)."
}

$readinessResults = foreach ($nodeConfiguration in $nodeConfigurations) {
    Write-Step "Checking Arc readiness on $($nodeConfiguration.Name)..."
    Invoke-Command `
        -VMName $nodeConfiguration.Name `
        -Credential $LocalAdministratorCredential `
        -ArgumentList $configuration.Domain.Fqdn, $configuration.Domain.DomainControllerIp, $context.azureLocation `
        -ScriptBlock {
            param(
                [string]$DomainFqdn,
                [string]$DomainControllerIp,
                [string]$AzureLocation
            )

            Set-StrictMode -Version Latest
            $ErrorActionPreference = 'Stop'

            $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
            if ($computerSystem.PartOfDomain) {
                throw "'$env:COMPUTERNAME' is already domain joined. This workflow expects Azure deployment to perform the join."
            }

            foreach ($adapterName in @('FABRIC', 'StorageA', 'StorageB')) {
                if (-not (Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue)) {
                    throw "Required adapter '$adapterName' was not found on '$env:COMPUTERNAME'."
                }
            }

            $fabricAdapter = Get-NetAdapter -Name 'FABRIC'
            Set-DnsClientServerAddress `
                -InterfaceIndex $fabricAdapter.ifIndex `
                -ServerAddresses @($DomainControllerIp)

            $null = Resolve-DnsName -Name $DomainFqdn -Type SOA -ErrorAction Stop
            # Arc onboarding fails deep into a 10-20 minute run if any of these are blocked.
            $requiredEndpoints = @(
                'management.azure.com'
                'login.microsoftonline.com'
                'gbl.his.arc.azure.com'
                'aka.ms'
            )
            $unreachableEndpoints = @(
                $requiredEndpoints | Where-Object {
                    -not (Test-NetConnection `
                        -ComputerName $_ `
                        -Port 443 `
                        -InformationLevel Quiet `
                        -ErrorAction SilentlyContinue `
                        -WarningAction SilentlyContinue)
                }
            )
            if ($unreachableEndpoints.Count -gt 0) {
                throw "'$env:COMPUTERNAME' cannot reach these endpoints over HTTPS: $($unreachableEndpoints -join ', ')."
            }

            w32tm.exe /config /manualpeerlist:"$DomainControllerIp,0x8" /syncfromflags:manual /update | Out-Null
            Restart-Service W32Time
            w32tm.exe /resync /force | Out-Null

            # A failed resync leaves the source as the CMOS clock, which only surfaces as an Azure
            # Local validation failure some forty minutes later.
            $timeDeadline = (Get-Date).AddMinutes(5)
            $timeSource = w32tm.exe /query /source
            while ($timeSource -match 'Local CMOS Clock') {
                if ((Get-Date) -ge $timeDeadline) {
                    throw "'$env:COMPUTERNAME' did not synchronise time with '$DomainControllerIp' and is still using the local CMOS clock."
                }
                Start-Sleep -Seconds 15
                w32tm.exe /resync /force 2>&1 | Out-Null
                $timeSource = w32tm.exe /query /source
            }

            # The Azure Local image stages AzureEdgeBootstrap through a scheduled task, so the Arc
            # installer is absent until that task has run at least once.
            if (-not (Get-Command 'Invoke-AzStackHciArcInitialization' -ErrorAction SilentlyContinue)) {
                $customizationTask = Get-ScheduledTask `
                    -TaskName 'ImageCustomizationScheduledTask' `
                    -ErrorAction SilentlyContinue
                if (-not $customizationTask) {
                    $bootstrapSetup = 'C:\BootstrapPackage\bootstrap\content\Bootstrap-Setup.ps1'
                    if (Test-Path -LiteralPath $bootstrapSetup) {
                        throw "'$env:COMPUTERNAME' is Azure Local media, but its first-boot bootstrap never ran, so the Arc installer was never staged. Run this on the node and let it reboot, then rerun: & 'C:\startupScriptsWrapper.ps1' '$bootstrapSetup -Install'"
                    }
                    throw "'Invoke-AzStackHciArcInitialization', 'ImageCustomizationScheduledTask' and the bootstrap package are all missing on '$env:COMPUTERNAME'. The OS disk is not Azure Local media."
                }

                if ($customizationTask.State -ne 'Running') {
                    $customizationTask | Start-ScheduledTask
                }

                $bootstrapDeadline = (Get-Date).AddMinutes(15)
                while (-not (Get-Command 'Invoke-AzStackHciArcInitialization' -ErrorAction SilentlyContinue)) {
                    if ((Get-Date) -ge $bootstrapDeadline) {
                        throw "ImageCustomizationScheduledTask did not stage the Arc installer on '$env:COMPUTERNAME' within 15 minutes. Inspect the task history in Task Scheduler."
                    }
                    Start-Sleep -Seconds 15
                    # Forces a fresh module scan; command discovery in a live session can be cached.
                    Import-Module AzsHCI.ARCinstaller -Force -ErrorAction SilentlyContinue
                }
            }

            [pscustomobject]@{
                Name          = $env:COMPUTERNAME
                Workgroup     = $computerSystem.Domain
                Dns           = $DomainControllerIp
                AzureLocation = $AzureLocation
                Result        = 'ReadyForArc'
            }
        }
}

Install-RequiredAzModule `
    -Name $dependencies.PowerShellModules.AzAccounts.Name `
    -Version $dependencies.PowerShellModules.AzAccounts.Version
Install-RequiredAzModule `
    -Name $dependencies.PowerShellModules.AzConnectedMachine.Name `
    -Version $dependencies.PowerShellModules.AzConnectedMachine.Version
Import-Module `
    -Name $dependencies.PowerShellModules.AzAccounts.Name `
    -RequiredVersion $dependencies.PowerShellModules.AzAccounts.Version `
    -Force
Import-Module `
    -Name $dependencies.PowerShellModules.AzConnectedMachine.Name `
    -RequiredVersion $dependencies.PowerShellModules.AzConnectedMachine.Version `
    -Force

Write-Step 'Signing in to Azure with the host managed identity...'
$null = Connect-AzAccount `
    -Identity `
    -Tenant $context.tenantId `
    -Subscription $context.subscriptionId

$registrationResults = foreach ($nodeConfiguration in $nodeConfigurations) {
    $existingMachine = Get-ConnectedMachine `
        -Name $nodeConfiguration.Name `
        -ResourceGroupName $context.resourceGroupName `
        -SubscriptionId $context.subscriptionId

    if ($existingMachine -and $existingMachine.Status -eq 'Connected') {
        [pscustomobject]@{
            Name   = $nodeConfiguration.Name
            Result = 'AlreadyConnected'
        }
        continue
    }

    $accountId = (Get-AzContext).Account.Id
    $initializationResult = $null
    for ($attempt = 1; $attempt -le $ArcInitializationAttempts -and -not $initializationResult; $attempt++) {
        # Re-issued per attempt because a retry starts long after the previous token was minted.
        $accessTokenResponse = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
        $armAccessToken = ConvertFrom-SecureToken -Token $accessTokenResponse.Token
        try {
            Write-Step "Running Invoke-AzStackHciArcInitialization on $($nodeConfiguration.Name), attempt $attempt of $ArcInitializationAttempts. This takes 10-20 minutes per node..."
            Invoke-Command `
                -VMName $nodeConfiguration.Name `
                -Credential $LocalAdministratorCredential `
                -ArgumentList $context, $armAccessToken, $accountId, $TargetSolutionVersion `
                -ScriptBlock {
                    param(
                        $Context,
                        [string]$ArmAccessToken,
                        [string]$AccountId,
                        [string]$TargetSolutionVersion
                    )

                    $parameters = @{
                        TenantId       = $Context.tenantId
                        SubscriptionID = $Context.subscriptionId
                        ResourceGroup  = $Context.resourceGroupName
                        Region         = $Context.azureLocation
                        Cloud          = 'AzureCloud'
                        ArmAccessToken = $ArmAccessToken
                        AccountID      = $AccountId
                    }
                    if ($TargetSolutionVersion) {
                        $parameters.TargetSolutionVersion = $TargetSolutionVersion
                    }

                    Invoke-AzStackHciArcInitialization @parameters
                }

            $initializationResult = 'InitializationInvoked'
        }
        catch {
            # Only the appliance image download timeout is worth repeating; every other failure is real.
            $errorText = ($_ | Out-String)
            if ($attempt -ge $ArcInitializationAttempts -or $errorText -notmatch 'PrepareKvaTimeoutError') {
                throw
            }

            Write-Step "$($nodeConfiguration.Name) hit PrepareKvaTimeoutError downloading the appliance image; retrying."
        }
        finally {
            $armAccessToken = $null
            $accessTokenResponse = $null
        }
    }

    [pscustomobject]@{
        Name   = $nodeConfiguration.Name
        Result = $initializationResult
    }
}

$deadline = (Get-Date).AddMinutes($RegistrationTimeoutMinutes)
do {
    $connectedMachines = @(
        foreach ($nodeConfiguration in $nodeConfigurations) {
            Get-ConnectedMachine `
                -Name $nodeConfiguration.Name `
                -ResourceGroupName $context.resourceGroupName `
                -SubscriptionId $context.subscriptionId
        }
    )
    $connectedNodeNames = @(
        $connectedMachines |
            Where-Object Status -eq 'Connected' |
            Select-Object -ExpandProperty Name
    )
    if (@($nodeConfigurations | Where-Object Name -notin $connectedNodeNames).Count -eq 0) {
        break
    }
    $statusSummary = @(
        foreach ($nodeConfiguration in $nodeConfigurations) {
            $machine = $connectedMachines | Where-Object Name -eq $nodeConfiguration.Name | Select-Object -First 1
            if ($machine) {
                "$($nodeConfiguration.Name)=$($machine.Status)"
            }
            else {
                "$($nodeConfiguration.Name)=NotFound"
            }
        }
    ) -join '; '
    Write-Step "Waiting for Azure Arc: $statusSummary"
    Start-Sleep -Seconds 30
} while ((Get-Date) -lt $deadline)

$notConnected = @(
    $nodeConfigurations |
        Where-Object Name -notin @($connectedMachines | Where-Object Status -eq 'Connected').Name
)
if ($notConnected.Count -gt 0) {
    throw "Azure Arc registration did not reach Connected for: $($notConnected.Name -join ', ')."
}

$machineState = @(
    $connectedMachines | ForEach-Object {
        [pscustomobject]@{
            Name       = $_.Name
            ResourceId = $_.Id
            Status     = $_.Status
        }
    }
)
$stateFile = 'C:\AzureLocalSandbox\State\arc-registration.json'
[ordered]@{
    phase     = 'AzureLocalNodesArcConnected'
    updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    readiness = @($readinessResults)
    invocation = @($registrationResults)
    machines  = $machineState
} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $stateFile -Encoding UTF8

$machineState | Format-Table -AutoSize