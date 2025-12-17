#!/usr/bin/env python3
"""
xcodebuild-test-with-env.py — Run iOS simulator tests with injected env vars.

Why:
  `xcodebuild test` does NOT automatically forward host environment variables into
  the iOS simulator xctest process. For this repo we use env vars (e.g.
  LEXICAL_BENCH_BLOCKS, LEXICAL_FORCE_*) to parameterize perf runs, so we need to
  inject them into the generated `.xctestrun` file.

How it works:
  1) Runs the provided xcodebuild invocation as `build-for-testing`
  2) Finds the matching `.xctestrun` under `Playground/Build/Products`
  3) Copies + patches it to include selected env vars in each test target's
     EnvironmentVariables and TestingEnvironmentVariables
  4) Runs `xcodebuild -xctestrun <patched> test-without-building` with the
     original test selection flags (e.g. -only-testing)

Usage:
  LEXICAL_BENCH_BLOCKS=5000 LEXICAL_FORCE_DFS_ORDER_SORT=1 \
    python3 scripts/xcodebuild-test-with-env.py -- \
      xcodebuild -workspace Playground/LexicalPlayground.xcodeproj/project.xcworkspace \
        -scheme Lexical-Package \
        -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' \
        -parallel-testing-enabled NO \
        -maximum-concurrent-test-simulator-destinations 1 \
        -only-testing:LexicalTests/MixedDocumentLiveBenchmarkTests \
        test
"""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple


DEFAULT_PREFIXES = ("LEXICAL_BENCH_", "LEXICAL_FORCE_")


def utc_now_id() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(":", "").replace("+", "_")


def split_after_dashdash(argv: List[str]) -> List[str]:
    if "--" in argv:
        idx = argv.index("--")
        return argv[idx + 1 :]
    return argv


def require_arg_value(args: List[str], key: str) -> str:
    try:
        i = args.index(key)
    except ValueError:
        raise SystemExit(f"error: missing required {key} in xcodebuild invocation")
    if i + 1 >= len(args):
        raise SystemExit(f"error: missing value after {key}")
    return args[i + 1]


def strip_build_actions(args: List[str]) -> List[str]:
    actions = {
        "build",
        "test",
        "analyze",
        "archive",
        "build-for-testing",
        "test-without-building",
    }
    return [a for a in args if a not in actions]


def filter_for_build_for_testing(args: List[str]) -> List[str]:
    out: List[str] = []
    skip_next = False
    # Options only relevant when executing tests (not when building-for-testing).
    test_only_flags = {
        "-only-testing",
        "-skip-testing",
        "-only-test-configuration",
        "-skip-test-configuration",
        "-test-iterations",
        "-testPlan",
        "-test-repetition-relaunch-enabled",
        "-retry-tests-on-failure",
        "-run-tests-until-failure",
        "-enumerate-tests",
    }

    for i, a in enumerate(args):
        if skip_next:
            skip_next = False
            continue
        if a in test_only_flags:
            # Some flags take a value, some don't. Treat as taking a value if the next
            # token doesn't look like another flag.
            if i + 1 < len(args) and not args[i + 1].startswith("-"):
                skip_next = True
            continue
        if any(a.startswith(prefix) for prefix in ("-only-testing:", "-skip-testing:")):
            continue
        out.append(a)
    return out


def filter_for_test_without_building(args: List[str]) -> List[str]:
    out: List[str] = []
    skip_next = False
    skip_flags_with_value = {"-workspace", "-project", "-scheme"}

    for i, a in enumerate(args):
        if skip_next:
            skip_next = False
            continue
        if a in skip_flags_with_value:
            skip_next = True
            continue
        out.append(a)
    return out


def collect_env(prefixes: Tuple[str, ...]) -> Dict[str, str]:
    env: Dict[str, str] = {}
    for k, v in os.environ.items():
        if any(k.startswith(p) for p in prefixes):
            env[k] = v
    return env


def find_xctestrun(scheme: str) -> Path:
    products_dir = Path("Playground/Build/Products")
    pattern = f"{scheme}_{scheme}_*.xctestrun"
    matches = list(products_dir.glob(pattern))
    if not matches:
        raise SystemExit(f"error: no .xctestrun found matching {products_dir}/{pattern} (did build-for-testing run?)")
    matches.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return matches[0]


def patch_xctestrun(in_path: Path, out_path: Path, env: Dict[str, str]) -> None:
    with in_path.open("rb") as f:
        data = plistlib.load(f)

    configs = data.get("TestConfigurations") or []
    for cfg in configs:
        targets = cfg.get("TestTargets") or []
        for t in targets:
            for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
                d = t.get(key)
                if not isinstance(d, dict):
                    d = {}
                    t[key] = d
                for ek, ev in env.items():
                    d[ek] = str(ev)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_XML, sort_keys=False)


def run(cmd: List[str]) -> int:
    proc = subprocess.run(cmd)
    return proc.returncode


def main() -> int:
    cmd = split_after_dashdash(sys.argv[1:])
    if not cmd:
        print("Usage: xcodebuild-test-with-env.py -- <xcodebuild ... test>", file=sys.stderr)
        return 2
    if cmd[0] != "xcodebuild":
        print("error: command after -- must start with `xcodebuild`", file=sys.stderr)
        return 2

    scheme = require_arg_value(cmd, "-scheme")
    env = collect_env(DEFAULT_PREFIXES)

    # 1) build-for-testing
    build_args = filter_for_build_for_testing(strip_build_actions(cmd[1:]))
    build_cmd = ["xcodebuild", *build_args, "build-for-testing"]
    rc = run(build_cmd)
    if rc != 0:
        return rc

    # 2) locate and patch xctestrun
    xctestrun_path = find_xctestrun(scheme)
    # Keep the patched xctestrun in the same directory as the original so __TESTROOT__
    # continues to resolve to the built test products under Playground/Build/Products.
    patched = xctestrun_path.parent / f"{scheme}-{utc_now_id()}.patched.xctestrun"
    patch_xctestrun(xctestrun_path, patched, env)

    # 3) test-without-building
    test_args = filter_for_test_without_building(strip_build_actions(cmd[1:]))
    test_cmd = ["xcodebuild", "-xctestrun", str(patched), *test_args, "test-without-building"]
    return run(test_cmd)


if __name__ == "__main__":
    raise SystemExit(main())
