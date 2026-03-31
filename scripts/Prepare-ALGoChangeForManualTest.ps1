param(
    [string] $RepoRoot,
    [string] $FilePath,
    [string[]] $ChangedFiles,
    [string] $WarningBaselinePath,
    [ValidateSet('Add', 'Clean', 'Development', 'ForceSync')]
    [string] $SyncMode = 'Development',
    [switch] $SkipOpenBrowser,
    [switch] $RepublishFullBranch,
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

if (-not $RepublishFullBranch -and $null -eq $context.CurrentApp -and (-not $ChangedFiles -or $ChangedFiles.Count -eq 0)) {
    throw 'A current app could not be resolved. Supply -FilePath or -ChangedFiles.'
}

$targetApps = @()
$seedApps = @()
if ($RepublishFullBranch) {
    $allRoots = @($context.RepoApps | Where-Object { -not $_.IsTestApp } | Select-Object -ExpandProperty AppRoot)
    $sortedRoots = Get-ChangedAppSequence -AppRoots $allRoots -RepoRoot $context.RepoRoot
    $seedApps = foreach ($rootPath in $sortedRoots) {
        $context.RepoApps | Where-Object { $_.AppRoot -eq $rootPath } | Select-Object -First 1
    }
    $targetApps = @($seedApps)
}
else {
    $impactedRoots = @(
        if ($ChangedFiles -and $ChangedFiles.Count -gt 0) {
            Get-ImpactedAppsFromFiles -ChangedFiles $ChangedFiles -RepoRoot $context.RepoRoot
        }
        else {
            $context.CurrentApp.AppRoot
        }
    )
    if ($impactedRoots.Count -eq 0 -and $null -ne $context.CurrentApp) {
        $impactedRoots = @($context.CurrentApp.AppRoot)
    }
    if ($impactedRoots.Count -gt 0) {
        $sortedRoots = Get-ChangedAppSequence -AppRoots $impactedRoots -RepoRoot $context.RepoRoot
        $seedApps = foreach ($rootPath in $sortedRoots) {
            $context.RepoApps | Where-Object { $_.AppRoot -eq $rootPath } | Select-Object -First 1
        }
        $targetApps = @(Get-ResolvedAppSequence -SeedApps $seedApps -RepoApps $context.RepoApps -RepoRoot $context.RepoRoot)
    }
}

if ($null -ne $context.AssociatedTestApp -and ($targetApps.Id -notcontains $context.AssociatedTestApp.Id)) {
    $targetApps += $context.AssociatedTestApp
}

if (@($targetApps).Count -eq 0) {
    throw 'No target apps were resolved from the current app or changed files.'
}

$compatibility = Get-AppCompatibilityAssessment -Context $context -Apps $targetApps
$skippedApps = @()
if ($RepublishFullBranch) {
    $targetApps = @($compatibility.CompatibleApps)
    $skippedApps = @($compatibility.IncompatibleApps)
}
elseif (@($compatibility.IncompatibleApps).Count -gt 0) {
    $totalStopwatch.Stop()
    $result = [pscustomobject]@{
        status               = 'failed'
        readyForManualTest   = $false
        context              = Convert-ContextForJson -Context $context
        sessionRoot          = $null
        compilerFolder       = $null
        buildResults         = @()
        publishedApps        = @()
        testResult           = $null
        browser              = [pscustomobject]@{ url = $context.BrowserUrl; opened = $false }
        compatibilityIssues  = @($compatibility.IncompatibleApps)
        skippedApps          = @()
        timings              = [pscustomobject]@{ totalMs = [int64]$totalStopwatch.ElapsedMilliseconds }
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

$plannedPublishApps = if ($RepublishFullBranch) {
    @($targetApps | Where-Object { -not $_.IsTestApp })
}
else {
    @($seedApps | Where-Object { $null -ne $_ -and -not $_.IsTestApp })
}
$publishReadiness = Get-PublishReadiness -Context $context -PublishBuildResults $plannedPublishApps
if (-not $publishReadiness.IsReady) {
    $totalStopwatch.Stop()
    $result = [pscustomobject]@{
        status               = 'action_required'
        readyForManualTest   = $false
        context              = Convert-ContextForJson -Context $context
        sessionRoot          = $null
        compilerFolder       = $null
        buildResults         = @()
        publishedApps        = @()
        testResult           = $null
        browser              = [pscustomobject]@{ url = $context.BrowserUrl; opened = $false }
        compatibilityIssues  = @($compatibility.IncompatibleApps)
        skippedApps          = $skippedApps
        publishReadiness     = $publishReadiness
        timings              = [pscustomobject]@{
            totalMs = [int64]$totalStopwatch.ElapsedMilliseconds
        }
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
$build = Invoke-ALGoBuildInternal -Context $context -Apps $targetApps -Session $session -WarningBaselinePath $WarningBaselinePath -BlockAnyWarningIfNoBaseline
$hasNewWarnings = @($build.Results | Where-Object { @($_.NewWarnings).Count -gt 0 }).Count -gt 0
$hasErrors = @($build.Results | Where-Object { @($_.Errors).Count -gt 0 -or -not $_.CompileSucceeded }).Count -gt 0

if ($hasErrors -or $hasNewWarnings) {
    $result = [pscustomobject]@{
        status               = 'failed'
        readyForManualTest   = $false
        context              = Convert-ContextForJson -Context $context
        sessionRoot          = $session.SessionRoot
        compilerFolder       = $build.CompilerFolder
        buildResults         = @($build.Results | ForEach-Object { Convert-BuildResultForJson -BuildResult $_ -RepoRoot $context.RepoRoot })
        publishedApps        = @()
        testResult           = $null
        browser              = [pscustomobject]@{ url = $context.BrowserUrl; opened = $false }
        compatibilityIssues  = @($compatibility.IncompatibleApps)
        skippedApps          = $skippedApps
        timings              = [pscustomobject]@{
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
    exit 1
}

$seedAppIds = @($seedApps | Where-Object { $null -ne $_ } | Select-Object -ExpandProperty Id)
$publishTargets = if ($RepublishFullBranch) {
    @($build.Results | Where-Object { -not $_.App.IsTestApp })
}
else {
    @($build.Results | Where-Object { -not $_.App.IsTestApp -and ($seedAppIds -contains $_.AppId) })
}

$publishQueue = @($publishTargets)
if ($null -ne $context.AssociatedTestApp) {
    $testBuildResult = @($build.Results | Where-Object { $_.AppId -eq $context.AssociatedTestApp.Id }) | Select-Object -First 1
    if ($null -ne $testBuildResult) {
        $publishQueue += @($testBuildResult)
    }
}

$publishStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $publishedApps = @(Publish-AppFilesToContainer -Context $context -BuildResults $publishQueue -SyncMode $SyncMode)
    $publishStopwatch.Stop()
}
catch {
    $publishStopwatch.Stop()
    $publishError = Get-PublishErrorDetails -Message $_.Exception.Message
    if ($publishQueue.Count -gt 1) {
        $publishError | Add-Member -NotePropertyName 'mayHavePublishedEarlierApps' -NotePropertyValue $true -Force
    }

    $totalStopwatch.Stop()
    $result = [pscustomobject]@{
        status               = 'failed'
        readyForManualTest   = $false
        context              = Convert-ContextForJson -Context $context
        sessionRoot          = $session.SessionRoot
        compilerFolder       = $build.CompilerFolder
        buildResults         = @($build.Results | ForEach-Object { Convert-BuildResultForJson -BuildResult $_ -RepoRoot $context.RepoRoot })
        publishedApps        = @()
        testResult           = $null
        browser              = [pscustomobject]@{ url = $context.BrowserUrl; opened = $false }
        compatibilityIssues  = @($compatibility.IncompatibleApps)
        skippedApps          = $skippedApps
        publishError         = $publishError
        timings              = [pscustomobject]@{
            buildMs   = $build.DurationMs
            publishMs = [int64]$publishStopwatch.ElapsedMilliseconds
            totalMs   = [int64]$totalStopwatch.ElapsedMilliseconds
        }
    }
    if ($OutputJson) {
        $result | ConvertTo-Json -Depth 80
    }
    else {
        $result
    }
    exit 1
}

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

if ($testStatus -ne 'ok') {
    $result = [pscustomobject]@{
        status               = 'failed'
        readyForManualTest   = $false
        context              = Convert-ContextForJson -Context $context
        sessionRoot          = $session.SessionRoot
        compilerFolder       = $build.CompilerFolder
        buildResults         = @($build.Results | ForEach-Object { Convert-BuildResultForJson -BuildResult $_ -RepoRoot $context.RepoRoot })
        publishedApps        = $publishedApps
        testResult           = $testResult
        browser              = [pscustomobject]@{ url = $context.BrowserUrl; opened = $false }
        compatibilityIssues  = @($compatibility.IncompatibleApps)
        skippedApps          = $skippedApps
        timings              = [pscustomobject]@{
            buildMs   = $build.DurationMs
            publishMs = [int64]$publishStopwatch.ElapsedMilliseconds
            totalMs   = [int64]$totalStopwatch.ElapsedMilliseconds
        }
    }
    if ($OutputJson) {
        $result | ConvertTo-Json -Depth 80
    }
    else {
        $result
    }
    exit 1
}

$browser = if ($SkipOpenBrowser) {
    [pscustomobject]@{ Url = $context.BrowserUrl; Opened = $false; Message = 'Browser open was skipped.' }
}
else {
    Open-BrowserUrl -Url $context.BrowserUrl
}

$totalStopwatch.Stop()

$result = [pscustomobject]@{
    status             = 'ok'
    readyForManualTest = $true
    context            = Convert-ContextForJson -Context $context
    sessionRoot        = $session.SessionRoot
    compilerFolder     = $build.CompilerFolder
    buildResults       = @($build.Results | ForEach-Object { Convert-BuildResultForJson -BuildResult $_ -RepoRoot $context.RepoRoot })
    publishedApps      = $publishedApps
    testResult         = $testResult
    browser            = [pscustomobject]@{ url = $browser.Url; opened = $browser.Opened; message = $browser.Message }
    compatibilityIssues = @($compatibility.IncompatibleApps)
    skippedApps        = $skippedApps
    timings            = [pscustomobject]@{
        buildMs   = $build.DurationMs
        publishMs = [int64]$publishStopwatch.ElapsedMilliseconds
        totalMs   = [int64]$totalStopwatch.ElapsedMilliseconds
    }
}

if ($OutputJson) {
    $result | ConvertTo-Json -Depth 80
}
else {
    $result
}
