local source = http.get("https://github.com/zerg960/cc/raw/refs/heads/main/startup.lua").readAll()
local fn = load("return " .. source, "code", "t", _G)
setfenv(fn, _G)
fn()(require, "zerg960/cc")
