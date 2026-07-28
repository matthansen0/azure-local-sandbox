#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules Dism, Hyper-V, Storage

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$WindowsServerIsoPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$AzureLocalIsoPath,

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$WindowsServerIsoSha256,

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$AzureLocalIsoSha256,

    [ValidateRange(0, 100)]
    [int]$WindowsServerImageIndex = 0,

    [ValidateRange(0, 100)]
    [int]$AzureLocalImageIndex = 0,

    [ValidateRange(127GB, 2TB)]
    [long]$BootDiskSizeBytes = 256GB,

    [string]$DestinationDirectory = 'V:\VHDs',

    [string]$StateFile = 'C:\AzureLocalSandbox\State\images.json',

    [switch]$ListImages,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-FreeDriveLetter {
    $usedDriveLetters = @(Get-Volume | Where-Object DriveLetter | Select-Object -ExpandProperty DriveLetter)
    foreach ($driveLetter in [char[]](90..70)) {
        if ($driveLetter -notin $usedDriveLetters) {
            return [string]$driveLetter
        }
    }

    throw 'No temporary drive letter is available.'
}

function Get-IsoInstallImage {
    param(
        [Parameter(Mandatory)]
        [string]$IsoPath
    )

    $resolvedIsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
    $diskImage = Mount-DiskImage -ImagePath $resolvedIsoPath -PassThru
    try {
        $volume = $diskImage | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
        if (-not $volume) {
            throw "Mounted ISO '$resolvedIsoPath' has no accessible volume."
        }

        $sourceRoot = "$($volume.DriveLetter):\sources"
        $installImagePath = @(
            Join-Path $sourceRoot 'install.wim'
            Join-Path $sourceRoot 'install.esd'
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $installImagePath) {
            throw "ISO '$resolvedIsoPath' does not contain sources\install.wim or sources\install.esd."
        }

        $images = @(Get-WindowsImage -ImagePath $installImagePath)
        return [pscustomobject]@{
            IsoPath          = $resolvedIsoPath
            InstallImagePath = $installImagePath
            Images           = $images
        }
    }
    catch {
        Dismount-DiskImage -ImagePath $resolvedIsoPath -ErrorAction SilentlyContinue
        throw
    }
}

function Dismount-IsoInstallImage {
    param($InstallImage)

    if ($InstallImage -and $InstallImage.IsoPath) {
        Dismount-DiskImage -ImagePath $InstallImage.IsoPath -ErrorAction SilentlyContinue
    }
}

function Assert-SourceHash {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExpectedSha256
    )

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualHash -ne $ExpectedSha256.ToUpperInvariant()) {
        throw "SHA-256 mismatch for '$Path'. Expected $ExpectedSha256; received $actualHash."
    }

    return $actualHash
}

function Convert-InstallImageToVhdx {
    param(
        [Parameter(Mandatory)]
        $InstallImage,

        [Parameter(Mandatory)]
        [int]$ImageIndex,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [long]$DiskSizeBytes,

        [Parameter(Mandatory)]
        [string]$ExpectedImageNamePattern,

        [switch]$Overwrite
    )

    $selectedImage = @($InstallImage.Images | Where-Object ImageIndex -eq $ImageIndex)
    if ($selectedImage.Count -ne 1) {
        $availableImages = $InstallImage.Images |
            ForEach-Object { "$($_.ImageIndex): $($_.ImageName)" }
        throw "Image index $ImageIndex was not found in '$($InstallImage.IsoPath)'. Available images: $($availableImages -join '; ')"
    }
    if ($selectedImage[0].ImageName -notmatch $ExpectedImageNamePattern) {
        throw "Image index $ImageIndex ('$($selectedImage[0].ImageName)') does not match expected media pattern '$ExpectedImageNamePattern'."
    }

    if (Test-Path -LiteralPath $DestinationPath) {
        if (-not $Overwrite) {
            throw "Destination '$DestinationPath' already exists. Use -Force only before nested differencing disks are created."
        }
        Remove-Item -LiteralPath $DestinationPath -Force
    }

    $efiDriveLetter = Get-FreeDriveLetter
    $windowsDriveLetter = $null
    $conversionSucceeded = $false
    $mountedVhd = $null

    try {
        New-VHD -Path $DestinationPath -SizeBytes $DiskSizeBytes -Dynamic -BlockSizeBytes 1MB | Out-Null
        $mountedVhd = Mount-VHD -Path $DestinationPath -Passthru
        $disk = $mountedVhd | Get-Disk | Initialize-Disk -PartitionStyle GPT -PassThru

        $efiPartition = New-Partition `
            -DiskNumber $disk.Number `
            -Size 260MB `
            -DriveLetter $efiDriveLetter `
            -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        $efiPartition | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null

        New-Partition `
            -DiskNumber $disk.Number `
            -Size 16MB `
            -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null

        $windowsDriveLetter = Get-FreeDriveLetter
        $windowsPartition = New-Partition `
            -DiskNumber $disk.Number `
            -UseMaximumSize `
            -DriveLetter $windowsDriveLetter `
            -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
        $windowsPartition | Format-Volume `
            -FileSystem NTFS `
            -AllocationUnitSize 4096 `
            -NewFileSystemLabel 'Windows' `
            -Confirm:$false | Out-Null

        $dismOutput = & dism.exe `
            /Apply-Image `
            "/ImageFile:$($InstallImage.InstallImagePath)" `
            "/Index:$ImageIndex" `
            "/ApplyDir:${windowsDriveLetter}:\" `
            /CheckIntegrity
        if ($LASTEXITCODE -ne 0) {
            throw "DISM failed to apply image index ${ImageIndex}: $($dismOutput -join [Environment]::NewLine)"
        }

        $bcdOutput = & bcdboot.exe `
            "${windowsDriveLetter}:\Windows" `
            /s "${efiDriveLetter}:" `
            /f UEFI
        if ($LASTEXITCODE -ne 0) {
            throw "BCDBoot failed: $($bcdOutput -join [Environment]::NewLine)"
        }

        $conversionSucceeded = $true
    }
    finally {
        if ($mountedVhd) {
            Dismount-VHD -Path $DestinationPath -ErrorAction SilentlyContinue
        }
        if (-not $conversionSucceeded) {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        }
    }

    $destinationHash = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash
    return [pscustomobject]@{
        Path       = $DestinationPath
        Sha256     = $destinationHash
        ImageIndex = $ImageIndex
        ImageName  = $selectedImage[0].ImageName
        Version    = [string]$selectedImage[0].Version
        Result     = 'ConvertedFromIso'
    }
}

$windowsInstallImage = $null
$azureLocalInstallImage = $null

try {
    $windowsInstallImage = Get-IsoInstallImage -IsoPath $WindowsServerIsoPath
    $azureLocalInstallImage = Get-IsoInstallImage -IsoPath $AzureLocalIsoPath

    if ($ListImages) {
        @(
            $windowsInstallImage.Images | ForEach-Object {
                [pscustomobject]@{
                    Media      = 'WindowsServer'
                    ImageIndex = $_.ImageIndex
                    ImageName  = $_.ImageName
                    Version    = $_.Version
                }
            }
            $azureLocalInstallImage.Images | ForEach-Object {
                [pscustomobject]@{
                    Media      = 'AzureLocal'
                    ImageIndex = $_.ImageIndex
                    ImageName  = $_.ImageName
                    Version    = $_.Version
                }
            }
        ) | Format-Table -AutoSize
        return
    }

    if (-not $WindowsServerIsoSha256 -or -not $AzureLocalIsoSha256) {
        throw 'Both publisher-provided ISO SHA-256 values are required for conversion.'
    }
    if ($WindowsServerImageIndex -eq 0 -or $AzureLocalImageIndex -eq 0) {
        throw 'Specify both image indexes. Run this script with -ListImages to inspect the media.'
    }

    $windowsSourceHash = Assert-SourceHash `
        -Path $windowsInstallImage.IsoPath `
        -ExpectedSha256 $WindowsServerIsoSha256
    $azureLocalSourceHash = Assert-SourceHash `
        -Path $azureLocalInstallImage.IsoPath `
        -ExpectedSha256 $AzureLocalIsoSha256

    if ($Force -and (Test-Path -LiteralPath 'C:\AzureLocalSandbox\State\nested-vms.json')) {
        throw 'ISO-derived parent images cannot be replaced after nested differencing disks exist.'
    }

    New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null
    $images = @(
        Convert-InstallImageToVhdx `
            -InstallImage $windowsInstallImage `
            -ImageIndex $WindowsServerImageIndex `
            -DestinationPath (Join-Path $DestinationDirectory 'WindowsServer2025.vhdx') `
            -DiskSizeBytes $BootDiskSizeBytes `
            -ExpectedImageNamePattern 'Windows Server 2025' `
            -Overwrite:$Force
        Convert-InstallImageToVhdx `
            -InstallImage $azureLocalInstallImage `
            -ImageIndex $AzureLocalImageIndex `
            -DestinationPath (Join-Path $DestinationDirectory 'AzureLocal.vhdx') `
            -DiskSizeBytes $BootDiskSizeBytes `
            -ExpectedImageNamePattern 'Azure Stack HCI|Azure Local' `
            -Overwrite:$Force
    )

    $stateDirectory = Split-Path -Parent $StateFile
    if ($stateDirectory) {
        New-Item -Path $stateDirectory -ItemType Directory -Force | Out-Null
    }
    [ordered]@{
        phase       = 'ImagesVerified'
        updatedAt   = (Get-Date).ToUniversalTime().ToString('o')
        sourceMedia = @(
            @{ Media = 'WindowsServer'; Sha256 = $windowsSourceHash; ImageIndex = $WindowsServerImageIndex }
            @{ Media = 'AzureLocal'; Sha256 = $azureLocalSourceHash; ImageIndex = $AzureLocalImageIndex }
        )
        images      = $images
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateFile -Encoding UTF8

    $images | Format-Table -AutoSize
}
finally {
    Dismount-IsoInstallImage -InstallImage $windowsInstallImage
    Dismount-IsoInstallImage -InstallImage $azureLocalInstallImage
}