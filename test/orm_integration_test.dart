// End-to-end tests for the ORM runtime against a real
// SQLite database (in-memory).
//
// These tests bridge `package:d_rocket/sqlite.dart` — the
// SQLite query provider) with `package:d_rocket` — the
// ORM runtime). The MVP scope of is `add / addRange /
// remove / saveChanges`; `toList` / `findById` are documented
// to throw because they need the codegen's `fromRow` helper,
// which the MVP does not ship. The verification strategy is
// therefore:
//
// 1. Stage a few entities in a `DbContext`.
// 2. Call `saveChanges`.
// 3. Run raw `SELECT` against the `SqliteQueryProvider` to
// assert that the rows landed in the database with the
// right column values.
//
// This is the canonical "end-to-end" smoke test for the
// MVP.

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  setUp(EntityRegistry.reset);
  tearDown(EntityRegistry.reset);

  group('Fase 3 — ORM end-to-end with SqliteQueryProvider', () {
    test('add + saveChanges inserts a single row, then we can SELECT it back',
        () {
      // 1. Open a fresh in-memory DB and create the schema.
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL,
          country TEXT NOT NULL
        )
      ''');

      // 2. Build the context + DbSet.
      final _TestDbContext ctx = _TestDbContext(provider);

      // 3. Stage + save.
      ctx.authors.add(Author(id: 1, name: 'Le Guin', country: 'USA'));
      final int affected = ctx.saveChanges();
      expect(affected, 1);

      // 4. Verify the row is in the DB.
      final List<Map<String, Object?>> rows = provider.select(
        'SELECT * FROM authors',
      );
      expect(rows, hasLength(1));
      final Map<String, Object?> row = rows.first;
      expect(row['name'], 'Le Guin');
      expect(row['country'], 'USA');
      // The auto-PK of the inserted row is 1 (the only row in
      // the table), regardless of the `id` field of the
      // entity. The MVP does not propagate the entity's `id`
      // back to the user; that is a refinement.
      expect(row['id'], 1);

      provider.dispose();
    });

    test('addRange + saveChanges inserts every staged entity', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL,
          country TEXT NOT NULL
        )
      ''');

      final _TestDbContext ctx = _TestDbContext(provider);
      ctx.authors.addRange(<Author>[
        Author(id: 1, name: 'Le Guin', country: 'USA'),
        Author(id: 2, name: 'Asimov', country: 'Russia'),
        Author(id: 3, name: 'Borges', country: 'Argentina'),
      ]);
      expect(ctx.saveChanges(), 3);

      final List<Map<String, Object?>> rows = provider.select(
        'SELECT name, country FROM authors ORDER BY name',
      );
      expect(rows.map((Map<String, Object?> r) => r['name']).toList(),
          <Object?>['Asimov', 'Borges', 'Le Guin']);

      provider.dispose();
    });

    test(
        'CRUD end-to-end (Fase 3.5): insert + findById + toList + '
        'update + delete', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL,
          country TEXT NOT NULL
        )
      ''');

      final _TestDbContext ctx = _TestDbContext(provider);

      // 1. INSERT: PK is auto-incremented, `id` is back-propagated.
      final Author leGuin = Author(id: 0, name: 'Le Guin', country: 'USA');
      ctx.authors.add(leGuin);
      expect(leGuin.id, 0, reason: 'before saveChanges: id is 0');
      ctx.saveChanges();
      expect(leGuin.id, 1,
          reason: 'after saveChanges: id is back-propagated to 1');

      // 2. findById: reads back the row from the DB.
      final Author? fromDb = ctx.authors.findById(1);
      expect(fromDb, isNotNull);
      expect(fromDb!.id, 1);
      expect(fromDb.name, 'Le Guin');
      expect(fromDb.country, 'USA');

      // 3. toList: returns every row, ordered by SQLite's default.
      final List<Author> all = ctx.authors.toList();
      expect(all, hasLength(1));
      expect(all.first.name, 'Le Guin');

      // 4. UPDATE via markModified: change a field, mark, save, read back.
      final Author updated =
          Author(id: 1, name: 'Le Guin (revised)', country: 'Canada');
      ctx.authors.markModified(updated);
      expect(ctx.saveChanges(), 1);
      final Author? reread = ctx.authors.findById(1);
      expect(reread!.name, 'Le Guin (revised)');
      expect(reread.country, 'Canada');

      // 5. DELETE via markDeleted (alias for remove).
      ctx.authors.markDeleted(updated);
      expect(ctx.saveChanges(), 1);
      expect(ctx.authors.findById(1), isNull);
      expect(ctx.authors.toList(), isEmpty);

      provider.dispose();
    });

    test('back-propagation: multiple inserts each get a unique PK', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL,
          country TEXT NOT NULL
        )
      ''');

      final _TestDbContext ctx = _TestDbContext(provider);
      final Author a = Author(id: 0, name: 'A', country: 'X');
      final Author b = Author(id: 0, name: 'B', country: 'Y');
      final Author c = Author(id: 0, name: 'C', country: 'Z');
      ctx.authors.add(a);
      ctx.authors.add(b);
      ctx.authors.add(c);
      ctx.saveChanges();

      // The PKs are 1, 2, 3 — assigned in the order the
      // entities were added. The in-memory entities now have
      // their `id` fields populated.
      expect(a.id, 1);
      expect(b.id, 2);
      expect(c.id, 3);

      provider.dispose();
    });

    test('remove + saveChanges deletes the targeted row', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL,
          country TEXT NOT NULL
        )
      ''');
      // Seed two rows.
      final _TestDbContext ctx = _TestDbContext(provider);
      ctx.authors.add(Author(id: 1, name: 'A', country: 'X'));
      ctx.authors.add(Author(id: 2, name: 'B', country: 'Y'));
      ctx.saveChanges();

      // Now remove one and save.
      ctx.authors.remove(Author(id: 1, name: 'A', country: 'X'));
      expect(ctx.saveChanges(), 1);

      final List<Map<String, Object?>> rows =
          provider.select('SELECT * FROM authors');
      expect(rows, hasLength(1));
      expect(rows.first['name'], 'B');

      provider.dispose();
    });

    test(
        'mixed batch: 2 inserts + 1 delete in a single saveChanges '
        'call (in INSERT → DELETE order)', () {
      final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
      provider.execute('''
        CREATE TABLE authors (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          name    TEXT NOT NULL,
          country TEXT NOT NULL
        )
      ''');
      // Seed one row (id=1, because the entity's `id` field is
      // ignored by SQLite when the column is auto-increment).
      final _TestDbContext ctx = _TestDbContext(provider);
      ctx.authors.add(Author(id: 1, name: 'Existing', country: 'Earth'));
      ctx.saveChanges();
      ctx.changeTracker.clear();

      // Now mix of operations.
      ctx.authors.add(Author(id: 2, name: 'New A', country: 'Mars'));
      ctx.authors.add(Author(id: 3, name: 'New B', country: 'Jupiter'));
      // The DELETE uses the entity's `id` field (= 1) which
      // matches the seeded row. SQLite returns 1 for the
      // affected rowcount of the DELETE.
      ctx.authors.remove(Author(id: 1, name: 'Existing', country: 'Earth'));
      // The MVP does not yet have a `markModified` API on
      // `DbSet<T>`, so the UPDATE branch is exercised in a
      // separate test. Here we have 2 INSERTs + 1 DELETE = 3
      // affected rows.
      expect(ctx.saveChanges(), 3);

      final List<Map<String, Object?>> rows = provider.select(
        'SELECT name FROM authors ORDER BY name',
      );
      expect(rows.map((Map<String, Object?> r) => r['name']).toList(),
          <Object?>['New A', 'New B']);

      provider.dispose();
    });
  });
}

// ─── Test fixtures ──────────────────────────────────────────────────

/// `id` is `var` (not `final`) so the back-propagation hook
/// can mutate it after an `INSERT`. The codegen rejects
/// `final` PK fields (see `TableGenerator._emitSetId`).
class Author implements RecordLike {
  Author({required this.id, required this.name, required this.country});
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
  String toString() => 'Author(id: $id, name: $name, country: $country)';
}

EntityMeta _authorMeta() {
  final ColumnMeta id = ColumnMeta(
    sqlName: 'id',
    dartField: 'id',
    dartType: int,
    isPrimaryKey: true,
    isAutoIncrement: true,
  );
  final ColumnMeta name = ColumnMeta(
    sqlName: 'name',
    dartField: 'name',
    dartType: String,
  );
  final ColumnMeta country = ColumnMeta(
    sqlName: 'country',
    dartField: 'country',
    dartType: String,
  );
  return EntityMeta(
    tableName: 'authors',
    columns: <ColumnMeta>[id, name, country],
    insertableColumns: <ColumnMeta>[name, country],
    updatableColumns: <ColumnMeta>[name, country],
    primaryKey: id,
    primaryKeyIndex: 0,
    pkOf: (Object e) => (e as Author).id,
    // The codegen emits these. We inline them here
    // (this is a hand-written test fixture, not a codegen
    // consumer).
    fromRow: (Map<String, Object?> r) => Author(
      id: r['id']! as int,
      name: r['name']! as String,
      country: r['country']! as String,
    ),
    setId: (Object e, Object newId) => (e as Author).id = newId as int,
  );
}

/// A `DbContext` that wires the `DbSet<T>` callbacks to a
/// `SqliteQueryProvider`. The MVP does not provide a
/// factory-ready `SqliteRocketDbContext` (that is planned for
///), so each test instantiates one of these.
class _TestDbContext extends DbContext {
  _TestDbContext(this.provider) {
    authors = dbSet<Author>(() => _authorMeta());
  }

  final SqliteQueryProvider provider;
  late final DbSet<Author> authors;

  @override
  DbSet<T> createDbSet<T>(EntityMeta Function() metaAccessor) {
    return DbSet<T>(
      metaAccessor: metaAccessor,
      tracker: changeTracker,
      execute: (String sql, List<Object?> binds) {
        // Use prepare / execute / updatedRows so the rowcount
        // of THIS statement (not the last one) is captured.
        // Without this, every statement would return 0 and
        // the `saveChanges` rowcount would be useless for
        // tests.
        if (binds.isEmpty) {
          provider.execute(sql);
        } else {
          final dynamic stmt = provider.database.prepare(sql);
          try {
            stmt.execute(binds);
          } finally {
            stmt.dispose();
          }
        }
        return provider.database.updatedRows;
      },
      select: (String sql, List<Object?> binds) {
        if (binds.isEmpty) return provider.select(sql);
        return provider.selectWithBinds(sql, binds);
      },
      lastInsertRowId: () => provider.database.lastInsertRowId,
    );
  }
}
