// End-to-end tests for the `MigrationRunner` against
// a real SQLite in-memory database.
//
// These tests wire the `MigrationBase` + `MigrationRunner` runtime
// to the `SqliteQueryProvider` so the user can verify that:
// * the `_d_rocket_migrations` tracking table is created,
// * the user's `up` callbacks actually create real
// tables / indices / foreign keys in SQLite,
// * a second `run` with the same migrations is a no-op
// (idempotency), and
// * `rollback` reverses the migrations in reverse order.

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
// Row type replaced with Map<String, Object?> in
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group('Fase 3.6 — MigrationRunner end-to-end with SQLite', () {
    test(
        'creates the _d_rocket_migrations table + runs the user\'s '
        'up() callbacks in lexicographic order', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      final List<String> executed = <String>[];
      final List<MigrationBase> migrations = <MigrationBase>[
        _$001CreateAuthors(),
        _$002CreateBooks(),
        _$003AddIndexOnBookTitle(),
      ];

      final MigrationRunner runner = MigrationRunner(
        createExecutor: () => (String sql, [List<Object?>? binds]) {
          executed.add(sql);
          if (binds == null) {
            provider.execute(sql);
          } else {
            provider.execute(sql, binds);
          }
        },
        createSelector: () => (String sql, [List<Object?>? binds]) {
          if (binds == null) return provider.select(sql);
          return provider.selectWithBinds(sql, binds);
        },
      );

      // 1. First run: applies all 3 migrations in order.
      final List<MigrationBase> applied1 = runner.run(migrations);
      expect(applied1, hasLength(3));
      expect(applied1.map((MigrationBase m) => m.id).toList(),
          <String>['001', '002', '003']);

      // 2. The tracking table exists and has 3 rows.
      final List<Map<String, Object?>> appliedRows = provider.select(
        'SELECT id, name FROM _d_rocket_migrations ORDER BY id',
      );
      expect(appliedRows, hasLength(3));
      expect(appliedRows[0]['id'], '001');
      expect(appliedRows[1]['id'], '002');
      expect(appliedRows[2]['id'], '003');

      // 3. The user's tables exist.
      final List<Map<String, Object?>> tables = provider.select(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      );
      final List<Object?> tableNames =
          tables.map((Map<String, Object?> r) => r['name']).toList();
      expect(
          tableNames,
          containsAll(<Object?>[
            '_d_rocket_migrations',
            'authors',
            'books',
          ]));

      // 4. The CREATE INDEX statement was actually run.
      final List<Map<String, Object?>> indexes = provider.select(
        "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx%'",
      );
      expect(indexes.map((Map<String, Object?> r) => r['name']).toList(),
          contains('idx_books_title'));

      provider.dispose();
    });

    test(
        're-running the same migrations is a no-op '
        '(idempotency via createSelector)', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      final List<String> executed = <String>[];

      final MigrationRunner runner = MigrationRunner(
        createExecutor: () => (String sql, [List<Object?>? binds]) {
          executed.add(sql);
          if (binds == null) {
            provider.execute(sql);
          } else {
            provider.execute(sql, binds);
          }
        },
        createSelector: () => (String sql, [List<Object?>? binds]) {
          if (binds == null) return provider.select(sql);
          return provider.selectWithBinds(sql, binds);
        },
      );

      final List<MigrationBase> migrations = <MigrationBase>[
        _$001CreateAuthors(),
        _$002CreateBooks(),
      ];

      // First run: applies all 2 migrations.
      runner.run(migrations);
      expect(executed.length, greaterThanOrEqualTo(2));

      // Second run: re-uses the same provider + the same
      // runner instance. The runner queries the
      // `_d_rocket_migrations` table via the selector and
      // skips the already-applied migrations.
      executed.clear();
      final List<MigrationBase> applied2 = runner.run(migrations);
      expect(applied2, isEmpty,
          reason: 'Idempotency: the second run() should be a no-op');
      // The only SQL emitted in the second run is the
      // SELECT against `_d_rocket_migrations` (and possibly
      // the CREATE TABLE IF NOT EXISTS for the tracking
      // table itself, which is also idempotent).
      // The user's CREATE TABLE statements should NOT run.
      final bool createdAuthorsAgain = executed.any(
        (String s) => s.contains('CREATE TABLE authors'),
      );
      expect(createdAuthorsAgain, isFalse,
          reason: 'The second run() must not re-create the user\'s tables');

      provider.dispose();
    });

    test(
        'rollback() reverses the migrations in reverse order '
        'and removes them from the tracking table', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      final List<String> executed = <String>[];

      final MigrationRunner runner = MigrationRunner(
        createExecutor: () => (String sql, [List<Object?>? binds]) {
          executed.add(sql);
          if (binds == null) {
            provider.execute(sql);
          } else {
            provider.execute(sql, binds);
          }
        },
        createSelector: () => (String sql, [List<Object?>? binds]) {
          if (binds == null) return provider.select(sql);
          return provider.selectWithBinds(sql, binds);
        },
      );

      final List<MigrationBase> migrations = <MigrationBase>[
        _$001CreateAuthors(),
        _$002CreateBooks(),
        _$003AddIndexOnBookTitle(),
      ];

      // 1. Apply.
      runner.run(migrations);
      // 2. Roll back.
      final List<MigrationBase> rolled = runner.rollback(migrations);
      expect(rolled.map((MigrationBase m) => m.id).toList(),
          <String>['003', '002', '001'],
          reason: 'rollback() must reverse the order');

      // 3. The tracking table is now empty.
      final List<Map<String, Object?>> appliedRows = provider.select(
        'SELECT id FROM _d_rocket_migrations',
      );
      expect(appliedRows, isEmpty);

      // 4. The user's tables are gone. (We exclude the
      // SQLite-internal `sqlite_sequence` table that
      // SQLite creates automatically when the user uses
      // `AUTOINCREMENT`. It's not a user-defined table and
      // is harmless.)
      final List<Map<String, Object?>> tables = provider.select(
        "SELECT name FROM sqlite_master "
        "WHERE type='table' "
        "  AND name NOT IN ('_d_rocket_migrations', 'sqlite_sequence')",
      );
      expect(tables, isEmpty,
          reason: 'rollback() must DROP the user\'s tables');

      provider.dispose();
    });

    test(
        'an irreversible migration is skipped on rollback '
        '(its down() throws UnsupportedError)', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();

      final MigrationRunner runner = MigrationRunner(
        createExecutor: () => (String sql, [List<Object?>? binds]) {
          if (binds == null) {
            provider.execute(sql);
          } else {
            provider.execute(sql, binds);
          }
        },
        createSelector: () => (String sql, [List<Object?>? binds]) {
          if (binds == null) return provider.select(sql);
          return provider.selectWithBinds(sql, binds);
        },
      );

      // A migration that doesn't override `down`. The
      // base class's `down` throws UnsupportedError.
      final MigrationBase irreversible = _IrreversibleMigration();

      final List<MigrationBase> rolled = runner.rollback(<MigrationBase>[
        irreversible,
      ]);
      expect(rolled, isEmpty,
          reason: 'Irreversible migrations are silently skipped on rollback');

      provider.dispose();
    });

    test(
        'Fase 3.7: each up() runs inside a transaction; on success '
        'the runner commits', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      final List<String> executed = <String>[];

      final MigrationRunner runner = MigrationRunner(
        createExecutor: () => (String sql, [List<Object?>? binds]) {
          executed.add(sql);
          if (binds == null) {
            provider.execute(sql);
          } else {
            provider.execute(sql, binds);
          }
        },
        createTransaction: () {
          executed.add('BEGIN');
          provider.execute('BEGIN');
          return MigrationTransaction(
            executor: (String sql, [List<Object?>? binds]) {
              executed.add(sql);
              if (binds == null) {
                provider.execute(sql);
              } else {
                provider.execute(sql, binds);
              }
            },
            commit: () {
              executed.add('COMMIT');
              provider.execute('COMMIT');
            },
            rollback: () {
              executed.add('ROLLBACK');
              provider.execute('ROLLBACK');
            },
          );
        },
        createSelector: () => (String sql, [List<Object?>? binds]) {
          if (binds == null) return provider.select(sql);
          return provider.selectWithBinds(sql, binds);
        },
      );

      final List<MigrationBase> applied = runner.run(<MigrationBase>[
        _$001CreateAuthors(),
        _$002CreateBooks(),
      ]);
      expect(applied, hasLength(2));

      // Every user migration runs between a BEGIN and a COMMIT.
      // We assert at least two BEGINs and two COMMITs and
      // no ROLLBACKs in the success path.
      expect(executed.where((String s) => s == 'BEGIN').length,
          greaterThanOrEqualTo(2));
      expect(executed.where((String s) => s == 'COMMIT').length,
          greaterThanOrEqualTo(2));
      expect(executed.where((String s) => s == 'ROLLBACK'), isEmpty);

      // The user tables exist.
      final List<Map<String, Object?>> tables = provider.select(
        "SELECT name FROM sqlite_master "
        "WHERE type='table' AND name NOT IN ('_d_rocket_migrations', 'sqlite_sequence')",
      );
      expect(tables, hasLength(2));

      provider.dispose();
    });

    test(
        'Fase 3.7: a failing up() rolls back the transaction; the '
        'migration is not recorded', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      final List<String> executed = <String>[];

      final MigrationRunner runner = MigrationRunner(
        createExecutor: () => (String sql, [List<Object?>? binds]) {
          executed.add(sql);
          if (binds == null) {
            provider.execute(sql);
          } else {
            provider.execute(sql, binds);
          }
        },
        createTransaction: () {
          executed.add('BEGIN');
          provider.execute('BEGIN');
          return MigrationTransaction(
            executor: (String sql, [List<Object?>? binds]) {
              executed.add(sql);
              if (binds == null) {
                provider.execute(sql);
              } else {
                provider.execute(sql, binds);
              }
            },
            commit: () {
              executed.add('COMMIT');
              provider.execute('COMMIT');
            },
            rollback: () {
              executed.add('ROLLBACK');
              provider.execute('ROLLBACK');
            },
          );
        },
        createSelector: () => (String sql, [List<Object?>? binds]) {
          if (binds == null) return provider.select(sql);
          return provider.selectWithBinds(sql, binds);
        },
      );

      // 1. Apply a good migration (the tracking table + a
      // user table).
      runner.run(<MigrationBase>[_$001CreateAuthors()]);

      // 2. Now apply a BAD migration that throws mid-up.
      // The runner must roll back the transaction; the
      // bad migration must NOT be recorded.
      final MigrationBase bad = _FailingMigration();
      expect(() => runner.run(<MigrationBase>[bad]), throwsStateError);

      // 3. The tracking table must still contain only the
      // good migration.
      final List<Map<String, Object?>> appliedRows = provider.select(
        "SELECT id FROM _d_rocket_migrations ORDER BY id",
      );
      expect(appliedRows, hasLength(1));
      expect(appliedRows.first['id'], '001');

      // 4. There must be a ROLLBACK in the executed list.
      expect(executed, contains('ROLLBACK'));
      // 5. The last `BEGIN; ... ROLLBACK;` block is the
      // failing one: the last BEGIN is after the
      // last COMMIT (the failing transaction was
      // never closed with a COMMIT), and the last
      // ROLLBACK is after the last BEGIN.
      final int lastBegin = executed.lastIndexOf('BEGIN');
      final int lastCommit = executed.lastIndexOf('COMMIT');
      final int lastRollback = executed.lastIndexOf('ROLLBACK');
      expect(lastBegin, greaterThan(lastCommit),
          reason: 'Failing migration\'s BEGIN is after the last COMMIT');
      expect(lastRollback, greaterThan(lastBegin),
          reason: 'Failing migration ends with a ROLLBACK');

      provider.dispose();
    });
  });
}

// ─── MigrationBase fixtures ────────────────────────────────────────────

class _$001CreateAuthors extends MigrationBase {
  @override
  String get id => '001';
  @override
  String get name => 'Create authors table';

  @override
  void up(MigrationExecutor exec) {
    exec('CREATE TABLE authors ('
        '  id INTEGER PRIMARY KEY AUTOINCREMENT, '
        '  name TEXT NOT NULL)');
  }

  @override
  void down(MigrationExecutor exec) {
    exec('DROP TABLE authors');
  }
}

class _$002CreateBooks extends MigrationBase {
  @override
  String get id => '002';
  @override
  String get name => 'Create books table (with FK to authors)';

  @override
  void up(MigrationExecutor exec) {
    exec('CREATE TABLE books ('
        '  id INTEGER PRIMARY KEY AUTOINCREMENT, '
        '  author_id INTEGER NOT NULL REFERENCES authors(id), '
        '  title TEXT NOT NULL, '
        '  price REAL NOT NULL)');
  }

  @override
  void down(MigrationExecutor exec) {
    exec('DROP TABLE books');
  }
}

class _$003AddIndexOnBookTitle extends MigrationBase {
  @override
  String get id => '003';
  @override
  String get name => 'Add index on books.title';

  @override
  void up(MigrationExecutor exec) {
    exec('CREATE INDEX idx_books_title ON books (title)');
  }

  @override
  void down(MigrationExecutor exec) {
    exec('DROP INDEX idx_books_title');
  }
}

class _IrreversibleMigration extends MigrationBase {
  @override
  String get id => 'X';
  @override
  String get name => 'Irreversible';

  @override
  void up(MigrationExecutor exec) {
    exec('CREATE TABLE tmp_xyz (id INTEGER PRIMARY KEY)');
  }
  // Note: no `down` override — inherits the base class's
  // throw-UnsupportedError default.
}

class _FailingMigration extends MigrationBase {
  @override
  String get id => '999';
  @override
  String get name => 'Always fails';

  @override
  void up(MigrationExecutor exec) {
    // First statement would succeed (the table would be
    // created), but the runner is in a transaction, so it
    // doesn't persist after rollback. The second statement
    // throws — the runner catches it and rolls back.
    exec('CREATE TABLE tmp_fail (id INTEGER PRIMARY KEY)');
    throw StateError('Simulated failure mid-up()');
  }

  @override
  void down(MigrationExecutor exec) {
    exec('DROP TABLE IF EXISTS tmp_fail');
  }
}
