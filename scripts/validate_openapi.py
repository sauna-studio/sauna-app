#!/usr/bin/env python3
"""Verify the pinned API snapshot; optionally compare the immutable upstream file."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--verify-upstream', action='store_true')
    args = parser.parse_args()
    source = json.loads((ROOT / 'docs/openapi-source.json').read_text())
    snapshot = (ROOT / 'Sources/SaunaAppleSession/openapi.yaml').read_bytes()
    if hashlib.sha256(snapshot).hexdigest() != source['sha256']:
        raise SystemExit('OpenAPI snapshot hash differs from its pinned source record.')
    if args.verify_upstream:
        url = 'https://raw.githubusercontent.com/{repository}/{commit}/{path}'.format(**source)
        with urllib.request.urlopen(url, timeout=30) as response:
            upstream = response.read(1_048_577)
        if upstream != snapshot:
            raise SystemExit('OpenAPI snapshot differs from the immutable upstream file.')
    root_pins = json.loads((ROOT / 'Package.resolved').read_text())['pins']
    xcode_pins = json.loads((ROOT / 'Tests/SessionSimulatorHarness/SessionSimulatorHarness.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
    runtime_dependencies = {'swift-collections', 'swift-http-types', 'swift-openapi-runtime', 'swift-openapi-urlsession'}
    root_by_id = {pin['identity']: pin for pin in root_pins}
    xcode_by_id = {pin['identity']: pin for pin in xcode_pins}
    if set(xcode_by_id) != runtime_dependencies or any(root_by_id.get(name) != pin for name, pin in xcode_by_id.items()):
        raise SystemExit('SwiftPM and Xcode runtime dependency pins differ.')
    print('Pinned OpenAPI hash and SwiftPM/Xcode dependency pins match.')


if __name__ == '__main__':
    main()
