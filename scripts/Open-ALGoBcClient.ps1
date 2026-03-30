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
$browser = Open-BrowserUrl -Url $context.BrowserUrl
$result = [pscustomobject]@{
    status  = 'ok'
    context = Convert-ContextForJson -Context $context
    browser = [pscustomobject]@{
        url     = $browser.Url
        opened  = $browser.Opened
        message = $browser.Message
    }
}

if ($OutputJson) {
    $result | ConvertTo-Json -Depth 50
}
else {
    $result
}
