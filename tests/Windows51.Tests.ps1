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
}
