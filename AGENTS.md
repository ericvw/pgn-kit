# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Project Overview

**PGN-Kit** is a modular suite of CLI utilities for high-velocity processing
of Portable Game Notation (PGN) data. Written in Nim with a Unix-first
philosophy, it decomposes chess data pipelines into discrete, pipeable stages
linked via a streaming NDJSON interface.

| Utility | Function | Input | Output |
| :--- | :--- | :--- | :--- |
| `pk-get` | Ingestion | Lichess/Chess.com API | Raw PGN stream |
| `pk-lex` | Lexical Analysis | Raw PGN | NDJSON tokens |
| `pk-parse` | Syntactic Analysis | NDJSON tokens | Annotated AST (JSON) |

Pipeline usage:

```bash
pk-get --user=gm_aman | pk-lex | pk-parse > games.json
```

## Build and Test

```bash
nimble build    # produces ./pk-lex
nimble test     # run all tests
```

To compile and run a single test file:

```bash
nim c -r tests/tfilename.nim
```

`tests/config.nims` adds `../src` to the Nim compiler path, so test files
can import `pgn_kit/module` without additional flags.

## Architecture

**Naming conventions:** Source files use underscores (`pk_lex.nim`); compiled
binaries use hyphens (`pk-lex`), as declared in `pgn_kit.nimble` via
`namedBin["pk_lex"] = "pk-lex"`.

**Lexer (`pk-lex`):** A manual FSM focusing on structural PGN boundaries —
delimiters, symbols, quoted strings — without chess-domain semantics. This
keeps the token schema stable across PGN variants.

**Token NDJSON schema** (minimized for throughput):

```json
{"t":"sym","v":"e4","l":1,"c":4,"p":42}
```

| Field | Meaning |
| :--- | :--- |
| `t` | Token type: `sym`, `str`, `opn`, `cls`, `dot`, `com`, `err` |
| `v` | Literal value |
| `l` | Line number |
| `c` | Column number |
| `p` | Byte offset |

**Parser (`pk-parse`):** Consumes the token stream to build an AST, handling
Recursive Annotation Variations (RAVs) and move-text validation via recursive
descent.

**Testing:** Test files live in `tests/` and must be prefixed with `t` (e.g.,
`tests/tlexer.nim`). Use the standard `unittest` module.
