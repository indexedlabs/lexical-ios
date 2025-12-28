#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/spm/build_ios_sim.sh [--arch arm64|x86_64] [-- <swift build args...>]

Builds this SwiftPM package for the iOS Simulator using a SwiftPM destination file.
This avoids the sysroot mismatch warnings that can happen when cross-compiling via
`-Xswiftc -target ...` (SwiftPM still plans a macOS build, then the linker sees an
iOS target).

With no additional `swift build` args, this script builds a set of library targets
(and skips demo executables) to keep the output warning-free.
EOF
}

arch=""
swift_build_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      arch="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      swift_build_args+=("$@")
      break
      ;;
    *)
      swift_build_args+=("$1")
      shift
      ;;
  esac
done

if [[ -z "$arch" ]]; then
  arch="$(uname -m)"
fi

case "$arch" in
  arm64|x86_64) ;;
  *)
    echo "Unsupported arch: $arch (expected arm64 or x86_64)" >&2
    exit 2
    ;;
esac

sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
swiftc_path="$(xcrun --find swiftc)"
toolchain_bin_dir="$(dirname "$swiftc_path")"
target_triple="${arch}-apple-ios16.0-simulator"

tmp_destination="${TMPDIR:-/tmp}/spm-destination-iphonesimulator-${arch}-$$.json"
cleanup() { rm -f "$tmp_destination"; }
trap cleanup EXIT

SDK_PATH="$sdk_path" TOOLCHAIN_BIN_DIR="$toolchain_bin_dir" TARGET_TRIPLE="$target_triple" \
  python3 - <<'PY' >"$tmp_destination"
import json
import os

print(
  json.dumps(
    {
      "version": 1,
      "sdk": os.environ["SDK_PATH"],
      "toolchain-bin-dir": os.environ["TOOLCHAIN_BIN_DIR"],
      "target": os.environ["TARGET_TRIPLE"],
      "extra-swiftc-flags": [],
      "extra-cc-flags": [],
      "extra-cpp-flags": [],
      "extra-linker-flags": [],
    },
    indent=2,
  )
)
PY

if [[ ${#swift_build_args[@]} -gt 0 ]]; then
  swift build --destination "$tmp_destination" "${swift_build_args[@]}"
  exit 0
fi

default_targets=(
  Lexical
  LexicalCore
  LexicalUIKit
  LexicalListPlugin
  LexicalListHTMLSupport
  LexicalHTML
  LexicalAutoLinkPlugin
  LexicalLinkPlugin
  LexicalLinkHTMLSupport
  LexicalInlineImagePlugin
  SelectableDecoratorNode
  EditorHistoryPlugin
  LexicalMarkdown
  LexicalSwiftUI
)

for target in "${default_targets[@]}"; do
  swift build --destination "$tmp_destination" --target "$target"
done
