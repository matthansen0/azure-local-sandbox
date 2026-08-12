#Requires -Version 7.2

[CmdletBinding()]
param(
    [uri]$WindowsServerIsoUri = 'https://software-static.download.prss.microsoft.com/dbazure/998969d5-f34g-4e03-ac9d-1f9786c66749/26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso',

    [uri]$AzureLocalIsoUri = 'https://azurestackreleases.download.prss.microsoft.com/dbazure/AzureLocal/ComposedImage/12.2607.0.3096/AzureLocal24H2.26100.32230.LCM.12.2607.0.3096.x64.en-us.iso',

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$WindowsServerIsoSha256 = '7B052573BA7894C9924E3E87BA732CCD354D18CB75A883EFA9B900EA125BFD51',

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$AzureLocalIsoSha256 = 'DE0158617BE91BC0390262A05363C50CDE1BD15D334A3AB15253FF8DD5100F02',

    [ValidateRange(1, 100)]
    [int]$WindowsServerImageIndex = 4,

    [ValidateRange(1, 100)]
    [int]$AzureLocalImageIndex = 1,

    [string]$ResourceGroupName = 'rg-azure-local-sandbox',

    [string]$VirtualMachineName = 'LocalBox-Client',

    [string]$RunCommandName = 'StartUnattendedSandboxDeployment'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredSecrets = @(
    'AZURE_LOCAL_SANDBOX_NESTED_ADMIN_PASSWORD'
    'AZURE_LOCAL_SANDBOX_DOMAIN_ADMIN_PASSWORD'
    'AZURE_LOCAL_SANDBOX_LCM_PASSWORD'
)
foreach ($name in $requiredSecrets) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Environment variable '$name' is required."
    }
}

$virtualMachine = az vm show `
    --resource-group $ResourceGroupName `
    --name $VirtualMachineName `
    --query '{id:id,location:location,powerState:instanceView.statuses[1].displayStatus}' `
    --show-details `
    --only-show-errors `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $virtualMachine) {
    throw "Virtual machine '$VirtualMachineName' was not found in '$ResourceGroupName'."
}

$remoteScriptPath = 'C:\AzureLocalSandbox\Source\scripts\Start-UnattendedSandboxDeployment.ps1'
$launcher = @"
param(
    [string]`$LocalAdministratorPassword,
    [string]`$DomainAdministratorPassword,
    [string]`$LcmPassword
)
if (-not (Test-Path -LiteralPath '$remoteScriptPath')) { throw 'The staged unattended deployment script was not found.' }
& '$remoteScriptPath' ``
    -WindowsServerIsoUri '$($WindowsServerIsoUri.AbsoluteUri)' ``
    -AzureLocalIsoUri '$($AzureLocalIsoUri.AbsoluteUri)' ``
    -WindowsServerIsoSha256 '$WindowsServerIsoSha256' ``
    -AzureLocalIsoSha256 '$AzureLocalIsoSha256' ``
    -WindowsServerImageIndex $WindowsServerImageIndex ``
    -AzureLocalImageIndex $AzureLocalImageIndex ``
    -LocalAdministratorPassword `$LocalAdministratorPassword ``
    -DomainAdministratorPassword `$DomainAdministratorPassword ``
    -LcmPassword `$LcmPassword
"@

$runCommandResourceId = "$($virtualMachine.id)/runCommands/$RunCommandName"
$existingRunCommand = az resource show `
    --ids $runCommandResourceId `
    --query id `
    --only-show-errors `
    --output tsv 2>$null
if ($existingRunCommand) {
    az vm run-command delete `
        --resource-group $ResourceGroupName `
        --vm-name $VirtualMachineName `
        --name $RunCommandName `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to replace managed Run Command '$RunCommandName'."
    }
}

az vm run-command create `
    --resource-group $ResourceGroupName `
    --vm-name $VirtualMachineName `
    --location $virtualMachine.location `
    --name $RunCommandName `
    --script $launcher `
    --protected-parameters `
        "LocalAdministratorPassword=$env:AZURE_LOCAL_SANDBOX_NESTED_ADMIN_PASSWORD" `
        "DomainAdministratorPassword=$env:AZURE_LOCAL_SANDBOX_DOMAIN_ADMIN_PASSWORD" `
        "LcmPassword=$env:AZURE_LOCAL_SANDBOX_LCM_PASSWORD" `
    --timeout-in-seconds 900 `
    --only-show-errors `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw 'Azure Run Command failed to start the unattended deployment task.'
}

Write-Information "Unattended deployment started on $VirtualMachineName." -InformationAction Continue