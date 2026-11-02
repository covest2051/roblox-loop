--[[
	Catalog — косметика, которую видят все игроки уровня:
	  • skin   — облик твоих призраков (материал и акцент; основной цвет — всегда цвет петли,
	             чтобы было видно, какой призрак из какой петли);
	  • trail  — след за тобой и твоими призраками;
	  • rewind — эффект перемотки (вспышка на месте каждого твоего тела в конце петли).
	Шансы капсулы считаются в целых «сотых процента» (Config.WeightTotal = 10000),
	поэтому показанные проценты точные.
]]

local Shared = script.Parent
local Config = require(Shared.Config)

local Catalog = {}

export type Item = {
	id: string,
	kind: "skin" | "trail" | "rewind",
	rarity: string, -- Common | Rare | Epic | Legendary | Default | Vip
	colors: { { number } }, -- акцентные цвета RGB
	material: string?, -- skin: plastic | glass | ice | neon | marble | forcefield | foil
	shape: string?, -- rewind: ring | spiral | clock | burst
	width: number?, -- trail
	rainbow: boolean?, -- цвет переливается (клиент)
}

Catalog.Kinds = { "skin", "trail", "rewind" }

Catalog.Items = {
	-- по умолчанию, у всех
	{
		id = "skin_classic",
		kind = "skin",
		rarity = "Default",
		colors = { { 255, 255, 255 } },
		material = "plastic",
	},
	{
		id = "trail_mist",
		kind = "trail",
		rarity = "Default",
		colors = { { 255, 255, 255 }, { 200, 220, 255 } },
		width = 0.8,
	},
	{
		id = "rewind_ring",
		kind = "rewind",
		rarity = "Default",
		colors = { { 255, 255, 255 } },
		shape = "ring",
	},
	-- Common
	{
		id = "skin_glass",
		kind = "skin",
		rarity = "Common",
		colors = { { 220, 245, 255 } },
		material = "glass",
	},
	{ id = "skin_ice", kind = "skin", rarity = "Common", colors = { { 170, 225, 255 } }, material = "ice" },
	{
		id = "trail_pink",
		kind = "trail",
		rarity = "Common",
		colors = { { 255, 130, 200 }, { 255, 220, 240 } },
		width = 1.2,
	},
	{
		id = "trail_mint",
		kind = "trail",
		rarity = "Common",
		colors = { { 110, 255, 180 }, { 220, 255, 240 } },
		width = 1.2,
	},
	{ id = "rewind_blue", kind = "rewind", rarity = "Common", colors = { { 90, 170, 255 } }, shape = "ring" },
	-- Rare
	{ id = "skin_neon", kind = "skin", rarity = "Rare", colors = { { 255, 255, 255 } }, material = "neon" },
	{
		id = "skin_marble",
		kind = "skin",
		rarity = "Rare",
		colors = { { 240, 235, 225 } },
		material = "marble",
	},
	{
		id = "trail_fire",
		kind = "trail",
		rarity = "Rare",
		colors = { { 255, 200, 50 }, { 255, 60, 20 } },
		width = 1.6,
	},
	{
		id = "rewind_spiral",
		kind = "rewind",
		rarity = "Rare",
		colors = { { 120, 255, 220 }, { 60, 140, 255 } },
		shape = "spiral",
	},
	-- Epic
	{
		id = "skin_hologram",
		kind = "skin",
		rarity = "Epic",
		colors = { { 120, 255, 255 } },
		material = "forcefield",
	},
	{
		id = "skin_shadow",
		kind = "skin",
		rarity = "Epic",
		colors = { { 30, 20, 50 }, { 190, 110, 255 } },
		material = "neon",
	},
	{
		id = "trail_comet",
		kind = "trail",
		rarity = "Epic",
		colors = { { 230, 245, 255 }, { 80, 120, 255 } },
		width = 2.2,
	},
	{
		id = "rewind_clock",
		kind = "rewind",
		rarity = "Epic",
		colors = { { 255, 230, 160 }, { 255, 160, 60 } },
		shape = "clock",
	},
	-- Legendary
	{
		id = "skin_prism",
		kind = "skin",
		rarity = "Legendary",
		colors = { { 255, 70, 70 }, { 255, 240, 70 }, { 70, 160, 255 } },
		material = "neon",
		rainbow = true,
	},
	{
		id = "rewind_galaxy",
		kind = "rewind",
		rarity = "Legendary",
		colors = { { 255, 70, 200 }, { 70, 160, 255 }, { 255, 240, 120 } },
		shape = "burst",
		rainbow = true,
	},
	-- только VIP
	{ id = "skin_gold", kind = "skin", rarity = "Vip", colors = { { 255, 200, 60 } }, material = "foil" },
	{
		id = "trail_gold",
		kind = "trail",
		rarity = "Vip",
		colors = { { 255, 220, 90 }, { 255, 170, 30 } },
		width = 1.8,
	},
	{ id = "rewind_gold", kind = "rewind", rarity = "Vip", colors = { { 255, 210, 80 } }, shape = "burst" },
}

Catalog.Default = { skin = "skin_classic", trail = "trail_mist", rewind = "rewind_ring" }

local byId: { [string]: Item } = {}
local byRarity: { [string]: { Item } } = {}
for _, item in Catalog.Items do
	byId[item.id] = item
	byRarity[item.rarity] = byRarity[item.rarity] or {}
	table.insert(byRarity[item.rarity], item)
end

function Catalog.get(id: string): Item?
	return byId[id]
end

function Catalog.ofRarity(rarity: string): { Item }
	return byRarity[rarity] or {}
end

-- Предмет можно получить из капсулы или купить (за монеты/Robux)
function Catalog.isTradable(item: Item): boolean
	return Config.Rarity[item.rarity] ~= nil
end

function Catalog.price(id: string): number?
	local item = byId[id]
	local r = item and Config.Rarity[item.rarity]
	return r and r.price
end

function Catalog.refund(id: string): number
	local item = byId[id]
	local r = item and Config.Rarity[item.rarity]
	return if r then r.refund else 0
end

--[[
	Точные шансы капсулы: { {id, rarity, bp} }, bp — сотые доли процента.
	Сумма bp = Config.WeightTotal. Вес редкости делится между её предметами поровну;
	тест проверяет, что деление без остатка.
]]
function Catalog.odds(): { { id: string, rarity: string, bp: number } }
	local out = {}
	for _, rarity in Config.RarityOrder do
		local items = byRarity[rarity] or {}
		local w = Config.Rarity[rarity].weight
		for _, item in items do
			table.insert(out, { id = item.id, rarity = rarity, bp = math.floor(w / #items) })
		end
	end
	return out
end

function Catalog.rarityPercent(rarity: string): string
	return Catalog.formatBp(Config.Rarity[rarity].weight)
end

-- 1250 → "12.5%", 560 → "5.6%", 100 → "1%"
function Catalog.formatBp(bp: number): string
	local s = string.format("%.2f", bp / 100)
	s = string.gsub(s, "0+$", "")
	s = string.gsub(s, "%.$", "")
	return s .. "%"
end

--[[
	Бросок капсулы. randInt(a, b) — целое в [a, b] (на сервере — Random.new():NextInteger).
	Возвращает id предмета.
]]
function Catalog.roll(randInt: (number, number) -> number): string
	local odds = Catalog.odds()
	local r = randInt(1, Config.WeightTotal)
	local acc = 0
	for _, o in odds do
		acc += o.bp
		if r <= acc then
			return o.id
		end
	end
	return odds[#odds].id
end

return Catalog
