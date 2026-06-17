//: end-to-end test that exercises the
// complete async-first d_rocket API in a single
// flow — every I/O call uses the `*Async_` methods
// (`saveChangesAsync`, `toListAsync_`, `findByIdAsync`,
// `firstByAsync`, `allByAsync`, `toListAsync_`,
// `runAsync`). This is the test mirror of the
// end-to-end demo (`lib/example/end_to_end/main.dart`).

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  late SqliteQueryProvider provider;
  late _BookstoreContext ctx;

  setUp(() {
    provider = SqliteQueryProvider.inMemory();
    provider.execute('PRAGMA foreign_keys = ON;');
    ctx = _BookstoreContext(provider);
    // Note: don't call createSchema — the migrations
    // (run in the test) create the tables.
  });

  tearDown(() async {
    await provider.disposeAsync();
  });

  test(
      'Fase 5.0+5 — full async-first flow '
      '(migration → insert → LINQ → join → cascade)', () async {
    // ─── 1. Async migration ──────────────────
    final List<MigrationBase> applied = await MigrationRunner(
      createExecutor: () => (String sql, [List<Object?>? binds]) {
        if (binds == null || binds.isEmpty) {
          provider.execute(sql);
        } else {
          provider.execute(sql, binds);
        }
      },
      createSelector: () => (String sql, [List<Object?>? binds]) {
        if (binds == null || binds.isEmpty) return provider.select(sql);
        return provider.selectWithBinds(sql, binds);
      },
      createAsyncExecutor: () => (String sql, [List<Object?>? binds]) async {
        if (binds == null || binds.isEmpty) {
          provider.execute(sql);
        } else {
          provider.execute(sql, binds);
        }
      },
      createAsyncSelector: () => (String sql, [List<Object?>? binds]) async {
        if (binds == null || binds.isEmpty) return provider.select(sql);
        return provider.selectWithBinds(sql, binds);
      },
    ).runAsync(<MigrationBase>[
      _CreateAuthorsTable(),
      _CreateBooksTable(),
    ]);
    expect(applied, hasLength(2));
    expect(applied[0].id, '001', reason: 'sorted by id');
    expect(applied[1].id, '002');

    // ─── 2. Async INSERT ────────────────────
    final alice = _Author(id: 0, name: 'Alice');
    final bob = _Author(id: 0, name: 'Bob');
    ctx.authors.add(alice);
    ctx.authors.add(bob);
    final int affected = await ctx.saveChangesAsync();
    expect(affected, 2);
    expect(alice.id, 1, reason: 'PK back-propagated');
    expect(bob.id, 2);

    // ─── 3. Async read ──────────────────────
    final List<_Author> allAuthors = await ctx.authors.toListAsync_();
    expect(allAuthors, hasLength(2));

    // ─── 4. Async typed navigation ──────────
    final dune = _Book(id: 0, title: 'Dune', authorId: alice.id);
    final foundation = _Book(id: 0, title: 'Foundation', authorId: bob.id);
    ctx.books.add(dune);
    ctx.books.add(foundation);
    await ctx.saveChangesAsync();
    expect(dune.id, 1);
    expect(foundation.id, 2);

    // Find the author of Dune via @BelongsTo (async).
    final _Author? duneAuthor = await ctx.authors.firstByAsync(
      column: 'id',
      value: dune.authorId,
    );
    expect(duneAuthor, isNotNull);
    expect(duneAuthor!.name, 'Alice');

    // Find all books by Bob via @HasMany (async).
    final List<_Book> bobBooks = await ctx.books.allByAsync(
      column: 'author_id',
      value: bob.id,
    );
    expect(bobBooks, hasLength(1));
    expect(bobBooks.first.title, 'Foundation');

    // ─── 5. Async LINQ ──────────────────────
    final q = ctx.books.asQueryable();
    final int count = await q.countAsync_();
    expect(count, 2);
    final List<_Book> list = await q.toListAsync_();
    expect(list, hasLength(2));

    // ─── 6. Async JOIN ( findByIdAsync + joins) ──
    final _Book? duneWithJoins = await ctx.books.findByIdAsync(
      dune.id,
      joins: [
        IncludeOne<_Book, _Author>(
          navigationName: 'author',
          relatedMeta: _authorMeta,
          fkColumnOnT: 'author_id',
        ),
      ],
    );
    expect(duneWithJoins, isNotNull);
    expect(duneWithJoins!.joinResults['author'], isA<_Author>());

    // ─── 7. Async cascade delete ────────────────────────
    // The books.author_id has ON DELETE CASCADE; deleting
    // the author also deletes their books.
    final int aliceBooksBefore = (await ctx.books.allByAsync(
      column: 'author_id',
      value: alice.id,
    ))
        .length;
    expect(aliceBooksBefore, 1);
    provider.execute('DELETE FROM authors WHERE id = ?', [alice.id]);
    final int aliceBooksAfter = (await ctx.books.allByAsync(
      column: 'author_id',
      value: alice.id,
    ))
        .length;
    expect(aliceBooksAfter, 0,
        reason: 'ON DELETE CASCADE removed the dependent row');

    // ─── 8. The final async read confirms the new state ──
    final List<_Book> remainingBooks = await ctx.books.toListAsync_();
    expect(remainingBooks, hasLength(1), reason: 'only the bob book remains');
    expect(remainingBooks.first.title, 'Foundation');
  });
}

// ─── Test fixtures ──────────────────────────────────────────────────

class _Author implements RecordLike {
  _Author({this.id = 0, required this.name});
  int id;
  String name;

  @override
  Object? readField(String f) => switch (f) {
        'id' => id,
        'name' => name,
        _ => null,
      };
}

class _Book implements RecordLike {
  _Book({this.id = 0, required this.title, required this.authorId});
  int id;
  String title;
  int authorId;

  final Map<String, Object?> joinResults = <String, Object?>{};

  @override
  Object? readField(String f) => switch (f) {
        'id' => id,
        'title' => title,
        //: the DbSet calls readField with
        // the dartField, not the sqlName. So the
        // switch must use 'authorId' (not 'author_id').
        'authorId' => authorId,
        _ => null,
      };
}

final ColumnMeta _idCol = ColumnMeta(
  sqlName: 'id',
  dartField: 'id',
  dartType: int,
  isPrimaryKey: true,
  isAutoIncrement: true,
);

final ColumnMeta _nameCol = ColumnMeta(
  sqlName: 'name',
  dartField: 'name',
  dartType: String,
);

final ColumnMeta _titleCol = ColumnMeta(
  sqlName: 'title',
  dartField: 'title',
  dartType: String,
);

final ColumnMeta _authorIdCol = ColumnMeta(
  sqlName: 'author_id',
  dartField: 'authorId',
  dartType: int,
);

final EntityMeta _authorMeta = EntityMeta(
  tableName: 'authors',
  columns: <ColumnMeta>[_idCol, _nameCol],
  insertableColumns: <ColumnMeta>[_nameCol],
  updatableColumns: <ColumnMeta>[_nameCol],
  primaryKey: _idCol,
  primaryKeyIndex: 0,
  pkOf: (Object e) => (e as _Author).id,
  setId: (Object e, Object id) => (e as _Author).id = id as int,
  fromRow: (Map<String, Object?> r) => _Author(
    id: r['id']! as int,
    name: r['name']! as String,
  ),
);

final EntityMeta _bookMeta = EntityMeta(
  tableName: 'books',
  columns: <ColumnMeta>[_idCol, _titleCol, _authorIdCol],
  insertableColumns: <ColumnMeta>[_titleCol, _authorIdCol],
  updatableColumns: <ColumnMeta>[_titleCol, _authorIdCol],
  primaryKey: _idCol,
  primaryKeyIndex: 0,
  pkOf: (Object e) => (e as _Book).id,
  setId: (Object e, Object id) => (e as _Book).id = id as int,
  fromRow: (Map<String, Object?> r) => _Book(
    id: r['id']! as int,
    title: r['title']! as String,
    authorId: r['author_id']! as int,
  ),
);

class _BookstoreContext extends DbContext {
  _BookstoreContext(this._provider);
  final SqliteQueryProvider _provider;

  @override
  AsyncQueryProvider? get asyncProvider => _provider;

  late final DbSet<_Author> authors = dbSet<_Author>(() => _authorMeta);
  late final DbSet<_Book> books = dbSet<_Book>(() => _bookMeta);

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

  void createSchema() {
    _provider.execute('''
      CREATE TABLE authors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
    ''');
    _provider.execute('''
      CREATE TABLE books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        author_id INTEGER NOT NULL
          REFERENCES authors(id) ON DELETE CASCADE
      )
    ''');
  }
}

class _CreateAuthorsTable extends MigrationBase {
  @override
  String get id => '001';
  @override
  String get name => 'Create authors table';
  @override
  void up(MigrationExecutor exec) {
    exec('CREATE TABLE authors ('
        '  id INTEGER PRIMARY KEY AUTOINCREMENT,'
        '  name TEXT NOT NULL)');
  }

  @override
  void down(MigrationExecutor exec) {
    exec('DROP TABLE authors');
  }
}

class _CreateBooksTable extends MigrationBase {
  @override
  String get id => '002';
  @override
  String get name => 'Create books table';
  @override
  void up(MigrationExecutor exec) {
    exec('CREATE TABLE books ('
        '  id INTEGER PRIMARY KEY AUTOINCREMENT,'
        '  title TEXT NOT NULL,'
        '  author_id INTEGER NOT NULL '
        '    REFERENCES authors(id) ON DELETE CASCADE)');
  }

  @override
  void down(MigrationExecutor exec) {
    exec('DROP TABLE books');
  }
}
