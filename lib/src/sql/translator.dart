/// Translator: `Expr` tree → SQL fragment.
///
/// Implements [ExprVisitor] for the 9 base [Expr] node types defined
/// in `package:d_rocket/d_rocket.dart`:
/// `Const`, `Param`, `Lambda`, `Binary`, `Unary`, `MemberAccess`,
/// `MethodCall`, `Null`, `List`.
///
/// What this translator does NOT cover in:
/// * Joins (the `join_` / `groupJoin_` operators).
/// * Grouping (`groupBy_`).
/// * Aggregates other than simple `COUNT` in the terminal.
/// * User-defined SQL functions.
///
/// These are scheduled for and later (see the roadmap).
library;

import 'package:d_rocket/d_rocket.dart';

import 'fragment.dart';

/// Walks an [Expr] tree and produces a [SqlFragment].
///
/// The translator is stateless (no instance-level state). Each
/// visit method builds a [SqlFragment] with its own bind list; the
/// caller combines them. This makes the visitor safe to reuse and
/// the bind-ordering explicit.
class SqlTranslator implements ExprVisitor<SqlFragment> {
  /// The alias for the table whose columns the lambda's body refers
  /// to. Default: `'u'`. Must match the parameter name of the lambda
  /// being translated.
  final String tableAlias;

  SqlTranslator({this.tableAlias = 'u'});

  /// Convenience for tests + callers: the visitor
  /// interface is `Expr.accept<R>(ExprVisitor<R>)`.
  /// This is the same call, just spelled out.
  SqlFragment translate(Expr e) => e.accept(this);

  /// Translates a top-level [LambdaExpr] predicate (the body of a
  /// `where_` clause). Returns a [SqlFragment] suitable for use
  /// after a SQL `WHERE` keyword.
  ///
  /// The [lambda] argument is typed as [Expr] (not [LambdaExpr])
  /// because the d_rocket factory `Expr.lambda(...)` returns the
  /// base type. We do a runtime check.
  SqlFragment translateLambda(Expr lambda) {
    if (lambda is! LambdaExpr) {
      throw ArgumentError(
        'translateLambda: argument must be a LambdaExpr, got '
        '${lambda.runtimeType}',
      );
    }
    if (lambda.params.length != 1) {
      throw ArgumentError(
        'translateLambda: lambda must take exactly 1 parameter, got '
        '${lambda.params.length}',
      );
    }
    if (lambda.params.first.name != tableAlias) {
      throw ArgumentError(
        'translateLambda: lambda parameter name '
        "'${lambda.params.first.name}' does not match the table alias "
        "'$tableAlias'",
      );
    }
    return lambda.body.accept(this);
  }

  // ─── Visitor implementation ───────────────────────────────────────

  @override
  SqlFragment visitConst(ConstExpr e) {
    if (e.value == null) {
      // ConstExpr(null) is a different node from NullExpr semantically
      // (ConstExpr is the value `null` of any type, NullExpr is the
      // type-`Null` singleton). Both map to `NULL` in SQL.
      return const SqlFragment('NULL');
    }
    return SqlFragment('?', [e.value]);
  }

  @override
  SqlFragment visitParam(ParamExpr e) {
    if (e.name == tableAlias) {
      // Shouldn't typically appear directly in a predicate (a column
      // reference is a `MemberAccess` on the alias). We emit the
      // alias anyway to surface unexpected trees to the user.
      return SqlFragment(tableAlias);
    }
    throw StateError(
      'SqlTranslator: unknown parameter "${e.name}" '
      '(expected the table alias "$tableAlias"). '
      'Fase 2.1 only supports top-level lambdas whose parameter is '
      'the table alias.',
    );
  }

  @override
  SqlFragment visitLambda(LambdaExpr e) {
    // Translating a nested lambda is unusual. Walk its body and
    // return the result; the table-alias check is bypassed.
    return e.body.accept(this);
  }

  @override
  SqlFragment visitBinary(BinaryExpr e) {
    final op = _mapBinaryOp(e.op);
    final l = e.left.accept(this);
    final r = e.right.accept(this);
    return SqlFragment(
      '(${l.sql} $op ${r.sql})',
      [...l.binds, ...r.binds],
    );
  }

  /// Maps the in-memory DSL operator strings to SQL.
  ///
  /// We use `<>` for `!=` to be SQL-portable; SQLite also accepts
  /// `!=` but `<>` is the standard.
  static String _mapBinaryOp(String op) {
    return switch (op) {
      '==' => '=',
      '!=' => '<>',
      '<' => '<',
      '>' => '>',
      '<=' => '<=',
      '>=' => '>=',
      '&&' => 'AND',
      '||' => 'OR',
      '+' => '+',
      '-' => '-',
      '*' => '*',
      '/' => '/',
      '%' => '%',
      _ => throw StateError(
          'SqlTranslator: unsupported binary op "$op" for SQL',
        ),
    };
  }

  @override
  SqlFragment visitUnary(UnaryExpr e) {
    final op = switch (e.op) {
      '!' => 'NOT',
      '-' => '-',
      _ => throw StateError(
          'SqlTranslator: unsupported unary op "${e.op}" for SQL',
        ),
    };
    final operand = e.operand.accept(this);
    return SqlFragment('$op (${operand.sql})', operand.binds);
  }

  @override
  SqlFragment visitMemberAccess(MemberAccessExpr e) {
    if (e.target is ParamExpr && (e.target as ParamExpr).name == tableAlias) {
      // NOTE: we deliberately do NOT double-quote the column name.
      // SQLite treats double-quoted strings that don't match a
      // known column/table as string literals (a SQLite "misfeature"
      // for compatibility with old MySQL-style queries). If the
      // user writes `nope` (a non-existent column) we want SQLite to
      // raise "no such column: nope", not silently return 0 rows.
      // Reserved-word columns are extremely unusual in practice; we
      // can revisit in if needed.
      return SqlFragment(e.name);
    }
    // .d: member access on a NavRef.
    // `o.customer.name` → the visitor first sees
    // the NavRef, then a MemberAccessExpr on it.
    // We translate to `<alias>.<memberName>` and
    // ensure the JOIN is collected (the NavRef
    // visitor already does that when it walks
    // the target via accept(this)).
    if (e.target is NavRef) {
      final NavRef nav = e.target as NavRef;
      // Trigger the NavRef's visit to ensure the
      // JOIN is collected (no-op if already).
      nav.accept(this);
      final String alias =
          nav.targetAlias.isNotEmpty ? nav.targetAlias : nav.targetTable[0];
      return SqlFragment('$alias.${e.name}', const <Object?>[]);
    }
    throw StateError(
      'SqlTranslator: member access on a non-alias target is not '
      'supported in Fase 2.1. Got ${e.target.runtimeType}.',
    );
  }

  @override
  SqlFragment visitMethodCall(MethodCallExpr e) {
    if (e.target is! MemberAccessExpr) {
      throw StateError(
        'SqlTranslator: method calls are only supported on columns '
        'of the table alias in Fase 2.1. Got ${e.target.runtimeType}.',
      );
    }
    final member = e.target as MemberAccessExpr;
    if (member.target is! ParamExpr ||
        (member.target as ParamExpr).name != tableAlias) {
      throw StateError(
        'SqlTranslator: method call on a non-alias column is not '
        'supported in Fase 2.1.',
      );
    }
    final col = member.name;

    if (e.method == 'startsWith' && e.args.length == 1) {
      return _startsWithFragment(col, e.args[0]);
    }
    if (e.method == 'endsWith' && e.args.length == 1) {
      return _endsWithFragment(col, e.args[0]);
    }
    if (e.method == 'contains' && e.args.length == 1) {
      // `INSTR(col, x) > 0` is case-sensitive, matching the
      // in-memory `String.contains` semantics. (SQLite's `LIKE` is
      // case-insensitive for ASCII by default, which would diverge
      // from the d_rocket in-memory behavior.)
      return _binaryOnStringArg(col, e.args[0], 'INSTR', '>');
    }
    if (e.method == 'length' && e.args.isEmpty) {
      return SqlFragment('LENGTH($col)');
    }
    if (e.method == 'toUpperCase' && e.args.isEmpty) {
      return SqlFragment('UPPER($col)');
    }
    if (e.method == 'toLowerCase' && e.args.isEmpty) {
      return SqlFragment('LOWER($col)');
    }
    if (e.method == 'trim' && e.args.isEmpty) {
      return SqlFragment('TRIM($col)');
    }
    if (e.method == 'isEmpty' && e.args.isEmpty) {
      return SqlFragment('($col = \'\')');
    }
    if (e.method == 'isNotEmpty' && e.args.isEmpty) {
      return SqlFragment('($col <> \'\')');
    }
    throw StateError(
      'SqlTranslator: method "${e.method}" is not supported for SQL. '
      'Supported: startsWith, endsWith, contains, length, '
      'toUpperCase, toLowerCase, trim, isEmpty, isNotEmpty.',
    );
  }

  /// `name.startsWith(x)` → `substr(col, 1, ?) = ?`
  ///
  /// Case-sensitive (matches in-memory `String.startsWith`).
  /// Binds: `[length(x), x]`.
  SqlFragment _startsWithFragment(String col, Expr arg) {
    final argFrag = _extractStringArg(col, arg, 'startsWith');
    final x = argFrag.binds[0] as String;
    return SqlFragment(
      '(substr($col, 1, ?) = ?)',
      [x.length, x],
    );
  }

  /// `name.endsWith(x)` → `substr(col, length(col) - ? + 1) = ?`
  ///
  /// Case-sensitive. Binds: `[length(x), x]`.
  SqlFragment _endsWithFragment(String col, Expr arg) {
    final argFrag = _extractStringArg(col, arg, 'endsWith');
    final x = argFrag.binds[0] as String;
    return SqlFragment(
      '(substr($col, length($col) - ? + 1) = ?)',
      [x.length, x],
    );
  }

  /// `name.contains(x)` and similar: builds `INSTR(col, ?) <op> ?`
  /// (or any binary op). Binds: `[x, x]`.
  SqlFragment _binaryOnStringArg(
    String col,
    Expr arg,
    String fn,
    String op,
  ) {
    final argFrag = _extractStringArg(col, arg, 'contains');
    final x = argFrag.binds[0] as String;
    return SqlFragment('($fn($col, ?) $op ?)', [x, 0]);
  }

  /// Validates and unwraps the argument of a String method.
  ///
  /// The argument must be a single-bind expression whose value is a
  /// `String`. Returns a fragment whose only bind is the String.
  SqlFragment _extractStringArg(String col, Expr arg, String opName) {
    final argFrag = arg.accept(this);
    if (argFrag.sql != '?' || argFrag.binds.length != 1) {
      throw StateError(
        'SqlTranslator: the argument of $opName must be a constant '
        '(or another expression with a single bind). Got fragment '
        '$argFrag.',
      );
    }
    final argValue = argFrag.binds.first;
    if (argValue is! String) {
      throw StateError(
        'SqlTranslator: the argument of $opName must be a String, '
        'got ${argValue.runtimeType}.',
      );
    }
    return argFrag;
  }

  @override
  SqlFragment visitNull(NullExpr e) => const SqlFragment('NULL');

  @override
  SqlFragment visitList(ListExpr e) {
    final frags = e.items.map((item) => item.accept(this)).toList();
    final placeholders = frags.map((f) => f.sql).join(', ');
    final binds = frags.expand((f) => f.binds).toList();
    return SqlFragment('($placeholders)', binds);
  }

  // ─── .e: map / ternary / null-aware ────────────────

  @override
  SqlFragment visitMapLiteral(MapLiteralExpr e) {
    // .f: SQLite 3.38+ has the
    // `json_object(key, value, key, value, …)` SQL
    // function. We use it to materialise the map
    // literal as a JSON string. The user can then
    // extract fields with `json_extract(map, '$.k')`.
    //
    // Why JSON: a true SQL "map" type doesn't
    // exist. JSON is the standard surrogate for
    // key-value pairs in modern SQL. The output of
    // this Expr is a TEXT (JSON string).
    //
    // Pre-3.38 fallback: if the user is on an
    // older SQLite, the SQL will fail at execute
    // time with a clear "no such function: json_object"
    // from the engine. We document this rather than
    // throw at translation time (which would block
    // the rest of the query).
    if (e.entries.isEmpty) {
      return const SqlFragment("json_object()", <Object?>[]);
    }
    final List<String> parts = <String>[];
    final List<Object?> binds = <Object?>[];
    for (final entry in e.entries) {
      final kFrag = entry.key.accept(this);
      final vFrag = entry.value.accept(this);
      parts.add(kFrag.sql);
      parts.add(vFrag.sql);
      binds.addAll(kFrag.binds);
      binds.addAll(vFrag.binds);
    }
    return SqlFragment('json_object(${parts.join(', ')})', binds);
  }

  @override
  SqlFragment visitTernary(TernaryExpr e) {
    // .e: `CASE WHEN cond THEN thenBranch
    // ELSE elseBranch END`. This is the SQL standard
    // ternary — works in SQLite, Postgres, MySQL.
    final condFrag = e.cond.accept(this);
    final thenFrag = e.thenBranch.accept(this);
    final elseFrag = e.elseBranch.accept(this);
    return SqlFragment(
      'CASE WHEN ${condFrag.sql} THEN ${thenFrag.sql} ELSE ${elseFrag.sql} END',
      <Object?>[...condFrag.binds, ...thenFrag.binds, ...elseFrag.binds],
    );
  }

  @override
  SqlFragment visitCoalesce(CoalesceExpr e) {
    // .e: `COALESCE(a, b)`. Standard
    // SQL; returns the first non-null argument.
    final leftFrag = e.left.accept(this);
    final rightFrag = e.right.accept(this);
    return SqlFragment(
      'COALESCE(${leftFrag.sql}, ${rightFrag.sql})',
      <Object?>[...leftFrag.binds, ...rightFrag.binds],
    );
  }

  @override
  SqlFragment visitNullSafeAccess(NullSafeAccessExpr e) {
    // .f: `CASE WHEN target IS NULL
    // THEN NULL ELSE target.member END`. This is
    // the standard SQL surrogate for `?.`.
    //
    // The "else" branch is a regular member access
    // (target.member), so for a column reference it
    // works directly. For a JOIN-based member
    // access, the user would have to make the
    // member access self-contained first (e.g.
    // pre-LEFT-JOIN'd into a column).
    final targetFrag = e.target.accept(this);
    // .f: build the member-access fragment
    // directly, bypassing the visitor (which would
    // emit a non-null-safe member). We use
    // `MemberAccessExpr` so the visitor's
    // translation is consistent.
    final memberExpr = MemberAccessExpr(e.target, e.member);
    final memberFrag = memberExpr.accept(this);
    return SqlFragment(
      'CASE WHEN ${targetFrag.sql} IS NULL '
      'THEN NULL '
      'ELSE ${memberFrag.sql} '
      'END',
      <Object?>[...targetFrag.binds, ...memberFrag.binds],
    );
  }

  // ───: aggregate / groupBy / having / join ─────────────

  @override
  SqlFragment visitAggregate(AggregateExpr e) {
    // Whitelist the supported function names so a
    // typo (`Expr.aggregate('SUUM', …)`) doesn't
    // produce a query the server will reject.
    const Set<String> kSupported = <String>{
      'SUM',
      'COUNT',
      'AVG',
      'MIN',
      'MAX',
    };
    if (!kSupported.contains(e.function.toUpperCase())) {
      throw StateError(
        'SqlTranslator: aggregate function must be one of '
        'SUM, COUNT, AVG, MIN, MAX — got "${e.function}".',
      );
    }
    // `COUNT(*)` is a special case (no selector).
    if (e.selector is NullExpr) {
      return SqlFragment('${e.function.toUpperCase()}(*)');
    }
    final SqlFragment inner = e.selector.accept(this);
    final String distinct = e.distinct ? 'DISTINCT ' : '';
    return SqlFragment(
      '${e.function.toUpperCase()}($distinct${inner.sql})',
      inner.binds,
    );
  }

  @override
  SqlFragment visitGroupBy(GroupByExpr e) {
    // The translator does NOT build the full
    // `SELECT ... GROUP BY ...` statement here.
    // It returns the GROUP BY fragment, which
    // the caller (Queryable) splices into the
    // outer SELECT. This keeps the translator
    // composable: the `WHERE` translator + the
    // `GROUP BY` translator + the `HAVING`
    // translator each return their own fragment.
    final SqlFragment key = e.keySelector.accept(this);
    final List<SqlFragment> parts = <SqlFragment>[key];
    if (e.elementSelector != null) {
      parts.add(e.elementSelector!.accept(this));
    }
    final String cols = parts.map((SqlFragment f) => f.sql).join(', ');
    final List<Object?> binds =
        parts.expand((SqlFragment f) => f.binds).toList();
    return SqlFragment('GROUP BY $cols', binds);
  }

  @override
  SqlFragment visitHaving(HavingExpr e) {
    final SqlFragment pred = e.predicate.accept(this);
    return SqlFragment('HAVING ${pred.sql}', pred.binds);
  }

  @override
  SqlFragment visitJoin(JoinExpr e) {
    // The translator returns the JOIN clause
    // (table + ON) for splicing into the outer
    // SELECT. The caller (Queryable) handles the
    // `outer` table, the SELECT list, and the
    // result-selector wrapping.
    final SqlFragment inner = e.inner.accept(this);
    final SqlFragment outerKey = e.outerKey.accept(this);
    final SqlFragment innerKey = e.innerKey.accept(this);
    final String type = e.joinType.toUpperCase();
    if (type != 'INNER' &&
        type != 'LEFT' &&
        type != 'RIGHT' &&
        type != 'FULL') {
      throw StateError(
        'SqlTranslator: joinType must be INNER, LEFT, RIGHT, or FULL '
        '— got "${e.joinType}".',
      );
    }
    return SqlFragment(
      '$type JOIN ${inner.sql} ON ${outerKey.sql} = ${innerKey.sql}',
      <Object?>[...inner.binds, ...outerKey.binds, ...innerKey.binds],
    );
  }

  @override
  SqlFragment visitNavRef(NavRef e) {
    // .d: when the translator sees a
    // navigation reference, it returns a column
    // reference for the target (e.g. `c.id`)
    // AND accumulates a JOIN clause for the
    // outer query.
    //
    // The caller (the SELECT generator) splices
    // all collected JOINs into the FROM clause.
    _collectJoin(e);
    final String alias = e.targetAlias.isNotEmpty
        ? e.targetAlias
        : _aliasForTable(e.targetTable);
    return SqlFragment('$alias.${e.pkColumn}', const <Object?>[]);
  }

  /// .d: a list of JOIN clauses
  /// collected by the translator during a
  /// single SELECT generation. Each entry is
  /// `INNER JOIN <table> <alias> ON <alias>.<pk> = <outer>.<fk>`.
  final List<String> _collectedJoins = <String>[];

  /// .d: the alias used for a
  /// table in the JOIN (e.g. `c` for
  /// `customers`). For MVP we use the first
  /// char; in a follow-up we can do
  /// de-duplication.
  String _aliasForTable(String table) {
    if (table.isEmpty) return 't';
    return table[0];
  }

  /// .d: register a JOIN clause for
  /// a NavRef. De-duplicates by (table, alias).
  void _collectJoin(NavRef e) {
    final String alias = e.targetAlias.isNotEmpty
        ? e.targetAlias
        : _aliasForTable(e.targetTable);
    final String joinSql =
        'INNER JOIN ${e.targetTable} $alias ON $alias.${e.pkColumn} = '
        '${e.fkColumn}';
    // De-dup: skip if the same (table, alias) is
    // already there.
    if (_collectedJoins.contains(joinSql)) return;
    _collectedJoins.add(joinSql);
  }

  /// .d: expose the collected JOIN
  /// clauses for the outer query to splice in.
  /// Returns a copy; the caller is free to
  /// modify the list.
  List<String> drainCollectedJoins() {
    final List<String> out = List<String>.from(_collectedJoins);
    _collectedJoins.clear();
    return out;
  }
}
