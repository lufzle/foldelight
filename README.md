# foldelight

foldelight is a native macOS app that turns the MacBook lid into a physical control for a live desktop folding effect.

The visual idea is inspired by the folding-glass effect shown for iPhone Duo. The desktop stays fixed in its fully open position while a separate glass plane follows the lid. Closing the lid changes the view through that glass: the desktop gains perspective, its rounded boundary diffuses, its sides darken, and the image fades to black by the geometric fold limit. Opening the lid retraces the same motion.

This is an independent open-source interpretation. It does not reuse the reference implementation and is not affiliated with Apple.

## What it does

- Reads the built-in MacBook lid-angle sensor.
- Captures the complete built-in display, including the menu bar.
- Renders the fold at native Retina resolution with Metal.
- Keeps the desktop on a fixed plane while the virtual glass follows the lid.
- Preserves rounded corners from the first visible fold to the final frame.
- Adds depth-dependent blur and a side vignette without a pale color veil.
- Fades continuously to black during the final 20% of available fold travel.
- Uses the display refresh rate, up to 120 Hz on supported hardware.
- Includes a draggable miniature that previews the same shader without capture permission.

The default effect uses **90% Blur**, **50% Vignette**, and a **90° activation angle**. Existing saved settings remain unchanged after an update. Select **Reset effect** to apply the current defaults.

## Controls

The Settings screen contains a shared lid-angle track with two handles:

- The cyan circle changes the miniature between 0° and 132°.
- The gold diamond sets the activation angle between 45° and 132°.

Enable **Match lid angle** to mirror the physical lid in the miniature. Dragging the miniature returns it to manual control. Blur controls the diffusion strength. Vignette controls the neutral edge shading.

Select **Try on desktop** for a four-second effect preview. Press **Escape** while foldelight has keyboard focus to pause. You can also pause or enable the effect from the window or menu bar. Pausing stops the effect's capture. An active diagnostic recording continues until you stop it or its 15-second limit expires.

**Reconnect lid sensor** closes and reopens the hardware connection, validates the report format again, and restarts angle readings. Use it when sensor reads stop or fail.

## Run

Build the app, then open `dist/foldelight.app`. The app starts paused and opens Settings.

1. Select **Enable foldelight**.
2. Allow foldelight in **System Settings → Privacy & Security → Screen & System Audio Recording**.
3. Restart foldelight if macOS requests it.
4. Enable foldelight again.

Closing Settings keeps the menu-bar app running. Opening the window makes foldelight appear in the Dock and Command-Tab switcher.

## Build

The project requires macOS 14 or later, Swift 5.10 or later, Metal, ScreenCaptureKit, and a compatible MacBook lid sensor. It has no third-party package dependencies.

```sh
swift test -c release
bash Tools/build-app.sh
dist/foldelight.app/Contents/MacOS/foldelight --diagnose
```

The build script creates `dist/foldelight.app`, copies its resources and license, generates the icon, signs the bundle, and verifies the signature. Set `FOLDELIGHT_SIGNING_IDENTITY` to a certificate hash or identity name when you need stable Screen Recording authorization:

```sh
FOLDELIGHT_SIGNING_IDENTITY="CERTIFICATE_HASH" bash Tools/build-app.sh
```

Without an available certificate, the script uses an ad-hoc signature. A changed ad-hoc build can look enabled in System Settings while macOS rejects its permission identity. Reset only foldelight's decision with:

```sh
tccutil reset ScreenCapture com.lufzle.foldelight
```

Then launch the current bundle and grant access again. The app bundle identifier is `com.lufzle.foldelight`.

## How it works

`LidSensor` discovers the private HID device on usage page `0x20`, usage `0x8A`. It uses report 1 for whole-degree readings. On the verified Apple device, it uses report 7 for hundredth-degree readings only after an exact capability match and agreement with whole-degree readings. A failed fine read falls back in the same sampling call and disables the fine report for that connection.

`DesktopCapture` uses ScreenCaptureKit to capture the built-in display at native pixels. Its filter excludes only foldelight's overlay, which prevents recursive capture while retaining the menu bar, Settings, and other windows. Live effect frames stay in memory.

`LiveRenderWorker` runs outside the main thread. The newest sensor and capture samples wake it directly. A bounded motion estimator reconstructs movement between sparse sensor changes, while the display link supplies presentation deadlines. The renderer avoids work for unchanged frames, uses one-frame drawable latency, and builds only the required compact Gaussian-pyramid levels.

`Renderer.swift` and `Resources/Bend.metal` implement fixed-plane projection, cubic mip reconstruction, rounded boundary diffusion, vignette, and angle-paced blackout. The live overlay and miniature use the same shader.

## Diagnostics

Enable **Debug** from the folding menu-bar icon. Logs are written to the current user's temporary directory under `foldelight-debug`. They contain lifecycle events and aggregate timing, but no desktop images.

Select **Record 15-second diagnostic** to save a local video in that directory. This explicit recording captures the screen and cursor without audio. It adds capture and encoder load, so it is useful for visual diagnosis rather than clean performance measurement.

The repository also includes read-only probes:

```sh
swift Tools/lid-probe.swift
swift Tools/probe-lid-precision.swift
swift Tools/capture-probe.swift
```

## Tests and limits

The XCTest suite covers settings, HID decoding, motion reconstruction, concurrency, capture filtering, frame pacing, GPU output, rounded boundaries, blackout, and interactive controls. Optional environment flags enable native, GPU, and performance checks. The mutation runner edits an isolated temporary copy and requires every selected mutant to compile and fail through an XCTest assertion.

See [TESTING.md](TESTING.md) for commands and current evidence. See [PERFORMANCE.md](PERFORMANCE.md) for measurements and their limits.

Coding agents should start with [AGENTS.md](AGENTS.md). It maps the runtime, invariants, focused source files, and verification workflow.

The effect applies only to the built-in display. External displays remain unchanged. The overlay is visual and does not transform application hit targets. Pause before interacting with a heavily folded desktop. Actual presentation rate depends on the Mac, workload, and WindowServer. The private lid reports are undocumented by Apple and may differ on other hardware.

## License and credits

foldelight is licensed under the [GNU Affero General Public License version 3](LICENSE).

The bundled IBM Plex Sans fonts are licensed under the SIL Open Font License. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution and source information.
