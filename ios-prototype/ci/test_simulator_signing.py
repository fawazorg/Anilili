import unittest
from verify_simulator_signing import verify


class SimulatorSigningTests(unittest.TestCase):
    def test_accepts_matching_simulator_host_without_apple_signing_credentials(self):
        verify({'application-identifier': 'org.anilili.playbackpoc', 'get-task-allow': True}, 'org.anilili.playbackpoc')

    def test_rejects_absent_mismatched_or_nondebug_test_identity(self):
        for values in [{}, {'application-identifier': 'different.app', 'get-task-allow': True},
                       {'application-identifier': 'org.anilili.playbackpoc', 'get-task-allow': False}]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                verify(values, 'org.anilili.playbackpoc')


class MachOSimulatorIdentityTests(unittest.TestCase):
    def binary(self, name=b'__entitlements'):
        import plistlib
        import struct
        claims = plistlib.dumps({'application-identifier': 'org.anilili.playbackpoc', 'get-task-allow': True}) + b'\0'
        commands_size = 72 + 80
        offset = 32 + commands_size
        header = struct.pack('<IiiIIIII', 0xfeedfacf, 0x01000007, 3, 2, 1, commands_size, 0, 0)
        segment = struct.pack('<II16sQQQQiiII', 0x19, commands_size, b'__TEXT', 0, offset + len(claims),
            0, offset + len(claims), 7, 5, 1, 0)
        section = struct.pack('<16s16sQQIIIIIIII', name, b'__TEXT', 0, len(claims), offset, 0, 0, 0, 0, 0, 0, 0)
        return header + segment + section + claims

    def test_extracts_and_validates_actual_simulator_section_format(self):
        from verify_simulator_signing import macho_entitlements
        verify(macho_entitlements(self.binary()), 'org.anilili.playbackpoc')

    def test_rejects_absent_truncated_or_out_of_bounds_sections(self):
        import struct
        from verify_simulator_signing import macho_entitlements
        bad_offset = bytearray(self.binary())
        struct.pack_into('<I', bad_offset, 32 + 72 + 48, len(bad_offset) + 1)
        for binary in [b'', self.binary()[:40], self.binary(name=b'__other'), bytes(bad_offset)]:
            with self.subTest(size=len(binary)), self.assertRaises(ValueError):
                macho_entitlements(binary)

    def test_extracted_identity_still_rejects_wrong_application(self):
        from verify_simulator_signing import macho_entitlements
        with self.assertRaises(ValueError):
            verify(macho_entitlements(self.binary()), 'another.application')
