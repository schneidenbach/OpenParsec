#!/bin/sh
# Runs the touch gesture classifier tests on macOS: no device or simulator needed.
set -e
cd "$(dirname "$0")/../.."
out="${TMPDIR:-/tmp}/openparsec-gesture-tests"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
	xcrun swiftc -O -o "$out" OpenParsec/TouchGestureClassifier.swift Tests/GestureClassifier/main.swift
"$out"
