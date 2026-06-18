/// 🚀 d_rocket_engine_sqlite — SQLite engine for d_rocket 2.0.
///
/// The runtime that powers the `Db` / `DbContext` /
/// `DbSet` / SQL `Queryable` / auto-migrations stack
/// of [d_rocket](https://pub.dev/packages/d_rocket).
///
/// ## What this package is
///
/// `d_rocket` is engine-agnostic. Each database
/// backend (SQLite, Postgres, libsql_wasm, ...)
/// ships as its own `d_rocket_engine_*` package.
/// This package is the SQLite implementation.
///
/// ## Usage
///
/// ```yaml
/// # pubspec.yaml
/// dependencies:
///   d_rocket: ^2.0.0
///   d_rocket_engine_sqlite: ^2.0.0
/// ```
///
/// ```dart
/// import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
///
/// void main() async {
///   // Required: register the SQLite engine once
///   // at app startup. Without this call,
///   // `Db.open` / `Db.inMemory` throw a clear
///   // "no engine registered" error.
///   dRocketSqlite();
///   initializeD();
///   final db = await Db.open(path: 'app.db');
/// }
/// ```
library;

import 'package:d_rocket/d_rocket.dart';

import 'src/sqlite_engine.dart';

// Re-export d_rocket core so consumers can
// import everything they need from
// `d_rocket_engine_sqlite`. The engine package
// is the canonical entry point for the
// Db-based stack; d_rocket core is the canonical
// entry point for the engine-agnostic layers
// (serialization, REST, sync, realtime).
export 'package:d_rocket/d_rocket.dart';

export 'src/db.dart';
export 'src/db_context_extension.dart';
export 'src/db_set_extension.dart';
export 'src/queryable.dart';
export 'src/sql/encryption_config.dart';
export 'src/sql/encryption_status.dart';
//: `sql/fragment.dart` was the old location
// of `SqlFragment`; in 2.0.0 the class lives in
// d_rocket core (`src/linq/sql/sql_fragment.dart`)
// and is re-exported by the d_rocket barrel.
// The engine no longer re-exports it directly
// to avoid duplicate definitions when the
// engine is imported alongside d_rocket.
export 'src/sql/key_provider.dart';
export 'src/sql/query_provider.dart';
//: `redact_pragma_key.dart` lives in d_rocket core
// (the function is a pure string transformation).
// d_rocket_engine_sqlite re-exports d_rocket
// already, so `redactPragmaKey` is reachable
// through this barrel without a duplicate export.
export 'src/sql/sqlcipher_probe.dart';
//: `src/sql/translator.dart` is gone. The
// `SqlTranslator` is in d_rocket core
// (`src/linq/sql/sql_translator.dart`); the
// `d_rocket` barrel re-exports it. The
// engine provides the `SqliteDialect`
// (a SQLite-flavoured `DefaultDialect`
// subclass) that callers pass to
// `SqlTranslator(dialect: ...)`.
export 'src/sql/sqlite_dialect.dart';
export 'src/sqlite_engine.dart';

/// Top-level registration helper. Call once at
/// app startup before any `Db.open` /
/// `Db.inMemory` call. Idempotent — calling it
/// twice replaces the previously registered
/// engine with a fresh `SqliteEngine` (the
/// `EngineRegistry` only holds one slot).
void dRocketSqlite() {
  EngineRegistry.register(const SqliteEngine());
}
