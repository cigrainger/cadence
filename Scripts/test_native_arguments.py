# SPDX-FileCopyrightText: 2026 Cadence contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

from pathlib import Path
import unittest

from native_arguments import native_arguments, VALUE_OPTIONS
from verify import native_scenarios


class NativeArgumentsTests(unittest.TestCase):
    def test_presence_flags_before_values_and_at_the_end_are_explicit(self):
        options = ['--song-preview', '--snapshot', Path('/tmp/a score.png'), '--width', '1350', '--coach-panel']
        self.assertEqual(native_arguments(options), [
            '--song-preview', 'YES', '--snapshot', '/tmp/a score.png',
            '--width', '1350', '--coach-panel', 'YES',
        ])
        self.assertEqual(options[0:2], ['--song-preview', '--snapshot'])

    def test_real_values_remain_literal_including_negative_numbers_and_spaces(self):
        self.assertEqual(native_arguments(['--interval', '-3', '--screen', 'a b', '--snapshot', '/tmp/$literal.png']),
                         ['--interval', '-3', '--screen', 'a b', '--snapshot', '/tmp/$literal.png'])

    def test_missing_values_and_unexpected_positional_arguments_fail(self):
        for option in VALUE_OPTIONS:
            for options in ([option], [option, '--song-preview']):
                with self.subTest(options=options), self.assertRaisesRegex(ValueError, 'Missing native option value'):
                    native_arguments(options)
        for options in (['score.pdf'], ['--song-preview', 'unexpected'], ['--']):
            with self.subTest(options=options), self.assertRaises(ValueError):
                native_arguments(options)

    def test_every_native_scenario_encodes_as_option_value_pairs(self):
        for name, flags, *_ in native_scenarios():
            with self.subTest(scenario=name):
                encoded = native_arguments(['--snapshot', '/tmp/' + name + '.png', *flags])
                self.assertEqual(len(encoded) % 2, 0)
                self.assertTrue(all(option.startswith('--') for option in encoded[::2]))
                self.assertTrue(all(not value.startswith('--') for value in encoded[1::2]))
