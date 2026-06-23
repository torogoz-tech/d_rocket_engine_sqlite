// Shared test helpers for `d_rocket_engine_sqlite`
// tests.
//
// All tests that use `Db.open` / `Db.inMemory` /
// `SqliteQueryProvider` must call
// `dRocketSqlite()` once before their
// first database call. The `setUpSqlite` helper
// is a thin wrapper around the test's
// `setUp` that does that registration and
// optionally resets the registry between tests.
//
// Usage:
//
// ```dart
// import '_helpers.dart';
//
// void main() {
//   setUpSqlite();
//   tearDown(() => EngineRegistry.resetForTest());
//
//   test('something', () async {
//     final db = await Db.inMemory();
//     // ...
//   });
// }
// ```
library;

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

/// Registers the SQLite engine. Call this from your
/// test's `setUp` (or `setUpAll` if you don't
/// reset between tests). Subsequent calls
/// re-register the same engine, which is
/// idempotent.
///
/// Returns the `void Function()` you should pass
/// to `tearDown` to reset the registry between
/// tests. If you don't reset, the registered
/// engine leaks across tests in the same file.
void setUpSqlite({bool resetBetweenTests = true}) {
  setUpAll(() {
    dRocketSqlite();
  });
  if (resetBetweenTests) {
    tearDown(() {
      EngineRegistry.resetForTest();
      dRocketSqlite();
    });
  }
}
