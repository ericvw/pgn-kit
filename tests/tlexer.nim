import std/[json, strutils, posix]
import unittest
import pgn_kit/lexer_types
import pk_lex

# Pipe-based harness: write input, close write end to signal EOF, run lex,
# read all output. Safe only for inputs whose output fits in the kernel pipe
# buffer (~64 KB). All test cases here are well within that limit.
proc runLex(input: string): seq[JsonNode] =
  var inPipe, outPipe: array[2, cint]
  doAssert posix.pipe(inPipe) == 0
  doAssert posix.pipe(outPipe) == 0
  if input.len > 0:
    discard posix.write(inPipe[1], unsafeAddr input[0], input.len)
  discard posix.close(inPipe[1])
  lex(inPipe[0], outPipe[1])
  discard posix.close(outPipe[1])
  var raw = ""
  var chunk: array[4096, char]
  while true:
    let n = posix.read(outPipe[0], addr chunk[0], chunk.len)
    if n <= 0: break
    let prev = raw.len
    raw.setLen(raw.len + n)
    copyMem(addr raw[prev], addr chunk[0], n)
  discard posix.close(outPipe[0])
  discard posix.close(inPipe[0])
  for line in raw.splitLines:
    if line.len > 0:
      result.add parseJson(line)

proc t(tok: JsonNode): string = tok["t"].getStr
proc v(tok: JsonNode): string = tok["v"].getStr
proc l(tok: JsonNode): int = tok["l"].getInt
proc c(tok: JsonNode): int = tok["c"].getInt
proc p(tok: JsonNode): int = tok["p"].getInt

suite "tokenName":
  test "covers all kinds":
    check tokenName[tkSym] == "sym"
    check tokenName[tkStr] == "str"
    check tokenName[tkOpn] == "opn"
    check tokenName[tkCls] == "cls"
    check tokenName[tkDot] == "dot"
    check tokenName[tkCom] == "com"

suite "lex — delimiters":
  test "empty input yields no tokens":
    check runLex("").len == 0

  test "whitespace-only input yields zero tokens":
    check runLex(" \t\r\n   \t\r\n").len == 0

  test "stray } in idle is silently skipped":
    let toks = runLex("}")
    check toks.len == 0
    let toks2 = runLex("e4 } e5")
    check toks2.len == 2
    check toks2[0].t == "sym" and toks2[0].v == "e4"
    check toks2[1].t == "sym" and toks2[1].v == "e5"

  test "multiple consecutive stray } and adjacent to brackets":
    let toks = runLex("}}}")
    check toks.len == 0
    let toks2 = runLex("}[Event]")
    check toks2.len == 3
    check toks2[0].t == "opn" and toks2[0].v == "["
    check toks2[1].t == "sym" and toks2[1].v == "Event"
    check toks2[2].t == "cls" and toks2[2].v == "]"

  test "tkOpn and tkCls value correctness for brackets and parentheses":
    let toks = runLex("[ ( ] )")
    check toks.len == 4
    check toks[0].t == "opn" and toks[0].v == "["
    check toks[1].t == "opn" and toks[1].v == "("
    check toks[2].t == "cls" and toks[2].v == "]"
    check toks[3].t == "cls" and toks[3].v == ")"

  test "multiple tokens of each delimiter kind in sequence":
    let toks = runLex("[[ (()) ]]")
    check toks.len == 8
    check toks[0].t == "opn" and toks[0].v == "["
    check toks[1].t == "opn" and toks[1].v == "["
    check toks[2].t == "opn" and toks[2].v == "("
    check toks[3].t == "opn" and toks[3].v == "("
    check toks[4].t == "cls" and toks[4].v == ")"
    check toks[5].t == "cls" and toks[5].v == ")"
    check toks[6].t == "cls" and toks[6].v == "]"
    check toks[7].t == "cls" and toks[7].v == "]"

  test "move number with dot":
    let toks = runLex("1.e4")
    check toks.len == 3
    check toks[0].t == "sym" and toks[0].v == "1"
    check toks[1].t == "dot" and toks[1].v == "."
    check toks[2].t == "sym" and toks[2].v == "e4"

  test "ellipsis continuation":
    let toks = runLex("3...a6")
    check toks.len == 5
    check toks[0].t == "sym" and toks[0].v == "3"
    check toks[1].t == "dot"
    check toks[2].t == "dot"
    check toks[3].t == "dot"
    check toks[4].t == "sym" and toks[4].v == "a6"

suite "lex — symbols":
  test "NAG treated as symbol":
    let toks = runLex("$1")
    check toks.len == 1
    check toks[0].t == "sym" and toks[0].v == "$1"

  test "game result symbol":
    let toks = runLex("1/2-1/2")
    check toks.len == 1
    check toks[0].t == "sym" and toks[0].v == "1/2-1/2"

  test "castling":
    let toks = runLex("O-O")
    check toks.len == 1
    check toks[0].t == "sym" and toks[0].v == "O-O"

  test "symbol at EOF without trailing whitespace":
    let toks = runLex("e4")
    check toks.len == 1
    check toks[0].t == "sym" and toks[0].v == "e4"

  test "result symbols":
    let toks = runLex("1-0 0-1")
    check toks.len == 2
    check toks[0].t == "sym" and toks[0].v == "1-0"
    check toks[1].t == "sym" and toks[1].v == "0-1"

suite "lex — strings":
  test "basic string":
    let toks = runLex("\"Test\"")
    check toks.len == 1
    check toks[0].t == "str" and toks[0].v == "Test"

  test "string with PGN escape sequence is valid NDJSON":
    let toks = runLex("\"a\\\"b\"")
    check toks.len == 1
    check toks[0].t == "str"
    check toks[0].v == "a\\\"b"

  test "string with literal escaped backslash and non-quote characters":
    let toks = runLex("\"a\\\\nb\"")
    check toks.len == 1
    check toks[0].t == "str"
    check toks[0].v == "a\\\\nb"

  test "string with backspace, formfeed and low control characters is escaped correctly":
    let toks = runLex("\"a\x08b\x0Cc\x01d\"")
    check toks.len == 1
    check toks[0].t == "str"
    check toks[0].v == "a\x08b\x0Cc\x01d"

suite "lex — comments":
  test "curly-brace comment":
    let toks = runLex("{Ruy Lopez}")
    check toks.len == 1
    check toks[0].t == "com" and toks[0].v == "Ruy Lopez"

  test "semicolon line comment":
    let toks = runLex("; comment\ne4")
    check toks.len == 2
    check toks[0].t == "com" and toks[0].v == " comment"
    check toks[1].t == "sym" and toks[1].v == "e4"

  test "comment with embedded quote is valid NDJSON":
    let toks = runLex("{a\"b}")
    check toks.len == 1
    check toks[0].t == "com"
    check toks[0].v == "a\"b"

  test "multiline comment has newline escaped in JSON output":
    let toks = runLex("{line1\nline2}")
    check toks.len == 1
    check toks[0].t == "com"
    check toks[0].v == "line1\nline2"

  test "comment with tab escaped in JSON output":
    let toks = runLex("{a\tb}")
    check toks.len == 1
    check toks[0].t == "com"
    check toks[0].v == "a\tb"

  test "comment with carriage return escaped in JSON output":
    let toks = runLex("{a\rb}")
    check toks.len == 1
    check toks[0].t == "com"
    check toks[0].v == "a\rb"

  test "comment with NUL byte escaped as \\u0000":
    let toks = runLex("{a\x00b}")
    check toks.len == 1
    check toks[0].t == "com"
    check toks[0].v == "a\x00b"

  test "comment with backspace, formfeed and low control characters":
    let toks = runLex("{a\x08b\x0Cc\x01d}")
    check toks.len == 1
    check toks[0].t == "com"
    check toks[0].v == "a\x08b\x0Cc\x01d"

  test "large brace comment (> 4KB) exercises direct-write path":
    let commentText = "x".repeat(4500)
    let toks = runLex("{" & commentText & "}")
    check toks.len == 1
    check toks[0].t == "com"
    check toks[0].v == commentText

suite "lex — malformed input":
  test "unterminated line comment at EOF emits tkCom":
    let toks = runLex("; no newline")
    check toks.len == 1
    check toks[0].t == "com"
    check toks[0].v == " no newline"

  test "bare ; at EOF emits nothing":
    let toks = runLex(";")
    check toks.len == 0

suite "lex — position tracking":
  test "byte offset, line, col on tag pair":
    let toks = runLex("[Event \"Test\"]")
    check toks[0].l == 1 and toks[0].c == 1 and toks[0].p == 0 # [
    check toks[1].l == 1 and toks[1].c == 2 and toks[1].p == 1 # Event
    check toks[2].l == 1 and toks[2].c == 8 and toks[2].p == 7 # "Test"
    check toks[3].l == 1 and toks[3].c == 14 and toks[3].p == 13 # ]

  test "line counter increments across newlines":
    let toks = runLex("[A \"x\"]\n[B \"y\"]")
    check toks[0].l == 1 # [
    check toks[4].l == 2 # second [

  test "semicolon comment position points to semicolon":
    let toks = runLex("; hi\ne4")
    check toks[0].l == 1 and toks[0].c == 1 and toks[0].p == 0
    check toks[1].l == 2 and toks[1].c == 1 and toks[1].p == 5

  test "column tracking after brace comment is correctly maintained":
    let toks = runLex("{comment}e4")
    check toks.len == 2
    check toks[0].t == "com" and toks[0].v == "comment"
    check toks[0].l == 1 and toks[0].c == 1 and toks[0].p == 0
    check toks[1].t == "sym" and toks[1].v == "e4"
    check toks[1].l == 1 and toks[1].c == 10 and toks[1].p == 9

  test "column tracking after multiline string":
    let toks = runLex("\"line1\nline2\" e4")
    check toks.len == 2
    check toks[0].t == "str"
    check toks[1].t == "sym" and toks[1].v == "e4"
    check toks[1].l == 2 and toks[1].c == 8 and toks[1].p == 14

  test "column tracking after multiline brace comment":
    let toks = runLex("{line1\nline2} e4")
    check toks.len == 2
    check toks[0].t == "com"
    check toks[1].t == "sym" and toks[1].v == "e4"
    check toks[1].l == 2 and toks[1].c == 8 and toks[1].p == 14

  test "column tracking after string backslash and newline":
    let toks = runLex("\"line1\\\nline2\" e4")
    check toks.len == 2
    check toks[0].t == "str"
    check toks[1].t == "sym" and toks[1].v == "e4"
    check toks[1].l == 2 and toks[1].c == 8 and toks[1].p == 15

suite "lex — integration":
  test "realistic multi-game PGN fragment":
    let pgn = """[Event "F/S Return Match"]
[Site "Belgrade SRB"]
[Result "1/2-1/2"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 {Ruy Lopez} a6 (3... Nf6) 1/2-1/2
"""
    let toks = runLex(pgn)
    # 33 tokens = 12 header tokens (3 tags * 4 tokens: [ Event "..." ])
    # + 21 move-text tokens (1.e4 e5 2.Nf3 Nc6 3.Bb5 {Ruy Lopez} a6 (3... Nf6) 1/2-1/2)
    check toks.len == 33
    check toks[0].t == "opn" and toks[0].v == "["
    check toks[1].t == "sym" and toks[1].v == "Event"
    check toks[2].t == "str" and toks[2].v == "F/S Return Match"
    check toks[3].t == "cls" and toks[3].v == "]"
    check toks[4].t == "opn"
    check toks[5].t == "sym" and toks[5].v == "Site"
    check toks[6].t == "str" and toks[6].v == "Belgrade SRB"
    check toks[7].t == "cls"
    check toks[8].t == "opn"
    check toks[9].t == "sym" and toks[9].v == "Result"
    check toks[10].t == "str" and toks[10].v == "1/2-1/2"
    check toks[11].t == "cls"
    check toks[12].t == "sym" and toks[12].v == "1"
    check toks[13].t == "dot" and toks[13].v == "."
    check toks[14].t == "sym" and toks[14].v == "e4"
    check toks[15].t == "sym" and toks[15].v == "e5"
    check toks[16].t == "sym" and toks[16].v == "2"
    check toks[17].t == "dot"
    check toks[18].t == "sym" and toks[18].v == "Nf3"
    check toks[19].t == "sym" and toks[19].v == "Nc6"
    check toks[20].t == "sym" and toks[20].v == "3"
    check toks[21].t == "dot"
    check toks[22].t == "sym" and toks[22].v == "Bb5"
    check toks[23].t == "com" and toks[23].v == "Ruy Lopez"
    check toks[24].t == "sym" and toks[24].v == "a6"
    check toks[25].t == "opn" and toks[25].v == "("
    check toks[26].t == "sym" and toks[26].v == "3"
    check toks[27].t == "dot"
    check toks[28].t == "dot"
    check toks[29].t == "dot"
    check toks[30].t == "sym" and toks[30].v == "Nf6"
    check toks[31].t == "cls" and toks[31].v == ")"
    check toks[32].t == "sym" and toks[32].v == "1/2-1/2"
