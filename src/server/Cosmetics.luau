--[[
	Cosmetics — облик призраков, след и эффект перемотки (видят все игроки уровня).
	По умолчанию — сразу, не дожидаясь профиля (DataStore может грузиться 10 с);
	когда профиль загрузился или что-то купили/надели — refresh обновляет атрибуты игрока
	(Skin, Trail, Rewind) и след на персонаже; новые призраки берут облик из них.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared.Catalog)
local Profile = require(Shared.Profile)

local Data = require(script.Parent.DataService)
local Monetization = require(script.Parent.Monetization)

local Cosmetics = {}

local listeners: { (Player) -> () } = {}

function Cosmetics.effective(player: Player, kind: string): string
	local d = Data.get(player)
	if not d then
		return Catalog.Default[kind]
	end
	return Profile.effective(d, kind, Monetization.hasPass(player, "Vip"))
end

function Cosmetics.styleOf(player: Player): { skin: string, trail: string, rewind: string }
	return {
		skin = Cosmetics.effective(player, "skin"),
		trail = Cosmetics.effective(player, "trail"),
		rewind = Cosmetics.effective(player, "rewind"),
	}
end

local function rgb(c)
	return Color3.fromRGB(c[1], c[2], c[3])
end

-- След на персонаже (Trail между двумя Attachment у корня) и табличка VIP
function Cosmetics.dress(player: Player)
	local ch = player.Character
	local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local item = Catalog.get(Cosmetics.effective(player, "trail")) :: Catalog.Item
	local a0 = root:FindFirstChild("TrailTop") :: Attachment? or Instance.new("Attachment")
	a0.Name = "TrailTop"
	a0.Position = Vector3.new(0, 0.6, 0)
	a0.Parent = root
	local a1 = root:FindFirstChild("TrailBottom") :: Attachment? or Instance.new("Attachment")
	a1.Name = "TrailBottom"
	a1.Position = Vector3.new(0, -0.6 - (item.width or 1), 0)
	a1.Parent = root
	local trail = root:FindFirstChild("LoopTrail") :: Trail? or Instance.new("Trail")
	trail.Name = "LoopTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.6
	trail.LightEmission = 0.6
	trail.FaceCamera = true
	trail.Color = ColorSequence.new(rgb(item.colors[1]), rgb(item.colors[2] or item.colors[1]))
	trail.Transparency = NumberSequence.new(0.3, 1)
	trail:SetAttribute("Item", item.id)
	trail.Parent = root
	local head = ch:FindFirstChild("Head") :: BasePart?
	local vip = Monetization.hasPass(player, "Vip")
	local tag = head and head:FindFirstChild("VipTag")
	if head and vip and not tag then
		local gui = Instance.new("BillboardGui")
		gui.Name = "VipTag"
		gui.Size = UDim2.fromOffset(60, 22)
		gui.StudsOffset = Vector3.new(0, 2.4, 0)
		gui.AlwaysOnTop = false
		local l = Instance.new("TextLabel")
		l.Name = "Label"
		l.BackgroundTransparency = 1
		l.Size = UDim2.fromScale(1, 1)
		l.Text = "★ VIP"
		l.TextColor3 = Color3.fromRGB(255, 205, 70)
		l.TextStrokeTransparency = 0.4
		l.Font = Enum.Font.BuilderSansBold
		l.TextScaled = true
		l.Parent = gui
		gui.Parent = head
	elseif tag and not vip then
		tag:Destroy()
	end
end

function Cosmetics.onChange(fn: (Player) -> ())
	table.insert(listeners, fn)
end

function Cosmetics.refresh(player: Player)
	local style = Cosmetics.styleOf(player)
	player:SetAttribute("Skin", style.skin)
	player:SetAttribute("Trail", style.trail)
	player:SetAttribute("Rewind", style.rewind)
	Cosmetics.dress(player)
	for _, fn in listeners do
		task.spawn(fn, player)
	end
end

function Cosmetics.start()
	Data.onLoaded(function(player)
		Cosmetics.refresh(player)
	end)
	Monetization.onPass(function(player, key)
		if key == "Vip" then
			Cosmetics.refresh(player)
		end
	end)
	local function added(player: Player)
		player:SetAttribute("Skin", Catalog.Default.skin)
		player:SetAttribute("Trail", Catalog.Default.trail)
		player:SetAttribute("Rewind", Catalog.Default.rewind)
		player.CharacterAdded:Connect(function()
			task.defer(Cosmetics.dress, player)
		end)
	end
	Players.PlayerAdded:Connect(added)
	for _, p in Players:GetPlayers() do
		added(p)
	end
end

return Cosmetics
