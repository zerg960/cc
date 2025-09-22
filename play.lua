function(require, mon, speakers, path, sub, limit)
    print("version 1.4.0")
  
    local char, byte, concat = string.char, string.byte, table.concat
    local bor, band, lshift, rshift = bit32.bor, bit32.band, bit32.lshift, bit32.rshift
    local min, max, floor = math.min, math.max, math.floor
    local epoch = os.epoch
    local pow2 = {}
    for i = 0, 15 do pow2[i] = 2^i end
  
    local function log2(n) local _, r = math.frexp(n); return r - 1 end
  
    local dfpwm = require("cc.audio.dfpwm")
  
    local function wrapText(text, width)
      text = tostring(text or "")
      local out, line = {}, ""
      local function flushLine() if #line > 0 then out[#out+1] = line end; line = "" end
      for para in (text .. "\n"):gmatch("([^\n]*)\n") do
        for word in para:gmatch("%S+") do
          if #line == 0 then line = word
          elseif #line + 1 + #word <= width then line = line .. " " .. word
          else out[#out+1] = line; line = word end
        end
        flushLine()
      end
      return out
    end

    
    local function save(name, url)
        fs.delete(name)
        if fs.exists(name) then
            return
        end

        local source = http.get(url).readAll()
        local file = fs.open(name, "w")
        file.write(source)
        file.close()
    end
    save("deflate", "https://raw.githubusercontent.com/zerg960/cc/refs/heads/main/deflate.lua")

    local function inflate_stream(src, kind, in_chunk, out_max)
        local DEFLATE = require("deflate")

        kind     = kind or "raw"
        in_chunk = in_chunk or 32 * 1024
        out_max  = out_max  or 64 * 1024  -- bigger to reduce yields/backpressure

        local byte   = string.byte
        local char   = string.char
        local concat = table.concat
        local min    = math.min

        local open, done = true, false

        -- Compact queue of produced chunks
        local chunks = {}
        local head_i, head_p, tail_i, avail = 1, 1, 0, 0

        local function queue_empty_reset()
            chunks = {}
            head_i, tail_i, head_p, avail = 1, 0, 1, 0
        end

        local function push_chunk(s)
            tail_i = tail_i + 1
            chunks[tail_i] = s
            avail = avail + #s
            if tail_i == 1 then head_i, head_p = 1, 1 end
        end

        local function in_fn()
            local s = src.read(in_chunk)
            if s == nil then return nil end
            if type(s) == "number" then s = char(s) end
            return s
        end

        local co = coroutine.create(function()
            -- Two-level coalescing:
            -- 1) Gather numeric bytes in nbuf; periodically convert to string via string.char(unpack(...)) in safe slabs.
            -- 2) Gather resulting strings in sbuf; flush to queue when big enough or before yielding.
            local NBUF_SLICE     = 2048        -- how many numbers per char(...) call
            local NBUF_FLUSH_AT  = 8192        -- flush numeric -> string when this many numbers accumulated
            local SBUF_COALESCE  = 64 * 1024   -- coalesce strings to at least this size before push
            local nbuf           = {}          -- numeric bytes (numbers 0..255)
            local ncnt           = 0
            local sbuf           = {}          -- string pieces
            local sbuf_bytes     = 0

            local unpack = unpack or table.unpack

            local function nbuf_to_strings()
                if ncnt == 0 then return end
                local i = 1
                while i <= ncnt do
                    local j = min(i + NBUF_SLICE - 1, ncnt)
                    sbuf[#sbuf + 1] = char(unpack(nbuf, i, j))
                    sbuf_bytes = sbuf_bytes + (j - i + 1)
                    i = j + 1
                end
                nbuf, ncnt = {}, 0
            end

            local function sbuf_flush()
                if sbuf_bytes > 0 then
                    push_chunk(concat(sbuf))
                    sbuf, sbuf_bytes = {}, 0
                end
            end

            local function out_fn(x)
                if type(x) == "number" then
                    -- Collect numeric bytes cheaply.
                    ncnt = ncnt + 1
                    nbuf[ncnt] = x
                    if ncnt >= NBUF_FLUSH_AT then
                        nbuf_to_strings()
                        if sbuf_bytes >= SBUF_COALESCE then
                            sbuf_flush()
                        end
                    end
                    -- Backpressure: consider both visible avail and pending buffers.
                    if (avail + sbuf_bytes + ncnt) >= out_max then
                        nbuf_to_strings(); sbuf_flush(); coroutine.yield()
                    end
                else
                    -- String from emitter: flush numeric buffer first, then coalesce string.
                    if ncnt > 0 then nbuf_to_strings() end
                    if x ~= "" then
                        sbuf[#sbuf + 1] = x
                        sbuf_bytes = sbuf_bytes + #x
                    end
                    if sbuf_bytes >= SBUF_COALESCE then
                        sbuf_flush()
                    end
                    if (avail + sbuf_bytes) >= out_max then
                        sbuf_flush(); coroutine.yield()
                    end
                end
            end

            if kind == "gzip" then
                DEFLATE.gunzip { input = in_fn, output = out_fn }
            elseif kind == "zlib" then
                DEFLATE.inflate_zlib { input = in_fn, output = out_fn }
            else
                DEFLATE.inflate { input = in_fn, output = out_fn }
            end

            -- Make pending data visible.
            nbuf_to_strings()
            sbuf_flush()
            done = true
        end)

        local function fill()
            if done then return end
            local ok, err = coroutine.resume(co)
            if not ok then error(err or "inflate error") end
        end

        local function pop1()
            local s = chunks[head_i]
            local b = byte(s, head_p)
            head_p = head_p + 1
            avail  = avail - 1
            if head_p > #s then
                chunks[head_i] = nil
                head_i = head_i + 1
                head_p = 1
                if head_i > tail_i then queue_empty_reset() end
            end
            return b
        end

        local function popn(n)
            local s1 = chunks[head_i]
            local len1 = #s1
            local rem1 = len1 - head_p + 1

            if n <= rem1 then
                local out = s1:sub(head_p, head_p + n - 1)
                head_p = head_p + n
                avail  = avail - n
                if head_p > len1 then
                    chunks[head_i] = nil
                    head_i = head_i + 1
                    head_p = 1
                    if head_i > tail_i then queue_empty_reset() end
                end
                return out
            end

            local want   = min(n, avail)
            local take1  = rem1
            local part1  = s1:sub(head_p)
            chunks[head_i] = nil
            head_i = head_i + 1
            head_p = 1
            avail  = avail - take1
            local remain = want - take1
            if remain == 0 then
                if head_i > tail_i then queue_empty_reset() end
                return part1
            end

            if head_i <= tail_i then
                local s2 = chunks[head_i]
                local len2 = #s2
                if remain <= len2 then
                    local out = part1 .. s2:sub(1, remain)
                    if remain < len2 then
                        head_p = remain + 1
                        avail  = avail - remain
                    else
                        chunks[head_i] = nil
                        head_i = head_i + 1
                        head_p = 1
                        avail  = avail - len2
                        if head_i > tail_i then queue_empty_reset() end
                    end
                    return out
                end
            end

            local out, oi = { part1 }, 2
            while remain > 0 and head_i <= tail_i do
                local s = chunks[head_i]
                local sl = #s
                if remain < sl then
                    out[oi] = s:sub(1, remain)
                    head_p  = remain + 1
                    avail   = avail - remain
                    remain  = 0
                    break
                else
                    out[oi] = s
                    chunks[head_i] = nil
                    head_i = head_i + 1
                    avail  = avail - sl
                    remain = remain - sl
                    oi = oi + 1
                end
            end
            if head_i > tail_i then queue_empty_reset() end
            return concat(out)
        end

        local function have() return avail end

        local t = {}

        function t.read(n)
            if not open then return nil end
            if n == nil or n == 1 then
                while have() < 1 do
                    if done then open = false; return nil end
                    fill()
                    if have() < 1 and done then open = false; return nil end
                end
                local b = pop1()
                if have() == 0 and done then open = false end
                return b
            else
                local want = n
                while have() < want do
                    if done then break end
                    fill()
                end
                if have() == 0 then open = false; return nil end
                local s = popn(want)
                if (s == nil or s == "") and done then open = false; return nil end
                if have() == 0 and done then open = false end
                return s
            end
        end

        function t.readLine(withTrailing)
            if not open then return nil end
            local out, oi = {}, 1
            while true do
                if avail == 0 then
                    if done then break end
                    fill()
                    if avail == 0 and done then break end
                    if avail == 0 then break end
                end
                local s = chunks[head_i]
                local p = head_p
                local nl = s:find("\n", p, true)
                if nl then
                    out[oi] = s:sub(p, nl); oi = oi + 1
                    avail = avail - (nl - p + 1)
                    head_p = nl + 1
                    if head_p > #s then
                        chunks[head_i] = nil
                        head_i = head_i + 1
                        head_p = 1
                        if head_i > tail_i then queue_empty_reset() end
                    end
                    break
                else
                    out[oi] = s:sub(p); oi = oi + 1
                    avail = avail - (#s - p + 1)
                    chunks[head_i] = nil
                    head_i = head_i + 1
                    head_p = 1
                    if head_i > tail_i then queue_empty_reset() end
                end
            end
            if oi == 1 then return nil end
            local line = concat(out)
            if not withTrailing then
                if line:sub(-1) == "\n" then line = line:sub(1, -2) end
                if line:sub(-1) == "\r" then line = line:sub(1, -2) end
            end
            if have() == 0 and done then open = false end
            return line
        end

        function t.readAll()
            local parts, pi = {}, 1
            while true do
                local s = t.read(64 * 1024)
                if not s then break end
                parts[pi] = s; pi = pi + 1
            end
            return concat(parts)
        end

        function t.close() open = false end

        return t
    end
    local function http_get(url)
      local r = http.get(url, { Range = "bytes=0-0", ["Accept-Encoding"] = "identity" }, true) or error("404")
      local h = r.getResponseHeaders()
      local total = tonumber(h["Content-Range"]:match("/(%d+)$"))
      total = min(limit or 50 * 1024 * 1024, total)
      r.readAll(); r.close()
  
      local parts, got = {}, 0
      while got < total do
        local first = got
        local last = min(got + 10 * 1024 * 1024 - 1, total - 1)
        local rr = http.get(url, { Range = ("bytes=%d-%d"):format(first, last), ["Accept-Encoding"] = "identity" }, true)
        parts[#parts + 1] = rr.readAll(); rr.close()
        got = last + 1
      end
  
      local body = concat(parts)
      local pos, open = 1, true
      local t = {}
      function t.readAll() if not open then return nil end; open = false; return body end
      function t.read(n)
        if not open then return nil end
        if n == nil or n == 1 then
          if pos > #body then open = false; return nil end
          local b = byte(body, pos); pos = pos + 1; if pos > #body then open = false end; return b
        else
          local s = body:sub(pos, pos + n - 1)
          pos = pos + #s; if pos > #body then open = false end
          if s == "" then return nil end; return s
        end
      end
      function t.readLine(withTrailing)
        if not open then return nil end
        local a, b = body:find("\n", pos, true)
        if not a then
          local s = body:sub(pos); pos = #body + 1; open = false
          if s == "" then return nil end
          return withTrailing and s .. "\n" or s
        end
        local line = body:sub(pos, a - 1); pos = b + 1
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        return withTrailing and line .. "\n" or line
      end
      function t.close() open = false end
      return t
    end
  
    local function ends_with(str, suffix)
      return suffix == "" or str:sub(-#suffix) == suffix
    end

    mon.setCursorBlink(false)
    local src = assert(http_get(path))
    local file = ends_with(path, ".bin") and src or inflate_stream(src, "gzip")
 
    local magic = file.read(4)
    if magic ~= "32VD" then file.close(); error("Invalid magic header: " .. tostring(magic)) end
    local width, height, fps, nstreams, flags = ("<HHBBH"):unpack(file.read(8))
    if nstreams ~= 1 then file.close(); error("Separate files unsupported") end
    local _, nframes, ctype = ("<IIB"):unpack(file.read(9))
    if ctype ~= 0x0C then file.close(); error("Stream type not supported") end

    if width == 61 or width == 71 or width == 82 then
      mon.setTextScale(1)
    elseif width == 121 or width == 143 or width == 164 then
      mon.setTextScale(0.5)
    elseif width == 30 or width == 36 or width == 41 then
      mon.setTextScale(2)
    end
  
    local vframe = 0
    local subs = {}
    local subPath = string.gsub(path, ".dat", ".sub")
    local subFileRaw = http.get(subPath)
    if subFileRaw ~= nil then
      local subIn = textutils.unserialize(subFileRaw.readAll())
      local function parse_time(t)
        local h, m, s = t:match("^(%d+):(%d+):(%d+%.%d+)$")
        if not h then error("Time format must be H:MM:SS.ff, got: " .. tostring(t)) end
        return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
      end
      local function to_frame(sec) return floor(sec * fps + 0.5) end
      for _, s in ipairs(subIn) do
        local startF = to_frame(parse_time(s.start))
        local endF = to_frame(parse_time(s["end"]))
        if endF <= startF then endF = startF + 1 end
        subs[#subs + 1] = { frame = startF, length = endF - startF, text = tostring(s.text or "") }
      end
    end
  
    local init, read
    if band(flags, 3) == 1 then
      local decodingTable, X, readbits, isColor
      function init(c)
        isColor = c
        local R = file.read()
        local L = 2 ^ R
        local Ls = (function(sz)
          local retval = {}
          for i = 0, sz - 1, 2 do local b = file.read(); retval[i] = rshift(b, 4); retval[i + 1] = band(b, 15) end
          return retval
        end)(isColor and 24 or 32)
        if R == 0 then decodingTable = file.read(); X = nil; return end
        local a = 0
        for i = 0, #Ls do Ls[i] = Ls[i] == 0 and 0 or 2 ^ (Ls[i] - 1); a = a + Ls[i] end
        assert(a == L, a)
        decodingTable = { R = R }
        local x, step, nexts, symbol = 0, 0.625 * L + 3, {}, {}
        for i = 0, #Ls do
          nexts[i] = Ls[i]
          for _ = 1, Ls[i] do
            while symbol[x] do x = (x + 1) % L end
            x, symbol[x] = (x + step) % L, i
          end
        end
        for x0 = 0, L - 1 do
          local s = symbol[x0]
          local t = { s = s, n = R - log2(nexts[s]) }
          t.X, decodingTable[x0], nexts[s] = lshift(nexts[s], t.n) - L, t, 1 + nexts[s]
        end
        local partial, bits, pos = 0, 0, 1
        function readbits(n)
          if not n then n = bits % 8 end; if n == 0 then return 0 end
          while bits < n do pos, bits, partial = pos + 1, bits + 8, lshift(partial, 8) + file.read() end
          local retval = band(rshift(partial, bits - n), 2 ^ n - 1); bits = bits - n; return retval
        end
        X = readbits(R)
      end
      function read(nsym)
        local retval = {}
        if X == nil then for i = 1, nsym do retval[i] = decodingTable end; return retval end
        local i, last = 1, 0
        while i <= nsym do
          local t = decodingTable[X]
          if isColor and t.s >= 16 then
            local l = 2 ^ (t.s - 15)
            for n = 0, l - 1 do retval[i + n] = last end
            i = i + l
          else retval[i], last, i = t.s, t.s, i + 1 end
          X = t.X + readbits(t.n)
        end
        return retval
      end
    elseif band(flags, 3) == 0 then
      local isColor, col_cache_bg, col_cache_fg, col_ready
      function init(c) isColor, col_cache_bg, col_cache_fg, col_ready = c, nil, nil, false end
  
      local function read_bytes(n)
        if n <= 0 then return "" end
        local s = file.read(n)
        if not s or #s < n then
          return (s or "") .. string.rep("\0", n - (s and #s or 0))
        end
        return s
      end
  
      function read(nsym)
        if isColor then
          if not col_ready then
            local bytes = read_bytes(nsym)
            local bg, fg = {}, {}
            for i = 1, nsym do
              local b = byte(bytes, i)
              bg[i] = rshift(b, 4); fg[i] = band(b, 0x0F)
            end
            col_cache_bg, col_cache_fg, col_ready = bg, fg, true
            return col_cache_bg
          else
            col_ready = false
            return col_cache_fg
          end
        end
  
        local totalPacks = math.ceil(nsym / 8)
        local targetBytes = totalPacks * 5
        local bytes = read_bytes(targetBytes)
  
        local out, buf, bits = {}, 0, 0
        for i = 1, targetBytes do
          local b = byte(bytes, i)
          buf  = bor(lshift(buf, 8), band(b, 0xFF))
          bits = bits + 8
          while bits >= 5 and #out < nsym do
            local shift = bits - 5
            out[#out + 1] = band(rshift(buf, shift), 0x1F)
            buf  = band(buf, lshift(1, shift) - 1)
            bits = shift
          end
          if #out >= nsym then break end
        end
        while #out < nsym do out[#out + 1] = 0 end
        return out
      end
    else
      error("Unimplemented compression method!")
    end
  
    local ch128 = {}
    for i = 0, 255 do ch128[i] = char(128 + (i % 128)) end
    local blitColors = {[0] = "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"}
  
    local function assemble_rows(screen, bg, fg, w, h)
      local texta, fga, bga = {}, {}, {}
      local idx = 0
      for y = 1, h do
        local trow, frow, brow = {}, {}, {}
        for x = 1, w do
          idx = idx + 1
          trow[x] = ch128[screen[idx]]
          frow[x] = blitColors[fg[idx]]
          brow[x] = blitColors[bg[idx]]
        end
        texta[y] = concat(trow)
        fga[y]   = concat(frow)
        bga[y]   = concat(brow)
      end
      return texta, fga, bga
    end
  
    local function draw_palette(target)
      for i = 0, 15 do
        local r = file.read() / 255
        local g = file.read() / 255
        local b = file.read() / 255
        target.setPaletteColor(pow2[i], r, g, b)
      end
    end
  
    local function present(monLike, texta, fga, bga, h)
      for y = 1, h do
        monLike.setCursorPos(1, y)
        monLike.blit(texta[y], fga[y], bga[y])
      end
    end
  
    local function wait_for_frame(start_ms, fno, fps)
      local deadline = start_ms + fno * 1000 / fps
      while true do
        local now = epoch("utc")
        local remain = deadline - now
        if remain <= 0 then return end
        if remain > 100 then sleep(0) else
        end
      end
    end
  
    mon.clear()
    mon.setCursorBlink(false)
    local start = epoch("utc")
    local lastyield = start
  
    for _ = 1, nframes do
      local size, ftype = ("<IB"):unpack(file.read(5))
  
      if ftype == 0 then
        if epoch("utc") - lastyield > 3000 then sleep(0); lastyield = epoch("utc") end
        init(false)
        local screen = read(width * height)
        init(true)
        local bg = read(width * height)
        local fg = read(width * height)
  
        wait_for_frame(start, vframe, fps)
  
        local texta, fga, bga = assemble_rows(screen, bg, fg, width, height)
        draw_palette(mon)
        present(mon, texta, fga, bga, height)
  
        local kill = {}
        for i, v in ipairs(subs) do
          if vframe >= v.frame and vframe <= v.frame + v.length then
            local w, h = sub.getSize()
            local lines = wrapText(v.text, w)
            sub.setBackgroundColor(colors.black)
            sub.setTextColor(colors.white)
            sub.clear()
            for j = 1, math.min(#lines, h) do sub.setCursorPos(1, j); sub.write(lines[j]) end
          elseif vframe > v.frame + v.length then kill[#kill + 1] = i end
        end
        for i2, v2 in ipairs(kill) do table.remove(subs, v2 - i2 + 1) end
  
        vframe = vframe + 1
  
      elseif ftype == 1 then
        local audio = file.read(size)
        for _, speaker in pairs(speakers) do
          if band(flags, 12) == 0 then
            local chunk = { audio:byte(1, -1) }
            for i = 1, #chunk do chunk[i] = chunk[i] - 128 end
            speaker.playAudio(chunk)
          else
            speaker.playAudio(dfpwm.decode(audio))
          end
        end
  
      elseif ftype == 8 then
        local data = file.read(size)
        local subrec = {}
        subrec.frame, subrec.length, subrec.x, subrec.y, subrec.color, subrec.flags, subrec.text = ("<IIHHBBs2"):unpack(data)
        subrec.bgColor, subrec.fgColor = pow2[rshift(subrec.color, 4)], pow2[band(subrec.color, 15)]
        subs[#subs + 1] = subrec
  
      elseif ftype >= 0x40 and ftype < 0x80 then
        if ftype == 64 then vframe = vframe + 1 end
        local mx, my = band(rshift(ftype, 3), 7) + 1, band(ftype, 7) + 1
        local termLike = monitors[my][mx]
        if epoch("utc") - lastyield > 3000 then sleep(0); lastyield = epoch("utc") end
        local tw, th = ("<HH"):unpack(file.read(4))
        init(false); local screen = read(tw * th)
        init(true);  local bg = read(tw * th); local fg = read(tw * th)
        wait_for_frame(start, vframe, fps)
        local texta, fga, bga = assemble_rows(screen, bg, fg, tw, th)
        for i = 0, 15 do termLike.setPaletteColor(pow2[i], file.read() / 255, file.read() / 255, file.read() / 255) end
        present(termLike, texta, fga, bga, th)
      else
        file.close(); error("Unknown frame type " .. tostring(ftype))
      end
    end
  
    for i = 0, 15 do mon.setPaletteColor(pow2[i], term.nativePaletteColor(pow2[i])) end
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.setCursorPos(1, 1)
    mon.clear()
  end
  