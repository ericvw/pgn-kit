# PGN-Kit

**PGN-Kit** is a modular, high-performance suite of CLI utilities designed for
processing Portable Game Notation (PGN) data. Built with a Unix-first
philosophy, it decomposes chess data pipelines into discrete, pipeable stages
linked via a streaming NDJSON interface.

## Core Philosophy

* **Unix-First:** Each tool does one thing well. Inputs and outputs are
  strictly pipeable via `stdin` and `stdout`.
* **Decoupled Architecture:** Independent binaries (`pk-lex`, `pk-parse`,
  `pk-get`) ensure strict separation of concerns and enable multi-core
  parallelism through kernel-level piping.
* **Systems-Grade Nim:** Leverages Nim’s performance and metaprogramming. We
  utilize manual FSM-based scanners and recursive descent parsers rather than
  high-level library abstractions.
* **Zero-Copy Lexing:** Optimized for high-throughput byte streaming with
  minimal memory allocations.

## The Toolkit

| Utility | Function | Input | Output |
| :--- | :--- | :--- | :--- |
| `pk-get` | Ingestion | Lichess/Chess.com API | Raw PGN Stream |
| `pk-lex` | Lexical Analysis | Raw PGN | NDJSON Tokens |
| `pk-parse` | Syntactic Analysis | NDJSON Tokens | Annotated AST (JSON) |

## Quick Start

### Installation

Requires [Nim](https://nim-lang.org/) and `nimble`.

```bash
git clone https://github.com/yourusername/pgn-kit
cd pgn-kit
nimble build
```

### Usage

The power of **PGN-Kit** lies in the pipeline. Fetch a game archive, tokenize
the content, and parse the structure in a single command:

```bash
pk-get --user=gm_aman | pk-lex | pk-parse > games.json
```

## Data Interchange (NDJSON)

`pk-lex` emits a minimized NDJSON schema for maximum throughput and easy
debugging:

```json
{"t":"sym","v":"e4","l":1,"c":4,"p":42}
{"t":"dot","v":".","l":1,"c":5,"p":43}
```

* `t`: Token type (sym [incl. `*`, `<`, `>`], str, opn, cls, dot, com, esc, err)
* `v`: Literal value
* `l`: Line number
* `c`: Column number
* `p`: Byte position/offset

## Architecture & Design

### Lexical Analysis
The lexer (`pk-lex`) uses a manual Finite State Machine (FSM). It is a "dumb"
lexer, focusing on structural boundaries (delimiters, symbols, strings) rather
than chess semantics, ensuring the interface remains stable across different
PGN variants.

For a detailed breakdown of the FSM states, input buffering, and output handling, see the [pk-lex Design Decisions](docs/pk-lex-design.md).

### Syntactic Parsing
The parser (`pk-parse`) consumes the token stream to build an AST, handling
Recursive Annotation Variations (RAVs) and move-text validation.

## License

Apache 2.0
