package d32

// Value is a signed Q16.16 number. Use the arithmetic procs rather than raw operators.
Value :: distinct i32

FRACTION_BITS :: 16
SCALE :: i64(1 << FRACTION_BITS)
ZERO :: Value(0)
ONE :: Value(1 << FRACTION_BITS)
HALF :: Value(1 << (FRACTION_BITS - 1))
MIN :: Value(-2147483648)
MAX :: Value(2147483647)

@(private)
Saturate :: proc(value: i64) -> Value {
	if value > i64(i32(MAX)) {
		return MAX
	}
	if value < i64(i32(MIN)) {
		return MIN
	}
	return Value(i32(value))
}

// FromRaw and Raw preserve the exact Q16.16 bit pattern.
FromRaw :: proc(raw: i32) -> Value {
	return Value(raw)
}

Raw :: proc(value: Value) -> i32 {
	return i32(value)
}

FromInt :: proc(value: i32) -> Value {
	return Saturate(i64(value) * SCALE)
}

// FromRatio truncates toward zero; a zero denominator follows Div's policy.
FromRatio :: proc(numerator, denominator: i32) -> Value {
	if denominator == 0 {
		if numerator > 0 {
			return MAX
		}
		if numerator < 0 {
			return MIN
		}
		return ZERO
	}
	return Saturate(i64(numerator) * SCALE / i64(denominator))
}

ToInt :: proc(value: Value) -> i32 {
	return i32(i64(i32(value)) / SCALE)
}

Add :: proc(a, b: Value) -> Value {
	return Saturate(i64(i32(a)) + i64(i32(b)))
}

Sub :: proc(a, b: Value) -> Value {
	return Saturate(i64(i32(a)) - i64(i32(b)))
}

Neg :: proc(value: Value) -> Value {
	return Saturate(-i64(i32(value)))
}

Abs :: proc(value: Value) -> Value {
	if i32(value) < 0 {
		return Saturate(-i64(i32(value)))
	}
	return value
}

Mul :: proc(a, b: Value) -> Value {
	return Saturate(i64(i32(a)) * i64(i32(b)) / SCALE)
}

// Div returns MAX, MIN, or ZERO on division by zero, according to a's sign.
Div :: proc(a, b: Value) -> Value {
	if b == ZERO {
		if i32(a) > 0 {
			return MAX
		}
		if i32(a) < 0 {
			return MIN
		}
		return ZERO
	}
	return Saturate(i64(i32(a)) * SCALE / i64(i32(b)))
}

// Sqrt returns zero for negative inputs and otherwise rounds down.
Sqrt :: proc(value: Value) -> Value {
	if i32(value) <= 0 {
		return ZERO
	}
	radicand := u64(i32(value)) * u64(SCALE)
	root := radicand
	next := (root + 1) / 2
	for next < root {
		root = next
		next = (root + radicand / root) / 2
	}
	return Value(i32(root))
}

// SqrtRaw returns the integer square root of a raw squared distance, rounded down.
SqrtRaw :: proc(squared: u64) -> i64 {
	remainder := squared
	root: u64
	bit := u64(1) << 62
	for bit != 0 {
		candidate := root | bit
		root >>= 1
		if remainder >= candidate {
			remainder -= candidate
			root |= bit
		}
		bit >>= 2
	}
	return i64(root)
}

// MAX_MAP_SIZE is the largest period in raw units supported by geometry procs.
MAX_MAP_SIZE :: i64(4294967296)

// WrapRaw wraps a raw coordinate into [origin, origin + size).
WrapRaw :: proc(coordinate: i64, origin: Value, size: i64) -> (Value, bool) {
	if size <= 0 || size > MAX_MAP_SIZE {
		return ZERO, false
	}
	lower := i64(i32(origin))
	if lower + size - 1 > i64(i32(MAX)) {
		return ZERO, false
	}
	offset := (coordinate % size - lower % size) % size
	if offset < 0 {
		offset += size
	}
	return Value(i32(lower + offset)), true
}

// AddRawWrapped adds a raw delta to a raw position, then wraps into [origin, origin + size).
AddRawWrapped :: proc(position, delta: i64, origin: Value, size: i64) -> (Value, bool) {
	if size <= 0 || size > MAX_MAP_SIZE {
		return ZERO, false
	}
	lower := i64(i32(origin))
	if lower + size - 1 > i64(i32(MAX)) {
		return ZERO, false
	}
	offset := (position % size + delta % size - lower % size) % size
	if offset < 0 {
		offset += size
	}
	return Value(i32(lower + offset)), true
}

// ShortestWrappedDelta returns the raw displacement from a to b.
ShortestWrappedDelta :: proc(a, b: Value, size: i64) -> (i64, bool) {
	if size <= 0 || size > MAX_MAP_SIZE {
		return 0, false
	}
	delta := (i64(i32(b)) - i64(i32(a))) % size
	if delta > size / 2 {
		delta -= size
	} else if delta < -(size / 2) {
		delta += size
	}
	return delta, true
}

// WrappedDistanceSquared returns squared raw units, without Q16.16 rescaling.
WrappedDistanceSquared :: proc(ax, ay, bx, by: Value, width, height: i64) -> (u64, bool) {
	deltaX, validX := ShortestWrappedDelta(ax, bx, width)
	deltaY, validY := ShortestWrappedDelta(ay, by, height)
	if !validX || !validY {
		return 0, false
	}
	return u64(deltaX * deltaX) + u64(deltaY * deltaY), true
}

// SinCos takes turns, not radians, and returns an approximate sine and cosine.
SinCos :: proc(turns: Value) -> (sine, cosine: Value) {
	phase := i64(i32(turns)) % SCALE
	if phase < 0 {
		phase += SCALE
	}
	results: [2]Value
	for index in 0..<2 {
		angle := (phase + i64(index) * (SCALE / 4)) % SCALE
		sign: i64 = 1
		if angle >= SCALE / 2 {
			angle -= SCALE / 2
			sign = -1
		}
		// Correct a parabolic sine approximation using 0.225 in Q16.16.
		curve := 4 * angle * (SCALE / 2 - angle) / (SCALE / 4)
		curve += 14746 * (curve * curve / SCALE - curve) / SCALE
		results[index] = Value(i32(sign * curve))
	}
	return results[0], results[1]
}
