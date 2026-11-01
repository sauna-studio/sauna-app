#!/usr/bin/env python3
"""Validate the effective manifest policy and the user-requested dependency catalog."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parent.parent
FEATURES = {'ExistentialAny', 'InternalImportsByDefault', 'MemberImportVisibility',
            'InferIsolatedConformances', 'ImmutableWeakCaptures', 'NonisolatedNonsendingByDefault'}


def normalized_url(value):
    return value.rstrip('/').removesuffix('.git').lower()


def version(value):
    if not re.fullmatch(r'\d+\.\d+\.\d+', value):
        raise ValueError('Expected a stable semantic version in the dependency catalog.')
    return tuple(map(int, value.split('.')))


def validate(package, catalog, pins):
    if package.get('swiftLanguageVersions') != ['6']:
        raise ValueError('Our package must use Swift 6 language mode.')
    for target in package['targets']:
        settings = [item for item in target.get('settings', []) if item['tool'] == 'swift']
        if any('condition' in item for item in settings):
            raise ValueError('Our compiler policy must apply on every supported platform.')
        kinds = [item['kind'] for item in settings]
        features = {kind['enableUpcomingFeature']['_0'] for kind in kinds if 'enableUpcomingFeature' in kind}
        required = [{'defaultIsolation': {'_0': 'nonisolated'}}, {'strictMemorySafety': {}},
                    {'treatAllWarnings': {'_0': 'error'}}]
        if features != FEATURES or any(item not in kinds for item in required) or any('unsafeFlags' in kind for kind in kinds):
            raise ValueError('An owned target does not satisfy the compiler policy.')
    dependencies = [item['sourceControl'][0] for item in package['dependencies'] if 'sourceControl' in item]
    by_id = {pin['identity']: pin for pin in pins}
    if len(by_id) != len(pins) or any(not re.fullmatch(r'[0-9a-f]{40}', pin['state'].get('revision', '')) for pin in pins):
        raise ValueError('Every resolved dependency must have a unique immutable revision.')
    for entry in catalog['dependencies']:
        matches = [item for item in dependencies if item['identity'] == entry['identity']]
        if len(matches) != 1:
            raise ValueError('Each catalog repository must be declared exactly once.')
        dependency = matches[0]
        expected_url = normalized_url(entry['url'])
        actual_url = normalized_url(dependency['location']['remote'][0]['urlString'])
        pin = by_id.get(entry['identity'])
        if actual_url != expected_url or pin is None or normalized_url(pin['location']) != expected_url:
            raise ValueError('Catalog repository or resolved location does not match the approved source.')
        requirement = entry['requirement']
        if 'branch' in requirement:
            if dependency['requirement'] != {'branch': [requirement['branch']]} or pin['state'].get('branch') != requirement['branch'] or pin['state']['revision'] != catalog['proposalRevision']:
                raise ValueError('The proposal main branch must match its reviewed immutable revision.')
        elif 'exact' in requirement:
            if dependency['requirement'] != {'exact': [requirement['exact']]} or pin['state'].get('version') != requirement['exact']:
                raise ValueError('An existing exact dependency pin was changed.')
        else:
            floor = version(requirement['from'])
            upper = f'{floor[0] + 1}.0.0'
            if dependency['requirement'] != {'range': [{'lowerBound': requirement['from'], 'upperBound': upper}]} or not floor <= version(pin['state'].get('version', '')) < version(upper):
                raise ValueError('A catalog semantic-version requirement or resolved version is incorrect.')


def validate_xcode(project_path):
    project = ROOT / project_path
    if not (project / 'project.xcproj').is_file():
        raise ValueError('The owned Xcode harness must use the native JSON project format.')
    common = ['xcodebuild', '-project', str(project), '-onlyUsePackageVersionsFromResolvedFile']
    inventory = json.loads(subprocess.check_output(common + ['-list', '-json'], cwd=ROOT, text=True))['project']
    expected = {'SWIFT_VERSION': '6.0', 'SWIFT_DEFAULT_ACTOR_ISOLATION': 'nonisolated',
                'SWIFT_STRICT_MEMORY_SAFETY': 'YES', 'SWIFT_TREAT_WARNINGS_AS_ERRORS': 'YES'}
    keys = ['EXISTENTIAL_ANY', 'INTERNAL_IMPORTS_BY_DEFAULT', 'MEMBER_IMPORT_VISIBILITY',
            'INFER_ISOLATED_CONFORMANCES', 'NONISOLATED_NONSENDING_BY_DEFAULT']
    expected.update({'SWIFT_UPCOMING_FEATURE_' + key: 'YES' for key in keys})
    for target in inventory['targets']:
        for configuration in inventory['configurations']:
            result = json.loads(subprocess.check_output(common + ['-target', target, '-configuration', configuration,
                                '-sdk', 'iphonesimulator', '-showBuildSettings', '-json'], cwd=ROOT, text=True))
            settings = next(item['buildSettings'] for item in result if item['target'] == target)
            flags = shlex.split(settings.get('OTHER_SWIFT_FLAGS', ''))
            flag_pairs = set(zip(flags, flags[1:]))
            if any(settings.get(key) != value for key, value in expected.items()) or ('-enable-upcoming-feature', 'ImmutableWeakCaptures') not in flag_pairs:
                raise ValueError('An owned Xcode target/configuration does not satisfy the compiler policy.')
    print(f'Compiler policy verified for {len(inventory["targets"])} owned Xcode target(s) in every configuration.')


def main():
    if any(name in os.environ for name in ['SWIFT_SYNTAX_VERSION', 'HTTP_API_ENABLE_WASM']):
        raise SystemExit('Catalog validation requires the reviewed default manifest configuration; no environment override is allowed.')
    package = json.loads(subprocess.check_output(['swift', 'package', 'dump-package'], cwd=ROOT, text=True))
    catalog = json.loads((ROOT / 'docs/dependency-catalog.json').read_text())
    pins = json.loads((ROOT / 'Package.resolved').read_text())['pins']
    try:
        validate(package, catalog, pins)
        if catalog.get("xcodeProject"):
            validate_xcode(catalog["xcodeProject"])
    except (KeyError, TypeError, ValueError) as error:
        raise SystemExit(str(error)) from None
    print(f'Compiler policy verified for {len(package["targets"])} owned target(s); {len(catalog["dependencies"])} catalog repositories and {len(pins)} immutable pins verified.')


if __name__ == '__main__':
    main()
