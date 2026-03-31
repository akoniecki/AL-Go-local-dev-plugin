
# These are lightweight smoke tests for the pure path and discovery helpers.
# Run on a Windows machine with PowerShell 7 and Pester installed.

Describe 'ALGoLocalDev helper smoke tests' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\scripts\ALGoLocalDev.psm1'
        Remove-Module ALGoLocalDev -ErrorAction SilentlyContinue
        Import-Module $modulePath -Force | Out-Null
    }

    It 'exports the expected public functions' {
        $module = Get-Module ALGoLocalDev
        ($module.ExportedFunctions.Keys -contains 'Resolve-ALGoLocalDevContext') | Should Be $true
        ($module.ExportedFunctions.Keys -contains 'Invoke-ALGoBuildInternal') | Should Be $true
        ($module.ExportedFunctions.Keys -contains 'Publish-AppFilesToContainer') | Should Be $true
    }

    It 'suggests full branch republish from plain app info objects when a repo dependency version is behind in the container' {
        InModuleScope ALGoLocalDev {
            $dependency = [pscustomobject]@{
                Id           = 'dep-id'
                Name         = 'Dependency App'
                Version      = '2.13.0.0'
                IsTestApp    = $false
                Dependencies = @()
            }
            $app = [pscustomobject]@{
                Id           = 'app-id'
                Name         = 'Feature App'
                Version      = '2.13.0.0'
                IsTestApp    = $false
                Dependencies = @([pscustomobject]@{
                    Id      = 'dep-id'
                    Name    = 'Dependency App'
                    Version = '2.13.0.0'
                })
            }
            $repoApps = @($dependency, $app)
            $context = [pscustomobject]@{
                RepoApps = $repoApps
            }

            Mock Get-InstalledContainerAppIndex {
                @{
                    'dep-id' = [pscustomobject]@{ Version = '2.9.0.0' }
                }
            }
            Mock Get-AppCompatibilityAssessment {
                [pscustomobject]@{
                    CompatibleApps   = $repoApps
                    IncompatibleApps = @()
                }
            }

            $readiness = Get-PublishReadiness -Context $context -PublishBuildResults @($app)

            $readiness.IsReady | Should Be $false
            $readiness.RequiresFullBranchRepublish | Should Be $true
            $readiness.SuggestedSwitch | Should Be '-RepublishFullBranch'
            $readiness.Prompt | Should Match '2\.9\.0\.0'
            $readiness.Prompt | Should Match '2\.13\.0\.0'
        }
    }

    It 'treats included repo dependencies as ready when app info objects already cover the full publish plan' {
        InModuleScope ALGoLocalDev {
            $dependency = [pscustomobject]@{
                Id           = 'dep-id'
                Name         = 'Dependency App'
                Version      = '2.13.0.0'
                IsTestApp    = $false
                Dependencies = @()
            }
            $app = [pscustomobject]@{
                Id           = 'app-id'
                Name         = 'Feature App'
                Version      = '2.13.0.0'
                IsTestApp    = $false
                Dependencies = @([pscustomobject]@{
                    Id      = 'dep-id'
                    Name    = 'Dependency App'
                    Version = '2.13.0.0'
                })
            }
            $repoApps = @($dependency, $app)
            $context = [pscustomobject]@{
                RepoApps = $repoApps
            }

            Mock Get-InstalledContainerAppIndex {
                @{
                    'dep-id' = [pscustomobject]@{ Version = '2.9.0.0' }
                }
            }
            Mock Get-AppCompatibilityAssessment {
                [pscustomobject]@{
                    CompatibleApps   = $repoApps
                    IncompatibleApps = @()
                }
            }

            $readiness = Get-PublishReadiness -Context $context -PublishBuildResults @($dependency, $app)

            $readiness.IsReady | Should Be $true
            $readiness.RequiresFullBranchRepublish | Should Be $false
        }
    }

    It 'turns AppSource dependency-chain publish errors into a structured suite-upgrade hint' {
        InModuleScope ALGoLocalDev {
            $details = Get-PublishErrorDetails -Message "Status Code UnprocessableEntity : Unprocessable Entity The extension could not be deployed, because it tries to replace the existing AppSource app 'CREA Integration' with id '1ee7554d-c7a1-44a9-9d5f-547dc29487e9', which is a dependency to the following AppSource apps: 'DOZera POS by CGI Sverige AB,DOZera eCommerce by CGI Sverige AB'."

            $details.issueType | Should Be 'installed_app_dependency_chain_block'
            $details.blockingAppName | Should Be 'CREA Integration'
            $details.dependentApps.Count | Should Be 2
            $details.suggestedAction | Should Be 'suite_upgrade_flow'
            $details.message | Should Match 'dedicated uninstall/reinstall suite-upgrade flow'
        }
    }

    It 'parses compiler text output diagnostics when they are missing from the error log' {
        InModuleScope ALGoLocalDev {
            $diagnostics = Get-DiagnosticsFromOutputLines -RepoRoot 'C:\repo' -OutputLines @(
                'C:\repo\CGI EDI\examples\Received DesAdv.txt(1,1): warning AL1025: The file at location ''C:\repo\CGI EDI\examples\Received DesAdv.txt'' does not match any definition.',
                'error AL1022: A package with publisher ''CGI Sverige AB'' could not be found.'
            )

            $diagnostics.Count | Should Be 2
            $diagnostics[0].Severity | Should Be 'warning'
            $diagnostics[0].Code | Should Be 'AL1025'
            $diagnostics[0].Line | Should Be 1
            $diagnostics[1].Severity | Should Be 'error'
            $diagnostics[1].Code | Should Be 'AL1022'
        }
    }

    It 'returns an empty warning baseline collection when no baseline file exists' {
        InModuleScope ALGoLocalDev {
            $baseline = Read-WarningBaseline -RepoRoot 'C:\repo' -BaselinePath 'C:\repo\.al-go-local-dev\baselines\missing.json'

            $baseline.Count | Should Be 0
        }
    }

    It 'resolves an app root from a new file path that does not exist yet' {
        InModuleScope ALGoLocalDev {
            $repoRoot = Join-Path $TestDrive 'repo'
            $appRoot = Join-Path $repoRoot 'App One'
            New-Item -Path $appRoot -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $appRoot 'app.json') -Value '{}' -Encoding utf8

            $resolved = Resolve-AppRootFromFile -FilePath (Join-Path $appRoot 'src\BrandNewFile.al') -RepoRoot $repoRoot

            $resolved | Should Be ([System.IO.Path]::GetFullPath($appRoot))
        }
    }

    It 'splits comma-separated changed files into impacted apps' {
        InModuleScope ALGoLocalDev {
            $repoRoot = Join-Path $TestDrive 'repo'
            $firstAppRoot = Join-Path $repoRoot 'App One'
            $secondAppRoot = Join-Path $repoRoot 'App Two'
            New-Item -Path (Join-Path $firstAppRoot 'src') -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path $secondAppRoot 'src') -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $firstAppRoot 'app.json') -Value '{}' -Encoding utf8
            Set-Content -Path (Join-Path $secondAppRoot 'app.json') -Value '{}' -Encoding utf8
            Set-Content -Path (Join-Path $firstAppRoot 'src\One.al') -Value 'codeunit 50100 One { }' -Encoding utf8
            Set-Content -Path (Join-Path $secondAppRoot 'src\Two.al') -Value 'codeunit 50101 Two { }' -Encoding utf8

            $impacted = @(Get-ImpactedAppsFromFiles -ChangedFiles @('App One\src\One.al,App Two\src\Two.al') -RepoRoot $repoRoot)
            $firstAppRoot = [System.IO.Path]::GetFullPath($firstAppRoot)
            $secondAppRoot = [System.IO.Path]::GetFullPath($secondAppRoot)

            $impacted.Count | Should Be 2
            ($impacted -contains $firstAppRoot) | Should Be $true
            ($impacted -contains $secondAppRoot) | Should Be $true
        }
    }

    It 'returns only publish result objects from Publish-AppFilesToContainer' {
        InModuleScope ALGoLocalDev {
            $context = [pscustomobject]@{
                ContainerName = 'bcserver'
                Credential    = $null
            }
            $buildResult = [pscustomobject]@{
                CompileSucceeded = $true
                AppName          = 'Feature App'
                AppId            = 'app-id'
                AppFilePath      = 'C:\repo\Feature App\output\Feature.app'
            }

            Mock Import-BcContainerHelperModule {}
            Mock Assert-PublishReadiness { [pscustomobject]@{ IsReady = $true } }
            Mock Publish-BcContainerApp {}
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'C:\repo\Feature App\output\Feature.app' -and $PathType -eq 'Leaf' }

            $published = @(Publish-AppFilesToContainer -Context $context -BuildResults @($buildResult))

            $published.Count | Should Be 1
            $published[0].AppId | Should Be 'app-id'
            $published[0].PSObject.Properties.Name -contains 'PublishDurationMs' | Should Be $true
            Assert-MockCalled Publish-BcContainerApp -Times 1
        }
    }
}
