# Style

## Naming

- **Variables, fields, arguments:** `camelCase`
- **Constants:** `SCREAMING_SNAKE_CASE` only
- **Procs and types:** `PascalCase`

## Switches

- Prefer exhaustive switches. Do **not** use partial switches (`#partial switch`), except in very rare cases where a full switch is genuinely impossible and the omission is obvious.

## Proc wrappers

- Do not add a proc that only forwards to another proc with different/default arguments:

```odin
InnerProc(a, b: int) {}
OuterProc(b: int) { InnerProc(2, b) } // Not allowed
```

Call `InnerProc(2, b)` directly instead.

## Comments

- Keep comments very short and concise.
- Comment struct fields inline, not above the field:

```odin
S :: struct {
	// Don't comment like this about a
	a: B // Comment like this
}
```

## Memory

- Do not create heap allocations that outlive the proc scope.
- Every `new`/`make` must have a matching `defer delete`/`free`, following that pattern.
