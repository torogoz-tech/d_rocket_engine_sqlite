/// Source of the encryption password for a SQLCipher database.
///
/// The [KeyProvider] abstraction lets the caller plug any
/// async source of a password (or a raw 256-bit key) into
/// [Db.open] / [Db.inMemory] without leaking the value
/// through synchronous call sites. The most common use
/// case is reading the key from platform secure storage on
/// every open:
///
/// ```dart
/// final db = await Db.open(
///   path: 'app.db',
///   keyProvider: FlutterSecureStorageKeyProvider(
///     FlutterSecureStorage(),
///     account: 'd_rocket_key',
///   ),
/// );
/// ```
///
/// `d_rocket` ships two built-in providers for tests and
/// the simple case:
///
/// * [StaticKeyProvider] holds a literal value in memory.
///   Useful for unit tests and for code paths where the
///   key is already a `String` in scope.
/// * [CallbackKeyProvider] wraps an async function. Useful
///   when the key source is not a `String` (e.g. a stream
///   you `.first` from) or when the consumer wants to
///   add logging around the read.
///
/// Consumers that integrate with `flutter_secure_storage`
/// (or any other platform-specific vault) write their
/// own `KeyProvider` in five lines:
///
/// ```dart
/// class FlutterSecureStorageKeyProvider implements KeyProvider {
///   FlutterSecureStorageKeyProvider(this._storage, {required this.account});
///   final FlutterSecureStorage _storage;
///   final String account;
///   @override
///   Future<String> readKey() async {
///     final String? key = await _storage.read(key: account);
///     if (key == null) {
///       throw StateError('No key in secure storage for account "$account"');
///     }
///     return key;
///   }
/// }
/// ```
///
/// The [readKey] result is consumed once per [Db.open]
/// call, held in memory for the duration of the
/// connection, and then dropped when the database is
/// closed. `d_rocket` does not cache the value across
/// opens: every `Db.open` re-reads, so rotating the key
/// in the keychain takes effect on the next open.
///
/// [KeyProvider] is mutually exclusive with the
/// `password` parameter on [Db.open]: passing both
/// raises [ArgumentError] at open time.
abstract class KeyProvider {
  /// Returns the encryption password (or raw key) for the
  /// next [Db.open] call. Called once per open, in the
  /// same isolate as the call site. The result must be a
  /// non-empty string; an empty result raises
  /// [ArgumentError] in [Db.open].
  Future<String> readKey();
}

/// A [KeyProvider] that holds a literal value in memory.
/// Used by tests and by code paths where the password is
/// already a `String` in scope. For production code on
/// mobile, prefer a [KeyProvider] backed by platform
/// secure storage.
class StaticKeyProvider implements KeyProvider {
  /// Creates a provider that returns [value] on every
  /// [readKey] call.
  const StaticKeyProvider(this.value);

  /// The value returned by [readKey]. Held by reference;
  /// mutating the field is allowed but not recommended.
  final String value;

  @override
  Future<String> readKey() async => value;
}

/// A [KeyProvider] that delegates to an async callback.
/// Use this when the key source is not a `String` (e.g.
/// a stream you `.first` from) or when the caller wants
/// to add logging, caching, or rotation around the read.
class CallbackKeyProvider implements KeyProvider {
  /// Creates a provider that invokes [reader] on every
  /// [readKey] call. The callback is awaited in the same
  /// isolate as the [Db.open] call site.
  const CallbackKeyProvider(this.reader);

  /// The function called on every [readKey]. The returned
  /// [Future] must complete to a non-empty string; an
  /// empty result raises [ArgumentError] in [Db.open].
  final Future<String> Function() reader;

  @override
  Future<String> readKey() => reader();
}
