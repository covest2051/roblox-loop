--[[
	Экспорт уровня кампании и его решения в JSON для картинки README:
	  lune run scripts/export_level.luau 22 build/level.json
	Клетки, двери, плиты, ключи, сокровище, старт; для каждого «я» — путь по шагам,
	когда он отпускает переключатель (hold), когда берёт ключ, где заканчивает петлю.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Loader = require("../tests/lib/Loader")

local Config = Loader.shared("Config")
local Campaign = Loader.shared("Campaign")
local Planner = Loader.shared("Planner")

local n = tonumber(process.args[1]) or 22
local out = process.args[2] or "build/level.json"
local lv = Campaign.level(n)
local plan = assert(Planner.solve(lv))

local cells = {}
for y = 0, lv.h - 1 do
	local row = {}
	for x = 0, lv.w - 1 do
		table.insert(row, lv.cells[y * lv.w + x + 1])
	end
	table.insert(cells, row)
end
local doors = {}
for _, d in lv.doors do
	table.insert(doors, { x = d.x, y = d.y, kind = d.kind, color = d.color or 0, axis = d.axis })
end
local plates = {}
for _, p in lv.plates do
	table.insert(plates, { x = p.x, y = p.y, kind = p.kind, color = p.color or 0 })
end
local keys = {}
for _, k in lv.keys do
	table.insert(keys, { x = k.x, y = k.y })
end
local selves = {}
for i, rec in plan.recs do
	local pts = { { rec.x0, rec.y0 } }
	for s = 1, rec.n do
		table.insert(pts, { rec.xs[s], rec.ys[s] })
	end
	local events = {}
	for s, e in rec.ev do
		table.insert(events, { t = s * Config.Loop.Step, kind = e[1] })
	end
	local tasks = {}
	for _, t in plan.itins[i] do
		local task = { kind = t.kind }
		if t["until"] then
			task["until"] = t["until"] * Config.Loop.Step
		end
		if t.plate then
			local p = lv.plates[t.plate]
			task.x, task.y, task.color = p.x, p.y, p.color or 0
		end
		table.insert(tasks, task)
	end
	table.insert(selves, { points = pts, ends = rec.n * Config.Loop.Step, events = events, tasks = tasks })
end
local data = {
	n = n,
	w = lv.w,
	h = lv.h,
	k = lv.k,
	cells = cells,
	doors = doors,
	plates = plates,
	keys = keys,
	start = lv.start,
	treasure = lv.treasure,
	vaultZone = lv.vaultZone,
	selves = selves,
	loopColors = Config.LoopColors,
	switchColors = Config.SwitchColors,
	metrics = plan.metrics,
	win = plan.winStep * Config.Loop.Step,
}
fs.writeFile(out, serde.encode("json", data, true))
print(string.format("level %d → %s (k = %d, win at %.1f s)", n, out, lv.k, data.win))
