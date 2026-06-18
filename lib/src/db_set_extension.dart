//: the `DbSet<T>` IS the queryable entry
// point. The user does:
//
// final adults = await db.set<Person>
// .where(Expr.lambda([...]))
// .toListAsync_;
//
// No `asQueryable` step. The `where`/`orderBy`/`select`/
// `groupBy`/`join`/`take`/`skip` methods on this file
// are extensions on `DbSet<T>` that bridge to the
// underlying `Queryable<T>`. The terminal methods
// (`toListAsync_`, `countAsync_`, …) follow the
// `_*` convention (suffixed underscore to avoid clashes
// with `Iterable`).

import 'package:d_rocket/d_rocket.dart';

import 'sql/query_provider.dart';

/// (the bridge): a `DbSet<T>.asQueryable`
/// extension. Returns a `Queryable<T>` wired to the
/// attached [SqliteQueryProvider].
///
/// Most users don't need this directly — the
/// [DbSetLinqExtension] below exposes the LINQ surface
/// on `DbSet<T>` itself. `asQueryable` is kept for
/// advanced cases (e.g. when the user wants to use a
/// Queryable-specific method that's not on the
/// extension).
///
/// Throws [UnsupportedError] when no
/// [SqliteQueryProvider] is attached.
extension SqliteDbSetExtension<T> on DbSet<T> {
  Queryable<T> asQueryable() {
    final SqliteQueryProvider? fromAttach = get<SqliteQueryProvider>();
    final SqliteQueryProvider? fromAsync =
        asyncProvider as SqliteQueryProvider?;
    final SqliteQueryProvider? provider = fromAttach ?? fromAsync;
    if (provider == null) {
      throw UnsupportedError(
        'DbSet<T>.asQueryable() requires a '
        'SqliteQueryProvider. Use `Db.set<T>()` '
        'instead of creating a DbSet directly — the '
        '`Db` facade auto-attaches the provider.',
      );
    }
    final EntityMeta meta = this.meta;
    if (meta.fromRow == null) {
      throw UnsupportedError(
        'DbSet<T>.asQueryable() requires the codegen-'
        'supplied `EntityMeta.fromRow` (Fase 3.5+). Run '
        'the `d_rocket_builder:table` codegen.',
      );
    }
    return Queryable<T>(
      provider: provider,
      table: meta.tableName,
      meta: meta,
      reader: (Map<String, Object?> row) => meta.fromRow!(row) as T,
      changeTracker: changeTracker,
      asyncProvider: asyncProvider,
    );
  }
}

/// (the LINQ surface): the LINQ operators
/// exposed directly on `DbSet<T>`. Each one returns a
/// `Queryable<T>` (or a typed variant for `select<T2>` /
/// `groupBy<TKey>`), so the user chains them naturally:
///
/// ```dart
/// final adults = await db.set`<Person>`
/// .where(Expr.lambda([Expr.param('p')], p.age >= 18))
/// .orderBy(Expr.lambda([Expr.param('p')], p.name))
/// .take(10)
/// .toListAsync_;
/// ```
///
/// All operators here delegate to the
/// `Queryable<T>` equivalents (which take the
/// trailing-underscore name, e.g. `where_`).
extension DbSetLinqExtension<T> on DbSet<T> {
  ///: `WHERE` clause. Mirrors
  /// [Queryable.where_].
  Queryable<T> where(Expr predicate) => asQueryable().where_(predicate);

  ///: `ORDER BY … ASC`. Mirrors
  /// [Queryable.orderBy_].
  Queryable<T> orderBy(Expr keySelector) => asQueryable().orderBy_(keySelector);

  ///: `ORDER BY … DESC`. Mirrors
  /// [Queryable.orderByDescending_].
  Queryable<T> orderByDescending(Expr keySelector) =>
      asQueryable().orderByDescending_(keySelector);

  ///: `SELECT` projection. Mirrors
  /// [Queryable.select_].
  Queryable<T2> select<T2>(Expr selector) =>
      asQueryable().select_<T2>(selector);

  ///: `LIMIT n`. Mirrors
  /// [Queryable.take_].
  Queryable<T> take(int n) => asQueryable().take_(n);

  ///: `OFFSET n`. Mirrors
  /// [Queryable.skip_].
  Queryable<T> skip(int n) => asQueryable().skip_(n);

  ///: GROUP BY in Dart. Mirrors
  /// [Queryable.groupBy_].
  SqliteGroupedQueryable<TKey, T> groupBy<TKey>({required Expr keySelector}) =>
      asQueryable().groupBy_<TKey>(keySelector: keySelector);

  ///: INNER JOIN. Mirrors [Queryable.join_].
  SqliteJoinedQueryable<TResult> join<TInner, TKey, TResult>({
    required IQueryable<TInner> inner,
    required Expr outerKeySelector,
    required Expr innerKeySelector,
    required Expr resultSelector,
  }) =>
      asQueryable().join_<TInner, TKey, TResult>(
        inner: inner,
        outerKeySelector: outerKeySelector,
        innerKeySelector: innerKeySelector,
        resultSelector: resultSelector,
      );

  ///: LEFT OUTER JOIN grouped. Mirrors
  /// [Queryable.groupJoin_].
  SqliteJoinedQueryable<TResult> groupJoin<TInner, TKey, TResult>({
    required IQueryable<TInner> inner,
    required Expr outerKeySelector,
    required Expr innerKeySelector,
    required Expr resultSelector,
  }) =>
      asQueryable().groupJoin_<TInner, TKey, TResult>(
        inner: inner,
        outerKeySelector: outerKeySelector,
        innerKeySelector: innerKeySelector,
        resultSelector: resultSelector,
      );
}
