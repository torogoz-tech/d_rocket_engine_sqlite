/// The encryption posture of an open [Db] connection.
///
/// Returned by [Db.diagnostics] (under the
/// `encryptionStatus` key) and useful for audit
/// logs, debug screens, and runtime feature
/// detection (e.g. "show the encryption-settings
/// button only when [encrypted]).
enum EncryptionStatus {
  /// The connection was opened without a `password:`
  /// or `keyProvider:`. The data is on disk as
  /// plaintext SQLite. Anyone with filesystem access
  /// can read it.
  plain,

  /// The connection was opened with a `password:`
  /// or `keyProvider:` AND the underlying engine is
  /// SQLCipher. The data is encrypted at rest.
  /// The exact tunables are reported under the
  /// `encryptionConfig` key of [Db.diagnostics].
  encrypted,

  /// The connection was opened with a `password:`
  /// or `keyProvider:` but the probe
  /// ([isSqlCipherAvailable]) cannot confirm that
  /// the engine is SQLCipher. Two possible causes:
  /// the consumer forgot to bundle
  /// `sqlcipher_flutter_libs` (or `libsqlcipher` on
  /// desktop), or the probe is being run in a
  /// context where it cannot open a second
  /// connection. The password is being passed
  /// correctly; the engine is silently ignoring
  /// it. The docstring of [isSqlCipherAvailable]
  /// explains the caveat.
  unknown,
}
