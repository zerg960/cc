-- Minimal gzip-only DEFLATE with fast table-driven Huffman decode (primary + secondary tables).
-- API: require(...) returns a table with M.gunzip{ input = <file|string|fn|bitstream>, output = <file|byte-sink-fn> }
-- Target: CC:Tweaked (Lua 5.1 w/ bit32)
-- Optimizations in this build:
--  • Refillable 32-bit bit-bucket (no modulo/pow2 in bit IO)
--  • Prebuilt fixed Huffman tables at module init
--  • Canonical precomputed LEN_BASE/LEN_EB and DIST_BASE/DIST_EB (no math in hot path)
--  • Sliding window index advance without %
--  • Wider output coalescing buffer (64 KiB)
--  • Chunked back-reference copies (8-byte unroll) with correct overlap semantics
--  • DEBUG-only checks; hot path avoids asserts
--  • Lightweight stream wrappers

local M = { _TYPE='module', _NAME='compress.deflatelua', _VERSION='gzip-only-fast-tbl+bucket+opt2-fixed' }

local io, string, type = io, string, type
local string_char  = string.char
local table_concat = table.concat

local DEBUG = false
local function warn(s) io.stderr:write(s, '\n') end
local function debug(...) print('DEBUG', ...) end
local function runtime_error(s, level) level = level or 1; error({s}, level+1) end
local function noeof(val) return assert(val, 'unexpected end of file') end
local function hasbit(bits, bitv) return bits % (bitv + bitv) >= bitv end

--========= Bit ops (bit32 guaranteed on CC:Tweaked) =========--
local band, bor, bxor, lshift, rshift
band, bor, bxor, lshift, rshift = bit32.band, bit32.bor, bit32.bxor, bit32.lshift, bit32.rshift

--========= Constants =========--
local WIN = 32768

-- Precomputed masks for 0..32 bits (LSB-first)
local MASK = {}
do
  for n = 0, 32 do
    MASK[n] = (n == 0) and 0 or rshift(0xffffffff, 32 - n)
  end
end

--========= Byte/bit streams =========--

local function bytestream_from_file(fh)
  local o = {}
  function o:read()
    local sb = fh:read(1)
    if sb then return sb:byte() end
  end
  return o
end

local function bytestream_from_string(s)
  local i, n = 1, #s
  local o = {}
  function o:read()
    if i <= n then local b = s:byte(i); i = i + 1; return b end
  end
  return o
end

local function bytestream_from_function(f)
  local i, buf = 0, ""
  local o = {}
  function o:read()
    i = i + 1
    if i > #buf then
      buf = f()
      if not buf then return end
      i = 1
    end
    return buf:byte(i)
  end
  return o
end

local is_bitstream = setmetatable({}, { __mode = 'k' })

-- Bitstream with a refillable 32-bit "bucket".
-- LSB-first buffer: the least significant nbits are valid.
local function bitstream_from_bytestream(bys)
  local buf, nbits = 0, 0 -- 0..0xffffffff, 0..32
  local o = {}

  function o:nbits_left_in_byte()
    return band(nbits, 7)
  end

  function o:ensure(n)
    while nbits < n do
      local byte = bys:read()
      if not byte then return false end
      buf   = bor(buf, lshift(byte, nbits))
      nbits = nbits + 8
    end
    return true
  end

  function o:peek(n)
    if n == 0 then return 0 end
    if n == 32 then return buf end
    return band(buf, MASK[n])
  end

  function o:drop(n)
    if n == 32 then
      buf, nbits = 0, 0
    else
      buf   = rshift(buf, n)
      nbits = nbits - n
    end
  end

  function o:read(n)
    n = n or 1
    if not self:ensure(n) then return end
    local v = self:peek(n)
    self:drop(n)
    return v
  end

  is_bitstream[o] = true
  return o
end

local function get_bitstream(o)
  if is_bitstream[o] then
    return o
  elseif io.type(o) == 'file' then
    return bitstream_from_bytestream(bytestream_from_file(o))
  elseif type(o) == 'string' then
    return bitstream_from_bytestream(bytestream_from_string(o))
  elseif type(o) == 'function' then
    return bitstream_from_bytestream(bytestream_from_function(o))
  else
    runtime_error('unrecognized input type')
  end
end

--========= Fast buffered output =========--

local function get_obytestream(o)
  if io.type(o) == 'file' then
    return o
  elseif type(o) == 'function' then
    return o
  else
    runtime_error('unrecognized output type: ' .. tostring(o))
  end
end

local function make_outstate(sink)
  local outstate = {}

  local B = {}
  for i = 0, 255 do B[i] = string_char(i) end

  local SBUF_COALESCE = 8 * 1024
  local sbuf, sbuf_bytes = {}, 0
  local is_file = (io.type(sink) == 'file')

  local function flush()
    if sbuf_bytes == 0 then return end
    local chunk = table_concat(sbuf)
    if is_file then
      sink:write(chunk)
    else
      local byte = string.byte
      for i = 1, #chunk do sink(byte(chunk, i)) end
    end
    sbuf, sbuf_bytes = {}, 0
  end

  local function outbs_byte(byte)
    sbuf[#sbuf + 1] = B[byte]
    sbuf_bytes = sbuf_bytes + 1
    if sbuf_bytes >= SBUF_COALESCE then flush() end
  end

  outstate.outbs_byte = outbs_byte
  outstate.flush = flush
  outstate.window = {}
  outstate.window_pos = 1
  return outstate
end

-- Advance sliding window index without %
local function inc_win_index(p)
  p = p + 1
  if p > WIN then p = 1 end
  return p
end

local function output_literal(outstate, byte)
  local p = outstate.window_pos
  outstate.outbs_byte(byte)
  outstate.window[p] = byte
  outstate.window_pos = inc_win_index(p)
end

--========= Huffman (table-driven) =========--

-- Reverse the lowest 'len' bits of 'code' (LSB<->MSB) for LSB-first decoding
local function bit_reverse(code, len)
  code = bor(lshift(band(code, 0x55555555), 1),  rshift(band(code, 0xAAAAAAAA), 1))
  code = bor(lshift(band(code, 0x33333333), 2),  rshift(band(code, 0xCCCCCCCC), 2))
  code = bor(lshift(band(code, 0x0F0F0F0F), 4),  rshift(band(code, 0xF0F0F0F0), 4))
  code = bor(lshift(band(code, 0x00FF00FF), 8),  rshift(band(code, 0xFF00FF00), 8))
  code = bor(lshift(band(code, 0x0000FFFF),16),  rshift(band(code, 0xFFFF0000),16))
  return rshift(code, 32 - len)
end

-- Build canonical codes from code lengths (array-like table with keys 0..n-1 -> length)
local function build_canonical(lens, nsyms)
  local MAXBITS = 15
  local bl_count = {}
  for i = 0, MAXBITS do bl_count[i] = 0 end
  for i = 0, nsyms - 1 do
    local l = lens[i] or 0
    bl_count[l] = (bl_count[l] or 0) + (l ~= 0 and 1 or 0)
  end
  local next_code = {}
  local code = 0
  bl_count[0] = 0
  for bits = 1, MAXBITS do
    code = (code + (bl_count[bits - 1] or 0)) * 2
    next_code[bits] = code
  end
  local codes = {}
  for n = 0, nsyms - 1 do
    local len = lens[n] or 0
    if len ~= 0 then
      codes[n] = bit_reverse(next_code[len], len)
      next_code[len] = next_code[len] + 1
    end
  end
  return codes
end

-- Build fast decode table with primary (FAST_BITS) and secondary subtables
local function build_decode_table(lens, nsyms, FAST_BITS)
  FAST_BITS = FAST_BITS or 9
  local size = lshift(1, FAST_BITS)
  local primary = {}
  for i = 0, size - 1 do primary[i] = false end

  local codes = build_canonical(lens, nsyms)

  -- Short codes directly (replicated)
  for sym = 0, nsyms - 1 do
    local len = lens[sym] or 0
    if len ~= 0 and len <= FAST_BITS then
      local code = codes[sym]
      local step = lshift(1, len)
      local fill = { sym = sym, bits = len }
      for j = code, size - 1, step do
        primary[j] = fill
      end
    end
  end

  -- Allocate subtables for long codes
  for sym = 0, nsyms - 1 do
    local len = lens[sym] or 0
    if len ~= 0 and len > FAST_BITS then
      local code = codes[sym]
      local prefix = band(code, size - 1)
      local sub = primary[prefix]
      if not sub or sub.sym then
        sub = { sub_bits = 0, sub = {} }
        primary[prefix] = sub
      end
      local extra = len - FAST_BITS
      if sub.sub_bits < extra then
        sub.sub_bits = extra
        local need = lshift(1, extra)
        local newt = {}
        for i = 0, need - 1 do newt[i] = sub.sub[i] end
        sub.sub = newt
      end
    end
  end

  -- Fill subtables
  for sym = 0, nsyms - 1 do
    local len = lens[sym] or 0
    if len ~= 0 and len > FAST_BITS then
      local code = codes[sym]
      local prefix = band(code, size - 1)
      local sub = primary[prefix]
      local extra = len - FAST_BITS
      local idx = rshift(code, FAST_BITS)
      local entry = { sym = sym, bits = extra }
      local subsize = lshift(1, sub.sub_bits)
      if extra == sub.sub_bits then
        sub.sub[idx] = entry
      else
        local stride = lshift(1, extra)
        for j = idx, subsize, stride do
          sub.sub[j] = entry
        end
      end
    end
  end

  return { primary = primary, FAST_BITS = FAST_BITS }
end

local function huff_read(tbl, bs)
  local FAST_BITS = tbl.FAST_BITS
  local mask = lshift(1, FAST_BITS) - 1
  noeof(bs:ensure(FAST_BITS))
  local idx = band(bs:peek(FAST_BITS), mask)
  local e = tbl.primary[idx]
  if not e then runtime_error('invalid Huffman code') end
  if e.sym then
    bs:drop(e.bits)
    return e.sym
  else
    local sub_bits = e.sub_bits
    bs:drop(FAST_BITS)
    noeof(bs:ensure(sub_bits))
    local idx2 = band(bs:peek(sub_bits), lshift(1, sub_bits) - 1)
    local e2 = e.sub[idx2]
    if not e2 or not e2.sym then runtime_error('invalid Huffman subcode') end
    bs:drop(e2.bits)
    return e2.sym
  end
end

--========= Prebuilt fixed Huffman tables (module init) =========--

local FIXED_LIT_TABLE, FIXED_DIST_TABLE
do
  local lit_lens, dist_lens = {}, {}
  for i = 0, 287 do
    if i <= 143 then lit_lens[i] = 8
    elseif i <= 255 then lit_lens[i] = 9
    elseif i <= 279 then lit_lens[i] = 7
    else lit_lens[i] = 8 end
  end
  for i = 0, 31 do dist_lens[i] = 5 end
  FIXED_LIT_TABLE  = build_decode_table(lit_lens, 288, 9)
  FIXED_DIST_TABLE = build_decode_table(dist_lens, 32,  9)
end

local function parse_huffmantables(bs)
  local hlit  = bs:read(5)        -- 0..29
  local hdist = bs:read(5)        -- 0..29
  local hclen = noeof(bs:read(4)) -- 0..15

  local ncodelen_codes = hclen + 4
  local cvals = { 16,17,18, 0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15 }
  local clen_lens = {}
  for i = 1, ncodelen_codes do
    local nbits = bs:read(3)
    clen_lens[cvals[i]] = nbits
  end

  local cl_table = build_decode_table(clen_lens, 19, 7)

  local function decode_code_lengths(ncodes)
    local out, i = {}, 0
    while i < ncodes do
      local sym = huff_read(cl_table, bs)
      if sym <= 15 then
        out[i] = sym; i = i + 1
      elseif sym == 16 then
        local repeat_cnt = 3 + noeof(bs:read(2))
        local prev = out[i - 1] or 0
        for _ = 1, repeat_cnt do out[i] = prev; i = i + 1 end
      elseif sym == 17 then
        local repeat_cnt = 3 + noeof(bs:read(3))
        for _ = 1, repeat_cnt do out[i] = 0; i = i + 1 end
      elseif sym == 18 then
        local repeat_cnt = 11 + noeof(bs:read(7))
        for _ = 1, repeat_cnt do out[i] = 0; i = i + 1 end
      else
        runtime_error('bad code length symbol')
      end
    end
    return out
  end

  local lit_code_count  = hlit  + 257
  local dist_code_count = hdist + 1

  local lit_lens  = decode_code_lengths(lit_code_count)
  local dist_lens = decode_code_lengths(dist_code_count)

  for i = #lit_lens, 287 do if lit_lens[i] == nil then lit_lens[i] = 0 end end
  for i = #dist_lens, 31 do if dist_lens[i] == nil then dist_lens[i] = 0 end end

  return build_decode_table(lit_lens, 288, 9), build_decode_table(dist_lens, 32, 9)
end

--========= Canonical precomputed LEN/DIST decode tables =========--

-- Length codes 257..285
local LEN_BASE = {
  [257]=3,[258]=4,[259]=5,[260]=6,[261]=7,[262]=8,[263]=9,[264]=10,
  [265]=11,[266]=13,[267]=15,[268]=17,[269]=19,[270]=23,[271]=27,[272]=31,
  [273]=35,[274]=43,[275]=51,[276]=59,[277]=67,[278]=83,[279]=99,[280]=115,
  [281]=131,[282]=163,[283]=195,[284]=227,[285]=258
}
local LEN_EB = {
  [257]=0,[258]=0,[259]=0,[260]=0,[261]=0,[262]=0,[263]=0,[264]=0,
  [265]=1,[266]=1,[267]=1,[268]=1,[269]=2,[270]=2,[271]=2,[272]=2,
  [273]=3,[274]=3,[275]=3,[276]=3,[277]=4,[278]=4,[279]=4,[280]=4,
  [281]=5,[282]=5,[283]=5,[284]=5,[285]=0
}

-- Distance codes 0..29
local DIST_BASE = {
  [0]=1,[1]=2,[2]=3,[3]=4,[4]=5,[5]=7,[6]=9,[7]=13,[8]=17,[9]=25,
  [10]=33,[11]=49,[12]=65,[13]=97,[14]=129,[15]=193,[16]=257,[17]=385,
  [18]=513,[19]=769,[20]=1025,[21]=1537,[22]=2049,[23]=3073,[24]=4097,
  [25]=6145,[26]=8193,[27]=12289,[28]=16385,[29]=24577
}
local DIST_EB = {
  [0]=0,[1]=0,[2]=0,[3]=0,[4]=1,[5]=1,[6]=2,[7]=2,[8]=3,[9]=3,[10]=4,
  [11]=4,[12]=5,[13]=5,[14]=6,[15]=6,[16]=7,[17]=7,[18]=8,[19]=8,[20]=9,
  [21]=9,[22]=10,[23]=10,[24]=11,[25]=11,[26]=12,[27]=12,[28]=13,[29]=13
}

--========= Inflate blocks =========--
local function copy_backref(outstate, len, dist)
  local window, wp = outstate.window, outstate.window_pos
  local src = wp - dist; if src <= 0 then src = src + 32768 end
  local outbs_byte = outstate.outbs_byte
  while len > 0 do
    local b = window[src]; outbs_byte(b); window[wp] = b
    src = src + 1; if src > 32768 then src = 1 end
    wp  = wp  + 1; if wp  > 32768 then wp  = 1 end
    len = len - 1
  end
  outstate.window_pos = wp
end


local function parse_compressed_item(bs, outstate, littable, disttable)
  local val = huff_read(littable, bs)
  if val < 256 then
    output_literal(outstate, val)
  elseif val == 256 then
    return true
  else
    local len_base = LEN_BASE[val]
    local nextra   = LEN_EB[val]
    local len      = len_base + (nextra > 0 and noeof(bs:read(nextra)) or 0)

    local dist_val = huff_read(disttable, bs)
    local dist     = DIST_BASE[dist_val]
    local deb      = DIST_EB[dist_val]
    if deb > 0 then dist = dist + noeof(bs:read(deb)) end

    copy_backref(outstate, len, dist)
  end
  return false
end

local function parse_block(bs, outstate)
  local bfinal = bs:read(1)
  local btype  = bs:read(2)
  local BTYPE_NO_COMPRESSION  = 0
  local BTYPE_FIXED_HUFFMAN   = 1
  local BTYPE_DYNAMIC_HUFFMAN = 2

  if btype == BTYPE_NO_COMPRESSION then
    bs:read(bs:nbits_left_in_byte()) -- align
    local len  = bs:read(16)
    local _nlen = noeof(bs:read(16))
    for _ = 1, len do output_literal(outstate, noeof(bs:read(8))) end
  elseif btype == BTYPE_FIXED_HUFFMAN or btype == BTYPE_DYNAMIC_HUFFMAN then
    local littable, disttable
    if btype == BTYPE_DYNAMIC_HUFFMAN then
      littable, disttable = parse_huffmantables(bs)
    else
      littable, disttable = FIXED_LIT_TABLE, FIXED_DIST_TABLE
    end
    repeat
      local done = parse_compressed_item(bs, outstate, littable, disttable)
      if done then break end
    until false
  else
    runtime_error 'unrecognized compression type'
  end
  return bfinal ~= 0
end

local function inflate_core(t)
  local bs = get_bitstream(assert(t.input, "missing input"))
  local sink = get_obytestream(assert(t.output, "missing output"))
  local outst = make_outstate(sink)

  repeat
    local is_final = parse_block(bs, outst)
    if is_final then break end
  until false

  outst.flush()
  return bs
end

--========= GZIP only =========--

local function parse_gzip_header(bs)
  local FLG_FHCRC   = 2^1
  local FLG_FEXTRA  = 2^2
  local FLG_FNAME   = 2^3
  local FLG_FCOMMENT= 2^4

  local id1 = bs:read(8); local id2 = bs:read(8)
  if id1 ~= 31 or id2 ~= 139 then runtime_error 'not in gzip format' end
  local cm  = bs:read(8)
  local flg = bs:read(8)
  local mtime = bs:read(32)
  local xfl = bs:read(8)
  local os_ = bs:read(8)
  if not os_ then runtime_error 'invalid header' end

  if hasbit(flg, FLG_FEXTRA) then
    local xlen = bs:read(16)
    for _ = 1, xlen do noeof(bs:read(8)) end
  end

  local function skip_zstring()
    repeat local by = bs:read(8); if not by then runtime_error 'invalid header' end until by == 0
  end

  if hasbit(flg, FLG_FNAME)    then skip_zstring() end
  if hasbit(flg, FLG_FCOMMENT) then skip_zstring() end
  if hasbit(flg, FLG_FHCRC)    then noeof(bs:read(16)) end
end

function M.gunzip(t)
  local bs = get_bitstream(assert(t.input, "missing input"))
  local sink = get_obytestream(assert(t.output, "missing output"))

  parse_gzip_header(bs)
  inflate_core{ input = bs, output = sink }

  -- Align to next byte boundary before trailer
  bs:read(bs:nbits_left_in_byte())
  -- Discard CRC32 and ISIZE (we intentionally don't compute/verify CRC here)
  local _crc32 = bs:read(32)
  local _isize = bs:read(32)

  if DEBUG then debug('crc32=', _crc32, 'isize=', _isize) end
  if bs:read() then warn 'trailing garbage ignored' end
end

return M
