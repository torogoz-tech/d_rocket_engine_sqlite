import 'package:d_rocket/d_rocket.dart';

class CliMigrationOne extends MigrationBase {
  @override
  String get id => '001';

  @override
  String get name => 'create_cli_items';

  @override
  void up(MigrationExecutor exec) {
    exec('CREATE TABLE cli_items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
  }

  @override
  void down(MigrationExecutor exec) {
    exec('DROP TABLE cli_items');
  }
}
