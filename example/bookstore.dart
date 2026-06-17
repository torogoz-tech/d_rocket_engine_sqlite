/// Example: a tiny bookstore, exercising the LINQ surface
/// (`where_`, `select_`, `orderBy_`, `take_`, `skip_`, `count_`,
/// `sum_`, `average_`, `min_`, `max_`, `groupBy_`, `join_`,
/// `groupJoin_`).
///
/// Run it with:
///
/// ```sh
/// dart run example/bookstore.dart
/// ```
///
/// The same data and queries are also exercised in
/// `test/sqlite/bookstore_test.dart`.
///
/// Note: this example was moved from `lib/example/`
/// to `example/` in v1.0.1. It is **not** part of the
/// published library — `pubspec.yaml` `example/`
/// files are only on the repo and on the GitHub
/// source tree, not in the pub.dev tarball.
library;

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';

import 'd_rocket_registry.g.dart';

part 'bookstore.g.dart';

// ─── Domain models — clean classes, no `readField` or `toString`
// boilerplate, no `@Record` annotation, no `with _$XRecord`.
// The `d_rocket_builder` codegen discovers by `extends Record`
// and emits a registration snippet into `bookstore.g.dart`.
// The developer calls `initializeD` once in `main`. ────

class Author extends Record {
  Author({required this.id, required this.name, required this.country});
  final int id;
  final String name;
  final String country;
}

class Book extends Record {
  Book({
    required this.id,
    required this.title,
    required this.authorId,
    required this.year,
    required this.price,
    required this.category,
  });
  final int id;
  final String title;
  final int authorId;
  final int year;
  final double price;
  final String category;
}

class Sale extends Record {
  Sale({
    required this.id,
    required this.bookId,
    required this.customer,
    required this.quantity,
    required this.totalPrice,
    required this.date,
  });
  final int id;
  final int bookId;
  final String customer;
  final int quantity;
  final double totalPrice;
  final String date;
}

// ─── Bundle of results returned by [runBookstoreExample]. ──────────

class BookstoreResults {
  const BookstoreResults({
    required this.modernBooks,
    required this.top3ByPrice,
    required this.allTitles,
    required this.totalSales,
    required this.totalRevenue,
    required this.avgPrice,
    required this.minYear,
    required this.maxPrice,
    required this.sciFiPairs,
    required this.authorBookCounts,
    required this.booksWithAuthors,
  });

  /// Q1: where_ — books published after 1970.
  final List<Book> modernBooks;

  /// Q2: orderByDescending_ + take_ — 3 most expensive books.
  final List<Book> top3ByPrice;

  /// Q3: select_`<String>` — list of all book titles.
  final List<String> allTitles;

  /// Q4: count_ — number of sales.
  final int totalSales;

  /// Q5: sum_ — total revenue.
  final num totalRevenue;

  /// Q6: average_ — average book price.
  final double avgPrice;

  /// Q7: min_ — oldest publication year.
  final int minYear;

  /// Q8: max_ — most expensive book price.
  final double maxPrice;

  /// Q9: join_ — 'Author: Title' pairs for sci-fi books.
  final List<String> sciFiPairs;

  /// Q10: groupBy_`<int>` — number of books per author id.
  final Map<int, int> authorBookCounts;

  /// Q11: groupJoin_ — every author with their book titles.
  final List<String> booksWithAuthors;
}

// ─── The example. ──────────────────────────────────────────────────

BookstoreResults runBookstoreExample() {
  // 1. Open an in-memory database, create the schema, and seed.
  final provider = SqliteQueryProvider.inMemory();
  provider.execute('''
    CREATE TABLE authors (
      id      INTEGER PRIMARY KEY,
      name    TEXT NOT NULL,
      country TEXT NOT NULL
    )
  ''');
  provider.execute('''
    CREATE TABLE books (
      id       INTEGER PRIMARY KEY,
      title    TEXT NOT NULL,
      authorId INTEGER NOT NULL,
      year     INTEGER NOT NULL,
      price    REAL NOT NULL,
      category TEXT NOT NULL
    )
  ''');
  provider.execute('''
    CREATE TABLE sales (
      id         INTEGER PRIMARY KEY,
      bookId     INTEGER NOT NULL,
      customer   TEXT NOT NULL,
      quantity   INTEGER NOT NULL,
      totalPrice REAL NOT NULL,
      date       TEXT NOT NULL
    )
  ''');

  final authors = <Author>[
    Author(id: 1, name: 'Ursula K. Le Guin', country: 'USA'),
    Author(id: 2, name: 'Isaac Asimov', country: 'Russia'),
    Author(id: 3, name: 'Gabriel García Márquez', country: 'Colombia'),
    Author(id: 4, name: 'Jorge Luis Borges', country: 'Argentina'),
  ];
  final insA = provider.database.prepare(
    'INSERT INTO authors (id, name, country) VALUES (?, ?, ?)',
  );
  for (final a in authors) {
    insA.execute([a.id, a.name, a.country]);
  }
  insA.close();

  final books = <Book>[
    Book(
        id: 1,
        title: 'A Wizard of Earthsea',
        authorId: 1,
        year: 1968,
        price: 12.50,
        category: 'fantasy'),
    Book(
        id: 2,
        title: 'The Left Hand of Darkness',
        authorId: 1,
        year: 1969,
        price: 14.00,
        category: 'sci-fi'),
    Book(
        id: 3,
        title: 'Foundation',
        authorId: 2,
        year: 1951,
        price: 9.99,
        category: 'sci-fi'),
    Book(
        id: 4,
        title: 'I, Robot',
        authorId: 2,
        year: 1950,
        price: 8.50,
        category: 'sci-fi'),
    Book(
        id: 5,
        title: 'One Hundred Years of Solitude',
        authorId: 3,
        year: 1967,
        price: 18.00,
        category: 'fiction'),
    Book(
        id: 6,
        title: 'Love in the Time of Cholera',
        authorId: 3,
        year: 1985,
        price: 15.50,
        category: 'fiction'),
    Book(
        id: 7,
        title: 'Ficciones',
        authorId: 4,
        year: 1944,
        price: 11.25,
        category: 'fiction'),
  ];
  final insB = provider.database.prepare(
    'INSERT INTO books (id, title, authorId, year, price, category) VALUES (?, ?, ?, ?, ?, ?)',
  );
  for (final b in books) {
    insB.execute([b.id, b.title, b.authorId, b.year, b.price, b.category]);
  }
  insB.close();

  final sales = <Sale>[
    Sale(
        id: 1,
        bookId: 1,
        customer: 'Alice',
        quantity: 1,
        totalPrice: 12.50,
        date: '2024-01-15'),
    Sale(
        id: 2,
        bookId: 3,
        customer: 'Alice',
        quantity: 2,
        totalPrice: 19.98,
        date: '2024-01-20'),
    Sale(
        id: 3,
        bookId: 2,
        customer: 'Bob',
        quantity: 1,
        totalPrice: 14.00,
        date: '2024-02-01'),
    Sale(
        id: 4,
        bookId: 5,
        customer: 'Bob',
        quantity: 1,
        totalPrice: 18.00,
        date: '2024-02-10'),
    Sale(
        id: 5,
        bookId: 4,
        customer: 'Carol',
        quantity: 3,
        totalPrice: 25.50,
        date: '2024-03-05'),
  ];
  final insS = provider.database.prepare(
    'INSERT INTO sales (id, bookId, customer, quantity, totalPrice, date) VALUES (?, ?, ?, ?, ?, ?)',
  );
  for (final s in sales) {
    insS.execute(
        [s.id, s.bookId, s.customer, s.quantity, s.totalPrice, s.date]);
  }
  insS.close();

  // 2. Build the queryables.
  final booksQ = Queryable<Book>(
    provider: provider,
    table: 'books',
    reader: (row) => Book(
      id: row['id']! as int,
      title: row['title']! as String,
      authorId: row['authorId']! as int,
      year: row['year']! as int,
      price: row['price']! as double,
      category: row['category']! as String,
    ),
  );
  final salesQ = Queryable<Sale>(
    provider: provider,
    table: 'sales',
    reader: (row) => Sale(
      id: row['id']! as int,
      bookId: row['bookId']! as int,
      customer: row['customer']! as String,
      quantity: row['quantity']! as int,
      totalPrice: row['totalPrice']! as double,
      date: row['date']! as String,
    ),
  );
  final authorsQ = Queryable<Author>(
    provider: provider,
    table: 'authors',
    reader: (row) => Author(
      id: row['id']! as int,
      name: row['name']! as String,
      country: row['country']! as String,
    ),
  );

  // Q1: where_ — books published after 1970.
  final modernBooks = booksQ.where_((Book u) => u.year > 1970).toList_();

  // Q2: orderByDescending_ + take_ — 3 most expensive books.
  final top3ByPrice =
      booksQ.orderByDescending_((Book u) => u.price).take_(3).toList_();

  // Q3: select_<String> — list of all book titles.
  final allTitles = booksQ.select_<String>((Book u) => u.title).toList_();

  // Q4: count_ — number of sales.
  final totalSales = salesQ.count_();

  // Q5: sum_ — total revenue.
  final totalRevenue = salesQ.sum_((Sale u) => u.totalPrice);

  // Q6: average_ — average book price.
  final avgPrice = booksQ.average_((Book u) => u.price);

  // Q7: min_ — oldest publication year.
  final minYear = booksQ.min_((Book u) => u.year)! as int;

  // Q8: max_ — most expensive book price.
  final maxPrice = booksQ.max_((Book u) => u.price)! as double;

  // Q9: join_ — 'Author: Title' pairs for sci-fi books.
  final sciFiPairs = booksQ
      .where_((Book u) => u.category == 'sci-fi')
      .join_<Author, int, String>(
        inner: authorsQ,
        outerKeySelector: (Book b) => b.authorId,
        innerKeySelector: (Author a) => a.id,
        resultSelector: (Book b, Author a) => '${a.name}: ${b.title}',
      )
      .toList_();

  // Q10: groupBy_<int> — number of books per author id.
  final grouped =
      booksQ.groupBy_<int>(keySelector: (Book u) => u.authorId).toList_();
  final authorBookCounts = <int, int>{
    for (final g in grouped) g.key: g.length,
  };

  // Q11: groupJoin_ — every author with their book titles.
  final booksWithAuthors = authorsQ
      .groupJoin_<Book, int, String>(
        inner: booksQ,
        outerKeySelector: (Author a) => a.id,
        innerKeySelector: (Book b) => b.authorId,
        // Note: the second parameter `bs` is typed as
        // `dynamic` (no explicit type annotation) so
        // that the runtime call site in
        // SqliteJoinedQueryable (which holds the
        // matches as `List<dynamic>`) does not trigger
        // a generic type check at invocation. The body
        // still works: `bs.map((b) => b.title)` uses
        // dynamic dispatch on the elements (which are
        // `Book` instances).
        resultSelector: (a, bs, k) =>
            '${a.name}: ${bs.map((b) => b.title).join(', ')}',
      )
      .toList_();

  provider.dispose();

  return BookstoreResults(
    modernBooks: modernBooks,
    top3ByPrice: top3ByPrice,
    allTitles: allTitles,
    totalSales: totalSales,
    totalRevenue: totalRevenue,
    avgPrice: avgPrice,
    minYear: minYear,
    maxPrice: maxPrice,
    sciFiPairs: sciFiPairs,
    authorBookCounts: authorBookCounts,
    booksWithAuthors: booksWithAuthors,
  );
}

// ─── Pretty-printer used by `main`. ──────────────────────────────

void printBookstoreResults(BookstoreResults r) {
  print('═══════════════════════════════════════════════════════════');
  print('  d_rocket — bookstore example (Fase 2.3 + Fase 3 ORM)');
  print('═══════════════════════════════════════════════════════════\n');

  print('── Q1: where_ — books published after 1970 ──');
  for (final b in r.modernBooks) {
    print('  • $b');
  }

  print('\n── Q2: orderByDescending_ + take_ — 3 most expensive books ──');
  for (final b in r.top3ByPrice) {
    print('  • $b');
  }

  print('\n── Q3: select_<String> — all book titles ──');
  for (final t in r.allTitles) {
    print('  • "$t"');
  }

  print('\n── Q4: count_ — number of sales ──');
  print('  • ${r.totalSales}');

  print('\n── Q5: sum_ — total revenue ──');
  print('  • \$${r.totalRevenue}');

  print('\n── Q6: average_ — average book price ──');
  print('  • \$${r.avgPrice.toStringAsFixed(2)}');

  print('\n── Q7: min_ — oldest publication year ──');
  print('  • ${r.minYear}');

  print('\n── Q8: max_ — most expensive book price ──');
  print('  • \$${r.maxPrice.toStringAsFixed(2)}');

  print('\n── Q9: join_ — sci-fi book:author pairs ──');
  for (final p in r.sciFiPairs) {
    print('  • $p');
  }

  print('\n── Q10: groupBy_ — books per author id ──');
  r.authorBookCounts.forEach((id, count) {
    print('  • author $id → $count book(s)');
  });

  print('\n── Q11: groupJoin_ — every author with their books ──');
  for (final line in r.booksWithAuthors) {
    print('  • $line');
  }

  print('\n═══════════════════════════════════════════════════════════\n');
}

void main() {
  initializeD(); // Generated by d_rocket_builder. Registers
  // every `extends Record` class in this package.
  final r = runBookstoreExample();
  printBookstoreResults(r);
}
