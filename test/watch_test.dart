// End-to-end tests for `Queryable.watch` .
//
// `watch` returns a `Stream<List<T>>` that emits the
// initial snapshot, then re-runs the query on every
// `ChangeTracker` event. The user subscribes once at
// startup and rebuilds their UI / triggers a re-fetch on
// every emit.
//
// Test coverage:
// 1. `watch` emits the initial snapshot synchronously.
// 2. `watch` re-emits when `saveChanges` runs.
// 3. `watch` composes with `where_` / `orderBy_` /
// `take_` (SQL-side filtering).
// 4. `watch` returns the same `Stream` shape for an
// empty table (emits an empty list, then the
// post-insert emit).
// 5. `watch` on a queryable without a `ChangeTracker`
// throws `StateError`.

import 'dart:async';

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
// Row type replaced with Map<String, Object?> in
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group('Fase 4.2 — Queryable.watch() reactive queries', () {
    test('watch() emits the initial snapshot synchronously', () async {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          year  INTEGER NOT NULL DEFAULT 0
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      // Insert 2 books.
      ctx.books.add(Book(id: 0, title: 'A', year: 1970));
      ctx.books.add(Book(id: 0, title: 'B', year: 1980));
      ctx.saveChanges();

      // Subscribe to watch. The first emit must be the
      // initial snapshot (2 books).
      final List<List<Book>> emissions = <List<Book>>[];
      final StreamSubscription<List<Book>> sub =
          ctx.books.asQueryable().watch().listen(emissions.add);
      // Wait one microtask so the controller emits the
      // initial snapshot.
      await Future<void>.delayed(Duration.zero);
      expect(emissions, hasLength(1));
      expect(emissions.first, hasLength(2));
      expect(
        emissions.first.map((Book b) => b.title).toList(),
        <Object?>['A', 'B'],
      );
      await sub.cancel();
      provider.dispose();
    });

    test('watch() re-emits when saveChanges() inserts more rows', () async {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          year  INTEGER NOT NULL DEFAULT 0
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      ctx.books.add(Book(id: 0, title: 'A', year: 1970));
      ctx.saveChanges();

      final List<List<Book>> emissions = <List<Book>>[];
      final StreamSubscription<List<Book>> sub =
          ctx.books.asQueryable().watch().listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(emissions, hasLength(1));
      expect(emissions.first, hasLength(1));

      // Insert another book and save. The stream must
      // re-emit.
      ctx.books.add(Book(id: 0, title: 'B', year: 1980));
      ctx.saveChanges();
      await Future<void>.delayed(Duration.zero);

      expect(emissions, hasLength(2));
      expect(emissions.last, hasLength(2));
      expect(emissions.last.map((Book b) => b.title).toList(),
          <Object?>['A', 'B']);

      await sub.cancel();
      provider.dispose();
    });

    test('watch() composes with where_ + orderBy_ (SQL-side)', () async {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          year  INTEGER NOT NULL DEFAULT 0
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      ctx.books.add(Book(id: 0, title: 'Old', year: 1950));
      ctx.books.add(Book(id: 0, title: 'Modern A', year: 1980));
      ctx.books.add(Book(id: 0, title: 'Modern B', year: 1990));
      ctx.saveChanges();

      // Watch only `year > 1970` ordered by `year DESC`.
      // `where_` / `orderBy_` propagate the
      // `_changeTracker` automatically, so
      // the cast is no longer necessary.
      final Queryable<Book> modern = ctx.books
          .asQueryable()
          .where_(Expr.lambda(
            <Expr>[Expr.param('u')],
            Expr.binary(
                '>', Expr.member(Expr.param('u'), 'year'), Expr.const_(1970)),
          ))
          .orderByDescending_(
            Expr.lambda(
              <Expr>[Expr.param('u')],
              Expr.member(Expr.param('u'), 'year'),
            ),
          );

      final List<List<Book>> emissions = <List<Book>>[];
      final StreamSubscription<List<Book>> sub =
          modern.watch().listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(emissions, hasLength(1));
      expect(emissions.first.map((Book b) => b.title).toList(),
          <Object?>['Modern B', 'Modern A']);

      // Insert a 3rd modern book. The stream must
      // re-emit with the new ordered list.
      ctx.books.add(Book(id: 0, title: 'Newer', year: 2000));
      ctx.saveChanges();
      await Future<void>.delayed(Duration.zero);
      expect(emissions, hasLength(2));
      expect(emissions.last.map((Book b) => b.title).toList(),
          <Object?>['Newer', 'Modern B', 'Modern A']);

      await sub.cancel();
      provider.dispose();
    });

    test('watch() on an empty table emits an empty list', () async {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          year  INTEGER NOT NULL DEFAULT 0
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      final List<List<Book>> emissions = <List<Book>>[];
      final StreamSubscription<List<Book>> sub =
          ctx.books.asQueryable().watch().listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(emissions, hasLength(1));
      expect(emissions.first, isEmpty);
      await sub.cancel();
      provider.dispose();
    });

    test('watch() throws when the queryable has no ChangeTracker', () {
      // A queryable built directly (not via
      // `DbSet.asQueryable`) has no ChangeTracker
      // and `watch` must throw.
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      final Queryable<Book> queryable = Queryable<Book>(
        provider: provider,
        table: 'books',
        meta: EntityMeta(
          tableName: 'books',
          columns: const <ColumnMeta>[],
          insertableColumns: const <ColumnMeta>[],
          updatableColumns: const <ColumnMeta>[],
          primaryKey: const ColumnMeta(
            sqlName: 'id',
            dartField: 'id',
            dartType: int,
          ),
          primaryKeyIndex: 0,
          pkOf: (Object e) => null,
        ),
        reader: (Map<String, Object?> row) => Book(
          id: row['id']! as int,
          title: row['title']! as String,
        ),
      );
      expect(() => queryable.watch(), throwsStateError);
    });
  });
}

// ─── Test fixtures ──────────────────────────────────────────────────

class Book implements RecordLike {
  Book({required this.id, required this.title, this.year = 0});
  int id;
  final String title;
  final int year;
  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'id' => id,
        'title' => title,
        'year' => year,
        _ => null,
      };
  @override
  String toString() => 'Book(id: $id, title: $title, year: $year)';
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
        ColumnMeta(
          sqlName: 'year',
          dartField: 'year',
          dartType: int,
        ),
      ],
      insertableColumns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'title',
          dartField: 'title',
          dartType: String,
        ),
        ColumnMeta(
          sqlName: 'year',
          dartField: 'year',
          dartType: int,
        ),
      ],
      updatableColumns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'title',
          dartField: 'title',
          dartType: String,
        ),
        ColumnMeta(
          sqlName: 'year',
          dartField: 'year',
          dartType: int,
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
      fromRow: (Map<String, Object?> r) => Book(
        id: r['id']! as int,
        title: r['title']! as String,
        year: r['year']! as int,
      ),
      setId: (Object e, Object newId) => (e as Book).id = newId as int,
    );

class _TestDbContext extends DbContext {
  _TestDbContext(this._provider);
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
      select: (String sql, [List<Object?>? binds]) {
        if (binds == null || binds.isEmpty) return _provider.select(sql);
        return _provider.selectWithBinds(sql, binds);
      },
      lastInsertRowId: () => _provider.database.lastInsertRowId,
    ).attach<SqliteQueryProvider>(_provider);
  }
}
