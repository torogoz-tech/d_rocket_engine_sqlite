/// A SQL-backed [IQueryable] implementation.
///
/// In the queryable supports:
///
/// * `where_(predicate)` — appends a WHERE clause.
/// * `select_<T2>(selector)` — appends a projection (`SELECT expr AS
/// result FROM …`).
/// * `orderBy_(keySelector)` / `orderByDescending_` — append
/// `ORDER BY` (multi-column via chaining).
/// * `take_(n)` / `skip_(n)` — append LIMIT / OFFSET.
/// * `groupBy_<TKey>({keySelector})` — group rows by a key
/// (materialized in Dart over the SQL-fetched rows).
/// * `join_<TInner, TKey, TResult>({...})` — INNER JOIN,
/// materialized in Dart.
/// * `groupJoin_<TInner, TKey, TResult>({...})` — LEFT OUTER JOIN,
/// materialized in Dart.
/// * `toList_` — executes and materializes.
/// * `count_` — SQL-side `SELECT COUNT(*) FROM …`.
/// * `sum_(selector)` / `average_(selector)` / `min_(selector)` /
/// `max_(selector)` — SQL-side aggregates.
///
/// Phase 2.3 design note: the `groupBy_` / `join_` / `groupJoin_`
/// operators build a `SELECT *` SQL statement on the outer table
/// (with the chained `where_`, `orderBy_`, `take_`, `skip_`),
/// execute it, and then perform the grouping/joining in Dart.
/// The result is a new queryable (grouped or joined) that is
/// itself iterable but does not support further SQL operators —
/// the d_rocket in-memory operators (e.g. `where_(...)` from
/// `package:d_rocket/d_rocket.dart`) can be applied to it.
library;

import 'dart:async';

import 'package:d_rocket/d_rocket.dart';

import 'sql/query_provider.dart';
import 'sql/sqlite_dialect.dart';
// (no sqlite3 import — sqflite uses Map<String, Object?>)

/// The single shared [SqliteDialect] instance
/// used by every [SqlTranslator] in this
/// engine. Const, so the engine has zero
/// dialect-state per query.
const SqlDialect _kDialect = SqliteDialect();

/// A function that maps a `Row` to a user value of type [T].
typedef ResultRowReader<T> = T Function(Map<String, Object?> row);

/// helper: top-level error stub used
/// when the user hasn't supplied `EntityMeta.fromRow`
/// (the codegen would normally emit this for every
/// `@Table` class). Lives at the top level (not
/// a method) so it can be referenced from an
/// initialiser (instance methods cannot).
T _mapReaderFallback<T>(Map<String, Object?> row) =>
    throw StateError('EntityMeta.fromRow is null');

/// One entry in the ORDER BY chain.
class _OrderByClause {
  final LambdaExpr selector;
  final bool descending;
  const _OrderByClause(this.selector, {required this.descending});
}

/// (closure LINQ): a single in-memory
/// `ORDER BY` entry. The `key` is a closure
/// `(T) => Comparable` extracted from the row at
/// materialisation time. The `descending` flag flips
/// the ordering at sort time.
class _MemOrderByClause<T> {
  final Comparable Function(T) key;
  final bool descending;
  const _MemOrderByClause(this.key, {required this.descending});
}

/// Internal: a (key, items) pair produced by `groupBy_`.
class _SqlGrouping<TKey, T> extends Iterable<T> implements IGrouping<TKey, T> {
  _SqlGrouping(this.key, this._items);
  @override
  final TKey key;
  final List<T> _items;
  @override
  Iterator<T> get iterator => _items.iterator;
  @override
  Object? readField(String fieldName) => switch (fieldName) {
        'key' => key,
        'length' => length,
        _ => null,
      };
}

/// Internal: parameters of a `join_` or `groupJoin_` call.
///
/// Exactly one of the two forms is set:
/// * AST: [outerKey] + [innerKey] + [result] are
///   non-null [LambdaExpr]s. The lambdas are
///   evaluated in Dart to compute the key / result.
/// * Closure: [outerKeyClosure] + [innerKeyClosure] +
///   [resultClosure] are non-null closures. The
///   closures are invoked directly on the
///   materialised rows.
///
/// Mixing forms is not allowed and is rejected by
/// the constructor.
class _JoinOp {
  final IQueryable<dynamic> inner;
  final bool isGroupJoin;

  //: AST form.
  final LambdaExpr? outerKey;
  final LambdaExpr? innerKey;
  final LambdaExpr? result;

  //: closure form. The Dart-typed
  // signatures (TKey Function(TOuter),
  // TKey Function(TInner), TResult
  // Function(TOuter, TInner) — or the
  // three-arg groupJoin variant) are
  // checked at the call site; internally
  // we treat them as `Function?` and cast
  // when invoking.
  final Function? outerKeyClosure;
  final Function? innerKeyClosure;
  final Function? resultClosure;

  const _JoinOp({
    required this.inner,
    required this.isGroupJoin,
    this.outerKey,
    this.innerKey,
    this.result,
    this.outerKeyClosure,
    this.innerKeyClosure,
    this.resultClosure,
  }) : assert(
          (outerKey != null && innerKey != null && result != null) !=
              (outerKeyClosure != null &&
                  innerKeyClosure != null &&
                  resultClosure != null),
          '_JoinOp: exactly one of (outerKey+innerKey+result) '
          'or (outerKeyClosure+innerKeyClosure+resultClosure) '
          'must be set',
        );
}

// ────────────────────────────────────────────────────────────────────
// Queryable<T> — single-table, all SQL-backed.
// ────────────────────────────────────────────────────────────────────

/// A SQL-backed [IQueryable] over a single table.
///
/// `Queryable<T>` is a queryable whose `iterator` lazy-builds
/// and executes a SQL statement. Each operator call (`where_`,
/// `select_`, `orderBy_`, `take_`, `skip_`) returns a *new*
/// `Queryable` with the operation added; nothing happens until
/// a terminal operator (`toList_`, `count_`, etc.) is called.
///
/// `groupBy_`, `join_`, and `groupJoin_` return a different
/// [IQueryable] subtype ([SqliteGroupedQueryable] or
/// [SqliteJoinedQueryable]) because the grouping/joining happens
/// in Dart on top of the SQL-fetched rows.
class Queryable<T> extends IQueryable<T> {
  final SqliteQueryProvider _provider;
  final String _table;
  final ResultRowReader<T> _reader;

  ///: optional [AsyncQueryProvider] for
  /// the `*Async_` terminal methods (`toListAsync_`,
  /// `countAsync_`, `firstOrDefaultAsync_`,
  /// `toListWithJoinsAsync_`). When `null`, the `*Async_`
  /// methods throw [StateError]. Propagated through
  /// every operator (`where_`, `orderBy_`, etc.) so
  /// that chained LINQ pipelines retain the async
  /// provider.
  final AsyncQueryProvider? _asyncProvider;

  ///: optional [ChangeTracker] the
  /// queryable subscribes to when [watch] is called.
  /// When the tracker fires a [ChangeEvent], [watch]
  /// re-runs the query and emits the new result list.
  final ChangeTracker? _changeTracker;

  /// The pending `WHERE` predicate, or `null` if none.
  final LambdaExpr? _where;

  /// The pending `SELECT` projection, or `null` if none.
  final LambdaExpr? _select;

  ///: `true` if a `SELECT DISTINCT` was
  /// chained (the `distinct_` operator). Default `false`.
  final bool _distinct;

  /// The pending `ORDER BY` chain (in order of precedence).
  final List<_OrderByClause> _orderBy;

  /// LIMIT value (positive) or `null`.
  final int? _take;

  /// OFFSET value (non-negative) or `null`.
  final int? _skip;

  /// (closure LINQ): in-memory filters
  /// applied AFTER the SQL `WHERE`. Each entry is a
  /// `(T) => bool` predicate the user provided via
  /// the closure overload `where_((t) => …)`.
  ///
  /// Semantics: SQL filter runs first (efficient);
  /// in-memory filters run on the smaller result.
  final List<bool Function(T)> _memFilters;

  /// (closure LINQ): in-memory `ORDER BY`.
  /// Each entry is `(T) => Comparable` key. The list
  /// is applied in order (primary, secondary, …).
  /// Descending is supported via [bool] flag.
  final List<_MemOrderByClause<T>> _memOrderBy;

  /// (closure LINQ): in-memory `LIMIT` /
  /// `OFFSET` applied AFTER the SQL pagination. When
  /// the user chains `.take_(n)` as a closure (e.g.
  /// `.take_( => 5)`), we don't translate to SQL —
  /// we apply in memory. For now, take_/skip_ remain
  /// SQL-only (see notes on the closure overloads).
  // (Intentionally no _memTake / _memSkip — they are
  // applied in Dart after SQL by reading the existing
  // _take / _skip fields.)

  /// (closure LINQ): in-memory `SELECT`
  /// projection. When the user calls
  /// `q.select_<T2>((t) => …)` (the closure
  /// overload), the closure is stored here and the
  /// [_memProjectSource] holds the pre-select source
  /// queryable. The materialize step then runs the
  /// source (with the original `where_` / `orderBy_` /
  /// `take_` / `skip_` pipeline) and maps the result
  /// rows through [_memProject] to produce the
  /// current `T`. The AST path (`q.select_(Expr…)`)
  /// continues to project in SQL via the
  /// [_select] lambda and is mutually exclusive with
  /// this field.
  final Function? _memProject;

  /// (closure LINQ): the pre-select
  /// source queryable. See [_memProject].
  final Queryable<dynamic>? _memProjectSource;

  /// The EntityMeta of the source table. Used by
  /// `toListWithJoins` to find the PK column
  /// name (so the JOIN rows can be deduped by PK).
  final EntityMeta _meta;

  /// The Map-based reader (`T Function(Map<String,
  /// Object?>)`) derived from the codegen-emitted
  /// `EntityMeta.fromRow`. Used by `toListWithJoins`
  /// to materialise entities from the JOIN
  /// result rows (which are `Map`-shaped, not `Row`-
  /// shaped). Initialised in the constructor body.
  late final T Function(Map<String, Object?>) _mapReader;

  Queryable._(
    this._provider,
    this._table,
    this._reader, {
    required EntityMeta meta,
    LambdaExpr? where,
    LambdaExpr? select,
    bool distinct = false,
    List<_OrderByClause>? orderBy,
    int? take,
    int? skip,
    ChangeTracker? changeTracker,
    AsyncQueryProvider? asyncProvider,
    List<bool Function(T)>? memFilters,
    List<_MemOrderByClause<T>>? memOrderBy,
    Function? memProject,
    Queryable<dynamic>? memProjectSource,
  })  : _meta = meta,
        _where = where,
        _select = select,
        _distinct = distinct,
        _orderBy = orderBy ?? const [],
        _take = take,
        _skip = skip,
        _changeTracker = changeTracker,
        //: propagate the async provider
        // through every operator.
        _asyncProvider = asyncProvider,
        _memProject = memProject,
        _memProjectSource = memProjectSource,
        //: in-memory layer (closure LINQ).
        _memFilters = memFilters ?? const [],
        _memOrderBy = memOrderBy ?? const [] {
    _mapReader = (Map<String, Object?> row) {
      final fromRow = meta.fromRow;
      if (fromRow == null) return _mapReaderFallback<T>(row);
      return fromRow(row) as T;
    };
  }

  /// Creates a fresh queryable over [table]. [reader] maps a
  /// `Row` to a value of type [T].
  ///
  /// [changeTracker] is optional . When set,
  /// the user can call [watch] to obtain a `Stream<List<T>>`
  /// that re-emits whenever the tracker reports a
  /// [ChangeEvent] for any entity in the context.
  factory Queryable({
    required SqliteQueryProvider provider,
    required String table,
    required ResultRowReader<T> reader,
    EntityMeta? meta,
    ChangeTracker? changeTracker,
    AsyncQueryProvider? asyncProvider,
  }) =>
      Queryable._(
        provider,
        table,
        reader,
        meta: meta ??
            EntityMeta(
              tableName: table,
              columns: const <ColumnMeta>[],
              insertableColumns: const <ColumnMeta>[],
              updatableColumns: const <ColumnMeta>[],
              primaryKey: const ColumnMeta(
                sqlName: 'id',
                dartField: 'id',
                dartType: int,
              ),
              primaryKeyIndex: 0,
              pkOf: (Object e) => null,
            ),
        changeTracker: changeTracker,
        asyncProvider: asyncProvider,
      );

  @override
  IQueryProvider get provider => EnumerableQueryProvider.instance;

  @override
  Expr? get expression => _where;

  @override
  Iterator<T> get iterator {
    // Lazy: returns an iterator over the materialized list. Used
    // when d_rocket operators (e.g. `where_` from
    // `package:d_rocket/d_rocket.dart`) are applied on top of us and
    // the in-memory fallback path pulls the rows.
    return toList_().iterator;
  }

  /// Exposed for use by [SqliteGroupedQueryable] and
  /// [SqliteJoinedQueryable] which live in the same file. Not part
  /// of the public API.
  ResultRowReader<T> get reader => _reader;

  /// Exposed for use by [SqliteGroupedQueryable] and
  /// [SqliteJoinedQueryable]. Not part of the public API.
  SqliteQueryProvider get db => _provider;

  // ─── Operators (instance methods, not extensions) ─────────────────

  /// Appends a `WHERE` filter. Accepts either:
  ///
  /// * an `Expr` (translates to SQL `WHERE`); or
  /// * a closure `(T) => bool` (runs in memory AFTER
  /// the SQL has materialised).
  ///
  ///: the closure overload was added so
  /// the user can write
  /// `q.where_((t) => t.status == 0)` instead of
  /// `q.where_(Expr.lambda([...], …))`. The two
  /// compose: SQL filter runs first, then the
  /// in-memory filter on the smaller result.
  Queryable<T> where_(Object predicate) {
    //: closure path.
    if (predicate is bool Function(T)) {
      return Queryable._(
        _provider,
        _table,
        _reader,
        meta: _meta,
        where: _where,
        select: _select,
        distinct: _distinct,
        orderBy: _orderBy,
        take: _take,
        skip: _skip,
        changeTracker: _changeTracker,
        asyncProvider: _asyncProvider,
        memFilters: <bool Function(T)>[..._memFilters, predicate],
      );
    }
    //: SQL path (Expr → LambdaExpr).
    final lambda = _requireLambda('where_', predicate as Expr);
    if (_where != null) {
      throw StateError(
        'Queryable.where_: only one SQL WHERE clause is '
        'supported. Combine multiple Expr predicates '
        'with AND/OR, or chain a closure `where_` after.',
      );
    }
    return Queryable._(
      _provider,
      _table,
      _reader,
      meta: _meta,
      where: lambda,
      select: _select,
      distinct: _distinct,
      orderBy: _orderBy,
      take: _take,
      skip: _skip,
      changeTracker: _changeTracker, // **Fase 4.2**
      asyncProvider: _asyncProvider, // **Fase 5.0+3**
    );
  }

  /// Projects each row to a single value.
  ///
  /// Accepts either an [Expr] (translated to
  /// `SELECT expr AS result FROM …` in SQL — the
  /// efficient path) or a closure `T2 Function(T)`
  /// (the source is materialised first, then the
  /// closure maps each row to `T2` in Dart). The two
  /// compose: chaining `where_` (AST or closure)
  /// before `select_` (closure) means the source
  /// filter runs first and the closure only sees
  /// the surviving rows.
  Queryable<T2> select_<T2>(Object selector) {
    //: closure path.
    if (selector is T2 Function(T)) {
      // The closure-path materialize step goes through
      // [_memProjectSource]. The reader stored on the
      // new queryable is therefore a type-system
      // placeholder: we wrap [_reader] in a fresh
      // closure so the runtime type matches
      // `ResultRowReader<T2>` without going through an
      // `as` cast (which would fail at runtime when T2
      // is a different concrete type than the source
      // T). The body of the wrapper is never invoked
      // in the closure path.
      // ignore: prefer_function_declarations_over_variables
      final ResultRowReader<T2> placeholderReader =
          (Map<String, Object?> row) => _reader(row) as T2;
      return Queryable<T2>._(
        _provider,
        _table,
        placeholderReader,
        meta: _meta,
        where: _where,
        orderBy: _orderBy,
        take: _take,
        skip: _skip,
        changeTracker: _changeTracker,
        asyncProvider: _asyncProvider,
        memProject: selector,
        memProjectSource: this,
      );
    }
    //: AST path (Expr → LambdaExpr → SQL projection).
    final lambda = _requireLambda('select_', selector as Expr);
    return Queryable<T2>._(
      _provider,
      _table,
      (row) => row['result'] as T2,
      meta: _meta,
      where: _where,
      select: lambda,
      orderBy: _orderBy,
      take: _take,
      skip: _skip,
      changeTracker: _changeTracker, // **Fase 4.2**
      asyncProvider: _asyncProvider, // **Fase 5.0+3**
    );
  }

  /// Appends `ORDER BY <key> ASC`.:
  /// also accepts a closure `(T) => Comparable`
  /// for in-memory sorting.
  Queryable<T> orderBy_(Object keySelector) {
    if (keySelector is Comparable Function(T)) {
      return Queryable._(
        _provider,
        _table,
        _reader,
        meta: _meta,
        where: _where,
        select: _select,
        distinct: _distinct,
        orderBy: _orderBy,
        take: _take,
        skip: _skip,
        changeTracker: _changeTracker,
        asyncProvider: _asyncProvider,
        memOrderBy: <_MemOrderByClause<T>>[
          ..._memOrderBy,
          _MemOrderByClause<T>(keySelector, descending: false),
        ],
      );
    }
    final lambda = _requireLambda('orderBy_', keySelector as Expr);
    return Queryable._(
      _provider,
      _table,
      _reader,
      meta: _meta,
      where: _where,
      select: _select,
      distinct: _distinct,
      orderBy: [..._orderBy, _OrderByClause(lambda, descending: false)],
      take: _take,
      skip: _skip,
      changeTracker: _changeTracker, // **Fase 4.2**
      asyncProvider: _asyncProvider, // **Fase 5.0+3**
    );
  }

  /// Appends `ORDER BY <key> DESC`.:
  /// accepts a closure `(T) => Comparable` for
  /// in-memory sorting (runs AFTER the SQL).
  Queryable<T> orderByDescending_(Object keySelector) {
    if (keySelector is Comparable Function(T)) {
      return Queryable._(
        _provider,
        _table,
        _reader,
        meta: _meta,
        where: _where,
        select: _select,
        distinct: _distinct,
        orderBy: _orderBy,
        take: _take,
        skip: _skip,
        changeTracker: _changeTracker,
        asyncProvider: _asyncProvider,
        memOrderBy: <_MemOrderByClause<T>>[
          ..._memOrderBy,
          _MemOrderByClause<T>(keySelector, descending: true),
        ],
      );
    }
    final lambda = _requireLambda('orderByDescending_', keySelector as Expr);
    return Queryable._(
      _provider,
      _table,
      _reader,
      meta: _meta,
      where: _where,
      select: _select,
      distinct: _distinct,
      orderBy: [..._orderBy, _OrderByClause(lambda, descending: true)],
      take: _take,
      skip: _skip,
      changeTracker: _changeTracker, // **Fase 4.2**
      asyncProvider: _asyncProvider, // **Fase 5.0+3**
    );
  }

  /// (chainable ORDER BY): appends a
  /// secondary `ORDER BY` key with `ASC`. Requires a
  /// prior `orderBy_` / `orderByDescending_`.
  ///: closure overload added.
  Queryable<T> thenBy_(Object keySelector) {
    if (keySelector is Comparable Function(T)) {
      if (_memOrderBy.isEmpty && _orderBy.isEmpty) {
        throw StateError(
          'Queryable.thenBy_: requires a preceding orderBy_ '
          '/ orderByDescending_.',
        );
      }
      return Queryable._(
        _provider,
        _table,
        _reader,
        meta: _meta,
        where: _where,
        select: _select,
        distinct: _distinct,
        orderBy: _orderBy,
        take: _take,
        skip: _skip,
        changeTracker: _changeTracker,
        asyncProvider: _asyncProvider,
        memOrderBy: <_MemOrderByClause<T>>[
          ..._memOrderBy,
          _MemOrderByClause<T>(keySelector, descending: false),
        ],
      );
    }
    if (_orderBy.isEmpty) {
      throw StateError(
        'Queryable.thenBy_: requires a preceding orderBy_ '
        '/ orderByDescending_.',
      );
    }
    final lambda = _requireLambda('thenBy_', keySelector as Expr);
    return Queryable._(
      _provider,
      _table,
      _reader,
      meta: _meta,
      where: _where,
      select: _select,
      distinct: _distinct,
      orderBy: [..._orderBy, _OrderByClause(lambda, descending: false)],
      take: _take,
      skip: _skip,
      changeTracker: _changeTracker,
      asyncProvider: _asyncProvider,
    );
  }

  /// (chainable ORDER BY): appends a
  /// secondary `ORDER BY` key with `DESC`.
  ///: closure overload added.
  Queryable<T> thenByDescending_(Object keySelector) {
    if (keySelector is Comparable Function(T)) {
      if (_memOrderBy.isEmpty && _orderBy.isEmpty) {
        throw StateError(
          'Queryable.thenByDescending_: requires a preceding '
          'orderBy_ / orderByDescending_.',
        );
      }
      return Queryable._(
        _provider,
        _table,
        _reader,
        meta: _meta,
        where: _where,
        select: _select,
        distinct: _distinct,
        orderBy: _orderBy,
        take: _take,
        skip: _skip,
        changeTracker: _changeTracker,
        asyncProvider: _asyncProvider,
        memOrderBy: <_MemOrderByClause<T>>[
          ..._memOrderBy,
          _MemOrderByClause<T>(keySelector, descending: true),
        ],
      );
    }
    if (_orderBy.isEmpty) {
      throw StateError(
        'Queryable.thenByDescending_: requires a preceding '
        'orderBy_ / orderByDescending_.',
      );
    }
    final lambda = _requireLambda('thenByDescending_', keySelector as Expr);
    return Queryable._(
      _provider,
      _table,
      _reader,
      meta: _meta,
      where: _where,
      select: _select,
      distinct: _distinct,
      orderBy: [..._orderBy, _OrderByClause(lambda, descending: true)],
      take: _take,
      skip: _skip,
      changeTracker: _changeTracker,
      asyncProvider: _asyncProvider,
    );
  }

  ///: `SELECT DISTINCT * FROM …`. Drops
  /// duplicate rows. Composable with `where_`,
  /// `orderBy_`, `take_`, `skip_`.
  Queryable<T> distinct_() {
    return Queryable._(
      _provider,
      _table,
      _reader,
      meta: _meta,
      where: _where,
      select: _select,
      distinct: true,
      orderBy: _orderBy,
      take: _take,
      skip: _skip,
      changeTracker: _changeTracker,
      asyncProvider: _asyncProvider,
    );
  }

  /// Appends a `LIMIT n` clause.
  Queryable<T> take_(int n) => Queryable._(
        _provider,
        _table,
        _reader,
        meta: _meta,
        where: _where,
        select: _select,
        distinct: _distinct,
        orderBy: _orderBy,
        take: n,
        skip: _skip,
        //: propagate the in-memory layer so that
        // closure-based orderBy_ / where_ chained
        // before take_ are still applied during
        // materialisation.
        memFilters: _memFilters,
        memOrderBy: _memOrderBy,
        changeTracker: _changeTracker, // **Fase 4.2**
        asyncProvider: _asyncProvider, // **Fase 5.0+3**
      );

  /// Appends an `OFFSET n` clause.
  Queryable<T> skip_(int n) => Queryable._(
        _provider,
        _table,
        _reader,
        meta: _meta,
        where: _where,
        select: _select,
        distinct: _distinct,
        orderBy: _orderBy,
        take: _take,
        skip: n,
        //: propagate the in-memory layer (see take_).
        memFilters: _memFilters,
        memOrderBy: _memOrderBy,
        changeTracker: _changeTracker, // **Fase 4.2**
        asyncProvider: _asyncProvider, // **Fase 5.0+3**
      );

  ///: groups rows by the value produced by
  /// [keySelector].
  ///
  /// The result is a [SqliteGroupedQueryable] that:
  /// * executes the current SQL (`SELECT * FROM … WHERE … ORDER BY
  /// … LIMIT …`) and materializes the rows;
  /// * groups them in Dart by [keySelector];
  /// * yields `IGrouping<TKey, T>` instances, in the order in which
  /// keys were first encountered.
  ///
  /// The grouped queryable is iterable but does not support further
  /// SQL operators. Apply d_rocket in-memory operators to it for
  /// post-grouping transformations.
  ///
  /// Example:
  ///
  /// ```dart
  /// final groups = q
  /// .where_(Expr.lambda(
  /// [Expr.param('u')],
  /// Expr.binary('>=',
  /// Expr.member(Expr.param('u'), 'age'),
  /// Expr.const_(18)),
  ///))
  /// .orderBy_(
  /// Expr.lambda(
  /// [Expr.param('u')],
  /// Expr.member(Expr.param('u'), 'age')),
  ///)
  /// .groupBy_`<int>`(
  /// keySelector: Expr.lambda(
  /// [Expr.param('u')],
  /// Expr.member(Expr.param('u'), 'age'),
  ///),
  ///)
  /// .toList_;
  /// ```
  SqliteGroupedQueryable<TKey, T> groupBy_<TKey>({
    required Object keySelector,
  }) {
    if (_select != null) {
      throw StateError(
        'groupBy_ after select_ is not supported in Fase 2.3. '
        'Reorder so groupBy_ comes first.',
      );
    }
    //: closure path.
    if (keySelector is TKey Function(T)) {
      return SqliteGroupedQueryable<TKey, T>._(
        this,
        closureKey: keySelector,
      );
    }
    //: AST path.
    final lambda = _requireLambda('groupBy_', keySelector as Expr);
    return SqliteGroupedQueryable<TKey, T>._(this, keySelector: lambda);
  }

  ///: INNER JOIN with [inner] on matching keys.
  ///
  /// * [outerKeySelector] extracts the key from each outer element.
  /// * [innerKeySelector] extracts the key from each inner element.
  /// * [resultSelector] is a two-parameter [LambdaExpr] that
  /// produces the result from each `(outer, inner)` pair.
  ///
  /// The join happens in Dart: the inner is materialized once and
  /// indexed by key, the outer is fetched via SQL (`SELECT * …`)
  /// and the matching pairs are evaluated.
  ///
  /// Example:
  ///
  /// ```dart
  /// final titles = q.join_<_Post, int, String>(
  /// inner: posts.asQueryable,
  /// outerKeySelector: Expr.lambda(
  /// [Expr.param('o')],
  /// Expr.member(Expr.param('o'), 'id'),
  ///),
  /// innerKeySelector: Expr.lambda(
  /// [Expr.param('i')],
  /// Expr.member(Expr.param('i'), 'userId'),
  ///),
  /// resultSelector: Expr.lambda(
  /// [Expr.param('o'), Expr.param('i')],
  /// Expr.binary('+',
  /// Expr.member(Expr.param('o'), 'name'),
  /// Expr.const_(': '),
  ///),
  ///),
  ///);
  /// ```
  SqliteJoinedQueryable<TResult> join_<TInner, TKey, TResult>({
    required IQueryable<TInner> inner,
    required Object outerKeySelector,
    required Object innerKeySelector,
    required Object resultSelector,
  }) {
    if (_select != null) {
      throw StateError(
        'join_ after select_ is not supported in Fase 2.3.',
      );
    }
    //: closure path. All three selectors must be
    // closures (Dart types them as TKey Function(T),
    // TKey Function(TInner), TResult Function(T,
    // TInner)). No mixing with AST — the constructor
    // assertion would fail anyway, but checking up
    // front gives a clearer error.
    if (outerKeySelector is TKey Function(T) &&
        innerKeySelector is TKey Function(TInner) &&
        resultSelector is TResult Function(T, TInner)) {
      return SqliteJoinedQueryable<TResult>._(
        source: this,
        op: _JoinOp(
          inner: inner,
          isGroupJoin: false,
          outerKeyClosure: outerKeySelector,
          innerKeyClosure: innerKeySelector,
          resultClosure: resultSelector,
        ),
      );
    }
    //: AST path. All three selectors must be
    // [Expr]s (the `_requireLambda` / `_requireResult2`
    // throw a clear ArgumentError if not).
    if (outerKeySelector is Expr &&
        innerKeySelector is Expr &&
        resultSelector is Expr) {
      return SqliteJoinedQueryable<TResult>._(
        source: this,
        op: _JoinOp(
          inner: inner,
          isGroupJoin: false,
          outerKey: _requireLambda('join_', outerKeySelector),
          innerKey: _requireLambda('join_', innerKeySelector),
          result: _requireResult2('join_', resultSelector),
        ),
      );
    }
    throw ArgumentError(
      'Queryable.join_: all three selectors must be '
      'closures of the form (T) => TKey, (TInner) => '
      'TKey, (T, TInner) => TResult, OR all three must '
      'be Expr / LambdaExpr. Got outerKeySelector='
      '${outerKeySelector.runtimeType}, '
      'innerKeySelector=${innerKeySelector.runtimeType}, '
      'resultSelector=${resultSelector.runtimeType}.',
    );
  }

  ///: LEFT OUTER JOIN grouped by outer key.
  ///
  /// Like [join_] but each outer element is paired with the list
  /// of matching inner elements (empty if no match). The
  /// [resultSelector] is a three-parameter [LambdaExpr]:
  /// `(outer, inners, key) => result`, where `inners` is a
  /// `List<TInner>`.
  SqliteJoinedQueryable<TResult> groupJoin_<TInner, TKey, TResult>({
    required IQueryable<TInner> inner,
    required Object outerKeySelector,
    required Object innerKeySelector,
    required Object resultSelector,
  }) {
    if (_select != null) {
      throw StateError(
        'groupJoin_ after select_ is not supported in Fase 2.3.',
      );
    }
    //: closure path.
    if (outerKeySelector is TKey Function(T) &&
        innerKeySelector is TKey Function(TInner) &&
        resultSelector is TResult Function(T, Iterable<TInner>, TKey)) {
      return SqliteJoinedQueryable<TResult>._(
        source: this,
        op: _JoinOp(
          inner: inner,
          isGroupJoin: true,
          outerKeyClosure: outerKeySelector,
          innerKeyClosure: innerKeySelector,
          resultClosure: resultSelector,
        ),
      );
    }
    //: AST path.
    if (outerKeySelector is Expr &&
        innerKeySelector is Expr &&
        resultSelector is Expr) {
      return SqliteJoinedQueryable<TResult>._(
        source: this,
        op: _JoinOp(
          inner: inner,
          isGroupJoin: true,
          outerKey: _requireLambda('groupJoin_', outerKeySelector),
          innerKey: _requireLambda('groupJoin_', innerKeySelector),
          result: _requireResult3('groupJoin_', resultSelector),
        ),
      );
    }
    throw ArgumentError(
      'Queryable.groupJoin_: all three selectors must be '
      'closures of the form (T) => TKey, (TInner) => '
      'TKey, (T, Iterable<TInner>, TKey) => TResult, OR '
      'all three must be Expr / LambdaExpr. Got '
      'outerKeySelector=${outerKeySelector.runtimeType}, '
      'innerKeySelector=${innerKeySelector.runtimeType}, '
      'resultSelector=${resultSelector.runtimeType}.',
    );
  }

  // ─── Terminal: execute + materialize ───────────────────────────────

  /// (in-memory layer): the central
  /// materialisation helper. Runs the SQL via
  /// [_executeSql], then applies the in-memory
  /// layer (mem filters, mem orderings) on top.
  ///
  /// Every terminal (`toList_`, `count_`, `first_`,
  /// `firstOrDefault_`, `*Async`, …) goes through this
  /// helper, so the closure LINQ operators compose
  /// uniformly with the SQL ones.
  List<T> _materialize() {
    //: closure select path — run the pre-select
    // source (which is the original Queryable<T> with
    // its where_/orderBy_/take_/skip_ pipeline), then
    // project each row through the closure to get the
    // current T. The in-memory filters and orderings
    // of THIS queryable (if any were chained after the
    // closure select) apply to the projected T.
    if (_memProject != null && _memProjectSource != null) {
      final source = _memProjectSource._materialize();
      return <T>[
        for (final row in source) _memProject(row) as T,
      ];
    }
    List<T> rows = _executeSql();
    //: in-memory filters (closure LINQ).
    for (final f in _memFilters) {
      rows = rows.where(f).toList(growable: false);
    }
    //: in-memory orderings (closure LINQ).
    // Each clause is applied in order — stable sort
    // so the SQL `ORDER BY` is preserved as the
    // primary key.
    if (_memOrderBy.isNotEmpty) {
      rows = List<T>.of(rows);
      for (final clause in _memOrderBy.reversed) {
        rows.sort((a, b) {
          final Comparable ka = clause.key(a);
          final Comparable kb = clause.key(b);
          final int cmp = ka.compareTo(kb);
          return clause.descending ? -cmp : cmp;
        });
      }
    }
    //: in-memory LIMIT / OFFSET. The SQL
    // path skips these when _memOrderBy is set
    // (see _buildSelect) so we apply them here
    // AFTER the sort. Without this, the user
    // would get the wrong subset of rows. We
    // guard with `_memOrderBy.isNotEmpty` so the
    // SQL path (which already emits LIMIT /
    // OFFSET) is not double-applied.
    if (_memOrderBy.isNotEmpty) {
      if (_take != null) {
        final int s = _skip ?? 0;
        final int end = s + _take;
        if (end < rows.length) {
          rows = rows.sublist(0, end);
        }
      }
      if (_skip != null && _take == null) {
        rows = rows.length > _skip ? rows.sublist(_skip) : <T>[];
      }
    }
    return rows;
  }

  ///: runs the SQL and returns the raw
  /// mapped rows (no in-memory layer). Most terminals
  /// go through [_materialize] instead.
  List<T> _executeSql() {
    final frag = _buildSelect();
    final rows = _provider.selectWithBinds(frag.sql, frag.binds);
    return rows.map(_reader).toList(growable: false);
  }

  /// Executes the SQL and returns the materialized list of [T].
  ///: also applies the in-memory layer
  /// (closure LINQ) on top of the SQL result.
  List<T> toList_() => _materialize();

  /// — `toList_` with JOIN-based eager
  /// loading.
  ///
  /// The user supplies a list of [IncludeRelation]s
  /// (the same shape used by `DbSet.findById(id,
  /// joins:)` in). The runtime emits a
  /// single `SELECT … FROM "T" LEFT JOIN
  /// "relatedTable" … WHERE …` and materialises the
  /// result into a list of `T` with each entity's
  /// `joinResults` field populated.
  ///
  /// The result is deduped by `T`'s primary key: if
  /// a `T` matches multiple JOIN rows (e.g. one book
  /// with three sales), the book appears once in
  /// the returned list, with all three sales collected
  /// in its `joinResults['sales']`.
  ///
  /// The user-facing pattern:
  ///
  /// ```dart
  /// final List`<Book>` books = ctx.books
  /// .asQueryable
  /// .where_(...)
  /// .orderByDescending_(...)
  /// .take_(10)
  /// .toListWithJoins([
  /// IncludeOne`<Book, Author>`(
  /// navigationName: 'author',
  /// relatedMeta: _authorMeta,
  /// fkColumnOnT: 'author_id',
  ///),
  /// IncludeMany`<Book, Sale>`(
  /// navigationName: 'sales',
  /// relatedMeta: _saleMeta,
  /// inverseFkColumn: 'book_id',
  ///),
  ///]);
  /// ```
  List<T> toListWithJoins(
    List<IncludeRelation<T, Object>> joins,
  ) {
    if (joins.isEmpty) {
      return toList_();
    }
    final frag = _buildSelectWithJoins(joins);
    final rows = _provider.selectWithBinds(frag.sql, frag.binds);
    if (rows.isEmpty) return <T>[];
    return _materializeJoins(rows, joins);
  }

  // ───: async terminal methods ─────────────────────
  //
  // These are the async counterparts of the I/O-bound
  // terminal methods ([toList_], [toListWithJoins],
  // [count_]). They use the [AsyncQueryProvider] that
  // was wired by [DbSet.asQueryable]. If no async
  // provider is set, they throw [StateError]. The legacy
  // sync methods continue to work (no breaking change).

  /// (async): the async counterpart of
  /// [toList_]. Returns the materialized list of [T]
  /// once the underlying SQL has executed through the
  /// [AsyncQueryProvider].
  ///
  /// Throws [StateError] if no [AsyncQueryProvider] is
  /// wired (configure it via [DbSet.asQueryable] or
  /// the [DbContext.asyncProvider] getter).
  Future<List<T>> toListAsync_() async {
    if (_asyncProvider == null) {
      throw StateError(
        'Queryable<T>.toListAsync_() requires an AsyncQueryProvider. '
        'Make sure the source DbSet has had attachAsyncProvider(...) '
        'called (the DbContext.dbSet<T>(...) helper does this '
        'automatically when the surrounding context has an asyncProvider).',
      );
    }
    //: go through _materializeAsync so the
    // closure-based memFilters and memOrderBy are
    // applied AFTER the SQL result.
    return _materializeAsync();
  }

  ///: the async counterpart of
  /// [_materialize]. Runs the SQL via the async
  /// provider, then applies the in-memory layer
  /// (memFilters + memOrderBy).
  Future<List<T>> _materializeAsync() async {
    final frag = _buildSelect();
    final List<Object?> rows =
        await _asyncProvider!.selectAsync(frag.sql, frag.binds);
    List<T> result = rows.map((Object? row) {
      // Each row is `Map<String, Object?>` (sqlite3 Row
      // satisfies this via covariance). The legacy
      // `_reader` expects a `Row`; we cast here.
      return _reader(row as dynamic);
    }).toList(growable: false);
    //: closure-based filters, then closures.
    for (final f in _memFilters) {
      result = result.where(f).toList(growable: false);
    }
    if (_memOrderBy.isNotEmpty) {
      result = List<T>.of(result);
      for (final clause in _memOrderBy.reversed) {
        result.sort((a, b) {
          final Comparable ka = clause.key(a);
          final Comparable kb = clause.key(b);
          final int cmp = ka.compareTo(kb);
          return clause.descending ? -cmp : cmp;
        });
      }
    }
    return result;
  }

  /// (async): the async counterpart of
  /// [toListWithJoins]. Returns the deduped list of [T]
  /// with their JOIN results populated, once the
  /// underlying SQL has executed through the
  /// [AsyncQueryProvider].
  Future<List<T>> toListWithJoinsAsync_(
    List<IncludeRelation<T, Object>> joins,
  ) async {
    if (_asyncProvider == null) {
      throw StateError(
        'Queryable<T>.toListWithJoinsAsync_() requires an AsyncQueryProvider.',
      );
    }
    if (joins.isEmpty) {
      return toListAsync_();
    }
    final frag = _buildSelectWithJoins(joins);
    final List<Object?> rows =
        await _asyncProvider.selectAsync(frag.sql, frag.binds);
    if (rows.isEmpty) return <T>[];
    return _materializeJoins(rows.cast<Map<String, Object?>>(), joins);
  }

  /// (async): the async counterpart of
  /// [count_]. Returns the count of rows matching the
  /// chained `where_` predicate.
  Future<int> countAsync_() async {
    if (_asyncProvider == null) {
      throw StateError(
        'Queryable<T>.countAsync_() requires an AsyncQueryProvider.',
      );
    }
    final frag = _buildAggregate(
      sqlExpr: 'COUNT(*)',
      coalesceZero: false,
    );
    final List<Object?> rows =
        await _asyncProvider.selectAsync(frag.sql, frag.binds);
    if (rows.isEmpty) return 0;
    final Object? first = rows.first;
    if (first is Map) {
      // `_buildAggregate` uses 'n' as the alias; the
      // first value is the count.
      final Object? value = first['n'] ?? first.values.first;
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.parse(value);
    }
    throw StateError(
      'Queryable<T>.countAsync_(): unexpected row shape '
      'from the underlying provider: $first',
    );
  }

  ///: returns the first row of the
  /// query result. Throws [StateError] if the result
  /// is empty. Implementation: `SELECT … LIMIT 1`
  /// — SQL is more efficient than fetching all and
  /// taking the first in Dart.
  Future<T> firstAsync_() async {
    if (_asyncProvider == null) {
      throw StateError(
        'Queryable<T>.firstAsync_() requires an AsyncQueryProvider.',
      );
    }
    final SqlFragment frag = _buildSelect();
    final String limited = '${frag.sql} LIMIT 1';
    final List<Object?> rows =
        await _asyncProvider.selectAsync(limited, frag.binds);
    if (rows.isEmpty) {
      throw StateError(
        'Queryable<T>.firstAsync_(): no rows matched the '
        'predicate.',
      );
    }
    return _reader(rows.first as dynamic);
  }

  ///: returns the first row of the
  /// query result, or `null` if the result is empty.
  /// The "default" (the null fallback) is not a
  /// separate code path — it's the same `LIMIT 1`
  /// query with an empty-result check.
  Future<T?> firstOrDefaultAsync_() async {
    if (_asyncProvider == null) {
      throw StateError(
        'Queryable<T>.firstOrDefaultAsync_() requires an '
        'AsyncQueryProvider.',
      );
    }
    final SqlFragment frag = _buildSelect();
    final String limited = '${frag.sql} LIMIT 1';
    final List<Object?> rows =
        await _asyncProvider.selectAsync(limited, frag.binds);
    if (rows.isEmpty) return null;
    return _reader(rows.first as dynamic);
  }

  ///: `SELECT EXISTS (SELECT 1 FROM … WHERE …)`.
  /// Returns `true` if any row matches the chained
  /// `where_` predicate. Without a chained `where_`,
  /// returns `true` if the table is non-empty.
  Future<bool> anyAsync_() async {
    if (_asyncProvider == null) {
      throw StateError(
        'Queryable<T>.anyAsync_() requires an AsyncQueryProvider.',
      );
    }
    // Build the EXISTS body directly. We translate
    // the WHERE once (if any), then wrap in EXISTS.
    final parts = <String>['SELECT EXISTS (SELECT 1 FROM "$_table"'];
    final binds = <Object?>[];
    if (_where != null) {
      final whereFrag = _translate(_where);
      parts.add('WHERE ${whereFrag.sql}');
      binds.addAll(whereFrag.binds);
    }
    parts.add(') AS n');
    final List<Object?> rows =
        await _asyncProvider.selectAsync(parts.join(' '), binds);
    if (rows.isEmpty) return false;
    final Object? first = rows.first;
    if (first is Map) {
      final Object? value = first['n'];
      if (value is int) return value != 0;
      if (value is num) return value != 0;
    }
    return false;
  }

  ///: `SELECT NOT EXISTS (… WHERE NOT <predicate>)`.
  /// Returns `true` if all rows match the chained
  /// `where_` predicate. Equivalent to SQL `ALL`.
  /// Throws [ArgumentError] if no predicate is chained
  /// (use [anyAsync_] or [countAsync_] for that case).
  Future<bool> allAsync_(Expr predicate) async {
    if (_asyncProvider == null) {
      throw StateError(
        'Queryable<T>.allAsync_() requires an AsyncQueryProvider.',
      );
    }
    final LambdaExpr lambda = _requireLambda('allAsync_', predicate);
    final LambdaExpr negated = _negateLambda(lambda);
    // Build `SELECT NOT EXISTS (SELECT 1 FROM … WHERE NOT pred)`.
    final parts = <String>['SELECT NOT EXISTS (SELECT 1 FROM "$_table"'];
    final binds = <Object?>[];
    final whereFrag = _translate(negated);
    parts.add('WHERE ${whereFrag.sql}');
    binds.addAll(whereFrag.binds);
    parts.add(') AS n');
    final List<Object?> rows =
        await _asyncProvider.selectAsync(parts.join(' '), binds);
    if (rows.isEmpty) return false;
    final Object? first = rows.first;
    if (first is Map) {
      final Object? value = first['n'];
      if (value is int) return value != 0;
      if (value is num) return value != 0;
    }
    return false;
  }

  /// helper: wraps a lambda `(T) => bool`
  /// in `(T) => !lambda(T)`. The `!` unary op maps
  /// to SQL `NOT (...)` in [SqlTranslator.visitUnary].
  /// Used by [allAsync_] to express the
  /// `NOT EXISTS (... WHERE NOT pred)` pattern.
  LambdaExpr _negateLambda(LambdaExpr original) {
    final Expr notBody = Expr.unary('!', original.body);
    return LambdaExpr(original.params, notBody);
  }

  /// helper: build a single `SELECT … FROM
  /// … LEFT JOIN …` SQL fragment with the chained
  /// `where_` / `orderBy_` / `take_` / `skip_` applied
  /// to the main table (the JOINs do not constrain
  /// the result set).
  SqlFragment _buildSelectWithJoins(
    List<IncludeRelation<T, Object>> joins,
  ) {
    // The main table's alias is `u` (same as the
    // default for the non-JOIN queryable, so the user's
    // existing `where_` / `orderBy_` lambdas work
    // unchanged). The related tables use `t0`, `t1`,
    // `t2`, ...
    final String mainAlias = 'u';
    final StringBuffer select = StringBuffer();
    final StringBuffer from = StringBuffer();
    final List<Object?> binds = <Object?>[];

    // Main table columns (prefixed with main alias to
    // avoid collision with related columns).
    select.write(
      _meta.columns
          .map((ColumnMeta c) => '$mainAlias."${c.sqlName}" AS "${c.sqlName}"')
          .join(', '),
    );
    from.write('"$_table" AS $mainAlias');

    // Add JOINs.
    for (int i = 0; i < joins.length; i++) {
      final IncludeRelation<T, Object> rel = joins[i];
      final String alias = 't$i';
      select.write(
        ', ${rel.relatedMeta.columns.map((ColumnMeta c) => '$alias."${c.sqlName}" AS '
            '"${rel.relatedMeta.tableName}_${c.sqlName}"').join(', ')}',
      );
      switch (rel) {
        case IncludeOne<T, Object>():
          from.write(
            ' LEFT JOIN "${rel.relatedMeta.tableName}" AS $alias ON '
            '$alias."id" = $mainAlias."${rel.fkColumnOnT}"',
          );
        case IncludeMany<T, Object>():
          from.write(
            ' LEFT JOIN "${rel.relatedMeta.tableName}" AS $alias ON '
            '$alias."${rel.inverseFkColumn}" = $mainAlias."id"',
          );
      }
    }

    // WHERE (uses the main alias implicitly via
    // `SqlTranslator`'s default table alias = 'u').
    if (_where != null) {
      // The translator needs the column to be prefixed
      // with the main alias. We re-parse the where via
      // a tiny adapter: pass the main alias as the
      // translator's table alias.
      final SqlTranslator tx =
          SqlTranslator(tableAlias: mainAlias, dialect: _kDialect);
      final SqlFragment whereFrag = tx.translateLambda(_where);
      from.write(' WHERE ${whereFrag.sql}');
      binds.addAll(whereFrag.binds);
    }

    // ORDER BY.
    for (final _OrderByClause clause in _orderBy) {
      final SqlTranslator tx =
          SqlTranslator(tableAlias: mainAlias, dialect: _kDialect);
      final SqlFragment orderFrag = tx.translateLambda(clause.selector);
      from.write(
        ' ORDER BY ${orderFrag.sql}${clause.descending ? ' DESC' : ' ASC'}',
      );
      binds.addAll(orderFrag.binds);
    }

    // LIMIT / OFFSET.
    if (_take != null) {
      from.write(' LIMIT $_take');
    } else if (_skip != null) {
      from.write(' LIMIT -1');
    }
    if (_skip != null) {
      from.write(' OFFSET $_skip');
    }

    return SqlFragment(
      'SELECT $select FROM $from',
      binds,
    );
  }

  /// helper: materialise the JOIN rows into
  /// a list of `T` (deduped by PK) with the
  /// `joinResults` field populated.
  List<T> _materializeJoins(
    List<Object?> rawRows,
    List<IncludeRelation<T, Object>> joins,
  ) {
    final Map<Object, T> byPk = <Object, T>{};
    final List<T> ordered = <T>[];
    // We can't use `_reader` (it takes a sqlite3 `Row`),
    // but `EntityMeta.fromRow` takes a `Map<String,
    // Object?>`. The codegen-emitted `fromRow` is what
    // `DbSet.findById(joins:)` uses too. We re-create
    // a fresh "empty" entity here just to satisfy the
    // `Map` lookup (this branch is only hit when
    // the loop's first row has no PK, which is a
    // degenerate case — but we keep the defensive
    // lookup for safety).
    for (int i = 0; i < rawRows.length; i++) {
      final Map<String, Object?> row = rawRows[i] as Map<String, Object?>;
      final Object? pk = row[_meta.primaryKey.sqlName];
      if (pk == null) continue;
      if (!byPk.containsKey(pk)) {
        // Materialise the main entity from this row.
        final Map<String, Object?> mainRow = <String, Object?>{};
        for (final MapEntry<String, Object?> e in row.entries) {
          final bool isRelated = joins.any(
            (IncludeRelation<T, Object> rel) =>
                e.key.startsWith('${rel.relatedMeta.tableName}_'),
          );
          if (!isRelated) {
            mainRow[e.key] = e.value;
          }
        }
        // The user-supplied `_reader` consumes a
        // sqlite3 `Row`, but here we already have a
        // `Map<String, Object?>`. Use `_mapReader`
        // (derived from `EntityMeta.fromRow`).
        final T newEntity = _mapReader(mainRow);
        byPk[pk] = newEntity;
        ordered.add(newEntity);
      }
      // Populate the JOIN results on the entity.
      final T entity = byPk[pk] as T;
      for (final IncludeRelation<T, Object> rel in joins) {
        _populateNavigationOnEntity(entity, rel, row);
      }
    }
    return ordered;
  }

  /// helper: populate a navigation property
  /// from a single JOIN row (vs `DbSet._populateNavigation`
  /// which processes a list). Used by the
  /// `_materializeJoins` loop, which calls this once
  /// per row.
  void _populateNavigationOnEntity(
    T entity,
    IncludeRelation<T, Object> rel,
    Map<String, Object?> row,
  ) {
    final String prefix = '${rel.relatedMeta.tableName}_';
    final String pkKey = '${prefix}id';
    final Object? relatedPk = row[pkKey];
    if (relatedPk == null) return;
    // Read existing joinResults (or initialise).
    final Map<String, Object?> existing =
        ((entity as dynamic).joinResults as Map<String, Object?>?) ??
            <String, Object?>{};
    (entity as dynamic).joinResults = existing;

    // Project the related row (strip prefix).
    final Map<String, Object?> related = <String, Object?>{};
    for (final MapEntry<String, Object?> e in row.entries) {
      if (e.key.startsWith(prefix)) {
        related[e.key.substring(prefix.length)] = e.value;
      }
    }

    switch (rel) {
      case IncludeOne<T, Object>():
        // Only the first non-null row wins.
        if (existing[rel.navigationName] == null &&
            rel.relatedMeta.fromRow != null) {
          existing[rel.navigationName] = rel.relatedMeta.fromRow!(related);
        }
      case IncludeMany<T, Object>():
        if (rel.relatedMeta.fromRow != null) {
          // Collect into a Set keyed by related PK to
          // dedupe (the same row may appear multiple
          // times if multiple JOINs collide).
          final List<Object?> acc =
              (existing[rel.navigationName] as List<Object?>?) ?? <Object?>[];
          // Dedup by related PK.
          final Object currentPk = relatedPk;
          final bool alreadyThere = acc.any(
            (Object? e) => e is Object && _pkOfRel(e) == currentPk,
          );
          if (!alreadyThere) {
            acc.add(rel.relatedMeta.fromRow!(related));
          }
          existing[rel.navigationName] = acc;
        }
    }
  }

  /// helper: extract the PK from a related
  /// entity. Reads the `id` field via the same reader
  /// function (best-effort; falls back to 0).
  Object? _pkOfRel(Object e) {
    try {
      return (e as dynamic).id as Object?;
    } on Object {
      return null;
    }
  }

  /// helper: see [_mapReaderFallback] (the
  /// top-level function). Kept here for documentation
  /// purposes only.
  // ignore: unused_element
  TOut _throwMapFallbackDoc<TOut>(Map<String, Object?> row) =>
      throw StateError('EntityMeta.fromRow is null');

  /// Returns the number of rows that match the current state.
  int count_() {
    final frag = _buildAggregate(
      sqlExpr: 'COUNT(*)',
      coalesceZero: false,
    );
    final rows = _provider.selectWithBinds(frag.sql, frag.binds);
    return rows.first['n'] as int;
  }

  /// (reactive queries): returns a
  /// `Stream<List<T>>` that emits the initial result
  /// immediately, then re-runs the query on every
  /// [ChangeEvent] from the underlying [ChangeTracker]
  /// and emits the new result list.
  ///
  /// Requires that the queryable was constructed with a
  /// [ChangeTracker] (the `DbSet.asQueryable`
  /// bridge wires this automatically). Throws
  /// [StateError] otherwise.
  ///
  /// Use case: the user subscribes once at startup
  /// and rebuilds their UI / triggers a re-fetch on
  /// every emit:
  ///
  /// ```dart
  /// final stream = ctx.books.asQueryable.watch;
  /// stream.listen((List`<Book>` books) {
  /// print('books: ${books.length}');
  /// });
  /// // ...later, in any saveChanges batch:
  /// ctx.books.add(Book(...));
  /// ctx.saveChanges;
  /// // → the stream fires with the new list.
  /// ```
  Stream<List<T>> watch() {
    final ChangeTracker? tracker = _changeTracker;
    if (tracker == null) {
      throw StateError(
        'Queryable.watch() requires a ChangeTracker. '
        'Construct the queryable via DbSet.asQueryable() '
        '(which wires the tracker from the surrounding '
        'DbContext) instead of calling '
        'Queryable(...) directly.',
      );
    }
    // Use a `StreamController` so the consumer can cancel
    // (which also cancels the subscription to the
    // change tracker).
    late final StreamController<List<T>> controller;
    late final StreamSubscription<ChangeEvent> sub;
    controller = StreamController<List<T>>(
      onListen: () {
        // Emit the initial snapshot synchronously.
        controller.add(toList_());
        // Subscribe to the tracker; re-run the query on
        // every event.
        sub = tracker.changes.listen((ChangeEvent _) {
          try {
            controller.add(toList_());
          } catch (e, st) {
            controller.addError(e, st);
          }
        });
      },
      onCancel: () => sub.cancel(),
    );
    return controller.stream;
  }

  /// Returns the sum of the values produced by [selector].
  ///
  /// Accepts either an [Expr] (translated to `SELECT
  /// SUM(...)` in SQL — the efficient path) or a closure
  /// `num Function(T)` (the source is materialised first
  /// via the same `where_` / `orderBy_` / `take_` / `skip_`
  /// pipeline, then the closure is applied in Dart). The
  /// closure path is required for callers that want a
  /// pure-Dart aggregate; the AST path is preferred when
  /// the source is a full table scan.
  num sum_(Object selector) {
    if (selector is num Function(T)) {
      num total = 0;
      for (final row in _materialize()) {
        total += selector(row);
      }
      return total;
    }
    final lambda = _requireLambda('sum_', selector as Expr);
    final selFrag = _translate(lambda);
    final frag = _buildAggregate(
      sqlExpr: 'SUM(${selFrag.sql})',
      coalesceZero: true,
      extraBinds: selFrag.binds,
    );
    final rows = _provider.selectWithBinds(frag.sql, frag.binds);
    final v = rows.first['n'];
    return (v as num?) ?? 0;
  }

  /// Returns the arithmetic mean of the values produced by
  /// [selector]. Throws [StateError] for an empty set.
  ///
  /// Accepts [Expr] (SQL `AVG`) or `num Function(T)`
  /// (in-memory). See [sum_] for the trade-off.
  double average_(Object selector) {
    if (selector is num Function(T)) {
      num total = 0;
      int n = 0;
      for (final row in _materialize()) {
        total += selector(row);
        n++;
      }
      if (n == 0) {
        throw StateError('average_ called on empty source');
      }
      return total / n;
    }
    final lambda = _requireLambda('average_', selector as Expr);
    final selFrag = _translate(lambda);
    final frag = _buildAggregate(
      sqlExpr: 'AVG(${selFrag.sql})',
      coalesceZero: false,
      extraBinds: selFrag.binds,
    );
    final rows = _provider.selectWithBinds(frag.sql, frag.binds);
    final v = rows.first['n'];
    if (v == null) {
      throw StateError('average_ called on empty source');
    }
    return (v as num).toDouble();
  }

  /// Returns the smallest value produced by [selector].
  ///
  /// Accepts [Expr] (SQL `MIN`) or `Comparable Function(T)`
  /// (in-memory). See [sum_] for the trade-off.
  Object? min_(Object selector) {
    if (selector is Comparable Function(T)) {
      Comparable? best;
      for (final row in _materialize()) {
        final v = selector(row);
        if (best == null || v.compareTo(best) < 0) best = v;
      }
      if (best == null) {
        throw StateError('min_ called on empty source');
      }
      return best;
    }
    final lambda = _requireLambda('min_', selector as Expr);
    final selFrag = _translate(lambda);
    final frag = _buildAggregate(
      sqlExpr: 'MIN(${selFrag.sql})',
      coalesceZero: false,
      extraBinds: selFrag.binds,
    );
    final rows = _provider.selectWithBinds(frag.sql, frag.binds);
    final v = rows.first['n'];
    if (v == null) {
      throw StateError('min_ called on empty source');
    }
    return v;
  }

  /// Returns the largest value produced by [selector].
  ///
  /// Accepts [Expr] (SQL `MAX`) or `Comparable Function(T)`
  /// (in-memory). See [sum_] for the trade-off.
  Object? max_(Object selector) {
    if (selector is Comparable Function(T)) {
      Comparable? best;
      for (final row in _materialize()) {
        final v = selector(row);
        if (best == null || v.compareTo(best) > 0) best = v;
      }
      if (best == null) {
        throw StateError('max_ called on empty source');
      }
      return best;
    }
    final lambda = _requireLambda('max_', selector as Expr);
    final selFrag = _translate(lambda);
    final frag = _buildAggregate(
      sqlExpr: 'MAX(${selFrag.sql})',
      coalesceZero: false,
      extraBinds: selFrag.binds,
    );
    final rows = _provider.selectWithBinds(frag.sql, frag.binds);
    final v = rows.first['n'];
    if (v == null) {
      throw StateError('max_ called on empty source');
    }
    return v;
  }

  /// `aggregate_` is not supported on `Queryable`.
  TResult aggregate_<TResult>({
    required TResult seed,
    required Expr func,
  }) {
    throw UnsupportedError(
      'Queryable.aggregate_ is not supported: SQL has no '
      'general-purpose fold. Use sum_, average_, min_, max_, or '
      'count_ instead.',
    );
  }

  // ─── Internal SQL builders ─────────────────────────────────────────

  /// Builds the final SELECT statement for the current state.
  SqlFragment _buildSelect() {
    final parts = <String>[];
    final binds = <Object?>[];

    if (_select != null) {
      final selectFrag = _translate(_select);
      //: distinct_ adds `DISTINCT` to the
      // SELECT projection. When combined with `select_`,
      // we insert `DISTINCT` between `SELECT` and the
      // projected expression.
      parts.add(
        _distinct
            ? 'SELECT DISTINCT ${selectFrag.sql} AS result FROM "$_table"'
            : 'SELECT ${selectFrag.sql} AS result FROM "$_table"',
      );
      binds.addAll(selectFrag.binds);
    } else {
      parts.add(
        _distinct
            ? 'SELECT DISTINCT * FROM "$_table"'
            : 'SELECT * FROM "$_table"',
      );
    }

    if (_where != null) {
      final whereFrag = _translate(_where);
      parts.add('WHERE ${whereFrag.sql}');
      binds.addAll(whereFrag.binds);
    }

    for (int i = 0; i < _orderBy.length; i++) {
      final clause = _orderBy[i];
      final orderFrag = _translate(clause.selector);
      if (i == 0) {
        // First ORDER BY clause — emit the keyword.
        parts.add(
          'ORDER BY ${orderFrag.sql}${clause.descending ? ' DESC' : ' ASC'}',
        );
      } else {
        //: subsequent ORDER BY clauses
        // (from `thenBy_` / `thenByDescending_`) are
        // comma-separated, NOT preceded by another
        // `ORDER BY` keyword (which would be a SQL
        // syntax error).
        parts.add(
          ', ${orderFrag.sql}${clause.descending ? ' DESC' : ' ASC'}',
        );
      }
      binds.addAll(orderFrag.binds);
    }

    //: defer LIMIT / OFFSET to the in-memory
    // step when the user has chained a
    // closure-based `orderBy_`. The SQL has no
    // `ORDER BY` (the ordering is in-memory), so a
    // SQL `LIMIT 3` would return the WRONG 3
    // rows — the first 3 in natural row order,
    // not the top 3 by the in-memory key. The
    // materialize step applies the in-memory
    // ordering first, then the limit / offset.
    if (_memOrderBy.isEmpty) {
      if (_take != null) {
        parts.add('LIMIT $_take');
      } else if (_skip != null) {
        parts.add('LIMIT -1');
      }
      final int? s = _skip;
      if (s != null) {
        parts.add('OFFSET $s');
      }
    }

    return SqlFragment(parts.join(' '), binds);
  }

  /// Builds a `SELECT <expr> AS n FROM …` aggregate query.
  SqlFragment _buildAggregate({
    required String sqlExpr,
    bool coalesceZero = false,
    List<Object?>? extraBinds,
  }) {
    final parts = <String>[];
    final binds = <Object?>[];
    final expr = coalesceZero ? 'COALESCE($sqlExpr, 0)' : sqlExpr;
    parts.add('SELECT $expr AS n FROM "$_table"');
    if (extraBinds != null) binds.addAll(extraBinds);
    final LambdaExpr? w = _where;
    if (w != null) {
      final whereFrag = _translate(w);
      parts.add('WHERE ${whereFrag.sql}');
      binds.addAll(whereFrag.binds);
    }
    return SqlFragment(parts.join(' '), binds);
  }

  /// Exposed publicly for testing and debugging.
  SqlFragment buildSelect() => _buildSelect();

  // ─── Helpers ───────────────────────────────────────────────────────

  SqlFragment _translate(LambdaExpr lambda) {
    return SqlTranslator(dialect: _kDialect).translateLambda(lambda);
  }

  LambdaExpr _requireLambda(String opName, Expr expr) {
    if (expr is! LambdaExpr) {
      throw ArgumentError(
        'Queryable.$opName: argument must be a LambdaExpr, '
        'got ${expr.runtimeType}',
      );
    }
    if (expr.params.length != 1) {
      throw ArgumentError(
        'Queryable.$opName: lambda must take exactly 1 '
        'parameter, got ${expr.params.length}',
      );
    }
    return expr;
  }

  LambdaExpr _requireResult2(String opName, Expr expr) {
    if (expr is! LambdaExpr) {
      throw ArgumentError(
        'Queryable.$opName: resultSelector must be a '
        'LambdaExpr, got ${expr.runtimeType}',
      );
    }
    if (expr.params.length != 2) {
      throw ArgumentError(
        'Queryable.$opName: resultSelector must take exactly '
        '2 parameters (outer, inner), got ${expr.params.length}',
      );
    }
    return expr;
  }

  LambdaExpr _requireResult3(String opName, Expr expr) {
    if (expr is! LambdaExpr) {
      throw ArgumentError(
        'Queryable.$opName: resultSelector must be a '
        'LambdaExpr, got ${expr.runtimeType}',
      );
    }
    if (expr.params.length != 3) {
      throw ArgumentError(
        'Queryable.$opName: resultSelector must take exactly '
        '3 parameters (outer, inners, key), got ${expr.params.length}',
      );
    }
    return expr;
  }

  ///: `ORDER BY rowid DESC`. Reverses
  /// the natural order of the result. Works on any
  /// table that has an implicit `rowid` (i.e. NOT
  /// declared `WITHOUT ROWID`). Composable with
  /// `where_` / `take_` / `skip_` / `select_`.
  Queryable<T> reverse_() {
    return Queryable._(
      _provider,
      _table,
      _reader,
      meta: _meta,
      where: _where,
      select: _select,
      distinct: _distinct,
      orderBy: <_OrderByClause>[
        _OrderByClause(
          LambdaExpr(
            <ParamExpr>[ParamExpr('u')],
            Expr.member(ParamExpr('u'), 'rowid'),
          ),
          descending: true,
        ),
      ],
      take: _take,
      skip: _skip,
      changeTracker: _changeTracker,
      asyncProvider: _asyncProvider,
    );
  }

  /// (terminal): materialises the source
  /// and groups by [keySelector]. Returns an
  /// `ILookup<TKey, T>` — a multi-valued dictionary.
  ILookup<TKey, T> toLookup_<TKey>({required Expr keySelector}) {
    final LambdaExpr lambda = _requireLambda('toLookup_', keySelector);
    if (lambda.params.length != 1) {
      throw ArgumentError(
        'Queryable.toLookup_: keySelector must take exactly 1 '
        'parameter, got ${lambda.params.length}',
      );
    }
    return buildLookup<T, TKey>(toList_(), lambda);
  }

  /// (terminal): combines [other] with the
  /// source element-wise. Returns a `List<(T, TInner)>`
  /// of pairs, stopping at the shorter of the two.
  ///
  /// No native SQL ZIP (SQLite has none); the result
  /// is computed in Dart after both sides are
  /// materialised.
  List<(T, TInner)> zip_<TInner>(Queryable<TInner> other) {
    final List<T> left = toList_();
    final List<TInner> right = other.toList_();
    final int n = left.length < right.length ? left.length : right.length;
    return <(T, TInner)>[
      for (int i = 0; i < n; i++) (left[i], right[i]),
    ];
  }

  // ───: closure LINQ overloads ────────────────────
  //
  // The `where_` / `orderBy_` / `orderByDescending_`
  // operators here are EXTENSION methods (declared
  // below) that accept a closure `(T) => …`
  // instead of an `Expr` tree. The closure is
  // evaluated in memory AFTER the SQL has been run.
  //
  // .where_((t) => t.status == 0) // closure
  // .where_(Expr.lambda([...], …)) // Expr (SQL)
  //
  // The two can be chained — the SQL filter runs
  // first (efficient), then the closure filter
  // applies on the smaller result.
}

// ────────────────────────────────────────────────────────────────────
// SqliteGroupedQueryable<K, T> — result of groupBy_.
// ────────────────────────────────────────────────────────────────────

/// A grouped queryable, produced by `groupBy_`.
///
/// The grouping itself is done in Dart: we execute the underlying
/// `SELECT *` SQL and partition the rows by the keySelector. The
/// result is a sequence of `IGrouping<TKey, T>` instances, in the
/// order in which keys were first encountered.
class SqliteGroupedQueryable<TKey, T> extends IQueryable<IGrouping<TKey, T>> {
  final Queryable<T> _source;

  /// AST path: the SQL-translatable key selector.
  /// Exactly one of [_keySelector] and [_closureKey]
  /// is set. The [groupBy_] method on the source
  /// queryable is responsible for the dispatch.
  final LambdaExpr? _keySelector;

  /// Closure path: the in-memory key selector.
  /// See [_keySelector] for the dispatch rule.
  final TKey Function(T)? _closureKey;

  SqliteGroupedQueryable._(this._source,
      {LambdaExpr? keySelector, TKey Function(T)? closureKey})
      : _keySelector = keySelector,
        _closureKey = closureKey {
    if ((keySelector == null) == (closureKey == null)) {
      throw ArgumentError(
        'SqliteGroupedQueryable: exactly one of '
        'keySelector / closureKey must be provided.',
      );
    }
  }

  @override
  IQueryProvider get provider => _source.provider;

  @override
  Expr? get expression => _keySelector;

  @override
  Iterator<IGrouping<TKey, T>> get iterator => _execute().iterator;

  /// Executes the underlying SQL and groups the rows in Dart.
  Iterable<IGrouping<TKey, T>> _execute() {
    final frag = _source.buildSelect();
    final rows = _source.db.selectWithBinds(frag.sql, frag.binds);
    final groups = <Object, List<T>>{};
    final order = <Object>[];
    for (final row in rows) {
      final t = _source.reader(row);
      //: dispatch on the key selector form.
      final Object k;
      if (_closureKey != null) {
        k = _closureKey(t) as Object;
      } else {
        final lambda = _keySelector!;
        final paramName = lambda.params.first.name;
        k = lambda.body.eval({paramName: t}) as Object;
      }
      if (groups.containsKey(k)) {
        groups[k]!.add(t);
      } else {
        groups[k] = [t];
        order.add(k);
      }
    }
    return order
        .map((k) => _SqlGrouping<TKey, T>(k as TKey, groups[k]!))
        .toList(growable: false);
  }

  /// Materializes the groups.
  List<IGrouping<TKey, T>> toList_() {
    return _execute().toList(growable: false);
  }

  /// Returns the number of groups (not the total number of rows).
  int count_() => _execute().length;
}

// ────────────────────────────────────────────────────────────────────
// SqliteJoinedQueryable<R> — result of join_ / groupJoin_.
// ────────────────────────────────────────────────────────────────────

/// A joined queryable, produced by `join_` or `groupJoin_`.
///
/// The join itself is done in Dart: the inner is materialized
/// once and indexed by key, the outer is fetched via SQL and the
/// matching pairs (or groups) are evaluated. The result is a flat
/// sequence (for `join_`) or one element per outer (for
/// `groupJoin_`, with empty inner list for no match).
class SqliteJoinedQueryable<R> extends IQueryable<R> {
  final Queryable<dynamic> _source;
  final _JoinOp _op;

  SqliteJoinedQueryable._({
    required Queryable<dynamic> source,
    required _JoinOp op,
  })  : _source = source,
        _op = op;

  @override
  IQueryProvider get provider => _source.provider;

  @override
  Expr? get expression => _op.result;

  @override
  Iterator<R> get iterator => _execute().iterator;

  /// Executes the inner + outer and materializes the join.
  Iterable<R> _execute() {
    // 1. Materialize inner.
    final innerList = _op.inner.toList();

    // 2. Build index.
    final index = <Object, List<dynamic>>{};
    if (_op.innerKeyClosure != null) {
      final ksel = _op.innerKeyClosure!;
      for (final i in innerList) {
        final k = ksel(i) as Object;
        (index.putIfAbsent(k, () => <dynamic>[])).add(i);
      }
    } else {
      final innerKey = _op.innerKey!;
      final innerParam = innerKey.params.first.name;
      for (final i in innerList) {
        final k = innerKey.body.eval({innerParam: i}) as Object;
        (index.putIfAbsent(k, () => <dynamic>[])).add(i);
      }
    }

    // 3. Materialize outer. We use `_materialize()`
    // (not the raw `buildSelect` + SQL scan) so that
    // any closure-based `where_` / `orderBy_` /
    // `take_` / `skip_` the user chained on the
    // source is applied. The raw SQL path would
    // skip in-memory filters and produce wrong
    // results for closure predicates like
    // `q.where_((u) => u.category == 'sci-fi')`.
    // `_materialize()` returns `List<TOuter>` (the
    // already-read entity objects), not raw row maps,
    // so we iterate entities directly below.
    final outerEntities = _source._materialize();

    // 4. Iterate outer, look up matches, evaluate result selector.
    final out = <R>[];
    final bool useClosure =
        _op.outerKeyClosure != null && _op.resultClosure != null;
    if (_op.isGroupJoin) {
      // Three params: (outer, inners, key).
      for (final o in outerEntities) {
        final Object ok;
        if (useClosure) {
          ok = _op.outerKeyClosure!(o) as Object;
        } else {
          final outerKey = _op.outerKey!;
          final outerParam = outerKey.params.first.name;
          ok = outerKey.body.eval({outerParam: o}) as Object;
        }
        final matches = index[ok] ?? const [];
        if (useClosure) {
          // `Function.apply` bypasses the runtime
          // type check on the argument list (the
          // closure's body still type-checks its
          // elements when it uses them). The regular
          // `resultClosure!(...)` form would fail
          // because `matches` is `List<dynamic>` but
          // the user typed the second param as
          // `Iterable<Book>`.
          out.add(
            Function.apply(_op.resultClosure!, [o, matches, ok]) as R,
          );
        } else {
          final resultLambda = _op.result!;
          final resultParams = resultLambda.params;
          final oName = resultParams[0].name;
          final iName = resultParams[1].name;
          final kName = resultParams[2].name;
          out.add(resultLambda.body.eval({
            oName: o,
            iName: matches,
            kName: ok,
          }) as R);
        }
      }
    } else {
      // Two params: (outer, inner). Yields one element per pair.
      for (final o in outerEntities) {
        final Object ok;
        if (useClosure) {
          ok = _op.outerKeyClosure!(o) as Object;
        } else {
          final outerKey = _op.outerKey!;
          final outerParam = outerKey.params.first.name;
          ok = outerKey.body.eval({outerParam: o}) as Object;
        }
        final matches = index[ok] ?? const [];
        if (useClosure) {
          for (final i in matches) {
            out.add(
              Function.apply(_op.resultClosure!, [o, i]) as R,
            );
          }
        } else {
          final resultLambda = _op.result!;
          final resultParams = resultLambda.params;
          final oName = resultParams[0].name;
          final iName = resultParams[1].name;
          for (final i in matches) {
            out.add(resultLambda.body.eval({
              oName: o,
              iName: i,
            }) as R);
          }
        }
      }
    }

    return out;
  }

  /// Materializes the joined sequence.
  List<R> toList_() => _execute().toList(growable: false);

  /// Returns the number of elements yielded by the join.
  int count_() => _execute().length;
}

/// (camelCase aliases): REMOVED in
/// the async-rename refactor. The async terminal
/// methods are now exposed directly under their
/// canonical names with the trailing underscore
/// (`toListAsync_`, `countAsync_`, `firstAsync_`,
/// `firstOrDefaultAsync_`, `anyAsync_`, `allAsync_`).
/// This matches the `where_` / `select_` /
/// `orderBy_` convention used everywhere else in
/// d_rocket: suffixed `_` to avoid clashing with
/// `Iterable` methods. The user-facing call site
/// in [db_set_extension.dart] is unchanged
/// structurally, but the public methods are now
/// the `*Async_` ones.

// ───: selectMany_ (CROSS JOIN flattened) ────────

///: data carrier for [selectMany_]. Holds
/// the inner `Queryable<TInner>` and the result selector
/// `(T, TInner) => TResult`.
class _SelectManyOp<TInner> {
  _SelectManyOp(this.inner, this.result);
  final IQueryable<TInner> inner;
  final Expr result;
}

///: the iterable wrapper for `selectMany_`.
/// Mirrors the `SqliteJoinedQueryable` pattern: outer is
/// fetched via SQL, inner is fetched via SQL (or materialised
/// in memory), and the cartesian product is emitted through
/// the result selector. Composes with `where_` / `orderBy_` /
/// `take_` / `skip_` applied to the outer side.
class SqliteSelectManyQueryable<R> extends IQueryable<R> {
  final Queryable<dynamic> _source;
  final _SelectManyOp<dynamic> _op;

  SqliteSelectManyQueryable._({
    required Queryable<dynamic> source,
    required _SelectManyOp<dynamic> op,
  })  : _source = source,
        _op = op;

  @override
  IQueryProvider get provider => _source.provider;

  @override
  Expr? get expression => _op.result;

  @override
  Iterator<R> get iterator => _execute().iterator;

  ///: materialise outer via SQL, inner via
  /// SQL (or in-memory), then cross-join in Dart.
  List<R> toList_() => _execute();

  List<R> _execute() {
    // Materialise the inner side first.
    final innerList = _op.inner.toList();
    // Materialise the outer side via SQL (respects
    // chained where_/orderBy_/take_/skip_ on the source).
    final outerFrag = _source.buildSelect();
    final outerRows =
        _source.db.selectWithBinds(outerFrag.sql, outerFrag.binds);
    final out = <R>[];
    final LambdaExpr resultLambda = _op.result is LambdaExpr
        ? _op.result as LambdaExpr
        : throw ArgumentError(
            'selectMany_: resultSelector must be a LambdaExpr',
          );
    final resultParams = resultLambda.params;
    final body = resultLambda.body;
    if (resultParams.length == 2) {
      // (outer, inner) — one result per pair.
      final oName = resultParams[0].name;
      final iName = resultParams[1].name;
      for (final row in outerRows) {
        final o = _source.reader(row);
        for (final i in innerList) {
          out.add(body.eval({oName: o, iName: i}) as R);
        }
      }
    } else {
      throw ArgumentError(
        'selectMany_: resultSelector must take exactly 2 '
        'parameters (outer, inner), got ${resultParams.length}',
      );
    }
    return out;
  }

  ///: row count.
  int count_() => _execute().length;
}

/// (SQL-backed CROSS JOIN): the C#-style
/// `from o in outer from i in inner select result(o, i)`.
/// Composes with `where_` / `orderBy_` / `take_` / `skip_`
/// applied to the outer side. The inner is materialised
/// in memory (it's an `IQueryable` we iterate once).
///
/// The result selector is a 2-arg lambda: `(outer, inner)
/// => TResult`. For 1-arg lambdas, see the convenience
/// overload.
extension QueryableSelectManyOnQueryable<T> on Queryable<T> {
  ///: selectMany_ with a 2-arg result
  /// selector `(outer, inner) => TResult`.
  SqliteSelectManyQueryable<R> selectMany_<TInner, R>({
    required IQueryable<TInner> inner,
    required Expr resultSelector,
  }) {
    return SqliteSelectManyQueryable<R>._(
      source: this,
      op: _SelectManyOp<TInner>(inner, resultSelector),
    );
  }
}

// ───: set operations (union_, intersect_, except_) ────

///: kind of SQL/Dart set operation. The
/// string value is what's emitted in the SQL comment for
/// debugging (the actual set op is done in Dart because
/// the two queryables may have different `where_`/`orderBy_`
/// chains — SQL `UNION` requires matching column counts
/// and types, which is hard to guarantee generically).
enum _SetOpKind { union, intersect, except }

///: the iterable wrapper for set operations.
/// Loads both queryables, then computes the set op in Dart.
/// Returns a `Queryable<T>` (preserves the LINQ chain
/// contract — user can chain `where_` / `orderBy_` /
/// `toList_` / `toListAsync_` on the result).
class SqliteSetOpQueryable<T> extends Queryable<T> {
  final Queryable<T> _left;
  final Queryable<T> _right;
  final _SetOpKind _kind;

  SqliteSetOpQueryable._({
    required Queryable<T> left,
    required Queryable<T> right,
    required _SetOpKind kind,
    required SqliteQueryProvider provider,
    required String table,
    required ResultRowReader<T> reader,
    required EntityMeta meta,
    AsyncQueryProvider? asyncProvider,
  })  : _left = left,
        _right = right,
        _kind = kind,
        super._(
          provider,
          table,
          reader,
          meta: meta,
          asyncProvider: asyncProvider,
        );

  @override
  List<T> toList_() {
    final leftList = _left.toList_();
    final rightList = _right.toList_();
    switch (_kind) {
      case _SetOpKind.union:
        return <T>[...leftList, ...rightList];
      case _SetOpKind.intersect:
        final rightSet = rightList.toSet();
        return leftList.where(rightSet.contains).toList();
      case _SetOpKind.except:
        final rightSet = rightList.toSet();
        return leftList.where((T x) => !rightSet.contains(x)).toList();
    }
  }
}

/// (set operations): union/intersect/except.
/// The result preserves the outer queryable's chain
/// (so chained `where_` / `orderBy_` on the left work) and
/// the right side is materialised eagerly.
///
/// MVP simplification: set ops are done in Dart (not
/// via SQL `UNION` / `INTERSECT` / `EXCEPT`). The
/// 9.7+ roadmap item is to emit native SQL `UNION` when
/// the two sides are structurally identical (same
/// projection, same `where_` shape).
extension QueryableSetOpsOnQueryable<T> on Queryable<T> {
  ///: `UNION` (concatenation with
  /// duplicates). Preserves the left's chain.
  SqliteSetOpQueryable<T> union_(Queryable<T> other) {
    return SqliteSetOpQueryable<T>._(
      left: this,
      right: other,
      kind: _SetOpKind.union,
      provider: _provider,
      table: _table,
      reader: _reader,
      meta: _meta,
      asyncProvider: _asyncProvider,
    );
  }

  ///: `INTERSECT` (rows in both).
  SqliteSetOpQueryable<T> intersect_(Queryable<T> other) {
    return SqliteSetOpQueryable<T>._(
      left: this,
      right: other,
      kind: _SetOpKind.intersect,
      provider: _provider,
      table: _table,
      reader: _reader,
      meta: _meta,
      asyncProvider: _asyncProvider,
    );
  }

  ///: `EXCEPT` (rows in left but not in
  /// right).
  SqliteSetOpQueryable<T> except_(Queryable<T> other) {
    return SqliteSetOpQueryable<T>._(
      left: this,
      right: other,
      kind: _SetOpKind.except,
      provider: _provider,
      table: _table,
      reader: _reader,
      meta: _meta,
      asyncProvider: _asyncProvider,
    );
  }
}

// ───: closure LINQ (handled by the `Object`
// dispatch in the instance methods above — no
// extension is needed. See `where_(Object)`.)

// ───: closure LINQ extensions ─────────────────────
