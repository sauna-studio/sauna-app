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


def main():
    runtimes = json.loads(run('xcrun', 'simctl', 'list', 'runtimes', '--json', capture=True))['runtimes']
    runtime = next((r['identifier'] for r in runtimes if r.get('isAvailable')
                    and r.get('version') == '27.2' and '.iOS-' in r['identifier']), None)
    if runtime is None:
        raise SystemExit('An available iOS 27.2 Simulator runtime is required; no test was skipped.')
    device = run('xcrun', 'simctl', 'create', 'Sauna-Session-Tests-' + str(uuid.uuid4()),
                 'com.apple.CoreSimulator.SimDeviceType.iPhone-17', runtime, capture=True).strip()
    try:
        run('xcrun', 'simctl', 'boot', device)
        run('xcrun', 'simctl', 'bootstatus', device, '-b')
        run('xcodebuild', '-project', 'Tests/SessionSimulatorHarness/SessionSimulatorHarness.xcodeproj',
            '-scheme', 'SessionSimulatorHarness', '-configuration', 'Debug',
            '-destination', 'platform=iOS Simulator,id=' + device,
            '-derivedDataPath', '.build/SimulatorDerivedData',
            'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM=', 'test')
    finally:
        # Shared devices belong to the developer; only this invocation's device may be removed.
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], cwd=ROOT, check=False)
        run('xcrun', 'simctl', 'delete', device)


if __name__ == '__main__':
    main()
