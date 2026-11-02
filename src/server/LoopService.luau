--[[
	LoopService — экземпляры уровней («забеги») и их петли.

	Забег: уровень кампании в своём слоте мира, участники (1–4), записи прошлых петель
	(призраки — общие для всех), фаза:
	  rewind (1,2 с) → play (петля 15 с) → rewind … → won | out.
	Шаг петли — модель Loop по GetServerTimeNow (не task.delay): шаг s выполняется, когда
	время от начала петли ≥ s·Step. Живые — вход модели (позиция корня персонажа),
	призраки — только записи (рисует клиент). Двери и плиты на сервере меняются по событиям
	модели. ⟲ — живой заканчивает петлю (запись обрывается, персонаж замирает).
	Петли кончились (призраков ≥ k + лишние) → фаза out: окно OutWait, потом сама отменяется
	последняя петля; «Лишняя петля» продлевает окно один раз, пока открыт промпт оплаты.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Campaign = require(Shared.Campaign)
local Config = require(Shared.Config)
local Loop = require(Shared.Loop)
local Net = require(Shared.Net)
local Planner = require(Shared.Planner)
local Profile = require(Shared.Profile)
local Rewards = require(Shared.Rewards)

local Data = require(script.Parent.DataService)
local Monetization = require(script.Parent.Monetization)
local Cosmetics = require(script.Parent.Cosmetics)
local LevelBuilder = require(script.Parent.LevelBuilder)

local LoopService = {}

local T = Config.Grid.Tile
local STEP = Config.Loop.Step

local runs: { [number]: any } = {}
local runOf: { [Player]: any } = {}
local usedSlots: { [number]: boolean } = {}
local planCache: { [number]: any } = {}
local nextId = 0
local levelsFolder: Folder? = nil

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function sendTo(player: Player, payload)
	Net.ServerEvent:FireClient(player, payload)
end

local function everyone(run)
	local out = table.clone(run.members)
	for _, p in run.pending do
		table.insert(out, p)
	end
	return out
end

local function send(run, payload)
	for _, p in everyone(run) do
		if p.Parent then
			sendTo(p, payload)
		end
	end
end

local function toast(player: Player, key: string, vars: { [string]: any }?)
	sendTo(player, { t = "toast", key = key, vars = vars })
end

function LoopService.planFor(n: number)
	if planCache[n] == nil then
		local lv = Campaign.level(n)
		planCache[n] = (lv and Planner.solve(lv)) or false
	end
	return planCache[n] or nil
end

-------------------------------------------------------------------------------
-- Персонажи
-------------------------------------------------------------------------------
local function rootOf(player: Player): BasePart?
	local ch = player.Character
	return ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function worldOf(run, px: number, py: number, h: number?): Vector3
	return run.origin + Vector3.new(px * T, h or 0, py * T)
end

local function tilesOf(run, pos: Vector3): (number, number)
	return (pos.X - run.origin.X) / T, (pos.Z - run.origin.Z) / T
end

local function freeze(player: Player, on: boolean)
	local r = rootOf(player)
	if r then
		r.Anchored = on
	end
end

local function placeAt(run, player: Player, px: number, py: number)
	local ch = player.Character
	if not ch then
		return
	end
	local c = run.lv
	local look = worldOf(run, c.w / 2, c.h / 2, 3)
	local pos = worldOf(run, px, py, 3)
	if (look - pos).Magnitude < 1 then
		look = pos + Vector3.new(0, 0, 1)
	end
	ch:PivotTo(CFrame.lookAt(pos, Vector3.new(look.X, pos.Y, look.Z)))
end

local function startTile(run, i: number)
	local s = run.lv.starts[math.min(i, #run.lv.starts)]
	return s.x + 0.5, s.y + 0.5
end

-------------------------------------------------------------------------------
-- Упаковка записей для клиента (без дырявых числовых ключей)
-------------------------------------------------------------------------------
local function packRec(rec)
	local ev = {}
	for s, e in rec.ev do
		table.insert(ev, { s, e[1], e[2] })
	end
	table.sort(ev, function(a, b)
		return a[1] < b[1]
	end)
	return {
		xs = rec.xs,
		ys = rec.ys,
		n = rec.n,
		ev = ev,
		x0 = rec.x0,
		y0 = rec.y0,
		owner = rec.owner,
		name = rec.name,
		loop = rec.loop,
		skin = rec.skin,
		trail = rec.trail,
		rewind = rec.rewind,
	}
end
LoopService.packRec = packRec

-------------------------------------------------------------------------------
-- Забеги
-------------------------------------------------------------------------------
local function loopIndex(run): number
	local L = 0
	for _, g in run.ghosts do
		L = math.max(L, g.loop or 0)
	end
	return L + 1
end

local function players(run): number
	return math.max(1, #run.members)
end

local function totalLoops(run): number
	local L = loopIndex(run)
	local left = math.max(1, math.ceil((run.lv.k + run.extra - #run.ghosts) / players(run)))
	return L + left - 1
end

local function newStats()
	return { loopsPlayed = 0, undone = false, extra = false, hinted = false }
end

local function slotOrigin(slot: number): Vector3
	local G = Config.Grid
	local col = slot % G.SlotsPerRow
	local row = math.floor(slot / G.SlotsPerRow)
	return Vector3.new(col * G.SlotGap, G.BaseY, row * G.SlotGap)
end

local function buildLevel(run, n: number)
	if run.model then
		run.model:Destroy()
	end
	local lv = assert(Campaign.level(n), "no level " .. n)
	run.n = n
	run.lv = lv
	run.model = LevelBuilder.build(lv, run.origin, levelsFolder :: Folder, "Run_" .. run.id)
	run.ghosts = {}
	run.extra = 0
	run.stats = newStats()
	run.hint = {}
	run.st = nil
	run.outHeld = false
end

function LoopService.create(n: number)
	nextId += 1
	local slot = 0
	while usedSlots[slot] do
		slot += 1
	end
	usedSlots[slot] = true
	local run = {
		id = nextId,
		slot = slot,
		origin = slotOrigin(slot),
		members = {},
		pending = {},
		lives = {},
		phase = "idle",
		phaseEnd = 0,
		autoplay = false,
	}
	buildLevel(run, n)
	runs[run.id] = run
	return run
end

local function destroy(run)
	runs[run.id] = nil
	usedSlots[run.slot] = nil
	if run.model then
		run.model:Destroy()
	end
end

local function levelPayload(run)
	return {
		t = "level",
		n = run.n,
		origin = { run.origin.X, run.origin.Y, run.origin.Z },
		run = run.id,
		k = run.lv.k,
	}
end

local function membersPayload(run)
	local list = {}
	for _, p in run.members do
		table.insert(list, { userId = p.UserId, name = p.DisplayName })
	end
	for _, p in run.pending do
		table.insert(list, { userId = p.UserId, name = p.DisplayName, pending = true })
	end
	return { t = "members", list = list, run = run.id }
end

-------------------------------------------------------------------------------
-- Фазы
-------------------------------------------------------------------------------
local startLoop

local function beginRewind(run, reason: string)
	run.phase = "rewind"
	run.phaseEnd = now() + Config.Loop.Rewind
	for _, p in run.pending do
		table.insert(run.members, p)
	end
	run.pending = {}
	for _, p in run.members do
		freeze(p, true)
	end
	send(run, { t = "rewind", reason = reason, dur = Config.Loop.Rewind, at = now() })
end

local function sendHint(run, player: Player)
	local plan = LoopService.planFor(run.n)
	if not plan then
		return
	end
	local idx = table.find(run.lives, player) or (#run.lives + 1)
	local i = #run.ghosts + idx
	-- призраки должны совпадать с решением (по последней клетке)
	local stale = false
	for j, g in run.ghosts do
		local pr = plan.recs[j]
		if not pr then
			stale = true
			break
		end
		local gx, gy = Loop.recAt(g, g.n)
		local px, py = Loop.recAt(pr, pr.n)
		if math.floor(gx) ~= math.floor(px) or math.floor(gy) ~= math.floor(py) then
			stale = true
			break
		end
	end
	if stale or not plan.recs[i] then
		sendTo(player, { t = "hint", stale = true })
		return
	end
	sendTo(player, { t = "hint", rec = packRec(plan.recs[i]), start = run.loopStart, self = i })
end

function LoopService.loopPayload(run, spectator: boolean?)
	local ghosts = {}
	for _, g in run.ghosts do
		table.insert(ghosts, packRec(g))
	end
	local livesInfo = {}
	if not spectator then
		for i, p in run.lives do
			local x, y = startTile(run, i)
			table.insert(livesInfo, {
				userId = p.UserId,
				name = p.DisplayName,
				skin = p:GetAttribute("Skin"),
				trail = p:GetAttribute("Trail"),
				rewind = p:GetAttribute("Rewind"),
				x = x,
				y = y,
			})
		end
	end
	return {
		t = "loop",
		n = run.n,
		loop = run.loopNo,
		total = run.total,
		start = run.loopStart,
		length = Config.Loop.Length,
		ghosts = ghosts,
		lives = livesInfo,
		k = run.lv.k,
		extra = run.extra,
		spectator = spectator == true,
	}
end

startLoop = function(run)
	run.lives = table.clone(run.members)
	local lives = {}
	for i, p in run.lives do
		local x, y = startTile(run, i)
		placeAt(run, p, x, y)
		freeze(p, false)
		table.insert(lives, { id = p.UserId, x = x, y = y })
	end
	run.st = Loop.new(run.lv, run.ghosts, lives)
	run.loopStart = now()
	run.phase = "play"
	run.loopNo = loopIndex(run)
	run.total = totalLoops(run)
	LevelBuilder.reset(run.model, run.lv)
	send(run, LoopService.loopPayload(run))
	for p in run.hint do
		if p.Parent and table.find(run.lives, p) then
			sendHint(run, p)
		end
	end
end

local function nextLevel(run, n: number)
	buildLevel(run, n)
	send(run, levelPayload(run))
	beginRewind(run, "level")
end

local function win(run)
	run.phase = "won"
	run.phaseEnd = now() + Config.Loop.WinPause
	local st = run.st
	run.stats.loopsPlayed += 1
	local needed = math.ceil(run.lv.k / math.max(1, #run.lives))
	local stars = Rewards.stars({
		loopsPlayed = run.stats.loopsPlayed,
		loopsNeeded = needed,
		extra = run.stats.extra,
		hinted = run.stats.hinted,
		undone = run.stats.undone,
	})
	for _, p in run.members do
		local d = Data.get(p)
		local coins, first, gained = 0, false, 0
		if d then
			first, gained = Profile.recordClear(d, run.n, stars)
			d.loops += 1
			local mult =
				Rewards.multiplier(Monetization.hasPass(p, "DoubleCoins"), Monetization.hasPass(p, "Vip"))
			coins = Rewards.apply(Rewards.levelCoins(run.lv.k, first, gained), mult)
			Profile.earn(d, coins)
			Data.changed(p)
			Monetization.sendProfile(p)
		end
		sendTo(p, {
			t = "won",
			n = run.n,
			stars = stars,
			coins = coins,
			first = first,
			loops = run.stats.loopsPlayed,
			needed = needed,
			k = run.lv.k,
			by = st and st.winBy,
			next = if run.n < Campaign.Count then run.n + 1 else nil,
			pause = Config.Loop.WinPause,
		})
	end
end

local function goOut(run)
	run.phase = "out"
	run.phaseEnd = now() + Config.Loop.OutWait
	run.outHeld = false
	send(run, {
		t = "out",
		deadline = run.phaseEnd,
		loop = loopIndex(run) - 1,
		canExtra = Monetization.available("product", "ExtraLoop"),
		robux = Config.Products.ExtraLoop.robux,
	})
end

local function endLoop(run)
	local st = run.st
	if st.won then
		win(run)
		return
	end
	run.stats.loopsPlayed += 1
	local recs = Loop.recordings(st)
	for i, rec in recs do
		local p = run.lives[i]
		rec.loop = run.loopNo
		rec.owner = p and p.UserId
		rec.name = p and p.DisplayName or "?"
		rec.skin = p and p:GetAttribute("Skin")
		rec.trail = p and p:GetAttribute("Trail")
		rec.rewind = p and p:GetAttribute("Rewind")
		table.insert(run.ghosts, rec)
	end
	for _, p in run.members do
		local d = Data.get(p)
		if d then
			d.loops += 1
			Data.changed(p)
		end
	end
	if #run.ghosts < run.lv.k + run.extra then
		beginRewind(run, "next")
	else
		goOut(run)
	end
end

local function undo(run, auto: boolean?)
	if #run.ghosts == 0 then
		return false
	end
	local L = loopIndex(run) - 1
	for i = #run.ghosts, 1, -1 do
		if run.ghosts[i].loop == L then
			table.remove(run.ghosts, i)
		end
	end
	run.stats.undone = true
	send(run, { t = "undone", loop = L, auto = auto == true })
	beginRewind(run, "undo")
	return true
end

-------------------------------------------------------------------------------
-- Шаг
-------------------------------------------------------------------------------
local function sampleInputs(run)
	local inputs = {}
	local st = run.st
	local plan = run.autoplay and LoopService.planFor(run.n)
	for i, p in run.lives do
		local b = Loop.bodyOf(st, p.UserId)
		if not b or b.done then
			continue
		end
		if plan then
			local rec = plan.recs[#run.ghosts + i]
			if rec then
				local s = st.step + 1
				local x, y = Loop.recAt(rec, s)
				local r = rootOf(p)
				if r then
					r.Anchored = true
					r.CFrame = CFrame.new(worldOf(run, x, y, 3)) * r.CFrame.Rotation
				end
				inputs[p.UserId] = { x = x, y = y }
				if s >= rec.n and #run.ghosts + i < run.lv.k then
					run.autoFinish = run.autoFinish or {}
					run.autoFinish[p] = true
				end
			end
			continue
		end
		local r = rootOf(p)
		if r and p.Parent then
			local x, y = tilesOf(run, r.CFrame.Position)
			-- скорость: дальше разумного за шаг — откат (телепорт, лаг)
			local maxStep = Config.Loop.WalkSpeed * Config.Loop.SpeedSlack * STEP / T * 3
			if math.abs(x - b.x) + math.abs(y - b.y) > maxStep * 2 then
				r.CFrame = CFrame.new(worldOf(run, b.x, b.y, 3)) * r.CFrame.Rotation
			else
				inputs[p.UserId] = { x = x, y = y }
			end
		end
	end
	return inputs
end

local function handleEvents(run, events)
	if #events == 0 then
		return
	end
	local out = {}
	for _, e in events do
		if e.t == "door" then
			LevelBuilder.setDoor(run.model, e.door, e.open)
		elseif e.t == "plate" then
			LevelBuilder.setPlate(run.model, e.plate, e.on)
			LevelBuilder.setVaultLamps(run.model, (Loop.vaultCount(run.st)))
		elseif e.t == "blocked" then
			-- закрытая дверь / стена: вернуть персонажа туда, где его видит модель
			local b = run.st.bodies[e.body]
			for _, p in run.lives do
				if b and p.UserId == b.id then
					local r = rootOf(p)
					if r then
						r.CFrame = CFrame.new(worldOf(run, b.x, b.y, 3)) * r.CFrame.Rotation
					end
				end
			end
		elseif e.t == "paradox" then
			for _, p in run.members do
				local d = Data.get(p)
				if d then
					d.paradoxes += 1
				end
			end
		end
		if e.t ~= "blocked" then
			table.insert(out, e)
		end
	end
	if #out > 0 then
		send(run, { t = "ev", list = out })
	end
end

local function playSteps(run, t: number)
	local st = run.st
	local target = math.min(st.n, math.floor((t - run.loopStart) / STEP + 1e-6))
	if st.step < target and not Loop.over(st) then
		local inputs = sampleInputs(run)
		local guard = 0
		while st.step < target and not Loop.over(st) and guard < 10 do
			guard += 1
			handleEvents(run, Loop.step(st, inputs))
		end
		if run.autoFinish then
			for p in run.autoFinish do
				LoopService.finishLive(p)
			end
			run.autoFinish = nil
		end
	end
	if Loop.over(st) then
		endLoop(run)
	end
end

function LoopService.step()
	local t = now()
	for _, run in runs do
		if run.phase == "rewind" and t >= run.phaseEnd then
			startLoop(run)
		elseif run.phase == "play" then
			playSteps(run, t)
		elseif run.phase == "out" and t >= run.phaseEnd then
			undo(run, true)
		elseif run.phase == "won" and t >= run.phaseEnd then
			nextLevel(run, if run.n < Campaign.Count then run.n + 1 else run.n)
		end
	end
end

-------------------------------------------------------------------------------
-- Игроки
-------------------------------------------------------------------------------
function LoopService.leave(player: Player)
	local run = runOf[player]
	if not run then
		return
	end
	runOf[player] = nil
	local i = table.find(run.members, player)
	if i then
		table.remove(run.members, i)
	end
	local j = table.find(run.pending, player)
	if j then
		table.remove(run.pending, j)
	end
	run.hint[player] = nil
	if run.phase == "play" and run.st and table.find(run.lives, player) then
		Loop.finish(run.st, player.UserId)
	end
	if #run.members == 0 and #run.pending == 0 then
		destroy(run)
		return
	end
	send(run, membersPayload(run))
	send(run, { t = "toast", key = "loop.left", vars = { name = player.DisplayName } })
end

-- Добавить игрока в забег: сразу (между петлями) или со следующей петли
function LoopService.join(player: Player, run): boolean
	if #run.members + #run.pending >= Config.Loop.MaxPlayers then
		return false
	end
	if runOf[player] == run then
		return true
	end
	LoopService.leave(player)
	runOf[player] = run
	sendTo(player, levelPayload(run))
	if run.phase == "play" then
		table.insert(run.pending, player)
		local x, y = startTile(run, #run.members + #run.pending)
		placeAt(run, player, x, y)
		freeze(player, true)
		-- текущая петля: зритель (видит призраков), войдёт со следующей
		sendTo(player, LoopService.loopPayload(run, true))
		toast(player, "ui.waitNext")
	else
		table.insert(run.members, player)
		local x, y = startTile(run, #run.members)
		placeAt(run, player, x, y)
		freeze(player, true)
		if run.phase == "idle" then
			beginRewind(run, "level")
		end
	end
	send(run, membersPayload(run))
	for _, p in everyone(run) do
		if p ~= player then
			toast(p, "loop.joined", { name = player.DisplayName })
		end
	end
	return true
end

-- Новый забег для игрока (одиночный) на уровне n
function LoopService.solo(player: Player, n: number)
	local run = LoopService.create(n)
	LoopService.join(player, run)
	return run
end

-- Клиент запустился: прислать уровень и текущую петлю (события до запуска клиента теряются)
function LoopService.sync(player: Player)
	local run = runOf[player]
	if not run then
		return
	end
	sendTo(player, levelPayload(run))
	sendTo(player, membersPayload(run))
	if run.phase == "play" then
		local live = table.find(run.lives, player) ~= nil
		sendTo(player, LoopService.loopPayload(run, not live))
		local b = live and Loop.bodyOf(run.st, player.UserId)
		if b and b.done then
			sendTo(player, { t = "done", step = run.st.step })
		end
	elseif run.phase == "out" then
		sendTo(player, {
			t = "out",
			deadline = run.phaseEnd,
			loop = loopIndex(run) - 1,
			canExtra = Monetization.available("product", "ExtraLoop"),
			robux = Config.Products.ExtraLoop.robux,
		})
	end
end

function LoopService.runOf(player: Player)
	return runOf[player]
end

function LoopService.runs()
	return runs
end

-- Персонаж появился (в т.ч. после смерти): поставить на старт своего забега
function LoopService.onCharacter(player: Player)
	local run = runOf[player]
	if not run then
		return
	end
	local i = table.find(run.lives, player) or table.find(run.members, player) or (#run.members + 1)
	local x, y = startTile(run, i)
	local st = run.st
	local b = st and run.phase == "play" and Loop.bodyOf(st, player.UserId)
	if b then
		x, y = b.x, b.y
	end
	placeAt(run, player, x, y)
	local frozen = run.phase ~= "play" or table.find(run.pending, player) ~= nil or (b and b.done)
	freeze(player, frozen == true)
end

-------------------------------------------------------------------------------
-- Действия игрока
-------------------------------------------------------------------------------
-- ⟲: закончить свою петлю здесь (призрак останется стоять)
function LoopService.finishLive(player: Player): boolean
	local run = runOf[player]
	if not run or run.phase ~= "play" or not table.find(run.lives, player) then
		return false
	end
	local b = Loop.bodyOf(run.st, player.UserId)
	if not b or b.done then
		return false
	end
	Loop.finish(run.st, player.UserId)
	freeze(player, true)
	sendTo(player, { t = "done", step = run.st.step })
	if not Loop.allDone(run.st) then
		toast(player, "loop.waitDone")
	end
	return true
end

function LoopService.undo(player: Player): boolean
	local run = runOf[player]
	if not run or run.phase == "won" or run.phase == "rewind" then
		return false
	end
	if not undo(run) then
		toast(player, "loop.nothingUndo")
		return false
	end
	return true
end

function LoopService.restart(player: Player): boolean
	local run = runOf[player]
	if not run or run.phase == "won" then
		return false
	end
	run.ghosts = {}
	run.stats.undone = true
	send(run, { t = "toast", key = "loop.restarted" })
	beginRewind(run, "restart")
	return true
end

function LoopService.playLevel(player: Player, n: number): boolean
	if not Campaign.level(n) then
		return false
	end
	local d = Data.get(player)
	if d and not Profile.unlocked(d, n) then
		return false
	end
	local run = runOf[player]
	if run and #run.members + #run.pending == 1 then
		nextLevel(run, n)
		return true
	end
	LoopService.solo(player, n)
	return true
end

-- Победа: «Дальше» / «Ещё раз» не дожидаясь паузы
function LoopService.advance(player: Player, again: boolean)
	local run = runOf[player]
	if run and run.phase == "won" then
		nextLevel(run, if again or run.n >= Campaign.Count then run.n else run.n + 1)
	end
end

-- Подсказка: с «Оракулом» бесплатно, иначе HintCost монет (один раз на уровень)
function LoopService.hint(player: Player): boolean
	local run = runOf[player]
	if not run then
		return false
	end
	if not run.hint[player] then
		if not Monetization.hasPass(player, "Oracle") then
			local d = Data.get(player)
			if not d or d.coins < Config.Rewards.HintCost then
				toast(player, "loop.hintNoCoins", { n = Config.Rewards.HintCost })
				return false
			end
			Profile.addCoins(d, -Config.Rewards.HintCost)
			Data.changed(player)
			Monetization.sendProfile(player)
		end
		run.hint[player] = true
		run.stats.hinted = true
	end
	sendHint(run, player)
	return true
end

-- Окно «петли кончились»: пока открыт промпт «Лишней петли», не истекает (один раз)
function LoopService.holdOut(player: Player)
	local run = runOf[player]
	if run and run.phase == "out" and not run.outHeld then
		run.outHeld = true
		run.phaseEnd = math.max(run.phaseEnd, now() + Config.Loop.PayHold)
		send(run, {
			t = "out",
			deadline = run.phaseEnd,
			loop = loopIndex(run) - 1,
			canExtra = Monetization.available("product", "ExtraLoop"),
			robux = Config.Products.ExtraLoop.robux,
			held = true,
		})
	end
end

-- Developer product «Лишняя петля»
function LoopService.extraLoop(player: Player): boolean
	local run = runOf[player]
	if not run then
		return false
	end
	run.extra += 1
	run.stats.extra = true
	if run.phase == "out" then
		beginRewind(run, "extra")
	end
	return true
end

-- Список забегов для панели «Вместе»
function LoopService.list(): { any }
	local out = {}
	for _, run in runs do
		local names = {}
		for _, p in run.members do
			table.insert(names, p.DisplayName)
		end
		table.insert(out, {
			id = run.id,
			n = run.n,
			names = names,
			count = #run.members + #run.pending,
			max = Config.Loop.MaxPlayers,
		})
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

function LoopService.joinRun(player: Player, id: number): boolean
	local run = runs[id]
	if not run or runOf[player] == run then
		return false
	end
	return LoopService.join(player, run)
end

-------------------------------------------------------------------------------
-- Отладка (Studio)
-------------------------------------------------------------------------------
function LoopService.debug(player: Player, cmd: string, arg: any): string?
	local run = runOf[player]
	if not run then
		return "not in a level"
	end
	if cmd == "win" then
		if run.phase == "play" then
			run.st.won = true
			endLoop(run)
			return "won"
		end
		return "not playing"
	elseif cmd == "next" then
		nextLevel(run, math.min(Campaign.Count, run.n + 1))
		return "level " .. run.n
	elseif cmd == "prev" then
		nextLevel(run, math.max(1, run.n - 1))
		return "level " .. run.n
	elseif cmd == "level" then
		local n = math.clamp(tonumber(arg) or 1, 1, Campaign.Count)
		nextLevel(run, n)
		return "level " .. n
	elseif cmd == "out" then
		while #run.ghosts < run.lv.k + run.extra do
			local rec = Loop.newRecording(run.lv.start.x + 0.5, run.lv.start.y + 0.5)
			rec.loop = loopIndex(run)
			rec.name = player.DisplayName
			table.insert(run.ghosts, rec)
		end
		goOut(run)
		return "out of loops"
	elseif cmd == "autoplay" then
		run.autoplay = not run.autoplay
		if run.autoplay and run.phase == "play" then
			LoopService.restart(player)
		end
		return "autoplay " .. tostring(run.autoplay)
	elseif cmd == "state" then
		return string.format(
			"level %d k=%d phase=%s step=%s loop=%s/%s ghosts=%d extra=%d players=%d",
			run.n,
			run.lv.k,
			run.phase,
			tostring(run.st and run.st.step),
			tostring(run.loopNo),
			tostring(run.total),
			#run.ghosts,
			run.extra,
			#run.members
		)
	elseif cmd == "unlockall" then
		local d = Data.get(player)
		if d then
			d.stars = string.rep("1", Campaign.Count)
			Data.changed(player)
			Monetization.sendProfile(player)
		end
		return "all levels unlocked"
	end
	return nil
end

function LoopService.start()
	levelsFolder = Workspace:FindFirstChild("Levels") :: Folder?
	if not levelsFolder then
		local f = Instance.new("Folder")
		f.Name = "Levels"
		f.Parent = Workspace
		levelsFolder = f
	end
	Monetization.extraLoop = LoopService.extraLoop
	Monetization.beforePrompt = function(player, key)
		if key == "ExtraLoop" then
			LoopService.holdOut(player)
		end
	end
	Cosmetics.onChange(function(_player) end)
	Players.PlayerRemoving:Connect(LoopService.leave)
end

return LoopService
