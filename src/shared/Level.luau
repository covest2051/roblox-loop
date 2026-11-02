--[[
	Level — генератор уровня из seed (чистая логика: сервер, клиент и тесты строят одно и то же).

	Сетка клеток w×h (0 — стена, 1 — пол), комнаты rows×cols размером roomW×roomH со стенами
	в 1 клетку. Комнаты соединены остовным деревом; часть рёбер — «ворота»:
	  switch — дверь цвета c, открыта, пока нажата плита того же цвета (плита — «до» двери);
	  lock   — замок, открывается ключом (ключ — «до» замка);
	  vault  — дверь хранилища: открыта, пока нажаты ВСЕ золотые плиты.
	Остальные рёбра — проход (open) или снесённая стена (wide). Комнаты без ворот между ними —
	одна «зона»; зоны образуют дерево с корнем в зоне старта.
	Золотых плит k − 1: в момент входа в хранилище нужно k тел одновременно (k − 1 на плитах
	и одно в проёме) — это и есть нижняя оценка «не меньше k петель».
	Решаемость за k проверяет Planner (генератор кампании принимает только такие уровни).

	Координаты: клетка (x, y), 0 ≤ x < w, 0 ≤ y < h; позиция тела — дробная (x, y) в клетках,
	центр клетки (x + 0.5, y + 0.5). В мире y клетки — это ось Z.
]]

local Shared = script.Parent
local Config = require(Shared.Config)
local Rng = require(Shared.Rng)

local Level = {}

Level.WALL = 0
Level.FLOOR = 1

export type Spec = {
	k: number, -- сколько «тебя» нужно (золотых плит k − 1)
	rows: number,
	cols: number,
	roomW: number,
	roomH: number,
	switches: number,
	locks: number,
	wide: number?, -- доля открытых рёбер, которые становятся залами
}

export type Door = {
	id: number,
	x: number,
	y: number,
	kind: string, -- switch | lock | vault
	color: number?,
	axis: string, -- "x": проход вдоль X (дверь в вертикальной стене), "y": вдоль Y
	parent: number, -- зона со стороны старта
	child: number,
	frontP: { x: number, y: number },
	frontC: { x: number, y: number },
}

export type Plate = { id: number, x: number, y: number, kind: string, color: number?, zone: number }
export type Key = { id: number, x: number, y: number, zone: number }

function Level.idx(lv, x: number, y: number): number
	return y * lv.w + x + 1
end

function Level.cell(lv, x: number, y: number): number
	if x < 0 or y < 0 or x >= lv.w or y >= lv.h then
		return Level.WALL
	end
	return lv.cells[y * lv.w + x + 1]
end

function Level.isFloor(lv, x: number, y: number): boolean
	return Level.cell(lv, x, y) == Level.FLOOR
end

-- Клетка, в которой стоит тело с дробной позицией
function Level.tileOf(px: number, py: number): (number, number)
	return math.floor(px), math.floor(py)
end

function Level.doorAt(lv, x: number, y: number): Door?
	return lv.doorAt[y * lv.w + x + 1]
end

function Level.plateAt(lv, x: number, y: number): Plate?
	return lv.plateAt[y * lv.w + x + 1]
end

function Level.zoneAt(lv, x: number, y: number): number?
	return lv.zoneAt[y * lv.w + x + 1]
end

-- Мир → клетки и обратно (origin — угол клетки (0, 0) на уровне пола)
function Level.toWorld(px: number, py: number): (number, number)
	return px * Config.Grid.Tile, py * Config.Grid.Tile
end

function Level.fromWorld(wx: number, wz: number): (number, number)
	return wx / Config.Grid.Tile, wz / Config.Grid.Tile
end

local function shuffle(rng, t)
	for i = #t, 2, -1 do
		local j = rng:int(1, i)
		t[i], t[j] = t[j], t[i]
	end
	return t
end

--[[
	Сгенерировать уровень. Возвращает level или nil, причина (тогда генератор кампании
	пробует следующий seed).
]]
function Level.generate(spec: Spec, seed: number): (any, string?)
	local rng = Rng.new(seed)
	local R, C = spec.rows, spec.cols
	local a, b = spec.roomW, spec.roomH
	local w, h = C * (a + 1) + 1, R * (b + 1) + 1
	local lv: any = {
		w = w,
		h = h,
		seed = seed,
		spec = spec,
		k = spec.k,
		steps = math.floor(Config.Loop.Length / Config.Loop.Step + 0.5),
		cells = table.create(w * h, Level.WALL),
		rooms = {},
		doors = {},
		plates = {},
		keys = {},
		zones = {},
		doorAt = {},
		plateAt = {},
		keyAt = {},
		zoneAt = {},
		openings = {}, -- проходы без двери: { x, y }
	}
	local function carve(x, y)
		lv.cells[y * w + x + 1] = Level.FLOOR
	end

	-- комнаты
	for r = 0, R - 1 do
		for c = 0, C - 1 do
			local x0, y0 = c * (a + 1) + 1, r * (b + 1) + 1
			local room =
				{ id = r * C + c + 1, r = r, c = c, x0 = x0, y0 = y0, x1 = x0 + a - 1, y1 = y0 + b - 1 }
			for x = room.x0, room.x1 do
				for y = room.y0, room.y1 do
					carve(x, y)
				end
			end
			table.insert(lv.rooms, room)
		end
	end
	local function roomAt(r, c)
		if r < 0 or c < 0 or r >= R or c >= C then
			return nil
		end
		return lv.rooms[r * C + c + 1]
	end

	-- остовное дерево: случайный DFS от комнаты старта (нижний ряд)
	local startRoom = roomAt(R - 1, rng:int(0, C - 1))
	local visited = { [startRoom.id] = true }
	local adj: { [number]: { any } } = {}
	local edges = {}
	local stack = { startRoom }
	while #stack > 0 do
		local cur = stack[#stack]
		local nbs = {}
		for _, d in { { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 } } do
			local nb = roomAt(cur.r + d[1], cur.c + d[2])
			if nb and not visited[nb.id] then
				table.insert(nbs, nb)
			end
		end
		if #nbs == 0 then
			table.remove(stack)
		else
			local nb = nbs[rng:int(1, #nbs)]
			visited[nb.id] = true
			local e = { a = cur, b = nb, kind = "open" }
			table.insert(edges, e)
			adj[cur.id] = adj[cur.id] or {}
			adj[nb.id] = adj[nb.id] or {}
			table.insert(adj[cur.id], e)
			table.insert(adj[nb.id], e)
			table.insert(stack, nb)
		end
	end

	-- глубина комнат от старта; хранилище — самый глубокий лист
	local depth = { [startRoom.id] = 0 }
	local parentEdge = {}
	local queue = { startRoom }
	local qi = 1
	while qi <= #queue do
		local cur = queue[qi]
		qi += 1
		for _, e in adj[cur.id] or {} do
			local nb = if e.a == cur then e.b else e.a
			if depth[nb.id] == nil then
				depth[nb.id] = depth[cur.id] + 1
				parentEdge[nb.id] = e
				table.insert(queue, nb)
			end
		end
	end
	local vault, best = nil, -1
	for _, room in shuffle(rng, table.clone(lv.rooms)) do
		if room ~= startRoom and #(adj[room.id] or {}) == 1 and depth[room.id] > best then
			vault, best = room, depth[room.id]
		end
	end
	if not vault then
		return nil, "no leaf for the vault"
	end
	local vaultEdge = parentEdge[vault.id]
	vaultEdge.kind = "vault"
	lv.vaultRoom = vault.id

	-- ворота: switch и lock на случайных рёбрах (не ребро хранилища)
	local cand = {}
	for _, e in edges do
		if e ~= vaultEdge then
			table.insert(cand, e)
		end
	end
	shuffle(rng, cand)
	local nGates = spec.switches + spec.locks
	if #cand < nGates then
		return nil, "not enough edges for gates"
	end
	for i = 1, nGates do
		cand[i].kind = if i <= spec.switches then "switch" else "lock"
	end
	for i = nGates + 1, #cand do
		if rng:next() < (spec.wide or 0) then
			cand[i].kind = "wide"
		end
	end

	-- зоны: комнаты, соединённые open/wide
	local zoneOfRoom = {}
	local zoneCount = 0
	local function flood(room, z)
		zoneOfRoom[room.id] = z
		for _, e in adj[room.id] or {} do
			if e.kind == "open" or e.kind == "wide" then
				local nb = if e.a == room then e.b else e.a
				if not zoneOfRoom[nb.id] then
					flood(nb, z)
				end
			end
		end
	end
	-- нумерация зон в порядке BFS от старта (зона 1 — старт)
	for _, room in queue do
		if not zoneOfRoom[room.id] then
			zoneCount += 1
			lv.zones[zoneCount] = { id = zoneCount, rooms = {}, parent = nil, gate = nil, depth = 0 }
			flood(room, zoneCount)
		end
	end
	for _, room in lv.rooms do
		room.zone = zoneOfRoom[room.id]
		table.insert(lv.zones[room.zone].rooms, room.id)
	end

	-- двери и проходы
	local colorN = 0
	local function wallTile(e)
		local ra, rb = e.a, e.b
		if ra.r == rb.r then
			local left = if ra.c < rb.c then ra else rb
			return left.x1 + 1, left.y0 + math.floor(b / 2), "x"
		else
			local top = if ra.r < rb.r then ra else rb
			return top.x0 + math.floor(a / 2), top.y1 + 1, "y"
		end
	end
	for _, e in edges do
		local x, y, axis = wallTile(e)
		if e.kind == "wide" then
			local ra = e.a
			if axis == "x" then
				for yy = ra.y0, ra.y1 do
					carve(x, yy)
				end
			else
				for xx = ra.x0, ra.x1 do
					carve(xx, y)
				end
			end
		elseif e.kind == "open" then
			carve(x, y)
			table.insert(lv.openings, { x = x, y = y, axis = axis })
		else
			carve(x, y)
			-- ориентация: parent — комната ближе к старту
			local pr, cr = e.a, e.b
			if depth[pr.id] > depth[cr.id] then
				pr, cr = cr, pr
			end
			local door: any = {
				id = #lv.doors + 1,
				x = x,
				y = y,
				kind = e.kind,
				axis = axis,
				parent = zoneOfRoom[pr.id],
				child = zoneOfRoom[cr.id],
			}
			if e.kind == "switch" then
				colorN += 1
				door.color = colorN
			end
			local function side(room)
				if axis == "x" then
					return if room.x1 < x then { x = x - 1, y = y } else { x = x + 1, y = y }
				else
					return if room.y1 < y then { x = x, y = y - 1 } else { x = x, y = y + 1 }
				end
			end
			door.frontP = side(pr)
			door.frontC = side(cr)
			table.insert(lv.doors, door)
			lv.doorAt[y * w + x + 1] = door
			local zc = lv.zones[door.child]
			zc.parent = door.parent
			zc.gate = door.id
			if e.kind == "vault" then
				lv.vaultDoor = door.id
				lv.vaultZone = door.child
			end
		end
	end
	for _, z in lv.zones do
		local d, cur = 0, z
		while cur.parent do
			d += 1
			cur = lv.zones[cur.parent]
		end
		z.depth = d
	end

	-- зона каждой клетки пола (проходы и залы — зона комнаты; двери — без зоны)
	for _, room in lv.rooms do
		for x = room.x0, room.x1 do
			for y = room.y0, room.y1 do
				lv.zoneAt[y * w + x + 1] = room.zone
			end
		end
	end
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local i = y * w + x + 1
			if lv.cells[i] == Level.FLOOR and not lv.zoneAt[i] and not lv.doorAt[i] then
				for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
					local z = lv.zoneAt[(y + d[2]) * w + x + d[1] + 1]
					if z and Level.isFloor(lv, x + d[1], y + d[2]) then
						lv.zoneAt[i] = z
						break
					end
				end
			end
		end
	end

	-- старт и сокровище
	local function center(room)
		return room.x0 + math.floor(a / 2), room.y0 + math.floor(b / 2)
	end
	local sx, sy = center(startRoom)
	lv.start = { x = sx, y = sy }
	lv.starts = { { x = sx, y = sy } }
	for _, d in { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } } do
		if #lv.starts < Config.Loop.MaxPlayers and Level.isFloor(lv, sx + d[1], sy + d[2]) then
			table.insert(lv.starts, { x = sx + d[1], y = sy + d[2] })
		end
	end
	local tx, ty = center(vault)
	lv.treasure = { x = tx, y = ty }

	-- свободные клетки комнаты для предметов: не перед проходами, не на старте
	local used = {}
	for _, s in lv.starts do
		used[s.y * w + s.x + 1] = true
	end
	local function isFront(x, y)
		for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			local nx, ny = x + d[1], y + d[2]
			local i = ny * w + nx + 1
			if Level.isFloor(lv, nx, ny) and not lv.zoneAt[i] then
				return true -- дверь
			end
			for _, o in lv.openings do
				if o.x == nx and o.y == ny then
					return true
				end
			end
		end
		return false
	end
	local function freeTiles(room, corners)
		local out = {}
		for x = room.x0, room.x1 do
			for y = room.y0, room.y1 do
				local i = y * w + x + 1
				local corner = (x == room.x0 or x == room.x1) and (y == room.y0 or y == room.y1)
				if not used[i] and not isFront(x, y) and (not corners or corner) then
					table.insert(out, { x = x, y = y })
				end
			end
		end
		return out
	end
	local function placeIn(room, corners)
		local tiles = freeTiles(room, corners)
		if #tiles == 0 and corners then
			tiles = freeTiles(room, false)
		end
		if #tiles == 0 then
			return nil
		end
		local t = tiles[rng:int(1, #tiles)]
		used[t.y * w + t.x + 1] = true
		return t
	end

	-- поддеревья зон: inSub[g][z] — зона z за воротами g
	local function under(z, gateZone)
		local cur = lv.zones[z]
		while cur do
			if cur.id == gateZone then
				return true
			end
			cur = cur.parent and lv.zones[cur.parent]
		end
		return false
	end
	local normalRooms = {}
	for _, room in lv.rooms do
		if room.id ~= vault.id then
			table.insert(normalRooms, room)
		end
	end

	-- золотые плиты: чаще за воротами (иначе ворота бессмысленны)
	local n = spec.k - 1
	local weights = {}
	for _, room in normalRooms do
		weights[room.id] = 1 + lv.zones[room.zone].depth * 1.5
	end
	local plateRooms = {}
	for _ = 1, n do
		local total = 0
		for _, room in normalRooms do
			total += weights[room.id]
		end
		local r = rng:next() * total
		local pick = normalRooms[#normalRooms]
		for _, room in normalRooms do
			r -= weights[room.id]
			if r <= 0 then
				pick = room
				break
			end
		end
		table.insert(plateRooms, pick)
		weights[pick.id] *= 0.35 -- реже две плиты в одной комнате
	end
	for _, room in plateRooms do
		local t = placeIn(room, false)
		if not t then
			return nil, "no tile for a vault plate"
		end
		local p = { id = #lv.plates + 1, x = t.x, y = t.y, kind = "vault", zone = room.zone }
		table.insert(lv.plates, p)
		lv.plateAt[t.y * w + t.x + 1] = p
	end

	-- хотя бы одна золотая плита без цветных дверей на пути: первому «я» есть что делать
	local function switchFree(z)
		local cur = lv.zones[z]
		while cur and cur.parent do
			if lv.doors[cur.gate].kind == "switch" then
				return false
			end
			cur = lv.zones[cur.parent]
		end
		return true
	end
	local anyFree = false
	for _, p in lv.plates do
		if switchFree(p.zone) then
			anyFree = true
		end
	end
	if not anyFree then
		return nil, "every vault plate is behind a switch door"
	end

	-- переключатели и ключи: в комнате, которая НЕ за своими воротами
	for _, door in lv.doors do
		if door.kind == "switch" or door.kind == "lock" then
			local opts = {}
			for _, room in normalRooms do
				if not under(room.zone, door.child) then
					table.insert(opts, room)
				end
			end
			if #opts == 0 then
				return nil, "no room before a gate"
			end
			local room = opts[rng:int(1, #opts)]
			if door.kind == "switch" then
				local t = placeIn(room, false)
				if not t then
					return nil, "no tile for a switch"
				end
				local p = {
					id = #lv.plates + 1,
					x = t.x,
					y = t.y,
					kind = "switch",
					color = door.color,
					zone = room.zone,
				}
				table.insert(lv.plates, p)
				lv.plateAt[t.y * w + t.x + 1] = p
			else
				local t = placeIn(room, true)
				if not t then
					return nil, "no tile for a key"
				end
				local k = { id = #lv.keys + 1, x = t.x, y = t.y, zone = room.zone }
				table.insert(lv.keys, k)
				lv.keyAt[t.y * w + t.x + 1] = k
			end
		end
	end

	-- каждые ворота должны быть нужны: за ними (в поддереве) что-то нужное
	local need = {}
	for _, p in lv.plates do
		if p.kind == "vault" then
			need[p.zone] = true
		end
	end
	need[lv.vaultZone] = true
	local changed = true
	local neededGate = {}
	while changed do
		changed = false
		for _, door in lv.doors do
			if not neededGate[door.id] then
				local any = false
				for z in need do
					if under(z, door.child) then
						any = true
						break
					end
				end
				if any then
					neededGate[door.id] = true
					changed = true
					if door.kind == "switch" then
						for _, p in lv.plates do
							if p.kind == "switch" and p.color == door.color then
								need[p.zone] = true
							end
						end
					elseif door.kind == "lock" then
						-- ключи взаимозаменяемы: нужен хоть один, но для простоты — все
						for _, k in lv.keys do
							need[k.zone] = true
						end
					end
				end
			end
		end
	end
	for _, door in lv.doors do
		if not neededGate[door.id] then
			return nil, "useless gate " .. door.id
		end
	end
	lv.n = n
	return lv, nil
end

-- Краткое описание для логов и тестов
function Level.describe(lv): string
	local sw, lk = 0, 0
	for _, d in lv.doors do
		if d.kind == "switch" then
			sw += 1
		elseif d.kind == "lock" then
			lk += 1
		end
	end
	return string.format("%dx%d k=%d switches=%d locks=%d zones=%d", lv.w, lv.h, lv.k, sw, lk, #lv.zones)
end

return Level
