# Testing foldelight

Run all commands from the repository root.

## Standard suite

Run the release suite before each publication commit:

```sh
swift test -c release
```

The suite covers effect mapping, settings, HID decoding, motion reconstruction,
capture filtering, frame pacing, GPU output, rounded boundaries, blackout, and
the interactive preview. Hardware-dependent tests skip when their explicit
environment flag is absent.

## Mutation tests

Validate the mutation runner and its source anchors:

```sh
python3 -m unittest discover -s Tools -p 'test_mutation_runner.py'
python3 Tools/mutation-test.py --validate-anchors
```

Run the complete mutation campaign:

```sh
python3 Tools/mutation-test.py
```

Use repeated `--only` arguments to select named mutations during development.
The runner copies the project to a temporary directory. A mutation passes the
campaign only when it compiles and a completed XCTest assertion detects it.

## Performance tests

Performance checks are opt-in because results depend on the machine and current
display workload:

```sh
FOLDELIGHT_CPU_BENCHMARK=1 swift test -c release --filter HotPathPerformanceTests
FOLDELIGHT_CPU_BENCHMARK=1 swift test -c release --filter SparseMotionPerformanceTests
FOLDELIGHT_GPU_BENCHMARK=1 swift test -c release --filter RenderPerformanceTests
FOLDELIGHT_GPU_BENCHMARK=1 swift test -c release --filter GPUTracePerformanceTests
FOLDELIGHT_GPU_BENCHMARK=1 swift test -c release --filter BlackoutRenderTests
FOLDELIGHT_LIVE_BENCHMARK=1 swift test -c release --filter LivePresentationTests
FOLDELIGHT_NATIVE_CAPTURE_TEST=1 swift test -c release --filter DesktopCaptureFilterTests
```

CPU checks consume their outputs through checksums. GPU checks submit real Metal
commands. Offscreen tests do not measure WindowServer presentation latency.

## Native verification

Build the signed app before testing permissions or physical lid motion:

```sh
bash Tools/build-app.sh
codesign --verify --deep --strict dist/foldelight.app
dist/foldelight.app/Contents/MacOS/foldelight --diagnose
```

Use the same signing identity between builds. A changed ad-hoc signature can
invalidate the existing Screen Recording permission.

Check these behaviors on a compatible MacBook:

- The overlay covers the complete built-in display, including the menu bar.
- Rounded corners remain visible from the first fold through the final frame.
- Closing fades continuously to black, and opening reverses the same curve.
- Physical movement remains smooth through stops and reversals.
- The Settings and About previews close to 0 degrees and open to 132 degrees.
- Pausing stops screen capture and removes the overlay.
