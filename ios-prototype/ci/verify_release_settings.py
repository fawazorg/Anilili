"""Require Release to link the matching Native framework for its actual SDK."""
import json
from pathlib import Path
import sys


def verify(settings, sdk):
    apps = [item['buildSettings'] for item in settings if item.get('target') == 'PlaybackPOC']
    if len(apps) != 1:
        raise ValueError('Expected exactly one PlaybackPOC app build configuration')
    app = apps[0]
    target = {'iphoneos': 'iosArm64', 'iphonesimulator': 'iosX64'}[sdk]
    arch = 'arm64' if sdk == 'iphoneos' else 'x86_64'
    paths = app.get('FRAMEWORK_SEARCH_PATHS', '')
    if isinstance(paths, list):
        paths = ' '.join(paths)
    checks = {
        'Release configuration': app.get('CONFIGURATION') == 'Release',
        'matching platform': app.get('PLATFORM_NAME') == sdk,
        'matching architecture': arch in app.get('ARCHS', '').split(),
        'matching Kotlin target': app.get('KOTLIN_FRAMEWORK_TARGET') == target,
        'Release Kotlin framework': app.get('KOTLIN_FRAMEWORK_CONFIGURATION') == 'releaseFramework',
        'expanded Release framework search path': f'/{target}/releaseFramework' in paths and 'debugFramework' not in paths,
        'preserved bundle identity': app.get('PRODUCT_BUNDLE_IDENTIFIER') == 'org.anilili.playbackpoc',
    }
    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        raise ValueError('Invalid Release settings: ' + ', '.join(failed))


if __name__ == '__main__':
    verify(json.loads(Path(sys.argv[1]).read_text()), sys.argv[2])
    print(f'Validated unsigned Release configuration for {sys.argv[2]}')
