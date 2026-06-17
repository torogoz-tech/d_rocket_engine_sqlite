// End-to-end tests for `DbSet<T>.asQueryable` .
//
// The `asQueryable` method bridges the ORM (`DbSet<T>`)
// with the LINQ surface (`Queryable<T>`) so the user
// can write:
//
// dbSet.asQueryable
// .where_((b) => b.year > 1970)
// .orderByDescending_((b) => b.price)
// .take_(3)
// .select_<String>((b) => b.title)
// .toList_;
//
// and get back a list of typed `Book` entities (or `String`
// titles, depending on the projection).
//
// MVP: the `where_` / `orderBy_` / `select_` /
// `take_` operators are evaluated in Dart over the rows
// fetched by a single `SELECT * FROM <table>`. Full
// SQL-side filtering is scheduled for .

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group('Fase 3.7 — DbSet<T>.asQueryable() end-to-end', () {
    test('asQueryable() materialises entities via EntityMeta.fromRow', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          year  INTEGER NOT NULL,
          price REAL NOT NULL
        )
      ''');

      final _TestDbContext ctx = _TestDbContext(provider);

      // Insert 3 books.
      for (int i = 0; i < 3; i++) {
        ctx.books.add(Book(
          id: 0,
          title: 'Book $i',
          year: 1970 + i * 10,
          price: 10.0 + i,
        ));
      }
      expect(ctx.saveChanges(), 3);

      // Read them back via asQueryable.
      final List<Book> all =
          ctx.books.asQueryable().toList_().cast<Book>().toList();
      expect(all, hasLength(3));
      expect(all.map((Book b) => b.id).toSet(), <int>{1, 2, 3});
      expect(all.map((Book b) => b.title),
          <Object?>['Book 0', 'Book 1', 'Book 2']);

      provider.dispose();
    });

    test('where_ filters in memory (MVP) and returns only matching entities',
        () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          year INTEGER NOT NULL,
          price REAL NOT NULL
        )
      ''');

      final _TestDbContext ctx = _TestDbContext(provider);
      ctx.books.addRange(<Book>[
        Book(id: 0, title: 'Old', year: 1950, price: 5.0),
        Book(id: 0, title: 'Modern A', year: 1980, price: 12.0),
        Book(id: 0, title: 'Modern B', year: 1990, price: 15.0),
        Book(id: 0, title: 'Recent', year: 2000, price: 8.0),
      ]);
      ctx.saveChanges();

      // Filter by year > 1970.
      final List<Book> modern = ctx.books
          .asQueryable()
          .where_(Expr.lambda(
            <Expr>[Expr.param('u')],
            Expr.binary(
                '>', Expr.member(Expr.param('u'), 'year'), Expr.const_(1970)),
          ))
          .toList_()
          .cast<Book>()
          .toList();
      expect(modern, hasLength(3));
      expect(modern.map((Book b) => b.title).toSet(),
          <Object?>{'Modern A', 'Modern B', 'Recent'});

      provider.dispose();
    });

    test('orderBy_ + take_ + select_ compose end-to-end (Fase 3.7 MVP)', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE books (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          year INTEGER NOT NULL,
          price REAL NOT NULL
        )
      ''');

      final _TestDbContext ctx = _TestDbContext(provider);
      ctx.books.addRange(<Book>[
        Book(id: 0, title: 'Cheap', year: 1970, price: 1.0),
        Book(id: 0, title: 'Mid', year: 1980, price: 5.0),
        Book(id: 0, title: 'Expensive', year: 1990, price: 10.0),
        Book(id: 0, title: 'Priciest', year: 2000, price: 20.0),
      ]);
      ctx.saveChanges();

      // Top-3 most expensive book titles (descending).
      final List<String> top3 = ctx.books
          .asQueryable()
          .orderByDescending_(
            Expr.lambda(
              <Expr>[Expr.param('u')],
              Expr.member(Expr.param('u'), 'price'),
            ),
          )
          .take_(3)
          .select_<String>(
            Expr.lambda(
              <Expr>[Expr.param('u')],
              Expr.member(Expr.param('u'), 'title'),
            ),
          )
          .toList_()
          .cast<String>()
          .toList();
      expect(top3, <Object?>['Priciest', 'Expensive', 'Mid'],
          reason:
              'orderByDescending_ + take_ + select_ compose to top-3 titles');

      provider.dispose();
    });

    test('asQueryable() throws when the runtime has no SqliteProvider', () {
      // Hand-rolled DbSet without attachSqliteProvider.
      final EntityMeta meta = _bookMeta();
      final DbSet<Book> set = DbSet<Book>(
        metaAccessor: () => meta,
        tracker: ChangeTracker(),
        execute: (String sql, List<Object?> binds) => 0,
        select: (String sql, List<Object?> binds) => <Object?>[],
        lastInsertRowId: () => 0,
      );

      expect(() => set.asQueryable(), throwsUnsupportedError,
          reason: 'No SqliteProvider attached — the bridge is SQLite-specific');
    });
  });
}

// ─── Test fixtures ──────────────────────────────────────────────────

/// `id` is `var` (not `final`) so the back-propagation hook
/// can mutate it after an `INSERT`.
class Book implements RecordLike {
  Book(
      {required this.id,
      required this.title,
      required this.year,
      required this.price});
  int id;
  final String title;
  final int year;
  final double price;

  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'id' => id,
        'title' => title,
        'year' => year,
        'price' => price,
        _ => null,
      };

  @override
  String toString() =>
      'Book(id: $id, title: $title, year: $year, price: $price)';
}

EntityMeta _bookMeta() {
  final ColumnMeta id = ColumnMeta(
    sqlName: 'id',
    dartField: 'id',
    dartType: int,
    isPrimaryKey: true,
    isAutoIncrement: true,
  );
  final ColumnMeta title = ColumnMeta(
    sqlName: 'title',
    dartField: 'title',
    dartType: String,
  );
  final ColumnMeta year = ColumnMeta(
    sqlName: 'year',
    dartField: 'year',
    dartType: int,
  );
  final ColumnMeta price = ColumnMeta(
    sqlName: 'price',
    dartField: 'price',
    dartType: double,
  );
  return EntityMeta(
    tableName: 'books',
    columns: <ColumnMeta>[id, title, year, price],
    insertableColumns: <ColumnMeta>[title, year, price],
    updatableColumns: <ColumnMeta>[title, year, price],
    primaryKey: id,
    primaryKeyIndex: 0,
    pkOf: (Object e) => (e as Book).id,
    fromRow: (Map<String, Object?> r) => Book(
      id: r['id']! as int,
      title: r['title']! as String,
      year: r['year']! as int,
      price: r['price']! as double,
    ),
    setId: (Object e, Object newId) => (e as Book).id = newId as int,
  );
}

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
        return 1; // MVP: assume every execute affects 1 row
      },
      select: (String sql, List<Object?> binds) {
        if (binds.isEmpty) return _provider.select(sql);
        return _provider.selectWithBinds(sql, binds);
      },
      lastInsertRowId: () => _provider.database.lastInsertRowId,
    ).attach<SqliteQueryProvider>(_provider);
  }
}
