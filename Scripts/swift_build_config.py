# SPDX-License-Identifier: AGPL-3.0-or-later
"""Compiler options shared by the unit gate and its build-cache identity."""

# UI scheduling changes must not invalidate compiler work. Actual unit compiler
# flag changes do, alongside Package.swift, dependency pins and the toolchain.
SWIFT_TEST_FLAGS = ('--enable-code-coverage', '-Xswiftc', '-warnings-as-errors')
