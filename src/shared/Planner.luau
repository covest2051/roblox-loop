--[[
	Planner — одна «голова» бота: тесты баланса (чистая модель), боты-персонажи на заглушке
	движка и подсказка в игре (путь «правильного тебя» для текущей петли).

	1. Planner.canWin(lv, bodies) — ПОЛНЫЙ перебор ослабленной модели: зоны, плиты, проёмы,
	   ключи; время не ограничено, тела действуют в любом порядке (как идеальный кооператив).
	   Ослабление только разрешает больше, поэтому «нельзя» здесь = нельзя и в игре.
	2. Planner.solve(lv) — роли для k «тебя»: кто на какую золотую плиту, кто держит
	   переключатель для будущего себя (и до какого момента), кто несёт ключ к замку.
	   Все k ботов идут одновременно; бот i проходит дверь, только если её держат боты < i
	   (в петле i живы только прошлые «я»). Затем Planner.verify проигрывает решение
	   ПО ПЕТЛЯМ, как в игре: в петле i живой только i-й, остальные — записи.
	3. Planner.newBot / Planner.drive — бот по задачам (pro), новичок без «передач» (novice),
	   «наугад» (random), «ничего не делает» (idle) — для сравнения в тестах.
]]

local Shared = script.Parent
local Config = require(Shared.Config)
local Level = require(Shared.Level)
local Loop = require(Shared.Loop)
local Rng = require(Shared.Rng)

local Planner = {}

local DT = Config.Loop.Step
local WALK = Config.Loop.WalkSpeed / Config.Grid.Tile -- клеток в секунду

-------------------------------------------------------------------------------
-- Дерево зон
-------------------------------------------------------------------------------
local function ancestors(lv, z: number): { number }
	local out = {}
	local cur = lv.zones[z]
	while cur do
		table.insert(out, cur.id)
		cur = cur.parent and lv.zones[cur.parent]
	end
	return out
end

-- Ворота на пути между зонами (по дереву)
function Planner.gatesBetween(lv, za: number, zb: number): { number }
	if za == zb then
		return {}
	end
	local A, B = ancestors(lv, za), ancestors(lv, zb)
	local inB = {}
	for i, z in B do
		inB[z] = i
	end
	local out = {}
	local lca = nil
	for _, z in A do
		if inB[z] then
			lca = z
			break
		end
		table.insert(out, lv.zones[z].gate)
	end
	local down = {}
	for _, z in B do
		if z == lca then
			break
		end
		table.insert(down, 1, lv.zones[z].gate)
	end
	for _, g in down do
		table.insert(out, g)
	end
	return out
end

-------------------------------------------------------------------------------
-- 1. Полный перебор ослабленной модели
-------------------------------------------------------------------------------
--[[
	Позиция тела: зона (свободно), плита, проём двери. Тело в зоне может встать на любую
	плиту зоны, войти в проём соседней двери (если она открыта), взять ключ зоны,
	открыть соседний замок ключом. Победа — тело в зоне хранилища.
	Возвращает won, explored (nil — упёрлись в предел состояний).
]]
function Planner.canWin(lv, bodies: number): (boolean?, number)
	local Z, NP, NK = #lv.zones, #lv.plates, #lv.keys
	local K1 = NK + 1
	local function code(pos, carry)
		return (pos - 1) * K1 + carry
	end
	local function decode(c)
		return c // K1 + 1, c % K1
	end
	local vaultPlates = {}
	for _, p in lv.plates do
		if p.kind == "vault" then
			table.insert(vaultPlates, p.id)
		end
	end
	local platesOfZone, doorsOfZone = {}, {}
	for z = 1, Z do
		platesOfZone[z], doorsOfZone[z] = {}, {}
	end
	for _, p in lv.plates do
		table.insert(platesOfZone[p.zone], p.id)
	end
	for _, d in lv.doors do
		table.insert(doorsOfZone[d.parent], d.id)
		table.insert(doorsOfZone[d.child], d.id)
	end
	local keysOfZone = {}
	for z = 1, Z do
		keysOfZone[z] = {}
	end
	for _, k in lv.keys do
		table.insert(keysOfZone[k.zone], k.id)
	end

	local function keyOf(codes, used, unl)
		return table.concat(codes, ",") .. "|" .. used .. "|" .. unl
	end
	local function doorOpen(d, occ, unl)
		local door = lv.doors[d]
		if occ[Z + NP + d] then
			return true
		end
		if door.kind == "lock" then
			return bit32.btest(unl, bit32.lshift(1, d - 1))
		elseif door.kind == "switch" then
			for _, p in lv.plates do
				if p.kind == "switch" and p.color == door.color and occ[Z + p.id] then
					return true
				end
			end
			return false
		end
		for _, pid in vaultPlates do
			if not occ[Z + pid] then
				return false
			end
		end
		return true
	end

	local start = {}
	for _ = 1, bodies do
		table.insert(start, code(1, 0))
	end
	local queue = { { start, 0, 0 } }
	local tail = 1
	local seen = { [keyOf(start, 0, 0)] = true }
	local qi = 1
	local explored = 0
	while qi <= tail do
		local cur = queue[qi]
		queue[qi] = nil
		qi += 1
		explored += 1
		if explored > Config.Plan.BfsStates then
			return nil, explored
		end
		local codes, used, unl = cur[1], cur[2], cur[3]
		local occ = {}
		local carried = 0
		for _, c in codes do
			local pos, carry = decode(c)
			occ[pos] = true
			if carry > 0 then
				carried = bit32.bor(carried, bit32.lshift(1, carry - 1))
			end
		end
		local function push(j, newCode, nused, nunl)
			local nc = table.clone(codes)
			nc[j] = newCode
			table.sort(nc)
			local key = keyOf(nc, nused, nunl)
			if not seen[key] then
				seen[key] = true
				tail += 1
				queue[tail] = { nc, nused, nunl }
			end
		end
		local last = -1
		for j, c in codes do
			if c == last then
				continue
			end
			last = c
			local pos, carry = decode(c)
			if pos <= Z then
				local z = pos
				if z == lv.vaultZone then
					return true, explored
				end
				for _, pid in platesOfZone[z] do
					push(j, code(Z + pid, carry), used, unl)
				end
				for _, d in doorsOfZone[z] do
					if doorOpen(d, occ, unl) then
						push(j, code(Z + NP + d, carry), used, unl)
					end
					local door = lv.doors[d]
					local bitD = bit32.lshift(1, d - 1)
					if door.kind == "lock" and carry > 0 and not bit32.btest(unl, bitD) then
						push(j, code(z, 0), bit32.bor(used, bit32.lshift(1, carry - 1)), bit32.bor(unl, bitD))
					end
				end
				if carry == 0 then
					for _, kid in keysOfZone[z] do
						local bitK = bit32.lshift(1, kid - 1)
						if not bit32.btest(used, bitK) and not bit32.btest(carried, bitK) then
							push(j, code(z, kid), used, unl)
						end
					end
				end
			elseif pos <= Z + NP then
				push(j, code(lv.plates[pos - Z].zone, carry), used, unl)
			else
				local door = lv.doors[pos - Z - NP]
				push(j, code(door.parent, carry), used, unl)
				push(j, code(door.child, carry), used, unl)
			end
		end
	end
	return false, explored
end

-------------------------------------------------------------------------------
-- Маршрут по клеткам
-------------------------------------------------------------------------------
local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- BFS от клетки до клетки; лежащие ключи (не цель) обходятся, если можно.
function Planner.route(lv, fx: number, fy: number, tx: number, ty: number, avoid: { [number]: boolean }?)
	local function bfs(useAvoid)
		local w = lv.w
		local start = fy * w + fx + 1
		local goal = ty * w + tx + 1
		local prev = { [start] = 0 }
		local queue = { start }
		local qi = 1
		while qi <= #queue do
			local cur = queue[qi]
			qi += 1
			if cur == goal then
				break
			end
			local cx, cy = (cur - 1) % w, (cur - 1) // w
			for _, d in DIRS do
				local nx, ny = cx + d[1], cy + d[2]
				local ni = ny * w + nx + 1
				if prev[ni] == nil and Level.isFloor(lv, nx, ny) then
					if not (useAvoid and avoid and avoid[ni] and ni ~= goal) then
						prev[ni] = cur
						table.insert(queue, ni)
					end
				end
			end
		end
		if prev[goal] == nil then
			return nil
		end
		local path = {}
		local cur = goal
		while cur ~= start do
			table.insert(path, 1, { x = (cur - 1) % w, y = math.floor((cur - 1) / w) })
			cur = prev[cur]
		end
		return path
	end
	return bfs(true) or bfs(false)
end

-------------------------------------------------------------------------------
-- 3. Бот
-------------------------------------------------------------------------------
--[[
	Задачи: { kind = "hold", plate, gate } — стоять на переключателе, пока будущие «я» не пройдут;
	        { kind = "key", key } — взять ключ; { kind = "unlock", door } — отпереть замок;
	        { kind = "plate", plate } — встать на золотую плиту (и закончить петлю);
	        { kind = "treasure" } — в хранилище.
	У задачи hold может быть until (шаг) — тогда бот отпускает плиту на этом шаге
	(так решение проигрывается в петлях, где будущих «я» ещё нет).
]]
function Planner.newBot(lv, index: number, tasks: { any }, opts: { [string]: any }?)
	local o = opts or {}
	return {
		lv = lv,
		index = index,
		tasks = tasks,
		ti = 1,
		path = nil,
		pathFor = nil,
		speed = (o.speed or Config.Plan.SpeedFactor) * WALK,
		skill = o.skill or "pro",
		react = math.floor((o.reaction or 0) / DT + 0.5),
		wait = math.floor((o.reaction or 0) / DT + 0.5),
		rng = o.rng,
		naive = o.naive == true,
		releaseAt = nil,
		finished = false,
		arrive = nil,
		idle = 0,
		idleRun = 0,
		idleMax = 0,
		lastZone = nil,
		crossed = {},
	}
end

local function taskTarget(lv, st, t)
	if t.kind == "hold" or t.kind == "plate" then
		local p = lv.plates[t.plate]
		return p.x, p.y
	elseif t.kind == "key" then
		local k = st.keys[t.key]
		return k.x, k.y
	elseif t.kind == "unlock" then
		local d = lv.doors[t.door]
		return d.frontP.x, d.frontP.y
	elseif t.kind == "treasure" then
		return lv.treasure.x, lv.treasure.y
	elseif t.kind == "goto" then
		return t.x, t.y
	end
	return nil, nil
end

local function avoidKeys(lv, st, exceptKey)
	local avoid = {}
	for id, k in st.keys do
		if k.state == "lying" and id ~= exceptKey then
			avoid[k.y * lv.w + k.x + 1] = true
		end
	end
	return avoid
end

--[[
	Решение бота на шаг: новая позиция (x, y). allowed(door) — можно ли входить в дверь
	(по умолчанию — она открыта). ctx.release(bot, task) — отпустить ли плиту (совместный прогон).
]]
function Planner.drive(bot, st, body, ctx: { [string]: any }?): (number, number)
	local lv = bot.lv
	local c = ctx or {}
	local x, y = body.x, body.y
	if bot.finished or body.done or body.broken then
		return x, y
	end
	if bot.wait > 0 then
		bot.wait -= 1
		return x, y
	end
	local t = bot.tasks[bot.ti]
	-- завершение задач
	while t do
		local tx, ty = taskTarget(lv, st, t)
		local at = tx ~= nil and body.tx == tx and body.ty == ty
		local doneTask = false
		if t.kind == "hold" then
			if at then
				local rel
				if t["until"] then
					rel = st.step >= t["until"]
				elseif c.release then
					rel = c.release(bot, t)
				else
					rel = false
				end
				if rel then
					doneTask = true
				end
			end
		elseif t.kind == "key" then
			doneTask = body.carry ~= nil
		elseif t.kind == "unlock" then
			doneTask = st.doors[t.door].unlocked
		elseif t.kind == "plate" or t.kind == "goto" then
			if at and t.hop then
				doneTask = true
			elseif at then
				bot.finished = true
				bot.arrive = st.step
				return x, y
			end
		end
		if not doneTask then
			break
		end
		bot.ti += 1
		bot.path = nil
		bot.wait = bot.react
		t = bot.tasks[bot.ti]
		if bot.wait > 0 then
			return x, y
		end
	end
	if not t then
		bot.finished = true
		bot.arrive = bot.arrive or st.step
		return x, y
	end
	local tx, ty = taskTarget(lv, st, t)
	if bot.pathFor ~= bot.ti or not bot.path then
		bot.path =
			Planner.route(lv, body.tx, body.ty, tx, ty, if bot.naive then nil else avoidKeys(lv, st, t.key))
		bot.pathFor = bot.ti
		if not bot.path then
			return x, y
		end
	end
	-- движение по центрам клеток
	local budget = bot.speed * DT
	local moved = false
	while budget > 1e-9 and #bot.path > 0 do
		local nxt = bot.path[1]
		local cx, cy = nxt.x + 0.5, nxt.y + 0.5
		local inTile = math.floor(x) == nxt.x and math.floor(y) == nxt.y
		if not inTile then
			local door = Level.doorAt(lv, nxt.x, nxt.y)
			if door then
				local ok
				if c.allowed then
					ok = c.allowed(bot, body, door)
				else
					ok = Loop.passable(st, door)
				end
				if not ok then
					-- ждём у двери в центре своей клетки
					local hx, hy = math.floor(x) + 0.5, math.floor(y) + 0.5
					local dx, dy = hx - x, hy - y
					local d = math.sqrt(dx * dx + dy * dy)
					if d > 1e-6 then
						local s = math.min(budget, d)
						x, y = x + dx / d * s, y + dy / d * s
						moved = true
					end
					break
				end
			end
		end
		local dx, dy = cx - x, cy - y
		local d = math.sqrt(dx * dx + dy * dy)
		if d <= budget then
			x, y = cx, cy
			budget -= d
			table.remove(bot.path, 1)
			moved = moved or d > 1e-9
		else
			x, y = x + dx / d * budget, y + dy / d * budget
			budget = 0
			moved = true
		end
	end
	if moved then
		bot.idleRun = 0
	else
		bot.idle += 1
		bot.idleRun += 1
		bot.idleMax = math.max(bot.idleMax, bot.idleRun)
	end
	return x, y
end

-------------------------------------------------------------------------------
-- 2. Роли и совместный прогон
-------------------------------------------------------------------------------
local function taskZone(lv, t): number
	if t.kind == "hold" or t.kind == "plate" then
		return lv.plates[t.plate].zone
	elseif t.kind == "key" then
		return lv.keys[t.key].zone
	elseif t.kind == "unlock" then
		return lv.doors[t.door].parent
	elseif t.kind == "treasure" then
		return lv.vaultZone
	end
	return 1
end

-- Сколько раз маршрут по задачам пересекает каждые ворота: { [gate] = n }, и порядок
local function crossings(lv, tasks): ({ [number]: number }, { { gate: number, task: number } })
	local count, seq = {}, {}
	local z = 1
	for ti, t in tasks do
		local nz = taskZone(lv, t)
		for _, g in Planner.gatesBetween(lv, z, nz) do
			count[g] = (count[g] or 0) + 1
			table.insert(seq, { gate = g, task = ti })
		end
		z = nz
	end
	return count, seq
end

local function cloneItins(itins)
	local out = {}
	for i, tasks in itins do
		out[i] = {}
		for j, t in tasks do
			out[i][j] = table.clone(t)
		end
	end
	return out
end

-- Первое невыполненное требование: ворота, которые кто-то пересекает без помощника
local function missing(lv, itins)
	local K = #itins
	local passers = {}
	local firstTask = {}
	for i = 1, K do
		local _, seq = crossings(lv, itins[i])
		for _, c in seq do
			passers[c.gate] = passers[c.gate] or {}
			passers[c.gate][i] = true
			firstTask[c.gate] = firstTask[c.gate] or {}
			if not firstTask[c.gate][i] then
				firstTask[c.gate][i] = c.task
			end
		end
	end
	local order = {}
	for g in passers do
		table.insert(order, g)
	end
	table.sort(order, function(a, b)
		local ma, mb = math.huge, math.huge
		for i in passers[a] do
			ma = math.min(ma, i)
		end
		for i in passers[b] do
			mb = math.min(mb, i)
		end
		if ma ~= mb then
			return ma < mb
		end
		return a < b
	end)
	for _, g in order do
		local door = lv.doors[g]
		local m = math.huge
		for i in passers[g] do
			m = math.min(m, i)
		end
		if door.kind == "switch" then
			local ok = false
			for h = 1, m - 1 do
				for _, t in itins[h] do
					if t.kind == "hold" and t.gate == g then
						ok = true
					end
				end
			end
			if not ok then
				return g, m, passers[g], firstTask[g]
			end
		elseif door.kind == "lock" then
			local ok = false
			for u = 1, m do
				for ti, t in itins[u] do
					if t.kind == "unlock" and t.door == g then
						-- у самого проходящего отпирание раньше прохода
						if u ~= m or ti <= (firstTask[g][m] or math.huge) then
							ok = true
						end
					end
				end
			end
			if not ok then
				return g, m, passers[g], firstTask[g]
			end
		end
	end
	return nil
end

-- Вставить задачи помощника перед его финальной задачей (после прежних помощей)
local function insertHelp(tasks, newTasks, before: number?)
	local pos = before or #tasks
	for i, t in newTasks do
		table.insert(tasks, pos + i - 1, t)
	end
end

local function helperCount(tasks)
	local n = 0
	for _, t in tasks do
		if t.kind == "hold" or t.kind == "key" then
			n += 1
		end
	end
	return n
end

--[[
	Совместный прогон: все k ботов одновременно, бот i доверяет только ботам < i.
	Возвращает { ok, recs, bots, winStep, holds = { [i] = { [taskIndex] = releaseStep } } }.
]]
function Planner.simulate(lv, itins, opts: { [string]: any }?)
	local o = opts or {}
	local K = #itins
	local sx, sy = lv.start.x + 0.5, lv.start.y + 0.5
	local lives = {}
	for i = 1, K do
		table.insert(lives, { id = i, x = sx, y = sy })
	end
	local st = Loop.new(lv, {}, lives)
	local bots = {}
	local remaining = {}
	for i = 1, K do
		bots[i] = Planner.newBot(lv, i, itins[i], { speed = o.speed })
		bots[i].lastZone = 1
		remaining[i] = (crossings(lv, itins[i]))
	end
	local margin = math.floor(Config.Plan.ReleaseMargin / DT + 0.5)
	local holdRelease = {}
	local doneAt = {}
	local function filterFor(i)
		return function(b)
			return b.id ~= i and b.id < i
		end
	end
	local ctx = {
		allowed = function(bot, _body, door)
			if not Loop.passable(st, door) then
				return false
			end
			local f = filterFor(bot.index)
			return Loop.condition(st, door, f) or Loop.occupied(st, door, f)
		end,
		release = function(bot, t)
			local g = t.gate
			local all = true
			local last = 0
			for j = 1, K do
				if j ~= bot.index and (remaining[j][g] or 0) > 0 then
					all = false
				end
				if doneAt[j] and doneAt[j][g] then
					last = math.max(last, doneAt[j][g])
				end
			end
			if not all then
				return false
			end
			if st.step - last < margin then
				return false
			end
			holdRelease[bot.index] = holdRelease[bot.index] or {}
			holdRelease[bot.index][bot.ti] = st.step
			return true
		end,
	}
	local limit = st.n
	while st.step < limit and not st.won do
		local inputs = {}
		for i = 1, K do
			local body = st.bodies[i]
			local nx, ny = Planner.drive(bots[i], st, body, ctx)
			inputs[i] = { x = nx, y = ny }
		end
		Loop.step(st, inputs)
		for i = 1, K do
			local body = st.bodies[i]
			local z = Level.zoneAt(lv, body.tx, body.ty)
			local bot = bots[i]
			if z and z ~= bot.lastZone then
				for _, g in Planner.gatesBetween(lv, bot.lastZone, z) do
					remaining[i][g] = (remaining[i][g] or 0) - 1
					doneAt[i] = doneAt[i] or {}
					doneAt[i][g] = st.step
				end
				bot.lastZone = z
			end
			if bot.finished and not body.done and not st.won then
				Loop.finish(st, i)
			end
		end
	end
	local recs = Loop.recordings(st)
	local ok = st.won
	for i = 1, K - 1 do
		if not bots[i].finished then
			ok = false
		end
	end
	return {
		ok = ok,
		st = st,
		recs = recs,
		bots = bots,
		winStep = if st.won then st.step else nil,
		holds = holdRelease,
	}
end

--[[
	Проигрыш решения по петлям, как в игре: в петле i живой — i-й бот (его позиции из
	совместного прогона), остальные — записи прошлых петель. Возвращает ok, info.
]]
function Planner.verify(lv, recs: { Loop.Recording })
	local K = #recs
	local ghosts = {}
	local sx, sy = lv.start.x + 0.5, lv.start.y + 0.5
	for i = 1, K do
		local st = Loop.new(lv, ghosts, { { id = "live", x = sx, y = sy } })
		local plan = recs[i]
		local bad = nil
		while not Loop.over(st) do
			local s = st.step + 1
			if s > plan.n and i < K then
				Loop.finish(st, "live")
				break
			end
			local px, py = Loop.recAt(plan, s)
			for _, e in Loop.step(st, { live = { x = px, y = py } }) do
				if e.t == "paradox" or e.t == "blocked" then
					bad = bad or e
				end
			end
		end
		if bad then
			return false, { loop = i, event = bad }
		end
		if i < K and st.won then
			return false, { loop = i, reason = "won before the last loop" }
		end
		if i == K then
			if not st.won then
				return false, { loop = i, reason = "no win in the last loop" }
			end
			return true, { winStep = st.step, log = Loop.logString(st) }
		end
		local rec = Loop.recordings(st)[1]
		rec.loop = i
		table.insert(ghosts, rec)
	end
	return false, { reason = "no loops" }
end

-- Перестановки (для k − 1 ≤ 4 плит — не больше 24)
local function permutations(list)
	local out = {}
	local function rec(prefix, rest)
		if #rest == 0 then
			table.insert(out, prefix)
			return
		end
		for i, v in rest do
			local np = table.clone(prefix)
			table.insert(np, v)
			local nr = table.clone(rest)
			table.remove(nr, i)
			rec(np, nr)
		end
	end
	rec({}, list)
	return out
end

--[[
	Найти решение за k «тебя». Возвращает plan или nil, причина.
	plan = { itins, recs, holds, winStep, metrics }
]]
function Planner.solve(lv, opts: { [string]: any }?)
	local o = opts or {}
	local K = lv.k
	local vaultPlates = {}
	for _, p in lv.plates do
		if p.kind == "vault" then
			table.insert(vaultPlates, p.id)
		end
	end
	-- сначала менее закрытые плиты достаются ранним «я»
	table.sort(vaultPlates, function(a, b)
		local da, db = lv.zones[lv.plates[a].zone].depth, lv.zones[lv.plates[b].zone].depth
		if da ~= db then
			return da < db
		end
		return a < b
	end)
	local perms = permutations(vaultPlates)
	local tried = 0
	local limit = o.maxAssignments or Config.Plan.MaxAssignments
	local deadline = (lv.steps - math.floor(Config.Plan.FinishSlack / DT + 0.5))
	local best = nil

	local function attempt(itins)
		tried += 1
		local sim = Planner.simulate(lv, itins, o)
		if not sim.ok or not sim.winStep or sim.winStep > deadline then
			return nil
		end
		-- отпускание плит — на тех же шагах в петлях, где будущих «я» ещё нет
		local fixed = cloneItins(itins)
		for i, rel in sim.holds do
			for ti, s in rel do
				fixed[i][ti]["until"] = s
			end
		end
		local ok = Planner.verify(lv, sim.recs)
		if not ok then
			return nil
		end
		return { itins = fixed, recs = sim.recs, bots = sim.bots, winStep = sim.winStep }
	end

	local function dfs(itins, depth)
		if best or tried >= limit then
			return
		end
		local g, m, passers, firstTask = missing(lv, itins)
		if not g then
			best = attempt(itins)
			return
		end
		if depth > 8 then
			return
		end
		local door = lv.doors[g]
		if door.kind == "switch" then
			local plate
			for _, p in lv.plates do
				if p.kind == "switch" and p.color == door.color then
					plate = p.id
				end
			end
			for h = m - 1, 1, -1 do
				if helperCount(itins[h]) < 2 then
					local ni = cloneItins(itins)
					insertHelp(ni[h], { { kind = "hold", plate = plate, gate = g } })
					dfs(ni, depth + 1)
					if best then
						return
					end
				end
			end
		elseif door.kind == "lock" then
			local usedKeys = {}
			for _, tasks in itins do
				for _, t in tasks do
					if t.kind == "key" then
						usedKeys[t.key] = true
					end
				end
			end
			for u = m, 1, -1 do
				if helperCount(itins[u]) < 2 then
					for _, k in lv.keys do
						if not usedKeys[k.id] then
							local ni = cloneItins(itins)
							local before = if passers[u] then firstTask[u] else nil
							insertHelp(
								ni[u],
								{ { kind = "key", key = k.id }, { kind = "unlock", door = g } },
								before
							)
							dfs(ni, depth + 1)
							if best then
								return
							end
						end
					end
				end
			end
		end
	end

	for _, perm in perms do
		local itins = {}
		for i = 1, K - 1 do
			itins[i] = { { kind = "plate", plate = perm[i] } }
		end
		itins[K] = { { kind = "treasure" } }
		dfs(itins, 0)
		if best or tried >= limit then
			break
		end
	end
	if not best then
		return nil, "no plan (" .. tried .. " assignments)"
	end
	best.metrics = Planner.metrics(lv, best)
	best.tried = tried
	return best, nil
end

--[[
	Метрики решения: передачи плит (hold), ключи, глубина зависимостей, плотность по времени,
	ожидание (скука) и итоговая сложность D.
]]
function Planner.metrics(lv, plan)
	local relays, keys = 0, 0
	local dep = {}
	local K = #plan.itins
	for i, tasks in plan.itins do
		dep[i] = 0
		for _, t in tasks do
			if t.kind == "hold" then
				relays += 1
			elseif t.kind == "key" then
				keys += 1
			end
		end
	end
	-- глубина: цепочка «держит для» по воротам
	local servedBy = {}
	for h, tasks in plan.itins do
		for _, t in tasks do
			if t.kind == "hold" then
				servedBy[t.gate] = h
			end
		end
	end
	local depth = 0
	for i = 1, K do
		local count = crossings(lv, plan.itins[i])
		local d = 0
		for g in count do
			if servedBy[g] then
				d = math.max(d, 1 + (dep[servedBy[g]] or 0))
			end
		end
		dep[i] = d
		depth = math.max(depth, d)
	end
	local idleMax, idleSum = 0, 0
	for i, bot in plan.bots do
		local endStep = if i == K then plan.winStep else (bot.arrive or plan.winStep)
		local _ = endStep
		idleMax = math.max(idleMax, bot.idleMax)
		idleSum += bot.idle
	end
	local finish = plan.winStep * DT
	local usable = Config.Loop.Length - Config.Plan.FinishSlack
	local tight = finish / usable
	local gates = 0
	for _, d in lv.doors do
		if d.kind ~= "vault" then
			gates += 1
		end
	end
	local D = 5 * (K - 2) + 4 * relays + 1.5 * keys + 2 * depth + 3 * tight + 0.5 * gates
	return {
		k = K,
		relays = relays,
		keys = keys,
		depth = depth,
		finish = finish,
		tight = tight,
		gates = gates,
		idleMax = idleMax * DT,
		idleMean = idleSum * DT / K,
		D = math.floor(D * 10 + 0.5) / 10,
	}
end

-------------------------------------------------------------------------------
-- Игра по петлям базовыми политиками (тест баланса)
-------------------------------------------------------------------------------
--[[
	Новичок: в начале петли смотрит, какие золотые плиты займут призраки (по их последним
	позициям). Все заняты — бежит к сокровищу. Иначе — к ближайшей свободной золотой плите;
	дорога закрыта цветной дверью, которую никто не держит, — встаёт на её переключатель
	навсегда (без «передачи»); закрыт замок — сначала идёт за ключом.
]]
local function noviceTasks(lv, ghosts)
	local held = {}
	for _, rec in ghosts do
		local x, y = Loop.recAt(rec, rec.n)
		local p = Level.plateAt(lv, math.floor(x), math.floor(y))
		if p then
			held[p.id] = true
		end
	end
	local free = {}
	for _, p in lv.plates do
		if p.kind == "vault" and not held[p.id] then
			table.insert(free, p)
		end
	end
	local tasks = {}
	local targetZone, final
	if #free == 0 then
		targetZone, final = lv.vaultZone, { kind = "treasure" }
	else
		table.sort(free, function(a, b)
			local ra = Planner.route(lv, lv.start.x, lv.start.y, a.x, a.y)
			local rb = Planner.route(lv, lv.start.x, lv.start.y, b.x, b.y)
			local la, lb = if ra then #ra else 999, if rb then #rb else 999
			if la ~= lb then
				return la < lb
			end
			return a.id < b.id
		end)
		targetZone, final = free[1].zone, { kind = "plate", plate = free[1].id }
	end
	local usedKey = {}
	for _, g in Planner.gatesBetween(lv, 1, targetZone) do
		local door = lv.doors[g]
		if door.kind == "switch" then
			local sp
			for _, p in lv.plates do
				if p.kind == "switch" and p.color == door.color then
					sp = p
				end
			end
			if sp and not held[sp.id] then
				-- без «передачи»: встаёт на переключатель навсегда
				table.insert(tasks, { kind = "plate", plate = sp.id })
				return tasks
			end
		elseif door.kind == "lock" then
			for _, k in lv.keys do
				if not usedKey[k.id] then
					usedKey[k.id] = true
					table.insert(tasks, { kind = "key", key = k.id })
					table.insert(tasks, { kind = "unlock", door = g })
					break
				end
			end
		end
	end
	table.insert(tasks, final)
	return tasks
end

--[[
	Играть уровень по петлям политикой policy: "pro" (решение), "novice", "random", "idle".
	loops — сколько петель есть (по умолчанию k). Возвращает { won, loop, paradoxes }.
]]
function Planner.play(lv, policy: string, opts: { [string]: any }?)
	local o = opts or {}
	local loops = o.loops or lv.k
	local plan = o.plan
	local ghosts = {}
	local sx, sy = lv.start.x + 0.5, lv.start.y + 0.5
	local rng = Rng.new(o.seed or 1)
	local paradoxes = 0
	for i = 1, loops do
		local st = Loop.new(lv, ghosts, { { id = "live", x = sx, y = sy } })
		local tasks
		if policy == "pro" then
			tasks = plan.itins[math.min(i, #plan.itins)]
		elseif policy == "novice" then
			tasks = noviceTasks(lv, ghosts)
		elseif policy == "random" then
			tasks = {}
			for j = 1, 3 do
				local tx, ty
				repeat
					tx, ty = rng:int(0, lv.w - 1), rng:int(0, lv.h - 1)
				until Level.isFloor(lv, tx, ty) and not Level.doorAt(lv, tx, ty)
				table.insert(tasks, { kind = "goto", x = tx, y = ty, hop = j < 3 })
			end
		else
			tasks = {}
		end
		local bot = Planner.newBot(lv, i, tasks, {
			speed = o.speed,
			reaction = o.reaction or (if policy == "novice" then 0.8 else 0),
			naive = policy == "novice",
		})
		while not Loop.over(st) do
			local body = st.bodies[#st.bodies]
			local nx, ny = body.x, body.y
			if policy ~= "idle" then
				nx, ny = Planner.drive(bot, st, body)
			end
			for _, e in Loop.step(st, { live = { x = nx, y = ny } }) do
				if e.t == "paradox" then
					paradoxes += 1
				end
			end
			if bot.finished then
				Loop.finish(st, "live")
			end
		end
		if st.won then
			return { won = true, loop = i, paradoxes = paradoxes }
		end
		local rec = Loop.recordings(st)[1]
		rec.loop = i
		table.insert(ghosts, rec)
	end
	return { won = false, loop = loops, paradoxes = paradoxes }
end

return Planner
