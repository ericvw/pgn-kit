# AGENTS.md

## Project Overview

**PGN-Kit** is a modular suite of CLI utilities designed for the high-velocity processing of Portable Game Notation (PGN) data. It is written in Nim and follows a Unix-first philosophy ("one tool, one job").

The project decomposes chess data workflows into discrete, pipeable stages (ingestion, lexical scanning, and syntactic parsing) linked via a streaming NDJSON interface.

*   **Primary Utilities:**
    *   `pk-get`: Ingestion from Lichess/Chess.com APIs.
    *   `pk-lex`: Lexical Analysis (Raw PGN to NDJSON Tokens).
    *   `pk-parse`: Syntactic Analysis (NDJSON Tokens to Annotated AST).

## Building and Testing

The project uses `nimble`, the Nim package manager, for building and testing.

*   **Build the project:**
    ```bash
    nimble build
    ```
*   **Run tests:**
    ```bash
    nimble test
    ```
*   **Run the main lexer binary:**
    ```bash
    ./pk-lex
    ```

## Development Conventions and Architecture

*   **Language:** Nim (requires version >= 2.2.10).
*   **Architecture:** Decoupled CLI architecture. Binaries are independent to ensure strict separation of concerns and enable multi-core parallelism through kernel-level piping.
*   **Design Focus:** 
    *   **Performance:** Systems-grade performance utilizing manual FSM-based scanners and recursive descent parsers.
    *   **Memory Efficiency:** Zero-copy lexing optimized for high-throughput byte streaming with minimal memory allocations.
*   **Data Interchange:** Utilities communicate via a minimized NDJSON schema. Tokens have the following structure: `{"t":"type","v":"value","l":line,"c":col,"p":pos}`.
*   **Lexer (`pk-lex`):** Focuses on structural boundaries (delimiters, symbols, strings) using a "dumb" manual Finite State Machine (FSM), avoiding chess-specific semantics for better stability.
*   **Testing Style:** The project uses the standard Nim `unittest` module. Test files are located in the `tests/` directory and should be prefixed with a `t` (e.g., `test1.nim`).