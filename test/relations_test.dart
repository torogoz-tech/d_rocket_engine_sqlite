// End-to-end tests for `DbSet<T>.firstBy` / `allBy`
// (.B typed navigation).
//
// `firstBy` / `allBy` are the runtime foundation for
// `@BelongsTo` / `@HasMany` navigation properties. They
// run a SQL-side `WHERE <column> = ?` against the
// `EntityMeta`'s declared columns, so:
//
// * The column name is validated against the
// `EntityMeta` (guards against SQL-injection through
// the column param).
// * The result is a typed `T` (or `T?` for `firstBy`)
// materialised via the codegen-supplied
// `EntityMeta.fromRow`.
//
// Test coverage:
// 1. `firstBy` returns the typed match (or `null`).
// 2. `allBy` returns every typed match.
// 3. `firstBy` / `allBy` reject an undeclared column
// with `StateError` (no SQL-injection vector).
// 4. `firstBy` / `allBy` reject when the codegen
// `fromRow` is missing (consistent with `findById`).
// 5. `firstBy` composes with the @BelongsTo navigation
// pattern (book → author).
// 6. `allBy` composes with the @HasMany navigation
// pattern (book → sales).

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group('Fase 4.2.B — DbSet<T>.firstBy / allBy typed navigation', () {
    setUp(() {
      // Run before each test.
    });

    test('firstBy returns the typed match (or null)', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL,
          country TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      final Author leGuin = Author(id: 0, name: 'Le Guin', country: 'USA');
      final Author asimov = Author(id: 0, name: 'Asimov', country: 'Russia');
      ctx.authors.add(leGuin);
      ctx.authors.add(asimov);
      ctx.saveChanges();

      // Look up by `name = 'Asimov'`.
      final Author? found =
          ctx.authors.firstBy(column: 'name', value: 'Asimov');
      expect(found, isNotNull);
      expect(found!.id, asimov.id);
      expect(found.name, 'Asimov');

      // No match → null.
      final Author? missing = ctx.authors.firstBy(
        column: 'name',
        value: 'Tolkien',
      );
      expect(missing, isNull);

      provider.dispose();
    });

    test('allBy returns every typed match', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL,
          country TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      // Three American authors, one Russian.
      ctx.authors.add(Author(id: 0, name: 'Le Guin', country: 'USA'));
      ctx.authors.add(Author(id: 0, name: 'Asimov', country: 'USA'));
      ctx.authors.add(Author(id: 0, name: 'Bradbury', country: 'USA'));
      ctx.authors.add(Author(id: 0, name: 'Tolstoy', country: 'Russia'));
      ctx.saveChanges();

      // @HasMany-style: every author with `country = 'USA'`.
      final List<Author> americans =
          ctx.authors.allBy(column: 'country', value: 'USA');
      expect(americans, hasLength(3));
      expect(
        americans.map((Author a) => a.name).toSet(),
        <Object?>{'Le Guin', 'Asimov', 'Bradbury'},
      );

      // No matches → empty list.
      final List<Author> none =
          ctx.authors.allBy(column: 'country', value: 'Atlantis');
      expect(none, isEmpty);

      provider.dispose();
    });

    test('firstBy / allBy reject an undeclared column (StateError)', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL,
          country TEXT NOT NULL
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      // `email` is NOT declared in the EntityMeta. The
      // column-name validation must reject it.
      expect(
        () => ctx.authors.firstBy(column: 'email', value: 'x@y'),
        throwsStateError,
      );
      expect(
        () => ctx.authors.allBy(column: 'email', value: 'x@y'),
        throwsStateError,
      );

      provider.dispose();
    });

    test('firstBy / allBy reject when the codegen fromRow is missing', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL
        )
      ''');
      final _NoFromRowContext ctx = _NoFromRowContext(provider);

      expect(
        () => ctx.authors.firstBy(column: 'id', value: 1),
        throwsUnsupportedError,
      );
      expect(
        () => ctx.authors.allBy(column: 'name', value: 'x'),
        throwsUnsupportedError,
      );

      provider.dispose();
    });

    test('@BelongsTo: book → author via firstBy', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL,
          country TEXT NOT NULL DEFAULT ''
        )
      ''');
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL REFERENCES authors(id),
          title     TEXT NOT NULL,
          year      INTEGER NOT NULL DEFAULT 0,
          price     REAL NOT NULL DEFAULT 0,
          category  TEXT NOT NULL DEFAULT ''
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      final Author leGuin = Author(id: 0, name: 'Le Guin', country: 'USA');
      ctx.authors.add(leGuin);
      ctx.saveChanges();

      final Book earthsea = Book(
        id: 0,
        title: 'A Wizard of Earthsea',
        authorId: leGuin.id,
        year: 1968,
        price: 12.50,
        category: 'fantasy',
      );
      ctx.books.add(earthsea);
      ctx.saveChanges();

      // @BelongsTo: look up the book → author by `id =
      // book.authorId`.
      final Author? author =
          ctx.authors.firstBy(column: 'id', value: earthsea.authorId);
      expect(author, isNotNull);
      expect(author!.id, leGuin.id);
      expect(author.name, 'Le Guin');

      provider.dispose();
    });

    test('@HasMany: book → sales via allBy', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          author_id INTEGER NOT NULL DEFAULT 0,
          title     TEXT NOT NULL,
          year      INTEGER NOT NULL DEFAULT 0,
          price     REAL NOT NULL DEFAULT 0,
          category  TEXT NOT NULL DEFAULT ''
        )
      ''');
      provider.execute('''
        CREATE TABLE sales (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          book_id    INTEGER NOT NULL REFERENCES books(id),
          customer   TEXT NOT NULL,
          quantity   INTEGER NOT NULL DEFAULT 0,
          total_price REAL NOT NULL DEFAULT 0,
          date       TEXT NOT NULL DEFAULT ''
        )
      ''');
      final _TestDbContext ctx = _TestDbContext(provider);

      final Book earthsea = Book(
        id: 0,
        title: 'Earthsea',
        authorId: 1,
        year: 1968,
        price: 12.50,
        category: 'fantasy',
      );
      ctx.books.add(earthsea);
      ctx.saveChanges();

      ctx.sales.add(Sale(
        id: 0,
        bookId: earthsea.id,
        customer: 'Alice',
        quantity: 1,
        totalPrice: 12.50,
        date: '2026-01-01',
      ));
      ctx.sales.add(Sale(
        id: 0,
        bookId: earthsea.id,
        customer: 'Bob',
        quantity: 2,
        totalPrice: 25.00,
        date: '2026-01-02',
      ));
      // A sale of a different book (won't match the
      // @HasMany filter below). The book must exist
      // because the test now runs with
      // `PRAGMA foreign_keys = ON` (1.1.1), so a
      // dangling FK would raise at insert time.
      ctx.books.add(Book(
        id: 2,
        title: 'Other',
        authorId: earthsea.authorId,
      ));
      ctx.sales.add(Sale(
        id: 0,
        bookId: 2,
        customer: 'Carol',
        quantity: 1,
        totalPrice: 9.99,
        date: '2026-01-03',
      ));
      ctx.saveChanges();

      // @HasMany: every sale with `book_id = earthsea.id`.
      final List<Sale> sales =
          ctx.sales.allBy(column: 'book_id', value: earthsea.id);
      expect(sales, hasLength(2));
      expect(
        sales.map((Sale s) => s.customer).toSet(),
        <Object?>{'Alice', 'Bob'},
      );

      provider.dispose();
    });
  });
}

// ─── Test fixtures ──────────────────────────────────────────────────

class Author implements RecordLike {
  Author({required this.id, required this.name, this.country = ''});
  int id;
  final String name;
  final String country;
  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'id' => id,
        'name' => name,
        'country' => country,
        _ => null,
      };
  @override
  String toString() => 'Author(id: $id, name: $name)';
}

class Book implements RecordLike {
  Book({
    required this.id,
    required this.title,
    required this.authorId,
    this.year = 0,
    this.price = 0.0,
    this.category = '',
  });
  int id;
  final int authorId;
  final String title;
  final int year;
  final double price;
  final String category;
  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'id' => id,
        'title' => title,
        'authorId' => authorId,
        'year' => year,
        'price' => price,
        'category' => category,
        _ => null,
      };
  @override
  String toString() => 'Book(id: $id, title: $title)';
}

class Sale implements RecordLike {
  Sale({
    required this.id,
    required this.bookId,
    required this.customer,
    this.quantity = 0,
    this.totalPrice = 0.0,
    this.date = '',
  });
  int id;
  final int bookId;
  final String customer;
  final int quantity;
  final double totalPrice;
  final String date;
  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'id' => id,
        'bookId' => bookId,
        'customer' => customer,
        'quantity' => quantity,
        'totalPrice' => totalPrice,
        'date' => date,
        _ => null,
      };
  @override
  String toString() => 'Sale(id: $id, bookId: $bookId)';
}

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
        ColumnMeta(
          sqlName: 'country',
          dartField: 'country',
          dartType: String,
        ),
      ],
      insertableColumns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'name',
          dartField: 'name',
          dartType: String,
        ),
        ColumnMeta(
          sqlName: 'country',
          dartField: 'country',
          dartType: String,
        ),
      ],
      updatableColumns: <ColumnMeta>[
        ColumnMeta(
          sqlName: 'name',
          dartField: 'name',
          dartType: String,
        ),
        ColumnMeta(
          sqlName: 'country',
          dartField: 'country',
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
        country: r['country']! as String,
      ),
      setId: (Object e, Object newId) => (e as Author).id = newId as int,
    );

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
        ColumnMeta(
          sqlName: 'price',
          dartField: 'price',
          dartType: double,
        ),
        ColumnMeta(
          sqlName: 'category',
          dartField: 'category',
          dartType: String,
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
        ColumnMeta(
          sqlName: 'price',
          dartField: 'price',
          dartType: double,
        ),
        ColumnMeta(
          sqlName: 'category',
          dartField: 'category',
          dartType: String,
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
        ColumnMeta(
          sqlName: 'price',
          dartField: 'price',
          dartType: double,
        ),
        ColumnMeta(
          sqlName: 'category',
          dartField: 'category',
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
        authorId: r['author_id']! as int,
        year: r['year']! as int,
        price: r['price']! as double,
        category: r['category']! as String,
      ),
      setId: (Object e, Object newId) => (e as Book).id = newId as int,
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
        ColumnMeta(
          sqlName: 'quantity',
          dartField: 'quantity',
          dartType: int,
        ),
        ColumnMeta(
          sqlName: 'total_price',
          dartField: 'totalPrice',
          dartType: double,
        ),
        ColumnMeta(
          sqlName: 'date',
          dartField: 'date',
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
        ColumnMeta(
          sqlName: 'quantity',
          dartField: 'quantity',
          dartType: int,
        ),
        ColumnMeta(
          sqlName: 'total_price',
          dartField: 'totalPrice',
          dartType: double,
        ),
        ColumnMeta(
          sqlName: 'date',
          dartField: 'date',
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
        ColumnMeta(
          sqlName: 'quantity',
          dartField: 'quantity',
          dartType: int,
        ),
        ColumnMeta(
          sqlName: 'total_price',
          dartField: 'totalPrice',
          dartType: double,
        ),
        ColumnMeta(
          sqlName: 'date',
          dartField: 'date',
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
        quantity: r['quantity']! as int,
        totalPrice: r['total_price']! as double,
        date: r['date']! as String,
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

/// Test context with `fromRow` deliberately `null`. Used
/// to verify `firstBy` / `allBy` reject when the codegen
/// helper is missing.
class _NoFromRowContext extends DbContext {
  _NoFromRowContext(this._provider);
  final SqliteQueryProvider _provider;

  late final DbSet<Author> authors = dbSet<Author>(
    () => EntityMeta(
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
      // No `fromRow` — exercises the "codegen missing"
      // guard in `firstBy` / `allBy`.
    ),
  );

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
