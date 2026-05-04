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
    quit("pk-lex: token exceeds 64 KB", 1)
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
    if b < 0x20 or b == ord('"') or b == ord('\\'):
      if valStart + i > segStart:
        bufWrite(ctx, unsafeAddr ctx.buffer[segStart], valStart + i - segStart)
      var esc: array[6, char]
      var escLen: int
      case b
      of 0x08: esc[0] = '\\'; esc[1] = 'b'; escLen = 2
      of 0x09: esc[0] = '\\'; esc[1] = 't'; escLen = 2
      of 0x0A: esc[0] = '\\'; esc[1] = 'n'; escLen = 2
      of 0x0C: esc[0] = '\\'; esc[1] = 'f'; escLen = 2
      of 0x0D: esc[0] = '\\'; esc[1] = 'r'; escLen = 2
      of ord('"'): esc[0] = '\\'; esc[1] = '"'; escLen = 2
      of ord('\\'): esc[0] = '\\'; esc[1] = '\\'; escLen = 2
      else:
        esc[0] = '\\'; esc[1] = 'u'; esc[2] = '0'; esc[3] = '0'
        esc[4] = hex[int(b) shr 4]; esc[5] = hex[int(b) and 0xF]
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

  # Value: escaped for tkStr/tkCom; zero-copy for all other kinds
  if valLen > 0:
    case kind
    of tkStr, tkCom:
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

  while true:
    if ctx.bufPos >= ctx.bufLen:
      if not fillBuffer(ctx): break
    let b = ctx.buffer[ctx.bufPos]

    case state
    of lsIdle:
      case b
      of ord('['), ord('('):
        emitToken(ctx, tkOpn, ctx.bufPos, 1, line, col,
                  ctx.globalOffset + ctx.bufPos)
        inc col; inc ctx.bufPos
        ctx.lexemeStart = ctx.bufPos
      of ord(']'), ord(')'):
        emitToken(ctx, tkCls, ctx.bufPos, 1, line, col,
                  ctx.globalOffset + ctx.bufPos)
        inc col; inc ctx.bufPos
        ctx.lexemeStart = ctx.bufPos
      of ord('.'):
        emitToken(ctx, tkDot, ctx.bufPos, 1, line, col,
                  ctx.globalOffset + ctx.bufPos)
        inc col; inc ctx.bufPos
        ctx.lexemeStart = ctx.bufPos
      of ord('"'):
        tokLine = line; tokCol = col
        tokPos = ctx.globalOffset + ctx.bufPos
        inc col; inc ctx.bufPos
        ctx.lexemeStart = ctx.bufPos
        state = lsString
      of ord('{'):
        tokLine = line; tokCol = col
        tokPos = ctx.globalOffset + ctx.bufPos
        inc col; inc ctx.bufPos
        ctx.lexemeStart = ctx.bufPos
        state = lsComment
      of ord(';'):
        tokLine = line; tokCol = col
        tokPos = ctx.globalOffset + ctx.bufPos
        inc col; inc ctx.bufPos
        ctx.lexemeStart = ctx.bufPos
        state = lsLineComment
      of ord('\n'):
        inc line; col = 1; inc ctx.bufPos
        ctx.lexemeStart = ctx.bufPos
      of ord(' '), ord('\t'), ord('\r'):
        inc col; inc ctx.bufPos
        ctx.lexemeStart = ctx.bufPos
      of ord('}'):
        inc col; inc ctx.bufPos
        ctx.lexemeStart = ctx.bufPos
      else:
        tokLine = line; tokCol = col
        tokPos = ctx.globalOffset + ctx.bufPos
        ctx.lexemeStart = ctx.bufPos
        state = lsSymbol
        inc col; inc ctx.bufPos

    of lsSymbol:
      case b
      of ord(' '), ord('\t'), ord('\r'), ord('\n'),
         ord('['), ord(']'), ord('('), ord(')'),
         ord('{'), ord('}'), ord('"'), ord('.'), ord(';'):
        emitToken(ctx, tkSym,
                  ctx.lexemeStart, ctx.bufPos - ctx.lexemeStart,
                  tokLine, tokCol, tokPos)
        ctx.lexemeStart = ctx.bufPos
        state = lsIdle
      else:
        inc col; inc ctx.bufPos

    of lsString:
      case b
      of ord('"'):
        emitToken(ctx, tkStr,
                  ctx.lexemeStart, ctx.bufPos - ctx.lexemeStart,
                  tokLine, tokCol, tokPos)
        inc col; inc ctx.bufPos
        ctx.lexemeStart = ctx.bufPos
        state = lsIdle
      of ord('\\'):
        inc col; inc ctx.bufPos
        state = lsStringEscape
      of ord('\n'):
        inc line; col = 1; inc ctx.bufPos
      else:
        inc col; inc ctx.bufPos

    of lsStringEscape:
      if b == ord('\n'):
        inc line; col = 1
      else:
        inc col
      inc ctx.bufPos
      state = lsString

    of lsComment:
      case b
      of ord('}'):
        emitToken(ctx, tkCom,
                  ctx.lexemeStart, ctx.bufPos - ctx.lexemeStart,
                  tokLine, tokCol, tokPos)
        inc col; inc ctx.bufPos
        ctx.lexemeStart = ctx.bufPos
        state = lsIdle
      of ord('\n'):
        inc line; col = 1; inc ctx.bufPos
      else:
        inc col; inc ctx.bufPos

    of lsLineComment:
      if b == ord('\n'):
        emitToken(ctx, tkCom,
                  ctx.lexemeStart, ctx.bufPos - ctx.lexemeStart,
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
  of lsLineComment:
    let vl = ctx.bufPos - ctx.lexemeStart
    if vl > 0:
      emitToken(ctx, tkCom, ctx.lexemeStart, vl, tokLine, tokCol, tokPos)
  of lsString, lsStringEscape, lsComment:
    let vl = ctx.bufPos - ctx.lexemeStart
    if vl > 0:
      let kind = if state in {lsString, lsStringEscape}: tkStr else: tkCom
      emitToken(ctx, kind, ctx.lexemeStart, vl, tokLine, tokCol, tokPos)
  else: discard
  flushOut(ctx)

when isMainModule:
  lex(STDIN_FILENO.cint, STDOUT_FILENO.cint)
