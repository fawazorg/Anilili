"""Require a simulator test host identity before exercising background URLSession."""
import plistlib
from pathlib import Path
import sys


def verify(entitlements, bundle_identifier):
    if entitlements.get('application-identifier') != bundle_identifier:
        raise ValueError('Simulator test host application identity is missing or mismatched')
    if entitlements.get('get-task-allow') is not True:
        raise ValueError('Simulator test host must allow test/debug attachment')


if __name__ == '__main__':
    verify(plistlib.loads(Path(sys.argv[1]).read_bytes()), sys.argv[2])
    print('Verified simulator-only ad-hoc test host identity')
