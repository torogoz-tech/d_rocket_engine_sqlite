/// The SQLite engine for d_rocket 2.0.
///
/// Implements d_rocket's [DbEngine] contract
/// using `package:sqlite3` as the native binding.
/// Register it once at app startup with
/// `dRocketSqlite()` and the
/// `Db` / `DbContext` / `DbSet` / SQL `Queryable` /
/// auto-migrations stack lights up.
library;

import 'package:d_rocket/d_rocket.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'sql/encryption_config.dart';
import 'sql/query_provider.dart';

/// The SQLite-backed [DbEngine] implementation.
class SqliteEngine implements DbEngine {
  const SqliteEngine();

  @override
  String get name => 'sqlite';

  @override
  bool get isAvailable {
    try {
      // sqlite3's library load is lazy; a successful
      // version query is the cheapest way to verify
      // the native lib is loadable on this platform.
      sql.sqlite3.version;
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<AsyncQueryProvider> open({
    String? path,
    String? password,
    Object? encryptionConfig,
  }) async {
    final EncryptionConfig? sqliteConfig =
        encryptionConfig is EncryptionConfig
            ? encryptionConfig
            : (encryptionConfig == null
                ? null
                : throw DatabaseException(
                    'the encryptionConfig passed to the SQLite engine '
                    'is not an instance of EncryptionConfig',
                    cause: encryptionConfig,
                  ));
    final String? resolvedPath = path;
    if (resolvedPath == null || resolvedPath == ':memory:') {
      return SqliteQueryProvider.inMemory(
        password: password,
        encryptionConfig: sqliteConfig,
      );
    }
    return SqliteQueryProvider.file(
      resolvedPath,
      password: password,
      encryptionConfig: sqliteConfig,
    );
  }
}
