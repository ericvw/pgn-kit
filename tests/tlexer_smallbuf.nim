## Boundary-condition tests compiled with -d:BufSize=32 to force fillBuffer
## mid-token. Confirms the sliding-window FSM handles buffer seams correctly.
##
## Run via: nimble test
import std/[json, strutils, posix]
import unittest
import pgn_kit/lexer_types
import pk_lex

static:
  doAssert BufSize == 32, "compile with -d:BufSize=32"

proc runLex(input: string): seq[JsonNode] =
  var inPipe, outPipe: array[2, cint]
  doAssert posix.pipe(inPipe) == 0
  doAssert posix.pipe(outPipe) == 0
  var remaining = input.len
  var offset = 0
  while remaining > 0:
    let written = posix.write(inPipe[1], unsafeAddr input[offset], remaining)
    if written < 0:
      if errno == EINTR: continue
      doAssert false, "write to pipe failed"
    offset += written
    remaining -= written
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

# Each test is crafted so interesting bytes land at or across the 32-byte
# fill boundary. Token content is kept ≤ BufSize-1 = 31 bytes; the sliding
# window can only accommodate one token per buffer frame.

suite "lex — buffer boundary (BufSize=32)":
  test "symbol split across buffer boundary":
    # 30-char symbol starts before boundary; its last chars are in next fill.
    let input = "x".repeat(30) & " " & "hello"
    let toks = runLex(input)
    check toks.len > 0
    check toks[^1].t == "sym"
    check toks[^1].v == "hello"

  test "string value spanning buffer boundary":
    # Opening quote at offset 30; content and closing quote cross the seam.
    let input = "x".repeat(29) & " \"content\""
    let toks = runLex(input)
    check toks.len > 0
    check toks[^1].t == "str"
    check toks[^1].v == "content"

  test "lsStringEscape state at buffer boundary":
    # \ lands at offset 31 (last byte of first fill)
    let input = "x".repeat(28) & " \"a\\\"\""
    let toks = runLex(input)
    check toks.len > 0
    check toks[^1].t == "str"
    check toks[^1].v == "a\\\""

  test "brace comment closing } requires a buffer refill":
    # { + 31 content bytes fill the buffer exactly; } arrives after the slide.
    let input = "{" & "x".repeat(31) & "}"
    let toks = runLex(input)
    check toks.len == 1
    check toks[0].t == "com"
    check toks[0].v == "x".repeat(31)

  test "newline inside comment at buffer boundary tracks line correctly":
    # \n is the last byte of the first fill; } arrives after the slide.
    let input = "{" & "x".repeat(30) & "\n}"
    let toks = runLex(input)
    check toks.len == 1
    check toks[0].t == "com"
    check toks[0].v == "x".repeat(30) & "\n"

  test "% escape line content spanning buffer boundary":
    # % + 31-char content fills the buffer; \n and next token after slide.
    let input = "%" & "x".repeat(31) & "\ne4"
    let toks = runLex(input)
    check toks[0].t == "esc"
    check toks[0].v == "x".repeat(31)
    check toks[1].t == "sym" and toks[1].v == "e4"

  test "CRLF split across buffer boundary in line comment":
    # \r is the last byte of the first fill (index 31); \n is the first byte of next fill.
    let input = "e4 ;" & "x".repeat(27) & "\r\ne5"
    let toks = runLex(input)
    check toks.len == 3
    check toks[0].t == "sym" and toks[0].v == "e4"
    check toks[1].t == "com" and toks[1].v == "x".repeat(27)
    check toks[2].t == "sym" and toks[2].v == "e5"

  test "unterminated string spanning buffer boundary emits tkErr":
    # Opening quote near boundary; string never closes — EOF in lsString.
    let input = "x".repeat(29) & " \"unclosed"
    let toks = runLex(input)
    check toks.len > 0
    check toks[^1].t == "err"
    check toks[^1].v == "unclosed"

  test "EOF immediately after buffer refill":
    # Input is exactly BufSize (32) bytes: "e4 " + 29 'x's
    let input = "e4 " & "x".repeat(29)
    let toks = runLex(input)
    check toks.len == 2
    check toks[0].t == "sym" and toks[0].v == "e4"
    check toks[1].t == "sym" and toks[1].v == "x".repeat(29)

  test "sequence of short tokens forces many fillBuffer calls":
    # 100 single-char symbols — about 6 buffer refills with BufSize=32.
    let input = "a ".repeat(100).strip()
    let toks = runLex(input)
    check toks.len == 100
    for tok in toks:
      check tok.t == "sym" and tok.v == "a"

  test "realistic PGN header spanning multiple refills":
    let header = "[Event \"Round 1\"]\n[Site \"London\"]\n1.e4 e5 2.Nf3"
    let toks = runLex(header)
    check toks[0].t == "opn"
    check toks[1].t == "sym" and toks[1].v == "Event"
    check toks[2].t == "str" and toks[2].v == "Round 1"
    check toks[3].t == "cls"
    check toks[4].t == "opn"
    check toks[5].t == "sym" and toks[5].v == "Site"
    check toks[6].t == "str" and toks[6].v == "London"
    check toks[7].t == "cls"

  test "string newline split across buffer boundary":
    let input = "x".repeat(28) & " \"a\nb\""
    let toks = runLex(input)
    check toks.len == 2
    check toks[1].t == "str" and toks[1].v == "a\nb"

  test "lsStringEscape state with backslash and newline split across buffer boundary":
    let input = "x".repeat(28) & " \"\\\n\""
    let toks = runLex(input)
    check toks.len == 2
    check toks[1].t == "str" and toks[1].v == "\\\n"

  test "CRLF split in lsEscapeLine at buffer boundary":
    let input = "%" & "x".repeat(30) & "\r\ne4"
    let toks = runLex(input)
    check toks.len == 2
    check toks[0].t == "esc" and toks[0].v == "x".repeat(30)
    check toks[1].t == "sym" and toks[1].v == "e4"

  test "absolute offset tracking after buffer refills":
    let input = "x".repeat(30) & " " & "hello"
    let toks = runLex(input)
    check toks.len == 2
    check toks[0].t == "sym" and toks[0].v == "x".repeat(30)
    check toks[0]["p"].getInt == 0
    check toks[0]["l"].getInt == 1
    check toks[0]["c"].getInt == 1
    check toks[1].t == "sym" and toks[1].v == "hello"
    check toks[1]["p"].getInt == 31
    check toks[1]["l"].getInt == 1
    check toks[1]["c"].getInt == 32

  # Note: The fatal path in fillBuffer() when a single token exceeds BufSize (32 bytes)
  # calls quit(), which would terminate the test process. Therefore, it is not
  # testable via the in-process runLex harness.
