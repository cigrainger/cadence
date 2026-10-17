# SPDX-FileCopyrightText: 2026 Cadence contributors
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Encode diagnostic options without leaving macOS positional open requests."""

VALUE_OPTIONS = frozenset({
    '--snapshot', '--selfcheck', '--screen', '--width', '--height',
    '--vision-fixture', '--pdf-draft', '--pdf-source', '--interval', '--exercise',
})


def native_arguments(options):
    """Give presence flags explicit values; preserve each real option value.

    NSApplication also reads launch arguments. A bare flag before another
    option can consume that option's name, leaving its path as an open request
    and suppressing SwiftUI's initial window. Cadence still tests flag presence.
    """
    result = []
    index = 0
    while index < len(options):
        option = str(options[index])
        if not option.startswith('--') or option == '--':
            raise ValueError('Unexpected positional native argument: ' + option)
        result.append(option)
        if option in VALUE_OPTIONS:
            if index + 1 >= len(options) or str(options[index + 1]).startswith('--'):
                raise ValueError('Missing native option value: ' + option)
            result.append(str(options[index + 1]))
            index += 2
        else:
            result.append('YES')
            index += 1
    return result
