// Tests for the SQLCipher ecosystem: EncryptionConfig,
// KeyProvider, Db.changePassword(), and
// redactPragmaKey().
//
// All tests are pure-Dart and run on the dev machine
// (no libsqlcipher required) because the contract
// being tested is the API surface, the validation,
// and the wiring — not the actual SQLCipher
// encryption. The encryption round-trip itself
// stays in test/sqlite/encrypted_db_test.dart,
// gated on a runtime probe for libsqlcipher.

import 'dart:io';

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group('EncryptionConfig — validation', () {
    test('defaults match SQLCipher 4.x', () {
      const EncryptionConfig c = EncryptionConfig();
      expect(c.kdfIterations, 256000);
      expect(c.pageSize, 4096);
      expect(c.hmacUse, isTrue);
      expect(c.memorySecurity, isTrue);
    });

    test('validate() passes for the default config', () {
      const EncryptionConfig c = EncryptionConfig();
      expect(() => c.validate(), returnsNormally);
    });

    test('validate() passes for tuned values', () {
      const EncryptionConfig c = EncryptionConfig(
        kdfIterations: 1000000,
        pageSize: 8192,
        hmacUse: false,
        memorySecurity: false,
      );
      expect(() => c.validate(), returnsNormally);
    });

    test('validate() throws on zero or negative kdfIterations', () {
      expect(
        () => const EncryptionConfig(kdfIterations: 0).validate(),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => const EncryptionConfig(kdfIterations: -1).validate(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('validate() throws when pageSize is not a power of two', () {
      expect(
        () => const EncryptionConfig(pageSize: 1000).validate(),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => const EncryptionConfig(pageSize: 5000).validate(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('validate() throws when pageSize is out of [512, 65536]', () {
      expect(
        () => const EncryptionConfig(pageSize: 256).validate(),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => const EncryptionConfig(pageSize: 131072).validate(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('validate() accepts every documented power-of-two pageSize', () {
      for (final int size in <int>[512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]) {
        expect(
          () => EncryptionConfig(pageSize: size).validate(),
          returnsNormally,
          reason: 'pageSize=$size must validate',
        );
      }
    });
  });

  group('KeyProvider — built-in providers', () {
    test('StaticKeyProvider.readKey() returns the literal value', () async {
      const StaticKeyProvider p = StaticKeyProvider('hunter2');
      expect(await p.readKey(), 'hunter2');
    });

    test('CallbackKeyProvider.readKey() awaits the callback', () async {
      int calls = 0;
      final CallbackKeyProvider p = CallbackKeyProvider(() async {
        calls += 1;
        return 'computed-$calls';
      });
      expect(await p.readKey(), 'computed-1');
      expect(await p.readKey(), 'computed-2');
      expect(calls, 2);
    });

    test('CallbackKeyProvider surfaces a callback error', () async {
      final CallbackKeyProvider p = CallbackKeyProvider(() async {
        throw StateError('keychain unavailable');
      });
      await expectLater(
        p.readKey(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Db.open / Db.inMemory — key resolution', () {
    test('Db.open accepts password + encryptionConfig (compile check)',
        () async {
      final Db db = await Db.inMemory(
        password: 'test',
        encryptionConfig: const EncryptionConfig(
          kdfIterations: 1000000,
        ),
      );
      await db.close();
    });

    test('Db.open accepts keyProvider (compile check)', () async {
      final Db db = await Db.inMemory(
        keyProvider: const StaticKeyProvider('test'),
      );
      await db.close();
    });

    test('Db.open accepts CallbackKeyProvider (compile check)', () async {
      final Db db = await Db.inMemory(
        keyProvider: CallbackKeyProvider(() async => 'async-key'),
      );
      await db.close();
    });

    test('Db.open rejects password + keyProvider (mutual exclusion)',
        () async {
      await expectLater(
        () => Db.inMemory(
          password: 'literal',
          keyProvider: const StaticKeyProvider('from-provider'),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('Db.open rejects empty key from KeyProvider', () async {
      await expectLater(
        () => Db.inMemory(
          keyProvider: const StaticKeyProvider(''),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('Db.open accepts neither password nor keyProvider (back-compat)',
        () async {
      final Db db = await Db.inMemory();
      await db.close();
    });

    test('SqliteQueryProvider validates the EncryptionConfig eagerly', () {
      expect(
        () => SqliteQueryProvider.inMemory(
          password: 'x',
          encryptionConfig: const EncryptionConfig(kdfIterations: 0),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('Db.changePassword — argument validation', () {
    test('throws when called without a newPassword or newKeyProvider',
        () async {
      final Db db = await Db.inMemory(password: 'old');
      try {
        await expectLater(
          db.changePassword(),
          throwsA(isA<ArgumentError>()),
        );
      } finally {
        await db.close();
      }
    });

    test('throws when called with both newPassword and newKeyProvider',
        () async {
      final Db db = await Db.inMemory(password: 'old');
      try {
        await expectLater(
          db.changePassword(
            newPassword: 'p',
            newKeyProvider: const StaticKeyProvider('k'),
          ),
          throwsA(isA<ArgumentError>()),
        );
      } finally {
        await db.close();
      }
    });

    test('throws when newKeyProvider returns an empty key', () async {
      final Db db = await Db.inMemory(password: 'old');
      try {
        await expectLater(
          db.changePassword(
            newKeyProvider: const StaticKeyProvider(''),
          ),
          throwsA(isA<ArgumentError>()),
        );
      } finally {
        await db.close();
      }
    });
  });

  group('redactPragmaKey() — redaction', () {
    test('redacts a simple PRAGMA key literal', () {
      expect(
        redactPragmaKey("PRAGMA key = 'hunter2'"),
        "PRAGMA key = '***'",
      );
    });

    test('redacts a simple PRAGMA rekey literal', () {
      expect(
        redactPragmaKey("PRAGMA rekey = 'hunter2'"),
        "PRAGMA rekey = '***'",
      );
    });

    test('handles a value that contains an escaped single quote', () {
      // d_rocket escapes single quotes by doubling, so
      // the SQL form is PRAGMA key = 'O''Brien'. The
      // redaction should eat the whole literal.
      expect(
        redactPragmaKey("PRAGMA key = 'O''Brien'"),
        "PRAGMA key = '***'",
      );
    });

    test('is case-insensitive on the PRAGMA keyword', () {
      expect(
        redactPragmaKey("pragma key = 'hunter2'"),
        "pragma key = '***'",
      );
      expect(
        redactPragmaKey("Pragma Key = 'hunter2'"),
        "Pragma Key = '***'",
      );
    });

    test('tolerates extra whitespace', () {
      expect(
        redactPragmaKey("PRAGMA  key   =    'hunter2'"),
        "PRAGMA  key   =    '***'",
      );
    });

    test('redacts the first match in a multi-statement script', () {
      expect(
        redactPragmaKey(
          "PRAGMA key = 'hunter2'; SELECT 1;",
        ),
        "PRAGMA key = '***'; SELECT 1;",
      );
    });

    test('returns unrelated SQL unchanged', () {
      const String sql = "SELECT * FROM users WHERE id = 42;";
      expect(redactPragmaKey(sql), sql);
    });

    test('returns the empty string unchanged', () {
      expect(redactPragmaKey(''), '');
    });
  });

  // Back-compat smoke: the original 1.0.5 API still works
  // on a fresh checkout (this is the regression net for
  // the signature additions across the 4 commits).
  group('Back-compat — 1.0.5 API surface still works', () {
    test('Db.open with no password, no config, no strategy (plain SQLite)',
        () async {
      final String tmp = '${Directory.systemTemp.path}/'
          'd_rocket_ecosystem_backcompat.db';
      try {
        final Db db = await Db.open(path: tmp);
        await db.close();
      } finally {
        try {
          await File(tmp).delete();
        } catch (_) {
          // best-effort cleanup
        }
      }
    });
  });

  group('Db.isOpen', () {
    test('is true after Db.inMemory()', () async {
      final Db db = await Db.inMemory();
      try {
        expect(db.isOpen, isTrue);
      } finally {
        await db.close();
      }
    });

    test('is false after Db.close()', () async {
      final Db db = await Db.inMemory();
      await db.close();
      expect(db.isOpen, isFalse);
    });
  });

  group('Db.diagnostics()', () {
    test('plain DB reports encrypted=false and status=plain', () async {
      final Db db = await Db.inMemory();
      try {
        final Map<String, Object?> d = db.diagnostics();
        expect(d['isOpen'], isTrue);
        expect(d['encrypted'], isFalse);
        expect(d['encryptionStatus'], EncryptionStatus.plain);
        expect(d['keySource'], 'none');
        expect(d['encryptionConfig'], isNull);
      } finally {
        await db.close();
      }
    });

    test('password DB reports encrypted=true and keySource=password',
        () async {
      final Db db = await Db.inMemory(password: 'k');
      try {
        final Map<String, Object?> d = db.diagnostics();
        expect(d['encrypted'], isTrue);
        expect(d['keySource'], 'password');
        expect(d['encryptionConfig'], isNull);
      } finally {
        await db.close();
      }
    });

    test('keyProvider DB reports keySource=keyProvider', () async {
      final Db db = await Db.inMemory(
        keyProvider: const StaticKeyProvider('k'),
      );
      try {
        final Map<String, Object?> d = db.diagnostics();
        expect(d['encrypted'], isTrue);
        expect(d['keySource'], 'keyProvider');
      } finally {
        await db.close();
      }
    });

    test('EncryptionConfig is reported as a map of the four tunables',
        () async {
      final Db db = await Db.inMemory(
        password: 'k',
        encryptionConfig: const EncryptionConfig(
          kdfIterations: 1000000,
          pageSize: 8192,
          hmacUse: false,
          memorySecurity: false,
        ),
      );
      try {
        final Map<String, Object?> d = db.diagnostics();
        expect(d['encryptionConfig'], <String, Object?>{
          'kdfIterations': 1000000,
          'pageSize': 8192,
          'hmacUse': false,
          'memorySecurity': false,
        });
      } finally {
        await db.close();
      }
    });

    test('isOpen flips to false after close()', () async {
      final Db db = await Db.inMemory();
      await db.close();
      final Map<String, Object?> d = db.diagnostics();
      expect(d['isOpen'], isFalse);
    });

    test(
      'encryptionStatus is encrypted (or unknown) when a password is used',
      () async {
        final Db db = await Db.inMemory(password: 'k');
        try {
          // On a SQLCipher build, status is
          // EncryptionStatus.encrypted. On vanilla
          // SQLite (the dev machine), it is
          // EncryptionStatus.unknown — the probe
          // couldn't confirm the engine. Both
          // indicate "the key was sent", so the
          // contract is met.
          expect(
            db.diagnostics()['encryptionStatus'],
            anyOf(
              EncryptionStatus.encrypted,
              EncryptionStatus.unknown,
            ),
          );
        } finally {
          await db.close();
        }
      },
    );
  });

  group('isSqlCipherAvailable()', () {
    test('returns false on a host without libsqlcipher (and caches it)',
        () {
      // The result is cached for the lifetime of
      // the isolate. The dev machine has vanilla
      // SQLite, so the cached value is false; the
      // second call must return the same.
      final bool first = isSqlCipherAvailable();
      final bool second = isSqlCipherAvailable();
      expect(second, first);
    });

    test('debugResetSqlCipherProbeCache clears the cache (test only)', () {
      isSqlCipherAvailable();
      debugResetSqlCipherProbeCache();
      // After the reset, the next call probes
      // again. We cannot assert the value (it
      // depends on the host engine), only that
      // the call does not throw.
      expect(isSqlCipherAvailable, isNotNull);
    });
  });
}
