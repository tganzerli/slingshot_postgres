/// Exact decimal value of a Postgres `numeric` column.
///
/// Public surface of the package — exported from
/// `slingshot_postgres.dart`.
library;

/// A Postgres `numeric` value, held exactly.
///
/// `numeric` is arbitrary-precision decimal, and Dart has no built-in
/// type for it. Decoding it into `double` — which this driver did until
/// 2026-09-10 — loses digits silently on money-sized values with more
/// than ~15 significant decimal digits.
///
/// **Representation.** The value is retained as the decimal text the
/// server produced, which is exact by construction: nothing is lost
/// between the wire and the consumer. [BigInt] is materialised only when
/// somebody asks for exactness, so the hot path (decode) costs the same
/// as before — a `numeric` arrives as decimal text either way, and now
/// that text is simply kept instead of parsed into a `double`.
///
/// ```dart
/// final amount = row.getNumeric('total')!;
/// print(amount);                 // 1234.56  — exact
/// print(amount.unscaledValue);   // 123456
/// print(amount.scale);           // 2
/// print(amount.toDouble());      // 1234.56  — lossy, explicitly
/// ```
///
/// **Non-finite values.** `numeric` is not only numbers: the type carries
/// `NaN`, `Infinity` and `-Infinity` as states of its own, in the `sign`
/// field of the binary format (`NUMERIC_NAN`, `NUMERIC_PINF`,
/// `NUMERIC_NINF`).
/// They are not floating-point artefacts that an exact type avoids.
/// [toString] and [toDouble] handle them; [unscaledValue] and [scale]
/// have no meaning for them and throw [StateError]. Ask [isFinite] first
/// when reading a column that can hold one.
///
/// **Equality is on the representation, not on the number.** `1.10` and
/// `1.1` are the same quantity and different `numeric` values: Postgres
/// keeps a display scale (`dscale`) and so does this type. Two instances
/// are `==` when their text matches. To compare quantities, compare
/// [unscaledValue] after aligning [scale], or go through [toDouble] when
/// the precision loss is acceptable.
final class PostgresNumeric {
  final String _text;

  /// Wraps the decimal text of a `numeric` exactly as the server wrote
  /// it. Accepts `'NaN'`, `'Infinity'` and `'-Infinity'`.
  const PostgresNumeric.fromText(this._text);

  /// `true` when this is `NaN`.
  bool get isNaN => _text == 'NaN';

  /// `true` when this is `Infinity` or `-Infinity`.
  bool get isInfinite => _text == 'Infinity' || _text == '-Infinity';

  /// `true` for an ordinary decimal — everything [unscaledValue] and
  /// [scale] are defined for.
  bool get isFinite => !isNaN && !isInfinite;

  /// Digits of the value with the decimal point removed.
  ///
  /// Together with [scale] this reconstructs the value exactly:
  /// `unscaledValue / 10^scale`.
  ///
  /// Throws [StateError] if the value is not finite.
  BigInt get unscaledValue {
    _requireFinite('unscaledValue');
    final dot = _text.indexOf('.');
    if (dot < 0) return BigInt.parse(_text);
    return BigInt.parse(_text.substring(0, dot) + _text.substring(dot + 1));
  }

  /// Number of digits after the decimal point, as the server declared
  /// it. Trailing zeros count: `1.10` has scale 2, `1.1` has scale 1.
  ///
  /// Throws [StateError] if the value is not finite.
  int get scale {
    _requireFinite('scale');
    final dot = _text.indexOf('.');
    return dot < 0 ? 0 : _text.length - dot - 1;
  }

  /// Lossy conversion, asked for explicitly. This is what
  /// `PostgresResultRow.getDouble` uses, so consumers written against the
  /// old `double` behaviour keep working.
  ///
  /// `NaN` and the infinities convert to their IEEE 754 counterparts.
  double toDouble() => double.parse(_text);

  void _requireFinite(String member) {
    if (isFinite) return;
    throw StateError(
        '$member is undefined for a non-finite numeric ($_text); '
        'check isFinite first');
  }

  @override
  String toString() => _text;

  @override
  bool operator ==(Object other) =>
      other is PostgresNumeric && other._text == _text;

  @override
  int get hashCode => _text.hashCode;
}
