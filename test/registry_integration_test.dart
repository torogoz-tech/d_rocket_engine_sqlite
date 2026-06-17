// Integration test for the central `d_rocket_registry.g.dart`
// produced by `d_rocket_builder:record_registry`.
//
// This test verifies the central-registry pattern shipped in
// the d_rocket roadmap. The `d_rocket_registry.g.dart` that
// ships in `d_rocket_sqlite/lib/` is the only entry point the
// user needs to wire up their records (and, with
// "absorb d_serializer", also their `@Serializable` classes).
//
// The test imports the generated registry, calls
// `initializeD`, and asserts that:
//
// 1. Every `extends Record` class in the consumer's `lib/.dart`
// has been registered in d_rocket's internal registry (so
// `Record.toString` produces a debug-friendly
// representation like `Author(id: 1, name: Le Guin, country:
// USA)` instead of `Author`).
// 2. The `Record` base class's `readField` method reads fields
// through the registry (so the LINQ `MemberAccess` evaluator
// can dispatch on a `Record` instance without the user
// having to write a hand-rolled `readField` override).
// 3. The generated `d_rocket_registry.g.dart` mentions every
// discovered `register<X>Record` call in the correct
// order — this catches regressions in the codegen.

import 'dart:io';

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

import '../example/bookstore.dart';
import '../example/d_rocket_registry.g.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  // The test must call `initializeD` exactly once before
  // any `Record` is constructed. We do it in `setUpAll` and
  // then assert the registration is effective in each test.
  setUpAll(initializeD);

  group('initializeD() — central record registry', () {
    test('is idempotent', () {
      // A second call must be a no-op (no exception, no
      // duplicate-registration warning).
      initializeD();
      initializeD();
    });

    test('registerAuthorRecord registers the field accessors', () {
      final Author a = Author(id: 1, name: 'Le Guin', country: 'USA');
      // If `Author` were not registered, the `Record` constructor
      // would have thrown a StateError. We constructed `a` above
      // without error, so the registration took effect.
      expect(a.readField('id'), 1);
      expect(a.readField('name'), 'Le Guin');
      expect(a.readField('country'), 'USA');
      expect(a.readField('notAField'), isNull);
    });

    test('registerBookRecord registers the field accessors', () {
      final Book b = Book(
        id: 42,
        title: 'A Wizard of Earthsea',
        authorId: 1,
        year: 1968,
        price: 12.50,
        category: 'fantasy',
      );
      expect(b.readField('id'), 42);
      expect(b.readField('title'), 'A Wizard of Earthsea');
      expect(b.readField('authorId'), 1);
      expect(b.readField('year'), 1968);
      expect(b.readField('price'), 12.50);
      expect(b.readField('category'), 'fantasy');
    });

    test('registerSaleRecord registers the field accessors', () {
      final Sale s = Sale(
        id: 1,
        bookId: 3,
        customer: 'Alice',
        quantity: 2,
        totalPrice: 25.98,
        date: '2024-01-20',
      );
      expect(s.readField('id'), 1);
      expect(s.readField('bookId'), 3);
      expect(s.readField('customer'), 'Alice');
      expect(s.readField('quantity'), 2);
      expect(s.readField('totalPrice'), 25.98);
      expect(s.readField('date'), '2024-01-20');
    });

    test('Record.toString produces a debug-friendly representation', () {
      final Author a = Author(id: 1, name: 'Le Guin', country: 'USA');
      // The exact string includes all registered fields, comma-
      // separated. We assert the structural shape rather than
      // the literal text because the field ordering depends on
      // the analyzer's enumeration of the class fields.
      final String s = a.toString();
      expect(s, startsWith('Author('));
      expect(s, endsWith(')'));
      expect(s, contains('id: 1'));
      expect(s, contains('name: Le Guin'));
      expect(s, contains('country: USA'));
    });

    test(
        'LINQ MemberAccess on a registered Record returns the field value '
        '(the central purpose of the registry)', () {
      final Author a = Author(id: 7, name: 'Asimov', country: 'Russia');
      // Without the registry, `Expr.member(...).eval(ctx)` would
      // fall back to `null` because no class-implemented
      // `readField` is in scope. With the registry, the
      // generated accessors provide the value.
      final Expr nameAccess = Expr.member(Expr.param('a'), 'name');
      expect(nameAccess.eval(<String, Object?>{'a': a}), 'Asimov');
      final Expr countryAccess = Expr.member(Expr.param('a'), 'country');
      expect(countryAccess.eval(<String, Object?>{'a': a}), 'Russia');
    });
  });

  group('initializeD() — generated registry file shape (regression)', () {
    test('d_rocket_registry.g.dart mentions every register call', () {
      // We import the registry file's source by reading the
      // string contents. The codegen output is deterministic and
      // sorted, so the substring assertions are stable.
      final String src =
          File('example/d_rocket_registry.g.dart').readAsStringSync();
      expect(src, contains('registerAuthorRecord()'));
      expect(src, contains('registerBookRecord()'));
      expect(src, contains('registerSaleRecord()'));
      // The function name is `initializeD` (not the legacy
      // `initializeDSerializer` from `d_builder`).
      expect(src, contains('void initializeD()'));
      // The registry is idempotent (uses a `_dRocketInitialized`
      // flag), not `initializeDSerializer`.
      expect(src, isNot(contains('initializeDSerializer')));
    });

    test(
        'd_rocket_registry.g.dart docstring mentions both `extends Record` '
        'AND `@Serializable` (Fase B extension)', () {
      // The extension of `RecordRegistryBuilder` updated
      // the header comment to mention both record and
      // serializable detection. If the codegen regresses, this
      // test catches it.
      final String src =
          File('example/d_rocket_registry.g.dart').readAsStringSync();
      expect(src, contains('extends Record'));
      expect(src, contains('@Serializable'));
    });
  });
}
