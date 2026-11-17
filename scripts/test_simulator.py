#!/usr/bin/env python3
"""Run session tests on an owned, temporary iOS 27.2 Simulator."""
import argparse
import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parent.parent


def run(*args, capture=False):
    return subprocess.run(args, cwd=ROOT, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


class MissingCompatiblePair(SystemExit):
    pass


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
        raise MissingCompatiblePair('An available iOS 27.2 runtime and an installed compatible device type are required; no test was skipped.')
    return min(pairs, key=lambda pair: (pair[1] != 'com.apple.CoreSimulator.SimDeviceType.iPhone-17', pair))


def inventory(kind):
    value = json.loads(run('xcrun', 'simctl', 'list', kind, '--json', capture=True))
    if not isinstance(value, dict) or not isinstance(value.get(kind), list) or any(not isinstance(item, dict) for item in value[kind]):
        raise ValueError('Simulator inventory must contain an object list for ' + kind)
    return value[kind]


def installed_pair():
    return choose_pair(inventory('runtimes'), inventory('devicetypes'))


def ensure_runtime():
    try:
        pair = installed_pair()
    except MissingCompatiblePair:
        run('xcodebuild', '-downloadPlatform', 'iOS', '-buildVersion', '27.2', '-architectureVariant', 'arm64')
        pair = installed_pair()
    print('Required Simulator pair is available:', *pair, flush=True)
    return pair


def main():
    runtime, device_type = installed_pair()
    print('Testing compatible Simulator pair:', runtime, device_type, flush=True)
    device = str(uuid.UUID(run('xcrun', 'simctl', 'create', 'Sauna-Session-Tests-' + str(uuid.uuid4()),
                               device_type, runtime, capture=True).strip())).upper()
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


def cli(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ensure-runtime', action='store_true', help='Install the required runtime only when no compatible pair is available')
    args = parser.parse_args(argv)
    if args.ensure_runtime:
        ensure_runtime()
    else:
        main()


if __name__ == '__main__':
    cli()
