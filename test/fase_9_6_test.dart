/// — new LINQ operators integration tests:
/// - `firstAsync_` / `firstOrDefaultAsync_`
/// - `anyAsync_` / `allAsync_`
/// - `thenBy_` / `thenByDescending_` (chainable ORDER BY)
/// - `distinct_` (SELECT DISTINCT)
library;

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

class _User implements RecordLike {
  _User({required this.id, required this.name, required this.age});
  final int id;
  final String name;
  final int age;

  @override
  bool operator ==(Object other) =>
      other is _User &&
      other.id == id &&
      other.name == name &&
      other.age == age;
  @override
  int get hashCode => Object.hash(id, name, age);
  @override
  String toString() => '_User(id: $id, name: "$name", age: $age)';

  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'id' => id,
        'name' => name,
        'age' => age,
        _ => null,
      };
}

_User _userReader(Map<String, Object?> row) => _User(
      id: row['id']! as int,
      name: row['name']! as String,
      age: row['age']! as int,
    );

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  late SqliteQueryProvider provider;

  setUp(() {
    provider = SqliteQueryProvider.inMemory();
    provider.execute('''
      CREATE TABLE users (
        id    INTEGER PRIMARY KEY,
        name  TEXT NOT NULL,
        age   INTEGER NOT NULL
      )
    ''');
    // Seed: 4 users ( appears twice with different ages).
    provider.execute(
      "INSERT INTO users (id, name, age) VALUES (1, 'Abner', 30)",
    );
    provider.execute(
      "INSERT INTO users (id, name, age) VALUES (2, 'Maria', 25)",
    );
    provider.execute(
      "INSERT INTO users (id, name, age) VALUES (3, 'Abner', 28)",
    );
    provider.execute(
      "INSERT INTO users (id, name, age) VALUES (4, 'Jose', 35)",
    );
  });

  // ─── firstAsync_ / firstOrDefaultAsync_ ─────────────────────

  group('Fase 9.6 — firstAsync_ / firstOrDefaultAsync_', () {
    test('firstAsync_ returns the first row matching the predicate', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      ).where_(Expr.lambda(
        <Expr>[Expr.param('u')],
        Expr.binary(
          '>',
          Expr.member(Expr.param('u'), 'age'),
          Expr.const_(20),
        ),
      ));
      final _User first = await q.firstAsync_();
      // The first row by insertion order with age > 20 is (30).
      expect(first.name, 'Abner');
      expect(first.age, 30);
    });

    test('firstAsync_ throws StateError when no rows match', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      ).where_(Expr.lambda(
        <Expr>[Expr.param('u')],
        Expr.binary(
          '>',
          Expr.member(Expr.param('u'), 'age'),
          Expr.const_(100),
        ),
      ));
      expect(q.firstAsync_(), throwsStateError);
    });

    test('firstOrDefaultAsync_ returns null when no rows match', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      ).where_(Expr.lambda(
        <Expr>[Expr.param('u')],
        Expr.binary(
          '>',
          Expr.member(Expr.param('u'), 'age'),
          Expr.const_(100),
        ),
      ));
      final _User? none = await q.firstOrDefaultAsync_();
      expect(none, isNull);
    });
  });

  // ─── anyAsync_ / allAsync_ ─────────────────────────────────

  group('Fase 9.6 — anyAsync_ / allAsync_', () {
    test('anyAsync_ returns true when rows match the predicate', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      ).where_(Expr.lambda(
        <Expr>[Expr.param('u')],
        Expr.binary(
          '==',
          Expr.member(Expr.param('u'), 'name'),
          Expr.const_('Abner'),
        ),
      ));
      expect(await q.anyAsync_(), isTrue);
    });

    test('anyAsync_ returns false when no rows match', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      ).where_(Expr.lambda(
        <Expr>[Expr.param('u')],
        Expr.binary(
          '==',
          Expr.member(Expr.param('u'), 'name'),
          Expr.const_('NoSuch'),
        ),
      ));
      expect(await q.anyAsync_(), isFalse);
    });

    test('allAsync_ returns true when every row matches', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      );
      // All ages are > 0.
      expect(
        await q.allAsync_(Expr.lambda(
          <Expr>[Expr.param('u')],
          Expr.binary(
            '>',
            Expr.member(Expr.param('u'), 'age'),
            Expr.const_(0),
          ),
        )),
        isTrue,
      );
    });

    test('allAsync_ returns false when at least one row fails', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      );
      // Not all users are named ''.
      expect(
        await q.allAsync_(Expr.lambda(
          <Expr>[Expr.param('u')],
          Expr.binary(
            '==',
            Expr.member(Expr.param('u'), 'name'),
            Expr.const_('Abner'),
          ),
        )),
        isFalse,
      );
    });
  });

  // ─── thenBy_ / thenByDescending_ ───────────────────────────

  group('Fase 9.6 — thenBy_ / thenByDescending_', () {
    test('thenBy_ requires a preceding orderBy_', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      );
      expect(
        () => q.thenBy_(Expr.lambda(
          <Expr>[Expr.param('u')],
          Expr.member(Expr.param('u'), 'age'),
        )),
        throwsStateError,
      );
    });

    test('thenBy_ chains a secondary ASC key', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      )
          .orderBy_(Expr.lambda(
            <Expr>[Expr.param('u')],
            Expr.member(Expr.param('u'), 'name'),
          ))
          .thenBy_(Expr.lambda(
            <Expr>[Expr.param('u')],
            Expr.member(Expr.param('u'), 'age'),
          ));
      final List<_User> users = await q.toListAsync_();
      // Ordered by name ASC: (28), (30), Jose(35), Maria(25).
      // Within the same name, by age ASC.
      expect(users.map((_User u) => '${u.name}/${u.age}').toList(), <String>[
        'Abner/28',
        'Abner/30',
        'Jose/35',
        'Maria/25',
      ]);
    });

    test('thenByDescending_ chains a secondary DESC key', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      )
          .orderBy_(Expr.lambda(
            <Expr>[Expr.param('u')],
            Expr.member(Expr.param('u'), 'name'),
          ))
          .thenByDescending_(Expr.lambda(
            <Expr>[Expr.param('u')],
            Expr.member(Expr.param('u'), 'age'),
          ));
      final List<_User> users = await q.toListAsync_();
      // Within the same name, by age DESC.
      expect(users.map((_User u) => '${u.name}/${u.age}').toList(), <String>[
        'Abner/30',
        'Abner/28',
        'Jose/35',
        'Maria/25',
      ]);
    });
  });

  // ─── distinct_ ─────────────────────────────────────────────

  group('Fase 9.6 — distinct_', () {
    test('distinct_ drops duplicate rows', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      ).distinct_();
      final List<_User> users = await q.toListAsync_();
      // Without distinct, there are 4 rows. With distinct on `*`,
      // duplicates of every column would be dropped, but our
      // seeded rows have different (id, name, age) tuples — so
      // distinct keeps all 4.
      expect(users, hasLength(4));
    });

    test('distinct_ after select_ projects distinct values', () async {
      // Use `select_<String>` to project the name, then distinct.
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      )
          .select_<String>(Expr.lambda(
            <Expr>[Expr.param('u')],
            Expr.member(Expr.param('u'), 'name'),
          ))
          .distinct_();
      final List<String> names = await q.toListAsync_();
      // 4 users, 3 distinct names:, Maria, Jose.
      expect(names.toSet(), <String>{'Abner', 'Maria', 'Jose'});
    });
  });

  // ─── selectMany_ (CROSS JOIN) ─────────────────────────────

  group('Fase 9.6.1 — selectMany_', () {
    test('CROSS JOIN flattens (outer × inner) pairs', () {
      final outer = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      );
      final inner = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      );
      // 4 users → 4 × 4 = 16 pairs.
      final pairs = outer
          .selectMany_<_User, int>(
            inner: inner,
            resultSelector: Expr.lambda(
              <Expr>[Expr.param('o'), Expr.param('i')],
              Expr.binary(
                '+',
                Expr.member(Expr.param('o'), 'age'),
                Expr.member(Expr.param('i'), 'age'),
              ),
            ),
          )
          .toList_();
      // 4 outer × 4 inner = 16 pairs. The selector
      // computes `o.age + i.age` (an `int`).
      expect(pairs, hasLength(16));
      // Spot-check: first pair is (1, 1) ages 30+30 = 60.
      expect(pairs.first, 60);
    });
  });

  // ─── union_ / intersect_ / except_ ────────────────────────

  group('Fase 9.6.1 — union_ / intersect_ / except_', () {
    test('union_ concatenates both sides', () {
      final left = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).where_(Expr.lambda(
        <Expr>[Expr.param('u')],
        Expr.binary(
          '==',
          Expr.member(Expr.param('u'), 'name'),
          Expr.const_('Abner'),
        ),
      ));
      final right = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).where_(Expr.lambda(
        <Expr>[Expr.param('u')],
        Expr.binary(
          '==',
          Expr.member(Expr.param('u'), 'name'),
          Expr.const_('Maria'),
        ),
      ));
      final List<_User> combined = left.union_(right).toList_();
      // Left has 2 rows, right has 1 Maria row.
      expect(combined, hasLength(3));
    });

    test('intersect_ keeps only common rows', () {
      final left = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      );
      final right = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).where_(Expr.lambda(
        <Expr>[Expr.param('u')],
        Expr.binary(
          '==',
          Expr.member(Expr.param('u'), 'name'),
          Expr.const_('Abner'),
        ),
      ));
      // Left = all 4 users, right = 2 rows. The
      // intersect by identity (== on the whole _User
      // object) keeps the 2 rows.
      final List<_User> common = left.intersect_(right).toList_();
      expect(common, hasLength(2));
    });

    test('except_ removes right-side rows from left', () {
      final left = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      );
      final right = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).where_(Expr.lambda(
        <Expr>[Expr.param('u')],
        Expr.binary(
          '==',
          Expr.member(Expr.param('u'), 'name'),
          Expr.const_('Abner'),
        ),
      ));
      // Left = 4 users, right = 2 rows. except_
      // returns the 2 non- rows.
      final List<_User> rest = left.except_(right).toList_();
      expect(rest, hasLength(2));
    });
  });

  // ───: reverse_ / toLookup_ / zip_ ───────────────

  group('Fase 9.7 — reverse_', () {
    test('reverse_ emits rows in reverse rowid order', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      ).reverse_();
      final List<_User> users = await q.toListAsync_();
      // Insertion order: (30), Maria(25), (28), Jose(35).
      // rowid order reversed: Jose(35), (28), Maria(25), (30).
      expect(users.map((_User u) => u.name).toList(), <String>[
        'Jose',
        'Abner',
        'Maria',
        'Abner',
      ]);
    });
  });

  group('Fase 9.7 — toLookup_', () {
    test('toLookup_ groups by key with multiple values per key', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      );
      final ILookup<String, _User> byName = q.toLookup_<String>(
        keySelector: Expr.lambda(
          <Expr>[ParamExpr('u')],
          Expr.member(ParamExpr('u'), 'name'),
        ),
      );
      // appears 2x, Maria 1x, Jose 1x.
      expect(byName['Abner'].length, 2);
      expect(byName['Maria'].length, 1);
      expect(byName['Jose'].length, 1);
      expect(byName.containsKey('NoSuch'), isFalse);
      expect(byName.length, 3); // 3 distinct keys
    });
  });

  group('Fase 9.7 — zip_', () {
    test('zip_ combines element-wise up to the shorter side', () {
      final left = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).where_(Expr.lambda(
        <Expr>[ParamExpr('u')],
        Expr.binary(
          '==',
          Expr.member(ParamExpr('u'), 'name'),
          Expr.const_('Abner'),
        ),
      ));
      final right = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).where_(Expr.lambda(
        <Expr>[ParamExpr('u')],
        Expr.binary(
          '==',
          Expr.member(ParamExpr('u'), 'name'),
          Expr.const_('Maria'),
        ),
      ));
      // 2 rows vs 1 Maria row → 1 pair (shorter side).
      final List<(_User, _User)> pairs = left.zip_<_User>(right);
      expect(pairs, hasLength(1));
    });
  });

  // ───: closure LINQ ──────────────────────────────

  group('Fase 9.8 — closure where_ / orderBy_', () {
    test('closure where_ runs as in-memory filter', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      ).where_((_User u) => u.age >= 30);
      // Closure: keep only users with age >= 30 (=30, Jose=35).
      final List<_User> users = await q.toListAsync_();
      expect(users.map((_User u) => u.name).toSet(), <String>{'Abner', 'Jose'});
    });

    test('closure where_ composes with SQL where_', () async {
      // SQL filter: name == '' (2 rows)
      // then closure filter: age > 28 (1 row: (30))
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      )
          .where_(Expr.lambda(
            <Expr>[ParamExpr('u')],
            Expr.binary(
              '==',
              Expr.member(ParamExpr('u'), 'name'),
              Expr.const_('Abner'),
            ),
          ))
          .where_((_User u) => u.age > 28);
      final List<_User> users = await q.toListAsync_();
      expect(users, hasLength(1));
      expect(users.first.age, 30);
    });

    test('closure orderBy_ sorts in memory', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      ).orderBy_((_User u) => u.age);
      final List<_User> users = await q.toListAsync_();
      // By age ASC: Maria(25), (28), (30), Jose(35).
      expect(users.map((_User u) => u.age).toList(), <int>[25, 28, 30, 35]);
    });

    test('closure orderByDescending_ sorts in memory DESC', () async {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
        asyncProvider: provider,
      ).orderByDescending_((_User u) => u.age);
      final List<_User> users = await q.toListAsync_();
      expect(users.map((_User u) => u.age).toList(), <int>[35, 30, 28, 25]);
    });
  });
}
