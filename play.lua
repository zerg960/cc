function(require, mon, speakers, path)
    function log2(n)
        local _, r = math.frexp(n)
        return r - 1
    end

    local dfpwm = require("cc.audio.dfpwm")

    function http_get_big(url, chunk_size)
        chunk_size = chunk_size or 10*1024*1024
        local r = http.get(url, {Range="bytes=0-0", ["Accept-Encoding"]="identity"}, true)
        local h = r.getResponseHeaders()
        local total = tonumber(r.getResponseHeaders()["Content-Range"]:match("/(%d+)$"))
        local ct = h["Content-Type"]
        r.readAll()
        r.close()

        local parts, got = {}, 0
        while got < total do
            local first = got
            local last = math.min(got + chunk_size - 1, total - 1)
            local rr = http.get(url, {Range=("bytes=%d-%d"):format(first, last), ["Accept-Encoding"]="identity"}, true)
            parts[#parts+1] = rr.readAll()    
            rr.close()
            got = last + 1
        end

        local body = table.concat(parts)
        local pos, open = 1, true
        local headers = {["Content-Length"]=tostring(#body)}
        if ct then headers["Content-Type"]=ct end
        local t = {}
        function t.readAll()
            if not open then
                return nil
            end
            open=false
            return body
        end

        function t.read(n)
            if not open then return nil end
            if n == nil or n == 1 then
            if pos > #body then open=false return nil end
            local b = string.byte(body, pos)
            pos = pos + 1
            if pos > #body then open=false end
            return b
            else
            local s = body:sub(pos, pos + n - 1)
            pos = pos + #s
            if pos > #body then open=false end
            if s == "" then return nil end
            return s
            end
        end
        
        function t.readLine(withTrailing)
            if not open then
                return nil
            end
            local a,b=body:find("\n",pos,true)
            if not a then
                local s=body:sub(pos)
                pos=#body+1
                open=false
                if s=="" then
                    return nil
                end
                return withTrailing and s.."\n" or s
            end
            
            local line=body:sub(pos,a-1)
            pos=b+1
            if line:sub(-1)=="\r" then
                line=line:sub(1,-2)
            end
            return withTrailing and line.."\n" or line
        end

        function t.close()
            open=false
        end

        function t.getResponseCode()
            return 200
        end

        function t.getResponseHeaders()
            return headers
        end

        return t
    end

    mon.setCursorBlink(false)  
    local file = assert(http_get_big(path))

    if file.read(4) ~= "32VD" then
        file.close()
        error("Invalid file")
    end
    
    local width, height, fps, nstreams, flags = ("<HHBBH"):unpack(file.read(8))
    if nstreams ~= 1 then file.close() error("Separate files unsupported") end
    if bit32.band(flags, 1) == 0 then file.close() error("unsupported compression method") end
    local _, nframes, ctype = ("<IIB"):unpack(file.read(9))
    if ctype ~= 0x0C then file.close() error("Stream type not supported") end

    local monitors, mawidth, maheight
    local function readDict(size)
        local retval = {}
        for i = 0, size - 1, 2 do
            local b = file.read()
            retval[i] = bit32.rshift(b, 4)
            retval[i+1] = bit32.band(b, 15)
        end
        return retval
    end

    local init, read
    if bit32.band(flags, 3) == 1 then
        local decodingTable, X, readbits, isColor
        function init(c)
            isColor = c
            local R = file.read()
            local L = 2^R
            local Ls = readDict(c and 24 or 32)
            if R == 0 then
                decodingTable = file.read()
                X = nil
                return
            end
            local a = 0
            for i = 0, #Ls do
                Ls[i] = Ls[i] == 0 and 0 or 2^(Ls[i]-1) a = a + Ls[i]
            end

            assert(a == L, a)
            decodingTable = {R = R}
            local x, step, next, symbol = 0, 0.625 * L + 3, {}, {}
            for i = 0, #Ls do
                next[i] = Ls[i]
                for _ = 1, Ls[i] do
                    while symbol[x] do x = (x + 1) % L end
                    x, symbol[x] = (x + step) % L, i
                end
            end

            for x = 0, L - 1 do
                local s = symbol[x]
                local t = {s = s, n = R - log2(next[s])}
                t.X, decodingTable[x], next[s] = bit32.lshift(next[s], t.n) - L, t, 1 + next[s]
            end

            local partial, bits, pos = 0, 0, 1
            function readbits(n)
                if not n then n = bits % 8 end
                if n == 0 then return 0 end
                while bits < n do pos, bits, partial = pos + 1, bits + 8, bit32.lshift(partial, 8) + file.read() end
                local retval = bit32.band(bit32.rshift(partial, bits-n), 2^n-1)
                bits = bits - n
                return retval
            end
            X = readbits(R)
        end

        function read(nsym)
            local retval = {}
            if X == nil then
                for i = 1, nsym do retval[i] = decodingTable end
                return retval
            end
            local i = 1
            local last = 0
            while i <= nsym do
                local t = decodingTable[X]
                if isColor and t.s >= 16 then
                    local l = 2^(t.s - 15)
                    for n = 0, l-1 do retval[i+n] = last end
                    i = i + l
                else retval[i], last, i = t.s, t.s, i + 1 end
                X = t.X + readbits(t.n)
            end
            return retval
        end
    else
        error("Unimplemented!")
    end

    local blitColors = {[0] = "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"}
    local start = os.epoch("utc")
    local lastyield = start
    local vframe = 0
    local subs = {}
    mon.clear()
    for _ = 1, nframes do
        local size, ftype = ("<IB"):unpack(file.read(5))
        if ftype == 0 then
            if os.epoch "utc" - lastyield > 3000 then sleep(0) lastyield = os.epoch "utc" end
            local dcstart = os.epoch "utc"
            init(false)
            local screen = read(width * height)
            init(true)
            local bg = read(width * height)
            local fg = read(width * height)
            local dctime = os.epoch "utc" - dcstart
            while os.epoch "utc" < start + vframe * 1000 / fps do end
            local texta, fga, bga = {}, {}, {}
            for y = 0, height - 1 do
                local text, fgs, bgs = "", "", ""
                for x = 1, width do
                    text = text .. string.char(128 + screen[y*width+x])
                    fgs = fgs .. blitColors[fg[y*width+x]]
                    bgs = bgs .. blitColors[bg[y*width+x]]
                end
                texta[y+1], fga[y+1], bga[y+1] = text, fgs, bgs
            end

            for i = 0, 15 do
                local r = file.read() / 255
                local g = file.read() / 255
                local b = file.read() / 255
                
                mon.setPaletteColor(2^i, r, g, b)
            end

            for y = 1, height do
                mon.setCursorBlink(false)
                mon.setCursorPos(1, y)
                mon.blit(texta[y], fga[y], bga[y])
            end
            local delete = {}
            for i, v in ipairs(subs) do
                if vframe <= v.frame + v.length then
                    mon.setCursorPos(v.x, v.y)
                    mon.setBackgroundColor(v.bgColor)
                    mon.setTextColor(v.fgColor)
                    mon.write(v.text)
                else delete[#delete+1] = i end
            end
            for i, v in ipairs(delete) do
                table.remove(subs, v - i + 1)
            end
            vframe = vframe + 1
        elseif ftype == 1 then
            local audio = file.read(size)
            for _, speaker in pairs(speakers) do
                if bit32.band(flags, 12) == 0 then
                    local chunk = {audio:byte(1, -1)}
                    for i = 1, #chunk do chunk[i] = chunk[i] - 128 end
                    speaker.playAudio(chunk)
                else
                    speaker.playAudio(dfpwm.decode(audio))
                end
            end
        elseif ftype == 8 then
            local data = file.read(size)
            local sub = {}
            sub.frame, sub.length, sub.x, sub.y, sub.color, sub.flags, sub.text = ("<IIHHBBs2"):unpack(data)
            sub.bgColor, sub.fgColor = 2^bit32.rshift(sub.color, 4), 2^bit32.band(sub.color, 15)
            subs[#subs+1] = sub
        elseif ftype >= 0x40 and ftype < 0x80 then
            if ftype == 64 then vframe = vframe + 1 end
            local mx, my = bit32.band(bit32.rshift(ftype, 3), 7) + 1, bit32.band(ftype, 7) + 1
            local term = monitors[my][mx]
            if os.epoch("utc") - lastyield > 3000 then sleep(0) lastyield = os.epoch("utc") end
            local width, height = ("<HH"):unpack(file.read(4))
            local dcstart = os.epoch("utc")
            init(false)
            local screen = read(width * height)
            init(true)
            local bg = read(width * height)
            local fg = read(width * height)
            local dctime = os.epoch("utc") - dcstart
            while os.epoch("utc") < start + vframe * 1000 / fps do end
            local texta, fga, bga = {}, {}, {}
            for y = 0, height - 1 do
                local text, fgs, bgs = "", "", ""
                for x = 1, width do
                    text = text .. string.char(128 + screen[y*width+x])
                    fgs = fgs .. blitColors[fg[y*width+x]]
                    bgs = bgs .. blitColors[bg[y*width+x]]
                end
                texta[y+1], fga[y+1], bga[y+1] = text, fgs, bgs
            end

            for i = 0, 15 do
                term.setPaletteColor(2^i, file.read() / 255, file.read() / 255, file.read() / 255)
            end
            for y = 1, height do
                term.setCursorPos(1, y)
                term.blit(texta[y], fga[y], bga[y])
            end
        else file.close() error("Unknown frame type " .. ftype) end
    end

    for i = 0, 15 do
        mon.setPaletteColor(2^i, term.nativePaletteColor(2^i))
    end
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.setCursorPos(1, 1)
    mon.clear()
end
