# Changelog

## 1.0.1

- Resolve the current app from relative paths and brand-new AL files that do not exist on disk yet, which makes Dev Box manual-test flows work earlier in the edit cycle
- Accept comma-, newline-, and semicolon-separated `-ChangedFiles` input and guard build, publish, and prepare flows when change detection returns no impacted apps
- Add Pester coverage for new-file app resolution and multi-file changed-file parsing
- Refresh release assets and README guidance based on external Dev Box validation

## 1.0.0

Initial public release.

- App-local `launch.json` resolution instead of assuming repo-root launch files
- Branch-versus-container publish readiness checks with `action_required` guidance for `-RepublishFullBranch`
- Warning-baseline capture and reuse under `.al-go-local-dev`
- Compiler stdout diagnostics surfaced in structured JSON results
- Safer strict-mode handling in build, publish, prepare, and baseline flows
- Current-app retry for `Unable to locate system symbols` when required `Microsoft_System_*.app` packages exist elsewhere in the repo
- Pester coverage for mismatch readiness, publish error classification, warning parsing, missing baselines, and publish output shape
