--[[
	Bots — та же «голова» (src/shared/Planner), что решает уровни в тестах баланса и даёт
	подсказку в игре, — для прогонов на заглушке движка: боты ведут персонажей игроков.

	local Bots = require("./lib/Bots").make(shared)
	Bots.plan(n) → lv, plan              -- решение уровня кампании n
	Bots.at(plan, i, step) → x, y        -- где «я» номер i на шаге (в клетках)
	Bots.ends(plan, i) → step            -- когда «я» i заканчивает петлю (⟲)
	Bots.thief(lv) → x, y                -- клетка первого ключа (украсть у прошлого себя)
]]

local Bots = {}

function Bots.make(shared)
	local Planner = shared("Planner")
	local Campaign = shared("Campaign")
	local Loop = shared("Loop")

	local function plan(n: number)
		local lv = Campaign.level(n)
		return lv, assert(Planner.solve(lv), "no plan for level " .. n)
	end

	local function at(p, i: number, step: number): (number, number)
		return Loop.recAt(p.recs[i], step)
	end

	local function ends(p, i: number): number
		return p.recs[i].n
	end

	local function thief(lv)
		local k = lv.keys[1]
		return k.x + 0.5, k.y + 0.5
	end

	return { plan = plan, at = at, ends = ends, thief = thief }
end

return Bots
