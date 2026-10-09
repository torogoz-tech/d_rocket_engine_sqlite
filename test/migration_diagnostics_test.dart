import 'dart:convert';
import 'dart:io';

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  test('writes CLI migration diagnostics as NDJSON', () {
    final directory = Directory.systemTemp.createTempSync('drocket-diag-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/events.ndjson');
    final sink = MigrationDiagnosticFile(file.path);

    sink.record(
      operation: 'cli.status',
      startedAt: DateTime.utc(2026, 10, 8, 20),
      duration: const Duration(milliseconds: 4),
      success: true,
      metadata: const <String, Object?>{'db': 'app.db'},
    );

    final event = jsonDecode(file.readAsStringSync().trim()) as Map;
    expect(event['category'], 'migration');
    expect(event['operation'], 'cli.status');
    expect(event['success'], isTrue);
    expect((event['metadata'] as Map)['source'],
        'd_rocket_engine_sqlite_cli');
  });
}
