#!/bin/sh
# Re-renders the D final candidate and its comparison sheet.
# Usage: ./render.sh "/path/to/Tokenly 글래스 아이콘 콘셉트 보드.png"
set -e
cd "$(dirname "$0")"
BUILD="${TMPDIR:-/tmp}/tokenly-d-final"; mkdir -p "$BUILD"
swiftc -Ounchecked FinalOrb.swift -o "$BUILD/finalorb"
swiftc -O Finalize.swift -o "$BUILD/finalize"
swiftc -O SheetF.swift -o "$BUILD/sheetf"
"$BUILD/finalorb" DF "$BUILD/DF-2048.png" 2048
"$BUILD/finalize" "$BUILD/DF-2048.png" ..
[ -n "$1" ] && "$BUILD/sheetf" "$1" ../.. ../D-final-comparison.png
