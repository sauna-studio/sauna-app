#!/usr/bin/env python3
"""Inventory-only regression tests. No Simulator or Keychain operation is executed."""
import json
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


if __name__ == '__main__':
    unittest.main()
