/// Unit tests for [decodeByOidBinary] + round-trip with [Param.encode].
///
/// Does NOT require a running Postgres — exercises the binary decoder
/// against synthetic wire-format bytes (the same shape libpq emits when
/// `PQsendQueryParams(..., resultFormat=1)` is used). End-to-end against
/// a live server is covered by the integration tests.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:slingshot_postgres/src/decoder/postgres_decoder.dart';
import 'package:slingshot_postgres/src/decoder/postgres_numeric.dart';
import 'package:slingshot_postgres/src/decoder/postgres_oids.dart';
import 'package:slingshot_postgres/src/decoder/postgres_type.dart';
import 'package:slingshot_postgres/src/postgres/param.dart';
import 'package:test/test.dart';

Uint8List _enc(Param p) {
  final b = p.encode();
  expect(b, isNotNull);
  return b!;
}

void main() {
  group('decodeByOidBinary — primitives', () {
    test('bool 0x01 → true / 0x00 → false', () {
      expect(
          decodeByOidBinary(
              Uint8List.fromList([0x01]), PostgresOid.boolean),
          true);
      expect(
          decodeByOidBinary(
              Uint8List.fromList([0x00]), PostgresOid.boolean),
          false);
    });

    test('int2 / int4 / int8 BE round-trip from encoder', () {
      expect(decodeByOidBinary(_enc(Param.int2(-1)), PostgresOid.int2), -1);
      expect(
          decodeByOidBinary(_enc(Param.int2(0x7FFF)), PostgresOid.int2),
          0x7FFF);
      expect(
          decodeByOidBinary(_enc(Param.int4(42)), PostgresOid.int4), 42);
      expect(
          decodeByOidBinary(
              _enc(Param.int4(-0x80000000)), PostgresOid.int4),
          -0x80000000);
      expect(
          decodeByOidBinary(_enc(Param.int8(1 << 33)), PostgresOid.int8),
          1 << 33);
    });

    test('float4 / float8 IEEE 754 BE round-trip', () {
      final f4 = decodeByOidBinary(_enc(Param.float4(1.5)), PostgresOid.float4)
          as double;
      expect(f4, closeTo(1.5, 1e-6));
      final f8 = decodeByOidBinary(_enc(Param.float8(2.71828)), PostgresOid.float8)
          as double;
      expect(f8, 2.71828);
    });
  });

  group('decodeByOidBinary — text family', () {
    test('text / varchar / bpchar decode as UTF-8', () {
      for (final oid in [
        PostgresOid.text,
        PostgresOid.varchar,
        PostgresOid.bpchar,
        PostgresOid.name,
      ]) {
        // 'café' in UTF-8
        final bytes = Uint8List.fromList([0x63, 0x61, 0x66, 0xC3, 0xA9]);
        expect(decodeByOidBinary(bytes, oid), 'café');
      }
    });

    test('"char" renders its byte the way charout does in text mode', () {
      // `pg_class.relkind`-style ASCII code.
      expect(
          decodeByOidBinary(Uint8List.fromList([0x72]), PostgresOid.char), 'r');
      // 0x00 is the empty string in text mode.
      expect(
          decodeByOidBinary(Uint8List.fromList([0x00]), PostgresOid.char), '');
      // High bit set: `\ooo` on PostgreSQL 15+, never a UTF-8 decode error.
      expect(decodeByOidBinary(Uint8List.fromList([0xE9]), PostgresOid.char),
          r'\351');
    });

    test('name and "char" decode as String in text mode too', () {
      expect(
          decodeByOid(
              Uint8List.fromList('pg_class'.codeUnits), PostgresOid.name),
          'pg_class');
      expect(decodeByOid(Uint8List.fromList('r'.codeUnits), PostgresOid.char),
          'r');
      expect(
          decodeByOid(Uint8List.fromList(r'\351'.codeUnits), PostgresOid.char),
          r'\351');
    });

    test('name and "char" report PostgresType.text', () {
      expect(postgresTypeFromOid(PostgresOid.name), PostgresType.text);
      expect(postgresTypeFromOid(PostgresOid.char), PostgresType.text);
    });

    test('json decodes via jsonDecode', () {
      final bytes = Uint8List.fromList('{"k":1}'.codeUnits);
      final v = decodeByOidBinary(bytes, PostgresOid.json) as Map;
      expect(v['k'], 1);
    });

    test('jsonb skips 1-byte version prefix', () {
      // Encoder: 0x01 + UTF-8 JSON
      final encoded = _enc(Param.jsonb('{"x":42}'));
      final v = decodeByOidBinary(encoded, PostgresOid.jsonb) as Map;
      expect(v['x'], 42);
    });
  });

  group('decodeByOidBinary — bytea', () {
    test('returns raw bytes unchanged', () {
      final raw = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      expect(decodeByOidBinary(raw, PostgresOid.bytea), raw);
    });
  });

  group('decodeByOidBinary — timestamp / timestamptz', () {
    // Changed 2026-09-10: binary `timestamp` used to be stamped
    // `isUtc: true`, which asserted a zone the server never sent and
    // disagreed with the text path for the same column. It is now naive,
    // like text. `timestamptz` is unaffected and stays UTC.
    test('pg epoch (2000-01-01) round-trips to a naive DateTime', () {
      final encoded = _enc(Param.timestamp(DateTime.utc(2000, 1, 1)));
      final v = decodeByOidBinary(encoded, PostgresOid.timestamp) as DateTime;
      expect(v.isUtc, isFalse);
      expect([v.year, v.month, v.day], [2000, 1, 1]);
    });

    test('the same payload as timestamptz stays UTC', () {
      final encoded = _enc(Param.timestamptz(DateTime.utc(2000, 1, 1)));
      final v =
          decodeByOidBinary(encoded, PostgresOid.timestamptz) as DateTime;
      expect(v.isUtc, isTrue);
      expect(v, DateTime.utc(2000, 1, 1));
    });

    test('1 second past epoch (1_000_000 µs) decodes correctly', () {
      final encoded = _enc(Param.timestamptz(DateTime.utc(2000, 1, 1, 0, 0, 1)));
      final v =
          decodeByOidBinary(encoded, PostgresOid.timestamptz) as DateTime;
      expect(v, DateTime.utc(2000, 1, 1, 0, 0, 1));
    });

    test('pre-epoch (negative µs) decodes correctly', () {
      final encoded = _enc(
          Param.timestamptz(DateTime.utc(1999, 12, 31, 23, 59, 59)));
      final v =
          decodeByOidBinary(encoded, PostgresOid.timestamptz) as DateTime;
      expect(v, DateTime.utc(1999, 12, 31, 23, 59, 59));
    });

    test('round-trip preserves modern instant', () {
      final original = DateTime.utc(2026, 5, 23, 14, 30, 45, 123, 456);
      final encoded = _enc(Param.timestamptz(original));
      final decoded =
          decodeByOidBinary(encoded, PostgresOid.timestamptz) as DateTime;
      expect(decoded.microsecondsSinceEpoch,
          original.microsecondsSinceEpoch);
    });
  });

  group('timestamp vs timestamptz — isUtc must not depend on wire format', () {
    // 2026-05-17T13:45:00Z == 8 modules of Postgres epoch micros; build the
    // binary payload the same way the server would.
    final micros = DateTime.utc(2026, 5, 17, 13, 45)
            .difference(DateTime.utc(2000, 1, 1))
            .inMicroseconds;
    final binary = Uint8List(8)
      ..buffer.asByteData().setInt64(0, micros, Endian.big);

    test('timestamptz is UTC in both text and binary', () {
      final t = decodeByOid(
          Uint8List.fromList('2026-05-17 13:45:00+00'.codeUnits),
          PostgresOid.timestamptz) as DateTime;
      final b =
          decodeByOidBinary(binary, PostgresOid.timestamptz) as DateTime;
      expect(t.isUtc, isTrue, reason: 'text timestamptz');
      expect(b.isUtc, isTrue, reason: 'binary timestamptz');
      expect(b.microsecondsSinceEpoch, t.microsecondsSinceEpoch);
    });

    test('timestamp is naive in both text and binary', () {
      // Text has no offset suffix, so DateTime.parse yields isUtc: false.
      final t = decodeByOid(
          Uint8List.fromList('2026-05-17 13:45:00'.codeUnits),
          PostgresOid.timestamp) as DateTime;
      final b = decodeByOidBinary(binary, PostgresOid.timestamp) as DateTime;
      expect(t.isUtc, isFalse, reason: 'text timestamp');
      // This is the defect: the binary path stamps isUtc: true
      // unconditionally, so the same column changes meaning when a
      // consumer flips binaryResult.
      expect(b.isUtc, isFalse, reason: 'binary timestamp');
    });

    test('the wall-clock reading of a timestamp agrees across formats', () {
      final t = decodeByOid(
          Uint8List.fromList('2026-05-17 13:45:00'.codeUnits),
          PostgresOid.timestamp) as DateTime;
      final b = decodeByOidBinary(binary, PostgresOid.timestamp) as DateTime;
      expect([b.year, b.month, b.day, b.hour, b.minute],
          [t.year, t.month, t.day, t.hour, t.minute]);
    });
  });

  group('decodeByOidBinary — numeric (base-10000)', () {
    /// Builds the wire payload numeric_send would write.
    Uint8List num_(
        {required int weight,
        required int sign,
        required int dscale,
        List<int> digits = const []}) {
      final b = Uint8List(8 + digits.length * 2);
      final bd = b.buffer.asByteData()
        ..setInt16(0, digits.length, Endian.big)
        ..setInt16(2, weight, Endian.big)
        ..setUint16(4, sign, Endian.big)
        ..setUint16(6, dscale, Endian.big);
      for (var i = 0; i < digits.length; i++) {
        bd.setInt16(8 + i * 2, digits[i], Endian.big);
      }
      return b;
    }

    PostgresNumeric dec(Uint8List b) =>
        decodeByOidBinary(b, PostgresOid.numeric) as PostgresNumeric;

    test('1234.56 — one group each side of the point', () {
      expect(dec(num_(weight: 0, sign: 0x0000, dscale: 2, digits: [1234, 5600]))
          .toString(), '1234.56');
    });

    test('groups after the first are zero-padded to four digits', () {
      // 1 * 10000 + 0002  → 10002, not 12.
      expect(dec(num_(weight: 1, sign: 0x0000, dscale: 0, digits: [1, 2]))
          .toString(), '10002');
    });

    test('trailing groups the payload omits are zeros', () {
      // 10000: one group, weight 1 — the units group is not transmitted.
      expect(dec(num_(weight: 1, sign: 0x0000, dscale: 0, digits: [1]))
          .toString(), '10000');
    });

    test('negative weight puts the value entirely after the point', () {
      expect(dec(num_(weight: -1, sign: 0x0000, dscale: 3, digits: [10]))
          .toString(), '0.001');
      // weight -2 means a whole group of zeros before the first digit.
      expect(dec(num_(weight: -2, sign: 0x0000, dscale: 8, digits: [1]))
          .toString(), '0.00000001');
    });

    test('sign 0x4000 is negative', () {
      expect(dec(num_(weight: -1, sign: 0x4000, dscale: 1, digits: [5000]))
          .toString(), '-0.5');
    });

    test('dscale beyond the digits carried pads with zeros', () {
      // 1.5 declared as numeric(12,4) → 1.5000
      expect(dec(num_(weight: 0, sign: 0x0000, dscale: 4, digits: [1, 5000]))
          .toString(), '1.5000');
    });

    test('zero carries its declared scale', () {
      expect(dec(num_(weight: 0, sign: 0x0000, dscale: 0)).toString(), '0');
      expect(dec(num_(weight: 0, sign: 0x0000, dscale: 2)).toString(), '0.00');
    });

    test('NaN and the infinities come through the sign field', () {
      expect(dec(num_(weight: 0, sign: 0xC000, dscale: 0)).isNaN, isTrue);
      expect(dec(num_(weight: 0, sign: 0xD000, dscale: 0)).toString(),
          'Infinity');
      expect(dec(num_(weight: 0, sign: 0xF000, dscale: 0)).toString(),
          '-Infinity');
    });

    test('an invalid sign is rejected, not guessed', () {
      expect(() => dec(num_(weight: 0, sign: 0x1234, dscale: 0)),
          throwsFormatException);
    });

    test('a truncated payload is rejected', () {
      expect(() => decodeByOidBinary(Uint8List(4), PostgresOid.numeric),
          throwsFormatException);
      // Header says two digits, payload carries none.
      final lying = num_(weight: 0, sign: 0x0000, dscale: 0)
        ..buffer.asByteData().setInt16(0, 2, Endian.big);
      expect(() => decodeByOidBinary(lying, PostgresOid.numeric),
          throwsFormatException);
    });

    test('a value double cannot hold survives the binary path', () {
      // 1234567890123456789.0123456
      // 1234567890123456789 groups from the point outward as
      // 123|4567|8901|2345|6789, and .0123456 as 0123|4560.
      final n = dec(num_(
          weight: 4,
          sign: 0x0000,
          dscale: 7,
          digits: [123, 4567, 8901, 2345, 6789, 123, 4560]));
      expect(n.toString(), '1234567890123456789.0123456');
      expect(n.unscaledValue, BigInt.parse('12345678901234567890123456'));
    });
  });

  group('decodeByOidBinary — date', () {
    Uint8List days(int n) =>
        Uint8List(4)..buffer.asByteData().setInt32(0, n, Endian.big);

    test('day 0 is the Postgres epoch, 2000-01-01', () {
      final d = decodeByOidBinary(days(0), PostgresOid.date) as DateTime;
      expect([d.year, d.month, d.day], [2000, 1, 1]);
    });

    test('the int32 is signed — dates before 2000 arrive negative', () {
      final d = decodeByOidBinary(days(-1), PostgresOid.date) as DateTime;
      expect([d.year, d.month, d.day], [1999, 12, 31]);
      final old = decodeByOidBinary(days(-730119), PostgresOid.date)
          as DateTime;
      expect([old.year, old.month, old.day], [1, 1, 1]);
    });

    test('date is naive, never stamped UTC', () {
      final d = decodeByOidBinary(days(9999), PostgresOid.date) as DateTime;
      expect(d.isUtc, isFalse);
      expect([d.hour, d.minute, d.second], [0, 0, 0]);
    });

    test('text and binary agree on the same day', () {
      final b = decodeByOidBinary(days(9633), PostgresOid.date) as DateTime;
      final t = decodeByOid(
          Uint8List.fromList('2026-05-17'.codeUnits), PostgresOid.date)
          as DateTime;
      expect([b.year, b.month, b.day], [t.year, t.month, t.day]);
      expect(b.isUtc, t.isUtc);
    });

    test('round-trip through Param.date drops the time component', () {
      final withTime = DateTime(2026, 5, 17, 13, 45, 30);
      final d = decodeByOidBinary(_enc(Param.date(withTime)),
          PostgresOid.date) as DateTime;
      expect([d.year, d.month, d.day], [2026, 5, 17]);
      expect([d.hour, d.minute, d.second], [0, 0, 0]);
    });

    test('infinity sentinels throw instead of decoding to a bogus year', () {
      expect(() => decodeByOidBinary(days(0x7FFFFFFF), PostgresOid.date),
          throwsFormatException);
      expect(() => decodeByOidBinary(days(-0x80000000), PostgresOid.date),
          throwsFormatException);
    });
  });

  group('decodeByOidBinary — uuid', () {
    // Bytes 00..0f in order: exercises the claim that uuid_send writes
    // uuid->data verbatim, with no field-wise byte swapping.
    final ascending = Uint8List.fromList(List<int>.generate(16, (i) => i));

    test('16 bytes decode in received order, lowercase canonical', () {
      expect(decodeByOidBinary(ascending, PostgresOid.uuid),
          '00010203-0405-0607-0809-0a0b0c0d0e0f');
    });

    test('no Microsoft GUID byte swapping on the first three groups', () {
      // If the first group were byte-swapped this would read '03020100'.
      final decoded =
          decodeByOidBinary(ascending, PostgresOid.uuid) as String;
      expect(decoded.substring(0, 8), '00010203');
      expect(decoded.substring(9, 13), '0405');
      expect(decoded.substring(14, 18), '0607');
    });

    test('round-trip through Param.uuid, canonical and bare hex', () {
      const canonical = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';
      expect(decodeByOidBinary(_enc(Param.uuid(canonical)), PostgresOid.uuid),
          canonical);
      // Same value without hyphens must encode to the same 16 bytes.
      expect(_enc(Param.uuid('6ba7b8109dad11d180b400c04fd430c8')),
          _enc(Param.uuid(canonical)));
    });

    test('uppercase input normalises to lowercase output', () {
      expect(
          decodeByOidBinary(
              _enc(Param.uuid('6BA7B810-9DAD-11D1-80B4-00C04FD430C8')),
              PostgresOid.uuid),
          '6ba7b810-9dad-11d1-80b4-00c04fd430c8');
    });

    test('malformed uuid fails in Dart, not at the server', () {
      // Wrong length.
      expect(() => Param.uuid('abc').encode(), throwsArgumentError);
      // Right length, hyphen in the wrong place.
      expect(() => Param.uuid('6ba7b8109-dad-11d1-80b4-00c04fd430c8').encode(),
          throwsArgumentError);
      // Right shape, non-hex digit.
      expect(() => Param.uuid('6ba7b810-9dad-11d1-80b4-00c04fd430cg').encode(),
          throwsArgumentError);
    });

    test('decoder rejects a payload that is not 16 bytes', () {
      expect(() => decodeByOidBinary(Uint8List(15), PostgresOid.uuid),
          throwsFormatException);
    });
  });

  group('decodeByOidBinary — text search', () {
    // Wire builders mirroring tsvectorsend / tsquerysend.
    List<int> i32(int v) => [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];
    List<int> u16(int v) => [v >> 8 & 0xFF, v & 0xFF];
    List<int> cstr(String s) => [...utf8.encode(s), 0];
    // WordEntryPos: weight 3=A 2=B 1=C 0=D in the 2 high bits.
    int wep(int pos, int weight) => weight << 14 | pos;
    List<int> lexeme(String s, List<int> positions) =>
        [...cstr(s), ...u16(positions.length), for (final p in positions) ...u16(p)];
    String vec(List<List<int>> lexemes) => decodeByOidBinary(
        Uint8List.fromList([...i32(lexemes.length), for (final l in lexemes) ...l]),
        PostgresOid.tsvector) as String;
    List<int> val(String s, {int weight = 0, bool prefix = false}) =>
        [1, weight, prefix ? 1 : 0, ...cstr(s)];
    List<int> op(int o) => [2, o];
    List<int> phrase(int distance) => [2, 4, ...u16(distance)];
    const not = 1, and = 2, or = 3;
    String query(List<List<int>> items) => decodeByOidBinary(
        Uint8List.fromList([...i32(items.length), for (final i in items) ...i]),
        PostgresOid.tsquery) as String;

    test('tsvector: positions, weights, no positions, escapes, UTF-8', () {
      expect(
          vec([
            lexeme('a', [wep(1, 3), wep(2, 2), wep(3, 1), wep(4, 0)]),
            lexeme('b', []),
          ]),
          "'a':1A,2B,3C,4 'b'");
      expect(vec([lexeme("it's", []), lexeme(r'back\slash', [wep(7, 0)])]),
          r"'it''s' 'back\\slash':7");
      expect(vec([lexeme('joão', [wep(1, 0)])]), "'joão':1");
      expect(vec([]), '');
    });

    test('tsquery: operand with prefix and weights', () {
      expect(query([val('a', weight: 8 | 4, prefix: true)]), "'a':*AB");
      expect(query([val('d', weight: 1)]), "'d':D");
      expect(query([val("o'k")]), "'o''k'");
      expect(query([]), '');
    });

    test('tsquery: binary operators read right operand first', () {
      // 'a' & 'b' is sent as AND, 'b', 'a'.
      expect(query([op(and), val('b'), val('a')]), "'a' & 'b'");
      expect(query([op(or), val('b'), val('a')]), "'a' | 'b'");
    });

    test('tsquery: parentheses follow operator priority', () {
      // ('a' | 'b') & 'c'  →  AND, 'c', OR, 'b', 'a'
      expect(query([op(and), val('c'), op(or), val('b'), val('a')]),
          "( 'a' | 'b' ) & 'c'");
      // 'a' | 'b' & 'c'  →  OR, AND('b','c'), 'a'
      expect(query([op(or), op(and), val('c'), val('b'), val('a')]),
          "'a' | 'b' & 'c'");
      // !( 'a' & 'b' )  →  NOT, AND, 'b', 'a'
      expect(query([op(not), op(and), val('b'), val('a')]), "!( 'a' & 'b' )");
      expect(query([op(not), val('a')]), "!'a'");
    });

    test('tsquery: phrase distance and phrase on the right of phrase', () {
      expect(query([phrase(1), val('b'), val('a')]), "'a' <-> 'b'");
      expect(query([phrase(2), val('b'), val('a')]), "'a' <2> 'b'");
      // 'a' <-> ( 'b' <-> 'c' ): the right PHRASE keeps its parentheses.
      expect(query([phrase(1), phrase(1), val('c'), val('b'), val('a')]),
          "'a' <-> ( 'b' <-> 'c' )");
      // ( 'a' <-> 'b' ) <-> 'c' prints without them.
      expect(query([phrase(1), val('c'), phrase(1), val('b'), val('a')]),
          "'a' <-> 'b' <-> 'c'");
    });

    test('malformed payloads throw FormatException', () {
      expect(
          () => decodeByOidBinary(
              Uint8List.fromList([...i32(1), 0x61]), PostgresOid.tsvector),
          throwsFormatException);
      expect(
          () => decodeByOidBinary(
              Uint8List.fromList([...i32(2), ...val('a')]), PostgresOid.tsquery),
          throwsA(anything));
      expect(
          () => decodeByOidBinary(
              Uint8List.fromList([...i32(1), 2, 9, ...val('a')]),
              PostgresOid.tsquery),
          throwsFormatException);
    });

    test('regconfig binary is the OID as a decimal String', () {
      expect(
          decodeByOidBinary(
              Uint8List.fromList([0, 0, 0x0E, 0xA4]), PostgresOid.regconfig),
          '3748');
    });

    test('text mode returns the server text for the three types', () {
      for (final (oid, text) in [
        (PostgresOid.tsvector, "'a':1A 'b'"),
        (PostgresOid.tsquery, "'jo':* & 'sil':*"),
        (PostgresOid.regconfig, 'simple'),
      ]) {
        expect(decodeByOid(Uint8List.fromList(utf8.encode(text)), oid), text);
      }
    });

    test('the three types report PostgresType.text', () {
      for (final oid in [
        PostgresOid.tsvector,
        PostgresOid.tsquery,
        PostgresOid.regconfig,
      ]) {
        expect(postgresTypeFromOid(oid), PostgresType.text);
      }
    });
  });

  group('decodeByOidBinary — postponed / unknown', () {
    // Changed 2026-09-10: binary `numeric` used to come back as raw
    // bytes, so the same column had a different Dart type depending on
    // the wire format. It now decodes, and the two formats converge.
    test('numeric zero decodes rather than returning raw bytes', () {
      // ndigits=0, weight=0, sign=POS, dscale=0 → the canonical zero.
      final raw = Uint8List.fromList(
          [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
      expect(decodeByOidBinary(raw, PostgresOid.numeric),
          PostgresNumeric.fromText('0'));
    });

    test('unknown OID returns raw bytes (zero-copy)', () {
      final raw = Uint8List.fromList([1, 2, 3]);
      expect(decodeByOidBinary(raw, 999999), raw);
    });
  });

  group('encode → decodeByOidBinary roundtrip (smoke for 12 types)', () {
    test('all values survive encode + decode unchanged', () {
      final cases = <(Param, int, Object)>[
        (Param.bool(true), PostgresOid.boolean, true),
        (Param.int2(-7), PostgresOid.int2, -7),
        (Param.int4(123456), PostgresOid.int4, 123456),
        (Param.int8(1 << 40), PostgresOid.int8, 1 << 40),
        (Param.float4(3.5), PostgresOid.float4, 3.5),
        (Param.float8(1.41421356), PostgresOid.float8, 1.41421356),
        (Param.text('hello'), PostgresOid.text, 'hello'),
        (Param.varchar('v'), PostgresOid.varchar, 'v'),
        (Param.bpchar('c'), PostgresOid.bpchar, 'c'),
        (Param.bytea(Uint8List.fromList([1, 2, 3])), PostgresOid.bytea,
            Uint8List.fromList([1, 2, 3])),
        // Naive on the way out — see the note in the timestamp group.
        (Param.timestamp(DateTime.utc(2026, 1, 2, 3, 4, 5)),
            PostgresOid.timestamp,
            DateTime(2026, 1, 2, 3, 4, 5)),
        (Param.timestamptz(DateTime.utc(2026, 1, 2, 3, 4, 5)),
            PostgresOid.timestamptz,
            DateTime.utc(2026, 1, 2, 3, 4, 5)),
      ];
      for (final (p, oid, expected) in cases) {
        final encoded = _enc(p);
        final decoded = decodeByOidBinary(encoded, oid);
        expect(decoded, expected,
            reason: 'roundtrip failed for ${p.runtimeType}');
      }
    });

    test('json / jsonb survive encode + decode', () {
      final j = decodeByOidBinary(
          _enc(Param.json('{"a":1,"b":[2,3]}')), PostgresOid.json) as Map;
      expect(j['a'], 1);
      expect(j['b'], [2, 3]);
      final jb = decodeByOidBinary(
          _enc(Param.jsonb('{"x":true}')), PostgresOid.jsonb) as Map;
      expect(jb['x'], true);
    });
  });
}
