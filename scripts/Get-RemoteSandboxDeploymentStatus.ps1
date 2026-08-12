#Requires -Version 7.2

[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-azure-local-sandbox',

    [string]$VirtualMachineName = 'LocalBox-Client',

    [ValidateRange(1, 200)]
    [int]$LogTailLines = 40
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$statusScript = @'
$stateRoot = 'C:\AzureLocalSandbox\State'
$statusPath = Join-Path $stateRoot 'unattended-status.json'
$task = Get-ScheduledTask -TaskName 'AzureLocalSandboxUnattendedDeployment' -ErrorAction SilentlyContinue
$taskInfo = if ($task) { Get-ScheduledTaskInfo -TaskName $task.TaskName } else { $null }
$stageFiles = @(
    'bootstrap.json'
    'images.json'
    'nested-vms.json'
    'guest-disks.json'
    'level-one-guests.json'
    'management-plane.json'
    'arc-registration.json'
    'azure-local-deployment.json'
)
$stages = foreach ($fileName in $stageFiles) {
    $path = Join-Path $stateRoot $fileName
    if (Test-Path -LiteralPath $path) {
        try {
            $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            [ordered]@{ file = $fileName; phase = $state.phase; message = $state.message }
        }
        catch {
            [ordered]@{ file = $fileName; phase = 'Unreadable'; message = $_.Exception.Message }
        }
    }
}
$logPath = 'C:\AzureLocalSandbox\Logs\UnattendedDeployment.log'
[ordered]@{
    status = if (Test-Path -LiteralPath $statusPath) {
        Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    } else {
        $null
    }
    task = if ($task) {
        [ordered]@{
            state = [string]$task.State
            lastRunTime = $taskInfo.LastRunTime
            lastTaskResult = $taskInfo.LastTaskResult
        }
    } else {
        $null
    }
    stages = @($stages)
    logTail = if (Test-Path -LiteralPath $logPath) {
        @(Get-Content -LiteralPath $logPath -Tail LOG_TAIL_LINES)
    } else {
        @()
    }
} | ConvertTo-Json -Depth 8 -Compress
'@.Replace('LOG_TAIL_LINES', [string]$LogTailLines)

$response = az vm run-command invoke `
    --resource-group $ResourceGroupName `
    --name $VirtualMachineName `
    --command-id RunPowerShellScript `
    --scripts $statusScript `
    --only-show-errors `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to query the remote sandbox deployment status.'
}

$message = @($response.value | Where-Object code -like 'ComponentStatus/StdOut/*').message -join [Environment]::NewLine
if (-not $message) {
    throw 'The remote status command returned no data.'
}

$message | ConvertFrom-Json | ConvertTo-Json -Depth 8