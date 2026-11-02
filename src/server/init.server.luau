--[[
	Точка входа сервера: сервисы, затем игроки. Каждый игрок сразу попадает в свой уровень
	(следующий непройденный); позвать друга — «Вместе». Логика идёт фиксированным шагом
	по GetServerTimeNow: шаг петли не зависит от частоты кадров сервера.
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Campaign = require(Shared.Campaign)
local Config = require(Shared.Config)
local Profile = require(Shared.Profile)

local DataService = require(script.DataService)
local Monetization = require(script.Monetization)
local Cosmetics = require(script.Cosmetics)
local LevelBuilder = require(script.LevelBuilder)
local LoopService = require(script.LoopService)
local Actions = require(script.Actions)
local SelfTest = require(script.SelfTest)

-- данные и покупки — сразу: ProcessReceipt должен быть назначен как можно раньше
DataService.start()
Monetization.start()
Cosmetics.start()
LoopService.start()
Actions.selfTest = SelfTest.run
Actions.start()

local t0 = os.clock()
LevelBuilder.lighting()
-- игроки проходят друг сквозь друга (узкие проходы в кооперативе)
pcall(function()
	if not PhysicsService:IsCollisionGroupRegistered("Players") then
		PhysicsService:RegisterCollisionGroup("Players")
	end
	PhysicsService:CollisionGroupSetCollidable("Players", "Players", false)
end)
-- решения кампании (для подсказок) — заранее, по одному уровню за кадр
task.spawn(function()
	for n = 1, Campaign.Count do
		LoopService.planFor(n)
		task.wait()
	end
end)
Workspace:SetAttribute("WorldReady", true)
print(string.format("[World] ready in %.2fs, %d levels", os.clock() - t0, Campaign.Count))

-- шаг логики
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc >= Config.Timing.Step * 0.5 then
		acc = 0
		LoopService.step()
	end
end)

local function setupCharacter(player: Player, character: Model)
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = "Players"
		end
	end
	character.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.CollisionGroup = "Players"
		end
	end)
	local hum = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if hum then
		hum.WalkSpeed = Config.Loop.WalkSpeed
		hum.UseJumpPower = false
		hum.JumpHeight = 0
		hum.Died:Connect(function()
			task.wait(2)
			if player.Parent then
				player:LoadCharacter()
			end
		end)
	end
	LoopService.onCharacter(player)
end

-- персонаж появляется, когда игрок уже в уровне (CharacterAutoLoads = false)
local function spawnLoop(player: Player)
	player.CharacterAdded:Connect(function(character)
		setupCharacter(player, character)
	end)
	-- профиль ждём недолго: DataStore бывает медленным, уровень 1 подойдёт новичку
	local d = DataService.get(player, 3)
	if not player.Parent then
		return
	end
	local n = if d then Profile.nextLevel(d, Campaign.Count) else 1
	LoopService.solo(player, n)
	player:LoadCharacter()
end
Players.PlayerAdded:Connect(spawnLoop)
for _, p in Players:GetPlayers() do
	task.spawn(spawnLoop, p)
end

if RunService:IsStudio() then
	task.delay(6, SelfTest.run)
end
