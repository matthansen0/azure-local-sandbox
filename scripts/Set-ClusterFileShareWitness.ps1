#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseUsingScopeModifierInNewRunspaces',
    '',
    Justification = 'PowerShell Direct script blocks receive serialized values through ArgumentList and declare them in local param blocks.'
)]
param(
    [Parameter(Mandatory)]
    [PSCredential]$LocalAdministratorCredential,

    [Parameter(Mandatory)]
    [PSCredential]$DomainAdministratorCredential,

    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..\config\lab.psd1'),

    [string]$StateFile = 'C:\AzureLocalSandbox\State\cluster-witness.json',

    [ValidateRange(5, 60)]
    [int]$ClusterTimeoutMinutes = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)

    Write-Information "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Message" -InformationAction Continue
}

$configuration = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $ConfigurationPath)
if ($configuration.SchemaVersion -ne 2) {
    throw "Unsupported configuration schema '$($configuration.SchemaVersion)'."
}

$clusterName = $configuration.Cluster.Name
$shareName = $configuration.Cluster.WitnessShareName
$sharePath = $configuration.Cluster.WitnessPath
$domainControllerName = $configuration.Domain.DomainControllerName
$netBiosName = $configuration.Domain.NetBiosName
$witnessUnc = "\\$domainControllerName.$($configuration.Domain.Fqdn)\$shareName"

$nodeConfigurations = @($configuration.VMs | Where-Object Role -eq 'AzureLocalNode')
if ($nodeConfigurations.Count -ne 2) {
    throw "Exactly two Azure Local node definitions are required; found $($nodeConfigurations.Count)."
}
$firstNodeName = $nodeConfigurations[0].Name

Write-Step "Waiting for cluster '$clusterName' to respond on $firstNodeName..."
$clusterDeadline = (Get-Date).AddMinutes($ClusterTimeoutMinutes)
$clusterIdentity = $null
while ($true) {
    $clusterIdentity = Invoke-Command `
        -VMName $firstNodeName `
        -Credential $LocalAdministratorCredential `
        -ArgumentList $clusterName `
        -ScriptBlock {
            param([string]$ClusterName)

            Import-Module FailoverClusters -ErrorAction SilentlyContinue
            $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
            if (-not $cluster) {
                return $null
            }

            [pscustomobject]@{
                Name        = [string]$cluster.Name
                Domain      = [string]$cluster.Domain
                QuorumType  = [string](Get-ClusterQuorum -Cluster $ClusterName -ErrorAction SilentlyContinue).QuorumResource
            }
        }

    if ($clusterIdentity) {
        break
    }
    if ((Get-Date) -ge $clusterDeadline) {
        throw "Cluster '$clusterName' did not respond on '$firstNodeName' within $ClusterTimeoutMinutes minutes."
    }
    Start-Sleep -Seconds 20
}
Write-Step "Cluster '$($clusterIdentity.Name)' is available."

# The cluster name object is what authenticates to the witness share, so it has to exist in the
# directory before the share permissions can reference it.
$clusterAccount = "$netBiosName\$clusterName`$"

Write-Step "Publishing the witness share '$witnessUnc' on $domainControllerName..."
$shareResult = Invoke-Command `
    -VMName 'AzLMGMT' `
    -Credential $LocalAdministratorCredential `
    -ArgumentList $DomainAdministratorCredential, $domainControllerName, $shareName, $sharePath, $clusterAccount, $clusterName `
    -ScriptBlock {
        param(
            [PSCredential]$DomainCredential,
            [string]$DomainControllerName,
            [string]$ShareName,
            [string]$SharePath,
            [string]$ClusterAccount,
            [string]$ClusterName
        )

        Invoke-Command `
            -VMName $DomainControllerName `
            -Credential $DomainCredential `
            -ArgumentList $ShareName, $SharePath, $ClusterAccount, $ClusterName `
            -ScriptBlock {
                param(
                    [string]$ShareName,
                    [string]$SharePath,
                    [string]$ClusterAccount,
                    [string]$ClusterName
                )

                Set-StrictMode -Version Latest
                $ErrorActionPreference = 'Stop'

                Import-Module ActiveDirectory

                $computer = Get-ADComputer -Identity $ClusterName -ErrorAction SilentlyContinue
                if (-not $computer) {
                    throw "Cluster name object '$ClusterName' was not found in Active Directory."
                }

                New-Item -Path $SharePath -ItemType Directory -Force | Out-Null

                $share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
                if (-not $share) {
                    New-SmbShare -Name $ShareName -Path $SharePath -FullAccess $ClusterAccount | Out-Null
                }
                elseif ($share.Path -ne $SharePath) {
                    throw "Share '$ShareName' already exists and points at '$($share.Path)'."
                }
                else {
                    Grant-SmbShareAccess -Name $ShareName -AccountName $ClusterAccount -AccessRight Full -Force | Out-Null
                }

                $acl = Get-Acl -Path $SharePath
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $ClusterAccount, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                $acl.SetAccessRule($rule)
                Set-Acl -Path $SharePath -AclObject $acl

                [pscustomobject]@{
                    Name        = $env:COMPUTERNAME
                    Share       = $ShareName
                    Path        = $SharePath
                    GrantedTo   = $ClusterAccount
                    Result      = 'WitnessShareReady'
                }
            }
    }

Write-Step "Pointing cluster quorum at '$witnessUnc'..."
$quorumResult = Invoke-Command `
    -VMName $firstNodeName `
    -Credential $LocalAdministratorCredential `
    -ArgumentList $clusterName, $witnessUnc `
    -ScriptBlock {
        param([string]$ClusterName, [string]$WitnessUnc)

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        Import-Module FailoverClusters

        $quorum = Get-ClusterQuorum -Cluster $ClusterName
        if ($quorum.QuorumResource -and $quorum.QuorumResource.Name -eq 'File Share Witness') {
            return [pscustomobject]@{ Result = 'AlreadyConfigured'; Witness = [string]$quorum.QuorumResource.Name }
        }

        Set-ClusterQuorum -Cluster $ClusterName -FileShareWitness $WitnessUnc | Out-Null

        $quorum = Get-ClusterQuorum -Cluster $ClusterName
        [pscustomobject]@{
            Result  = 'Configured'
            Witness = [string]$quorum.QuorumResource.Name
        }
    }

if (-not $quorumResult.Witness) {
    throw "Cluster '$clusterName' still has no quorum witness after configuring '$witnessUnc'."
}

$stateDirectory = Split-Path -Parent $StateFile
New-Item -Path $stateDirectory -ItemType Directory -Force | Out-Null
[ordered]@{
    phase       = 'ClusterWitnessConfigured'
    updatedAt   = (Get-Date).ToUniversalTime().ToString('o')
    clusterName = $clusterName
    witnessType = 'FileShare'
    witnessPath = $witnessUnc
    share       = $shareResult
    quorum      = $quorumResult
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateFile -Encoding UTF8

[pscustomobject]@{
    Cluster     = $clusterName
    WitnessType = 'FileShare'
    WitnessPath = $witnessUnc
    Quorum      = $quorumResult.Witness
    Result      = $quorumResult.Result
} | Format-List
