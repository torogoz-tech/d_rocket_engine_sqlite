/// The user-facing entry point for d_rocket's SQLite engine.
///
/// SQLite-First for Flutter: this is the
/// only entry point a user needs. No `attach<Provider>`,
/// no abstract `AsyncQueryProvider`, no manual lifecycle.
///
/// Both `open` and `inMemory` accept a
/// [MigrationStrategy] for version-tagged,
/// callback-driven schema management. The old
/// `onCreate: (db) => db.migrate()` pattern is still
/// supported for backward compat — when only `onCreate`
/// is provided the runner falls back to the
/// `DbContext.migrations` list.
///
/// ## Example
///
/// ```dart
/// // Open a database (use getDatabasesPath() on mobile
/// // or an absolute path on desktop)
/// final db = await Db.open(path: 'myapp.db');
///
/// // Get a typed set
/// final people = db.set`<Person>`();
///
/// // Query (async, LINQ-style)
/// final adults = await people
///     .asQueryable()
///     .where((p) => p.age >= 18)
///     .toListAsync_();
///
/// // Insert / update
/// await db.set`<Person>`().add(Person(id: 1, name: 'Ada', age: 30));
///
/// // Save changes
/// await db.saveChanges();
///
/// // Close
/// await db.close();
/// ```
library;

import 'package:d_rocket/d_rocket.dart';

import 'sql/encryption_config.dart';
import 'sql/encryption_status.dart';
import 'sql/key_provider.dart';
import 'sql/query_provider.dart';
import 'sql/sqlcipher_probe.dart';

/// (SQLite-First): the user-facing database
/// facade. Wraps a [SqliteQueryProvider] (the internal
/// storage engine) and a [DbContext] (the ORM).
///
/// The user never touches either directly. This class
/// exposes the idiomatic operations:
/// `set<T>`, `saveChanges`, `migrate`, `close`.
class Db {
  final SqliteQueryProvider _provider;
  final DbContext _ctx;
  final String? _password;
  final KeyProvider? _keyProvider;
  final EncryptionConfig? _encryptionConfig;

  Db._(
    this._provider,
    this._ctx, {
    String? password,
    KeyProvider? keyProvider,
    EncryptionConfig? encryptionConfig,
  })  : _password = password,
        _keyProvider = keyProvider,
        _encryptionConfig = encryptionConfig;

  /// Whether the connection is still alive. `false`
  /// after [close] has been called. Useful for
  /// "is this handle reusable?" checks at the
  /// call site.
  bool get isOpen => _provider.isOpen;

  /// Snapshot of the current connection state. The
  /// map contains at least the following keys:
  ///
  /// * `isOpen: bool` — same as the [isOpen] getter.
  /// * `encrypted: bool` — `true` if the connection
  ///   was opened with a `password:` or `keyProvider:`.
  /// * `encryptionStatus: EncryptionStatus` — the
  ///   posture (plain / encrypted / unknown). See
  ///   the `EncryptionStatus` docstring for the
  ///   `unknown` caveat.
  /// * `keySource: 'password' | 'keyProvider' | 'none'`
  ///   — which input produced the key (if any).
  /// * `encryptionConfig: Map<String, Object?>?` —
  ///   the four SQLCipher tunables if a config was
  ///   passed, `null` otherwise.
  ///
  /// The map is a plain `Map<String, Object?>`, not
  /// a typed record, so it is easy to log to JSON,
  /// post to a debug endpoint, or print.
  Map<String, Object?> diagnostics() {
    final bool wasEncrypted = _password != null || _keyProvider != null;
    final EncryptionStatus status = wasEncrypted
        ? (isSqlCipherAvailable()
            ? EncryptionStatus.encrypted
            : EncryptionStatus.unknown)
        : EncryptionStatus.plain;
    final String keySource = _keyProvider != null
        ? 'keyProvider'
        : (_password != null ? 'password' : 'none');

    return <String, Object?>{
      'isOpen': isOpen,
      'encrypted': wasEncrypted,
      'encryptionStatus': status,
      'keySource': keySource,
      'encryptionConfig': _encryptionConfig != null
          ? <String, Object?>{
              'kdfIterations': _encryptionConfig.kdfIterations,
              'pageSize': _encryptionConfig.pageSize,
              'hmacUse': _encryptionConfig.hmacUse,
              'memorySecurity': _encryptionConfig.memorySecurity,
            }
          : null,
    };
  }

  /// Opens a file-backed SQLite database at [path]. Use
  /// `getDatabasesPath` from `package:sqflite` on mobile,
  /// or an absolute path on desktop.
  ///
  /// If [password] is non-null, the database is opened as
  /// an encrypted SQLCipher database — see the
  /// `SqliteQueryProvider.file` docstring for the engine
  /// setup. The default (no [password]) is plain SQLite,
  /// preserving the v1.0.x behavior. The parameter is
  /// additive: existing callers that don't pass [password]
  /// are unaffected.
  ///
  /// If [strategy] is provided, the runner
  /// auto-detects the database's current version and
  /// either applies all migrations (`fresh` install),
  /// applies the upgrade subset, or rolls back the
  /// downgrade subset. The `onCreate` callback (if any)
  /// is invoked on a fresh install AFTER the strategy's
  /// declarative `migrations` list (or imperative
  /// `onCreate` callback) has run.
  ///
  /// For backward compat, the pre-strategy
  /// `onCreate: (db) => db.migrate()` pattern is still
  /// supported — when [strategy] is null and [onCreate]
  /// is provided, the runner uses the
  /// `DbContext.migrations` list. Mixing the two
  /// (providing both [strategy] and [onCreate]) is
  /// allowed but the [onCreate] callback runs AFTER the
  /// strategy.
  static Future<Db> open({
    required String path,
    String? password,
    KeyProvider? keyProvider,
    EncryptionConfig? encryptionConfig,
    MigrationStrategy? strategy,
    Future<void> Function(Db db)? onCreate,
    List<EntityMeta> entityMetas = const <EntityMeta>[],
    bool autoMigrate = false,
    //: [engine] (a [DbEngine]) is the
    // explicit way to choose the engine.
    // When provided, the [EngineRegistry]
    // is bypassed entirely — you don't
    // need to call dRocketSqlite() first.
    // When null, the engine is looked up
    // from the registry (the legacy path,
    // still supported). For tests and
    // multi-engine apps, prefer the
    // explicit path.
    DbEngine? engine,
  }) async {
    final String? resolvedPassword = await _resolveKey(
      password: password,
      keyProvider: keyProvider,
    );
    final Db db = await _openViaRegistry(
      path: path,
      rawPassword: password,
      password: resolvedPassword,
      encryptionConfig: encryptionConfig,
      entityMetas: entityMetas,
      strategy: strategy,
      onCreate: onCreate,
      autoMigrate: autoMigrate,
      keyProvider: keyProvider,
      engine: engine,
    );
    return db;
  }

  /// Opens an in-memory database. Convenient for tests.
  /// Same semantics as [open] for [password],
  /// [keyProvider], [encryptionConfig], [strategy] and
  /// [onCreate].
  static Future<Db> inMemory({
    String? password,
    KeyProvider? keyProvider,
    EncryptionConfig? encryptionConfig,
    MigrationStrategy? strategy,
    Future<void> Function(Db db)? onCreate,
    List<EntityMeta> entityMetas = const <EntityMeta>[],
    bool autoMigrate = false,
    DbEngine? engine,
  }) async {
    final String? resolvedPassword = await _resolveKey(
      password: password,
      keyProvider: keyProvider,
    );
    final Db db = await _openViaRegistry(
      path: null,
      rawPassword: password,
      password: resolvedPassword,
      encryptionConfig: encryptionConfig,
      entityMetas: entityMetas,
      strategy: strategy,
      onCreate: onCreate,
      autoMigrate: autoMigrate,
      keyProvider: keyProvider,
      engine: engine,
    );
    return db;
  }

  /// Helper: looks up the registered engine and
  /// calls its `open` method. The Db facade wraps
  /// the resulting `AsyncQueryProvider` in a
  /// `DbContext` (via `_SqliteRocketContext`).
  ///
  /// This is the single point where Db talks to
  /// the engine. In production the registered
  /// engine is `SqliteEngine`; in tests it can
  /// be a stub. The Db is the SQLite engine's
  /// user-facing facade, so it does not work
  /// with a non-SQLite engine (the engine would
  /// need to return a `SqliteQueryProvider`).
  /// For engine-agnostic queries, use
  /// `AsyncQueryProvider` directly via the
  /// registered engine.
  static Future<Db> _openViaRegistry({
    String? path,
    String? rawPassword,
    String? password,
    EncryptionConfig? encryptionConfig,
    KeyProvider? keyProvider,
    List<EntityMeta> entityMetas = const <EntityMeta>[],
    MigrationStrategy? strategy,
    Future<void> Function(Db db)? onCreate,
    bool autoMigrate = false,
    DbEngine? engine,
  }) async {
    //: prefer the explicit engine (the
    // new path) over the registry (the
    // legacy path). When the user passes
    // `engine: const SqliteEngine()`,
    // the registry is bypassed entirely.
    final DbEngine resolved = engine ?? EngineRegistry.findOrThrow;
    if (resolved.name != 'sqlite') {
      throw DatabaseException(
        'Db is the SQLite engine facade; the registered '
        'engine is "${resolved.name}". Use the engine-specific '
        'facade (e.g. d_rocket_engine_postgres) for a '
        'different backend, or register the SQLite engine '
        'with dRocketSqlite() before calling Db.open.',
        cause: resolved.name,
      );
    }
    final AsyncQueryProvider raw = await resolved.open(
      path: path,
      password: password,
      encryptionConfig: encryptionConfig,
    );
    if (raw is! SqliteQueryProvider) {
      throw DatabaseException(
        'The registered engine returned a non-SQLite provider '
        '(${raw.runtimeType}). Db requires SqliteQueryProvider.',
        cause: raw.runtimeType,
      );
    }
    final SqliteQueryProvider provider = raw;
    final DbContext ctx = _SqliteRocketContext(
      provider,
      entityMetas: entityMetas,
    );
    final Db db = Db._(
      provider,
      ctx,
      password: rawPassword,
      keyProvider: keyProvider,
      encryptionConfig: encryptionConfig,
    );
    if (strategy != null) {
      await db.migrateStrategy(strategy);
    }
    if (onCreate != null) {
      await onCreate(db);
    }
    if (autoMigrate && entityMetas.isNotEmpty) {
      // Run the auto-migrator AFTER any manual
      // migrations. The auto-migrator is a no-op
      // if the schema is already in sync with the
      // entity list (it just rewrites the snapshot
      // row to keep the state in lockstep with the
      // codegen-emitted entity list).
      await db.runAutoMigrations();
    }
    return db;
  }

  /// helper: validates that exactly one of [password] or
  /// [keyProvider] is set, awaits the key from the
  /// provider (if used), and returns the resolved key.
  /// Throws [ArgumentError] on mutual exclusion or on an
  /// empty key from a [KeyProvider].
  static Future<String?> _resolveKey({
    required String? password,
    required KeyProvider? keyProvider,
  }) async {
    if (password != null && keyProvider != null) {
      throw ArgumentError(
        'Db.open: pass either "password" or "keyProvider", not both',
      );
    }
    if (keyProvider != null) {
      final String resolved = await keyProvider.readKey();
      if (resolved.isEmpty) {
        throw ArgumentError(
          'Db.open: keyProvider returned an empty key',
        );
      }
      return resolved;
    }
    return password;
  }

  /// Returns a typed [DbSet] for entity [T]. Equivalent to
  /// EFCore's `dbContext.Set<T>`.
  ///
  /// The returned `DbSet<T>` has the SQLite provider already
  /// attached — the user doesn't need to call `attach`.
  DbSet<T> set<T>() {
    final DbSet<T> dbSet = _ctx.dbSet<T>(() => _ctx.entityMetaFor<T>());
    // Auto-attach the provider (: hidden from user).
    dbSet.attach<SqliteQueryProvider>(_provider);
    return dbSet;
  }

  /// Returns the underlying [DbContext]. Most users
  /// won't need this — it's exposed for advanced cases
  /// (e.g. running raw SQL via `ctx.database`, or
  /// accessing the change tracker directly).
  DbContext get context => _ctx;

  /// Returns a snapshot of the pending sync changes
  /// (the local changes that have been committed
  /// but not yet pushed to the remote). Awaits
  /// hydration from the persistent queue on the
  /// first call after process start, so the
  /// returned list is consistent across app
  /// restarts.
  Future<List<SyncChange>> pendingSyncChanges() async {
    await _ctx.ensureQueueHydrated();
    return _ctx.pendingSyncChanges;
  }

  /// Returns the underlying [SqliteQueryProvider]. Advanced
  /// use only — prefer `set<T>` for typed access.
  SqliteQueryProvider get provider => _provider;

  ///: applies all pending migrations.
  Future<List<MigrationBase>> migrate() => _ctx.migrateAsync();

  ///: rolls back migrations.
  Future<List<MigrationBase>> rollback({List<MigrationBase>? toRollback}) =>
      _ctx.rollbackAsync(toRollback: toRollback);

  ///: brings the database to exactly
  /// [targetVersion] using the `version` of the
  /// provided [MigrationBase] instances. Picks the
  /// direction (upgrade / downgrade) automatically
  /// based on the current schema version. No-op if
  /// already at the target.
  Future<List<MigrationBase>> migrateTo(
    int targetVersion, {
    List<MigrationBase>? migrations,
  }) {
    return _ctx.migrateToAsync(
      targetVersion,
      migrations ?? _ctx.migrations,
    );
  }

  ///: returns the highest version recorded
  /// in `_d_rocket_migrations`, or `0` for a fresh
  /// install. Used by the CLI's `status` command.
  Future<int> currentVersion() => _ctx.currentVersionAsync();

  ///: returns the full list of applied
  /// migrations, ordered by `version` ascending.
  Future<List<AppliedMigration>> appliedMigrations() => _ctx.appliedAsync();

  ///: runs a [MigrationStrategy] against
  /// the open database. The strategy's [MigrationStrategy.version]
  /// is the target. The runner inspects the
  /// current version and dispatches to the right
  /// callback (declarative migrations list /
  /// imperative onCreate / imperative onUpgrade /
  /// imperative onDowngrade).
  Future<List<MigrationBase>> migrateStrategy(MigrationStrategy strategy) {
    return _ctx.migrateStrategyAsync(strategy);
  }

  ///: saves all pending changes in the
  /// change tracker.
  Future<int> saveChanges() => _ctx.saveChangesAsync();

  /// Runs the auto-migration system. Computes
  /// the diff between the current schema and
  /// the entity list passed to `Db.open(
  /// entityMetas: ...)` and applies the safe
  /// changes in a single transaction. Returns
  /// the [AutoMigrationResult] so the caller
  /// can log the applied changes and surface
  /// the unsafe ones.
  ///
  /// Called automatically by `Db.open(
  /// autoMigrate: true)`; users do not call it
  /// directly. Exposed for tests that want to
  /// drive the auto-migrator from a custom
  /// `Db` lifecycle.
  Future<AutoMigrationResult> runAutoMigrations() async {
    final _SqliteRocketContext ctx =
        _ctx as _SqliteRocketContext;
    if (ctx._entityMetas.isEmpty) {
      return AutoMigrationResult(
        applied: const <SchemaDiff>[],
        unsafe: const <SchemaDiff>[],
        snapshot: SchemaSnapshot(version: 1, tables: const <SchemaTable>[]),
      );
    }
    final AutoMigrator migrator = AutoMigrator(
      provider: _provider,
      entityMetas: ctx._entityMetas,
    );
    return migrator.run();
  }

  /// Returns the pending schema diff (the
  /// changes that would be applied by the auto-
  /// migration system) WITHOUT applying them.
  /// Useful for logging, dry-runs, and CI
  /// checks.
  Future<List<SchemaDiff>> pendingSchemaDiff() async {
    final _SqliteRocketContext ctx =
        _ctx as _SqliteRocketContext;
    if (ctx._entityMetas.isEmpty) {
      return const <SchemaDiff>[];
    }
    final AutoMigrator migrator = AutoMigrator(
      provider: _provider,
      entityMetas: ctx._entityMetas,
    );
    return migrator.computePendingDiff();
  }

  /// Re-encrypts the database with a new key.
  ///
  /// Wraps `PRAGMA rekey` with the same single-quote
  /// escape used by the open path. The current
  /// connection stays open and continues to work
  /// (the engine re-encrypts the page cache in the
  /// background on the next write). Subsequent
  /// [close] + [Db.open] calls must use the new key.
  ///
  /// Exactly one of [newPassword] or [newKeyProvider]
  /// must be supplied; passing both — or neither —
  /// raises [ArgumentError]. The database must have
  /// been opened with a key (i.e. via [Db.open] /
  /// [Db.inMemory] with a non-null `password` or
  /// `keyProvider`); running `changePassword` on a
  /// plain SQLite database raises [StateError] because
  /// there is no key to rotate.
  ///
  /// The rekey is applied to every page; for a
  /// multi-megabyte database it can take a few hundred
  /// milliseconds. Plan a one-time migration flow
  /// (open → `changePassword` → close) and document
  /// it in your release notes.
  Future<void> changePassword({
    String? newPassword,
    KeyProvider? newKeyProvider,
  }) async {
    if (newPassword != null && newKeyProvider != null) {
      throw ArgumentError(
        'Db.changePassword: pass either "newPassword" '
        'or "newKeyProvider", not both',
      );
    }
    String? resolved;
    if (newKeyProvider != null) {
      resolved = await newKeyProvider.readKey();
      if (resolved.isEmpty) {
        throw ArgumentError(
          'Db.changePassword: newKeyProvider returned '
          'an empty key',
        );
      }
    } else {
      resolved = newPassword;
    }
    if (resolved == null) {
      throw ArgumentError(
        'Db.changePassword: pass either "newPassword" '
        'or "newKeyProvider"',
      );
    }
    final String escaped = resolved.replaceAll("'", "''");
    try {
      await _provider.executeAsync("PRAGMA rekey = '$escaped'");
    } on DatabaseException {
      rethrow;
    } on Object catch (e) {
      throw DatabaseException(
        'Failed to rekey database: ${e.toString()}',
        cause: e,
      );
    }
  }

  /// Closes the database. After this, all `set<T>`
  /// operations will throw.
  Future<void> close() => _provider.disposeAsync();
}

/// Internal — a [DbContext] pre-wired to the SQLite
/// provider. Users don't see this class; they interact
/// with [Db] only.
class _SqliteRocketContext extends DbContext {
  _SqliteRocketContext(
    this._provider, {
    List<EntityMeta> entityMetas = const <EntityMeta>[],
  }) {
    // Wire the persistent sync queue to the same
    // connection as the user data. The queue
    // table picks up SQLCipher encryption for
    // free when the main DB is encrypted.
    queueStore = SyncQueueStore(provider: _provider);
    _entityMetas.addAll(entityMetas);
  }
  final SqliteQueryProvider _provider;
  final List<EntityMeta> _entityMetas = <EntityMeta>[];

  /// helper: the list of [EntityMeta]s passed
  /// to the constructor. Used by the auto-
  /// migrator (which the [Db] calls via
  /// `db.runAutoMigrations()` / `db.pendingSchemaDiff()`).
  /// Empty when the consumer did not opt into
  /// the auto-migration system (back-compat).
  List<EntityMeta> get entityMetas =>
      List<EntityMeta>.unmodifiable(_entityMetas);

  @override
  AsyncQueryProvider? get asyncProvider => _provider;

  ///: looks up the [EntityMeta] for [T] in
  /// the global [EntityRegistry] populated by
  /// `initializeD` (emitted by `d_rocket_builder`).
  @override
  EntityMeta entityMetaFor<T>() {
    return EntityRegistry.metaFor(T);
  }

  ///: factory for [DbSet]s. The async
  /// provider is auto-attached so the user never has to
  /// call `attachAsyncProvider` themselves.
  @override
  DbSet<T> createDbSet<T>(EntityMeta Function() m) {
    // The DbSet constructor requires sync callbacks
    // (for the back-compat path). The async
    // path is the default — we attach
    // the SQLite provider via `attachAsyncProvider`.
    // The sync callbacks throw because the user is
    // expected to use `*Async` methods.
    return DbSet<T>(
      metaAccessor: m,
      tracker: changeTracker,
      execute: (String sql, List<Object?> binds) {
        throw UnsupportedError(
          'DbSet.execute() is sync-only. Use the `*Async` '
          'methods (e.g. `addAsync`, `selectAsync`) or '
          'await `db.saveChangesAsync()`.',
        );
      },
      select: (String sql, List<Object?> binds) {
        throw UnsupportedError(
          'DbSet.select() is sync-only. Use '
          '`db.set<T>().asQueryable().toListAsync_()`.',
        );
      },
      lastInsertRowId: () {
        throw UnsupportedError(
          'DbSet.lastInsertRowId() is sync-only. Use '
          'the `*Async` methods.',
        );
      },
    ).attachAsyncProvider(_provider).attach<SqliteQueryProvider>(_provider);
  }
}
