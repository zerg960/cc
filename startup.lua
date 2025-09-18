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
    colors.bg = colors.green
    colors.fg = colors.pink
    colors.btnbg = colors.orange
    colors.btnfg = colors.blue
    colors.accent = colors.lightBlue
    colors.accentfg = colors.lime

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
    term.clear()

    -- ===== Songs setup =====
    function ends_with(str, suffix)
        return suffix == "" or str:sub(-#suffix) == suffix
    end

    local songIndexUrl = "https://api.github.com/repos/" .. repo .. "/contents"
    local songNames = textutils.unserializeJSON(http.get(songIndexUrl).readAll())
    local songs = {}
    for i, file in ipairs(songNames) do
        if ends_with(file.name, ".dfpwm") then
            table.insert(songs, {
                text = file.name:gsub(".dfpwm", ""),
                name = file.name:gsub(".dfpwm", ""),
                fn = function()
                    return http.get(file.download_url).readAll()
                end
            })
        end
    end

    -- ===== Playback state =====
    local stopFlag = false
    local init = false

    local root = ui.getMainFrame()
        :initializeState("playing", false, true)
        :initializeState("shuffle", true, true)
        :initializeState("loop", 0, true) -- 0=Off,1=All,2=One
        :initializeState("offset", 0, true)
        :initializeState("current", "", true)
        :initializeState("never", {}, true)

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
    end):setState("never", root:getState("never"))

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
        contextMenu.width = 11
        contextMenu.x = math.min(main.width - 11, x)
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

        for i, song in ipairs(songs) do
            if song.name == newValue then
                song.selected = true
            end
        end
        
        stopFlag = true
        if init then
            root:setState("playing", true)
        end
        nowPlaying.text = newValue or "(None)"
    end):setState("current", root:getState("current"))
    :initializeState("volume", math.floor(root.width / 3) - 1, false)

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
        playing.text = newValue and " Playing " or " Stopped "
        if not newValue then
           stopFlag = true
        end
    end):setState("playing", root:getState("playing"))

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

        local idx = 1
        for i,s in ipairs(songs) do if s.name==root:getState("current") then idx=i end end
        if root:getState("shuffle") then
            root:setState("current", songs[math.random(#songs)].name)
        else
            if idx < #songs then
                root:setState("current", songs[idx+1].name)
            else
                root:setState("current", songs[1].name)
            end
        end
        stopFlag = true
        root:setState("playing", true)
    end)

    local volumeLabel = buttons:addLabel({
        y = 3, text = "Vol: 100%",
        background = colors.bg,
        foreground = colors.fg,
    })
    local volume = buttons:addSlider({
        y = 3, x = 1 + volumeLabel.width,
        width = buttons.width - volumeLabel.width,
        foreground = colors.btnfg,
        background = colors.bg,
        barColor = colors.btnbg,
        sliderColor = colors.accent,
        backgroundEnabled = true
    }):bind("step", "volume")
    root:onStateChange("volume", function(self, newValue)
        volumeLabel.text = "Vol: " .. volume:getValue() .. "%"
    end):setState("volume", root:getState("volume"))

    
    function hideAll()
        main.visible = false
    end
    local menu = root:addMenu({
        background = colors.btnbg,
        foreground = colors.btnfg,
        selectedBackground = colors.accent,
        selectedForeground = colors.accentfg,
        height = menuHeight,
        items = {
            {
                text = "Zerg's Music Player",
                selected = true,
                callback = function()
                    hideAll()
                    main.visible = true
                end
            }},
        width = root.width,
    })

    init = true
    
    local function playerLoop()
        local function anyPlayable()
            for _, s in ipairs(songs) do if not s.neverPlay then return true end end
            return false
        end

        local function indexOf(name)
            for i, s in ipairs(songs) do if s.name == name then return i end end
            return nil
        end

        local function pickRandomPlayable()
            local pool = {}
            for _, s in ipairs(songs) do
                if not s.neverPlay then pool[#pool+1] = s end
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
                if not songs[i].neverPlay then
                    return songs[i], i
                end
                steps = steps + 1
                if wrap and i == start then break end
            end
            return nil
        end

        local function advanceToNext()
            if not anyPlayable() then
                root:setState("current", "")
                root:setState("playing", false)
                return
            end

            local loopMode = root:getState("loop")
            local doShuffle = root:getState("shuffle")
            local curName = root:getState("current")
            local curIdx = indexOf(curName) or 0

            if doShuffle then
                local s = pickRandomPlayable()
                if s then root:setState("current", s.name); root:setState("playing", true) end
                return
            end

            if loopMode == 1 then
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
            else
                if curIdx ~= 0 and not songs[curIdx].neverPlay then
                    return
                else
                    local s = nextSequentialPlayable(curIdx, true)
                    if s then root:setState("current", s.name); root:setState("playing", true)
                    else root:setState("current", ""); root:setState("playing", false) end
                    return
                end
            end
        end

        while true do
            local currentSong = songsList:getSelectedItem()
            if root:getState("current") ~= "" and root:getState("playing") then
                if currentSong.neverPlay then
                    advanceToNext()
                else
                    local decoder = dfpwm.make_decoder()
                    local songData = currentSong.fn()
                    local dataLen = #songData
                    for i = 1, dataLen, 8*1024 do
                        if stopFlag then break end
                        local chunk = songData:sub(i, math.min(i+8*1024-1, dataLen))
                        local buffer = decoder(chunk)
                        local pending = {}
    
                        for _, spk in pairs(speakers) do
                            if stopFlag then break end
                            if not spk.playAudio(buffer, volume:getValue() / 100) then
                                pending[peripheral.getName(spk)] = spk
                            end
                        end
    
                        while not stopFlag and next(pending) do
                            local _, name = os.pullEvent("speaker_audio_empty")
                            local spk = pending[name]
                            if spk and spk.playAudio(buffer, volume:getValue() / 100) then
                                pending[name] = nil
                            end
                        end
                    end
    
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

    parallel.waitForAny(playerLoop, ui.run)
end
