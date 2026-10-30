# d32

Deterministic, allocation-free signed Q16.16 gameplay arithmetic. `Value` is a
distinct `i32` whose raw integer represents units of 1/65536. Its range is
-32768 through 32767 + 65535/65536 (32767.9999847412109375). Use the package
arithmetic procs rather than operators on the raw representation: raw operators
do not implement these overflow and scaling rules.

- `ZERO`, `ONE`, `HALF`, `MIN`, `MAX`, `SCALE`, `FRACTION_BITS`: constants.
- `FromRaw`, `Raw`: exact conversion to and from the signed underlying `i32`;
  suitable for serialization when byte order is specified by the caller.
- `FromInt`, `FromRatio`: convert an `i32` integer or ratio to fixed point.
  `FromRatio` truncates toward zero. `ToInt` converts back to `i32`,
  discarding the fraction toward zero.
- `Add`, `Sub`, `Neg`, `Abs`, `Mul`, `Div`: arithmetic; multiplication and
  division discard fractional raw units toward zero. Results outside the range
  saturate to `MIN` or `MAX`, including `Neg(MIN)` and `Abs(MIN)`.
- `Div` and `FromRatio` with a zero denominator return `MAX` for a positive
  numerator, `MIN` for a negative numerator, and `ZERO` for zero. This policy
  does not report errors; validate divisors separately if required.
- `Sqrt`: integer square root, rounded down to a raw unit; negative inputs
  return `ZERO` and must be checked by the caller if invalid.
- `SqrtRaw(squared: u64) -> i64`: floor integer square root of a raw squared
  distance, such as a `WrappedDistanceSquared` result, without Q16.16
  rescaling. It is deterministic, uses no float, and cannot overflow: every
  `u64` input yields a root at most 4294967295, which fits `i64`.
- `SinCos`: approximate sine and cosine for an angle in **turns** (one turn
  is `ONE`), returning values in that order. Angles wrap every turn, including
  negative angles. Cardinal directions are exact; the integer parabolic
  approximation has absolute error below 0.002 per component.

## Wrapped geometry

Geometry sizes and results are in raw Q16.16 units, not whole world units.
`MAX_MAP_SIZE` is 4294967296 raw units (65536 world units). Each size must be
in `1..=MAX_MAP_SIZE`; invalid arguments return zero and `false`.

- `WrapRaw(coordinate: i64, origin: Value, size: i64) -> (Value, bool)` wraps
  any raw `i64` coordinate into `[origin, origin + size)`. The entire interval
  must fit in signed raw `i32`: `Raw(origin) + size - 1 <= Raw(MAX)`. This
  permits the full signed `d32` range with `origin = MIN` and
  `size = MAX_MAP_SIZE`. Negative coordinates use Euclidean wrapping.
- `AddRawWrapped(position, delta: i64, origin: Value, size: i64) ->
  (Value, bool)` adds a raw `i64` delta to a raw `i64` position and wraps the
  result into the same interval. It validates arguments like `WrapRaw` and
  reduces `position`, `delta`, and `origin` modulo `size` before adding, so no
  `i64` intermediate can overflow even for `i64` minimum and maximum inputs.
- `ShortestWrappedDelta(a, b: Value, size: i64) -> (i64, bool)` returns the
  shortest raw displacement from `a` to `b`, even if either is not already
  wrapped. For an exact half-period tie, it keeps the sign of `Raw(b) - Raw(a)`,
  matching the existing movement rule for coordinates within one period.
- `WrappedDistanceSquared(ax, ay, bx, by: Value, width, height: i64) ->
  (u64, bool)` returns the sum of squared shortest raw displacements. The
  result has 32 fractional bits (units of 1/4294967296 squared world units),
  and is not saturated or rescaled to `Value`.

Both periods are independently validated. At the maximum size, each shortest
raw displacement has magnitude at most 2147483648; each signed `i64` square
is at most 2^62 and their `u64` sum at most 2^63. Wrapping reduces the input
before subtracting the origin, so even `i64` minimum and maximum coordinates
are safe. No geometry operation allocates or uses floating point.

All calculations use bounded integer intermediates and no floating point or
heap allocation. Rounding and saturation occur at each operation, so changing
operation order can change results. No float conversion is provided: convert
outside authoritative simulation only, with an explicit rounding policy.
