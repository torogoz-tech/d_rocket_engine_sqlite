import 'package:d_rocket/d_rocket.dart';
import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  test('rebuildTable preserves explicitly selected SQLite columns', () async {
    final SqliteQueryProvider provider = SqliteQueryProvider.inMemory();
    try {
      provider.execute(
        'CREATE TABLE events (id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
      );
      provider.execute(
        'INSERT INTO events (id, name) VALUES (?, ?)',
        <Object?>[1, 'created'],
      );
      provider.execute('BEGIN');

      final MigrationExecutor execute = (
        String sql, [
        List<Object?>? binds,
      ]) {
        provider.execute(sql, binds);
      };
      execute.rebuildTable(
        'events',
        'CREATE TABLE "events" ("id" INTEGER PRIMARY KEY, "name" TEXT NOT NULL, "amount" REAL NOT NULL DEFAULT 0)',
        columns: <String>['id', 'name'],
      );
      provider.execute('COMMIT');

      expect(
          provider.select('SELECT id, name, amount FROM events'),
          <Map<String, Object?>>[
            <String, Object?>{'id': 1, 'name': 'created', 'amount': 0.0},
          ]);
    } finally {
      await provider.disposeAsync();
    }
  });
}
