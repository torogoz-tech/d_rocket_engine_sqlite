// Tests for the optional SQLCipher password support on
// `Db.open` / `Db.inMemory` and `SqliteQueryProvider`.
//
// Three concerns are covered:
//
// 1. **API surface (always runs).** The new `password`
// parameter is accepted on every public entry point,
// the back-compat path (`password: null` / omitted) still
// works, and single-quote characters in the password
// are safely escaped (no SQL injection, no syntax error).
//
// 2. **Encryption round-trip (skipped without libsqlcipher).**
// On a test machine with a SQLCipher build available,
// the file path: open with a password, insert, close,
// reopen with the same password and read the row back.
// A second reopen with the wrong password must throw a
// [DatabaseException] at open time (not at first read).
//
// 3. **Probe helper.** `_sqlcipherAvailable()` is used to
// gate the encryption round-trip tests. The probe opens
// an in-memory DB with a deliberately wrong password:
// if the engine is SQLCipher, the first verification
// query raises `SQLITE_NOTADB` and the probe returns
// true. If the engine is vanilla SQLite, the `PRAGMA key`
// is a no-op and the probe returns false.

import 'dart:io';

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

bool? _sqlcipherCache;

bool _sqlcipherAvailable() {
  if (_sqlcipherCache != null) return _sqlcipherCache!;
  try {
    final SqliteQueryProvider p = SqliteQueryProvider.inMemory(
      password: '__d_rocket_probe__',
    );
    p.dispose();
    _sqlcipherCache = false;
    return false;
  } on DatabaseException {
    _sqlcipherCache = true;
    return true;
  }
}

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group('Encrypted DB — API surface', () {
    test('SqliteQueryProvider.file accepts password parameter (compile check)',
        () {
      final SqliteQueryProvider p = SqliteQueryProvider.file(
        '${Directory.systemTemp.path}/d_rocket_compile_check.db',
        password: 'compile-check',
      );
      p.dispose();
    });

    test('SqliteQueryProvider.inMemory accepts password parameter '
        '(compile check)', () {
      final SqliteQueryProvider p = SqliteQueryProvider.inMemory(
        password: 'compile-check',
      );
      p.dispose();
    });

    test('Db.open and Db.inMemory accept password parameter (compile check)',
        () async {
      final Db db1 = await Db.inMemory(password: 'compile-check');
      await db1.close();

      final String tmp =
          '${Directory.systemTemp.path}/d_rocket_db_compile_check.db';
      try {
        final Db db2 = await Db.open(
          path: tmp,
          password: 'compile-check',
        );
        await db2.close();
      } finally {
        try {
          await File(tmp).delete();
        } catch (_) {
          // best-effort cleanup
        }
      }
    });

    test('password with a single quote is escaped, not interpreted as SQL',
        () async {
      // The escape is a doubling of single quotes. The
      // resulting `PRAGMA key = 'O''Brien'` is a valid
      // SQLCipher string literal. Without the escape, the
      // open would throw on the malformed SQL.
      final Db db = await Db.inMemory(password: "O'Brien");
      await db.close();
    });

    test('back-compat: opening without a password still works (Db.open + '
        'Db.inMemory)', () async {
      final Db db1 = await Db.inMemory();
      await db1.close();

      final String tmp =
          '${Directory.systemTemp.path}/d_rocket_backcompat.db';
      try {
        final Db db2 = await Db.open(path: tmp);
        await db2.close();
      } finally {
        try {
          await File(tmp).delete();
        } catch (_) {
          // best-effort cleanup
        }
      }
    });
  });

  group('Encrypted DB — SQLCipher round-trip (requires libsqlcipher)', () {
    final bool available = _sqlcipherAvailable();

    test('round-trip: open → insert → close → reopen → read', () async {
      if (!available) {
        return;
      }
      final String tmp = Directory.systemTemp
          .createTempSync('d_rocket_sqlcipher_roundtrip_')
          .path;
      final String dbPath = '$tmp/encrypted.db';
      const String password = 'correct horse battery staple';

      // First open: create table, insert row, close.
      Db first = await Db.open(path: dbPath, password: password);
      try {
        await first.provider
            .executeAsync('CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT)');
        await first.provider
            .executeAsync('INSERT INTO t (n) VALUES (?)', ['hello']);
      } finally {
        await first.close();
      }

      // Reopen with the same password: the row must be there.
      Db second = await Db.open(path: dbPath, password: password);
      try {
        final List<Object?> rows = await second.provider
            .selectAsync('SELECT n FROM t ORDER BY id');
        expect(rows, hasLength(1));
        expect((rows.first as Map<String, Object?>)['n'], 'hello');
      } finally {
        await second.close();
      }

      // Reopen with a wrong password: open must throw
      // DatabaseException, not return an empty DB.
      Object? caught;
      try {
        Db wrong = await Db.open(path: dbPath, password: 'wrong-password');
        await wrong.close();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<DatabaseException>(),
          reason: 'Wrong password must fail at open time with a '
              'DatabaseException, not silently return a corrupt DB.');

      try {
        await Directory(tmp).delete(recursive: true);
      } catch (_) {
        // best-effort cleanup
      }
    }, skip: !available ? 'libsqlcipher not available on the test host' : null);
  });
}
