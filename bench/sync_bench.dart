// d_rocket 2.1.0 — sync throughput benchmark.
//
// Usage:
//   dart run bench/sync_bench.dart
//   dart run bench/sync_bench.dart --changes 5000

import 'dart:io';

import 'package:d_rocket/d_rocket.dart';

Future<void> main(List<String> args) async {
  final int changes = _readInt(args, '--changes') ?? 1000;
  if (changes < 1) {
    throw ArgumentError.value(changes, 'changes', 'must be positive');
  }

  final List<SyncChange> batch = <SyncChange>[
    for (int i = 0; i < changes; i++)
      SyncChange(
        tableName: 'events',
        pk: '$i',
        type: SyncChangeType.upsert,
        payload: <String, Object?>{
          'id': i,
          'name': 'event-$i',
          'amount': i / 100,
        },
        version: i + 1,
        changeId: 'bench-client:$i',
      ),
  ];
  final InMemorySyncProvider provider = InMemorySyncProvider();
  final Stopwatch firstTimer = Stopwatch()..start();
  await provider.syncAsync(
    SyncEnvelope(clientId: 'bench-client', since: 0, changes: batch),
  );
  firstTimer.stop();

  final Stopwatch retryTimer = Stopwatch()..start();
  await provider.syncAsync(
    SyncEnvelope(clientId: 'bench-client', since: 0, changes: batch),
  );
  retryTimer.stop();

  stdout.writeln('| Scenario | Changes | Duration | Throughput |');
  stdout.writeln('| --- | ---: | ---: | ---: |');
  _writeRow('initial push', changes, firstTimer.elapsedMicroseconds);
  _writeRow('idempotent retry', changes, retryTimer.elapsedMicroseconds);
}

int? _readInt(List<String> args, String flag) {
  final int index = args.indexOf(flag);
  if (index == -1 || index + 1 >= args.length) return null;
  return int.tryParse(args[index + 1]);
}

void _writeRow(String scenario, int changes, int micros) {
  final double seconds = micros / Duration.microsecondsPerSecond;
  final double throughput = seconds == 0 ? double.infinity : changes / seconds;
  stdout.writeln(
    '| $scenario | $changes | ${micros / 1000} ms | '
    '${throughput.toStringAsFixed(0)} changes/s |',
  );
}
