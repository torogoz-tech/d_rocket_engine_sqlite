// Tests for `DbSet<T>.findById(id, include: ...)` .
//
// `include` is the eager-load API for navigation
// properties. Each callback runs after the entity
// is materialised; the typical pattern is:
//
// ```dart
// final Book? book = ctx.books.findById(1, include: [
// (Book b) => b.author = ctx.authors.firstBy(
// column: 'id', value: b.authorId),
// (Book b) => b.sales = ctx.sales.allBy(
// column: 'book_id', value: b.id),
//]);
// ```
//
// Test coverage:
// 1. `findById` without `include` returns the entity
// with no navigation properties populated.
// 2. `findById` with `include: [cb]` runs the callback
// after materialisation.
// 3. `findById` with multiple `include` callbacks runs
// them in the order supplied.
// 4. `findById` returns `null` when the row does not
// exist (and skips the `include` callbacks).
// 5. The `include` callback receives the
// already-populated `EntityMeta.fromRow` entity
// (so its primary-key fields are valid).

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group('Fase 4.3 — DbSet<T>.findById(id, include: …)', () {
    test('findById without include returns the entity undecorated', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      ctx.books.add(Book(id: 0, title: 'Earthsea'));
      ctx.saveChanges();

      final Book? found = ctx.books.findById(1);
      expect(found, isNotNull);
      expect(found!.id, 1);
      expect(found.title, 'Earthsea');

      provider.dispose();
    });

    test('findById with include runs the callback after materialisation', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      ctx.books.add(Book(id: 0, title: 'Earthsea'));
      ctx.saveChanges();

      // `include` callback that mutates the entity.
      final Book? found = ctx.books.findById(1, include: [
        (Book b) => b.title = '${b.title} (annotated)',
      ]);
      expect(found, isNotNull);
      expect(found!.title, 'Earthsea (annotated)');

      provider.dispose();
    });

    test('findById with multiple include callbacks runs them in order', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      ctx.books.add(Book(id: 0, title: 'Earthsea'));
      ctx.saveChanges();

      // Track the order of the callbacks.
      final List<String> log = <String>[];

      final Book? found = ctx.books.findById(1, include: [
        (Book b) {
          log.add('first');
          b.title = '${b.title} / first';
        },
        (Book b) {
          log.add('second');
          b.title = '${b.title} / second';
        },
        (Book b) {
          log.add('third');
          b.title = '${b.title} / third';
        },
      ]);

      expect(found, isNotNull);
      expect(log, <String>['first', 'second', 'third']);
      expect(found!.title, 'Earthsea / first / second / third');

      provider.dispose();
    });

    test('findById returns null for a missing row (skips include)', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      bool callbackRan = false;
      final Book? found = ctx.books.findById(999, include: [
        (Book b) => callbackRan = true,
      ]);
      expect(found, isNull);
      expect(callbackRan, isFalse,
          reason: 'include must NOT run when the row is missing');

      provider.dispose();
    });

    test('findById include can populate @BelongsTo (book → author)', () {
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
      final _RelTestDbContext ctx = _RelTestDbContext(provider);

      ctx.authors.add(Author(id: 0, name: 'Le Guin'));
      ctx.saveChanges();
      ctx.books.add(Book(id: 0, authorId: 1, title: 'Earthsea'));
      ctx.saveChanges();

      // @BelongsTo: load the book + its author.
      final Book? book = ctx.books.findById(1, include: [
        (Book b) => b.author = ctx.authors.firstBy(
              column: 'id',
              value: b.authorId,
            ),
      ]);
      expect(book, isNotNull);
      expect(book!.title, 'Earthsea');
      expect(book.author, isNotNull);
      expect(book.author!.id, 1);
      expect(book.author!.name, 'Le Guin');

      provider.dispose();
    });

    test('findById include can populate @HasMany (book → sales)', () {
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
      final _RelTestDbContext ctx = _RelTestDbContext(provider);

      ctx.books.add(Book(id: 0, title: 'Earthsea', authorId: 1));
      ctx.books.add(Book(id: 0, title: 'Other', authorId: 1));
      ctx.saveChanges();
      ctx.sales.add(Sale(id: 0, bookId: 1, customer: 'Alice'));
      ctx.sales.add(Sale(id: 0, bookId: 1, customer: 'Bob'));
      // The sale below must reference a real
      // book id, because the test now runs with
      // `PRAGMA foreign_keys = ON` (1.1.1). The
      // book with id=2 was just inserted above
      // so that this sale can pass the FK check.
      ctx.sales.add(Sale(id: 0, bookId: 2, customer: 'Carol'));
      ctx.saveChanges();

      // @HasMany: load the book + its sales.
      final Book? book = ctx.books.findById(1, include: [
        (Book b) => b.sales = ctx.sales.allBy(column: 'book_id', value: b.id),
      ]);
      expect(book, isNotNull);
      expect(book!.sales, isNotNull);
      expect(book.sales, hasLength(2));
      expect(
        book.sales.map((Sale s) => s.customer).toSet(),
        <Object?>{'Alice', 'Bob'},
      );

      provider.dispose();
    });

    test('findById include composes @BelongsTo + @HasMany', () {
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
      final _RelTestDbContext ctx = _RelTestDbContext(provider);

      ctx.authors.add(Author(id: 0, name: 'Le Guin'));
      ctx.saveChanges();
      ctx.books.add(Book(id: 0, authorId: 1, title: 'Earthsea'));
      ctx.saveChanges();
      ctx.sales.add(Sale(id: 0, bookId: 1, customer: 'Alice'));
      ctx.sales.add(Sale(id: 0, bookId: 1, customer: 'Bob'));
      ctx.saveChanges();

      // Compose both relations in a single `findById`.
      final Book? book = ctx.books.findById(1, include: [
        (Book b) => b.author = ctx.authors.firstBy(
              column: 'id',
              value: b.authorId,
            ),
        (Book b) => b.sales = ctx.sales.allBy(column: 'book_id', value: b.id),
      ]);
      expect(book, isNotNull);
      expect(book!.title, 'Earthsea');
      expect(book.author!.name, 'Le Guin');
      expect(book.sales, hasLength(2));
      expect(
        book.sales.map((Sale s) => s.customer).toSet(),
        <Object?>{'Alice', 'Bob'},
      );

      provider.dispose();
    });
  });
}

// ─── Test fixtures ──────────────────────────────────────────────────

class Book implements RecordLike {
  Book({required this.id, this.title = '', this.authorId = 0});
  int id;
  String title;
  int authorId;

  /// @BelongsTo: populated by the `include` callback.
  Author? author;

  /// @HasMany: populated by the `include` callback.
  List<Sale> sales = const <Sale>[];

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
  Author({required this.id, required this.name});
  int id;
  final String name;
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
  Sale({required this.id, this.bookId = 0, this.customer = ''});
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

/// Minimal `books` meta for the simple `findById` tests
/// (no FK column). Used when the table schema only has
/// `id` + `title`.
EntityMeta _simpleBookMeta() => EntityMeta(
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
      fromRow: (Map<String, Object?> r) => Book(
        id: r['id']! as int,
        title: r['title']! as String,
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

  late final DbSet<Book> books = dbSet<Book>(_simpleBookMeta);

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

class _RelTestDbContext extends DbContext {
  _RelTestDbContext(this._provider);
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
