#!/usr/bin/env python3
"""Inventory-only regression tests. No Simulator or Keychain operation is executed."""
import json
import subprocess
import unittest
from unittest.mock import patch
import test_simulator
from test_simulator import choose_pair

IPHONE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
DUO = 'com.apple.CoreSimulator.SimDeviceType.iPhone-Duo'
IPAD = 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-27-2'


def device(identifier, family='iPhone'):
    return {'identifier': identifier, 'productFamily': family}


def runtime(identifier=RUNTIME, devices=None, version='27.2', available=True, platform='iOS'):
    return {'identifier': identifier, 'version': version, 'platform': platform, 'isAvailable': available,
            'supportedDeviceTypes': devices if devices is not None else [device(IPHONE)]}


class CompatiblePairTests(unittest.TestCase):
    def test_specific_runtime_uses_its_advertised_device(self):
        specific = RUNTIME + '-iPhone19-4'
        self.assertEqual(choose_pair([runtime(specific, [device(DUO)])], [device(IPHONE), device(DUO)]), (specific, DUO))

    def test_all_runtimes_are_considered_before_selecting_preferred_device(self):
        values = [runtime(RUNTIME + '-iPhone19-4', [device(DUO)]), runtime()]
        self.assertEqual(choose_pair(values, [device(DUO), device(IPHONE)]), (RUNTIME, IPHONE))
        self.assertEqual(choose_pair(list(reversed(values)), [device(IPHONE), device(DUO)]), (RUNTIME, IPHONE))

    def test_unavailable_other_os_and_other_version_are_rejected(self):
        values = [runtime(available=False), runtime(version='27.1'), runtime(platform='tvOS'), runtime(identifier='com.apple.CoreSimulator.SimRuntime.tvOS-27-2')]
        with self.assertRaises(SystemExit):
            choose_pair(values, [device(IPHONE)])

    def test_missing_platform_or_non_boolean_availability_fail_closed(self):
        missing_platform = runtime()
        del missing_platform['platform']
        for value in [runtime(available='false'), runtime(available='true'), missing_platform]:
            with self.assertRaises(SystemExit):
                choose_pair([value], [device(IPHONE)])

    def test_canonical_uppercase_uuid_is_used_for_all_owned_device_operations(self):
        created = '4130116c-e074-4a80-9403-def2e5e2b45e'
        expected = created.upper()
        inventory = [json.dumps({'runtimes': [runtime()]}),
                     json.dumps({'devicetypes': [device(IPHONE)]}), created, None, None, None, None]
        with patch.object(test_simulator, 'run', side_effect=inventory) as command:
            with patch.object(test_simulator.subprocess, 'run') as shutdown:
                test_simulator.main()
                calls = [call.args for call in command.call_args_list]
                self.assertEqual(calls[3], ('xcrun', 'simctl', 'boot', expected))
                self.assertEqual(calls[4], ('xcrun', 'simctl', 'bootstatus', expected, '-b'))
                self.assertIn('platform=iOS Simulator,id=' + expected, calls[5])
                self.assertEqual(calls[6], ('xcrun', 'simctl', 'delete', expected))
                self.assertEqual(shutdown.call_args.args[0], ['xcrun', 'simctl', 'shutdown', expected])

    def test_invalid_created_uuid_cannot_reach_boot_or_cleanup(self):
        inventory = [json.dumps({'runtimes': [runtime()]}),
                     json.dumps({'devicetypes': [device(IPHONE)]}), 'all']
        with patch.object(test_simulator, 'run', side_effect=inventory) as command:
            with patch.object(test_simulator.subprocess, 'run') as subprocess_run:
                with self.assertRaises(ValueError):
                    test_simulator.main()
                self.assertEqual(command.call_count, 3)
                subprocess_run.assert_not_called()

    def test_missing_support_and_not_installed_device_fail_closed(self):
        for values in [[runtime(devices=[])], [runtime(devices=[device(DUO)])]]:
            with self.assertRaises(SystemExit):
                choose_pair(values, [device(IPHONE)])

    def test_available_advertised_ipad_can_be_used(self):
        self.assertEqual(choose_pair([runtime(devices=[device(IPAD, 'iPad')])], [device(IPAD)]), (RUNTIME, IPAD))

    def test_other_product_families_are_not_selected(self):
        with self.assertRaises(SystemExit):
            choose_pair([runtime(devices=[device('watch', 'Apple Watch')])], [device('watch')])


class RuntimeProvisioningTests(unittest.TestCase):
    download = ('xcodebuild', '-downloadPlatform', 'iOS', '-buildVersion', '27.2', '-architectureVariant', 'arm64')

    def existing(self):
        return [json.dumps({'runtimes': [runtime()]}), json.dumps({'devicetypes': [device(IPHONE)]})]

    def missing(self):
        return [json.dumps({'runtimes': []}), json.dumps({'devicetypes': [device(IPHONE)]})]

    def test_ensure_cli_does_not_download_create_or_boot_when_pair_exists(self):
        with patch.object(test_simulator, 'run', side_effect=self.existing()) as command:
            test_simulator.cli(['--ensure-runtime'])
        self.assertEqual([call.args for call in command.call_args_list], [
            ('xcrun', 'simctl', 'list', 'runtimes', '--json'),
            ('xcrun', 'simctl', 'list', 'devicetypes', '--json')])

    def test_missing_pair_downloads_once_and_rechecks_both_inventories(self):
        with patch.object(test_simulator, 'run', side_effect=self.missing() + [None] + self.existing()) as command:
            self.assertEqual(test_simulator.ensure_runtime(), (RUNTIME, IPHONE))
        self.assertEqual([call.args for call in command.call_args_list], [
            ('xcrun', 'simctl', 'list', 'runtimes', '--json'),
            ('xcrun', 'simctl', 'list', 'devicetypes', '--json'), self.download,
            ('xcrun', 'simctl', 'list', 'runtimes', '--json'),
            ('xcrun', 'simctl', 'list', 'devicetypes', '--json')])

    def test_download_failure_is_not_ignored_or_rechecked_as_success(self):
        failure = subprocess.CalledProcessError(70, self.download)
        with patch.object(test_simulator, 'run', side_effect=self.missing() + [failure]) as command:
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                test_simulator.ensure_runtime()
        self.assertIs(raised.exception, failure)
        self.assertEqual(command.call_count, 3)

    def test_download_success_without_a_compatible_pair_still_fails(self):
        with patch.object(test_simulator, 'run', side_effect=self.missing() + [None] + self.missing()) as command:
            with self.assertRaises(test_simulator.MissingCompatiblePair):
                test_simulator.ensure_runtime()
        self.assertEqual(command.call_count, 5)

    def test_invalid_json_is_not_treated_as_a_missing_runtime(self):
        with patch.object(test_simulator, 'run', return_value='{invalid') as command:
            with self.assertRaises(json.JSONDecodeError):
                test_simulator.ensure_runtime()
        self.assertEqual(command.call_count, 1)

    def test_invalid_inventory_structure_is_not_treated_as_a_missing_runtime(self):
        for value in [[], {}, {'runtimes': 'invalid'}, {'runtimes': [None]}]:
            with self.subTest(value=value), patch.object(test_simulator, 'run', return_value=json.dumps(value)) as command:
                with self.assertRaises(ValueError):
                    test_simulator.ensure_runtime()
                self.assertEqual(command.call_count, 1)

    def test_inventory_command_failure_cannot_trigger_download(self):
        failure = subprocess.CalledProcessError(1, ['xcrun', 'simctl', 'list'])
        for results in [[failure], [self.existing()[0], failure]]:
            with self.subTest(results=results), patch.object(test_simulator, 'run', side_effect=results) as command:
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    test_simulator.ensure_runtime()
                self.assertIs(raised.exception, failure)
                self.assertNotIn(self.download, [call.args for call in command.call_args_list])


if __name__ == '__main__':
    unittest.main()
