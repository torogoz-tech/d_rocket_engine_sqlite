/// Integration tests for the operators added to
/// `Queryable`:
/// - `groupBy_<TKey>({keySelector})`
/// - `join_<TInner, TKey, TResult>({...})`
/// - `groupJoin_<TInner, TKey, TResult>({...})`
///
/// Phase 2.3 design: the outer table's SQL is executed (with any
/// chained `where_`, `orderBy_`, `take_`, `skip_`), and the
/// grouping/joining happens in Dart.
library;

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
// (sqlite3 import removed in — use Map<String, Object?>)
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

class _Post implements RecordLike {
  _Post({required this.id, required this.userId, required this.title});
  final int id;
  final int userId;
  final String title;

  @override
  String toString() => '_Post(id: $id, userId: $userId, title: "$title")';

  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'id' => id,
        'userId' => userId,
        'title' => title,
        _ => null,
      };
}

_Post _postReader(Map<String, Object?> row) => _Post(
      id: row['id']! as int,
      userId: row['userId']! as int,
      title: row['title']! as String,
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
    final insertUser = provider.database.prepare(
      'INSERT INTO users (id, name, age) VALUES (?, ?, ?)',
    );
    insertUser
      ..execute([1, 'Alice', 25])
      ..execute([2, 'Bob', 17])
      ..execute([3, 'Carol', 30])
      ..execute([4, 'Dave', 25])
      ..execute([5, 'Eve', 17]);
    insertUser.close();

    provider.execute('''
      CREATE TABLE posts (
        id     INTEGER PRIMARY KEY,
        userId INTEGER NOT NULL,
        title  TEXT NOT NULL
      )
    ''');
    final insertPost = provider.database.prepare(
      'INSERT INTO posts (id, userId, title) VALUES (?, ?, ?)',
    );
    insertPost
      ..execute([10, 1, 'Hello'])
      ..execute([11, 1, 'World'])
      ..execute([12, 3, 'Dart rocks'])
      ..execute([13, 99, 'Orphan']); // user 99 doesn't exist
    insertPost.close();
  });

  tearDown(() => provider.dispose());

  // ─── groupBy_<TKey> ─────────────────────────────────────────────────

  group('groupBy_<TKey> — grouping', () {
    test('groups by age (basic)', () {
      final groups = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .groupBy_<int>(
            keySelector: Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ),
          )
          .toList_();
      expect(groups.length, 3);
      expect(groups.map((g) => g.key), [25, 17, 30]);
      // First-encounter order: Alice (25), Bob (17), Carol (30),
      // Dave (25, joins Alice's group), Eve (17, joins Bob's group).
      expect(groups[0].length, 2); // Alice, Dave
      expect(groups[1].length, 2); // Bob, Eve
      expect(groups[2].length, 1); // Carol
    });

    test('group.key is the IGrouping key', () {
      final groups = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .groupBy_<int>(
            keySelector: Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ),
          )
          .toList_();
      // Materialize the groups (they're lazy iterables).
      expect(groups[0].key, 25);
      expect(groups[0].toList().map((u) => u.name).toSet(), {'Alice', 'Dave'});
    });

    test('groupBy_ chains with where_ (filter, then group)', () {
      final groups = Queryable<_User>(
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
          .groupBy_<int>(
            keySelector: Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ),
          )
          .toList_();
      // Adults: Alice(25), Carol(30), Dave(25). Two groups.
      expect(groups.map((g) => g.key), [25, 30]);
      expect(groups[0].length, 2); // Alice, Dave
      expect(groups[1].length, 1); // Carol
    });

    test('groupBy_ chains with orderBy_ (sort, then group)', () {
      final groups = Queryable<_User>(
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
          .groupBy_<int>(
            keySelector: Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ),
          )
          .toList_();
      // After ORDER BY age ASC: Bob(17), Eve(17), Alice(25), Dave(25),
      // Carol(30). Groups in first-encounter order: 17, 25, 30.
      expect(groups.map((g) => g.key), [17, 25, 30]);
    });

    test('groupBy_ chains with take_ (limit, then group)', () {
      final groups = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .take_(3)
          .groupBy_<int>(
            keySelector: Expr.lambda(
              [Expr.param('u')],
              Expr.member(Expr.param('u'), 'age'),
            ),
          )
          .toList_();
      // First 3 users: Alice(25), Bob(17), Carol(30). 3 groups.
      expect(groups.map((g) => g.key), [25, 17, 30]);
      expect(groups.every((g) => g.length == 1), true);
    });

    test('count_() returns the number of groups (not rows)', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).groupBy_<int>(
        keySelector: Expr.lambda(
          [Expr.param('u')],
          Expr.member(Expr.param('u'), 'age'),
        ),
      );
      expect(q.count_(), 3); // 3 distinct ages
    });

    test('non-Lambda keySelector throws', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      );
      expect(
        () => q.groupBy_<int>(keySelector: Expr.const_(1)),
        throwsArgumentError,
      );
    });
  });

  // ─── join_<TInner, TKey, TResult> ─────────────────────────────────

  group('join_<TInner, TKey, TResult> — INNER JOIN', () {
    test('basic join: each post → its author name', () {
      // (u, p) => 'u.name + ": " + p.title'
      final result = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .join_<_Post, int, String>(
            inner: Queryable<_Post>(
              provider: provider,
              table: 'posts',
              reader: _postReader,
            ),
            outerKeySelector: Expr.lambda(
              [Expr.param('o')],
              Expr.member(Expr.param('o'), 'id'),
            ),
            innerKeySelector: Expr.lambda(
              [Expr.param('i')],
              Expr.member(Expr.param('i'), 'userId'),
            ),
            resultSelector: Expr.lambda(
              [Expr.param('o'), Expr.param('i')],
              Expr.binary(
                '+',
                Expr.binary(
                  '+',
                  Expr.member(Expr.param('o'), 'name'),
                  Expr.const_(': '),
                ),
                Expr.member(Expr.param('i'), 'title'),
              ),
            ),
          )
          .toList_();
      expect(result, [
        'Alice: Hello',
        'Alice: World',
        'Carol: Dart rocks',
        // Bob and Dave have no posts → no rows.
        // Eve has no posts → no rows.
        // user 99 has no user → orphan not joined.
      ]);
    });

    test('one-to-many produces multiple rows per outer', () {
      // Just count the join.
      final result = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .join_<_Post, int, int>(
            inner: Queryable<_Post>(
              provider: provider,
              table: 'posts',
              reader: _postReader,
            ),
            outerKeySelector: Expr.lambda(
              [Expr.param('o')],
              Expr.member(Expr.param('o'), 'id'),
            ),
            innerKeySelector: Expr.lambda(
              [Expr.param('i')],
              Expr.member(Expr.param('i'), 'userId'),
            ),
            resultSelector: Expr.lambda(
              [Expr.param('o'), Expr.param('i')],
              Expr.const_(1),
            ),
          )
          .toList_();
      // 2 (Alice) + 1 (Carol) = 3 rows.
      expect(result.length, 3);
    });

    test('no matches returns empty', () {
      // Use a different table that has no matching key.
      provider.execute('CREATE TABLE empty_posts (id INTEGER, userId INTEGER)');
      final result = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .join_<_Post, int, String>(
            inner: Queryable<_Post>(
              provider: provider,
              table: 'empty_posts',
              reader: (row) => _Post(
                id: row['id']! as int,
                userId: row['userId']! as int,
                title: '',
              ),
            ),
            outerKeySelector: Expr.lambda(
              [Expr.param('o')],
              Expr.member(Expr.param('o'), 'id'),
            ),
            innerKeySelector: Expr.lambda(
              [Expr.param('i')],
              Expr.member(Expr.param('i'), 'userId'),
            ),
            resultSelector: Expr.lambda(
              [Expr.param('o'), Expr.param('i')],
              Expr.const_('match'),
            ),
          )
          .toList_();
      expect(result, isEmpty);
    });

    test('join_ with d_rocket in-memory inner (EnumerableQuery)', () {
      // The inner can be any IQueryable, including a Dart
      // in-memory one.
      final inMemoryPosts = [
        _Post(id: 1, userId: 2, title: 'in-mem-1'),
        _Post(id: 2, userId: 3, title: 'in-mem-2'),
      ].asQueryable();
      final result = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .join_<_Post, int, String>(
            inner: inMemoryPosts,
            outerKeySelector: Expr.lambda(
              [Expr.param('o')],
              Expr.member(Expr.param('o'), 'id'),
            ),
            innerKeySelector: Expr.lambda(
              [Expr.param('i')],
              Expr.member(Expr.param('i'), 'userId'),
            ),
            resultSelector: Expr.lambda(
              [Expr.param('o'), Expr.param('i')],
              Expr.binary(
                '+',
                Expr.member(Expr.param('o'), 'name'),
                Expr.member(Expr.param('i'), 'title'),
              ),
            ),
          )
          .toList_();
      // Bob(2) + in-mem-1, Carol(3) + in-mem-2.
      expect(result, ['Bobin-mem-1', 'Carolin-mem-2']);
    });

    test('count_() returns the number of joined rows', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).join_<_Post, int, int>(
        inner: Queryable<_Post>(
          provider: provider,
          table: 'posts',
          reader: _postReader,
        ),
        outerKeySelector: Expr.lambda(
          [Expr.param('o')],
          Expr.member(Expr.param('o'), 'id'),
        ),
        innerKeySelector: Expr.lambda(
          [Expr.param('i')],
          Expr.member(Expr.param('i'), 'userId'),
        ),
        resultSelector: Expr.lambda(
          [Expr.param('o'), Expr.param('i')],
          Expr.const_(1),
        ),
      );
      expect(q.count_(), 3);
    });

    test('resultSelector with wrong arity throws', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      );
      expect(
        () => q.join_<_Post, int, String>(
          inner: Queryable<_Post>(
            provider: provider,
            table: 'posts',
            reader: _postReader,
          ),
          outerKeySelector: Expr.lambda(
            [Expr.param('o')],
            Expr.member(Expr.param('o'), 'id'),
          ),
          innerKeySelector: Expr.lambda(
            [Expr.param('i')],
            Expr.member(Expr.param('i'), 'userId'),
          ),
          // 1 param — should be 2.
          resultSelector: Expr.lambda(
            [Expr.param('o')],
            Expr.const_('x'),
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  // ─── groupJoin_<TInner, TKey, TResult> ─────────────────────────────

  group('groupJoin_<TInner, TKey, TResult> — LEFT OUTER JOIN', () {
    test('each user with their list of posts (empty if none)', () {
      // (u, ps, k) => '{u.name}: {ps.length} post(s)'
      // We just verify the structure: 3 users have non-empty groups,
      // 2 users have empty groups.
      final result = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      )
          .groupJoin_<_Post, int, String>(
            inner: Queryable<_Post>(
              provider: provider,
              table: 'posts',
              reader: _postReader,
            ),
            outerKeySelector: Expr.lambda(
              [Expr.param('o')],
              Expr.member(Expr.param('o'), 'id'),
            ),
            innerKeySelector: Expr.lambda(
              [Expr.param('i')],
              Expr.member(Expr.param('i'), 'userId'),
            ),
            resultSelector: Expr.lambda(
              [Expr.param('o'), Expr.param('ps'), Expr.param('k')],
              Expr.binary(
                '+',
                Expr.member(Expr.param('o'), 'name'),
                Expr.binary(
                  '+',
                  Expr.const_(': '),
                  // We need ps.length. Since ps is a List, use the
                  // MethodCall on length.
                  Expr.call(
                    Expr.param('ps'),
                    'length',
                    [],
                  ),
                ),
              ),
            ),
          )
          .toList_();
      // All 5 users should appear.
      expect(result.length, 5);
      expect(result.where((s) => s.startsWith('Alice')), hasLength(1));
      expect(result.where((s) => s.startsWith('Bob')), hasLength(1));
      expect(result.where((s) => s.startsWith('Carol')), hasLength(1));
      expect(result.where((s) => s.startsWith('Dave')), hasLength(1));
      expect(result.where((s) => s.startsWith('Eve')), hasLength(1));
    });

    test('groupJoin_ with where_ on outer (only adults)', () {
      // Each adult with their post count.
      final result = Queryable<_User>(
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
          .groupJoin_<_Post, int, int>(
            inner: Queryable<_Post>(
              provider: provider,
              table: 'posts',
              reader: _postReader,
            ),
            outerKeySelector: Expr.lambda(
              [Expr.param('o')],
              Expr.member(Expr.param('o'), 'id'),
            ),
            innerKeySelector: Expr.lambda(
              [Expr.param('i')],
              Expr.member(Expr.param('i'), 'userId'),
            ),
            resultSelector: Expr.lambda(
              [Expr.param('o'), Expr.param('ps'), Expr.param('k')],
              Expr.call(
                Expr.param('ps'),
                'length',
                [],
              ),
            ),
          )
          .toList_();
      // Adults: Alice (2 posts), Carol (1 post), Dave (0 posts).
      expect(result, [2, 1, 0]);
    });

    test('count_() returns the number of outer rows', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      ).groupJoin_<_Post, int, int>(
        inner: Queryable<_Post>(
          provider: provider,
          table: 'posts',
          reader: _postReader,
        ),
        outerKeySelector: Expr.lambda(
          [Expr.param('o')],
          Expr.member(Expr.param('o'), 'id'),
        ),
        innerKeySelector: Expr.lambda(
          [Expr.param('i')],
          Expr.member(Expr.param('i'), 'userId'),
        ),
        resultSelector: Expr.lambda(
          [Expr.param('o'), Expr.param('ps'), Expr.param('k')],
          Expr.const_(1),
        ),
      );
      expect(q.count_(), 5); // 5 users
    });

    test('resultSelector with wrong arity (2 instead of 3) throws', () {
      final q = Queryable<_User>(
        provider: provider,
        table: 'users',
        reader: _userReader,
      );
      expect(
        () => q.groupJoin_<_Post, int, String>(
          inner: Queryable<_Post>(
            provider: provider,
            table: 'posts',
            reader: _postReader,
          ),
          outerKeySelector: Expr.lambda(
            [Expr.param('o')],
            Expr.member(Expr.param('o'), 'id'),
          ),
          innerKeySelector: Expr.lambda(
            [Expr.param('i')],
            Expr.member(Expr.param('i'), 'userId'),
          ),
          // 2 params — should be 3.
          resultSelector: Expr.lambda(
            [Expr.param('o'), Expr.param('i')],
            Expr.const_('x'),
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  // ─── Error cases for chaining ──────────────────────────────────────

  group('Combinability checks', () {
    test('groupBy_ after select_ throws', () {
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
      expect(
        () => q.groupBy_<int>(
          keySelector: Expr.lambda(
            [Expr.param('g')],
            Expr.const_(1),
          ),
        ),
        throwsStateError,
      );
    });

    test('join_ after select_ throws', () {
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
      expect(
        () => q.join_<_Post, int, String>(
          inner: Queryable<_Post>(
            provider: provider,
            table: 'posts',
            reader: _postReader,
          ),
          outerKeySelector: Expr.lambda(
            [Expr.param('o')],
            Expr.member(Expr.param('o'), 'name'),
          ),
          innerKeySelector: Expr.lambda(
            [Expr.param('i')],
            Expr.member(Expr.param('i'), 'userId'),
          ),
          resultSelector: Expr.lambda(
            [Expr.param('o'), Expr.param('i')],
            Expr.const_('x'),
          ),
        ),
        throwsStateError,
      );
    });
  });
}
