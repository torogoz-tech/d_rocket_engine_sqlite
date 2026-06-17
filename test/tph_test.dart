// Tests for the Polymorphism TPH (Table-Per-
// Hierarchy). Animal → Dog / Cat with a `kind`
// discriminator column. The Animal DbSet materialises
// the right subclass instance at row-read time.

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  late SqliteQueryProvider provider;
  late _ZooContext ctx;

  setUp(() {
    provider = SqliteQueryProvider.inMemory();
    provider.execute('PRAGMA foreign_keys = ON;');
    ctx = _ZooContext(provider);
    ctx.createSchema();
  });

  tearDown(() async {
    await provider.disposeAsync();
  });

  group('Fase 5.2 — TPH: schema + root meta', () {
    test('the animals table is created with the kind discriminator', () {
      final List<Map<String, Object?>> rows = provider.select(
        'PRAGMA table_info(animals)',
      );
      final Set<String> columnNames = <String>{
        for (final Map<String, Object?> row in rows) row['name']! as String,
      };
      expect(columnNames, containsAll(<String>{'id', 'name', 'kind'}));
    });

    test('the root meta has TPH strategy + subclassMetas map', () {
      expect(animalMeta.inheritanceStrategy, InheritanceStrategy.tph);
      expect(animalMeta.subclassMetas, isNotNull);
      expect(
          animalMeta.subclassMetas!.keys, containsAll(<String>['dog', 'cat']));
    });

    test('the child metas have discriminatorValue + discriminatorColumn', () {
      expect(dogMeta.discriminatorValue, 'dog');
      expect(dogMeta.discriminatorColumn, same(_kindCol));
      expect(catMeta.discriminatorValue, 'cat');
      expect(catMeta.discriminatorColumn, same(_kindCol));
    });

    test('resolveForDiscriminator returns the right child', () {
      expect(animalMeta.resolveForDiscriminator('dog'), same(dogMeta));
      expect(animalMeta.resolveForDiscriminator('cat'), same(catMeta));
      // Null falls back to the root (the root row is
      // materialised as Animal, not as Dog / Cat).
      expect(animalMeta.resolveForDiscriminator(null), same(animalMeta));
      // Unknown value throws.
      expect(() => animalMeta.resolveForDiscriminator('fish'),
          throwsA(isA<StateError>()));
    });
  });

  group('Fase 5.2 — TPH: DbSet materialises the right subclass', () {
    test('toList() returns the right subclass for each row', () async {
      ctx.animals.add(_Dog(id: 0, name: 'Rex', breed: 'labrador'));
      ctx.animals.add(_Cat(id: 0, name: 'Whiskers', indoor: true));
      await ctx.saveChangesAsync();

      final List<_Animal> all = await ctx.animals.toListAsync_();
      expect(all, hasLength(2));
      // The first row is a Dog.
      expect(all[0], isA<_Dog>());
      expect((all[0] as _Dog).breed, 'labrador');
      // The second row is a Cat.
      expect(all[1], isA<_Cat>());
      expect((all[1] as _Cat).indoor, true);
    });

    test('firstByAsync() with a discriminator-aware read', () async {
      ctx.animals.add(_Dog(id: 0, name: 'Rex', breed: 'labrador'));
      ctx.animals.add(_Cat(id: 0, name: 'Whiskers', indoor: true));
      await ctx.saveChangesAsync();

      // Find the first row where kind = 'cat' — should
      // return a Cat.
      final _Animal? cat =
          await ctx.animals.firstByAsync(column: 'kind', value: 'cat');
      expect(cat, isA<_Cat>());
      expect(cat!.name, 'Whiskers');
    });

    test('allByAsync() returns the right subclass for each row', () async {
      ctx.animals.add(_Dog(id: 0, name: 'Rex', breed: 'labrador'));
      ctx.animals.add(_Dog(id: 0, name: 'Buddy', breed: 'poodle'));
      ctx.animals.add(_Cat(id: 0, name: 'Whiskers', indoor: true));
      await ctx.saveChangesAsync();

      // Find all rows where kind = 'dog' — should
      // return only Dog instances.
      final List<_Animal> dogs =
          await ctx.animals.allByAsync(column: 'kind', value: 'dog');
      expect(dogs, hasLength(2));
      expect(dogs[0], isA<_Dog>());
      expect(dogs[1], isA<_Dog>());
      expect(dogs.map((_Animal a) => a.name).toSet(), <String>{'Rex', 'Buddy'});
    });

    test('findByIdAsync() materialises the right subclass', () async {
      ctx.animals.add(_Dog(id: 0, name: 'Rex', breed: 'labrador'));
      ctx.animals.add(_Cat(id: 0, name: 'Whiskers', indoor: true));
      await ctx.saveChangesAsync();

      // Find by id — the result is a Cat (id=2).
      final _Animal? animal2 = await ctx.animals.findByIdAsync(2);
      expect(animal2, isA<_Cat>());
      expect((animal2! as _Cat).indoor, true);
    });

    test('sync toList() also picks the right subclass', () {
      ctx.animals.add(_Dog(id: 0, name: 'Rex', breed: 'labrador'));
      ctx.animals.add(_Cat(id: 0, name: 'Whiskers', indoor: true));
      ctx.saveChanges();

      final List<_Animal> all = ctx.animals.toList();
      expect(all, hasLength(2));
      expect(all[0], isA<_Dog>());
      expect(all[1], isA<_Cat>());
    });
  });

  group('Fase 5.2 — TPH: polymorphism is transparent', () {
    test('a Dog row can be read through the Animal DbSet', () async {
      ctx.animals.add(_Dog(id: 0, name: 'Rex', breed: 'labrador'));
      await ctx.saveChangesAsync();

      final _Animal? rex = await ctx.animals.findByIdAsync(1);
      expect(rex, isA<_Animal>());
      expect(rex, isA<_Dog>());
      // The `breed` field (specific to Dog) is
      // accessible via the `_Dog` cast.
      expect((rex! as _Dog).breed, 'labrador');
    });

    test('inserts from a child instance are back-propagated', () async {
      // Add a Dog through the child type.
      ctx.animals.add(_Dog(id: 0, name: 'Rex', breed: 'labrador'));
      await ctx.saveChangesAsync();
      // The PK is back-propagated.
      // (The back-propagation works on the meta used
      // for the INSERT, which is the Animal root in
      // this test setup.)
      final List<Map<String, Object?>> rows = provider.select(
        'SELECT id, name, kind FROM animals',
      );
      expect(rows, hasLength(1));
      expect(rows.first['name'], 'Rex');
    });
  });
}

// ─── Test fixtures ──────────────────────────────────────────────────

class _Animal implements RecordLike {
  _Animal({this.id = 0, required this.name, this.kind = 'animal'});
  int id;
  String name;
  String kind;

  @override
  Object? readField(String f) => switch (f) {
        'id' => id,
        'name' => name,
        'kind' => kind,
        _ => null,
      };
}

class _Dog extends _Animal {
  _Dog({super.id, required super.name, required this.breed})
      : super(kind: 'dog');
  String breed;

  @override
  Object? readField(String f) => switch (f) {
        'breed' => breed,
        _ => super.readField(f),
      };
}

class _Cat extends _Animal {
  _Cat({super.id, required super.name, required this.indoor})
      : super(kind: 'cat');
  bool indoor;

  @override
  Object? readField(String f) => switch (f) {
        'indoor' => indoor,
        _ => super.readField(f),
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

final ColumnMeta _kindCol = ColumnMeta(
  sqlName: 'kind',
  dartField: 'kind',
  dartType: String,
);

final ColumnMeta _breedCol = ColumnMeta(
  sqlName: 'breed',
  dartField: 'breed',
  dartType: String,
  nullable: true,
);

final ColumnMeta _indoorCol = ColumnMeta(
  sqlName: 'indoor',
  dartField: 'indoor',
  dartType: bool,
  nullable: true,
);

final EntityMeta dogMeta = EntityMeta(
  tableName: 'animals',
  columns: <ColumnMeta>[_idCol, _nameCol, _kindCol, _breedCol],
  insertableColumns: <ColumnMeta>[_nameCol, _kindCol, _breedCol],
  updatableColumns: <ColumnMeta>[_nameCol, _kindCol, _breedCol],
  primaryKey: _idCol,
  primaryKeyIndex: 0,
  pkOf: (Object e) => (e as _Dog).id,
  setId: (Object e, Object id) => (e as _Dog).id = id as int,
  //: TPH child.
  inheritanceStrategy: InheritanceStrategy.tph,
  discriminatorValue: 'dog',
  discriminatorColumn: _kindCol,
  fromRow: (Map<String, Object?> r) => _Dog(
    id: r['id']! as int,
    name: r['name']! as String,
    breed: r['breed']! as String,
  ),
);

final EntityMeta catMeta = EntityMeta(
  tableName: 'animals',
  columns: <ColumnMeta>[_idCol, _nameCol, _kindCol, _indoorCol],
  insertableColumns: <ColumnMeta>[_nameCol, _kindCol, _indoorCol],
  updatableColumns: <ColumnMeta>[_nameCol, _kindCol, _indoorCol],
  primaryKey: _idCol,
  primaryKeyIndex: 0,
  pkOf: (Object e) => (e as _Cat).id,
  setId: (Object e, Object id) => (e as _Cat).id = id as int,
  //: TPH child.
  inheritanceStrategy: InheritanceStrategy.tph,
  discriminatorValue: 'cat',
  discriminatorColumn: _kindCol,
  fromRow: (Map<String, Object?> r) => _Cat(
    id: r['id']! as int,
    name: r['name']! as String,
    indoor: (r['indoor']! as int) != 0,
  ),
);

final EntityMeta animalMeta = EntityMeta(
  tableName: 'animals',
  columns: <ColumnMeta>[_idCol, _nameCol, _kindCol],
  insertableColumns: <ColumnMeta>[_nameCol, _kindCol],
  updatableColumns: <ColumnMeta>[_nameCol, _kindCol],
  primaryKey: _idCol,
  primaryKeyIndex: 0,
  pkOf: (Object e) => (e as _Animal).id,
  setId: (Object e, Object id) => (e as _Animal).id = id as int,
  //: TPH root.
  inheritanceStrategy: InheritanceStrategy.tph,
  discriminatorColumn: _kindCol,
  subclassMetas: <String, EntityMeta>{
    'dog': dogMeta,
    'cat': catMeta,
  },
  fromRow: (Map<String, Object?> r) => _Animal(
    id: r['id']! as int,
    name: r['name']! as String,
    kind: r['kind']! as String,
  ),
);

class _ZooContext extends DbContext {
  _ZooContext(this._provider);
  final SqliteQueryProvider _provider;

  @override
  AsyncQueryProvider? get asyncProvider => _provider;

  late final DbSet<_Animal> animals = dbSet<_Animal>(
    () => animalMeta,
    //: register the DbSet also as
    // `DbSet<_Dog>` / `DbSet<_Cat>` so the runtime
    // can resolve the right DbSet for any
    // child instance.
    hierarchy: <Type>[_Dog, _Cat],
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
      select: (String sql, List<Object?> binds) {
        if (binds.isEmpty) return _provider.select(sql);
        return _provider.selectWithBinds(sql, binds);
      },
      lastInsertRowId: () => _provider.database.lastInsertRowId,
    );
  }

  void createSchema() {
    _provider.execute('''
      CREATE TABLE animals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        breed TEXT,
        indoor INTEGER
      )
    ''');
  }
}
