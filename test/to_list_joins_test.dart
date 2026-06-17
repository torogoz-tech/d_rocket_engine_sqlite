// Tests for `Queryable<T>.toListWithJoins([...])` .
//
// `toListWithJoins` is the batch variant of
// `DbSet.findById(id, joins:)` . It applies the
// chained `where_` / `orderBy_` / `take_` / `skip_` and
// emits a SINGLE `LEFT JOIN` SQL, then materialises the
// result into a list of `T` with each entity's
// `joinResults` field populated.
//
// Test coverage:
// 1. `toListWithJoins` returns a list of `T` with the
// `joinResults` field populated.
// 2. `toListWithJoins` dedupes by PK: a book with 3
// sales appears once in the result.
// 3. `toListWithJoins` composes with `where_` to filter
// the main table (the JOIN doesn't change the
// filtered set).
// 4. `toListWithJoins` composes with `orderBy_` to
// order the result (the JOIN doesn't change the
// order).
// 5. `toListWithJoins` returns `` for an empty
// result.
// 6. `toListWithJoins` with only `IncludeMany`
// relations (no @BelongsTo).
// 7. `toListWithJoins` with only `IncludeOne`
// relations (no @HasMany).

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group(
      'Fase 4.5 — Queryable<T>.toListWithJoins([...]) '
      '— JOIN-based batch loading', () {
    test('toListWithJoins populates @BelongsTo + @HasMany per book', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL
        )
      ''');
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL REFERENCES authors(id),
          title     TEXT NOT NULL,
          year      INTEGER NOT NULL DEFAULT 0
        )
      ''');
      provider.execute('''
        CREATE TABLE sales (
          id       INTEGER PRIMARY KEY AUTOINCREMENT,
          book_id  INTEGER NOT NULL REFERENCES books(id),
          customer TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      ctx.authors.add(Author(id: 0, name: 'Le Guin'));
      ctx.saveChanges();
      ctx.books.add(Book(id: 0, title: 'Earthsea', authorId: 1));
      ctx.saveChanges();
      ctx.sales.add(Sale(id: 0, bookId: 1, customer: 'Alice'));
      ctx.sales.add(Sale(id: 0, bookId: 1, customer: 'Bob'));
      ctx.sales.add(Sale(id: 0, bookId: 1, customer: 'Carol'));
      ctx.saveChanges();

      final List<Book> books = ctx.books.asQueryable().toListWithJoins([
        IncludeOne<Book, Author>(
          navigationName: 'author',
          relatedMeta: _authorMeta(),
          fkColumnOnT: 'author_id',
        ),
        IncludeMany<Book, Sale>(
          navigationName: 'sales',
          relatedMeta: _saleMeta(),
          inverseFkColumn: 'book_id',
        ),
      ]);

      expect(books, hasLength(1));
      final Book b1 = books.first;
      final Author? author = b1.joinResults['author'] as Author?;
      expect(author, isNotNull);
      expect(author!.name, 'Le Guin');
      final List<Object?> sales = b1.joinResults['sales']! as List<Object?>;
      expect(sales, hasLength(3));
      expect(
        sales.map((Object? s) => (s! as Sale).customer).toSet(),
        <Object?>{'Alice', 'Bob', 'Carol'},
      );

      provider.dispose();
    });

    test('toListWithJoins dedupes by PK (3 sales → 1 book)', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL
        )
      ''');
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL DEFAULT 0,
          title     TEXT NOT NULL,
          year      INTEGER NOT NULL DEFAULT 0
        )
      ''');
      provider.execute('''
        CREATE TABLE sales (
          id       INTEGER PRIMARY KEY AUTOINCREMENT,
          book_id  INTEGER NOT NULL REFERENCES books(id),
          customer TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      ctx.books.add(Book(id: 0, title: 'Earthsea', authorId: 1));
      ctx.saveChanges();
      ctx.sales.add(Sale(id: 0, bookId: 1, customer: 'Alice'));
      ctx.sales.add(Sale(id: 0, bookId: 1, customer: 'Bob'));
      ctx.sales.add(Sale(id: 0, bookId: 1, customer: 'Carol'));
      ctx.saveChanges();

      final List<Book> books = ctx.books.asQueryable().toListWithJoins([
        IncludeOne<Book, Author>(
          navigationName: 'author',
          relatedMeta: _authorMeta(),
          fkColumnOnT: 'author_id',
        ),
        IncludeMany<Book, Sale>(
          navigationName: 'sales',
          relatedMeta: _saleMeta(),
          inverseFkColumn: 'book_id',
        ),
      ]);

      // 3 sales for 1 book → book appears ONCE.
      expect(books, hasLength(1));
      final List<Object?> sales =
          books.first.joinResults['sales']! as List<Object?>;
      expect(sales, hasLength(3));

      provider.dispose();
    });

    test('toListWithJoins composes with where_ (filter on the main table)', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL DEFAULT 0,
          title     TEXT NOT NULL,
          year      INTEGER NOT NULL DEFAULT 0
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      ctx.books.add(Book(id: 0, title: 'Old', authorId: 0, year: 1950));
      ctx.books.add(Book(id: 0, title: 'Recent A', authorId: 0, year: 2000));
      ctx.books.add(Book(id: 0, title: 'Recent B', authorId: 0, year: 2010));
      ctx.saveChanges();

      // Filter to `year > 1970` (2 books).
      final List<Book> books = ctx.books
          .asQueryable()
          .where_(Expr.lambda(
            <Expr>[Expr.param('u')],
            Expr.binary(
                '>', Expr.member(Expr.param('u'), 'year'), Expr.const_(1970)),
          ))
          .toListWithJoins([]);

      expect(books, hasLength(2));
      expect(
        books.map((Book b) => b.title).toSet(),
        <Object?>{'Recent A', 'Recent B'},
      );

      provider.dispose();
    });

    test('toListWithJoins composes with orderBy_ (order on the main table)',
        () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL DEFAULT 0,
          title     TEXT NOT NULL,
          year      INTEGER NOT NULL DEFAULT 0
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      ctx.books.add(Book(id: 0, title: 'A', authorId: 0, year: 1950));
      ctx.books.add(Book(id: 0, title: 'B', authorId: 0, year: 2000));
      ctx.books.add(Book(id: 0, title: 'C', authorId: 0, year: 1980));
      ctx.saveChanges();

      // Order by `year` DESC.
      final List<Book> books = ctx.books
          .asQueryable()
          .orderByDescending_(
            Expr.lambda(
              <Expr>[Expr.param('u')],
              Expr.member(Expr.param('u'), 'year'),
            ),
          )
          .toListWithJoins([]);

      expect(books.map((Book b) => b.title).toList(), <Object?>['B', 'C', 'A']);

      provider.dispose();
    });

    test('toListWithJoins returns [] for an empty result', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL DEFAULT 0,
          title     TEXT NOT NULL,
          year      INTEGER NOT NULL DEFAULT 0
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      final List<Book> books = ctx.books.asQueryable().toListWithJoins([]);

      expect(books, isEmpty);

      provider.dispose();
    });

    test('toListWithJoins with only IncludeMany (no IncludeOne)', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL DEFAULT 0,
          title     TEXT NOT NULL,
          year      INTEGER NOT NULL DEFAULT 0
        )
      ''');
      provider.execute('''
        CREATE TABLE sales (
          id       INTEGER PRIMARY KEY AUTOINCREMENT,
          book_id  INTEGER NOT NULL REFERENCES books(id),
          customer TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      ctx.books.add(Book(id: 0, title: 'Earthsea', authorId: 0));
      ctx.saveChanges();
      ctx.sales.add(Sale(id: 0, bookId: 1, customer: 'Alice'));
      ctx.sales.add(Sale(id: 0, bookId: 1, customer: 'Bob'));
      ctx.saveChanges();

      final List<Book> books = ctx.books.asQueryable().toListWithJoins([
        IncludeMany<Book, Sale>(
          navigationName: 'sales',
          relatedMeta: _saleMeta(),
          inverseFkColumn: 'book_id',
        ),
      ]);

      expect(books, hasLength(1));
      final List<Object?> sales =
          books.first.joinResults['sales']! as List<Object?>;
      expect(sales, hasLength(2));

      provider.dispose();
    });

    test('toListWithJoins with only IncludeOne (no IncludeMany)', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL
        )
      ''');
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL REFERENCES authors(id),
          title     TEXT NOT NULL,
          year      INTEGER NOT NULL DEFAULT 0
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      ctx.authors.add(Author(id: 0, name: 'Le Guin'));
      ctx.authors.add(Author(id: 0, name: 'Asimov'));
      ctx.saveChanges();
      ctx.books.add(Book(id: 0, title: 'Earthsea', authorId: 1));
      ctx.books.add(Book(id: 0, title: 'Foundation', authorId: 2));
      ctx.saveChanges();

      final List<Book> books = ctx.books
          .asQueryable()
          .orderBy_(
            Expr.lambda(
              <Expr>[Expr.param('u')],
              Expr.member(Expr.param('u'), 'title'),
            ),
          )
          .toListWithJoins([
        IncludeOne<Book, Author>(
          navigationName: 'author',
          relatedMeta: _authorMeta(),
          fkColumnOnT: 'author_id',
        ),
      ]);

      expect(books, hasLength(2));
      expect(
        (books[0].joinResults['author']! as Author).name,
        'Le Guin',
        reason: 'Earthsea (alphabetically first) belongs to Le Guin',
      );
      expect(
        (books[1].joinResults['author']! as Author).name,
        'Asimov',
        reason: 'Foundation belongs to Asimov',
      );

      provider.dispose();
    });
  });
}

// ─── Test fixtures ──────────────────────────────────────────────────

class Book implements RecordLike {
  Book({
    this.id = 0,
    this.title = '',
    this.authorId = 0,
    this.year = 0,
  });
  int id;
  String title;
  int authorId;
  int year;

  /// / 4.5 side-channel for the JOIN results.
  Map<String, Object?> joinResults = <String, Object?>{};

  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'id' => id,
        'title' => title,
        'authorId' => authorId,
        'year' => year,
        _ => null,
      };
  @override
  String toString() => 'Book(id: $id, title: $title)';
}

class Author implements RecordLike {
  Author({this.id = 0, this.name = ''});
  int id;
  String name;
  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'id' => id,
        'name' => name,
        _ => null,
      };
  @override
  String toString() => 'Author(id: $id, name: $name)';
}

class Sale implements RecordLike {
  Sale({this.id = 0, this.bookId = 0, this.customer = ''});
  int id;
  int bookId;
  String customer;
  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'id' => id,
        'bookId' => bookId,
        'customer' => customer,
        _ => null,
      };
  @override
  String toString() => 'Sale(id: $id, customer: $customer)';
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
          sqlName: 'author_id',
          dartField: 'authorId',
          dartType: int,
          isForeignKey: true,
          foreignTable: 'authors',
          foreignColumn: 'id',
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
          sqlName: 'author_id',
          dartField: 'authorId',
          dartType: int,
          isForeignKey: true,
          foreignTable: 'authors',
          foreignColumn: 'id',
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
      updatableColumns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'author_id',
          dartField: 'authorId',
          dartType: int,
          isForeignKey: true,
          foreignTable: 'authors',
          foreignColumn: 'id',
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
        authorId: (r['author_id'] as int?) ?? 0,
        year: (r['year'] as int?) ?? 0,
      ),
      setId: (Object e, Object newId) => (e as Book).id = newId as int,
    );

EntityMeta _authorMeta() => EntityMeta(
      tableName: 'authors',
      columns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'id',
          dartField: 'id',
          dartType: int,
          isPrimaryKey: true,
          isAutoIncrement: true,
        ),
        ColumnMeta(
          sqlName: 'name',
          dartField: 'name',
          dartType: String,
        ),
      ],
      insertableColumns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'name',
          dartField: 'name',
          dartType: String,
        ),
      ],
      updatableColumns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'name',
          dartField: 'name',
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
      pkOf: (Object e) => (e as Author).id,
      fromRow: (Map<String, Object?> r) => Author(
        id: r['id']! as int,
        name: r['name']! as String,
      ),
      setId: (Object e, Object newId) => (e as Author).id = newId as int,
    );

EntityMeta _saleMeta() => EntityMeta(
      tableName: 'sales',
      columns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'id',
          dartField: 'id',
          dartType: int,
          isPrimaryKey: true,
          isAutoIncrement: true,
        ),
        ColumnMeta(
          sqlName: 'book_id',
          dartField: 'bookId',
          dartType: int,
          isForeignKey: true,
          foreignTable: 'books',
          foreignColumn: 'id',
        ),
        ColumnMeta(
          sqlName: 'customer',
          dartField: 'customer',
          dartType: String,
        ),
      ],
      insertableColumns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'book_id',
          dartField: 'bookId',
          dartType: int,
          isForeignKey: true,
          foreignTable: 'books',
          foreignColumn: 'id',
        ),
        ColumnMeta(
          sqlName: 'customer',
          dartField: 'customer',
          dartType: String,
        ),
      ],
      updatableColumns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'book_id',
          dartField: 'bookId',
          dartType: int,
          isForeignKey: true,
          foreignTable: 'books',
          foreignColumn: 'id',
        ),
        ColumnMeta(
          sqlName: 'customer',
          dartField: 'customer',
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
      pkOf: (Object e) => (e as Sale).id,
      fromRow: (Map<String, Object?> r) => Sale(
        id: r['id']! as int,
        bookId: r['book_id']! as int,
        customer: r['customer']! as String,
      ),
      setId: (Object e, Object newId) => (e as Sale).id = newId as int,
    );

class _TestDbContext extends DbContext {
  _TestDbContext(this._provider);
  final SqliteQueryProvider _provider;

  late final DbSet<Author> authors = dbSet<Author>(_authorMeta);
  late final DbSet<Book> books = dbSet<Book>(_bookMeta);
  late final DbSet<Sale> sales = dbSet<Sale>(_saleMeta);

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
