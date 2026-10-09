/// Generates the temporary worker used by the SQLite migration CLI.
String buildMigrationWorkerSource(String migrationsImport) => '''
import 'dart:io';

import 'package:d_rocket/d_rocket.dart';
import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';

import '$migrationsImport' as user_migrations;

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('Usage: migration_worker <db> <run|rollback> [target]');
    exit(2);
  }
  final provider = SqliteQueryProvider.file(args[0]);
  final runner = MigrationRunner(
    createExecutor: () => (String sql, [List<Object?>? binds]) {
      provider.execute(sql, binds);
    },
    createSelector: () => (String sql, [List<Object?>? binds]) {
      if (binds == null || binds.isEmpty) return provider.select(sql);
      return provider.selectWithBinds(sql, binds);
    },
    createTransaction: () {
      provider.execute('BEGIN');
      return MigrationTransaction(
        executor: (String sql, [List<Object?>? binds]) {
          provider.execute(sql, binds);
        },
        commit: () => provider.execute('COMMIT'),
        rollback: () => provider.execute('ROLLBACK'),
      );
    },
  );
  try {
    final migrations = user_migrations.migrations;
    switch (args[1]) {
      case 'run':
        final target = args.length > 2 ? int.tryParse(args[2]) : null;
        final applied = target == null
            ? runner.run(migrations)
            : runner.migrateTo(target, migrations);
        stdout.writeln('\${applied.length} migration(s).');
        break;
      case 'rollback':
        final applied = runner.applied();
        if (applied.isEmpty) {
          stdout.writeln('No applied migrations to roll back.');
          break;
        }
        final last = applied.last;
        final candidates = migrations.where((m) => m.id == last.id).toList();
        if (candidates.isEmpty) {
          stderr.writeln(
            'Migration "\${last.id}" is applied but missing from migrations.',
          );
          exit(4);
        }
        final rolledBack = runner.rollback(<MigrationBase>[candidates.single]);
        stdout.writeln('Rolled back \${rolledBack.length} migration(s).');
        break;
      default:
        stderr.writeln('Unknown worker operation: \${args[1]}');
        exit(2);
    }
  } finally {
    provider.dispose();
  }
}
''';
