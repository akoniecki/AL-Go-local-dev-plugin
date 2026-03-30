param(
    [string] $RepoRoot,
    [string] $FilePath,
    [string] $LaunchName,
    [string] $ContainerNameOverride,
    [switch] $OutputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptRoot 'ALGoLocalDev.psm1') -Force

$context = Resolve-ALGoLocalDevContext -RepoRoot $RepoRoot -FilePath $FilePath -LaunchName $LaunchName -ContainerNameOverride $ContainerNameOverride
$testStatus = 'ok'
$testResult = $null
try {
    $testResult = Run-AssociatedTests -Context $context
}
catch {
    $testStatus = 'failed'
    $testResult = [pscustomobject]@{
        Ran     = $false
        Skipped = $false
        Reason  = $_.Exception.Message
        TestApp = if ($null -eq $context.AssociatedTestApp) { $null } else { [pscustomobject]@{ Name = $context.AssociatedTestApp.Name; Id = $context.AssociatedTestApp.Id } }
    }
}

$result = [pscustomobject]@{
    status     = if ($testStatus -eq 'ok') { 'ok' } else { 'failed' }
    context    = Convert-ContextForJson -Context $context
    testResult = $testResult
}

if ($OutputJson) {
    $result | ConvertTo-Json -Depth 50
}
else {
    $result
}

if ($result.status -ne 'ok') {
    exit 1
}
