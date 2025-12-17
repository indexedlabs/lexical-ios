# Performance Benchmarks (iOS Simulator)

This repo includes an XCTest-based perf harness plus host-side tooling to collect metrics into a local JSONL file.

## What’s measured

Benchmarks live in `LexicalTests/Tests/*BenchmarkTests.swift` and emit single-line JSON via:

- `LexicalTests/Support/PerformanceTestSupport.swift` (`🔥 PERF_JSON {...}`)

## Record a run (recommended)

Use `scripts/benchmarks.py record` to run `xcodebuild`, scrape `🔥 PERF_JSON`, and append records to `.benchmarks/results.jsonl` (gitignored):

```bash
python3 scripts/benchmarks.py record --issue lexical-ios-u7r.7 --tag baseline -- \
  xcodebuild -workspace Playground/LexicalPlayground.xcodeproj/project.xcworkspace \
    -scheme Lexical-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:LexicalTests/MixedDocumentLiveBenchmarkTests/testMixedDocumentLiveDeleteBlockBenchmarkTopMiddleEndQuick \
    test
```

Notes:
- Pass `--issue <bd-id>` so results can be correlated with the tracked work item.
- Use `--tag baseline|after|wip` to compare runs as you iterate.

## Report results

```bash
python3 scripts/benchmarks.py report --issue lexical-ios-u7r.7
python3 scripts/benchmarks.py report --scenario live-delete
```

## Debug hangs with timeouts

Wrap `xcodebuild` with `scripts/with-timeout.py` to kill the run if it stops producing output and capture a `sample`:

```bash
python3 scripts/with-timeout.py --idle 120 --hard 900 --sample -- \
  xcodebuild -workspace Playground/LexicalPlayground.xcodeproj/project.xcworkspace \
    -scheme Lexical-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' \
    test
```
