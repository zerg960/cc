function(require, repo)
    function dump(obj)
        local keyset={}
        local n=0

        for k,v in pairs(obj) do
            n=n+1
            keyset[n]=k
        end
        print(textutils.serialize(keyset))
        read()
    end
    
    function old()
        local dfpwm = require("cc.audio.dfpwm")
        local speakers = { peripheral.find("speaker") }
        if not peripheral.find("speaker") then error("No speaker(s) attached. Maybe this isn't a *noisy* pocket computer?") end
        
        local mon = peripheral.find("monitor")
        if mon then
            term.redirect(mon)
            if mon.setTextScale then mon.setTextScale(1) end
            mon.clear()
        end

        local ui = require("/basalt")
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()

        -- ===== Songs setup =====
        local songIndexUrl = "https://raw.githubusercontent.com/" .. repo .. "/refs/heads/main/index.txt"
        local songNames = textutils.unserialize(http.get(songIndexUrl).readAll())
        local songs = {}
        for i, name in ipairs(songNames) do
            table.insert(songs, {
                text = name,
                name = name,
                fn = function()
                    local url = "https://raw.githubusercontent.com/" .. repo .. "/refs/heads/main/" .. textutils.urlEncode(name):gsub("+", "%%20") .. ".dfpwm"
                    return http.get(url).readAll()
                end
            })
        end

        -- ===== Playback state =====
        local savedName = settings.get("currentSong", nil)
        local currentSong = nil
        
        if savedName ~= nil then
            for _, song in ipairs(songs) do
                if song.name == savedName then
                    currentSong = song
                    break
                end
            end
        end
        
        local playing = settings.get("playing", false)
        local stopFlag = false
        local shuffle = settings.get("shuffle", true)
        local loopMode = settings.get("loopMode", 0) -- 0=Off,1=All,2=One
        local volume = .35
        local decoder = dfpwm.make_decoder()
        local currentPage = settings.get("currentPage", 1)
        local width, height = term.getSize()
        local topRows = 2
        local bottomRows = 5 -- reserve bottom 5 lines
        local songsPerPage = height - topRows - bottomRows
        
        -- Button storage for click detection
        local buttons = {}
        
        -- ===== UI functions =====
        local function totalPages()
            return math.max(1, math.ceil(#songs / songsPerPage))
        end
        
        local function drawUI()
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.clear()
        
            -- Now Playing
            term.setCursorPos(2,1)
            term.write("Now Playing: " .. (currentSong and currentSong.name or "(none)"))
        
            -- Song list (paged)
            local startIdx = (currentPage-1)*songsPerPage + 1
            local y = 3
            for i=startIdx, math.min(startIdx+songsPerPage-1, #songs) do
                term.setCursorPos(2,y)
                term.setTextColor((currentSong==songs[i]) and colors.yellow or colors.white)
                term.write(songs[i].name)
                y = y + 1
            end
        
            -- Reserve a blank line
            y = y + 1
        
            -- Bottom controls (4 lines)
            buttons = {} -- reset button list
            local btnLines = {
                {"Shuffle: "..(shuffle and "On" or "Off"), "Loop: "..({[0]="Off",[1]="All",[2]="One"})[loopMode]},
                {"Page "..currentPage.."/"..totalPages(), "Prev","Next"},
                {(playing and "Playing" or "Stopped"), "Skip"},
                {"-","Volume: "..math.floor(volume*100).."%","+",""}
            }
        
            local startY = height - bottomRows + 1
            for lineIdx, line in ipairs(btnLines) do
                local x = 2
                local y = startY + lineIdx - 1
                for i, btn in ipairs(line) do
                    if #btn>0 then
                        local btnStartX = x
                        term.setCursorPos(btnStartX,y)
                        term.setBackgroundColor(colors.gray)
                        term.setTextColor(colors.white)
                        term.write(" "..btn.." ")
                        local btnEndX = btnStartX + #btn + 1
                        -- Store button for click detection
                        table.insert(buttons,{
                            line=lineIdx, text=btn, x1=btnStartX, x2=btnEndX
                        })
                        x = btnEndX + 2
                    end
                end
            end
        end
        
        -- ===== Input loop =====
        local function inputLoop()
            drawUI()
            while true do
                local e, button, x, y = os.pullEvent()
                if e=="mouse_click" then
                    -- Song list tap
                    local startIdx = (currentPage-1)*songsPerPage + 1
                    for i=startIdx, math.min(startIdx+songsPerPage-1, #songs) do
                        local row = 3 + (i-startIdx)
                        if y==row then
                            currentSong = songs[i]
                            stopFlag = true
                            playing = true
                            drawUI()
                        end
                    end
        
                    -- Bottom controls click detection
                    for _, btn in ipairs(buttons) do
                        local btnY = (height - bottomRows + btn.line)
                        if y == btnY and x >= btn.x1 and x <= btn.x2 then
                            -- Identify which button was clicked
                            if btn.text:find("Shuffle") then shuffle = not shuffle
                            elseif btn.text:find("Loop") then loopMode = (loopMode+1)%3
                            elseif btn.text:find("Prev") and currentPage>1 then currentPage=currentPage-1
                            elseif btn.text:find("Next") and currentPage<totalPages() then currentPage=currentPage+1
                            elseif btn.text:find("Stopped") or btn.text:find("Playing") then
                                if playing then
                                    -- Pause
                                    stopFlag = true
                                    playing = false
                                else
                                    -- Resume/start
                                    if currentSong then
                                        playing = true
                                    end
                                end
                            elseif btn.text:find("Skip") then
                                if currentSong then
                                    local idx = 1
                                    for i,s in ipairs(songs) do if s==currentSong then idx=i end end
                                    if shuffle then
                                        currentSong = songs[math.random(#songs)]
                                    else
                                        if idx < #songs then
                                            currentSong = songs[idx+1]
                                        else
                                            currentSong = songs[1]
                                        end
                                    end
                                    stopFlag = true
                                    playing = true
                                end
                            elseif btn.text=="-" then volume = math.max(0,volume-0.05)
                            elseif btn.text=="+" then volume = math.min(1,volume+0.05)
                            end
                            drawUI()
                        end
                    end

                    settings.set("currentPage", currentPage)
                    settings.set("loopMode", loopMode)
                    settings.set("shuffle", shuffle)
                    settings.set("currentSong", currentSong and currentSong.name or "nil")
                    settings.set("playing", playing)
                    settings.save()
                end
            end
        end
        
        -- ===== Playback loop =====
        local function playerLoop()
            while true do
                if currentSong and playing then
                    local songData = currentSong.fn()
                    local dataLen = #songData
                    for i = 1, dataLen, 16*1024 do
                        if stopFlag then break end
                        local chunk = songData:sub(i, math.min(i+16*1024-1, dataLen))
                        local buffer = decoder(chunk)
                        local pending = {}
                        
                        for _, spk in pairs(speakers) do
                        if stopFlag then break end
                        if not spk.playAudio(buffer, volume) then
                            pending[peripheral.getName(spk)] = spk
                        end
                        end
                        
                        while not stopFlag and next(pending) do
                        local _, name = os.pullEvent("speaker_audio_empty")
                        local spk = pending[name]
                        if spk and spk.playAudio(buffer, volume) then
                            pending[name] = nil
                        end
                        end
                    end
        
                    if stopFlag then
                        stopFlag = false
                    else
                        -- Auto-advance
                        if loopMode == 2 then
                            -- loop current song
                        elseif shuffle then
                            currentSong = songs[math.random(#songs)]
                        elseif loopMode == 1 then
                            local idx = 1
                            for i,s in ipairs(songs) do if s==currentSong then idx=i end end
                            currentSong = songs[idx % #songs + 1]
                        else
                            local idx = 1
                            for i,s in ipairs(songs) do if s==currentSong then idx=i end end
                            if idx<#songs then currentSong = songs[idx+1] else currentSong = nil playing=false end
                        end
                        settings.set("currentSong", currentSong and currentSong.name or "nil")
                        settings.set("playing", playing)
                        settings.save()
                    end
                    drawUI()
                else
                    os.sleep(0.05)
                end
            end
        end
        
        parallel.waitForAny(playerLoop, inputLoop)
    end

    function installUiLibrary()
        local source = http.get("https://raw.githubusercontent.com/Pyroxenium/Basalt2/main/install.lua").readAll()
        local fn = load("return function(...)\n" .. source .. "\nend", "ui", "t", _ENV)
        local print = _ENV.print
        _ENV.print = function() end
        setfenv(fn, _ENV)
        fn()("-r")
        _ENV.print = print
    end
    installUiLibrary()

    if package == nil then
        -- update bootloader
        local bootloader = fs.open("/startup.lua", "w")
        bootloader.writeLine("--don't change this line; it's for automatic software updates")
        bootloader.writeLine("local source = (http.get(\"https://github.com/zerg960/cc/raw/refs/heads/main/startup2.lua\") or http.get(\"https://github.com/zerg960/cc/raw/refs/heads/main/startup.lua\")).readAll()")
        bootloader.writeLine("local fn = load(\"return \" .. source, \"code\", \"t\", _G)")
        bootloader.writeLine("setfenv(fn, _ENV)")
        bootloader.writeLine("")
        bootloader.writeLine("--(optional) edit this to")
        bootloader.writeLine("--set the default playlist")
        bootloader.writeLine("--used by the first run")
        bootloader.writeLine("fn()(require, \"" .. repo .. "\")")
        bootloader.close()
        old()
        return
    end

    -- compression stuff
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

    local char, byte, concat = string.char, string.byte, table.concat
    local min, max, floor = math.min, math.max, math.floor
    local http_get, inflate_stream
    local root

    local function makeVideoPlayer()
        local char, byte, concat = string.char, string.byte, table.concat
        local bor, band, lshift, rshift = bit32.bor, bit32.band, bit32.lshift, bit32.rshift
        local min, max, floor = math.min, math.max, math.floor
        local epoch = os.epoch
        local pow2 = {}
        for i = 0, 15 do pow2[i] = 2^i end
    
        local function log2(n) local _, r = math.frexp(n); return r - 1 end
        
        local function ends_with(str, suffix)
            return suffix == "" or str:sub(-#suffix) == suffix
        end

        local ch128 = {}
        for i = 0, 255 do ch128[i] = char(128 + (i % 128)) end
        local blitColors = {[0] = "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"}
        
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

        local _texta, _fga, _bga = {}, {}, {}
        local _trow,  _frow, _brow = {}, {}, {}

        local function assemble_rows(screen, bg, fg, w, h)
            local texta, fga, bga = _texta, _fga, _bga
            local trow,  frow, brow = _trow, _frow, _brow
            local idx = 0
            for y = 1, h do
                for x = 1, w do
                    idx = idx + 1
                    trow[x] = ch128[screen[idx]]
                    frow[x] = blitColors[fg[idx]]
                    brow[x] = blitColors[bg[idx]]
                end
                texta[y] = table.concat(trow, "", 1, w)
                fga[y]   = table.concat(frow, "", 1, w)
                bga[y]   = table.concat(brow, "", 1, w)
            end
            return texta, fga, bga
        end

        local function present(monLike, texta, fga, bga, h)
            for y = 1, h do
                monLike.setCursorPos(1, y + 1)
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
        
        local t = {}
        t.start = os.epoch("utc")
        t.running = false
        t.loadNext = nil
        
        local src, file, subFileRaw

        function t.onSoundStart()
            t.start = os.epoch("utc")
        end

        function t.stopPlayback()
            t.running = false
        end

        function t.load(path)
            t.running = false
            t.loadNext = path
        end
        
        function t.doLoad(path)
            src = assert(http_get(path))
            file = ends_with(path, ".hqv") and src or inflate_stream(src, "gzip")
            local subPath = string.gsub(string.gsub(path, ".dat", ".sub"), ".hqv", ".sub")
            subFileRaw = http.get(subPath)
            t.running = true
        end
        
        function t.play()
            local magic = file.read(4)
            if magic ~= "32VD" then file.close(); error("Invalid magic header: " .. tostring(magic)) end
            local width, height, fps, nstreams, flags = ("<HHBBH"):unpack(file.read(8))
            if nstreams ~= 1 then file.close(); error("Separate files unsupported") end
            local _, nframes, ctype = ("<IIB"):unpack(file.read(9))
            if ctype ~= 0x0C then file.close(); error("Stream type not supported") end

        
            local vframe = 0
            local subs = {}
            if subFileRaw ~= nil then
                local data = subFileRaw.readAll();
                if data.sub(1, 1) ~= "{" then
                    data = string.reverse(data)
                end
                local subIn = textutils.unserialize(data)
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
        
        
            local function draw_palette(target)
                for i = 0, 15 do
                    local r = file.read() / 255
                    local g = file.read() / 255
                    local b = file.read() / 255
                    target.setPaletteColor(pow2[i], r, g, b)
                end
            end
        
            local start = t.start
            local lastyield = start
        
            local firstFrame = 1
            local function drain_to_now()
                local elapsed = epoch("utc") - start
                local target  = math.floor((elapsed * fps) / 1000)

                if vframe >= target then
                    return
                end

                while vframe < target and firstFrame < nframes do
                    if epoch("utc") - lastyield > 500 then sleep(0); lastyield = epoch("utc") end
                    local size, ftype = ("<IB"):unpack(file.read(5))
                    if size > 0 then file.read(size) end

                    firstFrame = firstFrame + 1
                    if ftype == 0 or ftype == 64 then
                    vframe = vframe + 1
                    end
                end
            end
            drain_to_now()
            
            
            for _ = firstFrame, nframes do
                local size, ftype = ("<IB"):unpack(file.read(5))
            
                if ftype == 0 then
                    if epoch("utc") - lastyield > 500 then sleep(0); lastyield = epoch("utc") end
                    if not t.running then break end

                    init(false)
                    local screen = read(width * height)
                    init(true)
                    local bg = read(width * height)
                    local fg = read(width * height)
            
                    wait_for_frame(start, vframe, fps)
            
                    local texta, fga, bga = assemble_rows(screen, bg, fg, width, height)
                    draw_palette(term)
                    present(term, texta, fga, bga, height)
            
                    local kill = {}
                    for i, v in ipairs(subs) do
                        if vframe >= v.frame and vframe <= v.frame + v.length then
                            local w, h = term.getSize()
                            local lines = wrapText(v.text, w)
                            lines[#lines + 1] = ""
                            term.setBackgroundColor(colors.bg)
                            term.setTextColor(colors.fg)
                            for j = 1, h do
                                term.setCursorPos(1, j + height + 1);
                                term.write((lines[j] or "  ") .. "                          ")
                            end
                        elseif vframe > v.frame + v.length then
                            kill[#kill + 1] = i
                            for j = 1, 6 do term.setCursorPos(1, j + height + 1); term.write("                          ") end
                        end
                    end
                    for i2, v2 in ipairs(kill) do table.remove(subs, v2 - i2 + 1) end
            
                    vframe = vframe + 1
                elseif ftype == 1 then
                    file.read(size)
                else
                    file.close(); error("Unknown frame type " .. tostring(ftype))
                end
            end
            t.stopPlayback()
        end

        function t.run()
            while true do
                if t.loadNext ~= nil then
                    local path = t.loadNext
                    t.loadNext = nil
                    t.doLoad(path)
                elseif not t.running then
                    coroutine.yield()
                elseif root:getState("current") ~= "" and root:getState("playing") then
                    t.play()
                else
                    coroutine.yield()
                end
            end
        end
        return t
    end
    local videoPlayer = makeVideoPlayer()

    inflate_stream = function(src, kind, in_chunk, out_max)
        local DEFLATE = require("deflate")

        kind     = kind or "raw"
        in_chunk = in_chunk or 64 * 1024
        out_max  = out_max  or 512 * 1024  -- bigger to reduce yields/backpressure

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

    http_get = function(url)
      local r = http.get(url, { Range = "bytes=0-0", ["Accept-Encoding"] = "identity" }, true) or error("404")
      local h = r.getResponseHeaders()
      local total = tonumber(h["Content-Range"]:match("/(%d+)$"))
      total = min(limit or 50 * 1024 * 1024, total)
      r.readAll(); r.close()
  
      local parts, got = {}, 0
      local body
      if http[url] then
        body = http[url]
      else
      while got < total do
        local first = got
        local last = min(got + 10 * 1024 * 1024 - 1, total - 1)
        local rr = http.get(url, { Range = ("bytes=%d-%d"):format(first, last), ["Accept-Encoding"] = "identity" }, true)
        parts[#parts + 1] = rr.readAll(); rr.close()
        got = last + 1
      end
      body = concat(parts)
      http[url] = body
      end
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
    --
    
    local dfpwm = require("cc.audio.dfpwm")
    local speakers = { peripheral.find("speaker") }
    if not peripheral.find("speaker") then error("No speaker(s) attached. Maybe this isn't a *noisy* pocket computer?") end
    
    local mon = peripheral.find("monitor")
    if mon then
        term.redirect(mon)
        if mon.setTextScale then mon.setTextScale(1) end
        mon.clear()
    end

    local ui = require("/basalt")
    colors.bg = colors.lightBlue -- 3
    colors.fg = colors.pink -- 6
    colors.btnbg = colors.orange -- 1
    colors.btnfg = colors.blue -- 11
    colors.accent = colors.green -- 13
    colors.accentfg = colors.lime -- 5

    local function restore_colors()
        for k,v in pairs({
            [colors.bg]       = 0x0A0D14,
            [colors.fg]       = 0xEDEBF2,
            [colors.btnbg]    = 0x161B26,
            [colors.btnfg]    = 0xEDEBF2,
            [colors.accent]   = 0xC81D25,
            [colors.accentfg] = 0xFFF5F5,
        }) do
            term.setPaletteColor(k, v)
        end

        term.setBackgroundColor(colors.bg)
        term.setTextColor(colors.fg)
    end

    restore_colors()
    term.clear()

    -- ===== Songs setup =====
    function ends_with(str, suffix)
        return suffix == "" or str:sub(-#suffix) == suffix
    end

    local video
    local stopFlag = false
    local function dfpwm_player(songData, song)
        local decoder = dfpwm.make_decoder()
        local dataLen = #songData
        if song.has_video and video.visible then
            videoPlayer.load(song.has_video)
        end
        videoPlayer.onSoundStart()
        for i = 1, dataLen, 8*1024 do
            if stopFlag then break end
            local chunk = songData:sub(i, math.min(i+8*1024-1, dataLen))
            local buffer = decoder(chunk)
            local pending = {}

            for _, spk in pairs(speakers) do
                if stopFlag then break end
                if not spk.playAudio(buffer, math.min(volume / 2, 0.5)) then
                    pending[peripheral.getName(spk)] = spk
                end
            end

            while not stopFlag and next(pending) do
                local _, name = os.pullEvent("speaker_audio_empty")
                local spk = pending[name]
                if spk and spk.playAudio(buffer, math.min(volume / 2, 0.5)) then
                    pending[name] = nil
                end
            end
        end
    end
    local function hqs_player(rawStream, song)
        local READ_CHUNK = 64 * 1024
        local PLAY_CHUNK = 48 * 1024
        local PAUSE_SEC = 0.05
    
        local function wrap_s8(x) return ((x + 128) % 256) - 128 end
        local function zz_inv(n)
            local half = math.floor(n / 2)
            return ((n % 2) == 0) and half or -(half + 1)
        end
    
        local rle_waiting = false
        local stage = 0
        local s_im2, s_im1
        local out = {}
        local out_len = 0
    
        local function feed_pcm_s8(s)
            out_len = out_len + 1
            out[out_len] = s
        end
    
        local started = false
        local function flush_play_chunks(final)
            while (out_len >= PLAY_CHUNK) or (final and out_len > 0) do
                local take = math.min(out_len, PLAY_CHUNK)
                local chunk_tbl = {}
                for i = 1, take do chunk_tbl[i] = out[i] end
                if take < out_len then
                    local new = {}
                    local k = 0
                    for i = take + 1, out_len do k = k + 1; new[k] = out[i] end
                    out = new
                    out_len = k
                else
                    out = {}
                    out_len = 0
                end
                local pending = {}
                if not started then
                    videoPlayer.onSoundStart()
                    started = true
                end
                for _, spk in pairs(speakers) do
                    if stopFlag then break end
                    if not spk.playAudio(chunk_tbl, math.min(volume / 3 * 2, 0.66)) then
                        pending[peripheral.getName(spk)] = spk
                    end
                end
                while not stopFlag and next(pending) do
                    local _, name = os.pullEvent("speaker_audio_empty")
                    local spk = pending[name]
                    if spk and spk.playAudio(chunk_tbl, math.min(volume / 3 * 2, 0.66)) then
                        pending[name] = nil
                    end
                end
            end
        end
    
        local function feed_t(t)
            if stage == 0 then
                s_im2 = wrap_s8(t)
                feed_pcm_s8(s_im2)
                stage = 1
            elseif stage == 1 then
                local s1 = wrap_s8(s_im2 + t)
                feed_pcm_s8(s1)
                s_im1 = s1
                stage = 2
            else
                local prevDelta = wrap_s8(s_im1 - s_im2)
                local newDelta = wrap_s8(prevDelta + t)
                local s = wrap_s8(s_im1 + newDelta)
                feed_pcm_s8(s)
                s_im2, s_im1 = s_im1, s
            end
        end
    
        if song.has_video and video.visible then
            videoPlayer.load(song.has_video)
        end
        while not stopFlag do
            local chunk = rawStream.read and rawStream.read(READ_CHUNK) or rawStream.readAll()
            if not chunk or #chunk == 0 then break end
            local pos, n = 1, #chunk
            while pos <= n and not stopFlag do
                local b = chunk:byte(pos); pos = pos + 1
                if rle_waiting then
                    local count = b
                    for _ = 1, count do
                        feed_t(0)
                        if out_len >= PLAY_CHUNK then flush_play_chunks(false) end
                        if stopFlag then break end
                    end
                    rle_waiting = false
                else
                    if b == 0 then
                        rle_waiting = true
                    else
                        feed_t(zz_inv(b))
                        if out_len >= PLAY_CHUNK then flush_play_chunks(false) end
                    end
                end
            end
            os.sleep(PAUSE_SEC)
        end
    
        flush_play_chunks(true)
        if rawStream.close then pcall(rawStream.close, rawStream) end
    end
   

    local songIndexUrl = "https://api.github.com/repos/" .. repo .. "/contents"
    local songNames = textutils.unserializeJSON(http.get(songIndexUrl).readAll())
    local byBase = {}
    
    local function make_rec(base, url, is_hqs)
        local buffer = nil
        local result;
        result = {
            text = base,
            name = base,
            is_hqs = is_hqs,
            has_video = false,
            play = function()
                if is_hqs then
                    local zstream = inflate_stream(http_get(url), "gzip")
                    hqs_player(zstream, result)
                else
                    if buffer == nil then
                        buffer = http.get(url).readAll()
                    end
                    dfpwm_player(buffer, result)
                end
            end
        }
        return result
    end

    for _, file in ipairs(songNames) do
        local name = file.name
        local lname = name:lower()

        if ends_with(lname, ".hqs") then
            local base = name:gsub("%.hqs$", "")
            byBase[base] = make_rec(base, file.download_url, true)
        elseif ends_with(lname, ".dfpwm") then
            local base = name:gsub("%.dfpwm$", "")
            if not byBase[base] then
                byBase[base] = make_rec(base, file.download_url, false)
            end
        end
    end

    for _, file in ipairs(songNames) do
        local name = file.name
        local lname = name:lower()

        if ends_with(lname, ".hqv") then
            local base = name:gsub("%.hqv$", "")
            if byBase[base] then
                byBase[base].has_video = file.download_url
            end
        end
    end

    local songs = {}
    for _, rec in pairs(byBase) do table.insert(songs, rec) end
    table.sort(songs, function(a, b) return a.text:lower() < b.text:lower() end)
    
    for _, song in ipairs(songs) do
        if song.has_video then
            song.text = "\164" .. song.text
        end
    end

    -- ===== Playback state =====
    local init = false

    root = ui.getMainFrame()
        :initializeState("playing", false, true)
        :initializeState("shuffle", true, true)
        :initializeState("loop", 0, true) -- 0=Off,1=All,2=One
        :initializeState("offset", 0, true)
        :initializeState("current", "", true)
        :initializeState("never", {}, true)
        :initializeState("queue", {}, true)
    
    -- Main screen
    local menuHeight = 1
    local main = root:addFrame({
        y = 1 + menuHeight,
        width = root.width,
        height = root.height - menuHeight
    })

    local buttons = main:addFrame({
        y = 1 + main.height - 5,
        width = main.width,
        height = 5,
        background = colors.bg
    })
    local banQueueLabel = buttons:addLabel({
        background = colors.bg,
        foreground = colors.fg,
    })

    function updateBanQueueLabel()
        local excludedCt = 0
        for _, _ in pairs(root:getState("never")) do
            excludedCt = excludedCt + 1
        end
        
        local queuedCt = #root:getState("queue")

        local text
        if queuedCt > 0 then
            text = "Queued: " .. queuedCt
        else
            text = "Exclude: " .. excludedCt
        end
        banQueueLabel.x = buttons.width - #text
        banQueueLabel.text = text
    end

    local songsList = main:addList({
        items = songs,
        width = main.width - 1,
        height = main.height - buttons.height,
        background = colors.bg,
        foreground = colors.fg,
        selectedBackground = colors.accent,
        selectedForeground = colors.accentfg
    }):bind("offset")
    root:onStateChange("never", function(self, newValue)
        for _, song in ipairs(songs) do
            song.neverPlay = newValue[song.name]
            song.foreground = song.neverPlay and colors.btnbg or nil
            song.selectedForeground = song.neverPlay and colors.btnbg or nil
        end
        updateBanQueueLabel()
    end):setState("never", root:getState("never"))
    root:onStateChange("queue", function(self, newValue)
        updateBanQueueLabel()
    end):setState("queue", root:getState("queue"))

    local contextMenu = main:addList({
        visible = false,
        background = colors.btnfg,
        foreground = colors.btnbg
    })
    songsList:onSelect(function(self, index, item)
        if contextMenu.visible then
            local selected = root:getState("current")
            for _, song in ipairs(songs) do
                song.selected = song.name == selected
            end
        else
            root:setState("current", item.name)
        end
    end)
    
    root:onStateChange("offset", function()
        contextMenu.visible = false
    end)
    root:onClick(function(self, button)
        contextMenu.visible = false
    end)
    songsList:onClick(function(self, button, x, y)
        if button ~= 2 then return end
        
        local _, index = self:getRelativePosition(x, y)
        local adjustedIndex = index + self.offset
        local song = songs[adjustedIndex]

        contextMenu.visible = true
        contextMenu.y = y
        contextMenu.items = {
            {
                text = " Add to Queue ",
                callback = function()
                    local queue = root:getState("queue")
                    queue[#queue + 1] = song.name
                    root:setState("queue", queue)
                end
            },
            {
                text = root:getState("never")[song.name] and " Include " or " Exclude ",
                callback = function()
                    local never = root:getState("never")
                    if never[song.name] then
                        never[song.name] = nil
                    else
                        never[song.name] = true
                    end
                    root:setState("never", never)
                end
            }
        }
        contextMenu.height = #contextMenu.items
        contextMenu.width = 14
        contextMenu.x = math.min(main.width - contextMenu.width, x)
    end)

    local nowPlaying = buttons:addLabel({
        y = 5,
        background = colors.bg,
        foreground = colors.fg,
    })
    root:onStateChange("current", function(self, newValue)
        local old = songsList:getSelectedItem()
        if old ~= nil then
            old.selected = false
        end

        local text = newValue or "(None)"
        for i, song in ipairs(songs) do
            if song.name == newValue then
                song.selected = true
            end
        end
        
        stopFlag = true
        videoPlayer.stopPlayback()
        if init then
            root:setState("playing", true)
        end
        nowPlaying.text = text
    end):initializeState("volume", math.floor(root.width / 3) - 1, true)

    main:addLabel({
        x = 1 + main.width - 1,
        z = 2,
        text = "\30",
        height = 1,
        background = colors.bg,
        foreground = colors.fg,
        backgroundEnabled = true
    }):onClick(function()
        root:setState("offset", math.max(0, songsList.offset - songsList.height))
    end)
    
    main:addLabel({
        x = 1 + main.width - 1,
        y = songsList.height,
        z = 2,
        text = "\31",
        background = colors.bg,
        foreground = colors.fg,
        backgroundEnabled = true
    }):onClick(function()
        root:setState("offset", math.min(#songs - songsList.height, songsList.offset + songsList.height))
    end)

    main:addScrollBar({
        x = main.width,
        y = 2,
        height = songsList.height - 2,
        property = "offset",
        value = root:getState("offset"),
        background = colors.bg,
        foreground = colors.fg,
        symbol = "#",
        symbolColor = colors.accent,
        symbolBackgroundColor = colors.bg,
        handleSize = 2
    }):attach(songsList, {
        property = "offset",
        min = 0,
        max = math.max(1, #songs - songsList.height),
     })

    local shuffle = buttons:addLabel({
        y = 1,
        foreground = colors.btnfg,
        background = colors.btnbg,
        backgroundEnabled = true
    }):onClick(function()
        root:setState("shuffle", not root:getState("shuffle"))
    end)
    root:onStateChange("shuffle", function(self, newValue)
        shuffle.text = " Shuffle: " .. (newValue and "On " or "Off") .. " "
    end):setState("shuffle", root:getState("shuffle"))

    local loop = buttons:addLabel({
        y = 1, x = 1 + shuffle.width + 1,
        foreground = colors.btnfg,
        background = colors.btnbg,
        backgroundEnabled = true
    }):onClick(function()
        root:setState("loop", (root:getState("loop") + 1) % 3)
    end)
    root:onStateChange("loop", function(self, newValue)
        loop.text = " Loop: " .. ({[0]="Off", [1]="All", [2]="One"})[newValue] .. " "
    end):setState("loop", root:getState("loop"))

    local playing = buttons:addLabel({
        y = 2,
        foreground = colors.btnfg,
        background = colors.btnbg,
        backgroundEnabled = true
    }):onClick(function()
        if root:getState("playing") then
            root:setState("playing", false)
        else
            if root:getState("current") ~= "" then
                root:setState("playing", true)
            end
        end
    end)
    root:onStateChange("playing", function(self, newValue)
        playing.text = newValue and "Playin" or " Stop "
        if not newValue then
           stopFlag = true
        end
        videoPlayer.stopPlayback()
    end):setState("playing", root:getState("playing"))

    local videoTab
    local function advanceToNext()
        local function anyPlayable()
            for _, s in ipairs(songs) do
                if not s.neverPlay and (not video.visible or s.has_video) then
                    return true
                end
            end
            return false
        end

        local function indexOf(name)
            for i, s in ipairs(songs) do
                if s.name == name then return i end
            end
            return nil
        end

        local function pickRandomPlayable()
            local pool = {}
            for _, s in ipairs(songs) do
                if not s.neverPlay and (not video.visible or s.has_video) then
                    pool[#pool+1] = s
                end
            end
            if #pool == 0 then return nil end
            return pool[math.random(#pool)]
        end

        local function nextSequentialPlayable(fromIdx, wrap)
            local n = #songs
            if n == 0 then return nil end
            local start = fromIdx or 0
            local i = start
            local steps = 0
            while steps < n do
                i = i + 1
                if i > n then
                    if not wrap then return nil end
                    i = 1
                end
                local s = songs[i]
                if not s.neverPlay and (not video.visible or s.has_video) then
                    return s, i
                end
                steps = steps + 1
                if wrap and i == start then break end
            end
            return nil
        end

        if not anyPlayable() then
            root:setState("current", "")
            root:setState("playing", false)
            return
        end

        local currentSong = songsList:getSelectedItem()
        local loopMode = root:getState("loop")
        local doShuffle = root:getState("shuffle")
        local curName = root:getState("current")
        local curIdx = indexOf(curName) or 0
        local queue = root:getState("queue")

        if #queue > 0 then
            local s = table.remove(queue, 1)
            root:setState("current", s)
            root:setState("playing", true)
            root:setState("queue", queue)
        elseif loopMode == 2 then
            if currentSong ~= nil and not currentSong.neverPlay then
                if video.visible and not currentSong.has_video then
                    local s = nextSequentialPlayable(curIdx, true)
                    if s then
                        root:setState("current", s.name)
                        root:setState("playing", true)
                    else
                        root:setState("current", "")
                        root:setState("playing", false)
                    end
                end
                return
            else
                local s = nextSequentialPlayable(curIdx, true)
                if s then
                    root:setState("current", s.name)
                    root:setState("playing", true)
                else
                    root:setState("current", "")
                    root:setState("playing", false)
                end
                return
            end
        elseif doShuffle then
            local s = pickRandomPlayable()
            if s then root:setState("current", s.name); root:setState("playing", true) end
            return
        elseif loopMode == 1 then
            local s = nextSequentialPlayable(curIdx, true)
            if s then root:setState("current", s.name); root:setState("playing", true) end
            return
        elseif loopMode == 0 then
            local s = nextSequentialPlayable(curIdx, false)
            if s then
                root:setState("current", s.name)
                root:setState("playing", true)
            else
                root:setState("current", "")
                root:setState("playing", false)
            end
            return
        end
    end

    buttons:addLabel({
        y = 2, x = 1 + playing.width + 1,
        text = " Skip ",
        foreground = colors.btnfg,
        background = colors.btnbg,
        backgroundEnabled = true
    }):onClick(function()
        if root:getState("current") == "" then
            return
        end
        
        advanceToNext()
        stopFlag = true
        videoPlayer.stopPlayback()
        root:setState("playing", true)
    end)
    banQueueLabel.y = 2

    local volumeLabel = buttons:addLabel({
        y = 3, text = "Vol: 100%",
        background = colors.bg,
        foreground = colors.fg,
    })
    local volumeSlider = buttons:addSlider({
        y = 3, x = 1 + volumeLabel.width,
        width = buttons.width - volumeLabel.width,
        foreground = colors.btnfg,
        background = colors.bg,
        barColor = colors.btnbg,
        sliderColor = colors.accent,
        backgroundEnabled = true
    }):bind("step", "volume")
    root:onStateChange("volume", function(self, newValue)
        volumeLabel.text = "Vol: " .. volumeSlider:getValue() .. "%"
        volume = volumeSlider:getValue() / 100
    end):setState("volume", root:getState("volume"))

    
    -- Video Player
    video = root:addFrame({
        y = 1 + menuHeight,
        width = root.width,
        height = root.height - menuHeight,
        visible = false,
        background = colors.bg,
        foreground = colors.fg,
    })
    
    function hideAll()
        videoPlayer.stopPlayback()
        main.visible = false
        video.visible = false
    end
    local menu
    menu = root:addMenu({
        background = colors.btnbg,
        foreground = colors.btnfg,
        selectedBackground = colors.accent,
        selectedForeground = colors.accentfg,
        height = menuHeight,
        items = {
            {
                text = "Zerg's Player",
                selected = true,
                callback = function()
                    hideAll()
                    os.sleep(0.1)
                    restore_colors()
                    main.visible = true
                    menu.background = colors.btnbg
                    menu.foreground = colors.btnfg
                    menu.selectedBackground = colors.accent
                    menu.selectedForeground = colors.accentfg
                end
            },
            {
                text = " ",
                separator = true
            }
        },
        width = root.width,
    })

    videoTab = {
        text = "Video",
        selected = false,
        callback = function()
            hideAll()
            video.visible = true
            menu.background = colors.bg
            menu.foreground = colors.fg
            menu.selectedBackground = colors.fg
            menu.selectedForeground = colors.bg

            local song = songsList:getSelectedItem()
            if song.has_video then
                videoPlayer.load(song.has_video)
            end
        end
    };
    
    root:onStateChange("current", function(self, newValue)
        local current = songsList:getSelectedItem()
        local desiredVisibility = current and current.has_video or false
        if desiredVisibility and not videoTab.visible then
            menu:addItem(videoTab)
        elseif not desiredVisibility and videoTab.visible then
            for i, item in ipairs(menu:getItems()) do
                if item == videoTab then
                    menu:removeItem(i)
                    break
                end
            end
        end
        videoTab.visible = desiredVisibility
    end):setState("current", root:getState("current"))

    init = true
    
    local function playerLoop()

        while true do
            local currentSong = songsList:getSelectedItem()
            if root:getState("current") ~= "" and root:getState("playing") then
                if currentSong.neverPlay then
                    advanceToNext()
                else
                    currentSong.play()

                    videoPlayer.stopPlayback()
    
                    if stopFlag then
                        stopFlag = false
                    else
                        advanceToNext()
                    end
                end
            else
                os.sleep(0.05)
            end
        end
    end

    parallel.waitForAny(playerLoop, videoPlayer.run, ui.run)
end
