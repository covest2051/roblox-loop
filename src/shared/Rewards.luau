--[[
	Rewards — звёзды за уровень и монеты (множители ×2 Монеты, VIP).
	Звёзды: ★ пройдено; ★★ без лишней петли и подсказки; ★★★ ещё и без отмен и повторов
	(ровно ⌈k / игроки⌉ петель).
]]

local Shared = script.Parent
local Config = require(Shared.Config)

local Rewards = {}

function Rewards.multiplier(double: boolean, vip: boolean): number
	local R = Config.Rewards
	local m = 1
	if double then
		m *= R.DoubleCoins
	end
	if vip then
		m *= 1 + R.VipBonus
	end
	return m
end

function Rewards.apply(base: number, mult: number): number
	return math.floor(base * mult + 1e-9)
end

-- run: { loopsPlayed, loopsNeeded, extra, hinted, undone }
function Rewards.stars(run: { [string]: any }): number
	if run.extra or run.hinted then
		return 1
	end
	if run.undone or run.loopsPlayed > run.loopsNeeded then
		return 2
	end
	return 3
end

-- Монеты за победу (до множителя). first — первое прохождение, gained — новых звёзд.
function Rewards.levelCoins(k: number, first: boolean, gained: number): number
	local R = Config.Rewards
	local base = if first then R.FirstBase + R.FirstPerK * k else R.Repeat
	return base + R.StarBonus * math.max(0, gained)
end

return Rewards
