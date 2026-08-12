Describe 'Host script execution under Windows PowerShell' -Skip:([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
    }

    It 'runs Test-HostReadiness.ps1 to completion against a simulated ready host' {
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

        # lab.psd1 is read for real so the memory calculation executes; only fixed host paths are simulated.
        function Test-Path {
            [CmdletBinding()]
            param([string]$LiteralPath)

            if ($LiteralPath -like 'C:\AzureLocalSandbox\*') {
                return $true
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

    It 'waits for an offline-serviced VHDX to detach and gives up on a stuck one' {
        Set-StrictMode -Version Latest

        $guestDiskScript = Join-Path $repoRoot 'scripts\Initialize-GuestDisks.ps1'
        $guestDiskAst = [System.Management.Automation.Language.Parser]::ParseFile($guestDiskScript, [ref]$null, [ref]$null)
        $functionAst = $guestDiskAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Wait-VhdDetach'
            }, $true)
        . ([scriptblock]::Create($functionAst.Extent.Text))

        $script:vhdState = 'Detached'
        function Get-VHD {
            [CmdletBinding()]
            param([string]$Path)

            switch ($script:vhdState) {
                'Detached' { [pscustomobject]@{ Attached = $false } }
                'Missing' { $null }
                default { [pscustomobject]@{ Attached = $true } }
            }
        }

        function Start-Sleep {
            [CmdletBinding()]
            param([int]$Seconds)
        }

        # Advancing the clock on every read guarantees the stuck case reaches its deadline immediately.
        $script:clock = [datetime]'2026-01-01T00:00:00'
        function Get-Date {
            $script:clock = $script:clock.AddHours(1)
            $script:clock
        }

        { Wait-VhdDetach -Path 'V:\VMs\AzLHOST1\AzLHOST1-OS.vhdx' } | Should -Not -Throw

        # Get-VHD returns nothing for a path it cannot open, which strict mode must tolerate.
        $script:vhdState = 'Missing'
        { Wait-VhdDetach -Path 'V:\VMs\AzLHOST1\AzLHOST1-OS.vhdx' } | Should -Not -Throw

        $script:vhdState = 'Attached'
        { Wait-VhdDetach -Path 'V:\VMs\AzLHOST1\AzLHOST1-OS.vhdx' } |
            Should -Throw -ExpectedMessage '*AzLHOST1-OS.vhdx*still attached*'
    }
}
