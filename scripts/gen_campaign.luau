--[[
	Подбор seed'ов кампании. Для каждого уровня перебирает seed'ы спецификации и берёт те,
	где: уровень строится; решатель находит решение за k; полный перебор доказывает, что
	за k − 1 нельзя; бот по решению выигрывает по петлям; ожидание в решении в норме.
	Из кандидатов выбирается тот, у которого сложность D ближе к плавной кривой
	(не ниже прошлого уровня − 1, не выше + 4). Блок SEEDS в Campaign.luau переписывается.
	Запуск из корня: lune run scripts/gen_campaign.luau [первый уровень]
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local Loader = require("../tests/lib/Loader")

local Config = Loader.shared("Config")
local Level = Loader.shared("Level")
local Planner = Loader.shared("Planner")
local Campaign = Loader.shared("Campaign")

local CANDIDATES = 8
local from = tonumber(process.args[1]) or 1

local function accept(lv)
	local plan = Planner.solve(lv)
	if not plan then
		return nil
	end
	local m = plan.metrics
	if m.idleMax > Config.Plan.MaxIdle or m.idleMean > Config.Plan.MeanIdle then
		return nil
	end
	local lower = Planner.canWin(lv, lv.k - 1)
	if lower ~= false then
		return nil
	end
	local r = Planner.play(lv, "pro", { plan = plan })
	if not r.won or r.loop ~= lv.k or r.paradoxes > 0 then
		return nil
	end
	return plan
end

local seeds = table.clone(Campaign.Seeds)
local prevD = 0
local usedSeeds = {}
for n = 1, Campaign.Count do
	if n < from and seeds[n] then
		local lv = Level.generate(Campaign.Specs[n], seeds[n])
		local plan = lv and Planner.solve(lv)
		prevD = if plan then plan.metrics.D else prevD
		continue
	end
	local sp = Campaign.Specs[n]
	local cands = {}
	local t0 = os.clock()
	for a = 1, Config.Plan.MaxAttempts do
		local seed = n * 1000 + a
		local lv = Level.generate(sp, seed)
		if lv then
			local plan = accept(lv)
			if plan then
				table.insert(cands, { seed = seed, D = plan.metrics.D, m = plan.metrics })
				if #cands >= CANDIDATES then
					break
				end
			end
		end
	end
	if #cands == 0 then
		print(string.format("level %d: NO CANDIDATES (%.1fs)", n, os.clock() - t0))
		process.exit(1)
	end
	-- ближе к «чуть выше прошлого»; первый уровень главы — передышка (самый простой из кандидатов)
	local chStart = false
	for _, ch in Campaign.Chapters do
		if ch.first == n then
			chStart = true
		end
	end
	if chStart then
		local lo = math.huge
		for _, c in cands do
			lo = math.min(lo, c.D)
		end
		prevD = lo - 1.5
	end
	local target = prevD + 1.5
	table.sort(cands, function(a, b)
		local function cost(c)
			local d = c.D - target
			if c.D < prevD - 1 then
				d = (prevD - 1 - c.D) * 4 + 10
			elseif c.D > prevD + 4 then
				d = (c.D - prevD - 4) * 2 + 4
			end
			return math.abs(d)
		end
		local ca, cb = cost(a), cost(b)
		if ca ~= cb then
			return ca < cb
		end
		return a.seed < b.seed
	end)
	local c = cands[1]
	seeds[n] = c.seed
	usedSeeds[c.seed] = true
	prevD = math.max(prevD, c.D)
	print(
		string.format(
			"level %2d: seed %d  D=%.1f  k=%d relays=%d keys=%d depth=%d finish=%.1fs idle max %.1f mean %.1f  (%d cands, %.1fs)",
			n,
			c.seed,
			c.D,
			c.m.k,
			c.m.relays,
			c.m.keys,
			c.m.depth,
			c.m.finish,
			c.m.idleMax,
			c.m.idleMean,
			#cands,
			os.clock() - t0
		)
	)
end

local lines = { "-- SEEDS BEGIN (scripts/gen_campaign.luau)", "Campaign.Seeds = {" }
for n = 1, Campaign.Count do
	table.insert(lines, string.format("\t%d, -- %d", seeds[n], n))
end
table.insert(lines, "}")
table.insert(lines, "-- SEEDS END")
local path = "src/shared/Campaign.luau"
local src = fs.readFile(path)
local a = string.find(src, "-- SEEDS BEGIN", 1, true)
local _, b = string.find(src, "-- SEEDS END", 1, true)
src = string.sub(src, 1, a - 1) .. table.concat(lines, "\n") .. string.sub(src, b + 1)
fs.writeFile(path, src)
print("written " .. path)
