function wrap(no)
  return peripheral.wrap("mysticalagriculture:infusion_pedestal_" .. no) or error("Pedestal " .. no .. " not found")
end

local pedestals = {
  N = wrap(19),
  E = wrap(25),
  S = wrap(23),
  W = wrap(26),
  NW = wrap(20),
  NE = wrap(21),
  SE = wrap(22),
  SW = wrap(24)
}

local altar = peripheral.find("mysticalagriculture:infusion_altar") or error("No altar found")
pedestals["C"] = altar

local provider = "expandedae:exp_pattern_provider_0"
local me = "turtle_12"

local inv = {}

function Group(list)
  local result = {}
  for _, value in ipairs(list) do
    result[value] = true
  end
  return {
    ["count"] = function()
      for key, value in pairs(inv) do
        if result[key] ~= nil then
          return value
        end
      end
      return 0
    end,
    ["what"] = function()
      for key, value in pairs(inv) do
        if result[key] ~= nil then
          return key
        end
      end
      return nil
    end
  }
end

local group = {
  ["essence"] = Group({
    "insanium_essence",
    "insanium_block",
    "inferium_essence",
    "prudentium_essence",
    "tertium_essence",
    "imperium_essence",
    "supremium_essence",
    "awakened_supremium_essence"
  }),
  ["seed_base"] = Group({
    "prosperity_seed_base",
    "soulium_seed_base"
  })
}

function move(to, item)
  print("Move " .. item .. " to " .. to)
  if item:sub(1, 1) == "#" then
    item = group[item:sub(2)].what(inv)
  end

  for id in to:gmatch("([^,]+)") do
    pedestals[id].pullItems(me, inv["#" .. item], 1)
    inv[item] = inv[item] - 1
  end
end

function remaining()
  for key, value in pairs(inv) do
    if key:sub(1,1) ~= "#" and value ~= 0 then
      return key
    end
  end
end

function wait()
  while altar.list()[2] == nil do
    sleep(0.05) 
  end
  altar.pushItems(provider, 2)
end

local recipes = {}

table.insert(recipes, function()
  if group.seed_base.count() ~= 1 or
    group.essence.count() ~= 4 then
    return false
  end
  
  move("C", "#seed_base")
  move("N,E,S,W", "#essence")
  move("NE,NW,SE,SW", remaining())
  wait()
end)

while true do
  inv = {}
  for i = 1, 16 do
    local item = turtle.getItemDetail(i)
    if item ~= nil then
      local name = string.gsub(item.name, "mysticalagriculture:", "")
      inv[name] = item.count
      inv["#" .. name] = i
    end
  end

  for _, recipe in pairs(recipes) do
    if recipe() then
      break
    end
  end
  
  os.pullEvent("turtle_inventory")
end
