param(
    [string] $RepoRoot,
    [string] $FilePath,
    [string[]] $ChangedFiles,
    [string] $WarningBaselinePath,
    [switch] $AllApps,
    [string] $LaunchName,
    [string] $ContainerNameOverride,
    [switch] $OutputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptRoot 'ALGoLocalDev.psm1') -Force

$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$context = Resolve-ALGoLocalDevContext -RepoRoot $RepoRoot -FilePath $FilePath -LaunchName $LaunchName -ContainerNameOverride $ContainerNameOverride

$targetApps = @()
if ($AllApps) {
    $allRoots = @($context.RepoApps | Where-Object { -not $_.IsTestApp } | Select-Object -ExpandProperty AppRoot)
    $sortedRoots = Get-ChangedAppSequence -AppRoots $allRoots -RepoRoot $context.RepoRoot
    $targetApps = foreach ($rootPath in $sortedRoots) {
        $context.RepoApps | Where-Object { $_.AppRoot -eq $rootPath } | Select-Object -First 1
    }
}
elseif ($ChangedFiles -and $ChangedFiles.Count -gt 0) {
    $impactedRoots = @(Get-ImpactedAppsFromFiles -ChangedFiles $ChangedFiles -RepoRoot $context.RepoRoot)
    if ($impactedRoots.Count -eq 0 -and $null -ne $context.CurrentApp) {
        $impactedRoots = @($context.CurrentApp.AppRoot)
    }
    $sortedRoots = Get-ChangedAppSequence -AppRoots $impactedRoots -RepoRoot $context.RepoRoot
    $seedApps = foreach ($rootPath in $sortedRoots) {
        $context.RepoApps | Where-Object { $_.AppRoot -eq $rootPath } | Select-Object -First 1
    }
    $targetApps = @(Get-ResolvedAppSequence -SeedApps $seedApps -RepoApps $context.RepoApps -RepoRoot $context.RepoRoot)
}
else {
    if ($null -eq $context.CurrentApp) {
        throw 'A current app could not be resolved. Supply -FilePath or use -AllApps.'
    }
    $targetApps = @(Get-ResolvedAppSequence -SeedApps @($context.CurrentApp) -RepoApps $context.RepoApps -RepoRoot $context.RepoRoot)
}

if (@($targetApps).Count -eq 0) {
    throw 'No target apps were resolved from the current app or changed files.'
}

$compatibility = Get-AppCompatibilityAssessment -Context $context -Apps $targetApps
$skippedApps = @()
if ($AllApps) {
    $targetApps = @($compatibility.CompatibleApps)
    $skippedApps = @($compatibility.IncompatibleApps)
}
elseif (@($compatibility.IncompatibleApps).Count -gt 0) {
    $totalStopwatch.Stop()
    $result = [pscustomobject]@{
        status              = 'failed'
        context             = Convert-ContextForJson -Context $context
        sessionRoot         = $null
        compilerFolder      = $null
        buildResults        = @()
        compatibilityIssues = @($compatibility.IncompatibleApps)
        skippedApps         = @()
        hasErrors           = $true
        hasNewWarnings      = $false
        timings             = [pscustomobject]@{ totalMs = [int64]$totalStopwatch.ElapsedMilliseconds }
    }
    if ($OutputJson) {
        $result | ConvertTo-Json -Depth 80
    }
    else {
        $result
    }
    exit 1
}

if (@($targetApps).Count -eq 0) {
    throw 'No compatible target apps were resolved for the current container.'
}

$session = New-SessionLayout -RepoRoot $context.RepoRoot
$build = Invoke-ALGoBuildInternal -Context $context -Apps $targetApps -Session $session -WarningBaselinePath $WarningBaselinePath -BlockAnyWarningIfNoBaseline
$hasNewWarnings = @($build.Results | Where-Object { @($_.NewWarnings).Count -gt 0 }).Count -gt 0
$hasErrors = @($build.Results | Where-Object { @($_.Errors).Count -gt 0 -or -not $_.CompileSucceeded }).Count -gt 0
$status = if ($hasErrors -or $hasNewWarnings) { 'failed' } else { 'ok' }
$totalStopwatch.Stop()

$result = [pscustomobject]@{
    status          = $status
    context         = Convert-ContextForJson -Context $context
    sessionRoot     = $session.SessionRoot
    compilerFolder  = $build.CompilerFolder
    buildResults    = @($build.Results | ForEach-Object { Convert-BuildResultForJson -BuildResult $_ -RepoRoot $context.RepoRoot })
    compatibilityIssues = @($compatibility.IncompatibleApps)
    skippedApps     = $skippedApps
    hasErrors       = $hasErrors
    hasNewWarnings  = $hasNewWarnings
    timings         = [pscustomobject]@{
        buildMs = $build.DurationMs
        totalMs = [int64]$totalStopwatch.ElapsedMilliseconds
    }
}

if ($OutputJson) {
    $result | ConvertTo-Json -Depth 80
}
else {
    $result
}

if ($status -ne 'ok') {
    exit 1
}
