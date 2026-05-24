const BufSize* {.intdefine.} = 65_536
const OutBufSize* = 4_096

type TokenKind* = enum
  tkSym, tkStr, tkOpn, tkCls, tkDot, tkCom, tkEsc, tkErr

const tokenName*: array[TokenKind, string] =
  ["sym", "str", "opn", "cls", "dot", "com", "esc", "err"]

static:
  for name in tokenName:
    doAssert name.len == 3, "emitToken prefix assumes 3-char token names"

type LexerState* = enum
  lsIdle, lsSymbol, lsString, lsStringEscape, lsComment, lsLineComment,
  lsEscapeLine

type LexerContext* = object
  bufPos*: int         ## scanning head
  bufLen*: int         ## valid bytes in buffer
  lexemeStart*: int    ## token anchor; safe-to-discard floor for slide
  outBufLen*: int      ## valid bytes in output buffer
  globalOffset*: int64 ## bytes shifted out before the current window
  inFd*: cint          ## source file descriptor
  outFd*: cint         ## sink file descriptor
  buffer*: array[BufSize, char]
  outBuf*: array[OutBufSize, char]
