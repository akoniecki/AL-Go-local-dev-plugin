# Changelog

## 1.0.0

Initial public release.

- App-local `launch.json` resolution instead of assuming repo-root launch files
- Branch-versus-container publish readiness checks with `action_required` guidance for `-RepublishFullBranch`
- Warning-baseline capture and reuse under `.al-go-local-dev`
- Compiler stdout diagnostics surfaced in structured JSON results
- Safer strict-mode handling in build, publish, prepare, and baseline flows
- Current-app retry for `Unable to locate system symbols` when required `Microsoft_System_*.app` packages exist elsewhere in the repo
- Pester coverage for mismatch readiness, publish error classification, warning parsing, missing baselines, and publish output shape
