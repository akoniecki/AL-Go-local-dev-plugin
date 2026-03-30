# AL-Go Local Dev

[![Pester](https://github.com/akoniecki/AL-Go-local-dev-plugin/actions/workflows/pester.yml/badge.svg)](https://github.com/akoniecki/AL-Go-local-dev-plugin/actions/workflows/pester.yml)

AL-Go Local Dev is a Codex plugin for Business Central developers who already have a working AL-Go local Docker environment created with `localDevEnv.ps1`.

It helps move a change from the edited AL file to a manual-test-ready state in the local container:

- resolves the current app from the file in focus
- reads the target app's `.vscode/launch.json`
- builds with `BcContainerHelper`
- blocks on new warnings
- publishes the impacted app or apps
- runs the associated test app when one exists
- opens the local Business Central client for manual verification

## Requirements

- Windows
- PowerShell 7 (`pwsh`)
- `BcContainerHelper`
- an existing AL-Go local development environment
- an app-local `.vscode/launch.json`

## Scope

- Local Docker development only
- No container creation or deletion
- No edits to `launch.json`, `settings.json`, `AL-Go-Settings.json`, or `app.json`
- No SaaS sandbox or GitHub workflow support

If a partial publish is unsafe because the container does not match the current branch, the plugin returns `action_required` and suggests `-RepublishFullBranch` before it starts compiling.

## Install

Clone this repository first, then run one of the install scripts below from the plugin repository root.

Repo-local install:

```powershell
pwsh -File .\install\Install-RepoPlugin.ps1 -RepoRoot C:\path\to\your\al-go-repo
```

Personal install:

```powershell
pwsh -File .\install\Install-PersonalPlugin.ps1
```

Sample marketplace entries are included in `examples/repo-marketplace.json` and `examples/personal-marketplace.json`.

## Quick Start

Prepare the current change for manual testing:

```powershell
pwsh -File ./plugins/al-go-local-dev/scripts/Prepare-ALGoChangeForManualTest.ps1 `
  -FilePath .\src\MyApp\codeunit\MyCodeunit.al `
  -ChangedFiles .\src\MyApp\codeunit\MyCodeunit.al,.\src\MyApp\page\MyPage.al `
  -OutputJson
```

If the repository already contains known warnings, capture a baseline first:

```powershell
pwsh -File ./plugins/al-go-local-dev/scripts/New-ALGoWarningBaseline.ps1 `
  -FilePath .\src\MyApp\codeunit\MyCodeunit.al `
  -BaselinePath .\.al-go-local-dev\baselines\current.json `
  -OutputJson
```

Then pass `-WarningBaselinePath` to build or prepare commands.

## Commands

- `Get-ALGoLocalDevContext.ps1`: resolve repo, app, launch profile, container, and browser URL
- `Build-ALGoApp.ps1`: build the current app, impacted apps, or all compatible apps
- `Publish-ALGoApp.ps1`: publish the current app or impacted apps
- `Prepare-ALGoChangeForManualTest.ps1`: build, publish, run tests, and open the browser
- `Run-ALGoAppTests.ps1`: run the dedicated associated test app when one exists
- `Sync-ALGoSymbols.ps1`: refresh symbols for the current app
- `Open-ALGoBcClient.ps1`: open the local Business Central client

All scripts return structured JSON with `ok`, `failed`, or `action_required` status values.

## Tested Scenarios

- Current-app build, publish, and browser handoff against a live `bcserver` container
- Warning baseline capture and reuse
- Fast branch-versus-container mismatch preflight for partial publish
- Current-app recovery when required `Microsoft_System_*.app` packages are only present in sibling app package folders

## Limitations

- Full-branch republish is detected and guided, but a full uninstall/reinstall suite-upgrade flow is not yet automated
- Generated folders left inside app roots can still surface as `AL1025` warnings and should be cleaned from the repository
