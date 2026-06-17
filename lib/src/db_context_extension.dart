//: the `sqliteProvider` getter lives in
// the SQLite package (not in `d_rocket` core). The
// `DbContext` base class exposes a generic
// `asyncProvider` getter; the SQLite package adds
// the SQLite-specific typed `sqliteProvider` for
// users who want the explicit SQLite type rather
// than the abstract `AsyncQueryProvider` interface.
//
// MigrationBase note: in `d_rocket 1.0` the
// `sqliteProvider` getter was a method on the
// base `DbContext`. In 1.1 it's an
// extension that lives in this package. Existing
// subclasses that overrode `sqliteProvider` must
// either:
// (a) switch to overriding `asyncProvider`
// (recommended), or
// (b) keep the override — the extension takes
// precedence over the `null` default but
// Dart's `super`-resolution rules mean
// the override still wins.

import 'package:d_rocket/d_rocket.dart';

import 'sql/query_provider.dart';

extension SqliteRocketDbContextExtension on DbContext {
  /// The optional [SqliteQueryProvider] backing this
  /// context. Resolves to the underlying
  /// [AsyncQueryProvider] when the latter is a
  /// [SqliteQueryProvider], otherwise `null`.
  SqliteQueryProvider? get sqliteProvider {
    final AsyncQueryProvider? async = asyncProvider;
    return async is SqliteQueryProvider ? async : null;
  }
}
