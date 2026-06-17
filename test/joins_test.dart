// Tests for `DbSet<T>.findById(id, joins: [...])` .
//
// `joins` is the declarative, JOIN-based eager
// loading API. Each [IncludeRelation] tells the runtime
// to emit a single `LEFT JOIN` for the navigation
// property; the result is materialised into `T` with the
// navigation properties populated.
//
// Test coverage:
// 1. `joins: [IncludeOne]` populates @BelongsTo (book →
// author) in one SQL statement.
// 2. `joins: [IncludeMany]` populates @HasMany (book →
// sales) in one SQL statement.
// 3. `joins: [IncludeOne, IncludeMany]` composes
// both relations in a single SQL.
// 4. `joins: [IncludeOne]` with a missing FK (no
// matching author) populates `null` (LEFT JOIN).
// 5. `joins: [IncludeMany]` with no matching rows
// populates an empty list.
// 6. `findById` returns `null` for a missing row
// (and skips the `joins` work entirely).
// 7. `joins` + `include` callbacks compose: the
// `joins` materialise first, then the `include`
// callbacks can post-process.

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group('Fase 4.4 — DbSet<T>.findById(id, joins: …) — JOIN-based', () {
    test('joins: [IncludeOne] populates @BelongsTo in one SQL', () {
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
          title     TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      ctx.authors.add(Author(id: 0, name: 'Le Guin'));
      ctx.saveChanges();
      ctx.books.add(Book(id: 0, title: 'Earthsea', authorId: 1));
      ctx.saveChanges();

      // The `joins: [...]` materialises `book.author` via
      // a single LEFT JOIN.
      final Book? book = ctx.books.findById(1, joins: [
        IncludeOne<Book, Author>(
          navigationName: 'author',
          relatedMeta: _authorMeta(),
          fkColumnOnT: 'author_id',
        ),
      ]);

      expect(book, isNotNull);
      final Book b1 = book!;
      expect(b1.title, 'Earthsea');
      expect(b1.joinResults, isNotNull);
      expect(b1.joinResults['author'], isNotNull);
      final Author? author = b1.joinResults['author'] as Author?;
      expect(author, isNotNull);
      expect(author!.id, 1);
      expect(author.name, 'Le Guin');

      provider.dispose();
    });

    test('joins: [IncludeMany] populates @HasMany in one SQL', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL DEFAULT 0,
          title     TEXT NOT NULL
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
      ctx.sales.add(Sale(id: 0, bookId: 1, customer: 'Carol'));
      ctx.saveChanges();

      final Book? book = ctx.books.findById(1, joins: [
        IncludeMany<Book, Sale>(
          navigationName: 'sales',
          relatedMeta: _saleMeta(),
          inverseFkColumn: 'book_id',
        ),
      ]);

      expect(book, isNotNull);
      final Book b1 = book!;
      expect(b1.joinResults['sales'], isNotNull);
      final List<Object?> sales = b1.joinResults['sales']! as List<Object?>;
      expect(sales, hasLength(3));
      expect(
        sales.map((Object? s) => (s! as Sale).customer).toSet(),
        <Object?>{'Alice', 'Bob', 'Carol'},
      );

      provider.dispose();
    });

    test('joins: [IncludeOne, IncludeMany] composes both relations', () {
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
          title     TEXT NOT NULL
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
      ctx.saveChanges();

      final Book? book = ctx.books.findById(1, joins: [
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

      expect(book, isNotNull);
      final Book b1 = book!;
      // @BelongsTo
      final Author? author = b1.joinResults['author'] as Author?;
      expect(author, isNotNull);
      expect(author!.name, 'Le Guin');
      // @HasMany
      final List<Object?> sales = b1.joinResults['sales']! as List<Object?>;
      expect(sales, hasLength(2));

      provider.dispose();
    });

    test('joins: [IncludeOne] with missing FK populates null', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id   INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL
        )
      ''');
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL DEFAULT 0,
          title     TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      // No author with id=999 → LEFT JOIN returns NULL
      // for the author columns.
      ctx.books.add(Book(id: 0, title: 'Orphan', authorId: 999));
      ctx.saveChanges();

      final Book? book = ctx.books.findById(1, joins: [
        IncludeOne<Book, Author>(
          navigationName: 'author',
          relatedMeta: _authorMeta(),
          fkColumnOnT: 'author_id',
        ),
      ]);

      expect(book, isNotNull);
      // `book.joinResults['author']` should be `null`
      // (the LEFT JOIN returned no row).
      final Object? authorResult = book!.joinResults['author'];
      expect(authorResult, isNull);

      provider.dispose();
    });

    test('joins: [IncludeMany] with no matching rows populates empty list', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL DEFAULT 0,
          title     TEXT NOT NULL
        )
      ''');
      provider.execute('''
        CREATE TABLE sales (
          id       INTEGER PRIMARY KEY AUTOINCREMENT,
          book_id  INTEGER NOT NULL DEFAULT 0,
          customer TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      ctx.books.add(Book(id: 0, title: 'NoSales', authorId: 0));
      ctx.saveChanges();
      // No sales for this book.

      final Book? book = ctx.books.findById(1, joins: [
        IncludeMany<Book, Sale>(
          navigationName: 'sales',
          relatedMeta: _saleMeta(),
          inverseFkColumn: 'book_id',
        ),
      ]);

      expect(book, isNotNull);
      final List<Object?> sales = book!.joinResults['sales']! as List<Object?>;
      expect(sales, isEmpty);

      provider.dispose();
    });

    test('findById returns null for a missing row (skips joins work)', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL DEFAULT 0,
          title     TEXT NOT NULL
        )
      ''');
      provider.execute('''
        CREATE TABLE sales (
          id       INTEGER PRIMARY KEY AUTOINCREMENT,
          book_id  INTEGER NOT NULL DEFAULT 0,
          customer TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      final Book? book = ctx.books.findById(999, joins: [
        IncludeMany<Book, Sale>(
          navigationName: 'sales',
          relatedMeta: _saleMeta(),
          inverseFkColumn: 'book_id',
        ),
      ]);
      expect(book, isNull);

      provider.dispose();
    });

    test('joins + include callbacks compose: joins first, then callbacks', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL DEFAULT 0,
          title     TEXT NOT NULL
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
      ctx.saveChanges();

      // Use `joins` to populate the sales list, then
      // `include` to mutate the title.
      final Book? book = ctx.books.findById(
        1,
        include: [
          (Book b) => b.title = '${b.title} (annotated)',
        ],
        joins: [
          IncludeMany<Book, Sale>(
            navigationName: 'sales',
            relatedMeta: _saleMeta(),
            inverseFkColumn: 'book_id',
          ),
        ],
      );

      expect(book, isNotNull);
      final Book b1 = book!;
      expect(b1.title, 'Earthsea (annotated)',
          reason: 'include callback ran after the JOIN');
      final List<Object?> sales = b1.joinResults['sales']! as List<Object?>;
      expect(sales, hasLength(1));

      provider.dispose();
    });
  });
}

// ─── Test fixtures ──────────────────────────────────────────────────

class Book implements RecordLike {
  Book({this.id = 0, this.title = '', this.authorId = 0});
  int id;
  String title;
  int authorId;

  /// side-channel: the `joins:` materialised
  /// navigation properties are attached here. The
  /// `joinResults` map is keyed by
  /// `IncludeRelation.navigationName`. Values are
  /// typed (`R` for `IncludeOne`, `List<R>` for
  /// `IncludeMany`).
  Map<String, Object?> joinResults = <String, Object?>{};

  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'id' => id,
        'title' => title,
        'authorId' => authorId,
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
          sqlName: 'title',
          dartField: 'title',
          dartType: String,
        ),
        ColumnMeta(
          sqlName: 'author_id',
          dartField: 'authorId',
          dartType: int,
          isForeignKey: true,
          foreignTable: 'authors',
          foreignColumn: 'id',
        ),
      ],
      insertableColumns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'title',
          dartField: 'title',
          dartType: String,
        ),
        ColumnMeta(
          sqlName: 'author_id',
          dartField: 'authorId',
          dartType: int,
          isForeignKey: true,
          foreignTable: 'authors',
          foreignColumn: 'id',
        ),
      ],
      updatableColumns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'title',
          dartField: 'title',
          dartType: String,
        ),
        ColumnMeta(
          sqlName: 'author_id',
          dartField: 'authorId',
          dartType: int,
          isForeignKey: true,
          foreignTable: 'authors',
          foreignColumn: 'id',
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
    );
  }
}
