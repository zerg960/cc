-- Minimal gzip-only DEFLATE (fast output path, no CRC/zlib/raw).
-- API kept small: require(...) returns a table with M.gunzip(t).

local M = { _TYPE='module', _NAME='compress.deflatelua', _VERSION='gzip-only-fast' }

local io, math, string = io, math, string
local string_char  = string.char
local table_concat = table.concat
local table_sort   = table.sort
local math_max     = math.max

local DEBUG = false
local function warn(s) io.stderr:write(s, '\n') end
local function debug(...) print('DEBUG', ...) end
local function runtime_error(s, level) level = level or 1; error({s}, level+1) end
local function noeof(val) return assert(val, 'unexpected end of file') end
local function hasbit(bits, bitv) return bits % (bitv + bitv) >= bitv end

-- Optional bitops
local function requireany(...)
    for i = 1, select('#', ...) do
        local name = select(i, ...)
        if not name then return nil end
        local ok, mod = pcall(require, name)
        if ok then return mod end
    end
end
local bit = requireany('bit', 'bit32', 'bit.numberlua')
local band, lshift, rshift
if bit then
    band   = bit.band
    lshift = bit.lshift
    rshift = bit.rshift
end

-- Simple memoize
local function memoize(f)
    local mt = {}
    local t = setmetatable({}, mt)
    function mt:__index(k) local v = f(k); rawset(t, k, v); return v end
    return t
end
local pow2 = memoize(function(n) return 2^n end)

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

local function bitstream_from_bytestream(bys)
    local buf_byte, buf_nbit = 0, 0
    local o = {}

    function o:nbits_left_in_byte() return buf_nbit end

    if band then
        function o:read(nbits)
            nbits = nbits or 1
            while buf_nbit < nbits do
                local byte = bys:read()
                if not byte then return end
                buf_byte = buf_byte + lshift(byte, buf_nbit)
                buf_nbit = buf_nbit + 8
            end
            local bits
            if nbits == 0 then
                bits = 0
            elseif nbits == 32 then
                bits = buf_byte
                buf_byte = 0
            else
                bits = band(buf_byte, rshift(0xffffffff, 32 - nbits))
                buf_byte = rshift(buf_byte, nbits)
            end
            buf_nbit = buf_nbit - nbits
            return bits
        end
    else
        function o:read(nbits)
            nbits = nbits or 1
            while buf_nbit < nbits do
                local byte = bys:read()
                if not byte then return end
                buf_byte = buf_byte + pow2[buf_nbit] * byte
                buf_nbit = buf_nbit + 8
            end
            local m = pow2[nbits]
            local bits = buf_byte % m
            buf_byte   = (buf_byte - bits) / m
            buf_nbit   = buf_nbit - nbits
            return bits
        end
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

    local SBUF_COALESCE = 64 * 1024
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

local function output(outstate, byte)
    local p = outstate.window_pos
    outstate.outbs_byte(byte)
    outstate.window[p] = byte
    outstate.window_pos = p % 32768 + 1
end

--========= Huffman & parsing =========--

local function HuffmanTable(init, is_full)
    local t = {}
    if is_full then
        for val, nbits in pairs(init) do
            if nbits ~= 0 then t[#t+1] = { val = val, nbits = nbits } end
        end
    else
        for i = 1, #init - 2, 2 do
            local firstval, nbits, nextval = init[i], init[i+1], init[i+2]
            if nbits ~= 0 then
                for val = firstval, nextval - 1 do
                    t[#t+1] = { val = val, nbits = nbits }
                end
            end
        end
    end

    table_sort(t, function(a, b)
        return (a.nbits == b.nbits and a.val < b.val) or (a.nbits < b.nbits)
    end)

    local code, nbits = 1, 0
    for _, s in ipairs(t) do
        if s.nbits ~= nbits then code = code * pow2[s.nbits - nbits]; nbits = s.nbits end
        s.code = code; code = code + 1
    end

    local minbits = math.huge
    local look = {}
    for _, s in ipairs(t) do
        if s.nbits < minbits then minbits = s.nbits end
        look[s.code] = s.val
    end

    local msb = band and
        function(bits, nbits_)
            local res = 0
            for _ = 1, nbits_ do res = lshift(res, 1) + band(bits, 1); bits = rshift(bits, 1) end
            return res
        end
        or
        function(bits, nbits_)
            local res = 0
            for _ = 1, nbits_ do local b = bits % 2; bits = (bits - b) / 2; res = res * 2 + b end
            return res
        end

    local tfirstcode = memoize(function(bits) return pow2[minbits] + msb(bits, minbits) end)

    function t:read(bs)
        local code_, nbits_ = 1, 0
        while true do
            if nbits_ == 0 then
                code_  = tfirstcode[noeof(bs:read(minbits))]
                nbits_ = nbits_ + minbits
            else
                local b = noeof(bs:read())
                nbits_ = nbits_ + 1
                code_  = code_ * 2 + b
            end
            local val = look[code_]
            if val then return val end
        end
    end

    return t
end

local function parse_huffmantables(bs)
    local hlit  = bs:read(5)
    local hdist = bs:read(5)
    local hclen = noeof(bs:read(4))

    local ncodelen_codes = hclen + 4
    local cinit = {}
    local cvals = { 16,17,18, 0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15 }
    for i = 1, ncodelen_codes do
        local nbits = bs:read(3)
        local val   = cvals[i]
        cinit[val] = nbits
    end

    local ctable = HuffmanTable(cinit, true)

    local function decode(ncodes)
        local init, nbits, val = {}, nil, 0
        while val < ncodes do
            local codelen = ctable:read(bs)
            local nrepeat
            if codelen <= 15 then
                nrepeat = 1; nbits = codelen
            elseif codelen == 16 then
                nrepeat = 3 + noeof(bs:read(2))
            elseif codelen == 17 then
                nrepeat = 3 + noeof(bs:read(3)); nbits = 0
            elseif codelen == 18 then
                nrepeat = 11 + noeof(bs:read(7)); nbits = 0
            else
                error 'ASSERT'
            end
            for _ = 1, nrepeat do init[val] = nbits; val = val + 1 end
        end
        return HuffmanTable(init, true)
    end

    local littable  = decode(hlit  + 257)
    local disttable = decode(hdist + 1)
    return littable, disttable
end

local tdecode_len_base, tdecode_len_nextrabits
local tdecode_dist_base, tdecode_dist_nextrabits

local function parse_compressed_item(bs, outstate, littable, disttable)
    local val = littable:read(bs)
    if val < 256 then
        output(outstate, val)
    elseif val == 256 then
        return true
    else
        if not tdecode_len_base then
            local t, skip = {[257]=3}, 1
            for i = 258, 285, 4 do
                for j = i, i + 3 do t[j] = t[j-1] + skip end
                if i ~= 258 then skip = skip * 2 end
            end
            t[285] = 258
            tdecode_len_base = t
        end
        if not tdecode_len_nextrabits then
            local t = {}
            if band then
                for i = 257, 285 do local j = math_max(i - 261, 0); t[i] = rshift(j, 2) end
            else
                for i = 257, 285 do local j = math_max(i - 261, 0); t[i] = (j - (j % 4)) / 4 end
            end
            t[285] = 0
            tdecode_len_nextrabits = t
        end
        local len_base   = tdecode_len_base[val]
        local nextra     = tdecode_len_nextrabits[val]
        local len        = len_base + (bs:read(nextra) or 0)

        if not tdecode_dist_base then
            local t, skip = {[0]=1}, 1
            for i = 1, 29, 2 do
                for j = i, i + 1 do t[j] = t[j-1] + skip end
                if i ~= 1 then skip = skip * 2 end
            end
            tdecode_dist_base = t
        end
        if not tdecode_dist_nextrabits then
            local t = {}
            if band then
                for i = 0, 29 do local j = math_max(i - 2, 0); t[i] = rshift(j, 1) end
            else
                for i = 0, 29 do local j = math_max(i - 2, 0); t[i] = (j - (j % 2)) / 2 end
            end
            tdecode_dist_nextrabits = t
        end

        local dist_val = disttable:read(bs)
        local dist     = tdecode_dist_base[dist_val] + (bs:read(tdecode_dist_nextrabits[dist_val]) or 0)

        for _ = 1, len do
            local pos = (outstate.window_pos - 1 - dist) % 32768 + 1
            output(outstate, assert(outstate.window[pos], 'invalid distance'))
        end
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
        bs:read(bs:nbits_left_in_byte())
        local len  = bs:read(16)
        local _nlen = noeof(bs:read(16))
        for _ = 1, len do output(outstate, noeof(bs:read(8))) end
    elseif btype == BTYPE_FIXED_HUFFMAN or btype == BTYPE_DYNAMIC_HUFFMAN then
        local littable, disttable
        if btype == BTYPE_DYNAMIC_HUFFMAN then
            littable, disttable = parse_huffmantables(bs)
        else
            littable  = HuffmanTable { 0,8, 144,9, 256,7, 280,8, 288,nil }
            disttable = HuffmanTable { 0,5, 32,nil }
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

    bs:read(bs:nbits_left_in_byte())
    -- Discard CRC32 and ISIZE (we intentionally don't compute/verify CRC here)
    local _crc32 = bs:read(32)
    local _isize = bs:read(32)

    if DEBUG then debug('crc32=', _crc32, 'isize=', _isize) end
    if bs:read() then warn 'trailing garbage ignored' end
end

return M
