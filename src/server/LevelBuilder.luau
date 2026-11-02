--[[
	LevelBuilder — уровень из примитивов на сервере: пол клетками, стены (слитые в полосы),
	двери-барьеры (цвет переключателя, замок, хранилище с лампами), плиты, сокровище, старт.
	Ключи и призраков рисует клиент (их состояние приходит событиями петли).
	Клетка (x, y) уровня → мир: origin + ((x + 0.5)·Tile, 0, (y + 0.5)·Tile); пол на origin.Y.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Level = require(Shared.Level)
local Make = require(Shared.Make)

local LevelBuilder = {}

local T = Config.Grid.Tile
local WH = Config.Grid.WallH

local function rgb(c)
	return Color3.fromRGB(c[1], c[2], c[3])
end

function LevelBuilder.tileCFrame(origin: Vector3, x: number, y: number, h: number?): CFrame
	return CFrame.new(origin + Vector3.new((x + 0.5) * T, h or 0, (y + 0.5) * T))
end

local function part(props)
	local p = {
		Anchored = true,
		CanCollide = true,
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

local function glyphGui(parent: BasePart, face: Enum.NormalId, text: string, color: Color3)
	local gui = Make("SurfaceGui", {
		Name = "Glyph_" .. face.Name,
		Face = face,
		LightInfluence = 0,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = 40,
		Parent = parent,
	})
	Make("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = text,
		TextColor3 = color,
		TextScaled = true,
		Font = Enum.Font.BuilderSansBold,
		Parent = gui,
	})
	return gui
end

function LevelBuilder.lighting()
	if not Lighting:FindFirstChild("Bloom") then
		Make(
			"BloomEffect",
			{ Name = "Bloom", Intensity = 0.6, Size = 24, Threshold = 0.9, Parent = Lighting }
		)
	end
	if not Lighting:FindFirstChild("Atmosphere") then
		Make("Atmosphere", {
			Name = "Atmosphere",
			Density = 0.32,
			Offset = 0.1,
			Color = Color3.fromRGB(70, 80, 140),
			Decay = Color3.fromRGB(40, 30, 80),
			Glare = 0,
			Haze = 1.5,
			Parent = Lighting,
		})
	end
end

--[[
	Построить уровень lv в точке origin. Возвращает папку модели.
	Внутри: Floor, Walls, Doors (Door_<id>), Plates (Plate_<id>), Vault, Treasure, Start, Base.
]]
function LevelBuilder.build(lv, origin: Vector3, parent: Instance, name: string)
	local root = Make("Folder", { Name = name, Attributes = { Level = lv.number or 0 } })
	local floorF = Make("Folder", { Name = "Floor", Parent = root })
	local wallsF = Make("Folder", { Name = "Walls", Parent = root })
	local doorsF = Make("Folder", { Name = "Doors", Parent = root })
	local platesF = Make("Folder", { Name = "Plates", Parent = root })

	-- основание: парящий остров
	local W, H = lv.w * T, lv.h * T
	part({
		Name = "Base",
		Size = Vector3.new(W + 4, 8, H + 4),
		CFrame = CFrame.new(origin + Vector3.new(W / 2, -4.5, H / 2)),
		Color = Color3.fromRGB(24, 26, 46),
		Material = Enum.Material.Slate,
		Parent = root,
	})
	part({
		Name = "Rim",
		Size = Vector3.new(W + 4.4, 0.4, H + 4.4),
		CFrame = CFrame.new(origin + Vector3.new(W / 2, -8.6, H / 2)),
		Color = Color3.fromRGB(110, 90, 255),
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = root,
	})

	-- пол: шахматка из клеток (зона хранилища — золотистая)
	for y = 0, lv.h - 1 do
		for x = 0, lv.w - 1 do
			if Level.isFloor(lv, x, y) and not Level.doorAt(lv, x, y) then
				local vault = Level.zoneAt(lv, x, y) == lv.vaultZone
				local dark = (x + y) % 2 == 0
				local c = if vault
					then (if dark then Color3.fromRGB(92, 74, 40) else Color3.fromRGB(110, 90, 48))
					else (if dark then Color3.fromRGB(46, 50, 78) else Color3.fromRGB(56, 60, 92))
				part({
					Name = "T" .. x .. "_" .. y,
					Size = Vector3.new(T - 0.12, 1, T - 0.12),
					CFrame = LevelBuilder.tileCFrame(origin, x, y, -0.5),
					Color = c,
					Parent = floorF,
				})
			end
		end
	end

	-- стены: горизонтальные полосы подряд идущих клеток
	for y = 0, lv.h - 1 do
		local x = 0
		while x < lv.w do
			if not Level.isFloor(lv, x, y) then
				local x0 = x
				while x + 1 < lv.w and not Level.isFloor(lv, x + 1, y) do
					x += 1
				end
				local len = x - x0 + 1
				local cx = origin.X + (x0 + len / 2) * T
				local cz = origin.Z + (y + 0.5) * T
				part({
					Name = "Wall",
					Size = Vector3.new(len * T, WH, T),
					CFrame = CFrame.new(cx, origin.Y + WH / 2, cz),
					Color = Color3.fromRGB(34, 36, 62),
					Material = Enum.Material.Slate,
					CastShadow = true,
					Parent = wallsF,
				})
				part({
					Name = "Cap",
					Size = Vector3.new(len * T, 0.3, T + 0.05),
					CFrame = CFrame.new(cx, origin.Y + WH + 0.15, cz),
					Color = Color3.fromRGB(120, 110, 255),
					Material = Enum.Material.Neon,
					CanCollide = false,
					Parent = wallsF,
				})
			end
			x += 1
		end
	end

	-- двери
	for _, d in lv.doors do
		local color, glyph
		if d.kind == "switch" then
			local sc = Config.SwitchColors[((d.color - 1) % #Config.SwitchColors) + 1]
			color, glyph = rgb(sc.rgb), sc.glyph
		elseif d.kind == "lock" then
			color, glyph = rgb(Config.LockColor), "⚿"
		else
			color, glyph = rgb(Config.VaultColor), "★"
		end
		local thick = 1.4
		local size = if d.axis == "x" then Vector3.new(thick, WH, T) else Vector3.new(T, WH, thick)
		local cf = LevelBuilder.tileCFrame(origin, d.x, d.y, WH / 2)
		local barrier = part({
			Name = "Door_" .. d.id,
			Size = size,
			CFrame = cf,
			Color = color,
			Material = Enum.Material.Neon,
			Transparency = 0.25,
			CanQuery = false,
			Attributes = { Kind = d.kind, Door = d.id, Open = false, Color = d.color or 0 },
			Parent = doorsF,
		})
		-- рамка
		local postSize = if d.axis == "x"
			then Vector3.new(thick + 0.6, WH, 0.6)
			else Vector3.new(0.6, WH, thick + 0.6)
		for _, side in { -1, 1 } do
			local off = if d.axis == "x"
				then Vector3.new(0, 0, side * (T / 2 - 0.3))
				else Vector3.new(side * (T / 2 - 0.3), 0, 0)
			part({
				Name = "Post",
				Size = postSize,
				CFrame = cf + off,
				Color = Color3.fromRGB(20, 22, 36),
				Material = Enum.Material.Metal,
				Parent = barrier,
			})
		end
		-- знак над дверью на обеих сторонах
		local signSize = if d.axis == "x" then Vector3.new(0.4, 2.4, 2.4) else Vector3.new(2.4, 2.4, 0.4)
		local sign = part({
			Name = "Sign",
			Size = signSize,
			CFrame = cf + Vector3.new(0, WH / 2 + 1.6, 0),
			Color = Color3.fromRGB(16, 18, 30),
			CanCollide = false,
			Parent = barrier,
		})
		if d.axis == "x" then
			glyphGui(sign, Enum.NormalId.Left, glyph, color)
			glyphGui(sign, Enum.NormalId.Right, glyph, color)
		else
			glyphGui(sign, Enum.NormalId.Front, glyph, color)
			glyphGui(sign, Enum.NormalId.Back, glyph, color)
		end
		if d.kind == "vault" then
			local lamps = Make("Folder", { Name = "Lamps", Parent = barrier })
			local n = lv.n
			for i = 1, n do
				local t = (i - (n + 1) / 2) * 1.3
				local off = if d.axis == "x" then Vector3.new(0, 0, t) else Vector3.new(t, 0, 0)
				part({
					Name = "Lamp" .. i,
					Shape = Enum.PartType.Ball,
					Size = Vector3.new(0.9, 0.9, 0.9),
					CFrame = cf + Vector3.new(0, WH / 2 + 3.4, 0) + off,
					Color = Color3.fromRGB(60, 50, 30),
					Material = Enum.Material.Neon,
					CanCollide = false,
					Parent = lamps,
				})
			end
			barrier.Name = "VaultDoor"
			barrier:SetAttribute("Door", d.id)
		end
	end

	-- плиты
	for _, p in lv.plates do
		local color, glyph
		if p.kind == "vault" then
			color, glyph = rgb(Config.VaultColor), "★"
		else
			local sc = Config.SwitchColors[((p.color - 1) % #Config.SwitchColors) + 1]
			color, glyph = rgb(sc.rgb), sc.glyph
		end
		local plate = part({
			Name = "Plate_" .. p.id,
			Size = Vector3.new(T * 0.72, 0.5, T * 0.72),
			CFrame = LevelBuilder.tileCFrame(origin, p.x, p.y, 0.25),
			Color = color,
			Material = Enum.Material.Neon,
			Transparency = 0.15,
			CanCollide = false,
			Attributes = { Kind = p.kind, Plate = p.id, Pressed = false, Color = p.color or 0 },
			Parent = platesF,
		})
		part({
			Name = "Rim",
			Size = Vector3.new(T * 0.86, 0.3, T * 0.86),
			CFrame = LevelBuilder.tileCFrame(origin, p.x, p.y, 0.1),
			Color = Color3.fromRGB(16, 18, 30),
			Material = Enum.Material.Metal,
			CanCollide = false,
			Parent = plate,
		})
		glyphGui(plate, Enum.NormalId.Top, glyph, Color3.fromRGB(20, 20, 30))
	end

	-- сокровище: пьедестал, кучка золота, кристалл (клиент вращает)
	local tr = Make("Model", { Name = "Treasure", Parent = root })
	local tcf = LevelBuilder.tileCFrame(origin, lv.treasure.x, lv.treasure.y, 0)
	part({
		Name = "Pedestal",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.2, T * 0.7, T * 0.7),
		CFrame = tcf * CFrame.new(0, 0.6, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(70, 60, 40),
		Material = Enum.Material.Marble,
		CanCollide = false,
		Parent = tr,
	})
	for i = 1, 7 do
		local a = i * 2.1
		part({
			Name = "Gold",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(1.1, 1.1, 1.1),
			CFrame = tcf * CFrame.new(math.cos(a) * 1.2, 1.5 + (i % 3) * 0.3, math.sin(a) * 1.2),
			Color = rgb(Config.VaultColor),
			Material = Enum.Material.Foil,
			CanCollide = false,
			Parent = tr,
		})
	end
	local gem = part({
		Name = "Gem",
		Size = Vector3.new(1.6, 1.6, 1.6),
		CFrame = tcf * CFrame.new(0, 3.6, 0) * CFrame.Angles(math.rad(45), 0, math.rad(45)),
		Color = Color3.fromRGB(120, 255, 230),
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = tr,
	})
	Make("PointLight", { Color = Color3.fromRGB(255, 220, 120), Range = 16, Brightness = 2, Parent = gem })
	tr.PrimaryPart = gem

	-- старт: часовой круг
	local start = Make("Model", { Name = "Start", Parent = root })
	local scf = LevelBuilder.tileCFrame(origin, lv.start.x, lv.start.y, 0)
	part({
		Name = "Pad",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, T * 0.9, T * 0.9),
		CFrame = scf * CFrame.new(0, 0.12, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(140, 120, 255),
		Material = Enum.Material.Neon,
		Transparency = 0.3,
		CanCollide = false,
		Parent = start,
	})
	for i = 0, 11 do
		local a = i / 12 * math.pi * 2
		part({
			Name = "Tick",
			Size = Vector3.new(0.25, 0.32, if i % 3 == 0 then 0.9 else 0.5),
			CFrame = scf
				* CFrame.new(math.sin(a) * T * 0.36, 0.18, math.cos(a) * T * 0.36)
				* CFrame.Angles(0, a, 0),
			Color = Color3.fromRGB(240, 240, 255),
			Material = Enum.Material.Neon,
			CanCollide = false,
			Parent = start,
		})
	end

	root.Parent = parent
	return root
end

-- Двери и плиты по состоянию модели петли
function LevelBuilder.setDoor(root: Instance, doorId: number, open: boolean)
	local doors = root:FindFirstChild("Doors")
	if not doors then
		return
	end
	for _, d in doors:GetChildren() do
		if d:GetAttribute("Door") == doorId and d:IsA("BasePart") then
			d:SetAttribute("Open", open)
			d.CanCollide = not open
			d.Transparency = if open then 0.88 else 0.25
		end
	end
end

function LevelBuilder.setPlate(root: Instance, plateId: number, pressed: boolean)
	local plates = root:FindFirstChild("Plates")
	local p = plates and plates:FindFirstChild("Plate_" .. plateId) :: BasePart?
	if p then
		if p:GetAttribute("Pressed") ~= pressed then
			p:SetAttribute("Pressed", pressed)
			p.CFrame = p.CFrame + Vector3.new(0, if pressed then -0.18 else 0.18, 0)
			p.Transparency = if pressed then 0 else 0.15
		end
	end
end

function LevelBuilder.setVaultLamps(root: Instance, n: number)
	local doors = root:FindFirstChild("Doors")
	local vd = doors and doors:FindFirstChild("VaultDoor")
	local lamps = vd and vd:FindFirstChild("Lamps")
	if not lamps then
		return
	end
	for _, l in lamps:GetChildren() do
		local i = tonumber(string.match(l.Name, "%d+")) or 0
		if l:IsA("BasePart") then
			l.Color = if i <= n then rgb(Config.VaultColor) else Color3.fromRGB(60, 50, 30)
		end
	end
end

-- Сбросить всё к началу петли
function LevelBuilder.reset(root: Instance, lv)
	for _, d in lv.doors do
		LevelBuilder.setDoor(root, d.id, false)
	end
	for _, p in lv.plates do
		LevelBuilder.setPlate(root, p.id, false)
	end
	LevelBuilder.setVaultLamps(root, 0)
end

return LevelBuilder
