/// Unit tests for the `SqlTranslator`.
library;

import 'package:d_rocket_engine_sqlite/d_rocket_engine_sqlite.dart';
import 'package:test/test.dart';

void main() {
  setUp(dRocketSqlite);
  tearDown(EngineRegistry.resetForTest);
  group('SqlTranslator — basic operators', () {
    test('Const(int) → `?` with bind', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.const_(42),
      ));
      expect(frag.sql, '?');
      expect(frag.binds, [42]);
    });

    test('Const(String) → `?` with bind', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.const_('hello'),
      ));
      expect(frag.sql, '?');
      expect(frag.binds, ['hello']);
    });

    test('Const(null) → `NULL`', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.const_(null),
      ));
      expect(frag.sql, 'NULL');
      expect(frag.binds, isEmpty);
    });

    test('NullExpr → `NULL`', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.null_,
      ));
      expect(frag.sql, 'NULL');
      expect(frag.binds, isEmpty);
    });
  });

  group('SqlTranslator — column references', () {
    test('MemberAccess on alias → column', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.member(Expr.param('u'), 'age'),
      ));
      expect(frag.sql, 'age');
      expect(frag.binds, isEmpty);
    });

    test('Column name with reserved word is NOT quoted (SQLite behavior)', () {
      // We deliberately do NOT double-quote column names: SQLite
      // treats double-quoted strings that don't match a known
      // column/table as string literals. Leaving the identifier
      // bare lets SQLite detect non-existent columns. Users with
      // reserved-word columns should rename them; documented in
      // the translator.
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.member(Expr.param('u'), 'order'),
      ));
      expect(frag.sql, 'order');
    });

    test('Non-alias member access throws', () {
      final t = SqlTranslator();
      expect(
        () => t.translateLambda(Expr.lambda(
          [Expr.param('u')],
          Expr.member(Expr.param('v'), 'age'),
        )),
        throwsStateError,
      );
    });
  });

  group('SqlTranslator — binary operators', () {
    test('==', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.binary('==', Expr.member(Expr.param('u'), 'age'), Expr.const_(18)),
      ));
      expect(frag.sql, '(age = ?)');
      expect(frag.binds, [18]);
    });

    test('!=', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.binary(
            '!=', Expr.member(Expr.param('u'), 'name'), Expr.const_('Alice')),
      ));
      expect(frag.sql, '(name <> ?)');
      expect(frag.binds, ['Alice']);
    });

    test('>, <, >=, <=', () {
      final t = SqlTranslator();
      for (final op in ['>', '<', '>=', '<=']) {
        final frag = t.translateLambda(Expr.lambda(
          [Expr.param('u')],
          Expr.binary(op, Expr.member(Expr.param('u'), 'age'), Expr.const_(18)),
        ));
        expect(frag.sql, '(age $op ?)');
        expect(frag.binds, [18]);
      }
    });

    test('&& and ||', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.binary(
            '&&',
            Expr.binary(
                '>', Expr.member(Expr.param('u'), 'age'), Expr.const_(18)),
            Expr.binary('==', Expr.member(Expr.param('u'), 'active'),
                Expr.const_(true))),
      ));
      expect(frag.sql, '((age > ?) AND (active = ?))');
      expect(frag.binds, [18, true]);
    });

    test('+', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.binary('+', Expr.member(Expr.param('u'), 'age'), Expr.const_(1)),
      ));
      expect(frag.sql, '(age + ?)');
      expect(frag.binds, [1]);
    });
  });

  group('SqlTranslator — unary operators', () {
    test('!', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.unary('!', Expr.member(Expr.param('u'), 'active')),
      ));
      expect(frag.sql, 'NOT (active)');
    });

    test('-', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.unary('-', Expr.member(Expr.param('u'), 'balance')),
      ));
      expect(frag.sql, '- (balance)');
    });
  });

  group('SqlTranslator — String methods', () {
    test('startsWith → substr(col, 1, ?) = ? (case-sensitive)', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.call(
          Expr.member(Expr.param('u'), 'name'),
          'startsWith',
          [Expr.const_('A')],
        ),
      ));
      expect(frag.sql, '(substr(name, 1, ?) = ?)');
      expect(frag.binds, [1, 'A']);
    });

    test('endsWith → substr(col, length(col) - ? + 1) = ?', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.call(
          Expr.member(Expr.param('u'), 'name'),
          'endsWith',
          [Expr.const_('e')],
        ),
      ));
      expect(frag.sql, '(substr(name, length(name) - ? + 1) = ?)');
      expect(frag.binds, [1, 'e']);
    });

    test('contains → INSTR(col, ?) > ? (case-sensitive)', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.call(
          Expr.member(Expr.param('u'), 'name'),
          'contains',
          [Expr.const_('lic')],
        ),
      ));
      expect(frag.sql, '(INSTR(name, ?) > ?)');
      expect(frag.binds, ['lic', 0]);
    });

    test('length → LENGTH(col)', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.call(Expr.member(Expr.param('u'), 'name'), 'length', []),
      ));
      expect(frag.sql, 'LENGTH(name)');
    });

    test('toUpperCase', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.call(Expr.member(Expr.param('u'), 'name'), 'toUpperCase', []),
      ));
      expect(frag.sql, 'UPPER(name)');
    });

    test('toLowerCase', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.call(Expr.member(Expr.param('u'), 'name'), 'toLowerCase', []),
      ));
      expect(frag.sql, 'LOWER(name)');
    });

    test('trim', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.call(Expr.member(Expr.param('u'), 'name'), 'trim', []),
      ));
      expect(frag.sql, 'TRIM(name)');
    });

    test('isEmpty', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.call(Expr.member(Expr.param('u'), 'name'), 'isEmpty', []),
      ));
      expect(frag.sql, '(name = \'\')');
    });

    test('isNotEmpty', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.call(Expr.member(Expr.param('u'), 'name'), 'isNotEmpty', []),
      ));
      expect(frag.sql, '(name <> \'\')');
    });

    test('unsupported method throws', () {
      final t = SqlTranslator();
      expect(
        () => t.translateLambda(Expr.lambda(
          [Expr.param('u')],
          Expr.call(
            Expr.member(Expr.param('u'), 'name'),
            'split',
            [Expr.const_(',')],
          ),
        )),
        throwsStateError,
      );
    });

    test('non-String argument to String method throws', () {
      final t = SqlTranslator();
      expect(
        () => t.translateLambda(Expr.lambda(
          [Expr.param('u')],
          Expr.call(
            Expr.member(Expr.param('u'), 'name'),
            'startsWith',
            [Expr.const_(42)], // int, not String
          ),
        )),
        throwsStateError,
      );
    });
  });

  group('SqlTranslator — complex compositions', () {
    test('(u) => u.age >= 18 && u.name != \'admin\'', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.binary(
          '&&',
          Expr.binary(
            '>=',
            Expr.member(Expr.param('u'), 'age'),
            Expr.const_(18),
          ),
          Expr.binary(
            '!=',
            Expr.member(Expr.param('u'), 'name'),
            Expr.const_('admin'),
          ),
        ),
      ));
      expect(frag.sql, '((age >= ?) AND (name <> ?))');
      expect(frag.binds, [18, 'admin']);
    });

    test('(u) => u.email != null', () {
      final t = SqlTranslator();
      final frag = t.translateLambda(Expr.lambda(
        [Expr.param('u')],
        Expr.binary(
          '!=',
          Expr.member(Expr.param('u'), 'email'),
          Expr.null_,
        ),
      ));
      expect(frag.sql, '(email <> NULL)');
      expect(frag.binds, isEmpty);
    });
  });

  group('SqlTranslator — argument validation', () {
    test('non-Lambda throws', () {
      final t = SqlTranslator();
      expect(
        () => t.translateLambda(Expr.const_(true)),
        throwsArgumentError,
      );
    });

    test('multi-param Lambda throws', () {
      final t = SqlTranslator();
      expect(
        () => t.translateLambda(Expr.lambda(
          [Expr.param('u'), Expr.param('v')],
          Expr.const_(true),
        )),
        throwsArgumentError,
      );
    });

    test('param name mismatch throws', () {
      final t = SqlTranslator();
      expect(
        () => t.translateLambda(Expr.lambda(
          [Expr.param('x')], // alias is 'u', not 'x'.
          Expr.const_(1),
        )),
        throwsArgumentError,
      );
    });
  });
}
