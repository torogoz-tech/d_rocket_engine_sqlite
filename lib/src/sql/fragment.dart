/// A piece of SQL produced by the translator.
library;

/// A SQL fragment together with its bind parameters.
///
/// Returned by [ExprVisitor] implementations when they walk an [Expr]
/// tree. Multiple fragments can be combined (e.g. WHERE clause + LIMIT)
/// using [SqlFragment.combine].
class SqlFragment {
  /// The SQL text. May contain `?` placeholders that are bound by
  /// [binds] in order.
  final String sql;

  /// The values to bind to the `?` placeholders, in order.
  final List<Object?> binds;

  const SqlFragment(this.sql, [List<Object?>? binds])
      : binds = binds ?? const [];

  /// Combines two fragments side-by-side: `(this) AND (other)`, etc.
  /// The two `sql` strings are concatenated with a single space and
  /// the bind lists are concatenated.
  SqlFragment combine(SqlFragment other) =>
      SqlFragment('$sql ${other.sql}', [...binds, ...other.binds]);

  /// Wraps the current fragment in parentheses.
  SqlFragment parens() => SqlFragment('($sql)', binds);

  /// Returns a new fragment whose SQL is prefixed with [prefix]
  /// (with a trailing space if not already present).
  SqlFragment withPrefix(String prefix) {
    if (prefix.isEmpty) return this;
    final sep = prefix.endsWith(' ') ? '' : ' ';
    return SqlFragment('$prefix$sep$sql', binds);
  }

  @override
  String toString() => 'SqlFragment($sql, binds: $binds)';
}
