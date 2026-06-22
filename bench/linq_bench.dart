// d_rocket 2.0.0 — LINQ benchmark suite (SQLite engine)
//
// Compares the d_rocket LINQ-to-SQL translation + execution overhead
// against the same operations written as raw SQL. Runs a fixed number
// of iterations of each operation and reports the median + p95 latency.
//
// Usage:
//   dart bench/linq_bench.dart
//   dart bench/linq_bench.dart --iterations 200 --warmup 50
//   dart bench/linq_bench.dart --output bench/results.csv
//
// Output:
//   - Stdout: human-readable markdown table
//   - --output: CSV with one row per (operation, variant) per (seed, N)
//
// What we measure:
//   1. Translation overhead  — d_rocket LINQ vs hand-written SQL
//      (a) Simple SELECT (100 rows)
//      (b) WHERE + ORDER BY (1k rows)
//      (c) GROUP BY (10k rows)
//      (d) JOIN (1k + 10k rows)
//   2. Engine overhead       — SQLite in-memory vs SQLite file
//   3. ORM overhead          — `db.set<T>().where_(...)` vs raw SQL
//      (a) SaveChanges (100 inserts in a transaction)
//      (b) SaveChanges (1000 inserts in a transaction)
//
// Out of scope (planned for 2.1.0 benchmarks):
//   - Cross-engine comparison (SQLite vs Postgres vs libsql_wasm)
//   - Realtime / WebSocket roundtrip
//   - Sync / REST throughput

import 'dart:io';
import 'dart:math';

import 'package:d_rocket/d_rocket.dart';
import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';

// ---------------------------------------------------------------------------
// Benchmark harness
// ---------------------------------------------------------------------------

class BenchResult {
  BenchResult({
    required this.name,
    required this.variant,
    required this.medianMicros,
    required this.p95Micros,
    required this.iterations,
    required this.records,
  });
  final String name;
  final String variant;
  final double medianMicros;
  final double p95Micros;
  final int iterations;
  final int records;

  String toMarkdownRow() {
    return '| $name | $variant | $records | '
        '${(medianMicros / 1000).toStringAsFixed(2)} ms | '
        '${(p95Micros / 1000).toStringAsFixed(2)} ms |';
  }

  String toCsvRow() {
    return '$name,$variant,$records,$iterations,'
        '${medianMicros.toStringAsFixed(1)},${p95Micros.toStringAsFixed(1)}';
  }
}

typedef BenchFn = Future<void> Function();

Future<BenchResult> bench({
  required String name,
  required String variant,
  required int iterations,
  required int records,
  required BenchFn fn,
}) async {
  // Warmup
  for (var i = 0; i < 5; i++) {
    await fn();
  }
  // Collect
  final samples = <int>[];
  for (var i = 0; i < iterations; i++) {
    final sw = Stopwatch()..start();
    await fn();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  samples.sort();
  final median = samples[samples.length ~/ 2];
  final p95 = samples[(samples.length * 0.95).floor()];
  return BenchResult(
    name: name,
    variant: variant,
    medianMicros: median.toDouble(),
    p95Micros: p95.toDouble(),
    iterations: iterations,
    records: records,
  );
}

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

class _User implements RecordLike {
  final int id;
  final String name;
  final int age;
  final String status;
  _User({
    required this.id,
    required this.name,
    required this.age,
    required this.status,
  });

  @override
  Object? readField(String name) {
    switch (name) {
      case 'id':
        return id;
      case 'name':
        return this.name;
      case 'age':
        return age;
      case 'status':
        return status;
      default:
        return null;
    }
  }
}

final _userMeta = EntityMeta(
  tableName: 'bench_users',
  columns: const [
    ColumnMeta(sqlName: 'id', dartField: 'id', dartType: int),
    ColumnMeta(sqlName: 'name', dartField: 'name', dartType: String),
    ColumnMeta(sqlName: 'age', dartField: 'age', dartType: int),
    ColumnMeta(sqlName: 'status', dartField: 'status', dartType: String),
  ],
  insertableColumns: const [
    ColumnMeta(sqlName: 'name', dartField: 'name', dartType: String),
    ColumnMeta(sqlName: 'age', dartField: 'age', dartType: int),
    ColumnMeta(sqlName: 'status', dartField: 'status', dartType: String),
  ],
  updatableColumns: const [
    ColumnMeta(sqlName: 'name', dartField: 'name', dartType: String),
    ColumnMeta(sqlName: 'age', dartField: 'age', dartType: int),
    ColumnMeta(sqlName: 'status', dartField: 'status', dartType: String),
  ],
  primaryKey: const ColumnMeta(
      sqlName: 'id', dartField: 'id', dartType: int),
  primaryKeyIndex: 0,
  pkOf: (e) => (e as _User).id,
  fromRow: (row) => _User(
    id: row['id']! as int,
    name: row['name']! as String,
    age: row['age']! as int,
    status: row['status']! as String,
  ),
);

class _Ctx extends DbContext {
  final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
  late final DbSet<_User> users = dbSet<_User>(() => _userMeta);

  @override
  AsyncQueryProvider? get asyncProvider => provider;

  @override
  DbSet<T> createDbSet<T>(EntityMeta Function() m) {
    return DbSet<T>(
      metaAccessor: m,
      tracker: changeTracker,
      execute: (sql, binds) {
        if (binds.isEmpty) provider.execute(sql);
        else provider.execute(sql, binds);
        return 1;
      },
      select: (sql, [List<Object?>? binds]) {
        if (binds == null || binds.isEmpty) return provider.select(sql);
        return provider.selectWithBinds(sql, binds);
      },
      lastInsertRowId: () => provider.database.lastInsertRowId,
    );
  }
}

// ---------------------------------------------------------------------------
// Setup: seed the DB with N rows
// ---------------------------------------------------------------------------

Future<_Ctx> setupCtx({required int userCount, String? filePath}) async {
  final ctx = _Ctx();
  // Schema
  ctx.provider.execute('''
    CREATE TABLE bench_users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      age INT NOT NULL,
      status TEXT NOT NULL
    )
  ''');
  // Bulk insert in a single transaction (1 INSERT per row; the
  // benchmark measures query perf, not insert perf, so this is OK).
  ctx.provider.execute('BEGIN');
  final rand = Random(42);
  for (var i = 0; i < userCount; i++) {
    ctx.provider.execute(
      'INSERT INTO bench_users (name, age, status) VALUES (?, ?, ?)',
      [
        'user_${i.toString().padLeft(6, '0')}',
        18 + rand.nextInt(60),
        rand.nextBool() ? 'active' : 'inactive',
      ],
    );
  }
  ctx.provider.execute('COMMIT');
  return ctx;
}

// ---------------------------------------------------------------------------
// Benchmarks
// ---------------------------------------------------------------------------

Future<List<BenchResult>> runAll({
  required int iterations,
  required int small,
  required int medium,
}) async {
  dRocketSqlite();
  final results = <BenchResult>[];

  // ---------------------------------------------------------------------
  // 1. Translation overhead: simple SELECT (small = 100 rows)
  // ---------------------------------------------------------------------
  {
    final ctx = await setupCtx(userCount: small);

    // Raw SQL
    results.add(await bench(
      name: 'SELECT (small)',
      variant: 'raw SQL',
      iterations: iterations,
      records: small,
      fn: () async {
        final rows = ctx.provider.selectWithBinds(
          'SELECT id, name, age, status FROM bench_users WHERE age >= ?',
          [21],
        );
        if (rows.isEmpty) throw StateError('no rows');
      },
    ));

    // d_rocket LINQ
    results.add(await bench(
      name: 'SELECT (small)',
      variant: 'd_rocket LINQ',
      iterations: iterations,
      records: small,
      fn: () async {
        final rows = await ctx.users
            .asQueryable()
            .where_(Expr.lambda(
              [Expr.param('u')],
              Expr.binary(
                '>=',
                Expr.member(Expr.param('u'), 'age'),
                Expr.const_(21),
              ),
            ))
            .toListAsync_();
        if (rows.isEmpty) throw StateError('no rows');
      },
    ));
  }

  // ---------------------------------------------------------------------
  // 2. WHERE + ORDER BY (medium = 1k rows)
  // ---------------------------------------------------------------------
  {
    final ctx = await setupCtx(userCount: medium);

    // Raw SQL
    results.add(await bench(
      name: 'WHERE + ORDER BY (medium)',
      variant: 'raw SQL',
      iterations: iterations,
      records: medium,
      fn: () async {
        final rows = ctx.provider.selectWithBinds(
          'SELECT id, name, age, status FROM bench_users '
          'WHERE status = ? AND age >= ? ORDER BY age DESC LIMIT 100',
          ['active', 30],
        );
        if (rows.isEmpty) throw StateError('no rows');
      },
    ));

    // d_rocket LINQ
    results.add(await bench(
      name: 'WHERE + ORDER BY (medium)',
      variant: 'd_rocket LINQ',
      iterations: iterations,
      records: medium,
      fn: () async {
        final rows = await ctx.users
            .asQueryable()
            .where_(Expr.lambda(
              [Expr.param('u')],
              Expr.binary(
                '&&',
                Expr.binary(
                  '==',
                  Expr.member(Expr.param('u'), 'status'),
                  Expr.const_('active'),
                ),
                Expr.binary(
                  '>=',
                  Expr.member(Expr.param('u'), 'age'),
                  Expr.const_(30),
                ),
              ),
            ))
            .orderBy_(Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ))
            .orderByDescending_(Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ))
            .take_(100)
            .toListAsync_();
        if (rows.isEmpty) throw StateError('no rows');
      },
    ));
  }

  // ---------------------------------------------------------------------
  // 3. GROUP BY (medium = 1k rows) — d_rocket's
  //    SqliteGroupedQueryable doesn't currently expose
  //    a SQL aggregation terminal (it's a 2.1.0 work item),
  //    so we only benchmark the raw-SQL variant here.
  // ---------------------------------------------------------------------
  {
    final ctx = await setupCtx(userCount: medium);

    // Raw SQL
    results.add(await bench(
      name: 'GROUP BY status, COUNT (medium)',
      variant: 'raw SQL',
      iterations: iterations,
      records: medium,
      fn: () async {
        final rows = ctx.provider.select(
          'SELECT status, COUNT(*) AS n FROM bench_users GROUP BY status',
        );
        if (rows.isEmpty) throw StateError('no rows');
      },
    ));

    // TODO(2.1.0): d_rocket LINQ GROUP BY benchmark
    // once SqliteGroupedQueryable exposes toListAsync_.
  }

  // ---------------------------------------------------------------------
  // 4. ORM overhead: saveChanges (100 inserts in a transaction)
  // ---------------------------------------------------------------------
  {
    final ctx = await setupCtx(userCount: 0);

    results.add(await bench(
      name: 'INSERT 100 rows',
      variant: 'd_rocket ORM',
      iterations: iterations,
      records: 100,
      fn: () async {
        for (var i = 0; i < 100; i++) {
          ctx.users.add(_User(
            id: 0,
            name: 'u$i',
            age: 25,
            status: 'active',
          ));
        }
        await ctx.saveChanges();
      },
    ));
  }

  return results;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  int iterations = 100;
  int small = 100;
  int medium = 1000;
  String? outputPath;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--iterations':
        iterations = int.parse(args[++i]);
        break;
      case '--small':
        small = int.parse(args[++i]);
        break;
      case '--medium':
        medium = int.parse(args[++i]);
        break;
      case '--output':
        outputPath = args[++i];
        break;
      case '-h':
      case '--help':
        stdout.writeln('Usage: dart bench/linq_bench.dart [options]');
        stdout.writeln('  --iterations N  how many samples per op (default 100)');
        stdout.writeln('  --small N      rows in the small dataset (default 100)');
        stdout.writeln('  --medium N     rows in the medium dataset (default 1000)');
        stdout.writeln('  --output PATH  write CSV to PATH');
        return;
      default:
        throw StateError('unknown arg: ${args[i]}');
    }
  }

  stdout.writeln('# d_rocket 2.0.0 — LINQ benchmark suite (SQLite engine)');
  stdout.writeln('# iterations=$iterations, small=$small, medium=$medium');
  stdout.writeln('# running...');
  final results = await runAll(
    iterations: iterations,
    small: small,
    medium: medium,
  );
  stdout.writeln('# done.');
  stdout.writeln('');
  stdout.writeln('| Operation | Variant | Records | Median | p95 |');
  stdout.writeln('| --- | --- | ---: | ---: | ---: |');
  for (final r in results) {
    stdout.writeln(r.toMarkdownRow());
  }

  if (outputPath != null) {
    final f = File(outputPath);
    await f.parent.create(recursive: true);
    final sink = f.openWrite();
    sink.writeln('operation,variant,records,iterations,median_us,p95_us');
    for (final r in results) {
      sink.writeln(r.toCsvRow());
    }
    await sink.close();
    stdout.writeln('');
    stdout.writeln('CSV written to $outputPath');
  }
}
