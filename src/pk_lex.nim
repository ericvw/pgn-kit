import std/posix
import pgn_kit/lexer_types

proc fillBuffer(ctx: var LexerContext): bool =
  if ctx.lexemeStart > 0:
    let remaining = ctx.bufLen - ctx.lexemeStart
    if remaining > 0:
      moveMem(addr ctx.buffer[0], addr ctx.buffer[ctx.lexemeStart], remaining)
    ctx.globalOffset += int64(ctx.lexemeStart)
    ctx.bufPos -= ctx.lexemeStart
    ctx.bufLen = remaining
    ctx.lexemeStart = 0
  elif ctx.bufLen == BufSize:
    quit("pk-lex: token exceeds buffer (" & $BufSize & " bytes)", 1)
  var n: int
  while true:
    let r = posix.read(ctx.inFd, addr ctx.buffer[ctx.bufLen], BufSize - ctx.bufLen)
    if r < 0:
      if errno == EINTR: continue
      quit("pk-lex: read error", 1)
    n = r
    break
  ctx.bufLen += n
  result = n > 0

proc writeAll(fd: cint, data: pointer, len: int) =
  var remaining = len
  var offset = 0
  while remaining > 0:
    let n = posix.write(fd, cast[pointer](cast[int](data) + offset), remaining)
    if n < 0:
      if errno == EINTR: continue
      quit("pk-lex: write error", 1)
    if n == 0:
      quit("pk-lex: write returned 0", 1)
    offset += n
    remaining -= n

proc flushOut(ctx: var LexerContext) =
  if ctx.outBufLen > 0:
    writeAll(ctx.outFd, addr ctx.outBuf[0], ctx.outBufLen)
    ctx.outBufLen = 0

proc bufWrite(ctx: var LexerContext, data: pointer, len: int) =
  if ctx.outBufLen + len > OutBufSize:
    writeAll(ctx.outFd, addr ctx.outBuf[0], ctx.outBufLen)
    ctx.outBufLen = 0
    if len >= OutBufSize:
      writeAll(ctx.outFd, data, len)
      return
  copyMem(addr ctx.outBuf[ctx.outBufLen], data, len)
  ctx.outBufLen += len

proc appendInt(buf: var openArray[char], at: var int, n: int64) =
  doAssert n >= 0, "appendInt requires non-negative input"
  var tmp: array[20, char]
  var hi = 20
  var x = n
  if x == 0:
    dec hi
    tmp[hi] = '0'
  else:
    while x > 0:
      dec hi
      tmp[hi] = char(ord('0') + int(x mod 10))
      x = x div 10
  let len = 20 - hi
  for i in 0 ..< len:
    buf[at + i] = tmp[hi + i]
  at += len

proc writeEscaped(ctx: var LexerContext, valStart, valLen: int) =
  const hex = "0123456789abcdef"
  var segStart = valStart
  for i in 0 ..< valLen:
    let b = ctx.buffer[valStart + i]
    if b < '\x20' or b == '"' or b == '\\':
      if valStart + i > segStart:
        bufWrite(ctx, unsafeAddr ctx.buffer[segStart], valStart + i - segStart)
      var esc: array[6, char]
      var escLen: int
      case b
      of '\x08': esc[0] = '\\'; esc[1] = 'b'; escLen = 2
      of '\x09': esc[0] = '\\'; esc[1] = 't'; escLen = 2
      of '\x0A': esc[0] = '\\'; esc[1] = 'n'; escLen = 2
      of '\x0C': esc[0] = '\\'; esc[1] = 'f'; escLen = 2
      of '\x0D': esc[0] = '\\'; esc[1] = 'r'; escLen = 2
      of '"': esc[0] = '\\'; esc[1] = '"'; escLen = 2
      of '\\': esc[0] = '\\'; esc[1] = '\\'; escLen = 2
      else:
        esc[0] = '\\'; esc[1] = 'u'; esc[2] = '0'; esc[3] = '0'
        esc[4] = hex[int(uint8(b)) shr 4]; esc[5] = hex[int(uint8(b)) and 0xF]
        escLen = 6
      bufWrite(ctx, addr esc[0], escLen)
      segStart = valStart + i + 1
  if valStart + valLen > segStart:
    bufWrite(ctx, unsafeAddr ctx.buffer[segStart], valStart + valLen - segStart)

proc emitToken(ctx: var LexerContext, kind: TokenKind,
               valStart, valLen: int, line, col: int, bytePos: int64) =
  # Prefix: {"t":"<3-char kind>","v":"   (always 16 bytes)
  var pfx: array[16, char]
  pfx[0] = '{'; pfx[1] = '"'; pfx[2] = 't'; pfx[3] = '"'
  pfx[4] = ':'; pfx[5] = '"'
  let nm = tokenName[kind]
  pfx[6] = nm[0]; pfx[7] = nm[1]; pfx[8] = nm[2]
  pfx[9] = '"'; pfx[10] = ','; pfx[11] = '"'
  pfx[12] = 'v'; pfx[13] = '"'; pfx[14] = ':'; pfx[15] = '"'
  bufWrite(ctx, addr pfx[0], 16)

  # Value: escaped for kinds that can contain control characters
  if valLen > 0:
    case kind
    of tkStr, tkCom, tkEsc, tkErr:
      writeEscaped(ctx, valStart, valLen)
    else:
      bufWrite(ctx, unsafeAddr ctx.buffer[valStart], valLen)

  # Suffix: ","l":<line>,"c":<col>,"p":<bytePos>}\n
  # Maximum size: 6 + 19 + 5 + 19 + 5 + 19 + 2 = 75 bytes.
  var sfx: array[96, char]
  var at = 0
  sfx[at] = '"'; inc at
  sfx[at] = ','; inc at; sfx[at] = '"'; inc at; sfx[at] = 'l'; inc at
  sfx[at] = '"'; inc at; sfx[at] = ':'; inc at
  appendInt(sfx, at, int64(line))
  sfx[at] = ','; inc at; sfx[at] = '"'; inc at; sfx[at] = 'c'; inc at
  sfx[at] = '"'; inc at; sfx[at] = ':'; inc at
  appendInt(sfx, at, int64(col))
  sfx[at] = ','; inc at; sfx[at] = '"'; inc at; sfx[at] = 'p'; inc at
  sfx[at] = '"'; inc at; sfx[at] = ':'; inc at
  appendInt(sfx, at, bytePos)
  sfx[at] = '}'; inc at
  sfx[at] = '\n'; inc at
  bufWrite(ctx, addr sfx[0], at)

proc lex*(inFd, outFd: cint) =
  var ctx: LexerContext
  ctx.inFd = inFd
  ctx.outFd = outFd
  var state = lsIdle
  var line = 1
  var col = 1
  var tokLine, tokCol: int
  var tokPos: int64

  template emitSingleChar(kind: TokenKind) =
    emitToken(ctx, kind, ctx.bufPos, 1, line, col, ctx.globalOffset + ctx.bufPos)
    inc col; inc ctx.bufPos
    ctx.lexemeStart = ctx.bufPos

  template startToken(newState: LexerState) =
    tokLine = line; tokCol = col
    tokPos = ctx.globalOffset + ctx.bufPos
    inc col; inc ctx.bufPos
    ctx.lexemeStart = ctx.bufPos
    state = newState

  template startSymbol() =
    tokLine = line; tokCol = col
    tokPos = ctx.globalOffset + ctx.bufPos
    ctx.lexemeStart = ctx.bufPos
    state = lsSymbol
    inc col; inc ctx.bufPos

  template emitTokenAndIdle(kind: TokenKind) =
    emitToken(ctx, kind,
              ctx.lexemeStart, ctx.bufPos - ctx.lexemeStart,
              tokLine, tokCol, tokPos)
    inc col; inc ctx.bufPos
    ctx.lexemeStart = ctx.bufPos
    state = lsIdle

  template skipChar() =
    inc col; inc ctx.bufPos
    ctx.lexemeStart = ctx.bufPos

  while true:
    if ctx.bufPos >= ctx.bufLen:
      if not fillBuffer(ctx): break
    let b = ctx.buffer[ctx.bufPos]

    case state
    of lsIdle:
      case b
      of '[', '(': emitSingleChar(tkOpn)
      of ']', ')': emitSingleChar(tkCls)
      of '.':      emitSingleChar(tkDot)
      of '*', '<', '>': emitSingleChar(tkSym)
      of '"':      startToken(lsString)
      of '{':      startToken(lsComment)
      of ';':      startToken(lsLineComment)
      of '\n':     inc line; col = 1; inc ctx.bufPos; ctx.lexemeStart = ctx.bufPos
      of ' ', '\t', '\r': skipChar()
      of '}':
        # Stray closing brace outside a comment — silently skip. PGN does not
        # define a meaning for unmatched } and erroring here would reject files
        # that are otherwise valid.
        skipChar()
      of '%':
        if col == 1: startToken(lsEscapeLine)
        else: startSymbol()
      else:
        startSymbol()

    of lsSymbol:
      case b
      of ' ', '\t', '\r', '\n',
         '[', ']', '(', ')',
         '{', '}', '"', '.', ';',
         '*', '<', '>':
        # We don't use emitTokenAndIdle here because the terminator character
        # shouldn't be consumed; it's merely detected so lsIdle can handle it
        # on the next iteration.
        emitToken(ctx, tkSym,
                  ctx.lexemeStart, ctx.bufPos - ctx.lexemeStart,
                  tokLine, tokCol, tokPos)
        ctx.lexemeStart = ctx.bufPos
        state = lsIdle
      else:
        inc col; inc ctx.bufPos

    of lsString:
      case b
      of '"':  emitTokenAndIdle(tkStr)
      of '\\': inc col; inc ctx.bufPos; state = lsStringEscape
      of '\n': inc line; col = 1; inc ctx.bufPos
      else:    inc col; inc ctx.bufPos

    of lsStringEscape:
      if b == '\n':
        inc line; col = 1
      else:
        inc col
      inc ctx.bufPos
      state = lsString

    of lsComment:
      case b
      of '}':  emitTokenAndIdle(tkCom)
      of '\n': inc line; col = 1; inc ctx.bufPos
      else:    inc col; inc ctx.bufPos

    of lsLineComment, lsEscapeLine:
      if b == '\n':
        let kind = if state == lsEscapeLine: tkEsc else: tkCom
        var vl = ctx.bufPos - ctx.lexemeStart
        if vl > 0 and ctx.buffer[ctx.bufPos - 1] == '\r':
          dec vl
          dec col
        emitToken(ctx, kind,
                  ctx.lexemeStart, vl,
                  tokLine, tokCol, tokPos)
        ctx.lexemeStart = ctx.bufPos
        state = lsIdle
        # bufPos NOT advanced — lsIdle handles \n for line/col accounting
      else:
        inc col; inc ctx.bufPos

  # EOF: flush any in-progress token
  case state
  of lsSymbol:
    let vl = ctx.bufPos - ctx.lexemeStart
    if vl > 0:
      emitToken(ctx, tkSym, ctx.lexemeStart, vl, tokLine, tokCol, tokPos)
  of lsLineComment, lsEscapeLine:
    var vl = ctx.bufPos - ctx.lexemeStart
    if vl > 0:
      if ctx.buffer[ctx.bufPos - 1] == '\r':
        dec vl
        dec col
      if vl > 0:
        let kind = if state == lsEscapeLine: tkEsc else: tkCom
        emitToken(ctx, kind, ctx.lexemeStart, vl, tokLine, tokCol, tokPos)
  of lsString, lsStringEscape, lsComment:
    let vl = ctx.bufPos - ctx.lexemeStart
    emitToken(ctx, tkErr, ctx.lexemeStart, vl, tokLine, tokCol, tokPos)
  else: discard
  flushOut(ctx)

when isMainModule:
  lex(STDIN_FILENO.cint, STDOUT_FILENO.cint)
