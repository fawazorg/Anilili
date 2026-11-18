"""Verify simulator identity in Xcode's Mach-O entitlement section, not host claims."""
import argparse
import plistlib
from pathlib import Path
import struct


def verify(entitlements, bundle_identifier):
    if entitlements.get('application-identifier') != bundle_identifier:
        raise ValueError('Simulator test host application identity is missing or mismatched')
    if entitlements.get('get-task-allow') is not True:
        raise ValueError('Simulator test host must allow test/debug attachment')


def macho_entitlements(data):
    # mach_header_64 / segment_command_64 / section_64, per Apple's mach-o/loader.h.
    # CI deliberately builds one Intel simulator slice. Unexpected formats fail closed.
    if len(data) < 32:
        raise ValueError('Truncated simulator executable')
    magic, cpu, _, filetype, commands, command_bytes, _, _ = struct.unpack_from('<IiiIIIII', data)
    if magic != 0xfeedfacf or cpu != 0x01000007 or filetype != 2:
        raise ValueError('Expected a thin Intel Mach-O executable')
    limit = 32 + command_bytes
    if limit > len(data) or commands > command_bytes // 8:
        raise ValueError('Invalid Mach-O load-command table')
    position = 32
    found = []
    for _ in range(commands):
        if position + 8 > limit:
            raise ValueError('Truncated Mach-O load command')
        kind, size = struct.unpack_from('<II', data, position)
        if size < 8 or size % 8 or position + size > limit:
            raise ValueError('Invalid Mach-O load-command bounds')
        if kind == 0x19:
            if size < 72:
                raise ValueError('Truncated Mach-O segment')
            sections = struct.unpack_from('<I', data, position + 64)[0]
            if 72 + sections * 80 > size:
                raise ValueError('Truncated Mach-O section table')
            for index in range(sections):
                section = position + 72 + index * 80
                name = data[section:section + 16].split(b'\0', 1)[0]
                segment = data[section + 16:section + 32].split(b'\0', 1)[0]
                if name == b'__entitlements' and segment == b'__TEXT':
                    length = struct.unpack_from('<Q', data, section + 40)[0]
                    offset = struct.unpack_from('<I', data, section + 48)[0]
                    if length == 0 or length > 1024 * 1024 or offset < limit or offset + length > len(data):
                        raise ValueError('Invalid simulator entitlement section bounds')
                    try:
                        found.append(plistlib.loads(data[offset:offset + length].rstrip(b'\0')))
                    except plistlib.InvalidFileException as error:
                        raise ValueError('Invalid simulator entitlement plist') from error
        position += size
    if position != limit or len(found) != 1 or not isinstance(found[0], dict):
        raise ValueError('Exactly one simulator entitlement section is required')
    return found[0]


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('input')
    parser.add_argument('bundle_identifier')
    parser.add_argument('--mach-o', action='store_true')
    parser.add_argument('--output')
    args = parser.parse_args()
    data = Path(args.input).read_bytes()
    entitlements = macho_entitlements(data) if args.mach_o else plistlib.loads(data)
    verify(entitlements, args.bundle_identifier)
    if args.output:
        Path(args.output).write_bytes(plistlib.dumps(entitlements))
    print('Verified simulator test host identity')
