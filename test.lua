-- if peripheral.find("me_bridge") ~= nil then return end

local movies = {
  "hananinatte2.dat",
--  "hananinatte.dat"
}

--fs.delete("play.lua")
--shell.run("import")
fs.delete("deflate")
shell.run("import")
fs.move("deflate.lua", "deflate")

peripheral.find("monitor").setTextScale(1)

for _, movie in pairs(movies) do
-- for i = 1, 2 do local movie = movies[math.random(#movies)]
  shell.run("play_drive https://github.com/zerg960/cc/raw/refs/heads/main/" .. movie)
  read()
end
