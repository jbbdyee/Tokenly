#!/bin/sh
# build.sh tool.swift : compiles raw.swift + tool (as main.swift) into ./<tool>
cd "$(dirname "$0")"
n=$(basename "$1" .swift); mkdir -p "b/$n"; cp raw.swift "b/$n/raw.swift"; cp "$1" "b/$n/main.swift"
swiftc -O "b/$n/raw.swift" "b/$n/main.swift" -o "$n" 2>&1 | grep error
exit 0
