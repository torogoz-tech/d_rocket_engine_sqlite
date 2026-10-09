import 'package:d_rocket/d_rocket.dart';
import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  final diagnostics = DrocketDiagnostics.instance;

  setUp(() {
    diagnostics.clear();
    diagnostics.configure(
      enabled: true,
      publishToVmService: false,
      includeSensitiveData: false,
    );
  });

  tearDown(() {
    diagnostics.clear();
    diagnostics.configure(enabled: false, publishToVmService: true);
  });

  test('captures SQL kind, bind metadata, rows and null values safely', () {
    final provider = SqliteQueryProvider.inMemory();
    addTearDown(provider.dispose);

    provider.execute('CREATE TABLE sample (id INTEGER, note TEXT)');
    provider.execute(
      'INSERT INTO sample (id, note) VALUES (?, ?)',
      <Object?>[7, null],
    );
    final rows = provider.selectWithBinds(
      'SELECT id, note FROM sample WHERE id = ?',
      <Object?>[7],
    );

    expect(rows.single['id'], 7);
    expect(rows.single['note'], isNull);
    expect(diagnostics.snapshot, hasLength(3));

    final create = diagnostics.snapshot[0];
    expect(create.operation, 'ddl');
    expect(create.metadata['sqlKind'], 'ddl');

    final insert = diagnostics.snapshot[1];
    expect(insert.operation, 'insert');
    expect(insert.metadata['sql'], contains('INSERT INTO'));
    expect(insert.metadata['bindCount'], 2);
    expect(insert.metadata['bindTypes'], <String>['int', 'null']);
    expect(insert.metadata.containsKey('binds'), isFalse);

    final select = diagnostics.snapshot[2];
    expect(select.operation, 'select');
    expect(select.metadata['rowCount'], 1);
    expect(select.metadata['bindTypes'], <String>['int']);
  });

  test('captures failed SQL as a diagnostic error', () {
    final provider = SqliteQueryProvider.inMemory();
    addTearDown(provider.dispose);

    expect(
      () => provider.execute('INSERT INTO missing_table VALUES (1)'),
      throwsA(isA<DatabaseException>()),
    );

    expect(diagnostics.snapshot.single.success, isFalse);
    expect(diagnostics.snapshot.single.operation, 'insert');
    expect(diagnostics.snapshot.single.error, isNotEmpty);
  });

  test('identifies SQL executed from the LINQ context', () async {
    final provider = SqliteQueryProvider.inMemory();
    addTearDown(provider.dispose);

    await diagnostics.runLinq(
      () => provider.selectAsync('SELECT 1 AS value'),
    );

    expect(diagnostics.snapshot.single.category, DiagnosticCategory.linq);
  });
}
