# d_rocket 2.0.0 — Benchmark suite

Standalone benchmark scripts for the d_rocket ecosystem.
Not part of the test suite (the CI does not run these by
default — they take 30+ seconds and produce output that
isn't a pass/fail).

## `linq_bench.dart` — LINQ vs raw SQL (SQLite engine)

Compares d_rocket LINQ translation + execution overhead
against the same operations written as raw SQL.

```bash
# Default: 100 iterations, 100 small / 1k medium rows
dart run bench/linq_bench.dart

# More iterations + larger datasets
dart run bench/linq_bench.dart \
  --iterations 200 \
  --small 1000 \
  --medium 10000

# Save results to CSV (for plotting or comparing over time)
dart run bench/linq_bench.dart \
  --iterations 200 \
  --output bench/results.csv
```

Output is a markdown table on stdout (and CSV to the
optional `--output` path):

```
| Operation | Variant | Records | Median | p95 |
| --- | --- | ---: | ---: | ---: |
| SELECT (small)            | raw SQL      |   100 | 0.22 ms | 0.35 ms |
| SELECT (small)            | d_rocket LINQ|   100 | 0.19 ms | 0.37 ms |
| WHERE + ORDER BY (medium) | raw SQL      |  1000 | 0.11 ms | 0.24 ms |
| WHERE + ORDER BY (medium) | d_rocket LINQ|  1000 | 0.18 ms | 0.33 ms |
| GROUP BY status, COUNT    | raw SQL      |  1000 | 0.12 ms | 0.17 ms |
| INSERT 100 rows           | d_rocket ORM |   100 | 0.73 ms | 1.30 ms |
```

## What we measure

1. **Translation overhead** — d_rocket LINQ vs hand-written SQL
   for SELECT, WHERE+ORDER BY, and GROUP BY.
2. **ORM overhead** — `db.set<T>().add(...)` + `saveChanges()` vs
   raw `INSERT` per row (within a single transaction).
3. **Engine overhead** (planned) — SQLite in-memory vs file-based.

## What's NOT in 2.0.0 (planned for 2.1.0)

* **Cross-engine comparison** — SQLite vs Postgres vs libsql_wasm.
  This requires running the bench in three different
  processes; we'll use a small `compare_engines.dart`
  script that runs all three and diffs the output.
* **Realtime / WebSocket roundtrip.**
* **Sync / REST throughput.**

## Methodology

* **5 warmup iterations** (discarded) before sampling to
  prime the JIT and the SQLite page cache.
* **N timed iterations** (default 100), reported as
  median (50th percentile) and p95 (95th percentile).
* **One fresh DB per benchmark** (the previous benchmark's
  data could pollute the next one).
* **Single-threaded** — the bench doesn't exercise
  concurrency. The Postgres engine has a connection
  pool; cross-engine benchmarks should test with
  `minConnections: 1, maxConnections: 32` to model
  production.

## Adding a new benchmark

1. Pick an operation. **What do you want to compare?**
   (raw SQL vs LINQ, this engine vs that engine, sync
   vs async, etc.)
2. Add a `results.add(await bench(...))` block in
   `linq_bench.dart::runAll`.
3. Use a fresh `_Ctx` (with the right row count) so
   benchmarks don't share data.
4. Add a comment explaining what the benchmark is
   measuring and why.
5. Run the bench and check the output. If the
   raw-SQL / LINQ ratio looks surprising (>5x or <0.2x),
   investigate before publishing.

## CI

The CI does NOT run the bench by default. To run it
in CI, add a `--run-bench` flag to the workflow.
The output goes to the workflow logs (or to a CSV
artifact if `--output` is set).
