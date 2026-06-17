# d_rocket_engine_sqlite

> **The SQLite engine for [d_rocket](https://pub.dev/packages/d_rocket) 2.0.**
> Register once at app startup; the `Db` / `DbContext` /
> `DbSet` / LINQ-SQL `Queryable` / auto-migrations
> stack lights up. If you only need serialization,
> REST, or LINQ-over-collections, you do not need
> this package — `d_rocket` stays light.

## What this package is

`d_rocket` is a single framework for the data layer
of a Dart/Flutter app. The core package (`d_rocket`)
ships the six layers (serialization, REST, LINQ,
ORM, sync, realtime), but the ORM layer needs a
database engine to talk to. Before 2.0 the SQLite
engine was bundled inside `d_rocket`, which meant
**every** consumer of `d_rocket` paid for the
`libsqlite3` native lib (~500KB-1MB on
Android/iOS/desktop) — even users who only wanted
`@Serializable` and `@RestClient`.

As of 2.0, the SQLite engine is its own package.
Consumers opt in:

```yaml
# pubspec.yaml
dependencies:
  d_rocket: ^2.0.0

  # Only add this if you use Db / DbContext / DbSet /
  # auto-migrations. Without it (or another
  # d_rocket_engine_* engine), Db.open throws a
  # clear "no engine registered" error.
  d_rocket_engine_sqlite: ^2.0.0
```

```dart
// main.dart
import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';

void main() async {
  // Required: register the SQLite engine once.
  dRocketSqlite.register();
  initializeD();
  final db = await Db.open(path: 'app.db', ...);
}
```

## What it does

- Owns the `libsqlite3` native binding (via
  `package:sqlite3`).
- Implements d_rocket's `DbEngine` interface with
  the SQLite engine (`SqliteEngine`).
- Provides `dRocketSqlite.register()` (the public
  API) which wires the engine into d_rocket's
  `EngineRegistry`.
- Owns `SqliteQueryProvider` (the SQLite
  `AsyncQueryProvider` implementation).
- Owns the `Db` user-facing facade (the
  `Db.open(path: ...)` / `Db.inMemory()` entry
  point).
- Owns the SQL LINQ translator + the
  `Queryable<T>` SQL implementation, plus
  `DbSetLinqExtension` (`db.set<T>().where(...)`).
- Owns the `EncryptionConfig` / `EncryptionStatus`
  / `KeyProvider` / SQLCipher PRAGMA-redaction
  helpers.
- Owns the SQLCipher probe (auto-detects whether
  the underlying engine supports `PRAGMA key`).
- Exposes the four SQLCipher tunables through
  `EncryptionConfig` (kdf iterations, HMAC size,
  page size, kdf algorithm).

## What's not in this package

- **The ORM itself.** `DbContext`, `DbSet<T>`,
  `@Table`, `MigrationBase`, `EntityMeta`, the
  auto-migrator — all of that lives in `d_rocket`.
  The engine just executes SQL and provides the
  LINQ SQL translator.
- **The other layers.** Serialization, REST, sync,
  realtime. They live in `d_rocket` and don't
  need the engine.
- **Web support.** The `sqlite3` package is a
  `dart:ffi` binding; it does not compile to JS
  / WASM. Web support requires a different engine
  (`d_rocket_engine_libsql_wasm`, planned for
  the 2.0 release).

## How it works

```
your app
  ↓ Db.open(path: 'app.db', ...)
d_rocket_engine_sqlite (2.0.0)
  ↓ Db()  →  d_rocket EngineRegistry.findOrThrow() → SqliteEngine
  ↓ SqliteQueryProvider.file(path, password: ..., config: ...)
  ↓ LINQ: Queryable<T> + translator.dart (SQL → SQL fragments)
package:sqlite3 (3.x)
  ↓ libsqlite3 native
SQLite (on disk, encrypted with SQLCipher if password)
```

The engine is the only piece that talks to the
native lib. Every other layer talks to the engine
through `AsyncQueryProvider` (the d_rocket
abstraction) and `DbEngine` (the engine registry
contract). If you want a Postgres or libsql_wasm
engine, you can write one that implements
`DbEngine` + `AsyncQueryProvider` + a
`Queryable<T>` for the dialect, register it via
`EngineRegistry.register(...)`, and `d_rocket`
doesn't change.

## Encryption

`d_rocket_engine_sqlite` supports SQLCipher out of
the box (when the underlying native lib is
SQLCipher — the consumer is responsible for
bundling `sqlcipher_flutter_libs` on Flutter or
`libsqlcipher` on desktop):

```dart
final db = await Db.open(
  path: 'app.db',
  password: 'master-password',
  encryptionConfig: EncryptionConfig(
    kdfIterations: 256000,
    hmacUse: true,
    pageSize: 4096,
    kdfAlgorithm: 'PBKDF2_HMAC_SHA512',
  ),
);
```

If you pass a `password` and the underlying engine
is plain SQLite (not SQLCipher), `Db.open` throws
a `DatabaseException` at open time with a clear
message ("the underlying engine is not SQLCipher").

## Status (2026-06-17)

| | |
|---|---|
| Latest release | 2.0.0 (paired with d_rocket 2.0.0) |
| pana | TBD |
| Tests | TBD |
| Lockstep | follows d_rocket 2.0.0 |

## License

MIT. See [LICENSE](LICENSE).
