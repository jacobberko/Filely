#!/bin/bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="$project_root/.build-cache"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$cache_root/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/swift"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$cache_root/packages" "$cache_root/configuration" "$cache_root/security"
swift_options=(--build-system native --package-path "$project_root" --scratch-path "$project_root/.build" --cache-path "$cache_root/packages" --config-path "$cache_root/configuration" --security-path "$cache_root/security" --disable-sandbox)
xcrun swift build "${swift_options[@]}" --build-tests
binary_directory="$(xcrun swift build "${swift_options[@]}" --show-bin-path)"
# Invoke XCTest directly: SwiftPM's runner can stall on macOS service-backed tests.
xcrun xctest "$binary_directory/FilerPackageTests.xctest"
policy_module_cache="${TMPDIR:-/tmp}/filer-policy-module-cache"
mkdir -p "$policy_module_cache"
CLANG_MODULE_CACHE_PATH="$policy_module_cache" xcrun swiftc -module-cache-path "$policy_module_cache" "$project_root/Sources/Filer/Integration/PickerPolicy.swift" "$project_root/Tests/IntegrationPolicyTests/Runner.swift" -o "$project_root/.build/policy-tests"
"$project_root/.build/policy-tests"
