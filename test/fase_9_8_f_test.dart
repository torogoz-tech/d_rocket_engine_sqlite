import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  late SqliteQueryProvider provider;

  setUp(() async {
    provider = SqliteQueryProvider.inMemory();
    provider.execute('''
      CREATE TABLE users (
        id    INTEGER PRIMARY KEY AUTOINCREMENT,
        name  TEXT NOT NULL,
        score INTEGER
      )
    ''');
    provider.execute("INSERT INTO users (name, score) VALUES ('Abner', 30)");
    provider.execute("INSERT INTO users (name, score) VALUES ('Maria', 25)");
    provider.execute("INSERT INTO users (name, score) VALUES ('Jose', NULL)");
  });

  tearDown(() async {
    await provider.disposeAsync();
  });

  group('Fase 9.8.f — visitMapLiteral (json_object)', () {
    test('json_object SQL function is available (SQLite 3.38+)', () {
      // Direct SQL test: verify the function works on
      // the connection. The d_rocket translation just
      // delegates to this function.
      final row = provider.select('''
        SELECT json_object('name', 'Abner', 'age', 30) AS m
      ''');
      final m = row.first['m'] as String;
      expect(m, contains('"name":"Abner"'));
      expect(m, contains('"age":30'));
    });

    test('json_object with NULL values', () {
      final row = provider.select('''
        SELECT json_object('name', 'Jose', 'age', NULL) AS m
      ''');
      final m = row.first['m'] as String;
      expect(m, contains('"name":"Jose"'));
      // SQLite json_object serialises NULL as JSON null.
      expect(m, contains('null'));
    });
  });

  group('Fase 9.8.f — visitNullSafeAccess (CASE WHEN)', () {
    test('CASE WHEN x IS NULL THEN NULL ELSE x END', () {
      // Direct SQL test: verify the pattern behaves
      // correctly for both NULL and non-NULL values.
      final rows = provider.select('''
        SELECT name, score,
               CASE WHEN score IS NULL THEN NULL ELSE score END AS safe
        FROM users
        ORDER BY id
      ''');
      expect((rows[0]['safe'] as int), 30); // Abner
      expect((rows[1]['safe'] as int), 25); // Maria
      expect(rows[2]['safe'], isNull); // Jose (score is NULL)
    });
  });
}
