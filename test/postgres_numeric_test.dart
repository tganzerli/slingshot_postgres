/// Unit tests for [PostgresNumeric] — pure, no Postgres and no FFI.
///
/// The point of the type is that a `numeric` survives the trip with every
/// digit intact, so the tests are built around values a `double` cannot
/// hold.
library;

import 'package:slingshot_postgres/src/decoder/postgres_numeric.dart';
import 'package:test/test.dart';

void main() {
  group('exactness', () {
    test('retains digits a double would silently drop', () {
      // 25 significant digits; a double holds ~15-17.
      const s = '1234567890123456789.0123456';
      final n = PostgresNumeric.fromText(s);
      expect(n.toString(), s);
      expect(n.unscaledValue, BigInt.parse('12345678901234567890123456'));
      expect(n.scale, 7);
      // The lossy view really is lossy — this is the whole motivation.
      expect(n.toDouble().toString(), isNot(s));
    });

    test('money-sized value round-trips through unscaled/scale', () {
      final n = PostgresNumeric.fromText('1234.56');
      expect(n.unscaledValue, BigInt.from(123456));
      expect(n.scale, 2);
      expect(n.toDouble(), closeTo(1234.56, 1e-9));
    });

    test('0.1 + 0.2 stays exact where double does not', () {
      final a = PostgresNumeric.fromText('0.1');
      final b = PostgresNumeric.fromText('0.2');
      final sum = a.unscaledValue + b.unscaledValue; // same scale
      expect(sum, BigInt.from(3));
      expect(0.1 + 0.2 == 0.3, isFalse); // the contrast
    });
  });

  group('scale, sign and zero', () {
    test('integer has scale 0', () {
      final n = PostgresNumeric.fromText('42');
      expect(n.scale, 0);
      expect(n.unscaledValue, BigInt.from(42));
    });

    test('negative below one keeps its digits', () {
      final n = PostgresNumeric.fromText('-0.001');
      expect(n.unscaledValue, BigInt.from(-1));
      expect(n.scale, 3);
      expect(n.toDouble(), closeTo(-0.001, 1e-12));
    });

    test('zero carries its declared scale', () {
      expect(PostgresNumeric.fromText('0').scale, 0);
      expect(PostgresNumeric.fromText('0.00').scale, 2);
      expect(PostgresNumeric.fromText('0.00').unscaledValue, BigInt.zero);
    });

    test('trailing zeros are part of the value, as in Postgres', () {
      final a = PostgresNumeric.fromText('1.10');
      final b = PostgresNumeric.fromText('1.1');
      expect(a.scale, 2);
      expect(b.scale, 1);
      // Same quantity, different numeric values — dscale is data.
      expect(a == b, isFalse);
      expect(a.toDouble(), b.toDouble());
    });
  });

  group('non-finite states', () {
    test('NaN is recognised and converts', () {
      final n = PostgresNumeric.fromText('NaN');
      expect(n.isNaN, isTrue);
      expect(n.isFinite, isFalse);
      expect(n.toString(), 'NaN');
      expect(n.toDouble().isNaN, isTrue);
    });

    test('both infinities are recognised and convert', () {
      final p = PostgresNumeric.fromText('Infinity');
      final m = PostgresNumeric.fromText('-Infinity');
      expect(p.isInfinite, isTrue);
      expect(m.isInfinite, isTrue);
      expect(p.isFinite, isFalse);
      expect(p.toDouble(), double.infinity);
      expect(m.toDouble(), double.negativeInfinity);
    });

    test('unscaledValue and scale throw instead of inventing a number', () {
      for (final s in ['NaN', 'Infinity', '-Infinity']) {
        final n = PostgresNumeric.fromText(s);
        expect(() => n.unscaledValue, throwsStateError, reason: s);
        expect(() => n.scale, throwsStateError, reason: s);
      }
    });

    test('the thrown message names the member and points at isFinite', () {
      final n = PostgresNumeric.fromText('NaN');
      expect(
          () => n.scale,
          throwsA(isA<StateError>().having((e) => e.message, 'message',
              allOf(contains('scale'), contains('isFinite')))));
    });
  });

  group('equality', () {
    test('equal text is equal value, and hashes alike', () {
      final a = PostgresNumeric.fromText('12.30');
      final b = PostgresNumeric.fromText('12.30');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('NaN equals NaN, unlike the double it converts to', () {
      // Postgres treats numeric NaN = NaN as true; the double does not.
      final a = PostgresNumeric.fromText('NaN');
      final b = PostgresNumeric.fromText('NaN');
      expect(a, b);
      expect(a.toDouble() == b.toDouble(), isFalse);
    });
  });
}
