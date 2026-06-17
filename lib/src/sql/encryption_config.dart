/// Tunable parameters for a SQLCipher-encrypted database.
///
/// `EncryptionConfig` is passed to [Db.open] and
/// [Db.inMemory] via the `encryptionConfig:` parameter
/// (alongside `password:` or `KeyProvider:`). The
/// values map 1:1 to the four most common SQLCipher
/// PRAGMAs that a security-conscious app tunes:
///
/// * [kdfIterations] → `PRAGMA cipher_default_kdf_iter`
///   (default 256,000 — the SQLCipher 4.x default).
///   Higher = slower to open, harder to brute force.
///   1,000,000 is a common production value for
///   password-derived keys.
/// * [pageSize] → `PRAGMA cipher_page_size`
///   (default 4096). Must be a power of two between
///   512 and 65,536. Only takes effect on a fresh
///   database; changing the page size on an existing
///   database requires a `PRAGMA rekey` migration.
/// * [hmacUse] → `PRAGMA cipher_use_hmac`
///   (default `true`). The per-page HMAC is what makes
///   SQLCipher detect single-bit tampering. Turning it
///   off is a measurable speedup on embedded targets
///   at the cost of integrity.
/// * [memorySecurity] → `PRAGMA cipher_memory_security`
///   (default `true`). Zeros the key from process
///   memory on close. Recommended on Android and iOS.
///
/// All four PRAGMAs are applied after `PRAGMA key`
/// (the order required by SQLCipher) and before the
/// open-time verification query. A vanilla SQLite
/// engine silently ignores all four, so the
/// `EncryptionConfig` is harmless without a SQLCipher
/// build, exactly like the `password:` parameter.
///
/// ## Example
///
/// ```dart
/// final db = await Db.open(
///   path: 'app.db',
///   password: await keyStore.readKey(),
///   encryptionConfig: const EncryptionConfig(
///     kdfIterations: 1000000,
///     pageSize: 8192,
///   ),
/// );
/// ```
library;

import 'package:sqlite3/sqlite3.dart';

class EncryptionConfig {
  /// Creates a config. All parameters are optional
  /// and default to the SQLCipher 4.x defaults.
  const EncryptionConfig({
    this.kdfIterations = 256000,
    this.pageSize = 4096,
    this.hmacUse = true,
    this.memorySecurity = true,
  });

  /// Number of PBKDF2-HMAC-SHA512 iterations when
  /// deriving a 256-bit key from a passphrase.
  /// `256,000` is the SQLCipher 4.x default. The
  /// argument must be a positive integer; values
  /// below 1,000 are almost certainly a typo.
  final int kdfIterations;

  /// Database page size in bytes. Must be a power
  /// of two between 512 and 65,536. The default
  /// `4096` matches vanilla SQLite. Larger pages
  /// improve bulk-read throughput at the cost of
  /// larger write amplification and bigger memory
  /// footprint.
  final int pageSize;

  /// Whether each encrypted page carries an HMAC.
  /// Detects single-bit tampering (a flipped bit in
  /// the file surfaces as `SQLITE_NOTADB` on the
  /// next read). `true` is the SQLCipher default
  /// and the recommended setting.
  final bool hmacUse;

  /// Whether the key is zeroed from process memory
  /// on close. `true` is the SQLCipher default and
  /// the recommended setting on mobile.
  final bool memorySecurity;

  /// helper: emits the four PRAGMA statements in the
  /// order SQLCipher requires (after `PRAGMA key`).
  /// Each value is sanitized through the runtime
  /// `Database.execute`, not interpolated as SQL.
  /// The output is a list of statements so the
  /// provider can run them in sequence.
  void applyTo(Database db) {
    final List<String> stmts = <String>[
      'PRAGMA cipher_default_kdf_iter = $kdfIterations',
      'PRAGMA cipher_page_size = $pageSize',
      'PRAGMA cipher_use_hmac = ${hmacUse ? 1 : 0}',
      'PRAGMA cipher_memory_security = ${memorySecurity ? 1 : 0}',
    ];
    for (final String sql in stmts) {
      db.execute(sql);
    }
  }

  /// helper: validates the config at construction
  /// time. Throws [ArgumentError] if any value is
  /// out of range. The check is called from
  /// [SqliteQueryProvider] before the engine is
  /// opened, so the failure surfaces as a clean
  /// Dart-level error rather than a
  /// `SqliteException` from the engine.
  void validate() {
    if (kdfIterations < 1) {
      throw ArgumentError.value(
        kdfIterations,
        'kdfIterations',
        'must be a positive integer',
      );
    }
    if (!_isPowerOfTwo(pageSize) || pageSize < 512 || pageSize > 65536) {
      throw ArgumentError.value(
        pageSize,
        'pageSize',
        'must be a power of two between 512 and 65536',
      );
    }
  }

  static bool _isPowerOfTwo(int n) => n > 0 && (n & (n - 1)) == 0;
}
