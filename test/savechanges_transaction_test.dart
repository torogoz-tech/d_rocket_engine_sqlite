// End-to-end tests for the transactional
// `DbContext.saveChanges` path. Verifies:
//
// 1. (Non-transactional path) After, each
// entity in a multi-insert batch is back-propagated
// with the PK produced by its own INSERT
// ( was buggy: it read the `lastInsertRowId`
// AFTER the entire inserts loop, so every entity
// ended up with the last PK).
// 2. (Transactional path) When
// `createSaveChangesTransaction` is set, the entire
// saveChanges batch is wrapped in a single
// BEGIN / COMMIT.
// 3. (Transactional failure path) A mid-batch exception
// rolls the whole batch back: the rows are NOT visible
// after `saveChanges` throws, and the change tracker
// entries remain in their original states.

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
// Row type replaced with Map<String, Object?> in
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group('Fase 3.8 — DbContext.saveChanges()', () {
    test(
        'Fase 3.8 fix: each entity in a multi-insert batch is '
        'back-propagated with the PK of its own INSERT '
        '(non-transactional path)', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL
        )
      ''');

      final _NoTxDbContext ctx = _NoTxDbContext(provider);

      final Book a = Book(id: 0, title: 'A');
      final Book b = Book(id: 0, title: 'B');
      final Book c = Book(id: 0, title: 'C');
      ctx.books.add(a);
      ctx.books.add(b);
      ctx.books.add(c);
      expect(ctx.saveChanges(), 3);

      // Each entity in the batch has a unique PK.
      expect(a.id, 1, reason: 'A was inserted first → id 1');
      expect(b.id, 2, reason: 'B was inserted second → id 2');
      expect(c.id, 3, reason: 'C was inserted third → id 3');

      // The DB has 3 rows.
      final List<Map<String, Object?>> rows =
          provider.select('SELECT id, title FROM books ORDER BY id');
      expect(rows, hasLength(3));
      expect(rows.map((Map<String, Object?> r) => r['title']).toList(),
          <Object?>['A', 'B', 'C']);

      provider.dispose();
    });

    test(
        'transactional path: the entire batch runs inside a single '
        'BEGIN / COMMIT', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL
        )
      ''');

      final List<String> executed = <String>[];
      final _TxDbContext ctx = _TxDbContext(provider, executed: executed);

      // Stage a mixed batch: 1 update + 1 delete.
      final Book a = Book(id: 0, title: 'A');
      final Book b = Book(id: 0, title: 'B');
      ctx.books.add(a);
      ctx.books.add(b);
      ctx.saveChanges();
      a.title = 'A (revised)';
      ctx.books.markModified(a);
      ctx.saveChanges(); // 1 update, transactional.
      ctx.books.markDeleted(b);
      executed.clear();

      // The 3rd saveChanges is 1 update + 1 delete inside
      // a single BEGIN / COMMIT.
      ctx.books.markModified(a); // re-mark to update
      expect(ctx.saveChanges(), 2, reason: '1 update + 1 delete');

      expect(executed[0], 'BEGIN');
      expect(executed.last, 'COMMIT');
      expect(executed.where((String s) => s == 'BEGIN'), hasLength(1));
      expect(executed.where((String s) => s == 'COMMIT'), hasLength(1));
      expect(executed.where((String s) => s == 'ROLLBACK'), isEmpty);

      provider.dispose();
    });

    test(
        'transactional failure path: a mid-batch exception rolls the '
        'whole batch back; tracker entries stay in Added state', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL
        )
      ''');

      final List<String> executed = <String>[];
      final _TxDbContext ctx = _TxDbContext(provider, executed: executed);

      ctx.books.add(Book(id: 0, title: 'A'));
      ctx.books.add(Book(id: 0, title: 'B'));
      ctx.books.add(Book(id: 0, title: 'C'));

      ctx.failAfter(1);
      expect(() => ctx.saveChanges(), throwsStateError);

      expect(executed.first, 'BEGIN');
      expect(executed.last, 'ROLLBACK');
      expect(executed.where((String s) => s == 'COMMIT'), isEmpty);

      final List<Map<String, Object?>> rows =
          provider.select('SELECT title FROM books');
      expect(rows, isEmpty,
          reason: 'Rollback: the in-flight inserts are not visible');

      expect(ctx.changeTracker.entries.length, 3);
      for (final TrackedEntry entry in ctx.changeTracker.entries) {
        expect(entry.state, EntityState.added,
            reason: 'After rollback, entries stay in Added state');
      }

      provider.dispose();
    });
  });
}

// ─── Test fixtures ──────────────────────────────────────────────────

class Book implements RecordLike {
  Book({required this.id, required this.title});
  int id;
  String title;
  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'id' => id,
        'title' => title,
        _ => null,
      };
  @override
  String toString() => 'Book(id: $id, title: $title)';
}

EntityMeta _bookMeta() => EntityMeta(
      tableName: 'books',
      columns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'id',
          dartField: 'id',
          dartType: int,
          isPrimaryKey: true,
          isAutoIncrement: true,
        ),
        ColumnMeta(
          sqlName: 'title',
          dartField: 'title',
          dartType: String,
        ),
      ],
      insertableColumns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'title',
          dartField: 'title',
          dartType: String,
        ),
      ],
      updatableColumns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'title',
          dartField: 'title',
          dartType: String,
        ),
      ],
      primaryKey: ColumnMeta(
        sqlName: 'id',
        dartField: 'id',
        dartType: int,
        isPrimaryKey: true,
        isAutoIncrement: true,
      ),
      primaryKeyIndex: 0,
      pkOf: (Object e) => (e as Book).id,
      fromRow: (Map<String, Object?> r) =>
          Book(id: r['id']! as int, title: r['title']! as String),
      setId: (Object e, Object newId) => (e as Book).id = newId as int,
    );

/// Non-transactional context. Exercises the bug-fix path
/// in `_saveChangesUnwrapped` (each insert captures the
/// PK right after it ran).
class _NoTxDbContext extends DbContext {
  _NoTxDbContext(this._provider);
  final SqliteQueryProvider _provider;

  late final DbSet<Book> books = dbSet<Book>(_bookMeta);

  @override
  DbSet<T> createDbSet<T>(EntityMeta Function() m) {
    return DbSet<T>(
      metaAccessor: m,
      tracker: changeTracker,
      execute: (String sql, List<Object?> binds) {
        if (binds.isEmpty) {
          _provider.execute(sql);
        } else {
          _provider.execute(sql, binds);
        }
        return 1;
      },
      select: (String sql, List<Object?> binds) {
        if (binds.isEmpty) return _provider.select(sql);
        return _provider.selectWithBinds(sql, binds);
      },
      lastInsertRowId: () => _provider.database.lastInsertRowId,
    );
  }
}

/// Transactional context. The whole `saveChanges` batch
/// is wrapped in a `BEGIN; ... COMMIT;` (or `ROLLBACK;`
/// on failure). Optionally fails mid-batch for the
/// rollback test.
class _TxDbContext extends DbContext {
  _TxDbContext(this._provider, {required this.executed});
  final SqliteQueryProvider _provider;
  final List<String> executed;
  int _failAfter = -1;

  void failAfter(int n) {
    _failAfter = n;
  }

  @override
  MigrationTransactionFactory? get createSaveChangesTransaction => () {
        executed.add('BEGIN');
        _provider.execute('BEGIN');
        int counter = 0;
        return MigrationTransaction(
          executor: (String sql, [List<Object?>? binds]) {
            counter++;
            executed.add(sql);
            if (_failAfter >= 0 && counter > _failAfter) {
              throw StateError('Injected failure mid-batch');
            }
            if (binds == null) {
              _provider.execute(sql);
            } else {
              _provider.execute(sql, binds);
            }
          },
          commit: () {
            executed.add('COMMIT');
            _provider.execute('COMMIT');
          },
          rollback: () {
            executed.add('ROLLBACK');
            _provider.execute('ROLLBACK');
          },
        );
      };

  late final DbSet<Book> books = dbSet<Book>(_bookMeta);

  @override
  DbSet<T> createDbSet<T>(EntityMeta Function() m) {
    return DbSet<T>(
      metaAccessor: m,
      tracker: changeTracker,
      execute: (String sql, List<Object?> binds) {
        if (binds.isEmpty) {
          _provider.execute(sql);
        } else {
          _provider.execute(sql, binds);
        }
        return 1;
      },
      select: (String sql, List<Object?> binds) {
        if (binds.isEmpty) return _provider.select(sql);
        return _provider.selectWithBinds(sql, binds);
      },
      lastInsertRowId: () => _provider.database.lastInsertRowId,
    );
  }
}
