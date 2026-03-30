
[CmdletBinding()]
param(
    [string] $PluginSourceRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $PluginFolderName = 'al-go-local-dev'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$homeFolder = [Environment]::GetFolderPath('UserProfile')
$pluginTargetRoot = Join-Path $homeFolder (Join-Path '.codex\plugins' $PluginFolderName)
$marketplacePath = Join-Path $homeFolder '.agents\plugins\marketplace.json'

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
        path   = './.codex/plugins/al-go-local-dev'
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
        name = 'personal-al-go-plugins'
        interface = [pscustomobject]@{
            displayName = 'Personal AL-Go Plugins'
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
