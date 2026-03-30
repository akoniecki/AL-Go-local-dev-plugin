param(
    [string] $RepoRoot,
    [string] $FilePath,
    [string] $BaselinePath,
    [string] $LaunchName,
    [string] $ContainerNameOverride,
    [switch] $OutputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptRoot 'ALGoLocalDev.psm1') -Force

if ([string]::IsNullOrWhiteSpace($BaselinePath)) {
    throw 'You must supply -BaselinePath.'
}

$context = Resolve-ALGoLocalDevContext -RepoRoot $RepoRoot -FilePath $FilePath -LaunchName $LaunchName -ContainerNameOverride $ContainerNameOverride
if ($null -eq $context.CurrentApp) {
    throw 'A current app could not be resolved. Supply -FilePath.'
}

$targetApps = @(Get-ResolvedAppSequence -SeedApps @($context.CurrentApp) -RepoApps $context.RepoApps -RepoRoot $context.RepoRoot)
$compatibility = Get-AppCompatibilityAssessment -Context $context -Apps $targetApps
if (@($compatibility.IncompatibleApps).Count -gt 0) {
    $result = [pscustomobject]@{
        status              = 'failed'
        context             = Convert-ContextForJson -Context $context
        baselinePath        = $BaselinePath
        warningCount        = 0
        buildResults        = @()
        compatibilityIssues = @($compatibility.IncompatibleApps)
    }
    if ($OutputJson) {
        $result | ConvertTo-Json -Depth 80
    }
    else {
        $result
    }
    exit 1
}

$session = New-SessionLayout -RepoRoot $context.RepoRoot
$build = Invoke-ALGoBuildInternal -Context $context -Apps $targetApps -Session $session -BlockAnyWarningIfNoBaseline:$false
$hasErrors = @($build.Results | Where-Object { @($_.Errors).Count -gt 0 -or -not $_.CompileSucceeded }).Count -gt 0
if ($hasErrors) {
    $result = [pscustomobject]@{
        status              = 'failed'
        context             = Convert-ContextForJson -Context $context
        baselinePath        = $BaselinePath
        warningCount        = 0
        buildResults        = @($build.Results | ForEach-Object { Convert-BuildResultForJson -BuildResult $_ -RepoRoot $context.RepoRoot })
        compatibilityIssues = @()
    }
    if ($OutputJson) {
        $result | ConvertTo-Json -Depth 80
    }
    else {
        $result
    }
    exit 1
}

$targetWarnings = @(
    $build.Results |
        Where-Object { $_.AppId -eq $context.CurrentApp.Id } |
        Select-Object -ExpandProperty Warnings
)
Write-WarningBaseline -Warnings $targetWarnings -RepoRoot $context.RepoRoot -BaselinePath $BaselinePath

$result = [pscustomobject]@{
    status        = 'ok'
    context       = Convert-ContextForJson -Context $context
    baselinePath  = $BaselinePath
    warningCount  = $targetWarnings.Count
    buildResults  = @($build.Results | ForEach-Object { Convert-BuildResultForJson -BuildResult $_ -RepoRoot $context.RepoRoot })
    compatibilityIssues = @()
}

if ($OutputJson) {
    $result | ConvertTo-Json -Depth 80
}
else {
    $result
}
