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
Import-Module BcContainerHelper -ErrorAction Stop | Out-Null

$context = Resolve-ALGoLocalDevContext -RepoRoot $RepoRoot -FilePath $FilePath -LaunchName $LaunchName -ContainerNameOverride $ContainerNameOverride
if ($null -eq $context.CurrentApp) {
    throw 'A current app could not be resolved. Supply -FilePath.'
}

$session = New-SessionLayout -RepoRoot $context.RepoRoot
$artifactUrl = Get-BcContainerArtifactUrl -ContainerName $context.ContainerName
$packagesFolder = Join-Path $context.CurrentApp.AppRoot '.alpackages'
New-Item -Path $packagesFolder -ItemType Directory -Force | Out-Null
$compilerFolder = New-BcCompilerFolder -ArtifactUrl $artifactUrl -ContainerName ("algo-codex-symbols-{0}" -f $context.ContainerName) -CacheFolder (Join-Path $session.CompilerCache $context.ContainerName) -PackagesFolder $packagesFolder

$result = [pscustomobject]@{
    status         = 'ok'
    context        = Convert-ContextForJson -Context $context
    compilerFolder = $compilerFolder
    packagesFolder = $packagesFolder
}

if ($OutputJson) {
    $result | ConvertTo-Json -Depth 50
}
else {
    $result
}
