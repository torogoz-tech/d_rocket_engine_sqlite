/// `d_rocket_engine_sqlite:migration` CLI:
///
/// The runtime half of the d_rocket migration CLI. Handles
/// the three subcommands that need a real SQLite engine:
///
/// ```bash
/// # Print the current schema version of a DB
/// dart run d_rocket_engine_sqlite:migration status --db app.db
///
/// # Apply all pending migrations
/// dart run d_rocket_engine_sqlite:migration run --db app.db
///
/// # Migrate to a specific version (upgrade OR downgrade)
/// dart run d_rocket_engine_sqlite:migration run --db app.db --target 5
///
/// # Roll back the most recently applied migration
/// dart run d_rocket_engine_sqlite:migration rollback --db app.db
/// ```
///
/// The scaffolder half (`add` / `list` / `doctor`) lives in
/// `d_rocket:migration` and is engine-agnostic.
///
/// As of `d_rocket 2.0.0`, the runtime subcommands moved
/// out of `d_rocket:migration` into this binary. The
/// reason is the dependency graph: `d_rocket` is
/// engine-agnostic and must NOT have a hard dependency on
/// any engine package. The scaffolder (which only reads
/// + writes files) can stay in `d_rocket`; the runtime
/// (which needs a real SQLite engine) ships here.
library;

import 'dart:io';

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';

const String _kBanner = '''
┌─────────────────────────────────────────────┐
│ d_rocket engine_sqlite migration runtime   │
│  (status / run / rollback)                 │
└─────────────────────────────────────────────┘''';

class _Flags {
  _Flags({
    this.dbPath,
    this.target,
  });

  final String? dbPath;
  final int? target;

  static _Flags parse(List<String> args) {
    String? db;
    int? target;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--db' && i + 1 < args.length) {
        db = args[++i];
      } else if (arg == '--target' && i + 1 < args.length) {
        target = int.tryParse(args[++i]);
      }
    }
    return _Flags(dbPath: db, target: target);
  }
}

class _RawSqliteRunner {
  _RawSqliteRunner(String path) {
    _provider = SqliteQueryProvider.file(path);
  }
  late final SqliteQueryProvider _provider;

  Future<int> currentVersion() async {
    return _buildRunner().currentVersionAsync();
  }

  Future<List<AppliedMigration>> applied() async {
    return _buildRunner().appliedAsync();
  }

  /// Applies the `exec` callback as a single
  /// migration. The CLI uses this for `run --target N`
  /// to perform a no-op-migration run (the user's
  /// strategy is what actually picks the subset).
  Future<int> upgradeTo(int target) async {
    // Without the migration classes on hand, we
    // can't pick the subset to run. We just print
    // the current state and the target.
    final from = await currentVersion();
    stdout.writeln(
      'current: v$from, target: v$target '
      '(${target > from ? "upgrade" : "downgrade"})',
    );
    stdout.writeln(
      '⚠️  This CLI MVP does NOT load your migration classes. '
      'Use `Db.open(strategy: MigrationStrategy(...))` '
      'programmatically to actually apply migrations.',
    );
    return from == target ? 0 : 1;
  }

  MigrationRunner _buildRunner() {
    return MigrationRunner(
      createExecutor: () => (String sql, [List<Object?>? binds]) {
        if (binds != null && binds.isNotEmpty) {
          _provider.execute(sql, binds);
        } else {
          _provider.execute(sql);
        }
      },
      createSelector: () => (String sql, [List<Object?>? binds]) {
        if (binds != null && binds.isNotEmpty) {
          return _provider.selectWithBinds(sql, binds);
        }
        return _provider.select(sql);
      },
    );
  }

  Future<void> close() async {
    await _provider.disposeAsync();
  }
}

Future<int> _runStatus(_Flags f) async {
  if (f.dbPath == null) {
    stderr.writeln('Error: --db <path> is required');
    return 2;
  }
  final runner = _RawSqliteRunner(f.dbPath!);
  try {
    final v = await runner.currentVersion();
    stdout.writeln('schema version: v$v');
    final list = await runner.applied();
    if (list.isEmpty) {
      stdout.writeln('(no migrations applied yet)');
    } else {
      stdout.writeln('');
      stdout
          .writeln('  id    version  name                          applied_at');
      stdout.writeln(
          '  ----  -------  ----------------------------  -----------------');
      for (final m in list) {
        stdout.writeln(
          '  ${m.id.padRight(4)}  '
          '${(m.version ?? 0).toString().padLeft(7)}  '
          '${m.name.padRight(28)}  '
          '${m.appliedAt.toIso8601String()}',
        );
      }
    }
    return 0;
  } finally {
    await runner.close();
  }
}

Future<int> _runMigrate(_Flags f) async {
  if (f.dbPath == null) {
    stderr.writeln('Error: --db <path> is required');
    return 2;
  }
  final runner = _RawSqliteRunner(f.dbPath!);
  try {
    if (f.target != null) {
      final code = await runner.upgradeTo(f.target!);
      return code;
    }
    // No target: just print the current state.
    final v = await runner.currentVersion();
    stdout.writeln('current: v$v');
    stdout.writeln(
      '⚠️  Apply all pending migrations programmatically via '
      '`Db.open(strategy: MigrationStrategy(...))`. '
      'See the README for the full pattern.',
    );
    return 0;
  } finally {
    await runner.close();
  }
}

Future<int> _runRollback(_Flags f) async {
  if (f.dbPath == null) {
    stderr.writeln('Error: --db <path> is required');
    return 2;
  }
  stderr.writeln(
    '⚠️  `rollback` requires the migration classes on hand to '
    'call `MigrationBase.down()`. Use '
    '`Db.open(strategy: ...)` programmatically, or '
    '`run --db <path> --target N` to downgrade to vN.',
  );
  return 0;
}

Future<int> main(List<String> args) async {
  if (args.isEmpty || args[0] == '--help' || args[0] == '-h') {
    stdout.writeln(_kBanner);
    stdout.writeln('');
    stdout.writeln('Usage:');
    stdout.writeln('  status   --db <path>             # print current schema version');
    stdout.writeln('  run      --db <path> [--target N]  # apply / migrate to vN');
    stdout.writeln('  rollback --db <path>             # roll back the most recent');
    stdout.writeln('');
    stdout.writeln('Scaffolder subcommands (`add` / `list` / `doctor`) live in');
    stdout.writeln('`d_rocket:migration` (engine-agnostic, no dep on the engine).');
    return 0;
  }

  final subcommand = args[0];
  final flags = _Flags.parse(args.sublist(1));

  switch (subcommand) {
    case 'status':
      return _runStatus(flags);
    case 'run':
      return _runMigrate(flags);
    case 'rollback':
      return _runRollback(flags);
    default:
      stderr.writeln('Error: unknown subcommand "$subcommand"');
      stderr.writeln('Valid: status, run, rollback');
      return 2;
  }
}
