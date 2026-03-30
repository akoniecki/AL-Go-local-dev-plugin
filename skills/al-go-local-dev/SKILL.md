---
name: al-go-local-dev
description: Use this skill when working in an AL-Go repository that already has a working local Docker dev environment created with localDevEnv.ps1. It builds, publishes, tests, and hands changes over for manual testing in the local Business Central browser using BcContainerHelper-backed scripts.
---

Use this skill when the repository already has a working AL-Go local Docker environment and the goal is to move an AL change to a local manual-test-ready state.

Principles:

- Treat `.vscode/launch.json` as the primary source of truth for the local target environment.
- Focus only on local Docker development. Ignore SaaS sandbox, GitHub workflow, and CI/CD concerns unless the user explicitly asks.
- Do not create, delete, or recreate containers.
- Do not edit `launch.json`, `settings.json`, `AL-Go-Settings.json`, or `app.json` unless the user explicitly asks for that.
- Use BcContainerHelper-backed helper scripts from this plugin whenever they match the task.
- Use the file being edited to determine the current app.
- For impacted-app detection, use the changed files from the current Codex task, not the whole git working tree.
- Any new warning introduced by the current task blocks readiness for manual testing.

Typical workflow:

1. Resolve context with:
   `pwsh -File ./plugins/al-go-local-dev/scripts/Get-ALGoLocalDevContext.ps1 -FilePath <edited-file> -OutputJson`
2. Build and prepare the change for manual testing with:
   `pwsh -File ./plugins/al-go-local-dev/scripts/Prepare-ALGoChangeForManualTest.ps1 -FilePath <edited-file> -ChangedFiles <comma-separated paths> -OutputJson`
3. If the script returns `action_required`, explain the container-versus-branch mismatch and ask whether to rerun with `-RepublishFullBranch`.
4. If the build reports warnings or errors, fix the code and rerun step 2.
5. After success, summarize:
   - which app(s) were built and published
   - whether tests ran or were skipped
   - the browser URL
   - short technical manual verification steps covering the implemented business logic

Other entry points:

- Build current app:
  `pwsh -File ./plugins/al-go-local-dev/scripts/Build-ALGoApp.ps1 -FilePath <edited-file> -OutputJson`
- Build all apps:
  `pwsh -File ./plugins/al-go-local-dev/scripts/Build-ALGoApp.ps1 -RepoRoot <repo-root> -AllApps -OutputJson`
- Publish current or impacted apps:
  `pwsh -File ./plugins/al-go-local-dev/scripts/Publish-ALGoApp.ps1 -FilePath <edited-file> -ChangedFiles <comma-separated paths> -OutputJson`
- Run tests for the current app when a dedicated test app exists:
  `pwsh -File ./plugins/al-go-local-dev/scripts/Run-ALGoAppTests.ps1 -FilePath <edited-file> -OutputJson`
- Refresh symbols for the current app:
  `pwsh -File ./plugins/al-go-local-dev/scripts/Sync-ALGoSymbols.ps1 -FilePath <edited-file> -OutputJson`
- Open the local BC client:
  `pwsh -File ./plugins/al-go-local-dev/scripts/Open-ALGoBcClient.ps1 -FilePath <edited-file> -OutputJson`

Warning baseline workflow:

- If the repository may already contain existing warnings and you need true “new warning” gating, capture a baseline before editing:
  `pwsh -File ./plugins/al-go-local-dev/scripts/New-ALGoWarningBaseline.ps1 -FilePath <edited-file> -BaselinePath ./.al-go-local-dev/baselines/current.json -OutputJson`
- Then pass the same baseline file to build or prepare scripts with `-WarningBaselinePath`.
- If no baseline is supplied, the scripts default to blocking on any warning they see for the targeted apps.

Manual verification handoff:

- After a successful prepare/publish flow, produce 2-5 short technical steps that tell the developer or consultant where to look in Business Central to verify the full business logic changed in the current task.
- Base those steps only on the changed AL objects and code currently in context.
- Do not invent UI details you cannot support from the code.
