
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InstalledContainerAppIndexCache = @{}
$script:ContainerCompatibilityInfoCache = @{}
$script:ContainerArtifactUrlCache = @{}

function Read-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }

    return $content | ConvertFrom-Json -Depth 100
}

function ConvertTo-HashtableDeep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $hash = @{}
        foreach ($key in $InputObject.Keys) {
            $hash[$key] = ConvertTo-HashtableDeep -InputObject $InputObject[$key]
        }
        return $hash
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $list = @()
        foreach ($item in $InputObject) {
            $list += @(ConvertTo-HashtableDeep -InputObject $item)
        }
        return $list
    }

    $properties = @($InputObject.PSObject.Properties)
    if ($InputObject.PSObject -and $properties.Count -gt 0) {
        $hash = @{}
        foreach ($prop in $properties) {
            $hash[$prop.Name] = ConvertTo-HashtableDeep -InputObject $prop.Value
        }
        return $hash
    }

    return $InputObject
}

function Merge-Hashtable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Base,
        [Parameter(Mandatory)]
        [hashtable] $Overlay
    )

    foreach ($key in $Overlay.Keys) {
        $baseValue = $Base[$key]
        $overlayValue = $Overlay[$key]

        if ($baseValue -is [hashtable] -and $overlayValue -is [hashtable]) {
            $Base[$key] = Merge-Hashtable -Base $baseValue -Overlay $overlayValue
            continue
        }

        $Base[$key] = $overlayValue
    }

    return $Base
}

function Get-PluginWorkspaceRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    return (Join-Path $RepoRoot '.al-go-local-dev')
}

function Get-ExcludedRepoSegments {
    [CmdletBinding()]
    param()

    return @(
        '.git',
        '.alpackages',
        'output',
        'node_modules',
        '.codex-plugin',
        'plugins',
        '.agents',
        '.al-go-local-dev',
        '.al-go-codex'
    )
}

function Get-ContainerCacheKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Context
    )

    $tenant = if ($Context.LaunchConfiguration.PSObject.Properties.Name -contains 'tenant' -and -not [string]::IsNullOrWhiteSpace([string]$Context.LaunchConfiguration.tenant)) {
        [string]$Context.LaunchConfiguration.tenant
    }
    else {
        'default'
    }

    return ('{0}|{1}' -f [string]$Context.ContainerName, $tenant).ToLowerInvariant()
}

function Get-MajorMinorVersionText {
    [CmdletBinding()]
    param(
        [string] $VersionText
    )

    if ([string]::IsNullOrWhiteSpace($VersionText)) {
        return $null
    }

    try {
        $version = [version]$VersionText
        return ('{0}.{1}' -f $version.Major, $version.Minor)
    }
    catch {
        $segments = @($VersionText.Split('.') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($segments.Count -ge 2) {
            return ('{0}.{1}' -f $segments[0], $segments[1])
        }
        return $VersionText
    }
}

function Resolve-RepoRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $StartPath
    )

    $resolvedStart = Resolve-Path -LiteralPath $StartPath -ErrorAction Stop
    $current = Get-Item -LiteralPath $resolvedStart.Path
    if ($current.PSIsContainer -eq $false) {
        $current = $current.Directory
    }

    $best = $null
    while ($null -ne $current) {
        $markers = @(
            (Join-Path $current.FullName '.vscode\launch.json'),
            (Join-Path $current.FullName '.AL-Go\settings.json'),
            (Join-Path $current.FullName 'AL-Go-Settings.json'),
            (Join-Path $current.FullName '.git')
        )

        if ($markers | Where-Object { Test-Path -LiteralPath $_ }) {
            $best = $current.FullName
        }

        $current = $current.Parent
    }

    if ($null -eq $best) {
        throw "Unable to locate the AL-Go repository root from '$StartPath'."
    }

    return $best
}

function Resolve-AppRootFromFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    $resolvedPath = Resolve-Path -LiteralPath $FilePath -ErrorAction Stop
    $current = Get-Item -LiteralPath $resolvedPath.Path
    if ($current.PSIsContainer -eq $false) {
        $current = $current.Directory
    }

    $repoRootResolved = (Resolve-Path -LiteralPath $RepoRoot).Path

    while ($null -ne $current -and $current.FullName.StartsWith($repoRootResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
        $appJsonPath = Join-Path $current.FullName 'app.json'
        if (Test-Path -LiteralPath $appJsonPath -PathType Leaf) {
            return $current.FullName
        }
        $current = $current.Parent
    }

    throw "Unable to resolve the current app from '$FilePath'."
}

function Get-AppInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $AppRoot,
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    $appJsonPath = Join-Path $AppRoot 'app.json'
    $appJson = Read-JsonFile -Path $appJsonPath
    if ($null -eq $appJson) {
        throw "Unable to read app.json from '$AppRoot'."
    }

    $relativePath = [System.IO.Path]::GetRelativePath($RepoRoot, $AppRoot).Replace('\\', '/')
    $dependencies = @()
    if ($appJson.dependencies) {
        foreach ($dependency in $appJson.dependencies) {
            $dependencyId = $null
            if ($dependency.PSObject.Properties.Name -contains 'id') {
                $dependencyId = $dependency.id
            }
            elseif ($dependency.PSObject.Properties.Name -contains 'appId') {
                $dependencyId = $dependency.appId
            }

            $dependencies += [pscustomobject]@{
                Publisher = $dependency.publisher
                Name      = $dependency.name
                Id        = $dependencyId
                Version   = $dependency.version
            }
        }
    }

    $folderName = Split-Path -Path $AppRoot -Leaf
    $isTestApp = $false
    if ($appJson.name -match '(?i)test' -or $folderName -match '(?i)test' -or $relativePath -match '(?i)test') {
        $isTestApp = $true
    }

    return [pscustomobject]@{
        AppRoot      = $AppRoot
        RelativePath = $relativePath
        AppJsonPath  = $appJsonPath
        Id           = if ($appJson.PSObject.Properties.Name -contains 'id') { $appJson.id } elseif ($appJson.PSObject.Properties.Name -contains 'appId') { $appJson.appId } else { $null }
        Name         = $appJson.name
        Publisher    = $appJson.publisher
        Version      = $appJson.version
        IsTestApp    = $isTestApp
        AppJson      = $appJson
        Dependencies = $dependencies
    }
}

function Get-RepoApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    $excludedSegments = @(Get-ExcludedRepoSegments)
    $appJsonFiles = Get-ChildItem -LiteralPath $RepoRoot -Filter 'app.json' -File -Recurse | Where-Object {
        $fullName = $_.FullName
        $include = $true
        foreach ($segment in $excludedSegments) {
            if ($fullName -match [regex]::Escape([System.IO.Path]::DirectorySeparatorChar + $segment + [System.IO.Path]::DirectorySeparatorChar)) {
                $include = $false
                break
            }
        }
        $include
    }

    $apps = foreach ($file in $appJsonFiles) {
        Get-AppInfo -AppRoot $file.Directory.FullName -RepoRoot $RepoRoot
    }

    return @($apps | Sort-Object RelativePath)
}

function Get-LaunchConfigurationFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,
        [string] $AppRoot
    )

    $orderedFiles = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($candidate in @(
        $(if (-not [string]::IsNullOrWhiteSpace($AppRoot)) { Join-Path $AppRoot '.vscode\launch.json' }),
        (Join-Path $RepoRoot '.vscode\launch.json')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }

        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        if ($seen.Add($resolved)) {
            [void]$orderedFiles.Add($resolved)
        }
    }

    $excludedSegments = @(Get-ExcludedRepoSegments)
    $recursiveCandidates = Get-ChildItem -LiteralPath $RepoRoot -Filter 'launch.json' -File -Recurse | Where-Object {
        if ($_.Directory.Name -ne '.vscode') {
            return $false
        }

        $fullName = $_.FullName
        foreach ($segment in $excludedSegments) {
            if ($fullName -match [regex]::Escape([System.IO.Path]::DirectorySeparatorChar + $segment + [System.IO.Path]::DirectorySeparatorChar)) {
                return $false
            }
        }

        return $true
    } | Sort-Object FullName

    foreach ($candidate in $recursiveCandidates) {
        if ($seen.Add($candidate.FullName)) {
            [void]$orderedFiles.Add($candidate.FullName)
        }
    }

    return @($orderedFiles)
}

function Resolve-LaunchConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,
        [string] $AppRoot,
        [string] $LaunchName
    )

    $launchPaths = @(Get-LaunchConfigurationFiles -RepoRoot $RepoRoot -AppRoot $AppRoot)
    if ($launchPaths.Count -eq 0) {
        throw "Unable to find an AL launch configuration under '$RepoRoot'."
    }

    $candidates = @()
    foreach ($launchPath in $launchPaths) {
        $launchJson = Read-JsonFile -Path $launchPath
        if ($null -eq $launchJson -or $null -eq $launchJson.configurations) {
            continue
        }

        foreach ($configuration in @($launchJson.configurations | Where-Object { $_.type -eq 'al' })) {
            $configurationCopy = $configuration | Select-Object *
            Add-Member -InputObject $configurationCopy -NotePropertyName '_launchPath' -NotePropertyValue $launchPath -Force
            $candidates += $configurationCopy
        }
    }

    if ($candidates.Count -eq 0) {
        throw "No AL launch configurations were found under '$RepoRoot'."
    }

    if ($LaunchName) {
        $selected = $candidates | Where-Object { $_.name -eq $LaunchName } | Select-Object -First 1
        if ($null -eq $selected) {
            throw "Launch configuration '$LaunchName' was not found in any launch.json under '$RepoRoot'."
        }
        return $selected
    }

    $preferred = $candidates | Where-Object {
        ($_.name -match '(?i)your own server') -or ($_.name -match '(?i)local') -or ($_.name -match '(?i)docker')
    } | Select-Object -First 1

    if ($null -ne $preferred) {
        return $preferred
    }

    return $candidates | Select-Object -First 1
}

function Resolve-BrowserUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $LaunchConfiguration
    )

    $server = [string]$LaunchConfiguration.server
    if ([string]::IsNullOrWhiteSpace($server)) {
        $server = 'http://bcserver'
    }

    $server = $server.TrimEnd('/')
    $serverInstance = [string]$LaunchConfiguration.serverInstance
    if ([string]::IsNullOrWhiteSpace($serverInstance)) {
        $serverInstance = 'BC'
    }

    if ($server.EndsWith('/' + $serverInstance, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "$server/"
    }

    return "$server/$serverInstance/"
}

function Resolve-ContainerName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $LaunchConfiguration,
        [string] $ContainerNameOverride
    )

    if ($ContainerNameOverride) {
        return $ContainerNameOverride
    }

    $server = [string]$LaunchConfiguration.server
    if ([string]::IsNullOrWhiteSpace($server)) {
        return 'bcserver'
    }

    try {
        $uri = [System.Uri]$server
        if (-not [string]::IsNullOrWhiteSpace($uri.Host) -and $uri.Host -notin @('localhost', '127.0.0.1')) {
            return $uri.Host
        }
    }
    catch {
        if ($server -notmatch '^(?i)localhost|127\.0\.0\.1$') {
            return $server.Trim('/').Split('/')[0]
        }
    }

    return 'bcserver'
}

function New-OptionalCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $LaunchConfiguration
    )

    if ($LaunchConfiguration.PSObject.Properties.Name -contains 'authentication' -and $LaunchConfiguration.authentication -eq 'Windows') {
        return $null
    }

    $username = if ($LaunchConfiguration.PSObject.Properties.Name -contains 'username') { [string]$LaunchConfiguration.username } else { 'admin' }
    if ([string]::IsNullOrWhiteSpace($username)) {
        $username = 'admin'
    }

    $password = if ($LaunchConfiguration.PSObject.Properties.Name -contains 'password') { [string]$LaunchConfiguration.password } else { 'admin' }
    if ([string]::IsNullOrWhiteSpace($password)) {
        $password = 'admin'
    }

    $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
    return [pscredential]::new($username, $secure)
}

function Resolve-ALGoSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,
        [string] $AppRoot
    )

    $candidates = @(
        (Join-Path $RepoRoot '.AL-Go\settings.json'),
        (Join-Path $RepoRoot 'AL-Go-Settings.json'),
        (Join-Path $RepoRoot 'settings.json')
    )

    if ($AppRoot) {
        $appRelativePath = [System.IO.Path]::GetRelativePath($RepoRoot, $AppRoot)
        $candidates += @(
            (Join-Path $RepoRoot (Join-Path $appRelativePath '.AL-Go\settings.json')),
            (Join-Path $RepoRoot (Join-Path $appRelativePath 'AL-Go-Settings.json')),
            (Join-Path $RepoRoot (Join-Path $appRelativePath 'settings.json'))
        )
    }

    $merged = @{}
    $loadedFiles = @()
    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $raw = Read-JsonFile -Path $candidate
            if ($null -ne $raw) {
                $hash = ConvertTo-HashtableDeep -InputObject $raw
                $merged = Merge-Hashtable -Base $merged -Overlay $hash
                $loadedFiles += $candidate
            }
        }
    }

    return [pscustomobject]@{
        Settings    = $merged
        LoadedFiles = $loadedFiles
    }
}

function Resolve-AnalyzerOptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Settings,
        [string] $RepoRoot,
        [switch] $IsTestApp
    )

    $enableAnalyzersOnTestApps = $false
    if ($Settings.ContainsKey('enableCodeAnalyzersOnTestApps')) {
        $enableAnalyzersOnTestApps = [bool]$Settings.enableCodeAnalyzersOnTestApps
    }

    $enableAnalyzers = (-not $IsTestApp.IsPresent) -or $enableAnalyzersOnTestApps

    $options = [ordered]@{
        EnableCodeCop               = $enableAnalyzers -and $Settings.ContainsKey('enableCodeCop') -and [bool]$Settings.enableCodeCop
        EnableUICop                 = $enableAnalyzers -and $Settings.ContainsKey('enableUICop') -and [bool]$Settings.enableUICop
        EnableAppSourceCop          = $enableAnalyzers -and $Settings.ContainsKey('enableAppSourceCop') -and [bool]$Settings.enableAppSourceCop
        EnablePerTenantExtensionCop = $enableAnalyzers -and $Settings.ContainsKey('enablePerTenantExtensionCop') -and [bool]$Settings.enablePerTenantExtensionCop
        CustomCodeCops              = @()
        Features                    = @()
        RulesetFile                 = $null
        EnableExternalRulesets      = $Settings.ContainsKey('enableExternalRulesets') -and [bool]$Settings.enableExternalRulesets
        ReportSuppressedDiagnostics = $Settings.ContainsKey('reportSuppressedDiagnostics') -and [bool]$Settings.reportSuppressedDiagnostics
        FailOn                      = if ($Settings.ContainsKey('failOn')) { [string]$Settings.failOn } else { 'error' }
        VsixFile                    = if ($Settings.ContainsKey('vsixFile')) { [string]$Settings.vsixFile } else { 'default' }
    }

    if ($enableAnalyzers -and $Settings.ContainsKey('customCodeCops') -and $null -ne $Settings.customCodeCops) {
        $custom = @($Settings.customCodeCops)
        foreach ($entry in $custom) {
            $value = [string]$entry
            if ($value -match '^(https?://)') {
                $options.CustomCodeCops += $value
                continue
            }

            $fullPath = if ([System.IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $RepoRoot $value }
            $options.CustomCodeCops += (Resolve-Path -LiteralPath $fullPath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path -ErrorAction SilentlyContinue)
        }
        $options.CustomCodeCops = @($options.CustomCodeCops | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($Settings.ContainsKey('features') -and $null -ne $Settings.features) {
        $options.Features = @($Settings.features)
    }

    if ($Settings.ContainsKey('rulesetFile') -and -not [string]::IsNullOrWhiteSpace([string]$Settings.rulesetFile)) {
        $candidate = [string]$Settings.rulesetFile
        $options.RulesetFile = if ([System.IO.Path]::IsPathRooted($candidate)) { $candidate } else { Join-Path $RepoRoot $candidate }
    }

    return [pscustomobject]$options
}

function Find-AssociatedTestApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $MainApp,
        [Parameter(Mandatory)]
        [object[]] $RepoApps
    )

    $candidates = @($RepoApps | Where-Object {
        $_.IsTestApp -and $_.Dependencies.Id -contains $MainApp.Id
    })

    if ($candidates.Count -eq 0) {
        return $null
    }

    $preferred = $candidates | Where-Object {
        $_.RelativePath -match ('(?i)^' + [regex]::Escape((Split-Path -Path $MainApp.RelativePath -Parent)) + '.*test')
    } | Select-Object -First 1

    if ($null -ne $preferred) {
        return $preferred
    }

    return $candidates | Select-Object -First 1
}

function Get-ResolvedAppSequence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $SeedApps,
        [Parameter(Mandatory)]
        [object[]] $RepoApps,
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    $appsById = @{}
    foreach ($app in $RepoApps) {
        $appId = [string]$app.Id
        if (-not [string]::IsNullOrWhiteSpace($appId)) {
            $appsById[$appId.ToLowerInvariant()] = $app
        }
    }

    $requiredRoots = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $stack = [System.Collections.Stack]::new()
    foreach ($app in $SeedApps) {
        if ($null -ne $app) {
            $stack.Push($app)
        }
    }

    while ($stack.Count -gt 0) {
        $app = $stack.Pop()
        if ($null -eq $app -or [string]::IsNullOrWhiteSpace([string]$app.AppRoot)) {
            continue
        }

        if (-not $requiredRoots.Add($app.AppRoot)) {
            continue
        }

        foreach ($dependency in @($app.Dependencies)) {
            if ($null -eq $dependency) {
                continue
            }

            $dependencyId = [string]$dependency.Id
            if ([string]::IsNullOrWhiteSpace($dependencyId)) {
                continue
            }

            $key = $dependencyId.ToLowerInvariant()
            if ($appsById.ContainsKey($key)) {
                $stack.Push($appsById[$key])
            }
        }
    }

    if ($requiredRoots.Count -eq 0) {
        return @()
    }

    $sortedRoots = Get-ChangedAppSequence -AppRoots @($requiredRoots) -RepoRoot $RepoRoot
    $sequence = foreach ($rootPath in $sortedRoots) {
        $RepoApps | Where-Object { $_.AppRoot -eq $rootPath } | Select-Object -First 1
    }

    return @($sequence | Where-Object { $null -ne $_ })
}

function Get-ChangedAppSequence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $AppRoots,
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    Import-BcContainerHelperModule

    $relativeFolders = foreach ($appRoot in $AppRoots) {
        [System.IO.Path]::GetRelativePath($RepoRoot, $appRoot)
    }

    $selectedRoots = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($appRoot in $AppRoots) {
        [void]$selectedRoots.Add((Resolve-Path -LiteralPath $appRoot).Path)
    }

    $repoAppsById = @{}
    foreach ($repoApp in Get-RepoApps -RepoRoot $RepoRoot) {
        $repoAppId = [string]$repoApp.Id
        if (-not [string]::IsNullOrWhiteSpace($repoAppId)) {
            $repoAppsById[$repoAppId.ToLowerInvariant()] = $repoApp
        }
    }

    $unknownDependencies = [ref]@()
    $sorted = @(Sort-AppFoldersByDependencies -AppFolders $relativeFolders -BaseFolder $RepoRoot -UnknownDependencies $unknownDependencies -WarningAction SilentlyContinue)
    if ($unknownDependencies.Value.Count -gt 0) {
        $dependencyLabels = foreach ($item in $unknownDependencies.Value) {
            $dependencyId = $null
            if ($null -ne $item.PSObject -and $item.PSObject.Properties.Name -contains 'appId' -and -not [string]::IsNullOrWhiteSpace([string]$item.appId)) {
                $dependencyId = [string]$item.appId
            }
            elseif ($null -ne $item.PSObject -and $item.PSObject.Properties.Name -contains 'AppId' -and -not [string]::IsNullOrWhiteSpace([string]$item.AppId)) {
                $dependencyId = [string]$item.AppId
            }

            if ([string]::IsNullOrWhiteSpace($dependencyId)) {
                continue
            }

            $repoDependency = $repoAppsById[$dependencyId.ToLowerInvariant()]
            if ($null -eq $repoDependency) {
                continue
            }

            $resolvedRepoRoot = (Resolve-Path -LiteralPath $repoDependency.AppRoot).Path
            if ($selectedRoots.Contains($resolvedRepoRoot)) {
                continue
            }

            '{0} ({1})' -f $repoDependency.Name, $repoDependency.RelativePath
        }

        $dependencyLabels = @($dependencyLabels | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($dependencyLabels.Count -gt 0) {
            Write-Warning ("Unresolved repo dependencies detected while sorting app folders: {0}" -f ($dependencyLabels -join ', '))
        }
    }

    if ($sorted.Count -eq 0) {
        return $AppRoots
    }

    return @($sorted | ForEach-Object { Join-Path $RepoRoot $_ })
}

function Get-ImpactedAppsFromFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $ChangedFiles,
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    $appRoots = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $ChangedFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
        $candidate = if ([System.IO.Path]::IsPathRooted($file)) { $file } else { Join-Path $RepoRoot $file }
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }

        try {
            $appRoot = Resolve-AppRootFromFile -FilePath $candidate -RepoRoot $RepoRoot
            [void]$appRoots.Add($appRoot)
        }
        catch {
            continue
        }
    }

    return @($appRoots)
}

function Import-BcContainerHelperModule {
    [CmdletBinding()]
    param()

    if (-not (Get-Module -Name BcContainerHelper)) {
        Import-Module BcContainerHelper -ErrorAction Stop | Out-Null
    }
}

function New-SessionLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,
        [string] $SessionName
    )

    if ([string]::IsNullOrWhiteSpace($SessionName)) {
        $SessionName = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    }

    $pluginRoot = Get-PluginWorkspaceRoot -RepoRoot $RepoRoot
    $sessionRoot = Join-Path $pluginRoot (Join-Path 'sessions' $SessionName)
    $outputRoot = Join-Path $sessionRoot 'output'
    $packagesRoot = Join-Path $sessionRoot 'packages'
    $cacheRoot = Join-Path $pluginRoot 'cache'
    $compilerCache = Join-Path $cacheRoot 'compiler'

    foreach ($path in @($sessionRoot, $outputRoot, $packagesRoot, $cacheRoot, $compilerCache)) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
    }

    return [pscustomobject]@{
        SessionName   = $SessionName
        SessionRoot   = $sessionRoot
        OutputRoot    = $outputRoot
        PackagesRoot  = $packagesRoot
        CacheRoot     = $cacheRoot
        CompilerCache = $compilerCache
    }
}

function Resolve-ALGoLocalDevContext {
    [CmdletBinding()]
    param(
        [string] $RepoRoot,
        [string] $FilePath,
        [string] $LaunchName,
        [string] $ContainerNameOverride
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        if ([string]::IsNullOrWhiteSpace($FilePath)) {
            $RepoRoot = Resolve-RepoRoot -StartPath (Get-Location).Path
        }
        else {
            $RepoRoot = Resolve-RepoRoot -StartPath $FilePath
        }
    }

    $repoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $currentAppRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($FilePath) -and (Test-Path -LiteralPath $FilePath)) {
        $currentAppRoot = Resolve-AppRootFromFile -FilePath $FilePath -RepoRoot $repoRoot
    }

    $launchConfiguration = Resolve-LaunchConfiguration -RepoRoot $repoRoot -AppRoot $currentAppRoot -LaunchName $LaunchName
    $browserUrl = Resolve-BrowserUrl -LaunchConfiguration $launchConfiguration
    $containerName = Resolve-ContainerName -LaunchConfiguration $launchConfiguration -ContainerNameOverride $ContainerNameOverride
    $credential = New-OptionalCredential -LaunchConfiguration $launchConfiguration

    $repoApps = Get-RepoApps -RepoRoot $repoRoot
    $currentApp = $null
    if ($currentAppRoot) {
        $currentApp = $repoApps | Where-Object { $_.AppRoot -eq $currentAppRoot } | Select-Object -First 1
        if ($null -eq $currentApp) {
            $currentApp = Get-AppInfo -AppRoot $currentAppRoot -RepoRoot $repoRoot
        }
    }

    $settingsInfo = Resolve-ALGoSettings -RepoRoot $repoRoot -AppRoot $currentAppRoot
    $associatedTestApp = $null
    if ($null -ne $currentApp) {
        $associatedTestApp = Find-AssociatedTestApp -MainApp $currentApp -RepoApps $repoApps
    }

    return [pscustomobject]@{
        RepoRoot          = $repoRoot
        LaunchName        = $launchConfiguration.name
        LaunchPath        = if ($launchConfiguration.PSObject.Properties.Name -contains '_launchPath') { $launchConfiguration._launchPath } else { $null }
        LaunchConfiguration = $launchConfiguration
        BrowserUrl        = $browserUrl
        ContainerName     = $containerName
        Credential        = $credential
        CurrentApp        = $currentApp
        AssociatedTestApp = $associatedTestApp
        RepoApps          = $repoApps
        Settings          = $settingsInfo.Settings
        SettingsFiles     = $settingsInfo.LoadedFiles
    }
}

function Get-CompilerFolderPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Context,
        [Parameter(Mandatory)]
        $Session,
        [string] $VsixFileOverride
    )

    Import-BcContainerHelperModule

    $artifactCacheKey = [string]$Context.ContainerName
    if (-not $script:ContainerArtifactUrlCache.ContainsKey($artifactCacheKey)) {
        $script:ContainerArtifactUrlCache[$artifactCacheKey] = Get-BcContainerArtifactUrl -ContainerName $Context.ContainerName
    }

    $artifactUrl = [string]$script:ContainerArtifactUrlCache[$artifactCacheKey]
    if ([string]::IsNullOrWhiteSpace($artifactUrl)) {
        throw "Unable to resolve the artifact URL from container '$($Context.ContainerName)'."
    }

    $settingsVsix = if ($Context.Settings.ContainsKey('vsixFile')) { [string]$Context.Settings.vsixFile } else { '' }
    $vsixFile = if ($VsixFileOverride) { $VsixFileOverride } else { $settingsVsix }
    if ([string]::IsNullOrWhiteSpace($vsixFile) -or $vsixFile -eq 'default') {
        $vsixFile = ''
    }

    $cacheFolder = Join-Path $Session.CompilerCache $Context.ContainerName
    New-Item -Path $cacheFolder -ItemType Directory -Force | Out-Null

    return New-BcCompilerFolder -ArtifactUrl $artifactUrl -ContainerName ("algo-local-dev-{0}" -f $Context.ContainerName) -CacheFolder $cacheFolder -VsixFile $vsixFile
}

function Get-AppOutputFolderName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $App
    )

    $name = ('{0}-{1}' -f $App.Publisher, $App.Name)
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        $name = $name.Replace($c, '-')
    }
    return $name
}

function Get-DiagnosticsFromErrorLog {
    [CmdletBinding()]
    param(
        [string] $ErrorLogPath,
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($ErrorLogPath) -or -not (Test-Path -LiteralPath $ErrorLogPath)) {
        return @()
    }

    $json = Read-JsonFile -Path $ErrorLogPath
    if ($null -eq $json) {
        return @()
    }

    $results = @()

    if ($json.PSObject.Properties.Name -contains 'runs') {
        foreach ($run in @($json.runs)) {
            foreach ($result in @($run.results)) {
                $file = $null
                $line = $null
                $column = $null
                if ($result.locations) {
                    $location = $result.locations[0]
                    if ($location.physicalLocation) {
                        $artifactUri = $location.physicalLocation.artifactLocation.uri
                        if ($artifactUri) {
                            try {
                                $file = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $artifactUri))
                            }
                            catch {
                                $file = $artifactUri
                            }
                        }
                        if ($location.physicalLocation.region) {
                            $line = $location.physicalLocation.region.startLine
                            $column = $location.physicalLocation.region.startColumn
                        }
                    }
                }

                $message = if ($result.message.text) { $result.message.text } else { $result.message }
                $severity = if ($result.level) { [string]$result.level } else { 'error' }
                $results += [pscustomobject]@{
                    Code     = [string]$result.ruleId
                    Severity = $severity.ToLowerInvariant()
                    Message  = [string]$message
                    File     = $file
                    Line     = $line
                    Column   = $column
                }
            }
        }
        return $results
    }

    if ($json -is [System.Collections.IEnumerable] -and -not ($json -is [string])) {
        foreach ($item in $json) {
            $results += [pscustomobject]@{
                Code     = if ($item.code) { [string]$item.code } else { [string]$item.ruleId }
                Severity = if ($item.severity) { [string]$item.severity } else { 'error' }
                Message  = [string]$item.message
                File     = [string]$item.file
                Line     = $item.line
                Column   = $item.column
            }
        }
        return $results
    }

    return @()
}

function Get-DiagnosticsFromOutputLines {
    [CmdletBinding()]
    param(
        [string[]] $OutputLines,
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    $results = @()
    foreach ($line in @($OutputLines)) {
        $text = [string]$line
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $match = [regex]::Match($text, '^(?<file>.+?)\((?<line>\d+),(?<column>\d+)\):\s+(?<severity>warning|error)\s+(?<code>[A-Za-z]+\d+):\s+(?<message>.+)$')
        $file = $null
        $lineNumber = $null
        $columnNumber = $null

        if ($match.Success) {
            $file = $match.Groups['file'].Value
            $lineNumber = [int]$match.Groups['line'].Value
            $columnNumber = [int]$match.Groups['column'].Value
        }
        else {
            $match = [regex]::Match($text, '^(?<severity>warning|error)\s+(?<code>[A-Za-z]+\d+):\s+(?<message>.+)$')
            if (-not $match.Success) {
                continue
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($file)) {
            try {
                $file = [System.IO.Path]::GetFullPath($file)
            }
            catch {
            }
        }

        $results += [pscustomobject]@{
            Code     = [string]$match.Groups['code'].Value
            Severity = [string]$match.Groups['severity'].Value
            Message  = [string]$match.Groups['message'].Value
            File     = $file
            Line     = $lineNumber
            Column   = $columnNumber
        }
    }

    return @($results)
}

function Merge-Diagnostics {
    [CmdletBinding()]
    param(
        [object[]] $PrimaryDiagnostics,
        [object[]] $AdditionalDiagnostics
    )

    $merged = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($diagnostic in @($PrimaryDiagnostics) + @($AdditionalDiagnostics)) {
        if ($null -eq $diagnostic) {
            continue
        }

        $signature = '{0}|{1}|{2}|{3}|{4}|{5}' -f `
            ([string]$diagnostic.Severity).Trim().ToLowerInvariant(), `
            ([string]$diagnostic.Code).Trim().ToLowerInvariant(), `
            ([string]$diagnostic.File).Trim().ToLowerInvariant(), `
            [string]$diagnostic.Line, `
            [string]$diagnostic.Column, `
            ([string]$diagnostic.Message).Trim()

        if ($seen.Add($signature)) {
            [void]$merged.Add($diagnostic)
        }
    }

    return @($merged.ToArray())
}

function Get-NormalizedWarningSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Diagnostic,
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    $file = ''
    if ($Diagnostic.File) {
        try {
            $full = [System.IO.Path]::GetFullPath([string]$Diagnostic.File)
            $file = [System.IO.Path]::GetRelativePath($RepoRoot, $full).Replace('\\', '/')
        }
        catch {
            $file = [string]$Diagnostic.File
        }
    }

    return ('{0}|{1}|{2}|{3}' -f ([string]$Diagnostic.Code).Trim().ToLowerInvariant(), $file.Trim().ToLowerInvariant(), [string]$Diagnostic.Line, ([string]$Diagnostic.Message).Trim())
}

function Read-WarningBaseline {
    [CmdletBinding()]
    param(
        [string] $BaselinePath,
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    $emptySignatures = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    if ([string]::IsNullOrWhiteSpace($BaselinePath) -or -not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) {
        return ,$emptySignatures
    }

    $baseline = Read-JsonFile -Path $BaselinePath
    if ($null -eq $baseline) {
        return ,$emptySignatures
    }

    $items = @()
    if ($baseline.PSObject.Properties.Name -contains 'warnings') {
        $items = @($baseline.warnings)
    }
    else {
        $items = @($baseline)
    }

    $signatures = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        $signature = if ($item.signature) { [string]$item.signature } else { Get-NormalizedWarningSignature -Diagnostic $item -RepoRoot $RepoRoot }
        [void]$signatures.Add($signature)
    }

    return ,$signatures
}

function Write-WarningBaseline {
    [CmdletBinding()]
    param(
        [object[]] $Warnings,
        [Parameter(Mandatory)]
        [string] $RepoRoot,
        [Parameter(Mandatory)]
        [string] $BaselinePath
    )

    $items = foreach ($warning in $Warnings) {
        [pscustomobject]@{
            signature = Get-NormalizedWarningSignature -Diagnostic $warning -RepoRoot $RepoRoot
            code      = $warning.Code
            severity  = $warning.Severity
            message   = $warning.Message
            file      = $warning.File
            line      = $warning.Line
            column    = $warning.Column
        }
    }

    $payload = [pscustomobject]@{
        createdAt = (Get-Date).ToString('o')
        warnings  = $items
    }

    $directory = Split-Path -Path $BaselinePath -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $BaselinePath -Encoding UTF8
}

function Copy-LocalPackageCacheToSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,
        [Parameter(Mandatory)]
        [object[]] $Apps,
        [Parameter(Mandatory)]
        [string] $DestinationPath
    )

    $null = Copy-PackageFilesToDestination -PackageFolders (Get-PackageFoldersForApps -RepoRoot $RepoRoot -Apps $Apps) -DestinationPath $DestinationPath -PackageNamePatterns @('*.app')
}

function Get-PackageFoldersForApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,
        [Parameter(Mandatory)]
        [object[]] $Apps
    )

    $packageFolders = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($candidate in @(
        (Join-Path $RepoRoot '.alpackages'),
        (Join-Path $RepoRoot '.alPackages')
    )) {
        if ((Test-Path -LiteralPath $candidate -PathType Container) -and $seen.Add((Resolve-Path -LiteralPath $candidate).Path)) {
            [void]$packageFolders.Add((Resolve-Path -LiteralPath $candidate).Path)
        }
    }

    foreach ($app in $Apps) {
        foreach ($candidate in @(
            (Join-Path $app.AppRoot '.alpackages'),
            (Join-Path $app.AppRoot '.alPackages')
        )) {
            if ((Test-Path -LiteralPath $candidate -PathType Container) -and $seen.Add((Resolve-Path -LiteralPath $candidate).Path)) {
                [void]$packageFolders.Add((Resolve-Path -LiteralPath $candidate).Path)
            }
        }
    }

    return @($packageFolders)
}

function Copy-PackageFilesToDestination {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $PackageFolders,
        [Parameter(Mandatory)]
        [string] $DestinationPath,
        [string[]] $PackageNamePatterns = @('*.app')
    )

    $copiedCount = 0
    foreach ($folder in @($PackageFolders)) {
        foreach ($package in Get-ChildItem -LiteralPath $folder -Filter '*.app' -File -ErrorAction SilentlyContinue) {
            if (@($PackageNamePatterns | Where-Object { $package.Name -like $_ }).Count -eq 0) {
                continue
            }
            $destinationFile = Join-Path $DestinationPath $package.Name
            if (Test-Path -LiteralPath $destinationFile -PathType Leaf) {
                Remove-Item -LiteralPath $destinationFile -Force -ErrorAction SilentlyContinue
            }

            $createdLink = $false
            try {
                if ([string]::Equals([System.IO.Path]::GetPathRoot($package.FullName), [System.IO.Path]::GetPathRoot($destinationFile), [System.StringComparison]::OrdinalIgnoreCase)) {
                    New-Item -ItemType HardLink -Path $destinationFile -Target $package.FullName -ErrorAction Stop | Out-Null
                    $createdLink = $true
                }
            }
            catch {
                $createdLink = $false
            }

            if (-not $createdLink) {
                Copy-Item -LiteralPath $package.FullName -Destination $destinationFile -Force
            }

            $copiedCount++
        }
    }

    return $copiedCount
}

function Copy-SupplementalSystemPackagesToSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,
        [Parameter(Mandatory)]
        [object[]] $RepoApps,
        [Parameter(Mandatory)]
        [string] $DestinationPath
    )

    $packageFolders = Get-PackageFoldersForApps -RepoRoot $RepoRoot -Apps $RepoApps
    return (Copy-PackageFilesToDestination -PackageFolders $packageFolders -DestinationPath $DestinationPath -PackageNamePatterns @('Microsoft_System_*.app'))
}

function Get-ContainerCompatibilityInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Context
    )

    $cacheKey = Get-ContainerCacheKey -Context $Context
    if ($script:ContainerCompatibilityInfoCache.ContainsKey($cacheKey)) {
        return $script:ContainerCompatibilityInfoCache[$cacheKey]
    }

    $installedApps = Get-InstalledContainerAppIndex -Context $Context
    $installedValues = @($installedApps.Values)
    $applicationApp = @($installedValues | Where-Object { $_.Name -eq 'Application' } | Select-Object -First 1)
    $systemApplicationApp = @($installedValues | Where-Object { $_.Name -eq 'System Application' } | Select-Object -First 1)
    $baseApplicationApp = @($installedValues | Where-Object { $_.Name -eq 'Base Application' } | Select-Object -First 1)

    $info = [pscustomobject]@{
        ApplicationVersion      = if (@($applicationApp).Count -gt 0) { [string]$applicationApp[0].Version } else { $null }
        ApplicationMajorMinor   = if (@($applicationApp).Count -gt 0) { Get-MajorMinorVersionText -VersionText ([string]$applicationApp[0].Version) } else { $null }
        PlatformVersion         = if (@($systemApplicationApp).Count -gt 0) { [string]$systemApplicationApp[0].Version } else { $null }
        PlatformMajorMinor      = if (@($systemApplicationApp).Count -gt 0) { Get-MajorMinorVersionText -VersionText ([string]$systemApplicationApp[0].Version) } else { $null }
        BaseApplicationVersion  = if (@($baseApplicationApp).Count -gt 0) { [string]$baseApplicationApp[0].Version } else { $null }
        BaseApplicationMajorMinor = if (@($baseApplicationApp).Count -gt 0) { Get-MajorMinorVersionText -VersionText ([string]$baseApplicationApp[0].Version) } else { $null }
    }

    $script:ContainerCompatibilityInfoCache[$cacheKey] = $info
    return $info
}

function Get-AppCompatibilityAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Context,
        [Parameter(Mandatory)]
        [object[]] $Apps
    )

    $containerInfo = Get-ContainerCompatibilityInfo -Context $Context
    $compatibleApps = New-Object System.Collections.Generic.List[object]
    $issues = New-Object System.Collections.Generic.List[object]

    foreach ($app in $Apps) {
        $requiredApplication = if ($app.AppJson.PSObject.Properties.Name -contains 'application') { [string]$app.AppJson.application } else { $null }
        $requiredApplicationMajorMinor = Get-MajorMinorVersionText -VersionText $requiredApplication
        if (-not [string]::IsNullOrWhiteSpace($requiredApplicationMajorMinor) -and -not [string]::IsNullOrWhiteSpace($containerInfo.ApplicationMajorMinor) -and $requiredApplicationMajorMinor -ne $containerInfo.ApplicationMajorMinor) {
            [void]$issues.Add([pscustomobject]@{
                appName               = $app.Name
                appId                 = $app.Id
                appRoot               = $app.AppRoot
                issueType             = 'application_version_mismatch'
                requiredVersion       = $requiredApplication
                requiredMajorMinor    = $requiredApplicationMajorMinor
                containerVersion      = $containerInfo.ApplicationVersion
                containerMajorMinor   = $containerInfo.ApplicationMajorMinor
                message               = ("'{0}' targets application {1}, but container '{2}' exposes application {3}. Choose a matching branch/container before building or publishing this app." -f $app.Name, $requiredApplication, $Context.ContainerName, $containerInfo.ApplicationVersion)
            })
            continue
        }

        $requiredPlatform = if ($app.AppJson.PSObject.Properties.Name -contains 'platform') { [string]$app.AppJson.platform } else { $null }
        $requiredPlatformMajorMinor = Get-MajorMinorVersionText -VersionText $requiredPlatform
        if (-not [string]::IsNullOrWhiteSpace($requiredPlatformMajorMinor) -and -not [string]::IsNullOrWhiteSpace($containerInfo.PlatformMajorMinor) -and $requiredPlatformMajorMinor -ne $containerInfo.PlatformMajorMinor) {
            [void]$issues.Add([pscustomobject]@{
                appName               = $app.Name
                appId                 = $app.Id
                appRoot               = $app.AppRoot
                issueType             = 'platform_version_mismatch'
                requiredVersion       = $requiredPlatform
                requiredMajorMinor    = $requiredPlatformMajorMinor
                containerVersion      = $containerInfo.PlatformVersion
                containerMajorMinor   = $containerInfo.PlatformMajorMinor
                message               = ("'{0}' targets platform {1}, but container '{2}' exposes platform {3}. Choose a matching branch/container before building or publishing this app." -f $app.Name, $requiredPlatform, $Context.ContainerName, $containerInfo.PlatformVersion)
            })
            continue
        }

        [void]$compatibleApps.Add($app)
    }

    return [pscustomobject]@{
        ContainerInfo     = $containerInfo
        CompatibleApps    = @($compatibleApps.ToArray())
        IncompatibleApps  = @($issues.ToArray())
    }
}

function Invoke-ALGoBuildInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Context,
        [Parameter(Mandatory)]
        [object[]] $Apps,
        [Parameter(Mandatory)]
        $Session,
        [string] $WarningBaselinePath,
        [switch] $BlockAnyWarningIfNoBaseline,
        [switch] $RefreshSymbolsOnly
    )

    Import-BcContainerHelperModule

    $buildStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $compilerFolder = Get-CompilerFolderPath -Context $Context -Session $Session
    $baselineSignatures = Read-WarningBaseline -BaselinePath $WarningBaselinePath -RepoRoot $Context.RepoRoot
    $results = @()
    $allWarnings = @()
    $allErrors = @()

    Copy-LocalPackageCacheToSession -RepoRoot $Context.RepoRoot -Apps $Apps -DestinationPath $Session.PackagesRoot

    foreach ($app in $Apps) {
        $appStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $outputFolder = Join-Path $Session.OutputRoot (Get-AppOutputFolderName -App $app)
        New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null

        $appSettingsInfo = Resolve-ALGoSettings -RepoRoot $Context.RepoRoot -AppRoot $app.AppRoot
        $analyzers = Resolve-AnalyzerOptions -Settings $appSettingsInfo.Settings -RepoRoot $Context.RepoRoot -IsTestApp:$app.IsTestApp
        $outputLines = New-Object System.Collections.Generic.List[string]

        $buildParams = @{
            compilerFolder              = $compilerFolder
            appProjectFolder            = $app.AppRoot
            appOutputFolder             = $outputFolder
            appSymbolsFolder            = $Session.PackagesRoot
            CopyAppToSymbolsFolder      = $true
            generateErrorLog            = $true
            FailOn                      = 'none'
            EnableCodeCop               = $analyzers.EnableCodeCop
            EnableUICop                 = $analyzers.EnableUICop
            EnableAppSourceCop          = $analyzers.EnableAppSourceCop
            EnablePerTenantExtensionCop = $analyzers.EnablePerTenantExtensionCop
            enableExternalRulesets      = $analyzers.EnableExternalRulesets
            ReportSuppressedDiagnostics = $analyzers.ReportSuppressedDiagnostics
            outputTo                    = { param($line) $null = $outputLines.Add([string]$line); Write-Host $line }
        }

        if (@($analyzers.CustomCodeCops).Count -gt 0) { $buildParams['CustomCodeCops'] = $analyzers.CustomCodeCops }
        if (@($analyzers.Features).Count -gt 0) { $buildParams['Features'] = $analyzers.Features }
        if ($analyzers.RulesetFile) { $buildParams['RulesetFile'] = $analyzers.RulesetFile }

        $compileSucceeded = $true
        $compileErrorMessage = $null
        try {
            Compile-AppWithBcCompilerFolder @buildParams | Out-Null
        }
        catch {
            $compileSucceeded = $false
            $compileErrorMessage = $_.Exception.Message
        }

        if (-not $compileSucceeded -and $compileErrorMessage -match 'Unable to locate system symbols') {
            $supplementalSystemPackageCount = Copy-SupplementalSystemPackagesToSession -RepoRoot $Context.RepoRoot -RepoApps $Context.RepoApps -DestinationPath $Session.PackagesRoot
            if ($supplementalSystemPackageCount -gt 0) {
                $null = $outputLines.Add('Retrying compile after supplementing shared system packages.')
                Write-Host 'Retrying compile after supplementing shared system packages.'
                $compileSucceeded = $true
                $compileErrorMessage = $null
                try {
                    Compile-AppWithBcCompilerFolder @buildParams | Out-Null
                }
                catch {
                    $compileSucceeded = $false
                    $compileErrorMessage = $_.Exception.Message
                }
            }
        }

        $errorLogPath = Get-ChildItem -LiteralPath $outputFolder -Filter '*.errorLog.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 | Select-Object -ExpandProperty FullName -ErrorAction SilentlyContinue
        $diagnostics = Merge-Diagnostics `
            -PrimaryDiagnostics @(Get-DiagnosticsFromErrorLog -ErrorLogPath $errorLogPath -RepoRoot $Context.RepoRoot) `
            -AdditionalDiagnostics @(Get-DiagnosticsFromOutputLines -OutputLines @($outputLines) -RepoRoot $Context.RepoRoot)
        $warnings = @($diagnostics | Where-Object { $_.Severity -match 'warning|note' })
        $errors = @($diagnostics | Where-Object { $_.Severity -match 'error' })

        if ($compileSucceeded -eq $false -and $errors.Count -eq 0 -and $compileErrorMessage) {
            $errors += [pscustomobject]@{
                Code     = ''
                Severity = 'error'
                Message  = $compileErrorMessage
                File     = $null
                Line     = $null
                Column   = $null
            }
        }

        $newWarnings = @()
        foreach ($warning in $warnings) {
            $signature = Get-NormalizedWarningSignature -Diagnostic $warning -RepoRoot $Context.RepoRoot
            if ($baselineSignatures.Count -eq 0) {
                if ($BlockAnyWarningIfNoBaseline) {
                    $newWarnings += $warning
                }
            }
            elseif (-not $baselineSignatures.Contains($signature)) {
                $newWarnings += $warning
            }
        }

        $appFilePath = Get-ChildItem -LiteralPath $outputFolder -Filter '*.app' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 | Select-Object -ExpandProperty FullName -ErrorAction SilentlyContinue
        if ($RefreshSymbolsOnly) {
            $appFilePath = $null
        }

        $appStopwatch.Stop()

        $result = [pscustomobject]@{
            App                  = $app
            AppRoot              = $app.AppRoot
            AppName              = $app.Name
            AppId                = $app.Id
            OutputFolder         = $outputFolder
            AppFilePath          = $appFilePath
            ErrorLogPath         = $errorLogPath
            CompileSucceeded     = $compileSucceeded -and $errors.Count -eq 0 -and (Test-Path -LiteralPath $appFilePath -PathType Leaf)
            OutputLines          = @($outputLines)
            Diagnostics          = $diagnostics
            Warnings             = $warnings
            Errors               = $errors
            NewWarnings          = $newWarnings
            AnalyzerSettings     = $analyzers
            CompileDurationMs    = [int64]$appStopwatch.ElapsedMilliseconds
        }

        $results += $result
        $allWarnings += $warnings
        $allErrors += $errors
    }

    $buildStopwatch.Stop()

    return [pscustomobject]@{
        CompilerFolder = $compilerFolder
        Results        = $results
        Warnings       = $allWarnings
        Errors         = $allErrors
        DurationMs     = [int64]$buildStopwatch.ElapsedMilliseconds
    }
}

function Get-InstalledContainerAppIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Context
    )

    $cacheKey = Get-ContainerCacheKey -Context $Context
    if ($script:InstalledContainerAppIndexCache.ContainsKey($cacheKey)) {
        return $script:InstalledContainerAppIndexCache[$cacheKey]
    }

    Import-BcContainerHelperModule

    $tenant = if ($Context.LaunchConfiguration.PSObject.Properties.Name -contains 'tenant' -and -not [string]::IsNullOrWhiteSpace([string]$Context.LaunchConfiguration.tenant)) {
        [string]$Context.LaunchConfiguration.tenant
    }
    else {
        'default'
    }

    $installedIndex = @{}
    $installedApps = @(Get-NavContainerAppInfo -containerName $Context.ContainerName -tenant $tenant -installedOnly -useNewFormat -tenantSpecificProperties)
    foreach ($app in $installedApps) {
        $appId = [string]$app.AppId
        if ([string]::IsNullOrWhiteSpace($appId)) {
            continue
        }

        $key = $appId.ToLowerInvariant()
        if (-not $installedIndex.ContainsKey($key)) {
            $installedIndex[$key] = $app
            continue
        }

        try {
            if ([version][string]$app.Version -gt [version][string]$installedIndex[$key].Version) {
                $installedIndex[$key] = $app
            }
        }
        catch {
            $installedIndex[$key] = $app
        }
    }

    $script:InstalledContainerAppIndexCache[$cacheKey] = $installedIndex
    return $installedIndex
}

function Get-TransitiveRepoDependents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $AppId,
        [Parameter(Mandatory)]
        [object[]] $RepoApps
    )

    $dependentsByDependencyId = @{}
    foreach ($app in $RepoApps) {
        foreach ($dependency in @($app.Dependencies)) {
            $dependencyId = [string]$dependency.Id
            if ([string]::IsNullOrWhiteSpace($dependencyId)) {
                continue
            }

            $key = $dependencyId.ToLowerInvariant()
            if (-not $dependentsByDependencyId.ContainsKey($key)) {
                $dependentsByDependencyId[$key] = @()
            }

            $dependentsByDependencyId[$key] += $app
        }
    }

    $result = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $stack = [System.Collections.Stack]::new()
    $stack.Push($AppId.ToLowerInvariant())

    while ($stack.Count -gt 0) {
        $currentId = [string]$stack.Pop()
        if (-not $dependentsByDependencyId.ContainsKey($currentId)) {
            continue
        }

        foreach ($dependent in $dependentsByDependencyId[$currentId]) {
            $dependentId = [string]$dependent.Id
            if ([string]::IsNullOrWhiteSpace($dependentId)) {
                continue
            }

            if ($seen.Add($dependentId)) {
                [void]$result.Add($dependent)
                $stack.Push($dependentId.ToLowerInvariant())
            }
        }
    }

    return @($result.ToArray())
}

function Normalize-PublishReadinessTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $PublishItems
    )

    $normalized = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($PublishItems)) {
        if ($null -eq $item) {
            continue
        }

        $app = if ($item.PSObject.Properties.Name -contains 'App' -and $null -ne $item.App) { $item.App } else { $item }
        $appId = if ($item.PSObject.Properties.Name -contains 'AppId' -and -not [string]::IsNullOrWhiteSpace([string]$item.AppId)) {
            [string]$item.AppId
        }
        else {
            [string]$app.Id
        }
        $appName = if ($item.PSObject.Properties.Name -contains 'AppName' -and -not [string]::IsNullOrWhiteSpace([string]$item.AppName)) {
            [string]$item.AppName
        }
        else {
            [string]$app.Name
        }

        if ($null -eq $app -or [string]::IsNullOrWhiteSpace($appId) -or [string]::IsNullOrWhiteSpace($appName)) {
            throw 'Publish readiness expects build results or app info objects with app Id and Name metadata.'
        }

        [void]$normalized.Add([pscustomobject]@{
            App     = $app
            AppId   = $appId
            AppName = $appName
        })
    }

    return @($normalized.ToArray())
}

function Get-PublishReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Context,
        [Parameter(Mandatory)]
        [object[]] $PublishBuildResults
    )

    $publishTargets = @(Normalize-PublishReadinessTargets -PublishItems $PublishBuildResults)
    if ($publishTargets.Count -eq 0) {
        return [pscustomobject]@{
            IsReady                    = $true
            Summary                    = 'No publish targets were supplied.'
            Issues                     = @()
            RequiresFullBranchRepublish = $false
            SuggestedAction            = $null
            SuggestedSwitch            = $null
            Prompt                     = $null
            SuggestedAppNames          = @()
        }
    }

    $installedApps = Get-InstalledContainerAppIndex -Context $Context
    $repoAppsById = @{}
    foreach ($repoApp in $Context.RepoApps) {
        $repoAppId = [string]$repoApp.Id
        if (-not [string]::IsNullOrWhiteSpace($repoAppId)) {
            $repoAppsById[$repoAppId.ToLowerInvariant()] = $repoApp
        }
    }

    $publishingIds = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($result in $publishTargets) {
        if (-not [string]::IsNullOrWhiteSpace([string]$result.AppId)) {
            [void]$publishingIds.Add([string]$result.AppId)
        }
    }

    $issues = New-Object System.Collections.Generic.List[object]
    $requiredVersionSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $installedVersionSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $requiresFullBranchRepublish = $false
    foreach ($result in $publishTargets) {
        foreach ($dependency in @($result.App.Dependencies)) {
            $dependencyId = [string]$dependency.Id
            if ([string]::IsNullOrWhiteSpace($dependencyId)) {
                continue
            }

            $key = $dependencyId.ToLowerInvariant()
            if ($publishingIds.Contains($dependencyId) -or -not $repoAppsById.ContainsKey($key)) {
                continue
            }

            $dependencyApp = $repoAppsById[$key]
            $requiredVersionText = [string]$dependency.Version
            $installedApp = if ($installedApps.ContainsKey($key)) { $installedApps[$key] } else { $null }
            $installedVersionText = if ($null -eq $installedApp) { '<not installed>' } else { [string]$installedApp.Version }

            $dependencyReady = $false
            if ($null -ne $installedApp) {
                try {
                    $dependencyReady = ([version]$installedVersionText -ge [version]$requiredVersionText)
                }
                catch {
                    $dependencyReady = ($installedVersionText -eq $requiredVersionText)
                }
            }

            if (-not $dependencyReady) {
                $requiresFullBranchRepublish = $true
                [void]$requiredVersionSet.Add($requiredVersionText)
                [void]$installedVersionSet.Add($installedVersionText)
                [void]$issues.Add([pscustomobject]@{
                    issueType        = 'repo_dependency_version_mismatch'
                    appName          = $result.AppName
                    dependencyName   = $dependencyApp.Name
                    requiredVersion  = $requiredVersionText
                    installedVersion = $installedVersionText
                    message          = ("Cannot publish '{0}' by itself because the container is missing repo dependency '{1}' at the required version. Required: {2}. Installed: {3}." -f $result.AppName, $dependencyApp.Name, $requiredVersionText, $installedVersionText)
                })
            }
        }

        $installedDependents = @(Get-TransitiveRepoDependents -AppId $result.AppId -RepoApps $Context.RepoApps | Where-Object {
            $dependentId = [string]$_.Id
            -not [string]::IsNullOrWhiteSpace($dependentId) -and
            (-not $publishingIds.Contains($dependentId)) -and
            $installedApps.ContainsKey($dependentId.ToLowerInvariant())
        })

        if ($installedDependents.Count -gt 0) {
            $requiresFullBranchRepublish = $true
            $dependentNames = @($installedDependents | Select-Object -ExpandProperty Name | Select-Object -Unique)
            [void]$issues.Add([pscustomobject]@{
                issueType      = 'installed_repo_dependents'
                appName        = $result.AppName
                dependentApps  = $dependentNames
                message        = ("Publishing repo dependency '{0}' alone is likely to fail because installed repo apps still depend on it: {1}." -f $result.AppName, ($dependentNames -join ', '))
            })
        }
    }

    $summary = if ($issues.Count -eq 0) {
        'Publish targets are ready.'
    }
    elseif ($requiresFullBranchRepublish) {
        'The container does not match the current branch for a safe partial publish.'
    }
    else {
        'Publish targets are blocked.'
    }

    $prompt = $null
    $suggestedAction = $null
    $suggestedSwitch = $null
    $suggestedAppNames = @()
    if ($requiresFullBranchRepublish) {
        $compatibleRepoApps = Get-AppCompatibilityAssessment -Context $Context -Apps @($Context.RepoApps | Where-Object { -not $_.IsTestApp })
        $suggestedAction = 'republish_full_branch'
        $suggestedSwitch = '-RepublishFullBranch'
        $suggestedAppNames = @($compatibleRepoApps.CompatibleApps | Select-Object -ExpandProperty Name)

        $requiredVersionText = @($requiredVersionSet) -join ', '
        $installedVersionText = @($installedVersionSet) -join ', '
        if (-not [string]::IsNullOrWhiteSpace($requiredVersionText) -and -not [string]::IsNullOrWhiteSpace($installedVersionText)) {
            $prompt = ("The container appears to be on repo app version {0} while this branch needs {1}. Do you want to rebuild and republish all compatible apps from the current branch?" -f $installedVersionText, $requiredVersionText)
        }
        else {
            $prompt = 'The selected publish is blocked by installed repo dependencies. Do you want to rebuild and republish all compatible apps from the current branch?'
        }
    }

    return [pscustomobject]@{
        IsReady                     = ($issues.Count -eq 0)
        Summary                     = $summary
        Issues                      = @($issues.ToArray())
        RequiresFullBranchRepublish = $requiresFullBranchRepublish
        SuggestedAction             = $suggestedAction
        SuggestedSwitch             = $suggestedSwitch
        Prompt                      = $prompt
        SuggestedAppNames           = $suggestedAppNames
    }
}

function Assert-PublishReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Context,
        [Parameter(Mandatory)]
        [object[]] $PublishBuildResults
    )

    $readiness = Get-PublishReadiness -Context $Context -PublishBuildResults $PublishBuildResults
    if (-not $readiness.IsReady) {
        throw ((@($readiness.Issues | Select-Object -ExpandProperty message) | Select-Object -Unique) -join [Environment]::NewLine)
    }

    return $readiness
}

function Get-PublishErrorDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Message
    )

    $normalizedMessage = ($Message -replace '\s+', ' ').Trim()
    if ($normalizedMessage -match "tries to replace the existing AppSource app '([^']+)'.+dependency to the following AppSource apps: '([^']+)'") {
        $blockingAppName = $matches[1]
        $dependentApps = @($matches[2].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        return [pscustomobject]@{
            issueType                   = 'installed_app_dependency_chain_block'
            blockingAppName             = $blockingAppName
            dependentApps               = $dependentApps
            suggestedAction             = 'suite_upgrade_flow'
            mayHavePublishedEarlierApps = $true
            message                     = ("The container blocks in-place replacement of '{0}' because installed apps still depend on it: {1}. A dedicated uninstall/reinstall suite-upgrade flow is required before this branch can be published cleanly." -f $blockingAppName, ($dependentApps -join ', '))
            rawMessage                  = $Message
        }
    }

    return [pscustomobject]@{
        issueType                   = 'publish_failed'
        suggestedAction             = $null
        mayHavePublishedEarlierApps = $false
        message                     = $normalizedMessage
        rawMessage                  = $Message
    }
}

function Publish-AppFilesToContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Context,
        [Parameter(Mandatory)]
        [object[]] $BuildResults,
        [ValidateSet('Add', 'Clean', 'Development', 'ForceSync')]
        [string] $SyncMode = 'Development'
    )

    Import-BcContainerHelperModule

    foreach ($result in $BuildResults) {
        if (-not $result.CompileSucceeded) {
            throw "Cannot publish '$($result.AppName)' because the build did not succeed."
        }

        if (-not (Test-Path -LiteralPath $result.AppFilePath -PathType Leaf)) {
            throw "Cannot publish '$($result.AppName)' because the app file was not found at '$($result.AppFilePath)'."
        }
    }

    $null = Assert-PublishReadiness -Context $Context -PublishBuildResults $BuildResults

    $publishParams = @{
        containerName    = $Context.ContainerName
        appFile          = @($BuildResults | Select-Object -ExpandProperty AppFilePath)
        sync             = $true
        install          = $true
        upgrade          = $true
        syncMode         = $SyncMode
        skipVerification = $true
    }

    if ($null -ne $Context.Credential) {
        $publishParams['useDevEndpoint'] = $true
        $publishParams['credential'] = $Context.Credential
    }

    $publishStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Publish-BcContainerApp @publishParams | Out-Null
    $publishStopwatch.Stop()

    $published = @()
    foreach ($result in $BuildResults) {
        $published += [pscustomobject]@{
            AppName           = $result.AppName
            AppId             = $result.AppId
            AppFilePath       = $result.AppFilePath
            SyncMode          = $SyncMode
            PublishDurationMs = [int64]$publishStopwatch.ElapsedMilliseconds
        }
    }

    return $published
}

function Invoke-AssociatedTestAppIfNeeded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Context,
        [Parameter(Mandatory)]
        [object[]] $PublishedBuildResults,
        [switch] $EnsurePublished
    )

    if ($null -eq $Context.AssociatedTestApp) {
        return [pscustomobject]@{
            Exists   = $false
            Skipped  = $true
            Reason   = 'No dedicated associated test app was found.'
            TestApp  = $null
            Published = @()
        }
    }

    $published = @()
    if ($EnsurePublished) {
        $alreadyPublished = @($PublishedBuildResults | Where-Object { $_.AppId -eq $Context.AssociatedTestApp.Id })
        if ($alreadyPublished.Count -eq 0) {
            throw "The associated test app '$($Context.AssociatedTestApp.Name)' exists but was not built in the current flow. Build and publish it before running tests."
        }
    }

    return [pscustomobject]@{
        Exists    = $true
        Skipped   = $false
        Reason    = $null
        TestApp   = $Context.AssociatedTestApp
        Published = $published
    }
}

function Run-AssociatedTests {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Context
    )

    Import-BcContainerHelperModule

    if ($null -eq $Context.AssociatedTestApp) {
        return [pscustomobject]@{
            Ran      = $false
            Skipped  = $true
            Reason   = 'No dedicated associated test app was found.'
            TestApp  = $null
        }
    }

    $params = @{
        containerName = $Context.ContainerName
        extensionId   = $Context.AssociatedTestApp.Id
        detailed      = $true
    }

    if ($null -ne $Context.Credential) {
        $params['credential'] = $Context.Credential
    }

    Run-TestsInBcContainer @params | Out-Null

    return [pscustomobject]@{
        Ran     = $true
        Skipped = $false
        Reason  = $null
        TestApp = [pscustomobject]@{
            Name = $Context.AssociatedTestApp.Name
            Id   = $Context.AssociatedTestApp.Id
            Path = $Context.AssociatedTestApp.RelativePath
        }
    }
}

function Open-BrowserUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Url
    )

    $opened = $false
    $message = $null
    try {
        Start-Process -FilePath $Url | Out-Null
        $opened = $true
    }
    catch {
        $message = $_.Exception.Message
    }

    return [pscustomobject]@{
        Url     = $Url
        Opened  = $opened
        Message = $message
    }
}

function Convert-ContextForJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Context
    )

    return [pscustomobject]@{
        repoRoot          = $Context.RepoRoot
        launchName        = $Context.LaunchName
        launchPath        = $Context.LaunchPath
        containerName     = $Context.ContainerName
        browserUrl        = $Context.BrowserUrl
        settingsFiles     = $Context.SettingsFiles
        currentApp        = if ($null -eq $Context.CurrentApp) { $null } else {
            [pscustomobject]@{
                name         = $Context.CurrentApp.Name
                id           = $Context.CurrentApp.Id
                publisher    = $Context.CurrentApp.Publisher
                version      = $Context.CurrentApp.Version
                relativePath = $Context.CurrentApp.RelativePath
                isTestApp    = $Context.CurrentApp.IsTestApp
            }
        }
        associatedTestApp = if ($null -eq $Context.AssociatedTestApp) { $null } else {
            [pscustomobject]@{
                name         = $Context.AssociatedTestApp.Name
                id           = $Context.AssociatedTestApp.Id
                publisher    = $Context.AssociatedTestApp.Publisher
                version      = $Context.AssociatedTestApp.Version
                relativePath = $Context.AssociatedTestApp.RelativePath
            }
        }
        credential        = if ($null -eq $Context.Credential) { $null } else {
            [pscustomobject]@{
                username    = $Context.Credential.UserName
                hasPassword = $true
            }
        }
    }
}

function Convert-BuildResultForJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $BuildResult,
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    return [pscustomobject]@{
        appName          = $BuildResult.AppName
        appId            = $BuildResult.AppId
        appRoot          = [System.IO.Path]::GetRelativePath($RepoRoot, $BuildResult.AppRoot).Replace('\\', '/')
        compileSucceeded = $BuildResult.CompileSucceeded
        compileDurationMs = $BuildResult.CompileDurationMs
        appFilePath      = $BuildResult.AppFilePath
        errorLogPath     = $BuildResult.ErrorLogPath
        warnings         = @($BuildResult.Warnings | ForEach-Object {
            [pscustomobject]@{
                code     = $_.Code
                severity = $_.Severity
                message  = $_.Message
                file     = $_.File
                line     = $_.Line
                column   = $_.Column
            }
        })
        newWarnings      = @($BuildResult.NewWarnings | ForEach-Object {
            [pscustomobject]@{
                code     = $_.Code
                severity = $_.Severity
                message  = $_.Message
                file     = $_.File
                line     = $_.Line
                column   = $_.Column
            }
        })
        errors           = @($BuildResult.Errors | ForEach-Object {
            [pscustomobject]@{
                code     = $_.Code
                severity = $_.Severity
                message  = $_.Message
                file     = $_.File
                line     = $_.Line
                column   = $_.Column
            }
        })
    }
}

Export-ModuleMember -Function @(
    'Resolve-ALGoLocalDevContext',
    'Get-RepoApps',
    'Get-ResolvedAppSequence',
    'Get-ChangedAppSequence',
    'Get-ImpactedAppsFromFiles',
    'Get-AppInfo',
    'New-SessionLayout',
    'Get-AppCompatibilityAssessment',
    'Get-PublishReadiness',
    'Get-PublishErrorDetails',
    'Invoke-ALGoBuildInternal',
    'Publish-AppFilesToContainer',
    'Run-AssociatedTests',
    'Open-BrowserUrl',
    'Write-WarningBaseline',
    'Convert-ContextForJson',
    'Convert-BuildResultForJson'
)
