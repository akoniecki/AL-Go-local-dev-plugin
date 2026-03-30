
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RepoRoot,
    [string] $PluginSourceRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $PluginFolderName = 'al-go-local-dev'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRootResolved = (Resolve-Path -LiteralPath $RepoRoot).Path
$pluginTargetRoot = Join-Path $repoRootResolved (Join-Path 'plugins' $PluginFolderName)
$marketplacePath = Join-Path $repoRootResolved '.agents\plugins\marketplace.json'

New-Item -Path (Split-Path -Parent $pluginTargetRoot) -ItemType Directory -Force | Out-Null
New-Item -Path (Split-Path -Parent $marketplacePath) -ItemType Directory -Force | Out-Null

if (Test-Path -LiteralPath $pluginTargetRoot) {
    Remove-Item -LiteralPath $pluginTargetRoot -Recurse -Force
}

Copy-Item -Path (Join-Path $PluginSourceRoot '*') -Destination $pluginTargetRoot -Recurse -Force

$entry = [ordered]@{
    name = 'al-go-local-dev'
    source = [ordered]@{
        source = 'local'
        path   = './plugins/al-go-local-dev'
    }
    policy = [ordered]@{
        installation  = 'AVAILABLE'
        authentication = 'ON_INSTALL'
    }
    category = 'Developer Tools'
}

if (Test-Path -LiteralPath $marketplacePath) {
    $marketplace = Get-Content -LiteralPath $marketplacePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
}
else {
    $marketplace = [pscustomobject]@{
        name = 'local-al-go-plugins'
        interface = [pscustomobject]@{
            displayName = 'Local AL-Go Plugins'
        }
        plugins = @()
    }
}

$plugins = @($marketplace.plugins | Where-Object { $_.name -ne 'al-go-local-dev' })
$plugins += [pscustomobject]$entry
$marketplace.plugins = $plugins
$marketplace | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $marketplacePath -Encoding UTF8

Write-Host "Plugin copied to $pluginTargetRoot"
Write-Host "Marketplace updated at $marketplacePath"
