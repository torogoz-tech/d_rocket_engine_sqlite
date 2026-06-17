// Tests for the cascade / set-null / restrict /
// no-action policies. These cover:
//
// 1. The `fkClause` helper emits the right SQL
// fragment for each of the 4 `OnDeleteAction`
// values.
// 2. SQLite actually enforces the `ON DELETE …`
// clause at the constraint-check time (cascade
// deletes the dependent, restrict fails, setNull
// sets NULL, noAction fails).

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
// (sqlite3 import removed in — use Map<String, Object?>)
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group('Fase 4.6 — fkClause() emits the right ON DELETE …', () {
    test('cascade → "ON DELETE CASCADE"', () {
      final s = fkClause(ColumnMeta(
        sqlName: 'author_id',
        dartField: 'authorId',
        dartType: int,
        isForeignKey: true,
        foreignTable: 'authors',
        foreignColumn: 'id',
        onDelete: OnDeleteAction.cascade,
      ));
      expect(s, 'REFERENCES "authors"("id") ON DELETE CASCADE');
    });

    test('setNull → "ON DELETE SET NULL"', () {
      final s = fkClause(ColumnMeta(
        sqlName: 'book_id',
        dartField: 'bookId',
        dartType: int,
        nullable: true,
        isForeignKey: true,
        foreignTable: 'books',
        foreignColumn: 'id',
        onDelete: OnDeleteAction.setNull,
      ));
      expect(s, 'REFERENCES "books"("id") ON DELETE SET NULL');
    });

    test('restrict → "ON DELETE RESTRICT"', () {
      final s = fkClause(ColumnMeta(
        sqlName: 'book_id',
        dartField: 'bookId',
        dartType: int,
        isForeignKey: true,
        foreignTable: 'books',
        foreignColumn: 'id',
        onDelete: OnDeleteAction.restrict,
      ));
      expect(s, 'REFERENCES "books"("id") ON DELETE RESTRICT');
    });

    test('noAction → no ON DELETE clause', () {
      final s = fkClause(ColumnMeta(
        sqlName: 'book_id',
        dartField: 'bookId',
        dartType: int,
        isForeignKey: true,
        foreignTable: 'books',
        foreignColumn: 'id',
        onDelete: OnDeleteAction.noAction,
      ));
      expect(s, 'REFERENCES "books"("id")');
    });

    test('non-FK column → empty string', () {
      final s = fkClause(ColumnMeta(
        sqlName: 'title',
        dartField: 'title',
        dartType: String,
      ));
      expect(s, '');
    });
  });

  group('Fase 4.6 — SQLite enforces the ON DELETE clause', () {
    late SqliteQueryProvider provider;

    setUp(() {
      provider = SqliteQueryProvider.inMemory();
      // Enable FK enforcement (SQLite has it OFF by
      // default; 's `ON DELETE …` clauses
      // require it).
      provider.execute('PRAGMA foreign_keys = ON');
    });

    tearDown(() {
      provider.dispose();
    });

    test('CASCADE: deleting the parent deletes the dependents', () {
      provider.execute('''
        CREATE TABLE authors (
          id   INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL
        )
      ''');
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL
            ${fkClause(ColumnMeta(
        sqlName: 'author_id',
        dartField: 'authorId',
        dartType: int,
        isForeignKey: true,
        foreignTable: 'authors',
        foreignColumn: 'id',
        onDelete: OnDeleteAction.cascade,
      ))},
          title     TEXT NOT NULL
        )
      ''');

      provider.execute('INSERT INTO authors (name) VALUES (?)', ['Le Guin']);
      provider.execute(
        'INSERT INTO books (author_id, title) VALUES (?, ?), (?, ?)',
        <Object?>[1, 'Earthsea', 1, 'Tehanu'],
      );

      // Sanity: 2 books exist.
      expect(
        provider.select('SELECT COUNT(*) AS n FROM books').first['n'] as int,
        2,
      );

      // Delete the author → CASCADE → both books gone.
      provider.execute('DELETE FROM authors WHERE id = ?', [1]);
      expect(
        provider.select('SELECT COUNT(*) AS n FROM books').first['n'] as int,
        0,
        reason: 'ON DELETE CASCADE should have removed the dependent rows',
      );
    });

    test('SET NULL: deleting the parent NULLs the FK on dependents', () {
      provider.execute('''
        CREATE TABLE authors (
          id   INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL
        )
      ''');
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER
            ${fkClause(ColumnMeta(
        sqlName: 'author_id',
        dartField: 'authorId',
        dartType: int,
        nullable: true,
        isForeignKey: true,
        foreignTable: 'authors',
        foreignColumn: 'id',
        onDelete: OnDeleteAction.setNull,
      ))},
          title     TEXT NOT NULL
        )
      ''');

      provider.execute('INSERT INTO authors (name) VALUES (?)', ['Le Guin']);
      provider.execute(
        'INSERT INTO books (author_id, title) VALUES (?, ?), (?, ?)',
        <Object?>[1, 'Earthsea', 1, 'Tehanu'],
      );

      // Delete the author → SET NULL → books still
      // exist, but `author_id` is now NULL.
      provider.execute('DELETE FROM authors WHERE id = ?', [1]);
      expect(
        provider.select('SELECT COUNT(*) AS n FROM books').first['n'] as int,
        2,
        reason: 'ON DELETE SET NULL should keep the dependent rows',
      );
      final books = provider.select('SELECT author_id FROM books');
      for (final row in books) {
        expect(row['author_id'], isNull);
      }
    });

    test('RESTRICT: deleting the parent throws SqliteException', () {
      provider.execute('''
        CREATE TABLE authors (
          id   INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL
        )
      ''');
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL
            ${fkClause(ColumnMeta(
        sqlName: 'author_id',
        dartField: 'authorId',
        dartType: int,
        isForeignKey: true,
        foreignTable: 'authors',
        foreignColumn: 'id',
        onDelete: OnDeleteAction.restrict,
      ))},
          title     TEXT NOT NULL
        )
      ''');

      provider.execute('INSERT INTO authors (name) VALUES (?)', ['Le Guin']);
      provider.execute(
        'INSERT INTO books (author_id, title) VALUES (?, ?)',
        <Object?>[1, 'Earthsea'],
      );

      // Delete the author → RESTRICT → SQLite throws.
      expect(
        () => provider.execute('DELETE FROM authors WHERE id = ?', [1]),
        throwsA(isA<DatabaseException>()),
        reason: 'ON DELETE RESTRICT should block the delete',
      );

      // Author and book still exist.
      expect(
        provider.select('SELECT COUNT(*) AS n FROM authors').first['n'] as int,
        1,
      );
      expect(
        provider.select('SELECT COUNT(*) AS n FROM books').first['n'] as int,
        1,
      );
    });

    test('NO ACTION: deleting the parent with dependents throws', () {
      provider.execute('''
        CREATE TABLE authors (
          id   INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL
        )
      ''');
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL
            ${fkClause(ColumnMeta(
        sqlName: 'author_id',
        dartField: 'authorId',
        dartType: int,
        isForeignKey: true,
        foreignTable: 'authors',
        foreignColumn: 'id',
        onDelete: OnDeleteAction.noAction,
      ))},
          title     TEXT NOT NULL
        )
      ''');

      provider.execute('INSERT INTO authors (name) VALUES (?)', ['Le Guin']);
      provider.execute(
        'INSERT INTO books (author_id, title) VALUES (?, ?)',
        <Object?>[1, 'Earthsea'],
      );

      // Delete the author → NO ACTION → SQLite throws
      // (the default SQLite behaviour is the same as
      // RESTRICT for non-deferred constraints, except
      // the error message differs).
      expect(
        () => provider.execute('DELETE FROM authors WHERE id = ?', [1]),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('default onDelete in ColumnMeta() is noAction', () {
      final meta = ColumnMeta(
        sqlName: 'author_id',
        dartField: 'authorId',
        dartType: int,
        isForeignKey: true,
        foreignTable: 'authors',
        foreignColumn: 'id',
      );
      expect(meta.onDelete, OnDeleteAction.noAction);
      expect(fkClause(meta), 'REFERENCES "authors"("id")');
    });
  });
}
