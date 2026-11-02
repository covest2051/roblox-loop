--[[
	Клиент: призраки и тени будущего, предсказание дверей, HUD петли, звуки,
	реакции на события сервера. Свой персонаж ходит сам (стандартное управление),
	сервер читает его позицию каждые 0,1 с.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local Ui = require(script.Ui)
local Lang = require(script.Lang)
local Ghosts = require(script.Ghosts)
local Hud = require(script.Hud)
local Shop = require(script.Shop)
local Controls = require(script.Controls)
local Fx = require(script.Fx)
local DebugPanel = require(script.DebugPanel)

local player = Players.LocalPlayer
local C = Ui.colors

while not Workspace:GetAttribute("WorldReady") do
	task.wait(0.2)
end

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

Ui.watchViewport()
Ghosts.build()
Hud.build()
Shop.build()
Fx.build()
Controls.build()
DebugPanel.build()

local function send(payload)
	Net.ClientAction:FireServer(payload)
end

local function invite()
	local ok, can = pcall(function()
		return SocialService:CanSendGameInviteAsync(player)
	end)
	if ok and can then
		pcall(function()
			SocialService:PromptGameInvite(player)
		end)
	end
end

local function rewind()
	if Hud.info.phase == "play" and not Hud.info.done then
		send({ t = "rewind" })
		Fx.play("Rewind")
	end
end
local function undo()
	send({ t = "undo" })
end
local function hint()
	send({ t = "hint" })
end

Controls.onRewind = rewind
Controls.onUndo = undo
Controls.onHint = hint
Hud.onRewind = rewind
Hud.onUndo = undo
Hud.onHint = hint
Hud.onRestart = function()
	send({ t = "restart" })
end
Hud.onPlay = function(n)
	send({ t = "play", n = n })
end
Hud.onShop = function(tab)
	if tab then
		Shop.open(tab)
	else
		Shop.toggle()
	end
end
Hud.onCoop = function()
	send({ t = "runs" })
end
Hud.onJoin = function(id)
	send({ t = "join", id = id })
end
Hud.onSolo = function()
	send({ t = "solo" })
end
Hud.onInvite = invite
Hud.onAdvance = function(again)
	send({ t = "advance", again = again })
end
Hud.onExtra = function()
	send({ t = "product", key = "ExtraLoop" })
end
Hud.onTick = function()
	Fx.play("Tick")
end
Ghosts.onParadox = function(e)
	Hud.paradox(e)
	Fx.play("Paradox")
	Fx.shake(0.8)
end

local handlers = {}

handlers.profile = function(p)
	Hud.setProfile(p)
	Shop.setProfile(p)
	if p.saved == false then
		Hud.toast(Lang.t("ui.dataOff"), C.warn)
	end
end

handlers.toast = function(p)
	Hud.toast(Lang.t(p.key, p.vars))
end

handlers.level = function(p)
	Ghosts.setLevel(p.n, p.origin, p.run)
	Hud.setLevel(p)
end

handlers.loop = function(p)
	Ghosts.startLoop(p)
	Hud.startLoop(p)
	Fx.play("Start")
	if p.loop == 1 and not p.spectator then
		task.defer(Controls.overview)
	end
end

handlers.ev = function(p)
	for _, e in p.list do
		Ghosts.event(e)
		if e.t == "pick" then
			Fx.play("Key")
			local g = Ghosts.state.ghosts[e.body]
			if not g then
				local l = Ghosts.state.lives[e.body - #Ghosts.state.ghosts]
				if l and l.userId == player.UserId then
					Hud.toast(Lang.t("loop.keyGot"), C.gold)
				end
			end
		elseif e.t == "unlock" then
			Fx.play("Unlock")
			Hud.toast(Lang.t("loop.unlock"), C.gold)
		elseif e.t == "door" then
			Fx.play("Door", if e.open then 1 else 0.5)
		elseif e.t == "plate" and e.on then
			Fx.play("Plate")
		elseif e.t == "win" then
			Fx.play("Win")
		end
	end
end

handlers.done = function()
	Hud.done()
end

handlers.rewind = function(p)
	Ghosts.rewind(p.dur)
	Hud.rewind()
	Fx.play("Rewind")
end

handlers.won = function(p)
	Hud.showWin(p)
	Fx.play("Win")
	Fx.shake(0.4)
end

handlers.out = function(p)
	Hud.showOut(p)
end

handlers.undone = function(p)
	Hud.undone(p)
end

handlers.hint = function(p)
	if p.stale then
		Hud.toast(Lang.t("loop.hintStale"), C.warn)
		return
	end
	Ghosts.setHint(p)
	Hud.toast(Lang.t("loop.hintShown"), C.gold)
end

handlers.runs = function(p)
	Hud.showRuns(p.list, p.mine)
end

handlers.members = function(_p) end

handlers.chestResult = function(p)
	Shop.showReward(p.id, Lang.t("shop.chestGot"), if p.dup then p.refund else nil)
end

handlers.directResult = function(p)
	Shop.showReward(p.id, Lang.t("shop.directGot"), nil)
end

handlers.selftest = function(p)
	for _, line in p.lines do
		print(line)
	end
	Hud.toast(p.lines[#p.lines] or "selftest")
end

Net.ServerEvent.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then
		return
	end
	local h = handlers[payload.t]
	if h then
		local ok, err = pcall(h, payload)
		if not ok then
			warn("[Client]", payload.t, err)
		end
	end
end)

send({ t = "sync" })

RunService.RenderStepped:Connect(function(dt)
	Ghosts.update(dt)
	Hud.update(dt)
	Fx.update(dt)
end)
