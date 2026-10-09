import 'dart:convert';
import 'dart:io';

import 'package:d_rocket/d_rocket.dart';

class MigrationDiagnosticFile {
  MigrationDiagnosticFile(String path)
      : _file = File(path)..createSync(recursive: true);

  final File _file;
  int _sequence = 0;

  void record({
    required String operation,
    required DateTime startedAt,
    required Duration duration,
    required bool success,
    Object? error,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final event = DiagnosticEvent(
      id: '${startedAt.microsecondsSinceEpoch}-${_sequence++}',
      category: DiagnosticCategory.migration,
      operation: operation,
      startedAt: startedAt,
      finishedAt: startedAt.add(duration),
      duration: duration,
      success: success,
      error: error?.toString(),
      metadata: <String, Object?>{
        'source': 'd_rocket_engine_sqlite_cli',
        ...metadata,
      },
    );
    _file.writeAsStringSync(
      '${jsonEncode(event.toJson())}\n',
      mode: FileMode.append,
    );
  }
}
