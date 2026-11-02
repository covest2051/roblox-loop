--[[
	Campaign — 30 уровней кампании в 5 главах. Уровень = спецификация + seed.
	Seed'ы подобраны скриптом `lune run scripts/gen_campaign.luau` (он же переписывает блок
	SEEDS ниже): каждый уровень решается ровно за k «тебя» (решатель + полный перебор),
	ожидание в решении ≤ MaxIdle, сложность D растёт плавно. Тест solver.spec проверяет это
	для всех уровней — после правки генератора или решателя перезапусти скрипт.
]]

local Shared = script.Parent
local Level = require(Shared.Level)

local Campaign = {}

local function spec(k, rows, cols, switches, locks, wide)
	return {
		k = k,
		rows = rows,
		cols = cols,
		roomW = 3,
		roomH = 3,
		switches = switches,
		locks = locks,
		wide = wide,
	}
end

Campaign.Specs = {
	-- глава 1 «Первая петля»: двое «тебя»
	spec(2, 2, 2, 0, 0),
	spec(2, 2, 3, 0, 0),
	spec(2, 2, 3, 0, 1), -- первый ключ
	spec(2, 2, 2, 1, 0), -- первая передача: подержи дверь и успей на плиту
	spec(2, 2, 3, 1, 0),
	spec(2, 2, 3, 1, 1),
	-- глава 2 «Трое»
	spec(3, 2, 2, 0, 0),
	spec(3, 2, 3, 0, 1),
	spec(3, 2, 3, 1, 0),
	spec(3, 2, 3, 1, 0, 0.5),
	spec(3, 2, 3, 1, 1),
	spec(3, 2, 4, 2, 0),
	-- глава 3 «Ключи и парадоксы»
	spec(3, 2, 3, 0, 2),
	spec(4, 2, 3, 0, 1),
	spec(3, 2, 4, 1, 1),
	spec(4, 2, 3, 1, 1),
	spec(4, 2, 4, 1, 1),
	spec(4, 2, 4, 1, 2),
	-- глава 4 «Ограбление»
	spec(4, 2, 4, 2, 0),
	spec(4, 3, 3, 2, 0),
	spec(4, 2, 4, 2, 1),
	spec(4, 3, 3, 2, 1),
	spec(4, 3, 3, 3, 0),
	spec(4, 3, 3, 2, 1, 0.4),
	-- глава 5 «Пятеро»
	spec(5, 2, 4, 1, 1),
	spec(5, 3, 3, 2, 0),
	spec(5, 2, 4, 2, 1),
	spec(5, 3, 3, 2, 1),
	spec(5, 3, 3, 3, 0),
	spec(5, 3, 3, 3, 1),
}

Campaign.Chapters = {
	{ key = "chapter.1", first = 1, last = 6 },
	{ key = "chapter.2", first = 7, last = 12 },
	{ key = "chapter.3", first = 13, last = 18 },
	{ key = "chapter.4", first = 19, last = 24 },
	{ key = "chapter.5", first = 25, last = 30 },
}

-- Подсказки-обучение на первых уровнях (ключи Strings)
Campaign.Tips = {
	[1] = "tip.1",
	[2] = "tip.2",
	[3] = "tip.3",
	[4] = "tip.4",
	[5] = "tip.5",
	[7] = "tip.7",
	[9] = "tip.9",
	[13] = "tip.13",
}

-- SEEDS BEGIN (scripts/gen_campaign.luau)
Campaign.Seeds = {
	1001, -- 1
	2001, -- 2
	3001, -- 3
	4020, -- 4
	5040, -- 5
	6364, -- 6
	7001, -- 7
	8002, -- 8
	9013, -- 9
	10005, -- 10
	11003, -- 11
	12027, -- 12
	13021, -- 13
	14008, -- 14
	15042, -- 15
	16026, -- 16
	17021, -- 17
	18019, -- 18
	19015, -- 19
	20046, -- 20
	21224, -- 21
	22091, -- 22
	23141, -- 23
	24161, -- 24
	25013, -- 25
	26005, -- 26
	27058, -- 27
	28186, -- 28
	29047, -- 29
	30264, -- 30
}
-- SEEDS END

Campaign.Count = #Campaign.Specs

local cache = {}

-- Уровень n кампании (кэш). nil — нет такого или seed ещё не подобран.
function Campaign.level(n: number)
	if cache[n] then
		return cache[n]
	end
	local sp, seed = Campaign.Specs[n], Campaign.Seeds[n]
	if not sp or not seed then
		return nil
	end
	local lv = Level.generate(sp, seed)
	if lv then
		lv.number = n
		cache[n] = lv
	end
	return lv
end

function Campaign.chapterOf(n: number): number
	for i, c in Campaign.Chapters do
		if n >= c.first and n <= c.last then
			return i
		end
	end
	return #Campaign.Chapters
end

return Campaign
