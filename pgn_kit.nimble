# Package

version       = "0.1.0"
author        = "Eric N. Vander Weele"
description   = "PGN-Kit is a modular suite of CLI utilities designed for the high-velocity processing of Portable Game Notation (PGN). Built on the Unix philosophy of \"one tool, one job,\" it decomposes chess data workflows into discrete, pipeable stages—ingestion, lexical scanning, and syntactic parsing-linked via a streaming NDJSON interface."
license       = "Apache-2.0"
srcDir        = "src"
installExt    = @["nim"]
namedBin["pk_lex"] = "pk-lex"


# Dependencies

requires "nim >= 2.2.10"
