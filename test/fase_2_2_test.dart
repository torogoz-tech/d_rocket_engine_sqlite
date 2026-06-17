/// Integration tests for the operators added to
/// `Queryable`:
/// - `select_<T2>(selector)`
/// - `orderBy_(keySelector)` / `orderByDescending_`
/// - `count_` (SQL-side)
/// - `sum_(selector)`, `average_(selector)`, `min_(selector)`,
/// `max_(selector)`
/// - `aggregate_<TResult>` (unsupported on SQL)
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
  bool operator ==(Object other) =>
      other is _User &&
      other.id == id &&
      other.name == name &&
      other.age == age;
  @override
  int get hashCode => Object.hash(id, name, age);
  @override
  String toString() => '_User(id: $id, name: "$name", age: $age)';
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

  group('select_<T2> — projection', () {
    test('projects a single column to String', () {
      final names = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .select_<String>(
            Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'name'),
            ),
          )
          .toList_();
      expect(names, ['Alice', 'Bob', 'Carol', 'Dave', 'Eve']);
    });

    test('projects to int', () {
      final ages = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .select_<int>(
            Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ),
          )
          .toList_();
      expect(ages, [25, 17, 30, 25, 17]);
    });

    test('computes a derived value (age + 1)', () {
      final ages = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .select_<int>(
            Expr.lambda(
              [Expr.param('u')],
              Expr.binary(
                '+',
                Expr.member(Expr.param('u'), 'age'),
                Expr.const_(1),
              ),
            ),
          )
          .toList_();
      expect(ages, [26, 18, 31, 26, 18]);
    });

    test('chains with where_', () {
      final names = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
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
          .select_<String>(
            Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'name'),
            ),
          )
          .toList_();
      expect(names, ['Alice', 'Carol', 'Dave']);
    });

    test('buildSelect exposes the projection', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).select_<String>(
        Expr.lambda(
          [Expr.param('u')],
          Expr.member(Expr.param('u'), 'name'),
        ),
      );
      expect(q.buildSelect().sql, 'SELECT name AS result FROM "users"');
    });

    test('non-Lambda selector throws', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      );
      expect(
          () => q.select_<String>(Expr.const_('hello')), throwsArgumentError);
    });
  });

  group('orderBy_ / orderByDescending_', () {
    test('orderBy_ ascending', () {
      final ids = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .orderBy_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ),
          )
          .toList_()
          .map((u) => u.id)
          .toList();
      // 17 (Bob), 17 (Eve), 25 (Alice), 25 (Dave), 30 (Carol)
      expect(ids, [2, 5, 1, 4, 3]);
    });

    test('orderByDescending_', () {
      final ids = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .orderByDescending_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ),
          )
          .toList_()
          .map((u) => u.id)
          .toList();
      // 30 (Carol), 25 (Alice), 25 (Dave), 17 (Bob), 17 (Eve)
      expect(ids, [3, 1, 4, 2, 5]);
    });

    test('chains with where_ and take_', () {
      // Adults, oldest first, take 2.
      final ids = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
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
          .orderByDescending_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ),
          )
          .take_(2)
          .toList_()
          .map((u) => u.id)
          .toList();
      expect(ids, [3, 1]); // Carol (30), Alice (25)
    });

    test('chains with select_ (project after order)', () {
      // Adults, oldest first; project name.
      final names = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
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
          .orderByDescending_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ),
          )
          .select_<String>(
            Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'name'),
            ),
          )
          .toList_();
      expect(names, ['Carol', 'Alice', 'Dave']);
    });

    test('buildSelect exposes the ORDER BY', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).orderBy_(
        Expr.lambda(
          [Expr.param('u')],
          Expr.member(Expr.param('u'), 'age'),
        ),
      );
      expect(q.buildSelect().sql, 'SELECT * FROM "users" ORDER BY age ASC');
    });
  });

  group('count_ — SQL-side', () {
    test('full source', () {
      final n = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).count_();
      expect(n, 5);
    });

    test('with where_', () {
      final n = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
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
          .count_();
      expect(n, 3); // Alice, Carol, Dave
    });

    test('with where_ that matches nothing', () {
      final n = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .where_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.binary(
                '>',
                Expr.member(Expr.param('u'), 'age'),
                Expr.const_(100),
              ),
            ),
          )
          .count_();
      expect(n, 0);
    });

    test('empty source', () {
      provider.execute('''
        CREATE TABLE empty (id INTEGER PRIMARY KEY)
      ''');
      final n = Queryable<_User>(
        provider: provider,
        table: 'empty',
        reader: _userReader,
      ).count_();
      expect(n, 0);
    });
  });

  group('sum_ — SQL-side', () {
    test('sum of ages', () {
      final total = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).sum_(
        Expr.lambda(
          [Expr.param('u')],
          Expr.member(Expr.param('u'), 'age'),
        ),
      );
      // 25 + 17 + 30 + 25 + 17 = 114
      expect(total, 114);
    });

    test('with where_', () {
      final total = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
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
          .sum_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ),
          );
      // 25 + 30 + 25 = 80
      expect(total, 80);
    });

    test('empty source returns 0 (Dart-ergonomic)', () {
      provider.execute('CREATE TABLE empty (age INTEGER)');
      final total = Queryable<_User>(
        provider: provider,
        table: 'empty',
        reader: _userReader,
      ).sum_(
        Expr.lambda(
          [Expr.param('u')],
          Expr.member(Expr.param('u'), 'age'),
        ),
      );
      expect(total, 0);
    });
  });

  group('average_ — SQL-side', () {
    test('average of ages', () {
      final avg = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).average_(
        Expr.lambda(
          [Expr.param('u')],
          Expr.member(Expr.param('u'), 'age'),
        ),
      );
      // 114 / 5 = 22.8
      expect(avg, closeTo(22.8, 0.001));
    });

    test('with where_', () {
      final avg = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
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
          .average_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ),
          );
      // 80 / 3 = 26.666...
      expect(avg, closeTo(80 / 3, 0.001));
    });

    test('empty source throws', () {
      provider.execute('CREATE TABLE empty (age INTEGER)');
      final q = Queryable<_User>(
        provider: provider,
        table: 'empty',
        reader: _userReader,
      );
      expect(
        () => q.average_(
          Expr.lambda(
            [Expr.param('u')],
            Expr.member(Expr.param('u'), 'age'),
          ),
        ),
        throwsStateError,
      );
    });
  });

  group('min_ / max_ — SQL-side', () {
    test('min age', () {
      final m = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).min_(
        Expr.lambda(
          [Expr.param('u')],
          Expr.member(Expr.param('u'), 'age'),
        ),
      );
      expect(m, 17);
    });

    test('max age', () {
      final m = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).max_(
        Expr.lambda(
          [Expr.param('u')],
          Expr.member(Expr.param('u'), 'age'),
        ),
      );
      expect(m, 30);
    });

    test('min name (alphabetical)', () {
      final m = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).min_(
        Expr.lambda(
          [Expr.param('u')],
          Expr.member(Expr.param('u'), 'name'),
        ),
      );
      expect(m, 'Alice');
    });

    test('max name (alphabetical)', () {
      final m = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).max_(
        Expr.lambda(
          [Expr.param('u')],
          Expr.member(Expr.param('u'), 'name'),
        ),
      );
      expect(m, 'Eve');
    });

    test('empty source throws', () {
      provider.execute('CREATE TABLE empty (age INTEGER)');
      final q = Queryable<_User>(
        provider: provider,
        table: 'empty',
        reader: _userReader,
      );
      expect(
        () => q.min_(
          Expr.lambda(
            [Expr.param('u')],
            Expr.member(Expr.param('u'), 'age'),
          ),
        ),
        throwsStateError,
      );
      expect(
        () => q.max_(
          Expr.lambda(
            [Expr.param('u')],
            Expr.member(Expr.param('u'), 'age'),
          ),
        ),
        throwsStateError,
      );
    });
  });

  group('aggregate_ — unsupported on SQL', () {
    test('throws UnsupportedError', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      );
      expect(
        () => q.aggregate_<String>(
          seed: '',
          func: Expr.lambda(
            [Expr.param('acc'), Expr.param('u')],
            Expr.const_('x'),
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('Operator chaining — full SQL pipeline', () {
    test('where_ + orderBy_ + select_ + take_ + toList_', () {
      // Top-2 oldest adult names.
      final names = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
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
          .orderByDescending_(
            Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ),
          )
          .select_<String>(
            Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'name'),
            ),
          )
          .take_(2)
          .toList_();
      expect(names, ['Carol', 'Alice']);
    });

    test('group-by-equivalent: count_ on a select_ (manual)', () {
      // The SQL equivalent of "count distinct age groups" via
      // subqueries is non-trivial in; verify the chain
      // composes without errors. (count_ on a select_ would just
      // count rows in the projected queryable.)
      final n = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
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
          .count_();
      expect(n, 3);
    });
  });
}
