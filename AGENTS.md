# AGENTS.md

This file gives coding agents the initial context needed to change foldelight safely. Read it before editing. Use the focused code map below instead of scanning every historical report.

## Project identity

- Product: **foldelight**
- Creator: **Dario Farzati**
- License: **AGPL-3.0-only**
- Bundle identifier: `com.lufzle.foldelight`
- Swift package, executable, and module: `foldelight`
- Platform: macOS 14 or later
- Dependencies: Apple frameworks only
- Built app: `dist/foldelight.app`

Do not introduce the former project name or other creator attribution. Preserve copyright and SPDX headers in source files.

## Product model

foldelight reads the MacBook hinge angle and renders a live folding-glass view of the built-in display. The captured desktop stays on a fixed, fully open plane. A separate virtual glass plane follows the lid. The effect covers the complete built-in display, including the menu bar.

The key visual invariants are:

- The fold starts below the activation angle. The default is 90°.
- The virtual lid and manual preview range from 0° through 132°.
- The desktop stays visually fixed while projection through the glass changes.
- Rounded display corners exist from the first active frame through maximum fold.
- Blur grows with separation and concentrates near the lifted boundary.
- Vignette shades both sides and the lifted edge while preserving the hinge-side center.
- The final 20% of fold travel fades continuously to exact black.
- Opening uses the same geometry and fade curve in reverse.
- The effect includes the menu bar. Never add a protected top strip.
- The open state is exact neutral output.

Current defaults live in `EffectSettings`:

- Blur: `0.9`
- Vignette: `0.5` (stored internally as `shadow` for settings compatibility)
- Activation angle: `90.0`

Saved values use the app's UserDefaults domain. A code default change does not overwrite an existing user's values. `Reset effect` creates a fresh `EffectSettings` value.

## Start here

Read these files for most changes:

| Area | Primary files |
| --- | --- |
| App lifecycle, menu, window policy | `Sources/foldelight/main.swift` |
| State, persistence, commands | `Sources/foldelight/AppModel.swift` |
| Settings and About UI | `Sources/foldelight/SettingsView.swift` |
| Effect defaults and angle mapping | `Sources/foldelight/Effect.swift`, `FoldBlackout.swift` |
| HID sensor input | `Sources/foldelight/LidSensor.swift`, `LidReportSelection.swift` |
| Sparse-motion reconstruction | `Sources/foldelight/LidMotionEstimator.swift`, `LatestAngleInput.swift` |
| Screen capture and overlay | `Sources/foldelight/DesktopCapture.swift`, `DesktopOverlayPolicy.swift` |
| Live scheduling | `Sources/foldelight/LiveRenderWorker.swift`, `RenderExecutor.swift`, `MetalFrameClock.swift` |
| GPU renderer and shader | `Sources/foldelight/Renderer.swift`, `Resources/Bend.metal` |
| Miniature and interaction | `Sources/foldelight/Preview.swift`, `PreviewLidDrag.swift`, `LidAngleSlider.swift` |
| Diagnostics | `Sources/foldelight/DebugLog.swift`, `DiagnosticRecorder.swift` |
| Packaging | `Package.swift`, `Tools/build-app.sh` |
| Test and mutation commands | `TESTING.md`, `Tools/mutation-test.py` |

Check production code and current tests before relying on documentation.

## Runtime data flow

1. `LidSensor` opens the HID device, then reads it on a serial user-interactive queue.
2. Its direct sample callback feeds `DesktopCapture` before `AppModel` receives throttled UI telemetry.
3. `DesktopCapture` captures native ScreenCaptureKit frames into a latest-value mailbox.
4. Sensor or capture changes wake `LiveRenderWorker`.
5. `LidMotionEstimator` predicts only within bounded age, velocity, lead, and offset limits.
6. `LiveRenderWorker` requests drawables from the display clock and submits Metal work through `RenderExecutor`.
7. `BendRenderer` updates the compact blur pyramid only when source damage and effect state require it.
8. The overlay appears only while an effect frame is needed. It stays excluded from its own capture stream.

Do not move HID polling, capture callbacks, GPU submission, or per-frame work onto the main thread. UI telemetry is intentionally slower than the direct renderer path.

## Sensor rules

Apple does not document the report layouts used here. Report 1 supplies whole degrees. Report 7 can supply hundredths only when `PreciseLidCapability` matches the exact vendor, product, and descriptor. `LidReportSelection` brackets a fine read with coarse reads and requires agreement. A failed fine read falls back to report 1 in the same call and disables precision until reconnect.

Three consecutive read failures stop polling. `Reconnect lid sensor` closes and reopens the device, resets failure and report-selection state, and resumes polling. Keep the recovery action unless the sensor lifecycle changes.

## Capture and overlay rules

`DesktopOverlayPolicy` creates a borderless, nonactivating panel above the status-bar level. It joins all spaces, ignores mouse events, and uses the complete built-in display frame. The ScreenCaptureKit filter must resolve and exclude that exact overlay window before capture starts. Fail closed if exclusion cannot be verified, or the capture will recurse.

Set `includeMenuBar` where the installed SDK supports it. Do not exclude all foldelight windows: Settings and menus are part of the desktop image. The live stream requests native pixels, the display's maximum refresh rate, BGRA, a queue depth of three, no cursor, and no audio.

Screen Recording permission belongs to the signed bundle identity. Replacing an ad-hoc binary can invalidate an apparently enabled permission entry. Use the same development certificate for iterative native checks.

## Rendering and performance rules

The renderer is latency-sensitive. Preserve these properties unless measurements justify a change:

- One frame of drawable latency.
- Display-link deadlines instead of a free-running animation timer.
- Latest-value mailboxes for capture and sensor input.
- No wait for a drawable or GPU completion on the main thread.
- Nonblocking GPU backpressure with completion-based permit release.
- Dirty-frame suppression when inputs are unchanged.
- Half-resolution compact Gaussian pyramid with only required levels.
- Damage accumulation until a pyramid refresh succeeds.
- Cubic reconstruction from explicit adjacent mip levels.
- Identical `BendUniforms` field order and layout in Swift and Metal.
- Captured image-buffer lifetime through GPU completion.
- Exact all-pixel black output at the fold stop.

The shader works in source-image pixels for its rounded boundary and blur scale. Keep logical corner radius consistent across backing scales. A visual change needs GPU tests or deterministic exported frames. A timing change needs release measurements. Debug logging and diagnostic recording add overhead.

## UI behavior

The window has only Settings and About tabs. Both use the same interactive MacBook miniature and renderer. The miniature supports dragging, keyboard and accessibility increment/decrement, a 0–132° range, and reopening from fully closed.

The Settings track has two independent handles on one 0–132° scale. The cyan preview handle can traverse the full range. The gold activation handle is limited to 45–132° and rounds to whole degrees. The handles can cross or overlap and must remain independently selectable.

`Match lid angle` mirrors the physical sensor. Dragging the miniature or preview handle turns matching off and retains the displayed pose. The normal sensor-connected message is intentionally hidden. Sensor errors remain visible. Escape pauses only while foldelight has keyboard focus. There is no global pause shortcut.

The app uses accessory activation while only the menu item is present. Opening Settings switches to regular activation so the app appears in the Dock and Command-Tab. Closing the window returns it to accessory mode.

## Build and verification

Run commands from the repository root.

```sh
swift test -c release
bash Tools/build-app.sh
```

For a stable permission identity, use:

```sh
FOLDELIGHT_SIGNING_IDENTITY="CERTIFICATE_HASH" bash Tools/build-app.sh
codesign --verify --deep --strict dist/foldelight.app
```

Invoke the build script with `bash`. It replaces the executable atomically because overwriting a running signed binary can terminate it with `CODESIGNING / Invalid Page`.

Use the diagnostic binary for a read-only environment check:

```sh
dist/foldelight.app/Contents/MacOS/foldelight --diagnose
```

Use targeted tests while iterating, then run the complete release suite. `TESTING.md` lists opt-in flags for CPU, GPU, live presentation, capture, and export tests. Optional tests skip unless their environment variable is set.

Validate mutation anchors after changes to production strings:

```sh
python3 -m unittest discover -s Tools -p 'test_mutation_runner.py'
python3 Tools/mutation-test.py --validate-anchors
```

Run focused mutations with repeated `--only` arguments. The runner copies the project to a temporary directory. A mutant counts as killed only when it compiles and a completed XCTest assertion fails. Compile errors, crashes, empty suites, and timeouts are failures of the campaign.

## Native checks

Build and sign before UI verification. Reuse the same signing identity to retain Screen Recording authorization. Verify through the actual app, not only screenshots or unit tests.

For visual changes, check Settings and About at clear, slight-fold, mid-fold, and near-stop angles. Confirm corner rounding, menu-bar coverage, reversible fade, and exact black at the stop. Confirm the miniature follows the same behavior.

For sensor changes, test a physical close and reopen without fully closing the MacBook. Read Debug timing separately from a diagnostic recording. Do not treat a short synthetic preview as evidence of physical motion-to-photon latency.

## Diagnostics and generated files

The Debug toggle writes low-frequency logs under the current user's temporary `foldelight-debug` directory. Logs contain no desktop pixels. The explicit 15-second diagnostic writes an MP4 there, includes the cursor, disables audio, and adds recording load.

`dist/`, `.build/`, mutation output, and local diagnostic output are generated. Do not commit them.

## Change discipline

- Inspect callers and tests before editing shared rendering or lifecycle code.
- Keep changes inside the requested scope.
- Preserve saved-settings compatibility. The UI name is Vignette, but its Codable field remains `shadow`.
- Preserve newest-value and generation checks across asynchronous boundaries.
- Treat shader constants as calibrated values. Record why a value changes and compare deterministic output.
- Run `git diff --check`, inspect the final diff, and keep the working tree reviewable.
- Commit completed and verified changes on a feature branch. Push only when a remote exists. Never invent a remote.
