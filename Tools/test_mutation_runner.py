#!/usr/bin/env python3
# Copyright (C) 2026 Dario Farzati
# SPDX-License-Identifier: AGPL-3.0-only
"""CPU-only runner classification tests. No Swift or GPU subprocesses execute."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch, Mock

spec = importlib.util.spec_from_file_location('mutation_runner', Path(__file__).with_name('mutation-test.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

PASSED = "Build complete!\nTest Suite 'All tests' passed\nExecuted 85 tests, with 0 failures\n"
FAILED = "Build complete!\nTest Case '-[Tests testBehavior]' failed (0.001 seconds).\nTest Suite 'All tests' failed\nExecuted 85 tests, with 1 failure\n"


class MutationClassificationTests(unittest.TestCase):
    def test_clean_baseline_and_assertion_failure(self):
        self.assertEqual(runner.classify_test_result(0, PASSED), 'passed')
        self.assertEqual(runner.classify_test_result(1, FAILED), 'test-failure')

    def test_selected_suites_require_completed_tests_too(self):
        self.assertEqual(runner.classify_test_result(0, PASSED.replace('All tests', 'Selected tests')), 'passed')
        self.assertEqual(runner.classify_test_result(1, FAILED.replace('All tests', 'Selected tests')), 'test-failure')
        self.assertEqual(runner.classify_test_result(0, PASSED.replace('All tests', 'Selected tests').replace('85 tests', '0 tests')), 'error')

    def test_every_current_mutation_has_covering_tests_and_unknown_source_falls_back(self):
        for name, source, *_ in runner.MUTATIONS:
            self.assertTrue(runner.covering_tests(name, source), name)
        self.assertIsNone(runner.covering_tests('future-behavior', 'Future.swift'))

    def test_covering_filter_reaches_swift_without_enabling_benchmarks(self):
        def launch(command, **kwargs):
            self.assertEqual(command[-2:], ['--filter', 'PerformanceMetricsTests'])
            kwargs['stdout'].write(PASSED.replace('All tests', 'Selected tests'))
            return Mock(wait=Mock(return_value=0))
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(runner, 'preflight_metal', return_value='passed'):
                with patch.object(runner.subprocess, 'Popen', side_effect=launch):
                    outcome, _ = runner.run_tests(Path(temp), Path(temp) / 'test.log', 5, 'PerformanceMetricsTests')
            self.assertEqual(outcome, 'passed')

    def test_runtime_metal_compilation_failure_never_counts_as_kill(self):
        for message in ['program_source:72:9: error: expected expression',
                        'Error Domain=MTLLibraryErrorDomain Code=3', 'Metal compiler failed']:
            self.assertEqual(runner.classify_test_result(1, FAILED + message), 'metal-compile-error')

    def test_swift_build_failure_crash_and_empty_suite_are_errors(self):
        self.assertEqual(runner.classify_test_result(1, 'error: Swift compilation failed'), 'error')
        self.assertEqual(runner.classify_test_result(-9, FAILED), 'error')
        self.assertEqual(runner.classify_test_result(0, PASSED.replace('85 tests', '0 tests')), 'error')
        self.assertEqual(runner.classify_test_result(1, FAILED.replace("Test Case '-[Tests testBehavior]' failed (0.001 seconds).", '')), 'error')

    def test_preflight_failure_prevents_xctest_execution(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(runner, 'preflight_metal', return_value='metal-compile-error'):
                with patch.object(runner.subprocess, 'Popen') as launch:
                    outcome, _ = runner.run_tests(Path(temp), Path(temp) / 'test.log', 5)
            self.assertEqual(outcome, 'metal-compile-error')
            launch.assert_not_called()

    def test_offline_preflight_classifies_compiler_exit_and_timeout(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            for code, expected in [(0, 'passed'), (1, 'metal-compile-error')]:
                with patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], code)) as run:
                    self.assertEqual(runner.preflight_metal(folder, folder / 'metal.log', 5), expected)
                    self.assertIn('metal', run.call_args.args[0])
            with patch.object(runner.subprocess, 'run', side_effect=subprocess.TimeoutExpired('metal', 5)):
                self.assertEqual(runner.preflight_metal(folder, folder / 'metal.log', 5), 'metal-compile-timeout')

    def test_runtime_metal_failure_after_successful_preflight_still_is_not_kill(self):
        def launch(*args, **kwargs):
            kwargs['stdout'].write(FAILED + 'Error Domain=MTLLibraryErrorDomain Code=3')
            return Mock(wait=Mock(return_value=1))
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(runner, 'preflight_metal', return_value='passed'):
                with patch.object(runner.subprocess, 'Popen', side_effect=launch):
                    outcome, _ = runner.run_tests(Path(temp), Path(temp) / 'runtime.log', 5)
            self.assertEqual(outcome, 'metal-compile-error')

    def test_preflight_and_xctest_share_one_timeout_budget(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(runner, 'preflight_metal', return_value='passed'):
                with patch.object(runner.time, 'monotonic', side_effect=[0, 3]):
                    with patch.object(runner.subprocess, 'Popen') as launch:
                        outcome, elapsed = runner.run_tests(Path(temp), Path(temp) / 'test.log', 2)
            self.assertEqual((outcome, elapsed), ('timeout', 3))
            launch.assert_not_called()

    def test_campaign_disables_only_opt_in_benchmarks_exports_and_native_capture(self):
        values = {'FOLDELIGHT_GPU_BENCHMARK': '1', 'FOLDELIGHT_LIVE_BENCHMARK': '1',
                  'FOLDELIGHT_CPU_BENCHMARK': '1', 'FOLDELIGHT_EXPORT_GLASS': '1',
                  'FOLDELIGHT_NATIVE_CAPTURE_TEST': '1', 'FOLDELIGHT_LIVE_ROUNDS': '2', 'PATH': '/safe/bin'}
        with patch.dict(runner.os.environ, values, clear=True):
            environment = runner.mutation_environment()
        disabled = {'FOLDELIGHT_GPU_BENCHMARK', 'FOLDELIGHT_LIVE_BENCHMARK',
                    'FOLDELIGHT_CPU_BENCHMARK', 'FOLDELIGHT_EXPORT_GLASS', 'FOLDELIGHT_NATIVE_CAPTURE_TEST'}
        for key in values:
            self.assertEqual(environment[key], '0' if key in disabled else values[key])

    def test_copy_keeps_immutable_shader_and_timing_fixtures(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'source'
            fixtures = root / 'Tests/foldelightTests/Fixtures'
            fixtures.mkdir(parents=True)
            expected = {'Bend52bf1ef.metal': b'baseline shader', 'GPUTrace20260910.txt': b'baseline timing'}
            for name, contents in expected.items():
                (fixtures / name).write_bytes(contents)
            (root / '.build').mkdir()
            (root / '.build/cache').write_text('ignored')
            copy = Path(temp) / 'work'
            runner.copy_workspace(root, copy)
            self.assertFalse((copy / '.build').exists())
            for name, contents in expected.items():
                self.assertEqual((copy / 'Tests/foldelightTests/Fixtures' / name).read_bytes(), contents)
                self.assertEqual((fixtures / name).read_bytes(), contents)


if __name__ == '__main__':
    unittest.main()
