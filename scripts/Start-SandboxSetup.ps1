#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$WindowsServerIsoPath,

    [string]$AzureLocalIsoPath,

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$WindowsServerIsoSha256,

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$AzureLocalIsoSha256,

    [ValidateRange(0, 100)]
    [int]$WindowsServerImageIndex = 0,

    [ValidateRange(0, 100)]
    [int]$AzureLocalImageIndex = 0,

    [ValidateSet('Validate', 'Deploy')]
    [string]$Mode,

    [switch]$SkipDownloadPages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sandboxRoot = 'C:\AzureLocalSandbox'
$mediaRoot = Join-Path $sandboxRoot 'Media'
$stateRoot = Join-Path $sandboxRoot 'State'
$orchestratorPath = Join-Path $PSScriptRoot 'Invoke-SandboxDeployment.ps1'
$converterPath = Join-Path $PSScriptRoot 'Convert-LabIsoMedia.ps1'
$azureLocalDownloadGuide = 'https://learn.microsoft.com/azure/azure-local/deploy/download-23h2-software'
$windowsServerDownloadPage = 'https://www.microsoft.com/evalcenter/download-windows-server-2025'

function Read-Choice {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Choices,
        [Parameter(Mandatory)][string]$Default
    )

    $choiceDisplay = ($Choices | ForEach-Object {
        if ($_ -eq $Default) { "[$_]" } else { $_ }
    }) -join '/'

    do {
        $answer = (Read-Host "$Prompt ($choiceDisplay)").Trim()
        if (-not $answer) {
            return $Default
        }
        $match = $Choices | Where-Object {
            $_.StartsWith($answer, [StringComparison]::OrdinalIgnoreCase)
        }
        if (@($match).Count -eq 1) {
            return [string]$match
        }
    } while ($true)
}

function Read-ImageIndex {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][object[]]$AvailableImages,
        [string]$RequiredNamePattern
    )

    do {
        $rawAnswer = (Read-Host $Prompt).Trim()
        $parsedIndex = 0
        if (-not [int]::TryParse($rawAnswer, [ref]$parsedIndex)) {
            Write-Warning "'$rawAnswer' is not a number."
            continue
        }

        $selectedImage = $AvailableImages | Where-Object ImageIndex -eq $parsedIndex
        if (-not $selectedImage) {
            Write-Warning "Index $parsedIndex is not in the list above."
            continue
        }
        if ($RequiredNamePattern -and $selectedImage.ImageName -notmatch $RequiredNamePattern) {
            Write-Warning "'$($selectedImage.ImageName)' does not match the required pattern. Choose the index whose name ends in '(Desktop Experience)'."
            continue
        }

        return $parsedIndex
    } while ($true)
}

function Select-IsoFile {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$InitialDirectory
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = [Windows.Forms.OpenFileDialog]::new()
        try {
            $dialog.Title = $Title
            $dialog.Filter = 'ISO images (*.iso)|*.iso|All files (*.*)|*.*'
            $dialog.InitialDirectory = $InitialDirectory
            $dialog.Multiselect = $false
            if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
                return $dialog.FileName
            }
        }
        finally {
            $dialog.Dispose()
        }
    }
    catch {
        Write-Warning "The graphical file picker is unavailable: $($_.Exception.Message)"
    }

    return (Read-Host "$Title - enter the full ISO path").Trim('"')
}

function Resolve-IsoPath {
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$Title
    )

    if (-not $Path) {
        $Path = Select-IsoFile -Title $Title -InitialDirectory $mediaRoot
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Title was not selected or does not exist."
    }
    if ([IO.Path]::GetExtension($Path) -ne '.iso') {
        throw "'$Path' is not an ISO file."
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-ConfirmedMediaHash {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedHash,
        [Parameter(Mandatory)][string]$Label
    )

    Write-Information "Calculating SHA-256 for $Label. Large ISOs can take several minutes..." -InformationAction Continue
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    Write-Information "$Label SHA-256: $actualHash" -InformationAction Continue

    if ($ExpectedHash) {
        if ($actualHash -ne $ExpectedHash.ToUpperInvariant()) {
            throw "$Label SHA-256 does not match the supplied trusted value."
        }
        return $actualHash
    }

    Write-Warning 'No independent publisher hash was supplied. This digest proves the file does not change after this point, but does not independently authenticate the original download.'
    $confirmation = Read-Choice `
        -Prompt "Confirm that $Label was downloaded from the official Microsoft source" `
        -Choices @('Yes', 'No') `
        -Default 'No'
    if ($confirmation -ne 'Yes') {
        throw "$Label was not confirmed."
    }

    return $actualHash
}

function Test-ExistingImageSet {
    $statePath = Join-Path $stateRoot 'images.json'
    if (-not (Test-Path -LiteralPath $statePath)) {
        return $false
    }

    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.phase -ne 'ImagesVerified' -or @($state.images).Count -ne 2) {
            return $false
        }
        foreach ($image in @($state.images)) {
            if (-not (Test-Path -LiteralPath $image.Path) -or
                (Get-FileHash -LiteralPath $image.Path -Algorithm SHA256).Hash -ne $image.Sha256) {
                return $false
            }
        }
        return $true
    }
    catch {
        return $false
    }
}

New-Item -Path $mediaRoot -ItemType Directory -Force | Out-Null

Write-Information '' -InformationAction Continue
Write-Information 'Azure Local Sandbox Guided Setup' -InformationAction Continue
Write-Information '================================' -InformationAction Continue
Write-Information "Media folder: $mediaRoot" -InformationAction Continue
Write-Information '' -InformationAction Continue

& (Join-Path $PSScriptRoot 'Test-HostReadiness.ps1')

$reuseImages = $false
if (Test-ExistingImageSet) {
    $reuseImages = (Read-Choice `
        -Prompt 'Verified parent images already exist. Reuse them' `
        -Choices @('Yes', 'No') `
        -Default 'Yes') -eq 'Yes'
}

$mediaParameters = @{}
if (-not $reuseImages) {
    if (-not $SkipDownloadPages -and (-not $WindowsServerIsoPath -or -not $AzureLocalIsoPath)) {
        Write-Information '' -InformationAction Continue
        Write-Information 'Download both ISOs from Microsoft and save them locally.' -InformationAction Continue
        Write-Information 'Azure Local requires portal sign-in, subscription selection, and license acceptance.' -InformationAction Continue
        $openPages = Read-Choice `
            -Prompt 'Open the official download pages in the browser now' `
            -Choices @('Yes', 'No') `
            -Default 'Yes'
        if ($openPages -eq 'Yes') {
            Start-Process $azureLocalDownloadGuide
            Start-Process $windowsServerDownloadPage
            Read-Host 'Complete both downloads, then press Enter to continue'
        }
    }

    $WindowsServerIsoPath = Resolve-IsoPath `
        -Path $WindowsServerIsoPath `
        -Title 'Select the Windows Server 2025 ISO'
    $AzureLocalIsoPath = Resolve-IsoPath `
        -Path $AzureLocalIsoPath `
        -Title 'Select the Azure Local ISO'

    $WindowsServerIsoSha256 = Get-ConfirmedMediaHash `
        -Path $WindowsServerIsoPath `
        -ExpectedHash $WindowsServerIsoSha256 `
        -Label 'Windows Server 2025 ISO'
    $AzureLocalIsoSha256 = Get-ConfirmedMediaHash `
        -Path $AzureLocalIsoPath `
        -ExpectedHash $AzureLocalIsoSha256 `
        -Label 'Azure Local ISO'

    if ($WindowsServerImageIndex -eq 0 -or $AzureLocalImageIndex -eq 0) {
        Write-Information '' -InformationAction Continue
        Write-Information 'Available installation images:' -InformationAction Continue
        $listImagesJsonPath = Join-Path $env:TEMP 'AzureLocalSandboxIsoImages.json'
        Remove-Item -LiteralPath $listImagesJsonPath -Force -ErrorAction SilentlyContinue
        & $converterPath `
            -WindowsServerIsoPath $WindowsServerIsoPath `
            -AzureLocalIsoPath $AzureLocalIsoPath `
            -ListImagesJsonPath $listImagesJsonPath `
            -ListImages
        if (-not (Test-Path -LiteralPath $listImagesJsonPath)) {
            throw "The image list was not found at '$listImagesJsonPath'."
        }
        $availableImages = @(Get-Content -LiteralPath $listImagesJsonPath -Raw | ConvertFrom-Json | ForEach-Object { $_ })

        if ($WindowsServerImageIndex -eq 0) {
            Write-Information 'Windows Server 2025 requires the index whose name ends in "(Desktop Experience)". A Server Core index will be rejected during conversion.' -InformationAction Continue
            $WindowsServerImageIndex = Read-ImageIndex `
                -Prompt 'Windows Server 2025 image index (Desktop Experience)' `
                -AvailableImages @($availableImages | Where-Object Media -eq 'WindowsServer') `
                -RequiredNamePattern '\(Desktop Experience\)'
        }
        if ($AzureLocalImageIndex -eq 0) {
            $AzureLocalImageIndex = Read-ImageIndex `
                -Prompt 'Azure Local image index' `
                -AvailableImages @($availableImages | Where-Object Media -eq 'AzureLocal')
        }
    }

    $mediaParameters = @{
        WindowsServerIsoPath   = $WindowsServerIsoPath
        AzureLocalIsoPath      = $AzureLocalIsoPath
        WindowsServerIsoSha256 = $WindowsServerIsoSha256
        AzureLocalIsoSha256    = $AzureLocalIsoSha256
        WindowsServerImageIndex = $WindowsServerImageIndex
        AzureLocalImageIndex    = $AzureLocalImageIndex
    }
}

Write-Information '' -InformationAction Continue
Write-Information 'Enter nested environment credentials. Values are held in memory only.' -InformationAction Continue
$localCredential = Get-Credential `
    -UserName 'Administrator' `
    -Message 'Nested local Administrator (14+ characters)'
$domainCredential = Get-Credential `
    -UserName 'JUMPSTART\Administrator' `
    -Message 'New forest Administrator (14+ characters)'
$lcmCredential = Get-Credential `
    -UserName 'LocalBoxDeployUser' `
    -Message 'Azure Local LCM deployment user (14+ characters)'

if (-not $Mode) {
    $Mode = Read-Choice `
        -Prompt 'Run cloud validation only, or validation followed by the 2.5-3 hour deployment' `
        -Choices @('Validate', 'Deploy') `
        -Default 'Validate'
}

$deploymentParameters = @{
    LocalAdministratorCredential  = $localCredential
    DomainAdministratorCredential = $domainCredential
    LcmCredential                 = $lcmCredential
}
foreach ($entry in $mediaParameters.GetEnumerator()) {
    $deploymentParameters[$entry.Key] = $entry.Value
}
if ($Mode -eq 'Deploy') {
    $deploymentParameters.Deploy = $true
}

Write-Information '' -InformationAction Continue
Write-Information "Starting sandbox workflow in $Mode mode." -InformationAction Continue
Write-Information 'The script is resumable. If a stage fails, correct the issue and launch setup again.' -InformationAction Continue
& $orchestratorPath @deploymentParameters

Write-Information '' -InformationAction Continue
Write-Information "Sandbox workflow completed in $Mode mode." -InformationAction Continue
Read-Host 'Press Enter to close'