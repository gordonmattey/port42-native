# DebugHarnesses

In-app `#if DEBUG` spikes and probes. Not test-target suites: they instantiate live app objects
(SCStream, WKWebView, NSPanel), need a real display and TCC grants, and run inside the running app,
so they cannot live in `Tests/` (XCTest/Swift Testing cannot host them). They are de-risking spikes
and repro/health probes, wired to the Debug menu and, where useful, one-shot self-clearing
`PORT42_*_AUTORUN` UserDefaults flags for hands-free runs.

Convention:
- One file per harness, gated entirely in `#if DEBUG`.
- Log results to a `/tmp/*.log` and print a clear PASS/FAIL verdict; the finding is the deliverable.
- Trigger from the Debug menu in `Port42App.swift`, plus an autorun flag for remote/hands-free runs.

Current: `ScreenRecordSpike.swift` (screen.record Step 0). The older spikes/probes
(`PortDesktopSpike`, `GhosttyResizeSpike`, `PortResizeSpike`, `RestWakeProbe`, `PortRenderProbe`,
`GhosttyDebugHarness`) still live under `Services/` and can migrate here in a pure-move sweep.
