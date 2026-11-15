/// Parameter bindings for the Postgres Extended Query Protocol.
///
/// Each [Param] subclass carries:
///   - a Postgres [oid] (from `pg_type.dat`),
///   - a wire [format] (`0` = text, `1` = binary),
///   - the bytes for the value via [encode] (`null` means SQL `NULL`).
///
/// Used by `pool_submit_query_params` (ABI MINOR 1, 2026-05-23). The
/// marshalling helpers [marshalParams] / [freeMarshalledParams] are
/// internal to the package.
///
/// Why a sealed class: the closed set of canonical Postgres types
/// gives compile-time exhaustiveness for marshalling and decoding,
/// and signals to consumers that adding ad-hoc types isn't supported
/// (custom Postgres types should be sent as `text`/`bytea` and
/// converted at the SQL layer).
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../decoder/postgres_oids.dart';

/// SQL statement bundled with its bound parameters.
///
/// Used as the return shape of [PostgresRepository]'s CRUD-template
/// methods (e.g. `selectByIdSql` returns `('SELECT … WHERE id = $1',
/// [Param.int4(id)])`). The base class destructures the record and
/// passes both halves to `PostgresQueryExecutorContract.execute`.
typedef SqlStmt = (String sql, List<Param> params);

/// A bound parameter for the Postgres Extended Query Protocol.
///
/// Create instances via the named factories:
///
/// ```dart
/// final params = <Param>[
///   Param.int4(42),
///   Param.text('hello'),
///   Param.nullValue(PostgresOid.text),
/// ];
/// ```
///
/// All values are sent in **binary format** when a portable binary
/// encoding exists (integers, floats, bool, timestamps, bytea,
/// jsonb). Otherwise text format is used (numeric, text, varchar,
/// bpchar, json) — for these, the server parses identically and the
/// extra round-trip latency is negligible.
sealed class Param {
  const Param();

  /// Postgres type OID from `pg_type.dat`.
  /// See [PostgresOid] for the catalogue of canonical OIDs.
  int get oid;

  /// Wire format: `0` = text (NUL-terminated UTF-8 on the wire),
  /// `1` = binary (raw bytes of length [encode]`!.lengthInBytes`).
  int get format;

  /// Bytes for this value. `null` means SQL `NULL`. For text format
  /// the returned bytes MUST be valid UTF-8; the marshalling layer
  /// appends a trailing NUL byte (libpq requires it for text params).
  Uint8List? encode();

  // ── Canonical factories (16 + nullValue) ──

  /// `bool` (OID 16, binary 1 byte: `0x00` / `0x01`).
  const factory Param.bool(bool value) = _ParamBool;

  /// `int2` / `smallint` (OID 21, binary 2 bytes big-endian).
  /// Range: −32 768 … 32 767. Throws [ArgumentError] otherwise.
  const factory Param.int2(int value) = _ParamInt2;

  /// `int4` / `integer` (OID 23, binary 4 bytes big-endian).
  /// Range: −2 147 483 648 … 2 147 483 647. Throws [ArgumentError] otherwise.
  const factory Param.int4(int value) = _ParamInt4;

  /// `int8` / `bigint` (OID 20, binary 8 bytes big-endian).
  const factory Param.int8(int value) = _ParamInt8;

  /// `float4` / `real` (OID 700, binary 4 bytes IEEE 754 big-endian).
  const factory Param.float4(double value) = _ParamFloat4;

  /// `float8` / `double precision` (OID 701, binary 8 bytes IEEE 754 BE).
  const factory Param.float8(double value) = _ParamFloat8;

  /// `numeric` / `decimal` (OID 1700, **text format**).
  ///
  /// Binary `numeric` is non-trivial (variable-width digit groups +
  /// scale + sign — see Postgres `numeric.c`). Sending as text lets
  /// the server's parser do the conversion; precision is preserved
  /// because no float intermediate exists.
  const factory Param.numeric(String value) = _ParamNumeric;

  /// `text` (OID 25, text format UTF-8).
  const factory Param.text(String value) = _ParamText;

  /// `varchar` (OID 1043, text format UTF-8).
  const factory Param.varchar(String value) = _ParamVarchar;

  /// `bpchar` (blank-padded `char(N)`, OID 1042, text format UTF-8).
  const factory Param.bpchar(String value) = _ParamBpchar;

  /// `json` (OID 114, text format UTF-8).
  const factory Param.json(String value) = _ParamJson;

  /// `jsonb` (OID 3802, binary: 1-byte version `0x01` + UTF-8 JSON).
  const factory Param.jsonb(String value) = _ParamJsonb;

  /// `bytea` (OID 17, binary: raw bytes).
  const factory Param.bytea(Uint8List value) = _ParamBytea;

  /// `timestamp` without time zone (OID 1114, binary int64 BE,
  /// microseconds since Postgres epoch `2000-01-01 00:00:00`).
  ///
  /// The [value]'s `DateTime` is interpreted as wall-clock; if the
  /// `DateTime` is local time, microseconds are taken verbatim (the
  /// server has no TZ context for this type).
  const factory Param.timestamp(DateTime value) = _ParamTimestamp;

  /// `timestamptz` with time zone (OID 1184, binary int64 BE,
  /// microseconds since Postgres epoch `2000-01-01 00:00:00 UTC`).
  ///
  /// The [value] is converted to UTC before encoding.
  const factory Param.timestamptz(DateTime value) = _ParamTimestamptz;

  /// `date` (OID 1082, **binary**: signed int32 BE of days since
  /// 2000-01-01).
  ///
  /// Only the calendar date of [value] is sent; any time component is
  /// dropped, because `date` has none. The day is taken from the
  /// [value]'s own fields, so a local `DateTime` sends the date the
  /// caller sees rather than the one it would have in UTC.
  const factory Param.date(DateTime value) = _ParamDate;

  /// `uuid` (OID 2950, **binary**: the 16 raw bytes in RFC 4122 order).
  ///
  /// Accepts the canonical `8-4-4-4-12` form or the same 32 hex digits
  /// without hyphens, in either case. Anything else throws
  /// [ArgumentError] at [encode] time — a malformed uuid has to fail in
  /// Dart, not as a server-side parse error three layers away.
  ///
  /// Binary rather than text because `uuid_send` is a verbatim
  /// `pq_sendbytes` of 16 bytes: there is no parsing to hand the server.
  const factory Param.uuid(String value) = _ParamUuid;

  /// SQL `NULL` for a given type [oid]. The OID is required so the
  /// server can infer the right type at parse time (e.g. for
  /// `WHERE col = $1` predicates).
  const factory Param.nullValue(int oid) = _ParamNull;

  // ── One-dimensional arrays (2026-11-15) ──
  //
  // Binary (`array_send` layout), one dimension, lower bound 1. Elements
  // may be null. An empty list is the empty array (zero dimensions), so
  // `col = ANY($1)` matches nothing. Each element goes through the scalar
  // encoder of its type, with the same validation: a malformed uuid or an
  // out-of-range int2/int4 throws [ArgumentError] at [encode] time.

  /// `bool[]` (OID 1000).
  const factory Param.boolArray(List<bool?> values) = _ParamBoolArray;

  /// `int2[]` (OID 1005).
  const factory Param.int2Array(List<int?> values) = _ParamInt2Array;

  /// `int4[]` (OID 1007).
  const factory Param.int4Array(List<int?> values) = _ParamInt4Array;

  /// `int8[]` (OID 1016).
  const factory Param.int8Array(List<int?> values) = _ParamInt8Array;

  /// `float8[]` (OID 1022).
  const factory Param.float8Array(List<double?> values) = _ParamFloat8Array;

  /// `text[]` (OID 1009). Commas, quotes and braces need no escaping: the
  /// binary form carries each element's length. A NUL character, which a
  /// PostgreSQL text value cannot hold, throws [ArgumentError].
  const factory Param.textArray(List<String?> values) = _ParamTextArray;

  /// `uuid[]` (OID 2951). Elements in the forms [Param.uuid] accepts.
  const factory Param.uuidArray(List<String?> values) = _ParamUuidArray;

  /// An array of [length] NULLs with no element type (`{}` when [length]
  /// is 0), sent as text with OID 0 so the server types it from where it
  /// is used, as [Param.nullValue] with OID 0 does. For callers that infer
  /// the type from the values and have none to infer from; with a known
  /// type, prefer the typed factories.
  const factory Param.untypedArrayOfNulls(int length) = _ParamUntypedNullArray;
}

// ─────────────── Subclasses ───────────────

/// Postgres epoch (2000-01-01T00:00:00Z) expressed as microseconds
/// since the Unix epoch. Used to translate `DateTime.microsecondsSinceEpoch`
/// (Unix epoch) into the on-wire Postgres timestamp representation.
const int _postgresEpochUnixMicros = 946684800 * 1000000;

final class _ParamBool extends Param {
  final bool value;
  const _ParamBool(this.value);
  @override
  int get oid => PostgresOid.boolean;
  @override
  int get format => 1;
  @override
  Uint8List encode() => Uint8List(1)..[0] = value ? 0x01 : 0x00;
}

final class _ParamInt2 extends Param {
  final int value;
  const _ParamInt2(this.value);
  @override
  int get oid => PostgresOid.int2;
  @override
  int get format => 1;
  @override
  Uint8List encode() {
    if (value < -0x8000 || value > 0x7FFF) {
      throw ArgumentError.value(value, 'value', 'int2 out of range');
    }
    final b = ByteData(2)..setInt16(0, value, Endian.big);
    return b.buffer.asUint8List();
  }
}

final class _ParamInt4 extends Param {
  final int value;
  const _ParamInt4(this.value);
  @override
  int get oid => PostgresOid.int4;
  @override
  int get format => 1;
  @override
  Uint8List encode() {
    if (value < -0x80000000 || value > 0x7FFFFFFF) {
      throw ArgumentError.value(value, 'value', 'int4 out of range');
    }
    final b = ByteData(4)..setInt32(0, value, Endian.big);
    return b.buffer.asUint8List();
  }
}

final class _ParamInt8 extends Param {
  final int value;
  const _ParamInt8(this.value);
  @override
  int get oid => PostgresOid.int8;
  @override
  int get format => 1;
  @override
  Uint8List encode() {
    final b = ByteData(8)..setInt64(0, value, Endian.big);
    return b.buffer.asUint8List();
  }
}

final class _ParamFloat4 extends Param {
  final double value;
  const _ParamFloat4(this.value);
  @override
  int get oid => PostgresOid.float4;
  @override
  int get format => 1;
  @override
  Uint8List encode() {
    final b = ByteData(4)..setFloat32(0, value, Endian.big);
    return b.buffer.asUint8List();
  }
}

final class _ParamFloat8 extends Param {
  final double value;
  const _ParamFloat8(this.value);
  @override
  int get oid => PostgresOid.float8;
  @override
  int get format => 1;
  @override
  Uint8List encode() {
    final b = ByteData(8)..setFloat64(0, value, Endian.big);
    return b.buffer.asUint8List();
  }
}

final class _ParamNumeric extends Param {
  final String value;
  const _ParamNumeric(this.value);
  @override
  int get oid => PostgresOid.numeric;
  @override
  int get format => 0;
  @override
  Uint8List encode() => Uint8List.fromList(value.codeUnits);
}

abstract final class _ParamTextLike extends Param {
  final String value;
  const _ParamTextLike(this.value);
  @override
  int get format => 0;
  @override
  Uint8List encode() {
    final bytes = <int>[];
    for (final cu in value.runes) {
      if (cu < 0x80) {
        bytes.add(cu);
      } else if (cu < 0x800) {
        bytes.add(0xC0 | (cu >> 6));
        bytes.add(0x80 | (cu & 0x3F));
      } else if (cu < 0x10000) {
        bytes.add(0xE0 | (cu >> 12));
        bytes.add(0x80 | ((cu >> 6) & 0x3F));
        bytes.add(0x80 | (cu & 0x3F));
      } else {
        bytes.add(0xF0 | (cu >> 18));
        bytes.add(0x80 | ((cu >> 12) & 0x3F));
        bytes.add(0x80 | ((cu >> 6) & 0x3F));
        bytes.add(0x80 | (cu & 0x3F));
      }
    }
    return Uint8List.fromList(bytes);
  }
}

final class _ParamText extends _ParamTextLike {
  const _ParamText(super.value);
  @override
  int get oid => PostgresOid.text;
}

final class _ParamVarchar extends _ParamTextLike {
  const _ParamVarchar(super.value);
  @override
  int get oid => PostgresOid.varchar;
}

final class _ParamBpchar extends _ParamTextLike {
  const _ParamBpchar(super.value);
  @override
  int get oid => PostgresOid.bpchar;
}

final class _ParamJson extends _ParamTextLike {
  const _ParamJson(super.value);
  @override
  int get oid => PostgresOid.json;
}

final class _ParamJsonb extends Param {
  final String value;
  const _ParamJsonb(this.value);
  @override
  int get oid => PostgresOid.jsonb;
  @override
  int get format => 1;
  @override
  Uint8List encode() {
    // 1-byte jsonb version (always 0x01 in current Postgres) + UTF-8 JSON.
    final textBytes = _ParamJson(value).encode();
    final out = Uint8List(1 + textBytes.length);
    out[0] = 0x01;
    out.setRange(1, out.length, textBytes);
    return out;
  }
}

final class _ParamDate extends Param {
  final DateTime value;
  const _ParamDate(this.value);
  @override
  int get oid => PostgresOid.date;
  @override
  int get format => 1;
  @override
  Uint8List encode() {
    final days = DateTime.utc(value.year, value.month, value.day)
        .difference(DateTime.utc(2000, 1, 1))
        .inDays;
    if (days == 0x7FFFFFFF || days == -0x80000000) {
      throw ArgumentError.value(value, 'value', 'date out of range');
    }
    final b = ByteData(4)..setInt32(0, days, Endian.big);
    return b.buffer.asUint8List();
  }
}

final class _ParamUuid extends Param {
  final String value;
  const _ParamUuid(this.value);
  @override
  int get oid => PostgresOid.uuid;
  @override
  int get format => 1;
  @override
  Uint8List encode() {
    final src = value.length == 36 ? _stripUuidHyphens(value) : value;
    if (src.length != 32) {
      throw ArgumentError.value(value, 'value', 'malformed uuid');
    }
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = (_hexNibble(value, src.codeUnitAt(2 * i)) << 4) |
          _hexNibble(value, src.codeUnitAt(2 * i + 1));
    }
    return out;
  }
}

/// Removes the four hyphens of the canonical form, rejecting any string
/// that has 36 characters but hyphens somewhere else.
String _stripUuidHyphens(String v) {
  if (v.codeUnitAt(8) != 0x2D ||
      v.codeUnitAt(13) != 0x2D ||
      v.codeUnitAt(18) != 0x2D ||
      v.codeUnitAt(23) != 0x2D) {
    throw ArgumentError.value(v, 'value', 'malformed uuid');
  }
  return v.replaceAll('-', '');
}

int _hexNibble(String original, int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  throw ArgumentError.value(original, 'value', 'malformed uuid');
}

final class _ParamBytea extends Param {
  final Uint8List value;
  const _ParamBytea(this.value);
  @override
  int get oid => PostgresOid.bytea;
  @override
  int get format => 1;
  @override
  Uint8List encode() => value;
}

final class _ParamTimestamp extends Param {
  final DateTime value;
  const _ParamTimestamp(this.value);
  @override
  int get oid => PostgresOid.timestamp;
  @override
  int get format => 1;
  @override
  Uint8List encode() {
    final pgMicros = value.microsecondsSinceEpoch - _postgresEpochUnixMicros;
    final b = ByteData(8)..setInt64(0, pgMicros, Endian.big);
    return b.buffer.asUint8List();
  }
}

final class _ParamTimestamptz extends Param {
  final DateTime value;
  const _ParamTimestamptz(this.value);
  @override
  int get oid => PostgresOid.timestamptz;
  @override
  int get format => 1;
  @override
  Uint8List encode() {
    final pgMicros =
        value.toUtc().microsecondsSinceEpoch - _postgresEpochUnixMicros;
    final b = ByteData(8)..setInt64(0, pgMicros, Endian.big);
    return b.buffer.asUint8List();
  }
}

final class _ParamNull extends Param {
  final int _oid;
  const _ParamNull(this._oid);
  @override
  int get oid => _oid;
  @override
  int get format => 0;
  @override
  Uint8List? encode() => null;
}

// ─────────────── Arrays ───────────────

Uint8List _int32Be(int v) =>
    (ByteData(4)..setInt32(0, v, Endian.big)).buffer.asUint8List();

abstract final class _ParamArray<T extends Object> extends Param {
  final List<T?> values;
  const _ParamArray(this.values);

  int get elementOid;

  /// Binary bytes of one non-null element.
  Uint8List encodeElement(T value);

  @override
  int get format => 1;

  @override
  Uint8List encode() {
    final elements = [
      for (final v in values) v == null ? null : encodeElement(v),
    ];
    final b = BytesBuilder(copy: false)
      ..add(_int32Be(values.isEmpty ? 0 : 1))
      ..add(_int32Be(elements.contains(null) ? 1 : 0))
      ..add(_int32Be(elementOid));
    if (values.isNotEmpty) {
      b
        ..add(_int32Be(values.length))
        ..add(_int32Be(1));
    }
    for (final e in elements) {
      if (e == null) {
        b.add(_int32Be(-1));
      } else {
        b
          ..add(_int32Be(e.length))
          ..add(e);
      }
    }
    return b.takeBytes();
  }
}

final class _ParamBoolArray extends _ParamArray<bool> {
  const _ParamBoolArray(super.values);
  @override
  int get oid => PostgresOid.boolArray;
  @override
  int get elementOid => PostgresOid.boolean;
  @override
  Uint8List encodeElement(bool value) => _ParamBool(value).encode();
}

final class _ParamInt2Array extends _ParamArray<int> {
  const _ParamInt2Array(super.values);
  @override
  int get oid => PostgresOid.int2Array;
  @override
  int get elementOid => PostgresOid.int2;
  @override
  Uint8List encodeElement(int value) => _ParamInt2(value).encode();
}

final class _ParamInt4Array extends _ParamArray<int> {
  const _ParamInt4Array(super.values);
  @override
  int get oid => PostgresOid.int4Array;
  @override
  int get elementOid => PostgresOid.int4;
  @override
  Uint8List encodeElement(int value) => _ParamInt4(value).encode();
}

final class _ParamInt8Array extends _ParamArray<int> {
  const _ParamInt8Array(super.values);
  @override
  int get oid => PostgresOid.int8Array;
  @override
  int get elementOid => PostgresOid.int8;
  @override
  Uint8List encodeElement(int value) => _ParamInt8(value).encode();
}

final class _ParamFloat8Array extends _ParamArray<double> {
  const _ParamFloat8Array(super.values);
  @override
  int get oid => PostgresOid.float8Array;
  @override
  int get elementOid => PostgresOid.float8;
  @override
  Uint8List encodeElement(double value) => _ParamFloat8(value).encode();
}

final class _ParamTextArray extends _ParamArray<String> {
  const _ParamTextArray(super.values);
  @override
  int get oid => PostgresOid.textArray;
  @override
  int get elementOid => PostgresOid.text;
  @override
  Uint8List encodeElement(String value) {
    if (value.contains('\u0000')) {
      throw ArgumentError.value(
          value, 'values', 'a text element cannot contain a NUL character');
    }
    // `text_send` is the raw UTF-8: the text-format bytes are the binary ones.
    return _ParamText(value).encode();
  }
}

final class _ParamUuidArray extends _ParamArray<String> {
  const _ParamUuidArray(super.values);
  @override
  int get oid => PostgresOid.uuidArray;
  @override
  int get elementOid => PostgresOid.uuid;
  @override
  Uint8List encodeElement(String value) => _ParamUuid(value).encode();
}

final class _ParamUntypedNullArray extends Param {
  final int length;
  const _ParamUntypedNullArray(this.length);
  @override
  int get oid => 0;
  @override
  int get format => 0;
  @override
  Uint8List encode() {
    if (length < 0) {
      throw ArgumentError.value(length, 'length', 'must not be negative');
    }
    return Uint8List.fromList(
        '{${List.filled(length, 'NULL').join(',')}}'.codeUnits);
  }
}

// ─────────────── Marshalling helpers (internal) ───────────────

/// Result of [marshalParams] — bundles the FFI arrays handed to
/// `pool_submit_query_params` along with the bookkeeping needed to
/// release them via [freeMarshalledParams].
@internal
final class MarshalledParams {
  final ffi.Pointer<ffi.Int32> types;
  final ffi.Pointer<ffi.Pointer<ffi.Uint8>> values;
  final ffi.Pointer<ffi.Int32> lengths;
  final ffi.Pointer<ffi.Int32> formats;
  final int count;

  /// Per-value buffers we allocated and now own. NULL entries
  /// (SQL `NULL`) are skipped — only non-null buffers appear here.
  final List<ffi.Pointer<ffi.Uint8>> _valueBuffers;

  MarshalledParams._(
    this.types,
    this.values,
    this.lengths,
    this.formats,
    this.count,
    this._valueBuffers,
  );
}

/// Allocates FFI arrays for the Extended Query Protocol from a list
/// of [Param]s. The caller MUST eventually pass the result to
/// [freeMarshalledParams], even on error paths.
///
/// Text parameters get a trailing NUL byte appended (libpq treats
/// text values as C strings). Binary parameters are copied verbatim.
/// `Param.nullValue` slots set the value pointer to `nullptr` and
/// length to 0 — libpq interprets a null value pointer as SQL `NULL`.
///
/// For `count == 0` the four FFI pointers are `nullptr` (libpq
/// accepts this for the zero-params case).
@internal
MarshalledParams marshalParams(List<Param> params) {
  final n = params.length;
  if (n == 0) {
    return MarshalledParams._(
      ffi.nullptr,
      ffi.nullptr,
      ffi.nullptr,
      ffi.nullptr,
      0,
      const <ffi.Pointer<ffi.Uint8>>[],
    );
  }

  final types = calloc<ffi.Int32>(n);
  final values = calloc<ffi.Pointer<ffi.Uint8>>(n);
  final lengths = calloc<ffi.Int32>(n);
  final formats = calloc<ffi.Int32>(n);
  final buffers = <ffi.Pointer<ffi.Uint8>>[];

  try {
    for (var i = 0; i < n; i++) {
      final p = params[i];
      types[i] = p.oid;
      formats[i] = p.format;

      final bytes = p.encode();
      if (bytes == null) {
        // SQL NULL — value pointer stays nullptr, length stays 0.
        values[i] = ffi.nullptr;
        lengths[i] = 0;
        continue;
      }

      // Text format: libpq calls strlen() on the value, so we MUST
      // append a NUL terminator. The length field is ignored for text.
      // Binary format: length is mandatory; no terminator needed.
      final isText = p.format == 0;
      final bufLen = isText ? bytes.length + 1 : bytes.length;
      final buf = malloc<ffi.Uint8>(bufLen);
      buf.asTypedList(bufLen).setRange(0, bytes.length, bytes);
      if (isText) {
        buf[bytes.length] = 0;
      }
      values[i] = buf;
      lengths[i] = bytes.length;
      buffers.add(buf);
    }
  } catch (_) {
    // Roll back on any allocation/encoding failure — never leak.
    for (final b in buffers) {
      malloc.free(b);
    }
    calloc.free(types);
    calloc.free(values);
    calloc.free(lengths);
    calloc.free(formats);
    rethrow;
  }

  return MarshalledParams._(types, values, lengths, formats, n, buffers);
}

/// Releases every buffer + array allocated by [marshalParams].
/// Safe on the zero-params sentinel returned by `marshalParams([])`.
@internal
void freeMarshalledParams(MarshalledParams m) {
  if (m.count == 0) return;
  for (final b in m._valueBuffers) {
    malloc.free(b);
  }
  calloc.free(m.types);
  calloc.free(m.values);
  calloc.free(m.lengths);
  calloc.free(m.formats);
}
