// Tests for the `@Embedded` value object pattern.
// Covers:
//
// 1. `embedColumns(EmbeddedMeta)` emits the right
// SQL column list for the embedded fields, both
// with and without a prefix.
// 2. `EntityMeta.createTableDdl` also flattens
// the embedded fields into the parent table.
// 3. End-to-end: insert a `Customer` with an
// `Address` (embedded), read it back, verify the
// embedded object is populated.
// 4. Mutating the embedded object on a tracked
// entity updates the right column (single SQL
// UPDATE for the whole row).

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group('Fase 4.7 — embedColumns() flattens embedded fields', () {
    test('no prefix: "street TEXT NOT NULL, city TEXT NOT NULL"', () {
      final em = EmbeddedMeta(
        name: 'address',
        dartType: _Address,
        columns: <ColumnMeta>[
          ColumnMeta(
            sqlName: 'street',
            dartField: 'street',
            dartType: String,
          ),
          ColumnMeta(
            sqlName: 'city',
            dartField: 'city',
            dartType: String,
          ),
        ],
        fromRow: (Map<String, Object?> row) => _Address(
          street: row['street']! as String,
          city: row['city']! as String,
        ),
        get: (Object e) => (e as _Customer).address,
        set: (Object e, Object? v) => (e as _Customer).address = v! as _Address,
      );
      final sql = embedColumns(em);
      expect(
        sql,
        'street TEXT NOT NULL, city TEXT NOT NULL',
      );
    });

    test('with prefix: "addr_street TEXT, addr_city TEXT"', () {
      final em = EmbeddedMeta(
        name: 'address',
        dartType: _Address,
        prefix: 'addr',
        columns: <ColumnMeta>[
          ColumnMeta(
            sqlName: 'street',
            dartField: 'street',
            dartType: String,
            nullable: true,
          ),
          ColumnMeta(
            sqlName: 'city',
            dartField: 'city',
            dartType: String,
            nullable: true,
          ),
        ],
        fromRow: (Map<String, Object?> row) => _Address(
          street: (row['addr_street'] as String?) ?? '',
          city: (row['addr_city'] as String?) ?? '',
        ),
        get: (Object e) => (e as _Customer).address,
        set: (Object e, Object? v) => (e as _Customer).address = v! as _Address,
      );
      final sql = embedColumns(em);
      expect(
        sql,
        'addr_street TEXT, addr_city TEXT',
      );
    });

    test('EntityMeta.createTableDdl() also flattens embedded fields', () {
      final em = EmbeddedMeta(
        name: 'address',
        dartType: _Address,
        columns: <ColumnMeta>[
          ColumnMeta(
            sqlName: 'street',
            dartField: 'street',
            dartType: String,
          ),
          ColumnMeta(
            sqlName: 'city',
            dartField: 'city',
            dartType: String,
          ),
        ],
        fromRow: (Map<String, Object?> _) => _Address(street: '', city: ''),
        get: (Object _) => null,
        set: (_, __) {},
      );
      final meta = EntityMeta(
        tableName: 'customers',
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
        pkOf: (Object e) => (e as _Customer).id,
        embeddedFields: <EmbeddedMeta>[em],
      );
      final ddl = meta.createTableDdl();
      expect(
        ddl,
        'CREATE TABLE IF NOT EXISTS customers (\n'
        '  id INTEGER PRIMARY KEY AUTOINCREMENT,\n'
        '  name TEXT NOT NULL,\n'
        '  street TEXT NOT NULL, city TEXT NOT NULL\n'
        ')\n',
      );
    });
  });

  group('Fase 4.7 — end-to-end @Embedded round-trip', () {
    late SqliteQueryProvider provider;
    late _CustomerDbContext ctx;

    setUp(() {
      provider = SqliteQueryProvider.inMemory();
      ctx = _CustomerDbContext(provider);
      ctx.createSchema();
    });

    tearDown(() {
      provider.dispose();
    });

    test('insert a customer with an address, read it back', () {
      final alice = _Customer(
        id: 0,
        name: 'Alice',
        address: _Address(street: '1 Apple Park', city: 'Cupertino'),
      );
      ctx.customers.add(alice);
      ctx.saveChanges();
      expect(alice.id, 1, reason: 'PK is back-propagated');

      // Read it back.
      final read = ctx.customers.findById(1);
      expect(read, isNotNull);
      expect(read!.name, 'Alice');
      expect(read.address.street, '1 Apple Park');
      expect(read.address.city, 'Cupertino');
    });

    test('embedded fields share the parent row (1 SQL per operation)', () {
      final bob = _Customer(
        id: 0,
        name: 'Bob',
        address: _Address(street: '742 Evergreen', city: 'Springfield'),
      );
      ctx.customers.add(bob);
      ctx.saveChanges();

      // The row should be FLAT (no nested table for
      // addresses). Verify by querying the raw row.
      final rows = provider.selectWithBinds(
        'SELECT name, street, city FROM customers WHERE id = ?',
        [bob.id],
      );
      expect(rows.length, 1);
      expect(rows.first['name'], 'Bob');
      expect(rows.first['street'], '742 Evergreen');
      expect(rows.first['city'], 'Springfield');
    });

    test('mutating the embedded object updates the right column', () {
      final alice = _Customer(
        id: 0,
        name: 'Alice',
        address: _Address(street: 'old street', city: 'old city'),
      );
      ctx.customers.add(alice);
      ctx.saveChanges();

      // Re-read (the saveChanges in-memory entity is
      // already populated, but the next findById loads
      // a fresh copy).
      final fresh = ctx.customers.findById(1)!;
      // Mutate the embedded object.
      fresh.address = _Address(street: 'new street', city: 'new city');
      //: when the entity is loaded via
      // `findById` and then mutated, the user must
      // call `update` to attach it to the change
      // tracker (otherwise saveChanges has nothing
      // to do for this entity).
      ctx.customers.markModified(fresh);
      ctx.saveChanges();

      // The DB has the new values.
      final rows = provider.selectWithBinds(
        'SELECT street, city FROM customers WHERE id = ?',
        [1],
      );
      expect(rows.first['street'], 'new street');
      expect(rows.first['city'], 'new city');
    });

    test('multiple customers with different addresses coexist', () {
      ctx.customers.add(_Customer(
        id: 0,
        name: 'Alice',
        address: _Address(street: 'A street', city: 'A city'),
      ));
      ctx.customers.add(_Customer(
        id: 0,
        name: 'Bob',
        address: _Address(street: 'B street', city: 'B city'),
      ));
      ctx.saveChanges();

      final all = ctx.customers.toList();
      expect(all, hasLength(2));
      final byName = {for (final c in all) c.name: c};
      expect(byName['Alice']!.address.street, 'A street');
      expect(byName['Bob']!.address.city, 'B city');
    });
  });
}

// ─── Test fixtures ──────────────────────────────────────────────────

class _Address {
  _Address({required this.street, required this.city});
  final String street;
  final String city;

  @override
  String toString() => '_Address(street: $street, city: $city)';
}

class _Customer implements RecordLike {
  _Customer({this.id = 0, required this.name, required this.address});
  int id;
  String name;
  _Address address;

  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'id' => id,
        'name' => name,
        'address' => address,
        _ => null,
      };

  @override
  String toString() => '_Customer(id: $id, name: $name, address: $address)';
}

final EmbeddedMeta _addressMeta = EmbeddedMeta(
  name: 'address',
  dartType: _Address,
  columns: <ColumnMeta>[
    ColumnMeta(
      sqlName: 'street',
      dartField: 'street',
      dartType: String,
    ),
    ColumnMeta(
      sqlName: 'city',
      dartField: 'city',
      dartType: String,
    ),
  ],
  fromRow: (Map<String, Object?> row) => _Address(
    street: row['street']! as String,
    city: row['city']! as String,
  ),
  get: (Object e) => (e as _Customer).address,
  set: (Object e, Object? v) => (e as _Customer).address = v! as _Address,
);

final EntityMeta _customerMeta = EntityMeta(
  tableName: 'customers',
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
    //: the embedded fields are also
    // insertable / updatable (they're just regular
    // columns at the SQL level).
    ColumnMeta(
      sqlName: 'street',
      dartField: 'address.street',
      dartType: String,
    ),
    ColumnMeta(
      sqlName: 'city',
      dartField: 'address.city',
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
      sqlName: 'street',
      dartField: 'address.street',
      dartType: String,
    ),
    ColumnMeta(
      sqlName: 'city',
      dartField: 'address.city',
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
  pkOf: (Object e) => (e as _Customer).id,
  setId: (Object e, Object newId) => (e as _Customer).id = newId as int,
  //: the codegen-emitted `readColumn`
  // for embedded fields. The `dartField` of an
  // embedded column is a path like `'address.street'`,
  // and `RecordLike.readField` doesn't understand
  // paths — so we emit a `readColumn` that knows how
  // to walk the path.
  readColumn: (Object e, ColumnMeta c) {
    final cust = e as _Customer;
    if (c.dartField == 'address.street') return cust.address.street;
    if (c.dartField == 'address.city') return cust.address.city;
    if (c.dartField == 'name') return cust.name;
    if (c.dartField == 'id') return cust.id;
    return null;
  },
  fromRow: (Map<String, Object?> row) => _Customer(
    id: row['id']! as int,
    name: row['name']! as String,
    address: _addressMeta.fromRow(row) as _Address,
  ),
  embeddedFields: <EmbeddedMeta>[_addressMeta],
);

class _CustomerDbContext extends DbContext {
  _CustomerDbContext(this._provider);
  final SqliteQueryProvider _provider;

  late final DbSet<_Customer> customers = dbSet<_Customer>(() => _customerMeta);

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

  void createSchema() {
    _provider.execute('PRAGMA foreign_keys = ON');
    // Use the helper to emit the embedded columns
    // automatically.
    _provider.execute('''
      CREATE TABLE customers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        ${embedColumns(_addressMeta)}
      )
    ''');
  }
}
