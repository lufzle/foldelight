#!/usr/bin/env python3
# Copyright (C) 2026 Dario Farzati
# SPDX-License-Identifier: AGPL-3.0-only
"""Run real source mutations in an isolated copy. Never edit the working app.

A killed mutant must compile and fail XCTest. Build failures, timeouts, and
missing mutation anchors are errors, never counted as test successes.
"""
import argparse
import json
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
MUTATIONS = [
    ('progress-zero', 'Effect.swift', 'return linear * linear * (3 - 2 * linear)', 'return 0'),
    ('progress-reversed', 'Effect.swift', '1 - angle / clearAngle', 'angle / clearAngle'),
    ('progress-linear', 'Effect.swift', 'return linear * linear * (3 - 2 * linear)', 'return linear'),
    ('default-blur-reverted', 'Effect.swift', 'static let defaultBlur = 0.9', 'static let defaultBlur = 0.5'),
    ('default-vignette-reverted', 'Effect.swift', 'static let defaultVignette = 0.5', 'static let defaultVignette = 0.3'),
    ('sanitize-no-bounds', 'Effect.swift', 'min(range.upperBound, max(range.lowerBound, value))', 'value'),
    ('sanitize-wrong-fallback', 'Effect.swift', ': fallback', ': 0'),
    ('smoother-frozen', 'FrameClock.swift', 'value += (target - value)', 'value += 0 * (target - value)'),
    ('smoother-overshoot', 'FrameClock.swift', '1 - exp(-dt / Self.responseTime)', '1 + exp(-dt / Self.responseTime)'),
    ('smoother-slow-response', 'FrameClock.swift', 'static let responseTime = 0.008', 'static let responseTime = 0.025'),
    ('smoother-no-snap', 'FrameClock.swift', 'abs(target - value) < 0.01', 'abs(target - value) < 0'),
    ('vignette-disabled', 'Renderer.swift', 'self.vignetteAmount = 0.60', 'self.vignetteAmount = 0.0'),
    ('vignette-global', 'Resources/Bend.metal', '* lateral * (1.0 - .30', '* 1.0 * (1.0 - .30'),
    ('blur-disabled', 'Renderer.swift', 'self.blurAmount = sinTilt * blur', 'self.blurAmount = 0 * blur'),
    ('glass-heavy-fog', 'Resources/Bend.metal', 'float sigma = amount * 48.0 * depth * u.pixelScale;', 'float sigma = amount * 120.0 * depth * u.pixelScale;'),
    ('glass-pale-veil', 'Resources/Bend.metal', 'color *= half((1.0 - vignette) * (1.0 - edgeShade));', 'color = mix(color, half3(.92h, .94h, .965h), half(amount * depth * .035)); color *= half((1.0 - vignette) * (1.0 - edgeShade));'),
    ('glass-edge-shade-disabled', 'Renderer.swift', 'self.edgeShadeAmount = 0.95', 'self.edgeShadeAmount = 0.0'),
    ('cubic-reverted-to-linear', 'Resources/Bend.metal', 'float2 size = float2(tex.get_width(mip), tex.get_height(mip));', 'return tex.sample(s, uv, level(mip)).rgb; float2 size = float2(tex.get_width(mip), tex.get_height(mip));'),
    ('cubic-wrong-mip', 'Resources/Bend.metal', 'uint lower = uint(floor(bounded));', 'uint lower = 0;'),
    ('boundary-square-corners', 'Resources/Bend.metal', 'min(28.0 * u.pixelScale,', 'min(0.0 * u.pixelScale,'),
    ('boundary-delayed-rounding', 'Resources/Bend.metal', 'float cornerRadius = min(28.0 * u.pixelScale, min(imageSize.x, imageSize.y) * .12);', 'float cornerRadius = min(28.0 * u.pixelScale, min(imageSize.x, imageSize.y) * .12) * smoothstep(0.0, .012, p);'),
    ('boundary-hard-cutout', 'Resources/Bend.metal', 'float edgeSoftness = max(.5 * edgeAA, 2.0 * amount * u.pixelScale + 2.0 * sigma);', 'float edgeSoftness = .5 * edgeAA;'),
    ('boundary-no-local-diffusion', 'Resources/Bend.metal', 'sigma *= 1.0 + .85 * perimeter;', 'sigma *= 1.0;'),
    ('plane-tilt-disabled', 'Renderer.swift', 'self.sinTilt = sinTilt', 'self.sinTilt = 0'),
    ('plane-perspective-disabled', 'Resources/Bend.metal', 'float rayScale = 2.0 / (2.0 - separation);', 'float rayScale = 1.0;'),
    ('plane-vertical-attached', 'Resources/Bend.metal', 'float sourceY = 1.0 - (.7 + (height * u.cosTilt - .7) * rayScale);', 'float sourceY = y;'),
    ('menu-effect-bypassed', 'Resources/Bend.metal', 'if (p <= 0.0)', 'if (p <= 0.0 || in.uv.y < .05)'),
    ('angle-input-accepts-stale', 'LatestAngleInput.swift', 'sampledAt >= lastTimestamp', 'sampledAt <= lastTimestamp'),
    ('dirty-gate-always-draws', 'MetalFrameClock.swift', 'inputs != submitted', 'true'),
    ('pyramid-keeps-full-width', 'Renderer.swift', 'let pyramidWidth = max(1, source.width / 2)', 'let pyramidWidth = max(1, source.width)'),
    ('pyramid-always-builds-all-levels', 'Renderer.swift', 'return min(available, max(1, highestCompactLevel + 1))', 'return available'),
    ('metrics-stale-epoch', 'PerformanceMetrics.swift', 'guard enabled, token == epoch else { return }', 'guard enabled else { return }'),
    ('metrics-scheduled-as-arrival', 'PerformanceMetrics.swift', 'state.arrivals.add(arrival, capacity: capacity)', 'state.arrivals.add(expected, capacity: capacity)'),
    ('metrics-hidden-present-miss', 'PerformanceMetrics.swift', 'if time > deadline { increment(.presentRequestDeadlineMisses) }', 'if false { increment(.presentRequestDeadlineMisses) }'),
    ('metrics-unobserved-sensor', 'PerformanceMetrics.swift', 'increment(.sensorReads)', 'increment(.sensorReads, by: 0)'),
    ('metrics-premature-settling', 'PerformanceMetrics.swift', 'abs(rendered - sensor.target) <= 0.01', 'abs(rendered - sensor.target) <= 10'),
    ('lid-report-big-endian', 'LidSensor.swift', 'UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)', '(UInt16(bytes[1]) << 8) | UInt16(bytes[2])'),
    ('lid-report-rejects-360', 'LidSensor.swift', 'degrees <= 360', 'degrees < 360'),
    ('fine-report-wrong-scale', 'LidSensor.swift', 'Double(hundredths) / 100', 'Double(hundredths) / 10'),
    ('fine-report-wrong-id', 'LidSensor.swift', 'bytes[0] == 7', 'bytes[0] == 1'),
    ('fine-report-truncates-high-bits', 'LidSensor.swift', '| (UInt32(bytes[3]) << 16) | (UInt32(bytes[4]) << 24)', '| (UInt32(0) << 16) | (UInt32(0) << 24)'),
    ('fine-capability-ungated', 'LidReportSelection.swift', 'vendor == 0x05ac && product == 0x8104', 'true'),
    ('fine-agreement-bypassed', 'LidReportSelection.swift', 'fine >= min(before, after) - 0.51, fine <= max(before, after) + 0.51', 'true'),
    ('fine-fallback-lost', 'LidReportSelection.swift', 'return read(1)', 'return nil'),
    ('motion-no-prediction', 'LidMotionEstimator.swift', 'velocity * (age + lead)', '0 * (age + lead)'),
    ('motion-never-expires', 'LidMotionEstimator.swift', 'guard age <= horizon else { return measuredAngle }', 'guard true else { return measuredAngle }'),
    ('motion-accepts-stale', 'LidMotionEstimator.swift', 'sample.sampledAt > last.sampledAt', 'true'),
    ('motion-duplicates-refresh-age', 'LidMotionEstimator.swift', 'guard delta != 0 else { return }', 'guard delta != 0 else { self.last = sample; return }'),
    ('motion-noise-animates', 'LidMotionEstimator.swift', 'static let noiseFloor = 0.15', 'static let noiseFloor = 0.0'),
    ('motion-velocity-unbounded', 'LidMotionEstimator.swift', 'static let maximumVelocity = 180.0', 'static let maximumVelocity = 1800.0'),
    ('motion-offset-unbounded', 'LidMotionEstimator.swift', 'static let maximumOffset = 24.0', 'static let maximumOffset = 240.0'),
    ('motion-future-lead-unbounded', 'LidMotionEstimator.swift', 'static let maximumLead = 0.05', 'static let maximumLead = 0.5'),
    ('motion-deadband-hides-activation', 'LidMotionEstimator.swift', ' || crossedActivation', ''),
    ('worker-forecast-bypassed', 'LiveRenderWorker.swift', 'let forecast = configuration.followsSensor && predictsSensorMotion', 'let forecast = false'),
    ('mailbox-stale-stream', 'DesktopCapture.swift', 'guard active == ObjectIdentifier(stream) else { lock.unlock(); return false }', 'guard active != nil else { lock.unlock(); return false }'),
    ('mailbox-repeat-notify', 'DesktopCapture.swift', 'let notify = first; first = false', 'let notify = true; first = false'),
    ('mailbox-replay-frame', 'DesktopCapture.swift', 'let result = pending; pending = nil', 'let result = pending'),
    ('mailbox-restore-stale-generation', 'DesktopCapture.swift', 'guard active != nil, frame.generation == generation else { return }', 'guard active != nil else { return }'),
    ('damage-unknown-becomes-empty', 'CapturedFrame.swift', 'guard let previous, let incoming else { return nil }', 'guard let previous, let incoming else { return [] }'),
    ('damage-forgotten-after-sharp-draw', 'PyramidUpdateState.swift', 'guard usedPyramid else { return }', 'if false { return }'),
    ('damage-drops-coalesced-region', 'PyramidUpdateState.swift', 'needsRefresh ? FrameDamage.merging(damage, incoming) : incoming', 'incoming'),
    ('damage-retry-claims-empty', 'PyramidUpdateState.swift', '    mutating func invalidate() {\n        needsRefresh = true\n        damage = nil', '    mutating func invalidate() {\n        needsRefresh = true\n        damage = []'),
    ('completion-double-release', 'RenderCompletionDelivery.swift', 'self.action = nil', 'self.action = { action?() }'),
    ('completion-discard-loses-permit', 'RenderCompletionDelivery.swift', 'deinit { finish() }', 'deinit {}'),
    ('worker-source-wake-suppressed', 'LiveRenderWorker.swift', 'func sourceChanged() { wake.signal() }', 'func sourceChanged() {}'),
    ('worker-sensor-wake-suppressed', 'LiveRenderWorker.swift', '        wake.signal()\n    }\n\n    func stop()', '    }\n\n    func stop()'),
    ('logger-no-rotation', 'DebugLog.swift', 'if bytes + data.count > limit {', 'if false {'),
    ('preview-drag-reversed', 'PreviewLidDrag.swift', 'angle - delta *', 'angle + delta *'),
    ('preview-drag-replays-total-distance', 'PreviewLidDrag.swift', 'previousTranslation = translation', 'previousTranslation = 0'),
    ('preview-drag-sticks-at-limits', 'PreviewLidDrag.swift', 'previousTranslation = translation', 'if angle > 0 && angle < 132 { previousTranslation = translation }'),
    ('preview-drag-no-lower-limit', 'PreviewLidDrag.swift', 'max(angleRange.lowerBound, angle)', 'angle'),
    ('preview-drag-no-upper-limit', 'PreviewLidDrag.swift', 'min(angleRange.upperBound, max(angleRange.lowerBound, angle))', 'max(angleRange.lowerBound, angle)'),
    ('preview-drag-loses-starting-angle', 'PreviewLidDrag.swift', 'self.angle = Self.clamped(angle)', 'self.angle = 78'),
    ('preview-drag-keyboard-resets-pointer', 'PreviewLidDrag.swift', 'angle = Self.clamped(angle + degrees)', 'previousTranslation = 0\n        angle = Self.clamped(angle + degrees)'),
    ('preview-drag-hinge-reversed', 'PreviewLidDrag.swift', 'clamped(angle) - 90', '90 - clamped(angle)'),
    ('preview-drag-opens-past-132', 'PreviewLidDrag.swift', '0.0...132.0', '0.0...135.0'),
    ('preview-activation-before-90', 'Effect.swift', 'static let defaultClearAngle = 90.0', 'static let defaultClearAngle = 100.0'),
    ('slider-track-ignores-inset', 'LidAngleSlider.swift', 'width - 2 * Self.inset', 'width'),
    ('slider-drag-reversed', 'LidAngleSlider.swift', 'rawAngle + delta / track.travel', 'rawAngle - delta / track.travel'),
    ('slider-replays-total-distance', 'LidAngleSlider.swift', 'previousTranslation = translation', 'previousTranslation = 0'),
    ('slider-sticks-at-limits', 'LidAngleSlider.swift', 'previousTranslation = translation', 'if rawAngle > handle.range.lowerBound && rawAngle < handle.range.upperBound { previousTranslation = translation }'),
    ('slider-rounds-every-event', 'LidAngleSlider.swift', 'rawAngle = handle.bounded(candidate)', 'rawAngle = handle.bounded(candidate).rounded()'),
    ('slider-activation-stops-rounding', 'LidAngleSlider.swift', 'handle == .activation ? rawAngle.rounded() : rawAngle', 'rawAngle'),
    ('slider-activation-uses-own-scale', 'LidAngleSlider.swift', 'delta / track.travel * PreviewLidDrag.angleRange.upperBound', 'delta / track.travel * (handle.range.upperBound - handle.range.lowerBound)'),
    ('slider-keyboard-resets-pointer', 'LidAngleSlider.swift', 'mutating func setValue(_ angle: Double) { rawAngle = handle.bounded(angle) }', 'mutating func setValue(_ angle: Double) { previousTranslation = 0; rawAngle = handle.bounded(angle) }'),
    ('slider-loses-lower-limit', 'LidAngleSlider.swift', 'max(range.lowerBound, angle)', 'angle'),
    ('slider-activation-exceeds-track', 'Effect.swift', 'static let clearAngleRange = 45.0...132.0', 'static let clearAngleRange = 45.0...135.0'),
    ('blackout-disabled', 'FoldBlackout.swift', 'return phase * phase * (3 - 2 * phase)', 'return 0'),
    ('blackout-too-late', 'FoldBlackout.swift', 'static let fadeFraction = 0.20', 'static let fadeFraction = 0.05'),
    ('blackout-too-early', 'FoldBlackout.swift', 'static let fadeFraction = 0.20', 'static let fadeFraction = 0.90'),
    ('blackout-linear-fade', 'FoldBlackout.swift', 'return phase * phase * (3 - 2 * phase)', 'return phase'),
    ('blackout-wrong-activation', 'FoldBlackout.swift', 'max(0, clearAngle - travel)', '32.0'),
    ('blackout-low-activation-unreachable', 'FoldBlackout.swift', 'min(EffectSettings.maximumTiltDegrees, clearAngle)', 'EffectSettings.maximumTiltDegrees'),
    ('blackout-reversed', 'FoldBlackout.swift', '(stop + span - angle) / span', '(angle - stop) / span'),
    ('blackout-shader-fade-disabled', 'Resources/Bend.metal', 'half transmission = half(1.0 - u.blackout);', 'half transmission = 1.0h;'),
    ('blackout-surround-bypassed', 'Resources/Bend.metal', 'if (coverage <= 0) return half4(surround * transmission, 1.0h);', 'if (coverage <= 0) return half4(surround, 1.0h);'),
    ('blackout-neutral-bypassed', 'Resources/Bend.metal', 'desktop.sample(s, in.uv, level(0)).rgb * transmission', 'desktop.sample(s, in.uv, level(0)).rgb'),
    ('blackout-pyramid-work', 'Renderer.swift', ' && blackout < 1', ''),
    ('blackout-discards-damage', 'Renderer.swift', 'pyramidUpdate.didSubmit(usedPyramid: uniforms.needsDiffusion)', 'pyramidUpdate.didSubmit(usedPyramid: true)'),
    ('blackout-gate-ignores-fade', 'MetalFrameClock.swift', 'return inputs != submitted', 'return inputs.angle != submitted?.angle || inputs.settings != submitted?.settings || inputs.sourceRevision != submitted?.sourceRevision'),
    ('blackout-gate-keeps-drawing', 'MetalFrameClock.swift', 'if inputs.blackout == 1, submitted?.blackout == 1 { return false }', ''),
    ('blackout-worker-omits-fade', 'LiveRenderWorker.swift', 'LiveMotionFrame(angle: angle, blackout: opacity,', 'LiveMotionFrame(angle: angle, blackout: 0,'),
    ('blackout-deadband-hides-stop', 'LidMotionEstimator.swift', ' || crossedFoldStop', ''),
    ('blackout-exact-stop-excluded', 'LidMotionEstimator.swift', '($0 <= threshold) != (sample.angle <= threshold)', '($0 < threshold) != (sample.angle < threshold)'),
    ('blackout-setting-keeps-stale-angle', 'LiveRenderWorker.swift', 'if motionClearAngle != configuration.settings.clearAngle {', 'if false {'),
    ('blackout-uses-measured-angle', 'LiveRenderWorker.swift', 'FoldBlackout.opacity(angle: angle,', 'FoldBlackout.opacity(angle: target,'),
]

# The baseline runs every test. Each mutant runs the behavior suites that cover
# its source, avoiding repeated unrelated native-resolution GPU comparisons.
# An unknown source falls back to the complete suite.
SOURCE_TESTS = {
    'LidAngleSlider.swift': 'LidAngleSliderTests',
    'PreviewLidDrag.swift': 'PreviewLidDragTests',
    'Effect.swift': 'EffectTests|CorePropertyTests',
    'FrameClock.swift': 'FramePacingTests|LowLatencyPipelineTests|CorePropertyTests',
    'LatestAngleInput.swift': 'LatestAngleInputTests|LowLatencyPipelineTests',
    'MetalFrameClock.swift': 'LowLatencyPipelineTests',
    'PerformanceMetrics.swift': 'PerformanceMetricsTests',
    'LidSensor.swift': 'LidReportTests|PreciseLidReportTests',
    'LidReportSelection.swift': 'PreciseLidReportTests',
    'LidMotionEstimator.swift': 'LidMotionTests|SparseMotionPerformanceTests|LiveRenderWorkerTests',
    'DesktopCapture.swift': 'CaptureMailboxTests|CapturedFrameTests|CaptureCallbackTests',
    'CapturedFrame.swift': 'CapturedFrameTests',
    'PyramidUpdateState.swift': 'PyramidUpdateStateTests|RendererSubmissionTests',
    'RenderCompletionDelivery.swift': 'RenderCompletionDeliveryTests',
    'LiveRenderWorker.swift': 'LiveRenderWorkerTests',
    'DebugLog.swift': 'DebugLogTests',
}

def covering_tests(name, source):
    if name.startswith('blackout-'):
        return 'FoldBlackoutTests|BlackoutRenderTests|LiveRenderWorkerTests|RendererSubmissionTests|LidMotionTests'
    if name.startswith('boundary-'):
        return 'RoundedBoundaryTests'
    if name.startswith('cubic-'):
        return 'CubicReconstructionTests'
    if name.startswith('plane-'):
        return 'FixedPlaneTests'
    if name.startswith('pyramid-'):
        return 'PyramidPlanningTests|RenderPerformanceTests'
    if source in ('Renderer.swift', 'Resources/Bend.metal'):
        return 'GlassQualityTests|GPUPropertyTests|MetalTests'
    return SOURCE_TESTS.get(source)

def classify_test_result(code, text):
    """Only a completed XCTest assertion failure can kill a compiled mutant."""
    metal_error = re.search(r'program_source:\d+(?::\d+)?:\s*(?:fatal )?error:|MTLLibraryErrorDomain|Metal compiler failed', text)
    if metal_error:
        return 'metal-compile-error'
    if code < 0 or 'Build complete!' not in text:
        return 'error'
    counts = [int(value) for value in re.findall(r'Executed (\d+) tests?', text)]
    if not counts or max(counts) == 0:
        return 'error'
    if code == 0 and re.search(r"Test Suite '(?:All|Selected) tests' passed", text):
        return 'passed'
    if code != 0 and re.search(r"Test Suite '(?:All|Selected) tests' failed", text) and re.search(r'Test Case .+ failed', text):
        return 'test-failure'
    return 'error'


def preflight_metal(work, output, timeout):
    """Compile production Metal offline before XCTest can count an assertion kill."""
    source = work / 'Sources/foldelight/Resources/Bend.metal'
    with tempfile.TemporaryDirectory(prefix='foldelight-metal-preflight-') as temp:
        command = ['xcrun', '-sdk', 'macosx', 'metal', '-mmacosx-version-min=14.0',
                   '-c', str(source), '-o', str(Path(temp) / 'Bend.air')]
        with output.open('w') as log:
            try:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                        timeout=timeout, check=False)
            except subprocess.TimeoutExpired:
                return 'metal-compile-timeout'
            except OSError as error:
                log.write(str(error))
                return 'metal-compiler-unavailable'
    return 'passed' if result.returncode == 0 else 'metal-compile-error'


def mutation_environment():
    # A correctness campaign must not inherit a live/thermal benchmark or export.
    environment = dict(os.environ)
    for key in environment:
        if key.startswith('FOLDELIGHT_') and ('BENCHMARK' in key or 'EXPORT' in key or key == 'FOLDELIGHT_NATIVE_CAPTURE_TEST'):
            environment[key] = '0'
    return environment


def copy_workspace(source, destination):
    # Shader and recorded baseline fixtures deliberately remain in the copy.
    return shutil.copytree(source, destination,
                           ignore=shutil.ignore_patterns('.build', 'dist', '.git', '.mutation-results'))


def run_tests(work, output, timeout, test_filter=None):
    started = time.monotonic()
    preflight = preflight_metal(work, output.with_suffix('.metal.log'), timeout)
    if preflight != 'passed':
        return preflight, time.monotonic() - started
    elapsed = time.monotonic() - started
    if elapsed >= timeout:
        return 'timeout', elapsed
    with output.open('w') as log:
        command = ['swift', 'test', '--package-path', str(work)]
        if test_filter:
            command += ['--filter', test_filter]
        process = subprocess.Popen(command, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True, env=mutation_environment())
        try:
            code = process.wait(timeout=timeout - elapsed)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            return 'timeout', time.monotonic() - started
    return classify_test_result(code, output.read_text(errors='replace')), time.monotonic() - started


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / '.mutation-results')
    parser.add_argument('--timeout', type=int, default=180, help='Seconds per baseline/mutant, including Metal preflight')
    parser.add_argument('--only', action='append', help='Run a named mutation. Repeat to select several with one baseline.')
    parser.add_argument('--full-suite-per-mutant', action='store_true',
                        help='Run every test for every mutant instead of its covering behavior suites')
    parser.add_argument('--validate-anchors', action='store_true',
                        help='Check that every selected source anchor is unique without running tests')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    selected = [m for m in MUTATIONS if not args.only or m[0] in args.only]
    if args.only and set(args.only) - {m[0] for m in MUTATIONS}:
        parser.error('Unknown mutation')
    if not selected:
        parser.error('Unknown mutation')
    if args.validate_anchors:
        failures = 0
        for name, relative, before, _ in selected:
            count = (ROOT / 'Sources/foldelight' / relative).read_text().count(before)
            print(f'{name}: anchor-count={count}')
            failures += count != 1
        return 1 if failures else 0
    report = {'mutations': [], 'baseline': None}
    with tempfile.TemporaryDirectory(prefix='foldelight-mutations-') as temp:
        work = Path(temp) / 'foldelight'
        copy_workspace(ROOT, work)
        outcome, seconds = run_tests(work, args.output / 'baseline.log', args.timeout)
        report['baseline'] = {'outcome': outcome, 'seconds': seconds}
        if outcome == 'passed':
            for name, relative, before, after in selected:
                test_filter = None if args.full_suite_per_mutant else covering_tests(name, relative)
                file = work / 'Sources/foldelight' / relative
                original = file.read_text()
                if original.count(before) != 1:
                    outcome, seconds = 'anchor-error', 0
                else:
                    try:
                        file.write_text(original.replace(before, after, 1))
                        outcome, seconds = run_tests(work, args.output / (name + '.log'), args.timeout, test_filter)
                        outcome = {'passed': 'survived', 'test-failure': 'killed'}.get(outcome, outcome)
                    finally:
                        file.write_text(original)
                report['mutations'].append({'name': name, 'outcome': outcome, 'seconds': seconds,
                                            'tests': test_filter or 'all'})
                print(f'{name}: {outcome}', flush=True)
                (args.output / 'report.json').write_text(json.dumps(report, indent=2))
    (args.output / 'report.json').write_text(json.dumps(report, indent=2))
    return 0 if report['baseline']['outcome'] == 'passed' and all(m['outcome'] == 'killed' for m in report['mutations']) else 1

if __name__ == '__main__':
    raise SystemExit(main())
