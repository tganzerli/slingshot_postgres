/// Decoders from raw libpq bytes to Dart values.
///
/// Internal — consumed by [PostgresResultRow]. Provides two parallel families:
///   - [decodeByOid] for **text** wire format (libpq `PQsendQuery` default).
///   - [decodeByOidBinary] for **binary** wire format (added in ABI MINOR 1,
///     2026-05-23, via `PQsendQueryParams(..., resultFormat=1)`).
///
/// Both paths normalise to the same Dart value types (bool / int /
/// double / String / DateTime / Map|List / Uint8List), so consumers
/// of [PostgresResultRow] don't observe a difference.
library;

import 'dart:convert' show utf8, jsonDecode;
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'postgres_numeric.dart';
import 'postgres_oids.dart';
import 'postgres_text_search.dart';
import 'postgres_type.dart';

/// Decoder for a single cell, reading straight from the zero-copy pointer
/// (`ptr` + `len`) returned by the native ABI. The pointer is guaranteed
/// non-null by the caller (SQL NULL is handled before the decoder runs).
///
/// The signature is deliberately driver-agnostic — it names no Postgres
/// type — so the same shape backs the MySQL mirror and is the candidate
/// for the v2 SQL-agnostic seam (see `postgres_decode_plan.dart`).
/// Resolved once per result shape by the codec plan, replacing the per-cell `switch`.
typedef CellDecoder = Object? Function(ffi.Pointer<ffi.Uint8> ptr, int len);

/// Postgres binary timestamp epoch (2000-01-01T00:00:00Z) expressed as
/// microseconds since the Unix epoch. Mirrors the encoder side in
/// `dart/lib/src/postgres/param.dart` so encode/decode round-trip.
const int _postgresEpochUnixMicros = 946684800 * 1000000;

/// Decodes [bytes] (text-format from libpq) into a Dart value according
/// to [oid].
///
/// Returns:
///   - `bool` for OID `boolean`
///   - `int` for OIDs int2/int4/int8
///   - `double` for OIDs float4/float8
///   - [PostgresNumeric] for numeric — exact; `getDouble` converts
///   - `String` for OIDs text/varchar/bpchar/name/"char" and the text
///     search types tsvector/tsquery/regconfig (the server's text form)
///   - `dynamic` (Map/List/etc) for json/jsonb (via [jsonDecode])
///   - `Uint8List` for bytea (decoded from `\x<hex>` text format) and
///     for unknown OIDs (returned as-is)
///   - `DateTime` for timestamp/timestamptz/date. `timestamptz` is UTC
///     (`isUtc: true`); `timestamp` and `date` are wall-clock without a
///     zone, so they come back naive (`isUtc: false`).
///   - `String` for uuid (canonical 8-4-4-4-12, lowercase)
Object decodeByOid(Uint8List bytes, int oid) {
  return switch (oid) {
    PostgresOid.boolean => bytes.isNotEmpty && bytes[0] == 0x74, // 't'
    PostgresOid.int2 ||
    PostgresOid.int4 ||
    PostgresOid.int8 =>
      int.parse(_asciiString(bytes)),
    PostgresOid.float4 ||
    PostgresOid.float8 =>
      double.parse(_asciiString(bytes)),
    // `numeric` is arbitrary-precision decimal; the text the server sent
    // is already exact, so it is kept rather than parsed into a double.
    PostgresOid.numeric => PostgresNumeric.fromText(_asciiString(bytes)),
    PostgresOid.text ||
    PostgresOid.varchar ||
    PostgresOid.bpchar ||
    PostgresOid.name ||
    PostgresOid.tsvector ||
    PostgresOid.tsquery ||
    PostgresOid.regconfig =>
      utf8.decode(bytes),
    // `"char"` text output is ASCII on PostgreSQL 15+: `charout` renders
    // bytes with the high bit set as `\ooo`. Older servers send the raw
    // byte, which comes back here as a Latin-1 character.
    PostgresOid.char => _asciiString(bytes),
    PostgresOid.json ||
    PostgresOid.jsonb =>
      jsonDecode(utf8.decode(bytes)) as Object,
    PostgresOid.bytea => _decodeByteaHex(bytes),
    PostgresOid.timestamp ||
    PostgresOid.timestamptz =>
      _parsePostgresTimestamp(_asciiString(bytes)),
    PostgresOid.date => _parsePostgresDate(_asciiString(bytes)),
    // Text-mode uuid already arrives canonical and lowercase, pure ASCII.
    PostgresOid.uuid => _asciiString(bytes),
    // Owned copy: [bytes] is a view into the PGresult and would outlive
    // `PostgresResultSet.release()` (Dart-C boundary audit, 2026-11-02).
    _ => Uint8List.fromList(bytes), // unknown OID → raw bytes, owned
  };
}

/// Fast path for ASCII-only payloads (numbers, booleans, timestamps in
/// text mode). Avoids the full UTF-8 decoder.
String _asciiString(Uint8List bytes) => String.fromCharCodes(bytes);

// ─────────────────────────────────────────────────────────────────────
// Codec plan — per-column decoder resolution + direct-from-pointer
// numeric parsing. See `postgres_decode_plan.dart`.
//
// `textDecoderForOid` / `binaryDecoderForOid` resolve the OID → decoder
// switch ONCE per result shape (the plan caches the returned closures),
// so the per-cell hot path no longer branches on the OID. Cold OIDs
// (json/bytea/timestamp/unknown) delegate to the existing
// [decodeByOid]/[decodeByOidBinary] families via `asTypedList`, keeping a
// single source of truth for decode semantics.
// ─────────────────────────────────────────────────────────────────────

/// Resolves the [CellDecoder] for a **text**-format column of type [oid].
/// Called once per result shape by the codec plan.
CellDecoder textDecoderForOid(int oid) => switch (oid) {
      PostgresOid.int2 ||
      PostgresOid.int4 ||
      PostgresOid.int8 =>
        _decodeIntTextPtr,
      PostgresOid.boolean => _decodeBoolTextPtr,
      PostgresOid.float4 || PostgresOid.float8 => _decodeDoubleTextPtr,
      PostgresOid.numeric => _decodeNumericTextPtr,
      PostgresOid.text ||
      PostgresOid.varchar ||
      PostgresOid.bpchar ||
      PostgresOid.name ||
      PostgresOid.tsvector ||
      PostgresOid.tsquery ||
      PostgresOid.regconfig =>
        _decodeUtf8Ptr,
      // Cold OIDs (json/jsonb/bytea/timestamp/unknown): delegate to the
      // canonical text family — same semantics, resolved once per plan.
      _ => (ptr, len) => decodeByOid(ptr.asTypedList(len), oid),
    };

/// Resolves the [CellDecoder] for a **binary**-format column of type
/// [oid]. Binary is not the hot path (TPC-C runs text mode because of
/// `numeric`), so every binary decoder delegates to the canonical
/// [decodeByOidBinary] — the win here is resolving the switch once, not a
/// specialised parser.
CellDecoder binaryDecoderForOid(int oid) =>
    (ptr, len) => decodeByOidBinary(ptr.asTypedList(len), oid);

/// Parses a text-mode integer (`int2`/`int4`/`int8`) straight from
/// the native pointer — no `asTypedList` wrapper, no intermediate
/// `String`. Reads bytes with `ptr[i]` (a memory load, not an FFI call).
///
/// On any byte outside `[-0-9]` (should never happen for these OIDs in
/// text mode) it falls back to the String path, so semantics can only
/// match [decodeByOid], never diverge.
///
/// int64 edge cases are correct by two's-complement wraparound: for
/// `int8` min (`-9223372036854775808`) the positive accumulation wraps to
/// int64 min and the final negation is a no-op on int64 min, yielding the
/// right value. Postgres never emits an int8 outside `[-2^63, 2^63-1]`.
Object _decodeIntTextPtr(ffi.Pointer<ffi.Uint8> ptr, int len) {
  if (len == 0) return _intFallback(ptr, len);
  var i = 0;
  var neg = false;
  final first = ptr[0];
  if (first == 0x2D /* '-' */) {
    neg = true;
    i = 1;
  } else if (first == 0x2B /* '+' */) {
    i = 1;
  }
  if (i == len) return _intFallback(ptr, len); // lone sign
  var v = 0;
  for (; i < len; i++) {
    final d = ptr[i] - 0x30;
    if (d < 0 || d > 9) return _intFallback(ptr, len);
    v = v * 10 + d;
  }
  return neg ? -v : v;
}

Object _intFallback(ffi.Pointer<ffi.Uint8> ptr, int len) =>
    int.parse(String.fromCharCodes(ptr.asTypedList(len)));

/// Parses a text-mode boolean (`'t'`/`'f'`) from the pointer. Mirrors
/// the `bytes[0] == 0x74` check in [decodeByOid].
Object _decodeBoolTextPtr(ffi.Pointer<ffi.Uint8> ptr, int len) =>
    len > 0 && ptr[0] == 0x74; // 't'

/// Text-mode float: keeps the `double.parse` path (v1). A manual float
/// parser has a high edge-case risk and TPC-C is int-dominated; left as a
/// future extension if the microbench points at it.
Object _decodeDoubleTextPtr(ffi.Pointer<ffi.Uint8> ptr, int len) =>
    double.parse(String.fromCharCodes(ptr.asTypedList(len)));

/// Text-mode `numeric`: retains the server's decimal text. Costs the same
/// as the `double.parse` it replaced — one `String` off the same bytes —
/// and the `BigInt` is only built if the consumer asks for exactness.
Object _decodeNumericTextPtr(ffi.Pointer<ffi.Uint8> ptr, int len) =>
    PostgresNumeric.fromText(String.fromCharCodes(ptr.asTypedList(len)));

/// Text-mode UTF-8 string (text/varchar/bpchar/name, and the text search
/// types, whose text output is already the final form). The zero-copy view is
/// the cheapest way to feed the UTF-8 decoder, which must allocate the
/// resulting `String` regardless.
Object _decodeUtf8Ptr(ffi.Pointer<ffi.Uint8> ptr, int len) =>
    utf8.decode(ptr.asTypedList(len));

/// Postgres text-mode `bytea` uses the `\x<hex>` prefix (since 9.0).
Uint8List _decodeByteaHex(Uint8List bytes) {
  if (bytes.length < 2 ||
      bytes[0] != 0x5C /* \ */ ||
      bytes[1] != 0x78 /* x */) {
    // Older escape format (\nnn octal) — not decoded here; returned as-is,
    // but owned: [bytes] is a view into the PGresult.
    return Uint8List.fromList(bytes);
  }
  final hex = bytes.sublist(2);
  if (hex.length.isOdd) {
    throw FormatException('bytea hex has odd length');
  }
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = (_hexNibble(hex[2 * i]) << 4) | _hexNibble(hex[2 * i + 1]);
  }
  return result;
}

int _hexNibble(int charCode) {
  if (charCode >= 0x30 && charCode <= 0x39) return charCode - 0x30;
  if (charCode >= 0x61 && charCode <= 0x66) return charCode - 0x61 + 10;
  if (charCode >= 0x41 && charCode <= 0x46) return charCode - 0x41 + 10;
  throw FormatException('invalid hex char: $charCode');
}

/// Parses Postgres text-mode timestamp format.
///
/// Expected formats:
///   - `timestamp`:    `2026-05-17 13:45:00[.fffffff]`
///   - `timestamptz`:  `2026-05-17 13:45:00[.fff]+00`
///
/// Converts to ISO-8601-ish (replace space with `T`) then `DateTime.parse`.
DateTime _parsePostgresTimestamp(String s) {
  final iso = s.replaceFirst(' ', 'T');
  return DateTime.parse(iso);
}

/// Decoded type information (for diagnostic / [PostgresResultRow.typeOf]).
PostgresType decodedTypeForOid(int oid) => postgresTypeFromOid(oid);

/// Decodes [bytes] (binary-format from libpq, `resultFormat = 1`) into a
/// Dart value according to [oid]. Mirror of [decodeByOid] for the
/// Extended Query Protocol with `resultFormat = 1`.
///
/// Returns the same Dart value types as [decodeByOid] (bool / int /
/// double / String / DateTime / Map|List / Uint8List), so [PostgresResultRow]
/// can mix-and-match without exposing the wire format to consumers.
///
/// Special cases:
///   - `numeric` (OID 1700): decoded to [PostgresNumeric] since
///     2026-09-10. Both wire formats converge on the same exact value —
///     before that the binary path returned raw [Uint8List], so the two
///     formats disagreed on the Dart type for the same column.
///   - `"char"` (OID 18): one raw byte, rendered the way `charout`
///     renders it in text mode (see [_charFromByte]).
///   - `tsvector` / `tsquery` (OIDs 3614 / 3615): the binary structure is
///     rendered the way `tsvectorout` / `tsqueryout` render it in text mode
///     (see `postgres_text_search.dart`), so both formats yield the same
///     `String`.
///   - `regconfig` (OID 3734): the binary form is only the configuration
///     OID, returned as a decimal `String` (text mode returns the name).
///   - Unknown OIDs: returned as raw [Uint8List] (zero-copy view).
Object decodeByOidBinary(Uint8List bytes, int oid) {
  return switch (oid) {
    PostgresOid.boolean => bytes.isNotEmpty && bytes[0] == 0x01,
    PostgresOid.int2 => ByteData.sublistView(bytes).getInt16(0, Endian.big),
    PostgresOid.int4 => ByteData.sublistView(bytes).getInt32(0, Endian.big),
    PostgresOid.int8 => ByteData.sublistView(bytes).getInt64(0, Endian.big),
    PostgresOid.float4 => ByteData.sublistView(bytes).getFloat32(0, Endian.big),
    PostgresOid.float8 => ByteData.sublistView(bytes).getFloat64(0, Endian.big),
    PostgresOid.text ||
    PostgresOid.varchar ||
    PostgresOid.bpchar ||
    PostgresOid.name =>
      utf8.decode(bytes),
    PostgresOid.char => _charFromByte(bytes),
    PostgresOid.tsvector => tsvectorFromBinary(bytes),
    PostgresOid.tsquery => tsqueryFromBinary(bytes),
    // The binary form is only the OID; the name needs a catalog lookup the
    // decoder cannot do. Decimal is also valid `regconfig` input.
    PostgresOid.regconfig =>
      ByteData.sublistView(bytes).getUint32(0, Endian.big).toString(),
    PostgresOid.json => jsonDecode(utf8.decode(bytes)) as Object,
    PostgresOid.jsonb =>
      // 1-byte version prefix (always 0x01 today) followed by UTF-8 JSON.
      jsonDecode(utf8.decode(bytes.sublist(1))) as Object,
    // Owned copy — the zero-copy view becomes a dangling pointer the
    // moment `PostgresResultSet.release()` runs, and callers cannot tell from
    // the API that holding the Uint8List past release is unsafe.
    // Matches the text-path semantics where `_decodeByteaHex` returns
    // a fresh Uint8List.
    PostgresOid.bytea => Uint8List.fromList(bytes),
    PostgresOid.timestamp => _binaryToDateTime(bytes, utc: false),
    PostgresOid.timestamptz => _binaryToDateTime(bytes, utc: true),
    PostgresOid.date => _binaryToDate(bytes),
    PostgresOid.uuid => _uuidFromBytes(bytes),
    PostgresOid.numeric => _binaryToNumeric(bytes),
    // Owned copy, same reason as the text path.
    _ => Uint8List.fromList(bytes), // unknown OID → raw bytes, owned
  };
}

/// Binary `"char"`: one raw byte (`charsend`). Rendered the way `charout`
/// does in text mode, so both wire formats yield the same `String`: 0x00
/// as `''`, ASCII as itself, a byte with the high bit set as `\ooo`.
String _charFromByte(Uint8List bytes) {
  if (bytes.isEmpty || bytes[0] == 0) return '';
  final b = bytes[0];
  if (b < 0x80) return String.fromCharCode(b);
  return '\\${b.toRadixString(8).padLeft(3, '0')}';
}

/// Binary `uuid`: 16 raw bytes in RFC 4122 order, rendered as the
/// canonical lowercase `8-4-4-4-12` form.
///
/// `uuid_send` writes `uuid->data` verbatim with no field-wise byte
/// swapping, so the hex runs in the order received — the Microsoft GUID
/// layout, which reverses the first three groups, does not apply.
String _uuidFromBytes(Uint8List bytes) {
  if (bytes.length != 16) {
    throw FormatException('uuid must be 16 bytes, got ${bytes.length}');
  }
  const hex = '0123456789abcdef';
  // 32 hex chars + 4 hyphens.
  final out = List<int>.filled(36, 0);
  var o = 0;
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) out[o++] = 0x2D; // '-'
    final b = bytes[i];
    out[o++] = hex.codeUnitAt(b >> 4);
    out[o++] = hex.codeUnitAt(b & 0x0F);
  }
  return String.fromCharCodes(out);
}

/// Binary timestamp / timestamptz: int64 BE µs since Postgres epoch.
///
/// [utc] carries the **intent of the OID**, not a property of the bytes:
/// the wire payload is identical for both types. `timestamptz` is UTC on
/// the wire and is UTC in fact; `timestamp` is a wall-clock reading with
/// no zone, and stamping it `isUtc: true` asserts something the server
/// never said.
///
/// Before 2026-09-10 this function stamped `isUtc: true` for both, so the
/// same `timestamp` column changed meaning when a consumer flipped
/// `binaryResult` — with no visible change in the Dart type. The text
/// path already made the distinction, by accident of the format: the
/// ISO-8601 offset suffix is present for `timestamptz` and absent for
/// `timestamp` (see [_parsePostgresTimestamp]). The binary path now
/// matches it.
DateTime _binaryToDateTime(Uint8List bytes, {required bool utc}) {
  final pgMicros = ByteData.sublistView(bytes).getInt64(0, Endian.big);
  final asUtc = DateTime.fromMicrosecondsSinceEpoch(
    pgMicros + _postgresEpochUnixMicros,
    isUtc: true,
  );
  if (utc) return asUtc;
  // Same wall-clock reading, no zone claim — mirrors what DateTime.parse
  // produces for a text `timestamp` with no offset suffix.
  return DateTime(asUtc.year, asUtc.month, asUtc.day, asUtc.hour, asUtc.minute,
      asUtc.second, asUtc.millisecond, asUtc.microsecond);
}

/// Binary `numeric`: four `int16` of header, then `ndigits` base-10000
/// digits, all big-endian.
///
/// ```
/// int16 ndigits | int16 weight | uint16 sign | uint16 dscale | int16 × ndigits
/// ```
///
/// `weight` is the power of 10000 of the **first** digit, so there are
/// `weight + 1` digit groups before the decimal point; it is signed, and
/// negative means the number starts after the point. `dscale` is the
/// declared count of *decimal* digits after the point, which is display
/// information and can call for more (or fewer) digits than `ndigits`
/// carries — the missing ones are zeros.
///
/// The `sign` field is not only a sign: `NaN`, `Infinity` and
/// `-Infinity` travel there, with `ndigits = 0`.
///
/// The reconstructed text is the same one the server's text mode would
/// have produced, so the two formats converge on an identical
/// [PostgresNumeric].
PostgresNumeric _binaryToNumeric(Uint8List bytes) {
  if (bytes.length < 8) {
    throw FormatException('numeric header needs 8 bytes, got ${bytes.length}');
  }
  final bd = ByteData.sublistView(bytes);
  final ndigits = bd.getInt16(0, Endian.big);
  final weight = bd.getInt16(2, Endian.big);
  final sign = bd.getUint16(4, Endian.big);
  final dscale = bd.getUint16(6, Endian.big);

  switch (sign) {
    case _numericNaN:
      return const PostgresNumeric.fromText('NaN');
    case _numericPosInf:
      return const PostgresNumeric.fromText('Infinity');
    case _numericNegInf:
      return const PostgresNumeric.fromText('-Infinity');
    case _numericPos:
    case _numericNeg:
      break;
    default:
      throw FormatException('invalid sign in binary numeric: 0x'
          '${sign.toRadixString(16)}');
  }

  if (ndigits < 0 || bytes.length < 8 + ndigits * 2) {
    throw FormatException('numeric claims $ndigits digits, payload is '
        '${bytes.length} bytes');
  }
  final digits = List<int>.generate(
      ndigits, (i) => bd.getInt16(8 + i * 2, Endian.big),
      growable: false);

  final sb = StringBuffer();
  if (sign == _numericNeg) sb.write('-');

  // Integer part: groups 0..weight. A negative weight means there is
  // none, and the value renders as `0.…`.
  if (weight < 0) {
    sb.write('0');
  } else {
    for (var d = 0; d <= weight; d++) {
      final group = d < ndigits ? digits[d] : 0;
      sb.write(d == 0 ? '$group' : group.toString().padLeft(4, '0'));
    }
  }

  // Fractional part: exactly `dscale` decimal digits, drawn from the
  // groups after `weight` and padded with zeros once they run out.
  if (dscale > 0) {
    final frac = StringBuffer();
    for (var d = weight + 1; frac.length < dscale; d++) {
      final group = (d >= 0 && d < ndigits) ? digits[d] : 0;
      frac.write(group.toString().padLeft(4, '0'));
    }
    sb
      ..write('.')
      ..write(frac.toString().substring(0, dscale));
  }

  return PostgresNumeric.fromText(sb.toString());
}

/// `sign` field values of the binary `numeric` header.
const int _numericPos = 0x0000;
const int _numericNeg = 0x4000;
const int _numericNaN = 0xC000;
const int _numericPosInf = 0xD000;
const int _numericNegInf = 0xF000;

/// Postgres text-mode `date`: `YYYY-MM-DD`, no time and no zone, so it
/// decodes to local midnight with `isUtc: false` — the same shape the
/// binary path produces.
DateTime _parsePostgresDate(String s) => DateTime.parse(s);

/// Binary `date`: **signed** int32 BE of days since 2000-01-01.
///
/// Signed matters: any date before 2000-01-01 arrives negative. The two
/// non-finite sentinels (`date 'infinity'` / `'-infinity'`) travel as
/// `INT32_MAX` / `INT32_MIN` and are not dates — decoding them as one
/// would silently produce a value ~5.8 million years away, so they throw.
DateTime _binaryToDate(Uint8List bytes) {
  final days = ByteData.sublistView(bytes).getInt32(0, Endian.big);
  if (days == 0x7FFFFFFF || days == -0x80000000) {
    throw FormatException(
        'date is infinity/-infinity, which has no DateTime equivalent');
  }
  final utcDay = DateTime.utc(2000, 1, 1).add(Duration(days: days));
  return DateTime(utcDay.year, utcDay.month, utcDay.day);
}
