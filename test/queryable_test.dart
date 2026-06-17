/// Integration tests for `Queryable` against a real
/// in-memory SQLite database.
library;

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
// (sqlite3 import removed in — use Map<String, Object?>)
import 'package:test/test.dart';

class _User {
  _User({required this.id, required this.name, required this.age});
  final int id;
  final String name;
  final int age;

  @override
  String toString() => '_User(id: $id, name: "$name", age: $age)';

  @override
  bool operator ==(Object other) =>
      other is _User &&
      other.id == id &&
      other.name == name &&
      other.age == age;
  @override
  int get hashCode => Object.hash(id, name, age);
}

_User _reader(Map<String, Object?> row) => _User(
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
    final insert = provider.database.prepare(
      'INSERT INTO users (id, name, age) VALUES (?, ?, ?)',
    );
    insert
      ..execute([1, 'Alice', 25])
      ..execute([2, 'Bob', 17])
      ..execute([3, 'Carol', 30])
      ..execute([4, 'Dave', 25])
      ..execute([5, 'Eve', 17]);
    insert.close();
  });

  tearDown(() => provider.dispose());

  group('Queryable — basic where_', () {
    test('simple comparison: age > 18', () {
      final r = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      )
          .where_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.binary(
                '>',
                Expr.member(Expr.param('u'), 'age'),
                Expr.const_(18),
              ),
            ),
          )
          .toList_();
      expect(r, hasLength(3));
      expect(r.map((u) => u.id), [1, 3, 4]);
    });

    test('AND of two comparisons', () {
      final r = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      )
          .where_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.binary(
                '&&',
                Expr.binary(
                  '>=',
                  Expr.member(Expr.param('u'), 'age'),
                  Expr.const_(25),
                ),
                Expr.binary(
                  '<=',
                  Expr.member(Expr.param('u'), 'age'),
                  Expr.const_(30),
                ),
              ),
            ),
          )
          .toList_();
      expect(r.map((u) => u.id), [1, 3, 4]);
    });

    test('OR', () {
      final r = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      )
          .where_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.binary(
                '||',
                Expr.binary(
                  '==',
                  Expr.member(Expr.param('u'), 'name'),
                  Expr.const_('Alice'),
                ),
                Expr.binary(
                  '==',
                  Expr.member(Expr.param('u'), 'name'),
                  Expr.const_('Eve'),
                ),
              ),
            ),
          )
          .toList_();
      expect(r.map((u) => u.id), [1, 5]);
    });

    test('startsWith', () {
      final r = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      )
          .where_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.call(
                Expr.member(Expr.param('u'), 'name'),
                'startsWith',
                [Expr.const_('A')],
              ),
            ),
          )
          .toList_();
      expect(r.map((u) => u.id), [1]);
    });

    test('contains', () {
      final r = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      )
          .where_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.call(
                Expr.member(Expr.param('u'), 'name'),
                'contains',
                [Expr.const_('a')],
              ),
            ),
          )
          .toList_();
      expect(r.map((u) => u.id), [3, 4]); // Carol, Dave
    });

    test('endsWith', () {
      final r = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      )
          .where_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.call(
                Expr.member(Expr.param('u'), 'name'),
                'endsWith',
                [Expr.const_('e')],
              ),
            ),
          )
          .toList_();
      // Alice, Dave, Eve end with 'e'. (Carol ends with 'l'.)
      expect(r.map((u) => u.id), [1, 4, 5]);
    });
  });

  group('Queryable — LIMIT and OFFSET', () {
    test('take_(2)', () {
      final r = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      ).take_(2).toList_();
      expect(r.map((u) => u.id), [1, 2]);
    });

    test('skip_(2)', () {
      final r = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      ).skip_(2).toList_();
      expect(r.map((u) => u.id), [3, 4, 5]);
    });

    test('skip_(2).take_(2) (paging)', () {
      final r = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      ).skip_(2).take_(2).toList_();
      expect(r.map((u) => u.id), [3, 4]);
    });

    test('where_ + take_ (filter then limit)', () {
      final r = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      )
          .where_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.binary(
                '>=',
                Expr.member(Expr.param('u'), 'age'),
                Expr.const_(18),
              ),
            ),
          )
          .take_(2)
          .toList_();
      expect(r.map((u) => u.id), [1, 3]); // First 2 adults
    });
  });

  group('Queryable — error handling', () {
    test('non-Lambda where_ throws', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      );
      expect(() => q.where_(Expr.const_(true)), throwsArgumentError);
    });

    test('multi-param Lambda throws', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      );
      final bad = Expr.lambda(
        [Expr.param('u'), Expr.param('v')],
        Expr.const_(true),
      );
      expect(() => q.where_(bad), throwsArgumentError);
    });

    test('param name mismatch throws', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      );
      final bad = Expr.lambda(
        [Expr.param('x')], // alias is 'u', not 'x'
        Expr.const_(1),
      );
      expect(() => q.where_(bad), throwsArgumentError);
    });

    test('SQL error on non-existent column', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      );
      expect(
        () => q
            .where_(
              Expr.lambda(
                [Expr.param('u')],
                Expr.binary(
                  '==',
                  Expr.member(Expr.param('u'), 'nope'),
                  Expr.const_(1),
                ),
              ),
            )
            .toList_(),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  group('Queryable — buildSelect exposes generated SQL', () {
    test('no filter', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      );
      expect(q.buildSelect().sql, 'SELECT * FROM "users"');
      expect(q.buildSelect().binds, isEmpty);
    });

    test('with where_', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      ).where_(
        Expr.lambda(
          [Expr.param('u')],
          Expr.binary(
            '>',
            Expr.member(Expr.param('u'), 'age'),
            Expr.const_(18),
          ),
        ),
      );
      expect(q.buildSelect().sql, 'SELECT * FROM "users" WHERE (age > ?)');
      expect(q.buildSelect().binds, [18]);
    });

    test('with where_ + take_ + skip_', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _reader,
      )
          .where_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.binary(
                '==',
                Expr.member(Expr.param('u'), 'age'),
                Expr.const_(25),
              ),
            ),
          )
          .skip_(2)
          .take_(5);
      expect(q.buildSelect().sql,
          'SELECT * FROM "users" WHERE (age = ?) LIMIT 5 OFFSET 2');
      expect(q.buildSelect().binds, [25]);
    });
  });
}
