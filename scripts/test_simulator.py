#!/usr/bin/env python3
"""Run session tests on an owned, temporary iOS 27.2 Simulator."""
import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parent.parent


def run(*args, capture=False):
    return subprocess.run(args, cwd=ROOT, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def choose_pair(runtimes, device_types):
    installed = {item['identifier'] for item in device_types}
    pairs = []
    for runtime in runtimes:
        identifier = runtime.get('identifier', '')
        if not (runtime.get('isAvailable') is True and runtime.get('version') == '27.2' and runtime.get('platform') == 'iOS' and '.iOS-' in identifier):
            continue
        for device in runtime.get('supportedDeviceTypes', []):
            device_id = device.get('identifier')
            if device_id in installed and device.get('productFamily') in ('iPhone', 'iPad'):
                pairs.append((identifier, device_id))
    if not pairs:
        raise SystemExit('An available iOS 27.2 runtime and an installed compatible device type are required; no test was skipped.')
    return min(pairs, key=lambda pair: (pair[1] != 'com.apple.CoreSimulator.SimDeviceType.iPhone-17', pair))


def main():
    runtimes = json.loads(run('xcrun', 'simctl', 'list', 'runtimes', '--json', capture=True))['runtimes']
    device_types = json.loads(run('xcrun', 'simctl', 'list', 'devicetypes', '--json', capture=True))['devicetypes']
    runtime, device_type = choose_pair(runtimes, device_types)
    print('Testing compatible Simulator pair:', runtime, device_type, flush=True)
    device = str(uuid.UUID(run('xcrun', 'simctl', 'create', 'Sauna-Session-Tests-' + str(uuid.uuid4()),
                               device_type, runtime, capture=True).strip()))
    try:
        run('xcrun', 'simctl', 'boot', device)
        run('xcrun', 'simctl', 'bootstatus', device, '-b')
        run('xcodebuild', '-project', 'Tests/SessionSimulatorHarness/SessionSimulatorHarness.xcodeproj',
            '-scheme', 'SessionSimulatorHarness', '-configuration', 'Debug',
            '-onlyUsePackageVersionsFromResolvedFile',
            '-destination', 'platform=iOS Simulator,id=' + device,
            '-derivedDataPath', '.build/SimulatorDerivedData',
            'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM=', 'test')
    finally:
        # Shared devices belong to the developer; only this invocation's device may be removed.
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], cwd=ROOT, check=False)
        run('xcrun', 'simctl', 'delete', device)
        print('Deleted owned Simulator:', device, flush=True)


if __name__ == '__main__':
    main()
