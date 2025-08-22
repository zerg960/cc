function()
  local songs = {}
  
  for _, title in pairs(textutils.unserialize(http.get("https://raw.githubusercontent.com/zerg960/cc/refs/heads/main/index.txt").readAll())) do
    print("Fetching " .. title)
  
    songs[title] = function()
      return http.get("https://raw.githubusercontent.com/zerg960/cc/refs/heads/main/" .. title:gsub(" ", "%%20") .. ".dfpwm").readAll()
    end
  end
  
  local dfpwm = require("cc.audio.dfpwm")
  local speaker = peripheral.find("speaker")
  
  while true do
    for title, songFn in pairs(songs) do
      print("Playing " .. title)
  
      local function play()
        local song = songFn()
        local dataLen = #song
        local decoder = dfpwm.make_decoder()
  
        for i = 1, dataLen, 16 * 1024 do
          local chunk = song:sub(i, math.min(i + 16 * 1024 - 1, dataLen))
          local buffer = decoder(chunk)
  
          for i = 1, #buffer do
            buffer[i] = buffer[i] * 0.25
          end
  
          while not speaker.playAudio(buffer) do
            os.pullEvent("speaker_audio_empty")
          end
        end
      end
  
      local function skip()
        os.pullEvent("mouse_click")
      end
  
      parallel.waitForAny(play, skip)
    end
  end
end
