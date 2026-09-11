# Performance notes

foldelight targets the built-in display refresh rate while keeping the newest
lid and capture samples ahead of older work. The renderer favors bounded latency
over queued throughput.

## Hot path

- `LidSensor` reads the HID device on a user-interactive serial queue.
- `LatestAngleInput` and `LatestSensorDelivery` retain only the newest sample.
- `LidMotionEstimator` reconstructs motion between sparse sensor changes and
  stops prediction after bounded age, velocity, lead, and offset limits.
- `DesktopCapture` retains the newest ScreenCaptureKit frame without copying its
  pixels to the CPU.
- `MetalFrameClock` supplies display deadlines.
- `LiveRenderWorker` coalesces wakes and avoids unchanged work.
- `RenderExecutor` limits GPU work without blocking the main thread.

## Renderer

The Metal renderer keeps one frame of drawable latency and one in-flight command.
It uses a three-drawable layer pool, native capture pixels, and a compact Gaussian
pyramid. Damage accumulates until a pyramid refresh succeeds. Small changed areas
update only the affected pyramid regions.

The shader reconstructs blur from adjacent mip levels with cubic filtering. Its
fixed desktop plane, rounded glass boundary, vignette, and angle-paced blackout
share one render pass. Exact open-state identity and exact final black remain
tested invariants.

## Measuring changes

Run the opt-in commands in [TESTING.md](TESTING.md). Compare the same build type,
display, resolution, power state, and foreground workload. Separate these values:

- Sensor change to submitted frame.
- Capture-frame age.
- CPU encoding time.
- GPU queue and execution time.
- Presentation callback time.
- Sustained frame rate and dropped presentation count.

Synthetic angles isolate the render pipeline. They do not prove physical lid
latency. Offscreen GPU submissions isolate Metal work. They do not prove
WindowServer presentation. Diagnostic recording adds capture and encoder load and
must not serve as a clean performance benchmark.

Metal System Trace and Time Profiler give the strongest evidence for a suspected
GPU or CPU bottleneck when they can acquire the required system trace.
