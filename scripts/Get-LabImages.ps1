#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding(DefaultParameterSetName = 'Hash')]
param(
    [Parameter(Mandatory)]
    [uri]$WindowsServerUri,

    [Parameter(Mandatory)]
    [uri]$AzureLocalUri,

    [Parameter(Mandatory, ParameterSetName = 'Hash')]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$WindowsServerSha256,

    [Parameter(Mandatory, ParameterSetName = 'Hash')]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$AzureLocalSha256,

    [Parameter(Mandatory, ParameterSetName = 'HashUri')]
    [uri]$WindowsServerSha256Uri,

    [Parameter(Mandatory, ParameterSetName = 'HashUri')]
    [uri]$AzureLocalSha256Uri,

    [string]$DestinationDirectory = 'V:\VHDs',

    [string]$StateFile = 'C:\AzureLocalSandbox\State\images.json',

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Information "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Message" -InformationAction Continue
}

function Get-ExpectedHash {
    param(
        [string]$Hash,
        [uri]$HashUri
    )

    if ($Hash) {
        return $Hash.ToUpperInvariant()
    }

    $hashResponse = Invoke-RestMethod -Uri $HashUri -UseBasicParsing
    $hashMatch = [regex]::Match([string]$hashResponse, '(?i)\b[A-F0-9]{64}\b')
    if (-not $hashMatch.Success) {
        throw "No SHA-256 value was found at '$HashUri'."
    }

    return $hashMatch.Value.ToUpperInvariant()
}

function Save-VerifiedImage {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [uri]$SourceUri,

        [Parameter(Mandatory)]
        [string]$ExpectedHash,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [switch]$Overwrite
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Write-Step "$Name already exists; verifying its SHA-256. Large images take several minutes..."
        $existingHash = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash
        if ($existingHash -eq $ExpectedHash) {
            Write-Step "$Name is already verified."
            return [pscustomobject]@{
                Name   = $Name
                Path   = $DestinationPath
                Sha256 = $existingHash
                Result = 'AlreadyVerified'
            }
        }

        if (-not $Overwrite) {
            throw "'$DestinationPath' exists but its SHA-256 does not match. Use -Force to replace it."
        }
    }

    $partialPath = "${DestinationPath}.partial"
    Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue

    try {
        Write-Step "Downloading $Name from $($SourceUri.Host). Multi-gigabyte images take a long time..."
        Start-BitsTransfer `
            -Source $SourceUri.AbsoluteUri `
            -Destination $partialPath `
            -DisplayName "Azure Local sandbox: $Name" `
            -Description "Downloading verified $Name parent image" `
            -Priority Foreground

        Write-Step "Verifying the SHA-256 of $Name..."
        $actualHash = (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash
        if ($actualHash -ne $ExpectedHash) {
            throw "SHA-256 mismatch for '$Name'. Expected $ExpectedHash; received $actualHash."
        }

        Move-Item -LiteralPath $partialPath -Destination $DestinationPath -Force
        Write-Step "$Name is downloaded and verified."
    }
    finally {
        Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Name   = $Name
        Path   = $DestinationPath
        Sha256 = $ExpectedHash
        Result = 'Downloaded'
    }
}

if ($WindowsServerUri.Scheme -ne 'https' -or $AzureLocalUri.Scheme -ne 'https') {
    throw 'Guest images must be downloaded over HTTPS.'
}

if ($PSCmdlet.ParameterSetName -eq 'HashUri' -and
    ($WindowsServerSha256Uri.Scheme -ne 'https' -or $AzureLocalSha256Uri.Scheme -ne 'https')) {
    throw 'Checksum files must be downloaded over HTTPS.'
}

New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null

$windowsHash = Get-ExpectedHash `
    -Hash $WindowsServerSha256 `
    -HashUri $WindowsServerSha256Uri
$azureLocalHash = Get-ExpectedHash `
    -Hash $AzureLocalSha256 `
    -HashUri $AzureLocalSha256Uri

$results = @(
    Save-VerifiedImage `
        -Name 'Windows Server 2025' `
        -SourceUri $WindowsServerUri `
        -ExpectedHash $windowsHash `
        -DestinationPath (Join-Path $DestinationDirectory 'WindowsServer2025.vhdx') `
        -Overwrite:$Force
    Save-VerifiedImage `
        -Name 'Azure Local' `
        -SourceUri $AzureLocalUri `
        -ExpectedHash $azureLocalHash `
        -DestinationPath (Join-Path $DestinationDirectory 'AzureLocal.vhdx') `
        -Overwrite:$Force
)

$stateDirectory = Split-Path -Parent $StateFile
if ($stateDirectory) {
    New-Item -Path $stateDirectory -ItemType Directory -Force | Out-Null
}
[ordered]@{
    phase     = 'ImagesVerified'
    updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    images    = @($results)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile -Encoding UTF8

$results | Format-Table -AutoSize