#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$SourceRoot = 'C:\AzureLocalSandbox\Source',

    [string]$Repository = 'https://github.com/matthansen0/azure-local-sandbox',

    [string]$Ref = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$archivePath = Join-Path $env:TEMP "azure-local-sandbox-$([guid]::NewGuid()).zip"
$extractPath = Join-Path $env:TEMP "azure-local-sandbox-$([guid]::NewGuid())"

try {
    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw "Source directory '$SourceRoot' was not found."
    }

    $archiveUri = "$($Repository.TrimEnd('/'))/archive/refs/heads/$Ref.zip"
    Write-Information "Downloading $archiveUri..." -InformationAction Continue
    Invoke-WebRequest -Uri $archiveUri -OutFile $archivePath -UseBasicParsing

    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
    $payloadRoot = Get-ChildItem -LiteralPath $extractPath -Directory | Select-Object -First 1
    if (-not $payloadRoot) {
        throw 'The downloaded repository archive did not contain a source directory.'
    }

    Write-Information "Updating $SourceRoot..." -InformationAction Continue
    Copy-Item -Path (Join-Path $payloadRoot.FullName '*') -Destination $SourceRoot -Recurse -Force
    Write-Information "Sandbox source updated from '$Ref'. Media, State, and Artifacts were preserved." -InformationAction Continue
}
finally {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
}