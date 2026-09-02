# Evaluated at discovery so the elevation-only test skips instead of failing on a non-elevated dev host.
$isElevatedWindows = $false
if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
    $isElevatedWindows = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

Describe 'Host script execution under Windows PowerShell' -Skip:([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
    }

    It 'runs Test-HostReadiness.ps1 to completion against a simulated ready host' -Skip:(-not $isElevatedWindows) {
        Set-StrictMode -Version Latest

        function Get-CimInstance {
            [CmdletBinding()]
            param([string]$ClassName)

            switch ($ClassName) {
                'Win32_OperatingSystem' {
                    [pscustomobject]@{ Caption = 'Microsoft Windows Server 2025 Datacenter'; BuildNumber = '26100' }
                }
                'Win32_ComputerSystem' {
                    [pscustomobject]@{ TotalPhysicalMemory = 256GB; HypervisorPresent = $true }
                }
                'Win32_Processor' {
                    # False once the hypervisor owns the CPU, which is why the script also checks HypervisorPresent.
                    [pscustomobject]@{ VirtualizationFirmwareEnabled = $false }
                }
                default { throw "Unexpected CIM class '$ClassName'." }
            }
        }

        function Get-WindowsFeature {
            [CmdletBinding()]
            param([string]$Name)
            [pscustomobject]@{ InstallState = 'Installed' }
        }

        function Get-Service {
            [CmdletBinding()]
            param([string]$Name)
            [pscustomobject]@{ Status = 'Running' }
        }

        function Get-Volume {
            [CmdletBinding()]
            param([char]$DriveLetter)
            [pscustomobject]@{
                FileSystem      = 'NTFS'
                FileSystemLabel = 'NestedVMs'
                Size            = 2045GB
                SizeRemaining   = 643GB
            }
        }

        function Get-VMSwitch {
            [CmdletBinding()]
            param([string]$Name)
            [pscustomobject]@{ SwitchType = 'Internal' }
        }

        function Get-NetNat {
            [CmdletBinding()]
            param([string]$Name)
            [pscustomobject]@{ InternalIPInterfaceAddressPrefix = '192.168.128.0/24' }
        }

        function Get-ItemProperty {
            [CmdletBinding()]
            param([string]$Path, [string]$Name)
            [pscustomobject]@{ NoAutoUpdate = 1 }
        }

        # lab.psd1 is read for real so the memory calculation executes; only fixed host paths are simulated.
        function Test-Path {
            [CmdletBinding()]
            param([string]$LiteralPath)

            if ($LiteralPath -like 'C:\AzureLocalSandbox\*') {
                return $true
            }

            # Answered directly so a servicing restart pending on the test runner cannot fail the run.
            if ($LiteralPath -like 'HKLM:\*') {
                return $false
            }

            return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
        }

        function Get-Content {
            [CmdletBinding()]
            param([string]$LiteralPath, [switch]$Raw)
            return '{"phase":"HostReady"}'
        }

        { . (Join-Path $repoRoot 'scripts\Test-HostReadiness.ps1') } | Should -Not -Throw
    }

    It 'derives the host memory requirement from the lab topology' {
        Set-StrictMode -Version Latest

        $configuration = Import-PowerShellDataFile (Join-Path $repoRoot 'config\lab.psd1')
        $nestedMemory = (@($configuration.VMs) | ForEach-Object { $_.MemoryStartupBytes } | Measure-Object -Sum).Sum

        $nestedMemory | Should -Be 220GB
    }

    It 'builds install image metadata that includes Version' {
        Set-StrictMode -Version Latest

        # Windows PowerShell 5.1 Join-Path resolves the drive, so the simulated mount point must exist.
        if (-not (Get-PSDrive -Name 'X' -ErrorAction SilentlyContinue)) {
            $null = New-PSDrive -Name 'X' -PSProvider FileSystem -Root $env:TEMP
        }

        $convertScript = Join-Path $repoRoot 'scripts\Convert-LabIsoMedia.ps1'
        $convertAst = [System.Management.Automation.Language.Parser]::ParseFile($convertScript, [ref]$null, [ref]$null)
        $functionAst = $convertAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-IsoInstallImage'
            }, $true)
        . ([scriptblock]::Create($functionAst.Extent.Text))

        function Write-Step {
            param([string]$Message)
        }

        function Mount-DiskImage {
            [CmdletBinding()]
            param([string]$ImagePath, [switch]$PassThru)
            [pscustomobject]@{ ImagePath = $ImagePath }
        }

        function Dismount-DiskImage {
            [CmdletBinding()]
            param([string]$ImagePath)
        }

        function Get-Volume {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject)
            process { [pscustomobject]@{ DriveLetter = 'X' } }
        }

        function Test-Path {
            [CmdletBinding()]
            param([string]$LiteralPath)
            return ($LiteralPath -eq 'X:\sources\install.wim')
        }

        # Mirrors DISM: the list form returns BasicImageInfoObject with no Version, only -Index carries it.
        function Get-WindowsImage {
            [CmdletBinding()]
            param([string]$ImagePath, [int]$Index)

            if ($PSBoundParameters.ContainsKey('Index')) {
                return [pscustomobject]@{
                    ImageIndex = $Index
                    ImageName  = "Edition $Index"
                    Version    = '10.0.26100.1'
                }
            }

            return @(
                [pscustomobject]@{ ImageIndex = 1; ImageName = 'Edition 1' }
                [pscustomobject]@{ ImageIndex = 2; ImageName = 'Edition 2' }
            )
        }

        $installImage = Get-IsoInstallImage -IsoPath (Join-Path $repoRoot 'README.md')

        @($installImage.Images).Count | Should -Be 2
        @($installImage.Images)[0].Version | Should -Not -BeNullOrEmpty
    }

    It 'restarts the router until the RemoteAccess cmdlet is available' {
        Set-StrictMode -Version Latest

        $managementScript = Join-Path $repoRoot 'scripts\Initialize-ManagementPlane.ps1'
        $managementAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $managementScript,
            [ref]$null,
            [ref]$null
        )
        $featureScriptAst = @(
            $managementAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.ScriptBlockAst] -and
                    $node.Extent.Text -match 'Install-WindowsFeature' -and
                    $node.Extent.Text -match 'Get-Command -Name Install-RemoteAccess'
                }, $true) |
                Sort-Object { $_.Extent.Text.Length }
        )[0]
        $featureScript = $featureScriptAst.GetScriptBlock()

        function Invoke-FeatureInstallSimulation {
            param(
                [string]$FeatureRestartNeeded,
                [bool]$RemoteAccessAvailable
            )

            function Install-WindowsFeature {
                [CmdletBinding()]
                param([string[]]$Name, [switch]$IncludeManagementTools)
                [pscustomobject]@{ RestartNeeded = $FeatureRestartNeeded }
            }

            function Get-WindowsFeature {
                [CmdletBinding()]
                param([string]$Name)
                [pscustomobject]@{ InstallState = 'Installed' }
            }

            function Get-Command {
                [CmdletBinding()]
                param([string]$Name)
                if ($RemoteAccessAvailable) {
                    [pscustomobject]@{ Name = $Name }
                }
            }

            & $featureScript
        }

        (Invoke-FeatureInstallSimulation -FeatureRestartNeeded Yes -RemoteAccessAvailable $true).RestartNeeded |
            Should -Be 'Yes'
        (Invoke-FeatureInstallSimulation -FeatureRestartNeeded No -RemoteAccessAvailable $false).RestartNeeded |
            Should -Be 'Yes'
        (Invoke-FeatureInstallSimulation -FeatureRestartNeeded No -RemoteAccessAvailable $true).RestartNeeded |
            Should -Be 'No'
    }

    It 'recreates a missing AD provider drive through the local domain controller' {
        Set-StrictMode -Version Latest

        $managementScript = Join-Path $repoRoot 'scripts\Initialize-ManagementPlane.ps1'
        $managementAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $managementScript,
            [ref]$null,
            [ref]$null
        )
        $providerFunctionAst = $managementAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Wait-ActiveDirectoryProviderDrive'
            }, $true)
        $providerFunctionAst | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($providerFunctionAst.Extent.Text))

        $simulationResult = & {
            $state = [ordered]@{
                DriveExists  = $false
                NewDrive     = $null
                RequestedPath = $null
            }

            function Get-PSDrive {
                [CmdletBinding()]
                param([string]$Name)

                if ($state.DriveExists) {
                    return [pscustomobject]@{ Name = $Name }
                }
            }

            function New-PSDrive {
                [CmdletBinding()]
                param(
                    [string]$Name,
                    [string]$PSProvider,
                    [string]$Root,
                    [string]$Server,
                    [string]$Scope
                )

                $state.NewDrive = [pscustomobject]@{
                    Name       = $Name
                    PSProvider = $PSProvider
                    Root       = $Root
                    Server     = $Server
                    Scope      = $Scope
                }
                $state.DriveExists = $true
                return [pscustomobject]@{ Name = $Name }
            }

            function Get-Item {
                [CmdletBinding()]
                param([string]$LiteralPath)

                if (-not $state.DriveExists) {
                    throw 'The simulated AD: drive does not exist.'
                }
                $state.RequestedPath = $LiteralPath
                return [pscustomobject]@{ DistinguishedName = 'DC=jumpstart,DC=local' }
            }

            Wait-ActiveDirectoryProviderDrive `
                -Server 'JumpstartDC' `
                -DomainDistinguishedName 'DC=jumpstart,DC=local' `
                -TimeoutMinutes 1

            return [pscustomobject]@{
                NewDrive      = $state.NewDrive
                RequestedPath = $state.RequestedPath
            }
        }

        $simulationResult.NewDrive.Name | Should -Be 'AD'
        $simulationResult.NewDrive.PSProvider | Should -Be 'ActiveDirectory'
        $simulationResult.NewDrive.Root | Should -Be '//RootDSE/'
        $simulationResult.NewDrive.Server | Should -Be 'JumpstartDC'
        $simulationResult.NewDrive.Scope | Should -Be 'Global'
        $simulationResult.RequestedPath | Should -Be 'AD:\DC=jumpstart,DC=local'
    }
}
