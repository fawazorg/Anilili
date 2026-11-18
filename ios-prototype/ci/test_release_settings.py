import unittest
from verify_release_settings import verify


class ReleaseSettingsTests(unittest.TestCase):
    def settings(self, sdk):
        target, arch = ('iosArm64', 'arm64') if sdk == 'iphoneos' else ('iosX64', 'x86_64')
        return [dict(target='PlaybackPOC', buildSettings=dict(
            CONFIGURATION='Release', PLATFORM_NAME=sdk, ARCHS=arch,
            KOTLIN_FRAMEWORK_TARGET=target, KOTLIN_FRAMEWORK_CONFIGURATION='releaseFramework',
            FRAMEWORK_SEARCH_PATHS=f'/project/shared-core/build/bin/{target}/releaseFramework',
            PRODUCT_BUNDLE_IDENTIFIER='org.anilili.playbackpoc'))]

    def test_accepts_matching_release_device_and_simulator_frameworks(self):
        for sdk in ['iphoneos', 'iphonesimulator']:
            verify(self.settings(sdk), sdk)

    def test_rejects_debug_framework_and_wrong_device_architecture(self):
        for field, value in [('CONFIGURATION', 'Debug'), ('ARCHS', 'x86_64'),
                             ('KOTLIN_FRAMEWORK_TARGET', 'iosX64'),
                             ('KOTLIN_FRAMEWORK_CONFIGURATION', 'debugFramework'),
                             ('FRAMEWORK_SEARCH_PATHS', '/iosArm64/debugFramework')]:
            with self.subTest(field=field):
                settings = self.settings('iphoneos')
                settings[0]['buildSettings'][field] = value
                with self.assertRaises(ValueError):
                    verify(settings, 'iphoneos')

    def test_rejects_absent_app_settings(self):
        with self.assertRaises(ValueError):
            verify([], 'iphoneos')
