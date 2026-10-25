/// Unit tests for [Param] encoders + marshalling (ABI MINOR 1).
///
/// Does NOT require a running Postgres — exercises only the Dart-side
/// `encode()` of each [Param] subclass plus the FFI marshalling layer
/// (`marshalParams` + `freeMarshalledParams`). Round-trip vs a real
/// Postgres is covered by `binary_decoder_test.dart`.
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:slingshot_postgres/src/decoder/postgres_oids.dart';
import 'package:slingshot_postgres/src/postgres/param.dart';
import 'package:test/test.dart';

// ─────────── helpers ───────────

Uint8List _encode(Param p) {
  final b = p.encode();
  expect(b, isNotNull, reason: '${p.runtimeType}.encode() returned null');
  return b!;
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('Param.bool', () {
    test('true → 0x01, oid=16, format=1', () {
      final p = Param.bool(true);
      expect(p.oid, PostgresOid.boolean);
      expect(p.format, 1);
      expect(_encode(p), Uint8List.fromList([0x01]));
    });

    test('false → 0x00', () {
      expect(_encode(Param.bool(false)), Uint8List.fromList([0x00]));
    });
  });

  group('Param.int2', () {
    test('42 → 00 2a big-endian', () {
      final p = Param.int2(42);
      expect(p.oid, PostgresOid.int2);
      expect(p.format, 1);
      expect(_hex(_encode(p)), '002a');
    });

    test('-1 → ff ff (two-complement)', () {
      expect(_hex(_encode(Param.int2(-1))), 'ffff');
    });

    test('range overflow throws', () {
      expect(() => Param.int2(0x8000).encode(), throwsArgumentError);
      expect(() => Param.int2(-0x8001).encode(), throwsArgumentError);
    });

    test('boundary values OK', () {
      expect(_hex(_encode(Param.int2(0x7FFF))), '7fff');
      expect(_hex(_encode(Param.int2(-0x8000))), '8000');
    });
  });

  group('Param.int4', () {
    test('42 → 00 00 00 2a', () {
      final p = Param.int4(42);
      expect(p.oid, PostgresOid.int4);
      expect(p.format, 1);
      expect(_hex(_encode(p)), '0000002a');
    });

    test('range overflow throws', () {
      expect(() => Param.int4(0x80000000).encode(), throwsArgumentError);
      expect(() => Param.int4(-0x80000001).encode(), throwsArgumentError);
    });
  });

  group('Param.int8', () {
    test('1 → 00..00 01 (8 bytes)', () {
      final p = Param.int8(1);
      expect(p.oid, PostgresOid.int8);
      expect(p.format, 1);
      expect(_hex(_encode(p)), '0000000000000001');
    });

    test('large value 2^33', () {
      expect(_hex(_encode(Param.int8(1 << 33))), '0000000200000000');
    });
  });

  group('Param.float4', () {
    test('1.0 → 3f 80 00 00 (IEEE 754)', () {
      final p = Param.float4(1.0);
      expect(p.oid, PostgresOid.float4);
      expect(p.format, 1);
      expect(_hex(_encode(p)), '3f800000');
    });
  });

  group('Param.float8', () {
    test('1.0 → 3f f0 00 00 00 00 00 00 (IEEE 754)', () {
      final p = Param.float8(1.0);
      expect(p.oid, PostgresOid.float8);
      expect(p.format, 1);
      expect(_hex(_encode(p)), '3ff0000000000000');
    });
  });

  group('Param.numeric', () {
    test('text format, oid=1700, UTF-8 bytes', () {
      final p = Param.numeric('123.45');
      expect(p.oid, PostgresOid.numeric);
      expect(p.format, 0);
      expect(_encode(p), Uint8List.fromList('123.45'.codeUnits));
    });
  });

  group('Param.text / varchar / bpchar / json (text family)', () {
    test('text encodes UTF-8 multi-byte', () {
      // 'café' → 63 61 66 c3 a9
      final p = Param.text('café');
      expect(p.oid, PostgresOid.text);
      expect(p.format, 0);
      expect(_hex(_encode(p)), '636166c3a9');
    });

    test('varchar oid=1043, text format', () {
      expect(Param.varchar('x').oid, PostgresOid.varchar);
      expect(Param.varchar('x').format, 0);
    });

    test('bpchar oid=1042, text format', () {
      expect(Param.bpchar('x').oid, PostgresOid.bpchar);
      expect(Param.bpchar('x').format, 0);
    });

    test('json oid=114, text format', () {
      expect(Param.json('{"k":1}').oid, PostgresOid.json);
      expect(Param.json('{"k":1}').format, 0);
      expect(_encode(Param.json('{"k":1}')),
          Uint8List.fromList('{"k":1}'.codeUnits));
    });
  });

  group('Param.jsonb', () {
    test('binary, version 0x01 prefix + UTF-8 JSON', () {
      final p = Param.jsonb('{"k":1}');
      expect(p.oid, PostgresOid.jsonb);
      expect(p.format, 1);
      final bytes = _encode(p);
      expect(bytes[0], 0x01, reason: 'jsonb version byte must be 0x01');
      expect(
          Uint8List.fromList(bytes.sublist(1)),
          Uint8List.fromList('{"k":1}'.codeUnits));
    });
  });

  group('Param.bytea', () {
    test('raw bytes pass-through', () {
      final raw = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      final p = Param.bytea(raw);
      expect(p.oid, PostgresOid.bytea);
      expect(p.format, 1);
      expect(_encode(p), raw);
    });
  });

  group('Param.timestamp / timestamptz', () {
    test('timestamp: postgres epoch (2000-01-01 UTC) → all zeros', () {
      final pgEpoch = DateTime.utc(2000, 1, 1, 0, 0, 0, 0, 0);
      final p = Param.timestamp(pgEpoch);
      expect(p.oid, PostgresOid.timestamp);
      expect(p.format, 1);
      expect(_hex(_encode(p)), '0000000000000000');
    });

    test('timestamptz: 1 second past pg epoch → 1_000_000 µs BE', () {
      final ts = DateTime.utc(2000, 1, 1, 0, 0, 1);
      final bytes = _encode(Param.timestamptz(ts));
      final v = ByteData.sublistView(bytes).getInt64(0, Endian.big);
      expect(v, 1000000);
    });

    test('timestamptz: pre-epoch (1999-12-31 23:59:59 UTC) → -1_000_000 µs', () {
      final ts = DateTime.utc(1999, 12, 31, 23, 59, 59);
      final bytes = _encode(Param.timestamptz(ts));
      final v = ByteData.sublistView(bytes).getInt64(0, Endian.big);
      expect(v, -1000000);
    });

    test('timestamptz converts local to UTC before encoding', () {
      // Pick a fixed UTC instant; whatever local offset Dart reports,
      // toUtc() must normalise it back.
      final utcInstant = DateTime.utc(2026, 5, 23, 12, 0, 0);
      final localCopy = utcInstant.toLocal();
      final bytesA = _encode(Param.timestamptz(utcInstant));
      final bytesB = _encode(Param.timestamptz(localCopy));
      expect(bytesA, bytesB,
          reason: 'same instant must encode identically regardless of zone');
    });
  });

  group('Param.nullValue', () {
    test('encode() returns null; oid + format preserved', () {
      final p = Param.nullValue(PostgresOid.text);
      expect(p.oid, PostgresOid.text);
      expect(p.encode(), isNull);
    });
  });

  group('marshalParams', () {
    test('empty list → all-nullptr sentinel', () {
      final m = marshalParams(const []);
      expect(m.count, 0);
      expect(m.types, ffi.nullptr);
      expect(m.values, ffi.nullptr);
      expect(m.lengths, ffi.nullptr);
      expect(m.formats, ffi.nullptr);
      freeMarshalledParams(m); // must be safe
    });

    test('single int4=42 + NUL terminator for text param', () {
      final params = <Param>[
        Param.int4(42),
        Param.text('hi'),
      ];
      final m = marshalParams(params);
      try {
        expect(m.count, 2);
        expect(m.types[0], PostgresOid.int4);
        expect(m.types[1], PostgresOid.text);
        expect(m.formats[0], 1);
        expect(m.formats[1], 0);

        // int4=42 — 4 bytes, BE 0x0000002A
        expect(m.lengths[0], 4);
        final intBuf = m.values[0].asTypedList(4);
        expect(_hex(Uint8List.fromList(intBuf)), '0000002a');

        // text='hi' — length reflects payload (2), buffer has NUL at [2]
        expect(m.lengths[1], 2);
        // Read 3 bytes to see the NUL terminator.
        final textBuf = m.values[1].asTypedList(3);
        expect(textBuf[0], 0x68); // 'h'
        expect(textBuf[1], 0x69); // 'i'
        expect(textBuf[2], 0x00); // NUL terminator
      } finally {
        freeMarshalledParams(m);
      }
    });

    test('NULL value → nullptr in values[], length=0, oid preserved', () {
      final params = <Param>[
        Param.nullValue(PostgresOid.text),
        Param.int4(7),
      ];
      final m = marshalParams(params);
      try {
        expect(m.count, 2);
        expect(m.types[0], PostgresOid.text);
        expect(m.values[0], ffi.nullptr);
        expect(m.lengths[0], 0);
        expect(m.types[1], PostgresOid.int4);
        expect(m.lengths[1], 4);
      } finally {
        freeMarshalledParams(m);
      }
    });

    test('all 14 canonical types marshal without throwing', () {
      final params = <Param>[
        Param.bool(true),
        Param.int2(1),
        Param.int4(2),
        Param.int8(3),
        Param.float4(1.5),
        Param.float8(2.5),
        Param.numeric('3.14'),
        Param.text('t'),
        Param.varchar('v'),
        Param.bpchar('c'),
        Param.json('{}'),
        Param.jsonb('{}'),
        Param.bytea(Uint8List.fromList([0xFF])),
        Param.timestamp(DateTime.utc(2026, 1, 1)),
        Param.timestamptz(DateTime.utc(2026, 1, 1)),
        Param.nullValue(PostgresOid.text),
      ];
      final m = marshalParams(params);
      try {
        expect(m.count, 16);
        for (var i = 0; i < params.length; i++) {
          expect(m.types[i], params[i].oid, reason: 'type[$i]');
          expect(m.formats[i], params[i].format, reason: 'format[$i]');
        }
      } finally {
        freeMarshalledParams(m);
      }
    });
  });
}
