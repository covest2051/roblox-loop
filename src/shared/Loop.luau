--[[
	Loop — модель одной петли (чистая функция шага, детерминированная).

	Тела: призраки (повторяют запись) и живые (позиция — вход модели: из персонажа на сервере,
	от бота в тестах). Каждый шаг (Config.Loop.Step):
	  1. позиции: призрак — запись[шаг] (после конца записи стоит на месте), живой — вход;
	     вход в закрытую дверь: призрак → ПАРАДОКС («door»), живой → откат на прошлую позицию;
	  2. события: призраки — только записанные (взять ключ k; открыть замок d); если ключа
	     на месте нет → ПАРАДОКС («key»). Живые — автоматически: ключ берётся, если руки пусты,
	     замок открывается, если ключ в руках и стоишь рядом. У прошлого приоритет: призраки
	     обрабатываются раньше живых;
	  3. плиты: нажата, если на ней стоит не рассыпавшееся тело;
	  4. двери: switch — нажата плита цвета; vault — нажаты все золотые; lock — отперт;
	     тело в проёме держит дверь открытой; иначе закрывается через CloseDelay;
	  5. победа: тело на клетке сокровища.
	Рассыпавшийся призрак стоит на месте и ничего не нажимает, ключ из рук падает на его клетку.

	Запись: { xs, ys, n, ev = { [шаг] = { "pick", keyId } | { "unlock", doorId } }, start }.
]]

local Shared = script.Parent
local Config = require(Shared.Config)
local Level = require(Shared.Level)

local Loop = {}

local DT = Config.Loop.Step
local CLOSE_STEPS = math.max(1, math.floor(Config.Loop.CloseDelay / DT + 0.5))

export type Recording = {
	xs: { number },
	ys: { number },
	n: number, -- последний записанный шаг (дальше — стоит)
	ev: { [number]: { any } },
	x0: number,
	y0: number,
	owner: number?,
	name: string?,
	loop: number?, -- номер петли (цвет призрака)
	skin: string?,
	trail: string?,
	rewind: string?,
}

export type Body = {
	i: number, -- порядок в модели (призраки по петлям, потом живые)
	id: any, -- живой: id игрока/бота; призрак: номер записи
	ghost: boolean,
	rec: Recording,
	x: number,
	y: number,
	tx: number,
	ty: number,
	broken: boolean,
	carry: number?,
	done: boolean,
}

-- Записать позицию: клетки → компактно (0.01 клетки ≈ 0.06 studs)
local function q(v: number): number
	return math.floor(v * 100 + 0.5) / 100
end
Loop.quantize = q

function Loop.newRecording(x0: number, y0: number): Recording
	return { xs = {}, ys = {}, n = 0, ev = {}, x0 = q(x0), y0 = q(y0) }
end

-- Позиция записи на шаге s (s = 0 — старт; после n — последняя)
function Loop.recAt(rec: Recording, s: number): (number, number)
	if s <= 0 or rec.n == 0 then
		return rec.x0, rec.y0
	end
	local i = math.min(s, rec.n)
	return rec.xs[i], rec.ys[i]
end

-- Плавная позиция для клиента (s — дробный шаг)
function Loop.recLerp(rec: Recording, s: number): (number, number)
	local s0 = math.floor(s)
	local f = s - s0
	local ax, ay = Loop.recAt(rec, s0)
	local bx, by = Loop.recAt(rec, s0 + 1)
	return ax + (bx - ax) * f, ay + (by - ay) * f
end

--[[
	ghosts — записи прошлых петель по порядку; lives — { {id, x, y} } живые в этой петле.
]]
function Loop.new(lv, ghosts: { Recording }, lives: { { id: any, x: number, y: number } })
	local st: any = {
		lv = lv,
		step = 0,
		n = lv.steps,
		bodies = {},
		keys = {},
		doors = {},
		plates = {},
		won = false,
		winBy = nil,
		paradoxes = 0,
		log = {}, -- все события петли по порядку (для теста детерминизма)
	}
	for i, rec in ghosts do
		local x, y = Loop.recAt(rec, 0)
		table.insert(st.bodies, {
			i = #st.bodies + 1,
			id = i,
			ghost = true,
			rec = rec,
			x = x,
			y = y,
			tx = math.floor(x),
			ty = math.floor(y),
			broken = false,
			carry = nil,
			done = false,
		})
	end
	for _, l in lives do
		table.insert(st.bodies, {
			i = #st.bodies + 1,
			id = l.id,
			ghost = false,
			rec = Loop.newRecording(l.x, l.y),
			x = q(l.x),
			y = q(l.y),
			tx = math.floor(l.x),
			ty = math.floor(l.y),
			broken = false,
			carry = nil,
			done = false,
		})
	end
	for _, k in lv.keys do
		st.keys[k.id] = { state = "lying", x = k.x, y = k.y, by = nil }
	end
	for _, d in lv.doors do
		st.doors[d.id] = { open = false, closing = 0, unlocked = false, by = nil }
	end
	for _, p in lv.plates do
		st.plates[p.id] = false
	end
	Loop.updateWorld(st, {})
	return st
end

function Loop.bodyOf(st, id: any)
	for _, b in st.bodies do
		if not b.ghost and b.id == id then
			return b
		end
	end
	return nil
end

-- Открыта ли дверь (для входа на следующем шаге): открыта или ещё закрывается
function Loop.passable(st, door): boolean
	local d = st.doors[door.id]
	return d.open
end

-- Условие двери без учёта «держат в проёме». filter(body) — какие тела считать (решатель)
function Loop.condition(st, door, filter: ((any) -> boolean)?): boolean
	local lv = st.lv
	if door.kind == "lock" then
		local d = st.doors[door.id]
		if not d.unlocked then
			return false
		end
		if filter then
			local by = st.bodies[d.by]
			return by == nil or filter(by)
		end
		return true
	end
	local function pressed(p)
		if not filter then
			return st.plates[p.id]
		end
		for _, b in st.bodies do
			if not b.broken and b.tx == p.x and b.ty == p.y and filter(b) then
				return true
			end
		end
		return false
	end
	if door.kind == "switch" then
		for _, p in lv.plates do
			if p.kind == "switch" and p.color == door.color and pressed(p) then
				return true
			end
		end
		return false
	end
	-- vault
	for _, p in lv.plates do
		if p.kind == "vault" and not pressed(p) then
			return false
		end
	end
	return true
end

function Loop.occupied(st, door, filter: ((any) -> boolean)?): boolean
	for _, b in st.bodies do
		if not b.broken and b.tx == door.x and b.ty == door.y and (filter == nil or filter(b)) then
			return true
		end
	end
	return false
end

-- Сколько золотых плит нажато (для ламп на двери хранилища)
function Loop.vaultCount(st): (number, number)
	local n, total = 0, 0
	for _, p in st.lv.plates do
		if p.kind == "vault" then
			total += 1
			if st.plates[p.id] then
				n += 1
			end
		end
	end
	return n, total
end

local function emit(st, events, e)
	e.step = st.step
	table.insert(events, e)
	table.insert(st.log, e)
end

function Loop.updateWorld(st, events)
	local lv = st.lv
	for _, p in lv.plates do
		local on = false
		for _, b in st.bodies do
			if not b.broken and b.tx == p.x and b.ty == p.y then
				on = true
				break
			end
		end
		if on ~= st.plates[p.id] then
			st.plates[p.id] = on
			emit(st, events, { t = "plate", plate = p.id, on = on })
		end
	end
	for _, door in lv.doors do
		local d = st.doors[door.id]
		local want = Loop.condition(st, door) or Loop.occupied(st, door)
		local was = d.open
		if want then
			d.open = true
			d.closing = 0
		elseif d.open then
			d.closing += 1
			if d.closing >= CLOSE_STEPS then
				d.open = false
				d.closing = 0
			end
		end
		if d.open ~= was then
			emit(st, events, { t = "door", door = door.id, open = d.open })
		end
	end
	if not st.won then
		local tr = lv.treasure
		for _, b in st.bodies do
			if not b.broken and b.tx == tr.x and b.ty == tr.y then
				st.won = true
				st.winBy = b.i
				emit(st, events, { t = "win", body = b.i })
				break
			end
		end
	end
end

-- Клетки на отрезке (для проверки прохода сквозь стену при рывке)
local function segmentBlocked(st, ax, ay, bx, by): (boolean, any)
	local lv = st.lv
	local dist = math.max(math.abs(bx - ax), math.abs(by - ay))
	local n = math.max(1, math.ceil(dist / 0.25))
	local lastX, lastY = math.floor(ax), math.floor(ay)
	for i = 1, n do
		local px, py = ax + (bx - ax) * i / n, ay + (by - ay) * i / n
		local tx, ty = math.floor(px), math.floor(py)
		if tx ~= lastX or ty ~= lastY then
			if not Level.isFloor(lv, tx, ty) then
				return true, nil
			end
			local door = Level.doorAt(lv, tx, ty)
			if door and not Loop.passable(st, door) then
				return true, door
			end
			lastX, lastY = tx, ty
		end
	end
	return false, nil
end

local function breakBody(st, events, b, reason: string, extra: { [string]: any }?)
	b.broken = true
	st.paradoxes += 1
	local e = { t = "paradox", body = b.i, rec = b.id, reason = reason, x = b.x, y = b.y }
	if extra then
		for k, v in extra do
			e[k] = v
		end
	end
	emit(st, events, e)
	if b.carry then
		local k = st.keys[b.carry]
		k.state = "lying"
		k.x, k.y = b.tx, b.ty
		k.by = nil
		emit(st, events, { t = "drop", key = b.carry, body = b.i, x = b.tx, y = b.ty })
		b.carry = nil
	end
end

local function adjacentLock(st, b)
	for _, door in st.lv.doors do
		if door.kind == "lock" and not st.doors[door.id].unlocked then
			if math.abs(door.x - b.tx) + math.abs(door.y - b.ty) == 1 then
				return door
			end
		end
	end
	return nil
end

local function pick(st, events, b, keyId)
	local k = st.keys[keyId]
	k.state = "carried"
	k.by = b.i
	b.carry = keyId
	if not b.ghost then
		b.rec.ev[st.step] = { "pick", keyId }
	end
	emit(st, events, { t = "pick", body = b.i, key = keyId })
end

local function unlock(st, events, b, door)
	local key = b.carry
	if key then
		st.keys[key].state = "used"
		st.keys[key].by = nil
	end
	b.carry = nil
	local d = st.doors[door.id]
	if not d.unlocked then
		d.unlocked = true
		d.by = b.i
	end
	if not b.ghost then
		b.rec.ev[st.step] = { "unlock", door.id }
	end
	emit(st, events, { t = "unlock", body = b.i, door = door.id, key = key })
end

--[[
	Шаг. inputs[id] = { x, y } — новые позиции живых (нет — стоит на месте).
	Возвращает события шага.
]]
function Loop.step(st, inputs: { [any]: { x: number, y: number } }?)
	local events = {}
	if st.step >= st.n or st.won then
		return events
	end
	st.step += 1
	local s = st.step
	local lv = st.lv
	-- 1. позиции
	for _, b in st.bodies do
		if b.broken then
			continue
		end
		local nx, ny
		if b.ghost then
			nx, ny = Loop.recAt(b.rec, s)
		elseif b.done then
			nx, ny = b.x, b.y
		else
			local inp = inputs and inputs[b.id]
			if inp then
				nx, ny = q(inp.x), q(inp.y)
			else
				nx, ny = b.x, b.y
			end
		end
		local ntx, nty = math.floor(nx), math.floor(ny)
		if ntx ~= b.tx or nty ~= b.ty or nx ~= b.x or ny ~= b.y then
			local blocked, door = segmentBlocked(st, b.x, b.y, nx, ny)
			if blocked then
				if b.ghost then
					breakBody(st, events, b, "door", { door = door and door.id })
					continue
				else
					emit(st, events, { t = "blocked", body = b.i, door = door and door.id })
					nx, ny = b.x, b.y
					ntx, nty = b.tx, b.ty
				end
			end
		end
		b.x, b.y, b.tx, b.ty = nx, ny, ntx, nty
		if not b.ghost and not b.done then
			b.rec.n = s
			b.rec.xs[s] = nx
			b.rec.ys[s] = ny
		end
	end
	-- 2. события: сначала призраки (у прошлого приоритет), потом живые
	for _, b in st.bodies do
		if b.ghost and not b.broken then
			local ev = b.rec.ev[s]
			if ev then
				if ev[1] == "pick" then
					local k = st.keys[ev[2]]
					if k and k.state == "lying" and k.x == b.tx and k.y == b.ty and not b.carry then
						pick(st, events, b, ev[2])
					else
						local by = if k and k.state == "carried" then k.by else nil
						breakBody(st, events, b, "key", { key = ev[2], by = by })
					end
				elseif ev[1] == "unlock" then
					local door = lv.doors[ev[2]]
					if door and b.carry then
						unlock(st, events, b, door)
					end
				end
			end
		end
	end
	for _, b in st.bodies do
		if not b.ghost and not b.broken and not b.done then
			if not b.carry then
				for id, k in st.keys do
					if k.state == "lying" and k.x == b.tx and k.y == b.ty then
						pick(st, events, b, id)
						break
					end
				end
			end
			if b.carry then
				local door = adjacentLock(st, b)
				if door then
					unlock(st, events, b, door)
				end
			end
		end
	end
	-- 3–5. плиты, двери, победа
	Loop.updateWorld(st, events)
	return events
end

-- Живой закончил петлю раньше (⟲): запись обрывается, дальше призрак стоит на месте
function Loop.finish(st, id: any)
	local b = Loop.bodyOf(st, id)
	if b and not b.done then
		b.done = true
		b.rec.n = st.step
	end
end

function Loop.allDone(st): boolean
	for _, b in st.bodies do
		if not b.ghost and not b.done then
			return false
		end
	end
	return true
end

function Loop.over(st): boolean
	return st.won or st.step >= st.n or Loop.allDone(st)
end

-- Записи живых (станут призраками следующей петли), в порядке живых
function Loop.recordings(st): { Recording }
	local out = {}
	for _, b in st.bodies do
		if not b.ghost then
			table.insert(out, b.rec)
		end
	end
	return out
end

-- Журнал событий строкой (детерминизм: одинаковые входы → одинаковые строки)
function Loop.logString(st): string
	local parts = {}
	for _, e in st.log do
		local keys = {}
		for k in e do
			table.insert(keys, k)
		end
		table.sort(keys)
		local kv = {}
		for _, k in keys do
			table.insert(kv, k .. "=" .. tostring(e[k]))
		end
		table.insert(parts, table.concat(kv, ","))
	end
	return table.concat(parts, ";")
end

--[[
	Предсказание по призракам (клиент): прогон петли только с записями.
	Возвращает doors[id] = { {from, to}, ... } интервалы «открыта» в шагах и события.
]]
function Loop.predict(lv, ghosts: { Recording })
	local st = Loop.new(lv, ghosts, {})
	local open = {}
	local since = {}
	for _, d in lv.doors do
		open[d.id] = {}
		if st.doors[d.id].open then
			since[d.id] = 0
		end
	end
	local events = {}
	while st.step < st.n and not st.won do
		for _, e in Loop.step(st, nil) do
			table.insert(events, e)
			if e.t == "door" then
				if e.open then
					since[e.door] = e.step
				elseif since[e.door] then
					table.insert(open[e.door], { since[e.door], e.step })
					since[e.door] = nil
				end
			end
		end
	end
	for id, s in since do
		table.insert(open[id], { s, st.n + 1 })
	end
	return { doors = open, events = events, won = st.won }
end

return Loop
