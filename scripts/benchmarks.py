#!/usr/bin/env python3
"""
benchmarks.py — record and report Lexical iOS perf benchmarks.

This script is host-side: it runs xcodebuild, scrapes `🔥 PERF_JSON {...}` lines
from the test output, and appends them to a JSONL file with run metadata.

Typical usage:
  python3 scripts/benchmarks.py record --issue lexical-ios-u7r.8 -- \\
    xcodebuild -workspace Playground/LexicalPlayground.xcodeproj/project.xcworkspace \\
      -scheme Lexical-Package \\
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' \\
      -parallel-testing-enabled NO \\
      -maximum-concurrent-test-simulator-destinations 1 \\
      -only-testing:LexicalTests/MixedDocumentBenchmarkTests test

  python3 scripts/benchmarks.py report --issue lexical-ios-u7r.8
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Iterable, List, Optional, Tuple


PERF_JSON_RE = re.compile(r"🔥 PERF_JSON (\{.*\})\s*$")


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def ensure_parent_dir(path: str) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.exists(parent):
        os.makedirs(parent, exist_ok=True)


def run_cmd_capture_perf_json(cmd: List[str]) -> Tuple[int, List[Dict[str, Any]]]:
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    records: List[Dict[str, Any]] = []
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        m = PERF_JSON_RE.search(line)
        if m:
            try:
                records.append(json.loads(m.group(1)))
            except json.JSONDecodeError:
                # Keep going; output already contains the bad line.
                pass
    return proc.wait(), records


def get_git_head() -> Optional[str]:
    try:
        out = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        return out or None
    except Exception:
        return None


def get_git_branch() -> Optional[str]:
    try:
        out = subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"], text=True).strip()
        return out or None
    except Exception:
        return None


def get_git_is_dirty() -> Optional[bool]:
    try:
        out = subprocess.check_output(["git", "status", "--porcelain"], text=True)
        return bool(out.strip())
    except Exception:
        return None


def append_jsonl(path: str, rows: Iterable[Dict[str, Any]]) -> None:
    ensure_parent_dir(path)
    with open(path, "a", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, sort_keys=True))
            f.write("\n")


def cmd_record(args: argparse.Namespace) -> int:
    if not args.cmd:
        print("error: missing command after --", file=sys.stderr)
        return 2

    out_path: str = args.out
    run_id: str = args.run_id or utc_now_iso().replace(":", "").replace("+", "_")
    issue: Optional[str] = args.issue
    tag: Optional[str] = args.tag
    git_head = args.git_head or get_git_head()
    git_branch = get_git_branch()
    git_dirty = get_git_is_dirty()

    started_at = utc_now_iso()
    rc, perf_records = run_cmd_capture_perf_json(args.cmd)
    ended_at = utc_now_iso()

    rows: List[Dict[str, Any]] = []
    for rec in perf_records:
        rows.append(
            {
                "run": {
                    "id": run_id,
                    "issue": issue,
                    "tag": tag,
                    "git_head": git_head,
                    "git_branch": git_branch,
                    "git_dirty": git_dirty,
                    "started_at": started_at,
                    "ended_at": ended_at,
                    "cmd": " ".join(args.cmd),
                },
                "bench": rec,
            }
        )

    append_jsonl(out_path, rows)

    print(f"\nRecorded {len(rows)} benchmark records -> {out_path}")
    if rc != 0:
        print(f"warning: command exited non-zero rc={rc}", file=sys.stderr)
    return rc


@dataclass(frozen=True)
class AggKey:
    run_id: str
    issue: str
    scenario: str


@dataclass
class Agg:
    started_at: str
    tag: str
    git_head: str
    git_dirty: Optional[bool]
    count: int = 0
    opt_sum: float = 0.0
    leg_sum: float = 0.0

    def add(self, opt: float, leg: float) -> None:
        self.count += 1
        self.opt_sum += opt
        self.leg_sum += leg

    @property
    def opt_avg(self) -> float:
        return self.opt_sum / self.count if self.count else 0.0

    @property
    def leg_avg(self) -> float:
        return self.leg_sum / self.count if self.count else 0.0

    @property
    def opt_over_leg(self) -> float:
        return self.opt_avg / self.leg_avg if self.leg_avg else 0.0


def cmd_report(args: argparse.Namespace) -> int:
    in_path: str = args.input
    if not os.path.exists(in_path):
        print(f"error: no such file: {in_path}", file=sys.stderr)
        return 2

    issue_filter: Optional[str] = args.issue
    scenario_filter: Optional[str] = args.scenario

    aggs: Dict[AggKey, Agg] = {}

    with open(in_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue

            run = row.get("run") or {}
            bench = row.get("bench") or {}

            issue = run.get("issue") or ""
            if issue_filter and issue != issue_filter:
                continue

            run_id = run.get("id") or ""
            started_at = run.get("started_at") or ""
            scenario = bench.get("scenario") or ""
            if scenario_filter and scenario != scenario_filter:
                continue

            opt = ((bench.get("optimized") or {}).get("wallTimeSeconds")) or 0.0
            leg = ((bench.get("legacy") or {}).get("wallTimeSeconds")) or 0.0

            key = AggKey(run_id=run_id, issue=issue, scenario=scenario)
            agg = aggs.get(key)
            if not agg:
                agg = Agg(
                    started_at=started_at,
                    tag=run.get("tag") or "",
                    git_head=run.get("git_head") or "",
                    git_dirty=run.get("git_dirty"),
                )
                aggs[key] = agg
            agg.add(float(opt), float(leg))

    rows = [
        (k, v)
        for (k, v) in aggs.items()
        if k.run_id and k.scenario
    ]
    rows.sort(key=lambda kv: kv[1].started_at)

    # Keep the last N run_ids if requested
    if args.last:
        keep_ids = set([k.run_id for (k, _) in rows][-args.last :])
        rows = [(k, v) for (k, v) in rows if k.run_id in keep_ids]

    if not rows:
        print("No benchmark records matched.")
        return 0

    print("run_id\tissue\ttag\tgit\tdirty\tscenario\tcount\topt_avg_s\tleg_avg_s\topt/leg")
    for (k, agg) in rows:
        git_short = (agg.git_head or "")[:8]
        dirty = ""
        if agg.git_dirty is True:
            dirty = "dirty"
        elif agg.git_dirty is False:
            dirty = "clean"
        print(
            f"{k.run_id}\t{k.issue}\t{agg.tag}\t{git_short}\t{dirty}\t{k.scenario}\t{agg.count}\t{agg.opt_avg:.4f}\t{agg.leg_avg:.4f}\t{agg.opt_over_leg:.2f}"
        )
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    sub = ap.add_subparsers(dest="cmd")

    rec = sub.add_parser("record", help="Run a command and append PERF_JSON records to a JSONL file")
    rec.add_argument("--out", default=".benchmarks/results.jsonl", help="Output JSONL path")
    rec.add_argument("--issue", default=None, help="bd issue id to associate with the run")
    rec.add_argument("--tag", default=None, help="Optional tag for the run (e.g. 'baseline', 'wip')")
    rec.add_argument("--run-id", default=None, help="Optional run id (defaults to UTC timestamp)")
    rec.add_argument("--git-head", default=None, help="Optional git sha (defaults to `git rev-parse HEAD`)")
    rec.add_argument("--", dest="dashdash", nargs=argparse.REMAINDER)

    rep = sub.add_parser("report", help="Summarize recorded benchmark JSONL")
    rep.add_argument("--in", dest="input", default=".benchmarks/results.jsonl", help="Input JSONL path")
    rep.add_argument("--issue", default=None, help="Filter by bd issue id")
    rep.add_argument("--scenario", default=None, help="Filter by scenario id")
    rep.add_argument("--last", type=int, default=10, help="Only show the last N run_ids (default 10)")

    args, unknown = ap.parse_known_args()
    if args.cmd == "record":
        cmd = None
        if args.dashdash:
            dd = args.dashdash
            if dd and dd[0] == "--":
                dd = dd[1:]
            cmd = dd
        if not cmd and "--" in sys.argv:
            idx = sys.argv.index("--")
            cmd = sys.argv[idx + 1 :]
        args.cmd = cmd
        return cmd_record(args)
    if args.cmd == "report":
        return cmd_report(args)

    ap.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
