// Verifies that PRAGMA foreign_keys = ON is set on
// every open. SQLite ships with FK enforcement off
// by default; without this PRAGMA, the FOREIGN KEY
// clauses in CREATE TABLE are parsed and stored but
// never enforced at runtime. This is a silent data
// integrity risk: a row can be inserted with a
// dangling reference, and the constraint violation
// only surfaces if a tool happens to re-enable FKs.
//
// This test exercises the contract: after
// SqliteQueryProvider.openInMemory, inserting a row
// with a dangling FK must raise a SqliteException.

import 'dart:io';

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group('PRAGMA foreign_keys = ON — enforcement', () {
    test(
        'SqliteQueryProvider.inMemory() sets foreign_keys = ON',
        () {
      final SqliteQueryProvider p =
          SqliteQueryProvider.inMemory();
      try {
        final List<Map<String, Object?>> r = p.database
            .select('PRAGMA foreign_keys');
        expect(r, hasLength(1));
        // PRAGMA foreign_keys returns 0 (off) or 1
        // (on). d_rocket sets it to 1 on every open.
        expect(r.first.values.first, 1);
      } finally {
        p.dispose();
      }
    });

    test(
        'SqliteQueryProvider.file() sets foreign_keys = ON after a clean open',
        () {
      // Use a temp file because we need a real
      // on-disk DB to test the file() factory.
      final String tmp = '${Directory.systemTemp.path}/'
          'd_rocket_fk_enforcement.db';
      try {
        // Open with the file factory and immediately
        // close to drop the connection.
        final SqliteQueryProvider p =
            SqliteQueryProvider.file(tmp);
        try {
          final List<Map<String, Object?>> r = p.database
              .select('PRAGMA foreign_keys');
          expect(r.first.values.first, 1);
        } finally {
          p.dispose();
        }
      } finally {
        // best-effort cleanup; ignore errors.
        File(tmp).deleteSync(recursive: false);
      }
    });

    test(
        'INSERT with a dangling FK raises SqliteException (FK enforcement on)',
        () {
      // The whole point of this test: prove that
      // the PRAGMA is actually doing its job. If
      // the PRAGMA were missing, this test would
      // silently pass (the insert would succeed
      // and leave the table in an inconsistent
      // state).
      final SqliteQueryProvider p =
          SqliteQueryProvider.inMemory();
      try {
        p.database.execute('''
          CREATE TABLE authors (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL
          )
        ''');
        p.database.execute('''
          CREATE TABLE books (
            id INTEGER PRIMARY KEY,
            author_id INTEGER NOT NULL REFERENCES authors(id)
          )
        ''');
        p.database.execute(
          "INSERT INTO authors (id, name) VALUES (1, 'A')",
        );
        // The author exists; this insert must succeed.
        p.database.execute(
          "INSERT INTO books (id, author_id) VALUES (1, 1)",
        );
        // The author 99 does NOT exist. This insert
        // must throw (FK enforcement on).
        expect(
          () => p.database.execute(
            "INSERT INTO books (id, author_id) VALUES (2, 99)",
          ),
          throwsA(isA<SqliteException>()),
          reason: 'FK enforcement is on; dangling FK must throw',
        );
      } finally {
        p.dispose();
      }
    });

    test(
        'Db.inMemory() also enables FK enforcement (end-to-end)',
        () async {
      // This is the "consumer-facing" path: the
      // user just calls Db.inMemory() and expects
      // FKs to work without any extra setup.
      final Db db = await Db.inMemory();
      try {
        db.provider.execute('''
          CREATE TABLE authors (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL
          )
        ''');
        db.provider.execute('''
          CREATE TABLE books (
            id INTEGER PRIMARY KEY,
            author_id INTEGER NOT NULL REFERENCES authors(id)
          )
        ''');
        // Dangling FK must throw at the provider
        // level too (DbContext re-throws).
        expect(
          () => db.provider.execute(
            "INSERT INTO books (id, author_id) VALUES (1, 99)",
          ),
          throwsA(isA<DatabaseException>()),
        );
      } finally {
        await db.close();
      }
    });
  });
}
