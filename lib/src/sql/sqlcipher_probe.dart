/// Runtime feature detection for the SQLCipher
/// engine.
///
/// Opens a short-lived in-memory database with a
/// deliberately wrong password, then checks whether
/// the engine rejected the key. The result is
/// cached for the lifetime of the isolate, so the
/// cost (one open + one prepared statement + one
/// close) is paid at most once per process.
///
/// On a SQLCipher build, the `PRAGMA key` of an
/// unknown password raises `SQLITE_NOTADB` on
/// the verification query, which we catch and
/// report as `true`. On a vanilla SQLite build,
/// the `PRAGMA key` is silently ignored and the
/// verification query succeeds, which we report
/// as `false`.
///
/// Useful for:
///
/// * `Db.diagnostics()` callers that want to know
///   whether the engine actually applied the key.
/// * Apps that want to feature-detect at startup
///   and warn the user if they forgot to bundle
///   `sqlcipher_flutter_libs` (or install
///   `libsqlcipher` on desktop).
/// * Tests that need to gate SQLCipher-specific
///   paths on a flag.
///
/// ## Caveat
///
/// The probe opens a second in-memory database.
/// On platforms where opening a second DB is
/// expensive (very low-end mobile targets) or
/// impossible (e.g. Web with no sqlite3
/// available), the probe will fall through and
/// return `false`. The cached result is therefore
/// a "best effort" detection, not a guarantee.
///
/// On hosts where the probe itself is unreliable
/// (CI runners without a SQLite binary, server-side
/// Dart with the bundled sqlite3 stripped), prefer
/// to gate on the build configuration directly
/// (e.g. a `--dart-define=SQLCIPHER=1` flag).
library;

import 'package:d_rocket/d_rocket.dart';

import 'query_provider.dart';

bool? _sqlcipherCache;

/// Returns `true` if the underlying SQLite engine
/// is SQLCipher. The result is cached at the
/// isolate level; the first call opens a short
/// in-memory database, subsequent calls are
/// constant-time.
bool isSqlCipherAvailable() {
  if (_sqlcipherCache != null) return _sqlcipherCache!;
  try {
    final SqliteQueryProvider p = SqliteQueryProvider.inMemory(
      password: '__d_rocket_sqlcipher_probe__',
    );
    p.dispose();
    _sqlcipherCache = false;
    return false;
  } on DatabaseException {
    _sqlcipherCache = true;
    return true;
  }
}

/// helper: clears the cached probe result. Test
/// only. Production code should never call this.
void debugResetSqlCipherProbeCache() {
  _sqlcipherCache = null;
}
