#!/bin/sh
# Re-extracts concept D from the board and rebuilds every output in ../
# Usage: ./run.sh "/path/to/Tokenly 글래스 아이콘 콘셉트 보드.png"   (MD5 22ee342dcf9bcda39b582b5e410a0a3e)
set -e
cd "$(dirname "$0")"
for t in extract resample verify recomp colorcheck sheetx; do ./build.sh $t.swift; done
./extract "$1" ..                                     # original-crop-343.png, native-396.png
./verify "$1" ../original-crop-343.png ../native-396.png
./recomp "$1" ../native-396.png "${TMPDIR:-/tmp}/recomp-diff.png"
./resample ../native-396.png ..                       # icon-*.png + resampling-comparison/
./colorcheck ../native-396.png ../icon-1024.png ../icon-512.png ../icon-256.png ../icon-128.png ../icon-64.png
./sheetx .. ../../D-final-candidate                   # comparison-sheet.png, dock-preview.png
