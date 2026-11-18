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
