--[[
	Ghosts — всё, что клиент рисует сам по записям и событиям петли:
	  • призраки (фигуры из деталей, цвет петли, номер над головой, кольцо под ногами,
	    облик/след владельца) — позиция = интерполяция записи от времени начала петли
	    (GetServerTimeNow), физики нет: якорные детали без коллизий;
	  • тень будущего: полупрозрачная копия на ShadowAhead секунд вперёд и пунктир пути
	    (с «Оракулом» — до конца петли), 🔑 там, где призрак возьмёт ключ;
	  • предсказание дверей (та же модель Loop на одних призраках): «через 2.1» на двери;
	  • ключи (лежат / в руках у призрака или игрока), парадоксы (вспышка, осколки, ✕),
	    перемотка (все бегут назад по своим следам, эффект перемотки владельца),
	    подсказка (белый силуэт по решению), кольца живых игроков.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Campaign = require(Shared.Campaign)
local Catalog = require(Shared.Catalog)
local Config = require(Shared.Config)
local Loop = require(Shared.Loop)
local Make = require(Shared.Make)

local Ui = require(script.Parent.Ui)
local Lang = require(script.Parent.Lang)

local Ghosts = {}

local T = Config.Grid.Tile
local STEP = Config.Loop.Step
local player = Players.LocalPlayer

local folder: Folder? = nil
local state: any = {
	lv = nil,
	origin = Vector3.zero,
	loop = 0,
	start = 0,
	ghosts = {}, -- { rec, model, shadow, dots, label, broken = { step, x, y }, color }
	lives = {}, -- { userId, name, ring }
	keys = {}, -- id → { model, state, by }
	doors = {}, -- id → { label, intervals }
	pred = nil,
	phase = "idle",
	rewindFrom = 0,
	rewindUntil = 0,
	hint = nil,
	oracle = false,
	trails = {}, -- userId → { {t, pos} } выборка живых для перемотки
}
Ghosts.state = state
Ghosts.onParadox = nil :: ((any) -> ())?

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function rgb(c)
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function world(px: number, py: number, h: number?): Vector3
	return state.origin + Vector3.new(px * T, h or 0, py * T)
end

local function part(props)
	local p = {
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Material = Enum.Material.SmoothPlastic,
		TopSurface = Enum.SurfaceType.Smooth,
		BottomSurface = Enum.SurfaceType.Smooth,
	}
	for k, v in props do
		p[k] = v
	end
	return Make("Part", p)
end

local MATERIAL = {
	plastic = Enum.Material.SmoothPlastic,
	glass = Enum.Material.Glass,
	ice = Enum.Material.Ice,
	neon = Enum.Material.Neon,
	marble = Enum.Material.Marble,
	forcefield = Enum.Material.ForceField,
	foil = Enum.Material.Foil,
}

local function billboard(parent: Instance, text: string, color: Color3, size: number, offset: number)
	local gui = Make("BillboardGui", {
		Name = "Label",
		Size = UDim2.fromOffset(size * 3, size),
		StudsOffsetWorldSpace = Vector3.new(0, offset, 0),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = 260,
		Parent = parent,
	})
	Make("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Ui.fontBold,
		TextScaled = true,
		Text = text,
		TextColor3 = color,
		TextStrokeTransparency = 0.2,
		TextStrokeColor3 = Color3.new(0, 0, 0),
		Parent = gui,
	})
	return gui
end

--[[
	Фигура призрака: голова, тело, руки, ноги. color — цвет петли; skin — облик владельца.
	Возвращает { model, parts = {name → part}, base = {name → CFrame относительно корня} }.
]]
local function figure(name: string, color: Color3, skinId: string?, alpha: number)
	local skin = Catalog.get(skinId or Catalog.Default.skin) or Catalog.get(Catalog.Default.skin) :: any
	local mat = MATERIAL[skin.material or "plastic"] or Enum.Material.SmoothPlastic
	local accent = rgb(skin.colors[1])
	local tr = alpha
	if skin.material == "glass" then
		tr = math.max(alpha, 0.5)
	elseif skin.material == "neon" or skin.material == "foil" then
		tr = math.min(alpha, 0.2)
	end
	local model = Make("Model", { Name = name })
	local parts = {}
	local base = {}
	local function add(pname, size, offset, c, shape)
		local p = part({
			Name = pname,
			Size = size,
			Color = c,
			Material = mat,
			Transparency = tr,
			Shape = shape or Enum.PartType.Block,
			Parent = model,
		})
		parts[pname] = p
		base[pname] = CFrame.new(offset)
		return p
	end
	add("Torso", Vector3.new(2, 2, 1), Vector3.new(0, 3, 0), color)
	add("Head", Vector3.new(1.3, 1.3, 1.3), Vector3.new(0, 4.7, 0), accent, Enum.PartType.Ball)
	add("ArmL", Vector3.new(0.8, 1.9, 0.8), Vector3.new(-1.45, 3, 0), color)
	add("ArmR", Vector3.new(0.8, 1.9, 0.8), Vector3.new(1.45, 3, 0), color)
	add("LegL", Vector3.new(0.9, 2, 0.9), Vector3.new(-0.5, 1, 0), color)
	add("LegR", Vector3.new(0.9, 2, 0.9), Vector3.new(0.5, 1, 0), color)
	local root = part({
		Name = "Root",
		Size = Vector3.new(0.2, 0.2, 0.2),
		Transparency = 1,
		Parent = model,
	})
	model.PrimaryPart = root
	return { model = model, parts = parts, base = base, skin = skin, phase = 0, alpha = tr, color = color }
end

local function poseFigure(fig, cf: CFrame, walk: number)
	local swing = math.sin(fig.phase) * 0.7 * walk
	local parts, base = fig.parts, fig.base
	local list, cfs = {}, {}
	table.insert(list, fig.model.PrimaryPart)
	table.insert(cfs, cf)
	for name, p in parts do
		local b = base[name]
		local c = cf * b
		if name == "LegL" or name == "ArmR" then
			c = cf
				* CFrame.new(b.Position + Vector3.new(0, 1, 0))
				* CFrame.Angles(swing, 0, 0)
				* CFrame.new(0, -1, 0)
		elseif name == "LegR" or name == "ArmL" then
			c = cf
				* CFrame.new(b.Position + Vector3.new(0, 1, 0))
				* CFrame.Angles(-swing, 0, 0)
				* CFrame.new(0, -1, 0)
		end
		table.insert(list, p)
		table.insert(cfs, c)
	end
	Workspace:BulkMoveTo(list, cfs, Enum.BulkMoveMode.FireCFrameChanged)
end

local function setFigureLook(fig, color: Color3?, alpha: number?)
	for name, p in fig.parts do
		if color and name ~= "Head" then
			p.Color = color
		end
		if alpha then
			p.Transparency = alpha
		end
	end
end

local function trailOn(fig, trailId: string?)
	local item = Catalog.get(trailId or Catalog.Default.trail) or Catalog.get(Catalog.Default.trail) :: any
	local torso = fig.parts.Torso
	local a0 = Make("Attachment", { Name = "T0", Position = Vector3.new(0, 0.6, 0), Parent = torso })
	local a1 = Make(
		"Attachment",
		{ Name = "T1", Position = Vector3.new(0, -0.6 - (item.width or 1), 0), Parent = torso }
	)
	Make("Trail", {
		Name = "Trail",
		Attachment0 = a0,
		Attachment1 = a1,
		Lifetime = 0.5,
		LightEmission = 0.6,
		FaceCamera = true,
		Color = ColorSequence.new(rgb(item.colors[1]), rgb(item.colors[2] or item.colors[1])),
		Transparency = NumberSequence.new(0.35, 1),
		Attributes = { Item = item.id },
		Parent = torso,
	})
end

local function ring(color: Color3, name: string)
	return part({
		Name = name,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.15, 3.6, 3.6),
		Color = color,
		Material = Enum.Material.Neon,
		Transparency = 0.25,
		Parent = folder,
	})
end

local function clear()
	if folder then
		folder:ClearAllChildren()
	end
	state.ghosts = {}
	state.lives = {}
	state.keys = {}
	state.doors = {}
	state.hint = nil
end

-------------------------------------------------------------------------------
-- Ключи
-------------------------------------------------------------------------------
local function keyModel(id: number)
	local m = Make("Model", { Name = "Key_" .. id })
	local gold = rgb(Config.KeyColor)
	local ringP = part({
		Name = "Bow",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.35, 1.3, 1.3),
		Color = gold,
		Material = Enum.Material.Neon,
		Parent = m,
	})
	part({
		Name = "Shaft",
		Size = Vector3.new(0.35, 0.35, 1.8),
		Color = gold,
		Material = Enum.Material.Neon,
		Parent = m,
	})
	part({
		Name = "Tooth",
		Size = Vector3.new(0.35, 0.6, 0.35),
		Color = gold,
		Material = Enum.Material.Neon,
		Parent = m,
	})
	Make("PointLight", { Color = gold, Range = 8, Brightness = 1.5, Parent = ringP })
	m.PrimaryPart = ringP
	m.Parent = folder
	return m
end

local function placeKey(k, cf: CFrame)
	local m = k.model
	local bow = m.PrimaryPart
	Workspace:BulkMoveTo({ bow, m.Shaft, m.Tooth }, {
		cf * CFrame.Angles(0, math.rad(90), 0),
		cf * CFrame.new(0, 0, -1.4),
		cf * CFrame.new(0, -0.4, -2.1),
	}, Enum.BulkMoveMode.FireCFrameChanged)
end

-------------------------------------------------------------------------------
-- Уровень и петля
-------------------------------------------------------------------------------
function Ghosts.setLevel(n: number, origin: { number }, runId: number?)
	clear()
	state.run = runId
	state.gem = nil
	state.lv = Campaign.level(n)
	state.n = n
	state.origin = Vector3.new(origin[1], origin[2], origin[3])
	state.phase = "idle"
	state.pred = nil
end

local function unpackRec(r)
	local ev = {}
	for _, e in r.ev or {} do
		ev[e[1]] = { e[2], e[3] }
	end
	return {
		xs = r.xs or {},
		ys = r.ys or {},
		n = r.n or 0,
		ev = ev,
		x0 = r.x0,
		y0 = r.y0,
		owner = r.owner,
		name = r.name,
		loop = r.loop or 1,
		skin = r.skin,
		trail = r.trail,
		rewind = r.rewind,
	}
end
Ghosts.unpackRec = unpackRec

function Ghosts.startLoop(p)
	if not state.lv or not folder then
		return
	end
	clear()
	local lv = state.lv
	state.loop = p.loop
	state.start = p.start
	state.length = p.length or Config.Loop.Length
	state.phase = "play"
	state.spectator = p.spectator == true
	state.trails = {}
	local recs = {}
	local coop = false
	for _, g in p.ghosts do
		if g.owner and g.owner ~= player.UserId then
			coop = true
		end
	end
	for i, g in p.ghosts do
		local rec = unpackRec(g)
		table.insert(recs, rec)
		local color = Ui.loopColor(rec.loop)
		local fig = figure("Ghost_" .. i, color, rec.skin, 0.35)
		trailOn(fig, rec.trail)
		local labelText = tostring(rec.loop) .. (if coop and rec.name then " · " .. rec.name else "")
		billboard(fig.parts.Head, labelText, color, 26, 1.6)
		fig.model.Parent = folder
		local shadow = figure("Shadow_" .. i, color, nil, 0.8)
		setFigureLook(shadow, color, 0.82)
		shadow.model.Parent = folder
		local dots = {}
		local nDots = if state.oracle then 36 else 12
		for d = 1, nDots do
			dots[d] = part({
				Name = "Dot",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(0.5, 0.5, 0.5),
				Color = color,
				Material = Enum.Material.Neon,
				Transparency = 0.35,
				Parent = folder,
			})
		end
		local keyIcon =
			part({ Name = "KeyIcon", Size = Vector3.new(0.2, 0.2, 0.2), Transparency = 1, Parent = folder })
		billboard(keyIcon, "🔑", Color3.new(1, 1, 1), 22, 0)
		local fx, fy = Loop.recAt(rec, rec.n)
		table.insert(state.ghosts, {
			rec = rec,
			fig = fig,
			shadow = shadow,
			dots = dots,
			keyIcon = keyIcon,
			color = color,
			ring = ring(color, "Ring_" .. i),
			endX = fx,
			endY = fy,
			last = nil,
		})
	end
	for _, l in p.lives or {} do
		table.insert(state.lives, {
			userId = l.userId,
			name = l.name,
			rewind = l.rewind,
			ring = ring(Ui.loopColor(p.loop), "LiveRing_" .. l.userId),
		})
	end
	-- ключи
	for _, k in lv.keys do
		state.keys[k.id] = { model = keyModel(k.id), state = "lying", x = k.x, y = k.y, by = nil }
	end
	-- предсказание дверей по призракам
	state.pred = Loop.predict(lv, recs)
	for _, d in lv.doors do
		local anchor = part({
			Name = "DoorLabel_" .. d.id,
			Size = Vector3.new(0.2, 0.2, 0.2),
			Transparency = 1,
			CFrame = CFrame.new(world(d.x + 0.5, d.y + 0.5, Config.Grid.WallH + 4.2)),
			Parent = folder,
		})
		local gui = billboard(anchor, "", Color3.new(1, 1, 1), 22, 0)
		state.doors[d.id] = { gui = gui, intervals = state.pred.doors[d.id] or {} }
	end
	if state.hintPending then
		Ghosts.setHint(state.hintPending)
		state.hintPending = nil
	end
end

-- Тело модели по номеру: сначала призраки, потом живые
local function entity(i: number)
	local g = state.ghosts[i]
	if g then
		return g, nil
	end
	return nil, state.lives[i - #state.ghosts]
end

function Ghosts.event(e)
	if e.t == "pick" then
		local k = state.keys[e.key]
		if k then
			k.state = "carried"
			k.by = e.body
		end
	elseif e.t == "drop" then
		local k = state.keys[e.key]
		if k then
			k.state = "lying"
			k.by = nil
			k.x, k.y = e.x, e.y
		end
	elseif e.t == "unlock" then
		local k = e.key and state.keys[e.key]
		if k then
			k.state = "used"
			k.model.Parent = nil
		end
	elseif e.t == "paradox" then
		local g = state.ghosts[e.body]
		if g then
			g.broken = { step = e.step, x = e.x, y = e.y }
			setFigureLook(g.fig, Color3.fromRGB(150, 150, 160), 0.6)
			g.fig.parts.Head.Label.Text.Text = "✕ " .. tostring(g.rec.loop)
			g.fig.parts.Head.Label.Text.TextColor3 = Ui.colors.paradox
			g.shadow.model.Parent = nil
			for _, d in g.dots do
				d.Transparency = 1
			end
			-- осколки
			local pos = world(e.x, e.y, 3)
			for i = 1, 10 do
				local shard = part({
					Name = "Shard",
					Size = Vector3.new(0.6, 0.6, 0.6),
					Color = if i % 2 == 0 then g.color else Ui.colors.paradox,
					Material = Enum.Material.Neon,
					CFrame = CFrame.new(
						pos + Vector3.new(math.cos(i) * 1.5, (i % 3) * 0.8, math.sin(i) * 1.5)
					) * CFrame.Angles(i, i * 2, i * 3),
					Parent = folder,
				})
				shard:SetAttribute("Born", now())
				shard:SetAttribute("Vx", math.cos(i) * 8)
				shard:SetAttribute("Vy", 6 + (i % 4) * 2)
				shard:SetAttribute("Vz", math.sin(i) * 8)
			end
			local flash = part({
				Name = "Flash",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(2, 2, 2),
				Color = Ui.colors.paradox,
				Material = Enum.Material.Neon,
				Transparency = 0.2,
				CFrame = CFrame.new(pos),
				Parent = folder,
			})
			flash:SetAttribute("Born", now())
			local mark = part({
				Name = "ParadoxMark",
				Size = Vector3.new(0.2, 0.2, 0.2),
				Transparency = 1,
				CFrame = CFrame.new(world(e.x, e.y, 1)),
				Parent = folder,
			})
			billboard(mark, "✕", Ui.colors.paradox, 34, 0)
			if Ghosts.onParadox then
				Ghosts.onParadox(e)
			end
		end
	elseif e.t == "win" then
		state.winAt = now()
	end
end

-- Подсказка: белый силуэт по записи решения
function Ghosts.setHint(h)
	if state.phase ~= "play" or not folder then
		state.hintPending = h
		return
	end
	if state.hint then
		state.hint.fig.model:Destroy()
	end
	local fig = figure("Hint", Color3.fromRGB(255, 255, 255), "skin_glass", 0.55)
	setFigureLook(fig, Color3.fromRGB(255, 255, 255), 0.55)
	billboard(fig.parts.Head, "💡", Color3.fromRGB(255, 255, 200), 26, 1.6)
	fig.model.Parent = folder
	state.hint = { rec = unpackRec(h.rec), fig = fig }
end

function Ghosts.setOracle(on: boolean)
	state.oracle = on
end

-- Перемотка: все бегут назад по своим следам
function Ghosts.rewind(dur: number)
	if state.phase ~= "play" then
		return
	end
	state.phase = "rewind"
	local s = math.clamp((now() - state.start) / STEP, 0, state.lv and state.lv.steps or 150)
	state.rewindFrom = s
	state.rewindAt = now()
	state.rewindDur = dur
	for _, g in state.ghosts do
		g.shadow.model.Parent = nil
		for _, d in g.dots do
			d.Transparency = 1
		end
	end
	-- эффект перемотки каждого тела (облик владельца)
	local function burst(pos: Vector3, rewindId: string?, color: Color3)
		local item = Catalog.get(rewindId or Catalog.Default.rewind)
			or Catalog.get(Catalog.Default.rewind) :: any
		local n = if item.shape == "burst" then 3 elseif item.shape == "spiral" then 2 else 1
		for i = 1, n do
			local c = if item.colors[i] then rgb(item.colors[i]) else color
			local r = part({
				Name = "RewindFx",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.2, 2, 2),
				Color = c,
				Material = Enum.Material.Neon,
				Transparency = 0.2,
				CFrame = CFrame.new(pos + Vector3.new(0, 0.3 + i * 0.4, 0))
					* CFrame.Angles(0, 0, math.rad(90)),
				Attributes = { Born = now(), Grow = 6 + i * 3, Item = item.id },
				Parent = folder,
			})
			_ = r
		end
	end
	for _, g in state.ghosts do
		local x, y = Loop.recLerp(g.rec, s)
		burst(world(x, y, 0), g.rec.rewind, g.color)
	end
	for _, l in state.lives do
		local p = Players:GetPlayerByUserId(l.userId)
		local r = p and p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r then
			burst(r.CFrame.Position - Vector3.new(0, 3, 0), l.rewind, Ui.loopColor(state.loop))
		end
	end
end

function Ghosts.loopTime(): number
	if state.phase ~= "play" then
		return 0
	end
	return math.clamp(now() - state.start, 0, state.length or Config.Loop.Length)
end

-- Метки для шкалы петли: { t (с), color, glyph }
function Ghosts.timeline()
	local out = {}
	for _, g in state.ghosts do
		for s, ev in g.rec.ev do
			table.insert(
				out,
				{ t = s * STEP, color = g.color, glyph = if ev[1] == "pick" then "🔑" else "⚿" }
			)
		end
		if g.rec.n < (state.lv and state.lv.steps or 150) then
			table.insert(out, { t = g.rec.n * STEP, color = g.color, glyph = "■" })
		end
	end
	if state.pred then
		for id, list in state.pred.doors do
			local d = state.lv.doors[id]
			for _, iv in list do
				if iv[1] > 0 then
					local glyph = if d.kind == "vault" then "★" else "▮"
					local color = if d.kind == "vault" then rgb(Config.VaultColor) else Color3.new(1, 1, 1)
					if d.kind == "switch" then
						local sc = Config.SwitchColors[((d.color - 1) % #Config.SwitchColors) + 1]
						color, glyph = rgb(sc.rgb), sc.glyph
					end
					table.insert(out, { t = iv[1] * STEP, color = color, glyph = glyph })
				end
			end
		end
	end
	return out
end

-------------------------------------------------------------------------------
-- Кадр
-------------------------------------------------------------------------------
local function ghostPose(g, s: number)
	if g.broken and s >= g.broken.step then
		return g.broken.x, g.broken.y, 0
	end
	local x, y = Loop.recLerp(g.rec, s)
	local x2, y2 = Loop.recLerp(g.rec, s + 1)
	local speed = math.sqrt((x2 - x) ^ 2 + (y2 - y) ^ 2) / STEP
	return x, y, speed
end

local function facing(g, x, y, x2, y2)
	local dx, dz = x2 - x, y2 - y
	if dx * dx + dz * dz > 1e-6 then
		g.yaw = math.atan2(-dx, -dz)
	end
	return g.yaw or 0
end

function Ghosts.update(dt: number)
	if not folder or not state.lv then
		return
	end
	local t = now()
	local s
	if state.phase == "rewind" then
		local f = math.clamp((t - (state.rewindAt or t)) / (state.rewindDur or 1), 0, 1)
		s = state.rewindFrom * (1 - f)
	elseif state.phase == "play" then
		s = math.clamp((t - state.start) / STEP, 0, state.lv.steps)
	else
		s = 0
	end
	-- живые: выборка позиций для перемотки, кольца
	for _, l in state.lives do
		local p = Players:GetPlayerByUserId(l.userId)
		local r = p and p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r then
			l.ring.CFrame = CFrame.new(r.CFrame.Position - Vector3.new(0, 2.9, 0))
				* CFrame.Angles(0, 0, math.rad(90))
		end
	end
	for i, g in state.ghosts do
		local x, y, speed = ghostPose(g, s)
		local x2, y2 = Loop.recLerp(g.rec, s + 1)
		local yaw = facing(g, x, y, x2, y2)
		if state.phase == "rewind" then
			yaw += math.pi
			speed = 6
		end
		local walk = math.clamp(speed / 2.6, 0, 1)
		g.fig.phase += dt * 10 * walk
		local cf = CFrame.new(world(x, y, 0)) * CFrame.Angles(0, yaw, 0)
		poseFigure(g.fig, cf, walk)
		g.ring.CFrame = CFrame.new(world(x, y, 0.1)) * CFrame.Angles(0, 0, math.rad(90))
		-- тень будущего и пунктир
		if state.phase == "play" and not g.broken then
			local ahead = Config.Loop.ShadowAhead / STEP
			local sx, sy = Loop.recLerp(g.rec, s + ahead)
			local same = math.abs(sx - x) + math.abs(sy - y) < 0.05
			local scf = CFrame.new(world(sx, sy, 0)) * CFrame.Angles(0, yaw, 0)
			poseFigure(g.shadow, scf, 0)
			setFigureLook(g.shadow, nil, if same then 1 else 0.82)
			local span = if state.oracle then state.lv.steps - s else Config.Loop.PathAhead / STEP
			local n = #g.dots
			for d = 1, n do
				local ds = s + span * d / n
				local dx, dy = Loop.recLerp(g.rec, ds)
				local still = math.abs(dx - x) + math.abs(dy - y) < 0.05
				g.dots[d].CFrame = CFrame.new(world(dx, dy, 0.4))
				g.dots[d].Transparency = if still or ds > state.lv.steps then 1 else 0.35 + 0.5 * d / n
			end
			-- 🔑 там, где возьмёт ключ в ближайшие PathAhead секунд
			local icon = false
			for es, ev in g.rec.ev do
				if ev[1] == "pick" and es >= s and es <= s + Config.Loop.PathAhead / STEP then
					local kx, ky = Loop.recAt(g.rec, es)
					g.keyIcon.CFrame = CFrame.new(world(kx, ky, 4.5))
					icon = true
				end
			end
			g.keyIcon.Label.Enabled = icon
		else
			g.keyIcon.Label.Enabled = false
		end
		_ = i
	end
	-- ключи
	for id, k in state.keys do
		if k.state == "lying" then
			local base = world(k.x + 0.5, k.y + 0.5, 2 + math.sin(t * 2 + id) * 0.3)
			placeKey(k, CFrame.new(base) * CFrame.Angles(0, t * 1.5, 0))
		elseif k.state == "carried" then
			local g, l = entity(k.by)
			local pos
			if g then
				pos = g.fig.parts.Head.CFrame.Position + Vector3.new(0, 1.6, 0)
			elseif l then
				local p = Players:GetPlayerByUserId(l.userId)
				local head = p and p.Character and p.Character:FindFirstChild("Head") :: BasePart?
				pos = head and head.CFrame.Position + Vector3.new(0, 1.8, 0)
			end
			if pos then
				placeKey(k, CFrame.new(pos) * CFrame.Angles(0, t * 3, 0))
			end
		end
	end
	-- двери: «через N с» по предсказанию
	for id, d in state.doors do
		local text = ""
		if state.phase == "play" then
			for _, iv in d.intervals do
				if s >= iv[1] and s < iv[2] then
					text = ""
					break
				elseif iv[1] > s then
					local left = (iv[1] - s) * STEP
					if left >= 0.1 then
						text = Lang.t("ui.doorIn", { t = string.format("%.1f", left) })
					end
					break
				end
			end
		end
		d.gui.Text.Text = text
		d.gui.Enabled = text ~= ""
		_ = id
	end
	-- кристалл сокровища вращается (локально, сервер его не двигает)
	if not state.gem and state.run then
		local levels = Workspace:FindFirstChild("Levels")
		local m = levels and levels:FindFirstChild("Run_" .. state.run)
		local tr = m and m:FindFirstChild("Treasure")
		local gem = tr and tr:FindFirstChild("Gem") :: BasePart?
		if gem then
			state.gem = { part = gem, cf = gem.CFrame }
		end
	end
	if state.gem and state.gem.part.Parent then
		local up = math.sin(t * 2) * 0.3
		state.gem.part.CFrame = CFrame.new(state.gem.cf.Position + Vector3.new(0, up, 0))
			* CFrame.Angles(0, t * 1.2, 0)
			* CFrame.Angles(math.rad(45), 0, math.rad(45))
	end
	-- подсказка
	if state.hint and state.phase == "play" then
		local x, y = Loop.recLerp(state.hint.rec, s)
		local x2, y2 = Loop.recLerp(state.hint.rec, s + 1)
		local yaw = facing(state.hint, x, y, x2, y2)
		local speed = math.sqrt((x2 - x) ^ 2 + (y2 - y) ^ 2) / STEP
		local walk = math.clamp(speed / 2.6, 0, 1)
		state.hint.fig.phase += dt * 10 * walk
		poseFigure(state.hint.fig, CFrame.new(world(x, y, 0)) * CFrame.Angles(0, yaw, 0), walk)
	end
	-- эффекты: осколки, вспышки, кольца перемотки
	for _, c in folder:GetChildren() do
		local born = c:GetAttribute("Born")
		if born and c:IsA("BasePart") then
			local age = t - born
			if c.Name == "Shard" then
				local vy = (c:GetAttribute("Vy") or 0) - 40 * age
				c.CFrame = c.CFrame
					+ Vector3.new(c:GetAttribute("Vx") or 0, vy, c:GetAttribute("Vz") or 0)
						* math.min(dt, 0.05)
				c.Transparency = math.clamp(age / 1.2, 0, 1)
				if age > 1.2 then
					c:Destroy()
				end
			elseif c.Name == "Flash" then
				c.Size = Vector3.one * (2 + age * 14)
				c.Transparency = math.clamp(0.2 + age * 1.6, 0, 1)
				if age > 0.5 then
					c:Destroy()
				end
			elseif c.Name == "RewindFx" then
				local g = c:GetAttribute("Grow") or 6
				local sz = 2 + age * g * 2
				c.Size = Vector3.new(0.2, sz, sz)
				c.Transparency = math.clamp(0.2 + age / 1.2, 0, 1)
				if age > 1.2 then
					c:Destroy()
				end
			end
		end
	end
end

function Ghosts.build()
	folder = Make("Folder", { Name = "LoopFx", Parent = Workspace })
end

function Ghosts.folder(): Folder?
	return folder
end

return Ghosts
