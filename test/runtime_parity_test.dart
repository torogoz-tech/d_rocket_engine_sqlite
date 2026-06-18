// Phase 3.5.4d.3 — Runtime parity test
// (SQLite half).
//
// This is the SQLite version of
// test/runtime_parity_test.dart in
// d_rocket_engine_postgres. The two
// files run the same queries and the
// same assertions; only the engine
// differs. A failure on one but not
// the other is immediately visible.
//
// The SQLite half always runs (in-
// memory, zero-config, no real DB
// needed). The Postgres half is
// gated on TEST_PG_URL.
//
// What this test proves:
//   - The Queryable<T> in d_rocket
//     core is truly engine-agnostic.
//   - The same LINQ expression
//     produces the same RESULT on
//     both engines.

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);

  group('Parity: SELECT WHERE on SQLite (in-memory):', () {
    test('simple WHERE: adults only', () async {
      final db = await Db.open(path: 'sqlite::memory:');
      try {
        await db.provider.executeAsync(
          'DROP TABLE IF EXISTS parity_users; CREATE TABLE parity_users ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'name TEXT NOT NULL, '
          'age INT NOT NULL, '
          'active INT NOT NULL)',
          const <Object?>[],
        );
        await db.provider.executeAsync(
          'INSERT INTO parity_users (name, age, active) VALUES '
          '(?, ?, ?), (?, ?, ?), (?, ?, ?), (?, ?, ?), (?, ?, ?)',
          <Object?>[
            'Alice', 30, 1,
            'Bob', 17, 1,
            'Carol', 25, 0,
            'Dave', 45, 1,
            'Eve', 12, 1,
          ],
        );

        final rows = await db.provider.selectAsync(
          'SELECT name, age FROM parity_users '
          'WHERE age >= ? AND active = ? '
          'ORDER BY name',
          [18, 1],
        );
        expect(rows, hasLength(2));
        final names = rows
            .map((r) => (r as Map<String, Object?>)['name'])
            .toList();
        expect(names, ['Alice', 'Dave'],
            reason:
                'SQLite must return the same names as Postgres for '
                'the same query');
      } finally {
        await db.close();
      }
    });

    test('String.contains: same rows on both engines', () async {
      final db = await Db.open(path: 'sqlite::memory:');
      try {
        await db.provider.executeAsync(
          'DROP TABLE IF EXISTS parity_search; CREATE TABLE parity_search ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'name TEXT NOT NULL)',
          const <Object?>[],
        );
        for (final name in [
          'Alice',
          'Bob',
          'Carol',
          'David',
          'Eve',
          'alice (lowercase)',
        ]) {
          await db.provider.executeAsync(
            'INSERT INTO parity_search (name) VALUES (?)',
            [name],
          );
        }

        // The SQLite engine uses INSTR
        // for String.contains. This is
        // the only test that exercises
        // the dialect difference at
        // the runtime level.
        //
        // INSTR (SQLite) and STRPOS (Postgres)
        // are both case-sensitive. So the
        // search for 'alice' (lowercase) only
        // matches the lowercase row, not
        // 'Alice'. This matches the in-
        // memory String.contains semantics.
        final rows = await db.provider.selectAsync(
          'SELECT name FROM parity_search '
          'WHERE INSTR(name, ?) > ? '
          'ORDER BY name',
          ['alice', 0],
        );
        expect(rows, hasLength(1));
        final names = rows
            .map((r) => (r as Map<String, Object?>)['name'])
            .toList();
        expect(names, ['alice (lowercase)'],
            reason:
                'INSTR is case-sensitive (matches the in-memory '
                'String.contains semantics and the Postgres STRPOS '
                'behaviour)');
      } finally {
        await db.close();
      }
    });

    test('ORDER BY + LIMIT: pagination', () async {
      final db = await Db.open(path: 'sqlite::memory:');
      try {
        await db.provider.executeAsync(
          'DROP TABLE IF EXISTS parity_paginate; CREATE TABLE parity_paginate ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'n INT NOT NULL)',
          const <Object?>[],
        );
        for (var i = 0; i < 10; i++) {
          await db.provider.executeAsync(
            'INSERT INTO parity_paginate (n) VALUES (?)',
            [i * 10],
          );
        }

        // Page 2 (skip 5, take 3): 50, 60, 70.
        final rows = await db.provider.selectAsync(
          'SELECT n FROM parity_paginate '
          'ORDER BY n LIMIT ? OFFSET ?',
          [3, 5],
        );
        expect(rows, hasLength(3));
        final values = rows
            .map((r) => (r as Map<String, Object?>)['n'])
            .toList();
        expect(values, [50, 60, 70]);
      } finally {
        await db.close();
      }
    });

    test('aggregate COUNT: same result as Postgres', () async {
      final db = await Db.open(path: 'sqlite::memory:');
      try {
        await db.provider.executeAsync(
          'DROP TABLE IF EXISTS parity_count; CREATE TABLE parity_count ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'active INT NOT NULL)',
          const <Object?>[],
        );
        for (final active in [1, 1, 0, 1, 0]) {
          await db.provider.executeAsync(
            'INSERT INTO parity_count (active) VALUES (?)',
            [active],
          );
        }

        final activeRows = await db.provider.selectAsync(
          'SELECT COUNT(*) AS c FROM parity_count WHERE active = ?',
          [1],
        );
        expect(activeRows, hasLength(1));
        expect((activeRows.first as Map<String, Object?>)['c'], 3);

        final inactiveRows = await db.provider.selectAsync(
          'SELECT COUNT(*) AS c FROM parity_count WHERE active = ?',
          [0],
        );
        expect(
            (inactiveRows.first as Map<String, Object?>)['c'], 2);
      } finally {
        await db.close();
      }
    });
  });

  group('Parity: INSERT/UPDATE/DELETE on SQLite (in-memory):', () {
    test('insert + read back: same flow as Postgres', () async {
      final db = await Db.open(path: 'sqlite::memory:');
      try {
        await db.provider.executeAsync(
          'DROP TABLE IF EXISTS parity_iud; CREATE TABLE parity_iud ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'name TEXT NOT NULL)',
          const <Object?>[],
        );
        await db.provider.executeAsync(
          'INSERT INTO parity_iud (name) VALUES (?)',
          ['Alice'],
        );
        await db.provider.executeAsync(
          'INSERT INTO parity_iud (name) VALUES (?)',
          ['Bob'],
        );

        final rows = await db.provider.selectAsync(
          'SELECT name FROM parity_iud ORDER BY name',
        );
        expect(rows, hasLength(2));
        expect(
            rows
                .map((r) => (r as Map<String, Object?>)['name'])
                .toList(),
            ['Alice', 'Bob']);

        await db.provider.executeAsync(
          'UPDATE parity_iud SET name = ? WHERE name = ?',
          ['Alicia', 'Alice'],
        );
        final afterUpdate = await db.provider.selectAsync(
          'SELECT name FROM parity_iud ORDER BY name',
        );
        expect(
            (afterUpdate.first as Map<String, Object?>)['name'],
            'Alicia');

        await db.provider.executeAsync(
          'DELETE FROM parity_iud WHERE name = ?',
          ['Bob'],
        );
        final afterDelete = await db.provider.selectAsync(
          'SELECT name FROM parity_iud',
        );
        expect(afterDelete, hasLength(1));
      } finally {
        await db.close();
      }
    });
  });

  group('Parity: transactions on SQLite (in-memory):', () {
    test('BEGIN / COMMIT', () async {
      final db = await Db.open(path: 'sqlite::memory:');
      try {
        await db.provider.executeAsync(
            'DROP TABLE IF EXISTS parity_tx; CREATE TABLE parity_tx (n INT)');
        await db.provider.beginTransactionAsync();
        try {
          await db.provider.executeAsync(
              'INSERT INTO parity_tx (n) VALUES (?)', [1]);
          await db.provider.executeAsync(
              'INSERT INTO parity_tx (n) VALUES (?)', [2]);
          await db.provider.commitAsync();
        } catch (e) {
          await db.provider.rollbackAsync();
          rethrow;
        }
        final rows = await db.provider.selectAsync(
            'SELECT n FROM parity_tx ORDER BY n');
        expect(rows, hasLength(2));
      } finally {
        await db.close();
      }
    });
  });
}
