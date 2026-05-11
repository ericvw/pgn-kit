# pk-lex Design Decisions

pk-lex is a streaming PGN lexer that reads raw PGN from stdin and emits
NDJSON tokens to stdout.  This document explains the key design choices.

## Structural Tokenization

The lexer recognizes PGN structure — delimiters, quoted strings, comments,
symbols — without assigning chess-domain semantics.  A move like `Nxf7+`
is simply a `sym` token; the lexer does not validate it as a legal move or
even a syntactically valid SAN string.

This keeps the token schema stable across PGN variants (standard, Chess960,
Crazyhouse) and confines chess-specific validation to `pk-parse`, where the
full game context is available.

Seven token kinds cover the entire PGN surface:

| Kind  | Meaning          | Examples             |
| :---- | :--------------- | :------------------- |
| `sym` | Symbol           | `e4`, `Nf3`, `1-0`  |
| `str` | Quoted string    | `"Kasparov, Garry"`  |
| `opn` | Opening bracket  | `[`, `(`             |
| `cls` | Closing bracket  | `]`, `)`             |
| `dot` | Period           | `.`                  |
| `com` | Comment          | `{text}`, `; text`   |
| `err` | Malformed token  | Unterminated string or comment at EOF |

## Manual Finite State Machine

The lexer is a hand-written Mealy FSM rather than a generated parser or
regex-based scanner.  A manual FSM gives predictable, branch-driven
performance with no runtime dependencies beyond libc.

Six states drive the machine:

- **lsIdle** — between tokens; dispatches on the next byte.
- **lsSymbol** — accumulating a symbol until a delimiter or whitespace.
- **lsString** — inside a `"…"` quoted string.
- **lsStringEscape** — the byte immediately after `\` inside a string.
- **lsComment** — inside a `{…}` brace comment.
- **lsLineComment** — after `;` until the next newline.

`lsStringEscape` exists as an explicit state (rather than an inline flag)
so that buffer refills only ever happen at the top of the main loop.  This
keeps the refill invariant uniform: every iteration begins with a validity
check on `bufPos`, and no mid-token code path calls `fillBuffer`.

## Input Buffer

A single 64 KB sliding-window buffer (`buffer: array[65536, uint8]`) feeds
the FSM.  When the scanning head (`bufPos`) reaches the end of valid data,
`fillBuffer` compacts the buffer:

1. Slide unprocessed bytes (from `lexemeStart` to `bufLen`) to position 0
   via `moveMem`.
2. Increment `globalOffset` by the number of bytes discarded to maintain
   correct absolute byte positions.
3. Read new data into the freed space.

A ring buffer was considered but rejected: it complicates token extraction
(values can wrap around the boundary) for a marginal reduction in
`moveMem` calls.  In practice, most PGN tokens are short, so the slide
distance is small.

`lexemeStart` marks the beginning of the current in-progress token and
acts as the safe-to-discard floor.  The buffer never discards data before
this point.

### Token Size Limit

If a token fills the entire 64 KB buffer (`lexemeStart == 0` and
`bufLen == BufSize`), the lexer terminates with an error rather than
dynamically resizing.  PGN tokens are inherently short — move notation,
player names, and comments rarely approach even 1 KB — so a 64 KB ceiling
is generous.

## Output Path

### NDJSON Format

Each token is emitted as a single JSON object on its own line:

```json
{"t":"sym","v":"e4","l":1,"c":4,"p":42}
```

Field names are minimized to single characters (`t`, `v`, `l`, `c`, `p`)
to reduce output volume in high-throughput pipelines.  NDJSON was chosen
over a binary format for debuggability: tokens can be inspected with
standard text tools (`head`, `grep`, `jq`).

### Write Buffer

Output is accumulated in a 4 KB buffer (`outBuf`) and flushed to the
output file descriptor only when the buffer is full or at EOF.  This
batches roughly 50–60 typical tokens per syscall.

4 KB was chosen over a larger buffer because pk-lex's primary use case is
piping to `pk-parse`, where throughput is governed by the kernel pipe
buffer and the downstream reader, not the write size.  A 4 KB buffer fits
in L1 cache and keeps memory pressure low when multiple pipeline stages
run concurrently.

### JSON Escaping

`tkStr`, `tkCom`, and `tkErr` values are scanned for bytes that
require JSON escaping.  All other token kinds (`tkSym`, `tkOpn`, `tkCls`, `tkDot`)
pass their values through unescaped; symbol terminators (`\n`, `\t`, space)
ensure those values never contain control characters.

Escaping follows RFC 8259: any byte below 0x20 must be escaped, as must
`"` and `\`.  Common control characters map to their two-byte JSON sequences
(`\n`, `\r`, `\t`, `\b`, `\f`); the remaining control bytes map to
six-byte `\u00XX` sequences.  Escape strings are built into a stack-allocated
`array[6, char]` — no heap allocation on the hot path.

PGN comments can legally contain literal newlines (`{multi\nline}`), which
is the primary reason this full escaping is necessary: a raw `\n` inside a
JSON string value would both produce invalid JSON and break the NDJSON
line-oriented streaming contract.

### Integer Formatting

`appendInt` converts integers to ASCII decimal without allocations or
format-string parsing.  It builds the digit sequence right-to-left in a
small stack buffer, then copies the result into the output array.  This
avoids pulling in Nim's string formatting machinery on the hot path.

## Error Contract

pk-lex applies three tiers of error handling:

- **Fail-fast:** I/O errors (`read`/`write` failures) and tokens exceeding
  the buffer limit (`BufSize`, default 64 KB) terminate immediately with a
  non-zero exit status.
- **Best-effort pass-through:** Invalid ASCII or non-UTF-8 bytes inside
  string or comment content are forwarded verbatim (after JSON escaping).
  Encoding validation is the responsibility of downstream consumers.
- **Error signaling:** Reaching EOF while inside `lsString`,
  `lsStringEscape` (retaining the trailing backslash verbatim in the token value),
  or `lsComment` emits a `tkErr` token containing whatever content was
  accumulated before EOF.  Unterminated line comments (`lsLineComment`) emit
  `tkCom` at EOF — a missing trailing newline is not considered an error.

## I/O Model

The lexer operates on raw POSIX file descriptors (`cint`), not Nim `File`
objects.  `lex(inFd, outFd)` accepts explicit descriptors rather than
defaulting to `stdin`/`stdout`.  This makes the lexer directly testable
via kernel pipes without spawning a subprocess or redirecting streams.

## Position Tracking

Every token carries three position fields:

- **`l`** (line) — 1-based line number, incremented at each `\n`.
- **`c`** (column) — 1-based column, incremented per byte, reset at `\n`.
- **`p`** (position) — 0-based absolute byte offset from the start of
  input, computed as `globalOffset + bufPos`.

Byte offset (`p`) survives buffer refills because `globalOffset` tracks
the cumulative bytes discarded during slides.  These positions are passed
through to `pk-parse` for error reporting.

## LexerContext Layout

`LexerContext` orders its fields for cache locality: the four scalars
accessed on every FSM iteration (`bufPos`, `bufLen`, `lexemeStart`,
`outBufLen`) occupy the first cache line.  The two large arrays (`buffer`
at 64 KB, `outBuf` at 4 KB) are placed last to avoid pushing hot fields
to high offsets.
