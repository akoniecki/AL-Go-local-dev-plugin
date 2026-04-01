# AL-Go Local Dev

AL-Go Local Dev is a Codex plugin for Business Central developers who already have a working AL-Go local Docker environment created with `localDevEnv.ps1`.

It helps your Agent to navigate AL-Go repository and operate local Docker container running Business Central. 


AL-Go Local Dev plugin:
- resolves the current app from the file in focus
- reads the target app's `.vscode/launch.json`
- builds with `BcContainerHelper`
- resolves CodeCops new warnings
- publishes the impacted app or apps to container
- runs the associated test app when one exists
- after successfully implementing development task, opens the local Business Central client for manual verification

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

## Install

Run the install scripts from this plugin repository root.

Repo-local install:

```powershell
pwsh -File .\install\Install-RepoPlugin.ps1 -RepoRoot <repo-root>
```

Personal install:

```powershell
pwsh -File .\install\Install-PersonalPlugin.ps1
```

Sample marketplace entries are included in `examples/repo-marketplace.json` and `examples/personal-marketplace.json`.

## Commands

- `Get-ALGoLocalDevContext.ps1`: resolve repo, app, launch profile, container, and browser URL
- `Build-ALGoApp.ps1`: build the current app, impacted apps, or all compatible apps
- `Publish-ALGoApp.ps1`: publish the current app or impacted apps
- `Prepare-ALGoChangeForManualTest.ps1`: build, publish, run tests, and open the browser
- `Run-ALGoAppTests.ps1`: run the dedicated associated test app when one exists
- `Sync-ALGoSymbols.ps1`: refresh symbols for the current app
- `Open-ALGoBcClient.ps1`: open the local Business Central client

## Tested Scenarios

- Current-app build, publish, and browser handoff against a live `bcserver` container
- Current-app resolution from a brand-new AL file path before the file exists on disk
- Warning baseline capture and reuse
- Fast branch-versus-container mismatch preflight for partial publish


## Limitations

- Full-branch republish is detected and guided, but a full uninstall/reinstall suite-upgrade flow is not yet automated
