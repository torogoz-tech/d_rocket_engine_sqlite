/// The SQLite-flavoured [SqlDialect].
///
/// The default dialect (in d_rocket core) IS
/// the SQLite dialect, so [SqliteDialect] is
/// an alias for [DefaultDialect]. The class
/// exists so the engine can be explicit
/// ("we want the SQLite dialect") and so
/// future SQLite-specific tweaks (e.g.
/// `JSONB` deprecation, PRAGMA quirks) have
/// a place to live.
library;

import 'package:d_rocket/d_rocket.dart';

/// The SQLite dialect. Aliased to
/// [DefaultDialect] for now; the class is
/// kept so the engine can pass it explicitly
/// and so future SQLite-specific tweaks have
/// a place to live.
class SqliteDialect extends DefaultDialect {
  const SqliteDialect();
}
