--[[
	Сервер + клиент в одном DataModel на заглушке движка. Кадры идут вручную (детерминированно).
	Проверяется то, что видит игрок:
	  HUD петли («LOOP 1 / 2», точки, шкала времени, остаток), обучение на первом уровне;
	  R → ⟲ (кнопка гаснет), перемотка (кольца эффекта), призрак в петле 2 стоит РОВНО там,
	  где запись (интерполяция по времени сервера), номер и кольцо цвета петли, тень будущего
	  впереди, пунктир; дверь пишет «in X.X» по предсказанию; метки на шкале; победа (★★★);
	  парадокс (осколки, ✕, сообщение); «петли кончились» (+1 петля); отмена (Z); подсказка
	  (белый силуэт); уровни (главы, замки); «Вместе»; магазин с точными шансами и
	  PolicyService; раскладка на 667×375 и при масштабе 1.25 (всё на экране, без наложений).
	Запуск (после rojo build): lune run tests/engine/client_sim.luau build/game.rbxl
]]

local process = require("@lune/process")
local roblox = require("@lune/roblox")
local task = require("@lune/task")
local Sim = require("./Sim")

local CFrame, Vector3, Vector2 = roblox.CFrame, roblox.Vector3, roblox.Vector2

local failures = {}
local function check(cond, msg)
	print((if cond then "  ✓ " else "  ✗ ") .. msg)
	if not cond then
		table.insert(failures, msg)
	end
end
local function waitUntil(fn, timeout)
	local t0 = os.clock()
	while not fn() do
		if os.clock() - t0 > timeout then
			return false
		end
		task.wait(0.05)
	end
	return true
end

roblox.implementMethod("SocialService", "CanSendGameInviteAsync", function()
	return true
end)

local game = Sim.loadPlace(process.args[1] or "build/game.rbxl")
local ws = game:GetService("Workspace")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local function shared(name)
	return Sim.require(RS.Shared[name])
end
local Config = shared("Config")
local Catalog = shared("Catalog")
local Loop = shared("Loop")
local Campaign = shared("Campaign")
local Bots = require("../lib/Bots").make(shared)

local T = Config.Grid.Tile
local STEP = Config.Loop.Step
Sim.virtualTime = 5000
local player = Sim.addPlayer("Tester")
Players.LocalPlayer = player
Sim.localPlayer = player
Sim.clientMode = true
roblox.Instance.new("PlayerGui").Parent = player
local cam = roblox.Instance.new("Camera")
cam.Parent = ws
ws.CurrentCamera = cam
cam.ViewportSize = Vector2.new(1280, 720)

local server = game:GetService("ServerScriptService").Server
Sim.runScript(server)
check(
	waitUntil(function()
		return ws:GetAttribute("WorldReady") == true and player.Character ~= nil
	end, 20),
	"server ready, character spawned"
)
local LS = Sim.require(server.LoopService)
local run = LS.runOf(player)

local client = game:GetService("StarterPlayer").StarterPlayerScripts.Client
local ok, err = pcall(function()
	Sim.runScript(client)
end)
check(ok, "client script starts" .. (if ok then "" else ": " .. tostring(err)))

local frameErrors = {}
local function frame(dt)
	Sim.virtualTime += dt
	local okF, errF = pcall(function()
		Sim.signalOf(RunService, "Heartbeat"):Fire(dt)
		task.wait()
		Sim.signalOf(RunService, "RenderStepped"):Fire(dt)
	end)
	if not okF then
		table.insert(frameErrors, tostring(errF))
	end
	task.wait()
end
local DT = 1 / 30
local function frames(seconds)
	for _ = 1, math.floor(seconds / DT + 0.5) do
		frame(DT)
	end
end
local function key(name)
	local fn = Sim.actions and Sim.actions[name]
	if fn then
		fn(name, roblox.Enum.UserInputState.Begin, {})
	end
	task.wait()
end
local function act(payload)
	Sim.signalOf(RS.Remotes.ClientAction, "OnServerEvent"):Fire(player, payload)
	task.wait(0.03)
end
local function click(btn)
	Sim.signalOf(btn, "Activated"):Fire()
	task.wait(0.03)
end
local function moveTo(x, y)
	local r = player.Character.HumanoidRootPart
	r.CFrame = CFrame.new(run.origin + Vector3.new(x * T, 3, y * T))
end
local function untilPhase(phase, maxSec)
	local t = 0
	while run.phase ~= phase and t < (maxSec or 5) do
		frame(DT)
		t += DT
	end
	return run.phase == phase
end
local Hud, Ghosts
-- живой бот: персонаж идёт по записи «я» i решения, на конце записи — R
local function playSelf(plan, i, each)
	local rec = plan.recs[i]
	local guard = 0
	while run.phase == "play" and guard < 2000 do
		guard += 1
		local x, y = Loop.recAt(rec, run.st.step + 1)
		moveTo(x, y)
		frame(DT)
		if each then
			each()
		end
		if run.st and run.st.step >= rec.n and i < run.lv.k and run.phase == "play" and not Hud.info.done then
			key("LoopRewind")
		end
	end
end

local gui = player.PlayerGui
check(
	waitUntil(function()
		frame(DT)
		return gui:FindFirstChild("LoopUI") ~= nil and gui.LoopUI:FindFirstChild("Hud") ~= nil
	end, 10),
	"HUD built"
)
local ui = gui.LoopUI
local hudF = ui.Hud
Hud = Sim.require(client.Hud)
Ghosts = Sim.require(client.Ghosts)
check(
	hudF.Top
		and hudF.Info
		and hudF.Actions
		and ui:FindFirstChild("Shop")
		and ui:FindFirstChild("Levels")
		and ui:FindFirstChild("Win")
		and ui:FindFirstChild("Out"),
	"panels built"
)
check(
	Sim.actions and Sim.actions.LoopRewind and Sim.actions.LoopUndo and Sim.actions.LoopHint,
	"R / Z / H bound"
)
check(Sim.humanoidStates and Sim.humanoidStates.Jumping == false, "no jumping")

print("== sync and loop HUD")
check(
	waitUntil(function()
		frame(DT)
		return Ghosts.state.lv ~= nil and Hud.info.phase == "play"
	end, 6),
	"client synced the level and the loop (events before the client started are not lost)"
)
local bar = hudF.Top.Bar
check(bar.Loop.Text == "LOOP 1 / 2", "loop counter: " .. bar.Loop.Text)
check(#bar.Dots:GetChildren() == 2, "a dot per loop")
local f0 = bar.Timeline.Fill.Size.X.Scale
local t0 = tonumber(bar.TimeLeft.Text) or 0
frames(1)
check(
	bar.Timeline.Fill.Size.X.Scale > f0 and (tonumber(bar.TimeLeft.Text) or 99) < t0,
	"timeline runs, time left drops"
)
check(ui.Tip.Visible and string.find(ui.Tip.Text.Text, "REWIND", 1, true) ~= nil, "level 1 tip shown")
check(hudF.Info.Panel.Need.Text == "You need: 2 of you", "how many of you: " .. hudF.Info.Panel.Need.Text)

print("== loop 1: walk to the gold plate, R")
-- свежий уровень с начала петли (клиент синхронизировался посреди петли)
act({ t = "debug", cmd = "level", arg = 1 })
check(untilPhase("play") and run.st.step <= 1, "fresh loop 1")
local lv1, plan1 = Bots.plan(1)
local fx = ws.LoopFx
playSelf(plan1, 1)
check(Hud.info.done or run.phase ~= "play", "R → my loop recorded")
check(run.phase == "rewind" or run.phase == "play", "rewind")
local rings = 0
for _, c in fx:GetChildren() do
	if c.Name == "RewindFx" then
		rings += 1
	end
end
check(rings >= 1 or run.phase == "play", "rewind effect at my position (" .. rings .. ")")
check(untilPhase("play"), "loop 2")
check(bar.Loop.Text == "LOOP 2 / 2", "counter → 2 / 2")
local g = fx:FindFirstChild("Ghost_1")
check(g ~= nil and fx:FindFirstChild("Shadow_1") ~= nil, "ghost and its future shadow")

print("== the ghost is exactly where its recording says")
local rec = Ghosts.state.ghosts[1].rec
local worst, worstShadow = 0, 0
local labelOk, dotsOk = false, false
local doorText = nil
for _ = 1, 30 do
	frame(DT)
	local s = (ws:GetServerTimeNow() - Ghosts.state.start) / STEP
	local x, y = Loop.recLerp(rec, s)
	local want = run.origin + Vector3.new(x * T, 0, y * T)
	local got = g.PrimaryPart.CFrame.Position
	worst = math.max(worst, (Vector3.new(got.X, 0, got.Z) - Vector3.new(want.X, 0, want.Z)).Magnitude)
	local sx, sy = Loop.recLerp(rec, s + Config.Loop.ShadowAhead / STEP)
	local sg = fx.Shadow_1.PrimaryPart.CFrame.Position
	local wo = run.origin + Vector3.new(sx * T, 0, sy * T)
	worstShadow = math.max(worstShadow, (Vector3.new(sg.X, 0, sg.Z) - Vector3.new(wo.X, 0, wo.Z)).Magnitude)
	labelOk = labelOk or g.Head.Label.Text.Text == "1"
	for _, c in fx:GetChildren() do
		if c.Name == "Dot" and c.Transparency < 1 then
			dotsOk = true
		end
		if string.sub(c.Name, 1, 10) == "DoorLabel_" and c.Label.Enabled then
			doorText = doorText or c.Label.Text.Text
		end
	end
end
check(worst < 0.3, string.format("ghost on its recording (max error %.3f studs)", worst))
check(
	worstShadow < 0.3,
	string.format("future shadow %.1fs ahead (error %.3f)", Config.Loop.ShadowAhead, worstShadow)
)
check(
	labelOk and g.Head.Label.Text.TextColor3 == roblox.Color3.fromRGB(table.unpack(Config.LoopColors[1])),
	"number 1 in loop color 1"
)
check(dotsOk, "dotted path ahead")
check(
	doorText ~= nil and string.match(doorText, "^in %d+%.%d$") ~= nil,
	"vault door says when it opens: " .. tostring(doorText)
)
check(
	#bar.Timeline.Marks:GetChildren() >= 1,
	"ghost events on the timeline (" .. #bar.Timeline.Marks:GetChildren() .. ")"
)
check(
	fx:FindFirstChild("Ring_1") ~= nil and fx:FindFirstChild("LiveRing_" .. player.UserId) ~= nil,
	"rings under the ghost and me"
)

print("== win")
playSelf(plan1, 2)
check(
	waitUntil(function()
		frame(DT)
		return ui.Win.Visible
	end, 3),
	"vault cracked → win panel"
)
check(ui.Win.Stars.Text == "★★★", "★★★ " .. ui.Win.Stars.Text)
check(string.find(ui.Win.Body.Text, "Coins: +", 1, true) ~= nil, "coins shown")
frames(0.5)
check(string.find(ui.Win.Next.Text, "(", 1, true) ~= nil, "next level countdown: " .. ui.Win.Next.Text)
click(ui.Win.Next)
check(untilPhase("play"), "next level starts")
check(
	run.n == 2 and Ghosts.state.n == 2 and hudF.Info.Panel.Level.Text:find("Level 2", 1, true) ~= nil,
	"level 2 on screen"
)

print("== paradox on screen")
local keyN
for n = 1, Campaign.Count do
	local plan = LS.planFor(n)
	for _, ev in plan.recs[1].ev do
		if ev[1] == "pick" and Campaign.level(n).k <= 3 then
			keyN = keyN or n
		end
	end
end
act({ t = "debug", cmd = "level", arg = keyN })
check(untilPhase("play"), "key level " .. tostring(keyN))
local lvK, planK = Bots.plan(keyN)
playSelf(planK, 1)
check(untilPhase("play"), "loop 2")
local Planner = shared("Planner")
local kx, ky = Bots.thief(lvK)
local guard = 0
while run.phase == "play" and not run.st.bodies[1].broken and guard < 300 do
	guard += 1
	local r = player.Character.HumanoidRootPart.CFrame.Position - run.origin
	local x, y = r.X / T, r.Z / T
	local path = Planner.route(lvK, math.floor(x), math.floor(y), math.floor(kx), math.floor(ky))
	local nx, ny = kx, ky
	if path and #path > 0 then
		nx, ny = path[1].x + 0.5, path[1].y + 0.5
	end
	local dx, dy = nx - x, ny - y
	local d = math.max(1e-6, math.sqrt(dx * dx + dy * dy))
	local st = Config.Loop.WalkSpeed / T * DT
	moveTo(x + dx / d * math.min(st, d), y + dy / d * math.min(st, d))
	frame(DT)
end
frames(0.3)
check(run.st.bodies[1].broken, "server: ghost shattered")
local shards, mark = 0, false
for _, c in fx:GetChildren() do
	if c.Name == "Shard" then
		shards += 1
	elseif c.Name == "ParadoxMark" then
		mark = true
	end
end
check(shards > 0 and mark, "shards and ✕ where it happened")
check(string.find(fx.Ghost_1.Head.Label.Text.Text, "✕", 1, true) ~= nil, "ghost label crossed out")
check(string.find(ui.Center.Text, "PARADOX", 1, true) ~= nil, "big message: " .. ui.Center.Text)

print("== undo (Z)")
key("LoopUndo")
frames(0.2)
check(#run.ghosts == 0, "↶ erased loop 1")
check(untilPhase("play") and bar.Loop.Text == "LOOP 1 / " .. lvK.k, "back to loop 1")

print("== out of loops → +1 loop")
act({ t = "debug", cmd = "out" })
frames(0.2)
check(ui.Out.Visible and ui.Out.Extra.Visible, "out-of-loops window with +1 loop")
check(
	string.find(ui.Out.Timer.Text, "erased in", 1, true) ~= nil,
	"auto-undo countdown: " .. ui.Out.Timer.Text
)
click(ui.Out.Extra)
frames(0.3)
check(run.extra == 1, "extra loop bought (Studio emulation)")
check(untilPhase("play") and not ui.Out.Visible, "play goes on")

print("== hint")
local Data = Sim.require(server.DataService)
Data.get(player).coins = 500
click(hudF.Actions.Hint)
frames(0.2)
act({ t = "restart" })
check(untilPhase("play"), "restart")
frames(0.2)
check(fx:FindFirstChild("Hint") ~= nil, "white hint figure walks the solution")

print("== levels and together")
act({ t = "debug", cmd = "unlockall" })
frames(0.2)
click(hudF.Info.LevelsButton)
frames(0.1)
local levels = ui.Levels
local cells, chapters = 0, 0
for _, d in levels.Body:GetDescendants() do
	if d.ClassName == "TextButton" and string.match(d.Name, "^L%d+$") then
		cells += 1
	elseif string.sub(d.Name, 1, 8) == "Chapter_" then
		chapters += 1
	end
end
check(levels.Visible and cells == 30 and chapters == 5, "30 levels in 5 chapters")
local b5
for _, d in levels.Body:GetDescendants() do
	if d.Name == "L5" then
		b5 = d
	end
end
click(b5)
frames(0.3)
check(run.n == 5 and not levels.Visible, "picked level 5")
click(hudF.Info.CoopButton)
frames(0.2)
check(ui.Coop.Visible and ui.Coop.Body:FindFirstChild("None") ~= nil, "Together: nobody else yet")
click(ui.Coop.Close)

print("== shop")
click(hudF.Info.ShopButton)
frames(0.2)
local shop = ui.Shop
check(shop.Visible, "shop opens")
local cards = 0
for _, d in shop.Body:GetDescendants() do
	if d.ClassName == "Frame" and Catalog.get(d.Name) then
		cards += 1
	end
end
check(cards == #Catalog.Items, "all items shown (" .. cards .. ")")
Data.get(player).coins = 999
act({ t = "profile" })
frames(0.1)
local buy
for _, d in shop.Body:GetDescendants() do
	if d.Name == "skin_glass" then
		buy = d:FindFirstChildWhichIsA("TextButton")
	end
end
click(buy)
check(
	waitUntil(function()
		frame(DT)
		return Data.get(player).owned.skin_glass == true and player:GetAttribute("Skin") == "skin_glass"
	end, 2),
	"bought and wearing a new ghost look"
)
click(shop.Tab_chest)
frames(0.2)
local odds = 0
for _, d in shop.Body:GetChildren() do
	if string.sub(d.Name, 1, 5) == "Odds_" then
		odds += 1
	end
end
check(odds == #Catalog.odds(), "every capsule item has its exact chance (" .. odds .. ")")
check(shop.Body:FindFirstChild("OpenChest") ~= nil, "capsule button where allowed")
click(shop.Body.OpenChest)
check(
	waitUntil(function()
		frame(DT)
		return ui.Reward.Visible == true
	end, 3),
	"capsule result popup"
)
click(shop.Tab_passes)
frames(0.2)
check(
	shop.Body:FindFirstChild("Oracle")
		and shop.Body:FindFirstChild("ExtraLoop")
		and shop.Body:FindFirstChild("Vip"),
	"passes and products"
)
Sim.policyRestricted = true
local Mon = Sim.require(server.Monetization)
Sim.signalOf(Players, "PlayerRemoving"):Fire(player)
task.wait(0.1)
Sim.signalOf(Players, "PlayerAdded"):Fire(player)
task.wait(0.3)
Data.load(player)
task.wait(0.2)
_ = Mon
click(shop.Tab_chest)
frames(0.3)
check(shop.Body:FindFirstChild("OpenChest") == nil, "restricted region: no capsule button")
Sim.policyRestricted = false
click(shop.Close)
check(not shop.Visible, "shop closes")
run = LS.runOf(player) or run

print("== layout: phone 667×375 and 1.25 scale")
-- Абсолютный прямоугольник с учётом UIScale предков (масштаб — вокруг AnchorPoint объекта со шкалой)
local function rect(obj, vp)
	local function walk(o)
		local parent = o.Parent
		local ppos, psize, cum = Vector2.new(0, 0), vp, 1
		if parent and parent.ClassName ~= "ScreenGui" and parent.Name ~= "Hud" then
			local a, b, c = walk(parent)
			ppos, psize, cum = a, b / c, c
		end
		-- размеры в несжатых единицах родителя
		local w = o.Size.X.Scale * psize.X + o.Size.X.Offset
		local h = o.Size.Y.Scale * psize.Y + o.Size.Y.Offset
		local x = o.Position.X.Scale * psize.X + o.Position.X.Offset
		local y = o.Position.Y.Scale * psize.Y + o.Position.Y.Offset
		local sc = o:FindFirstChildOfClass("UIScale")
		local own = if sc then sc.Scale else 1
		local total = cum * own
		-- точка привязки остаётся на месте, размер растёт в own раз
		local ax, ay = x * cum, y * cum
		local W, H = w * total, h * total
		local pos = ppos + Vector2.new(ax - o.AnchorPoint.X * W, ay - o.AnchorPoint.Y * H)
		return pos, Vector2.new(W, H), total
	end
	local p, s = walk(obj)
	return p, s
end
local function barRect(vp)
	local p, sz = rect(hudF.Top, vp)
	local s = hudF.Top.UIScale.Scale
	return p, Vector2.new(sz.X, 74 * s)
end
local function overlap(a, as, b, bs)
	return a.X < b.X + bs.X and b.X < a.X + as.X and a.Y < b.Y + bs.Y and b.Y < a.Y + as.Y
end
local Ui = Sim.require(client.Ui)
for _, vp in { Vector2.new(667, 375), Vector2.new(1600, 900), Vector2.new(1280, 720) } do
	cam.ViewportSize = vp
	Sim.signalOf(cam, "Prop:ViewportSize"):Fire()
	frames(0.1)
	ui.Tip.Visible = true
	local boxes = {
		{ "top", barRect(vp) },
		{ "info", rect(hudF.Info, vp) },
		{ "actions", rect(hudF.Actions, vp) },
		{ "tip", rect(ui.Tip, vp) },
	}
	local inside, clash = true, nil
	for i, b in boxes do
		local p, s = b[2], b[3]
		if p.X < 0 or p.Y < 0 or p.X + s.X > vp.X + 0.5 or p.Y + s.Y > vp.Y + 0.5 then
			inside = false
			clash = clash or (b[1] .. " off screen")
		end
		for j = i + 1, #boxes do
			local c = boxes[j]
			if overlap(p, s, c[2], c[3]) then
				clash = clash or (b[1] .. " × " .. c[1])
			end
		end
	end
	local s = hudF.Top.UIScale.Scale
	check(
		inside and clash == nil,
		string.format("%dx%d: HUD on screen, no overlaps %s", vp.X, vp.Y, clash or "")
	)
	check(s >= 0.75 and s <= 1.25, string.format("%dx%d: HUD scale %.2f within 0.75…1.25", vp.X, vp.Y, s))
	for _, m in { ui.Shop, ui.Levels, ui.Win, ui.Out, ui.Coop } do
		local p, sz = rect(m, vp)
		check(
			p.X >= 0 and p.Y >= 0 and p.X + sz.X <= vp.X and p.Y + sz.Y <= vp.Y,
			string.format("%dx%d: %s fits the screen", vp.X, vp.Y, m.Name)
		)
	end
	-- большая кнопка ⟲ на телефоне — не меньше пальца
	local _, rs = rect(hudF.Actions.Rewind, vp)
	check(
		rs.Y >= 60 and rs.X >= 150,
		string.format("%dx%d: ⟲ is thumb-sized (%.0f×%.0f)", vp.X, vp.Y, rs.X, rs.Y)
	)
end
_ = Ui
ui.Tip.Visible = false

print("== language, invite, debug")
local Lang = Sim.require(client.Lang)
Lang.set("ru")
frames(0.1)
check(hudF.Actions.Rewind.Text == "⟲ ПЕРЕМОТКА", "RU: " .. hudF.Actions.Rewind.Text)
Lang.set("en")
frames(0.1)
check(hudF.Actions.Rewind.Text == "⟲ REWIND", "EN")
click(hudF.Info.InviteButton)
check((Sim.invites or 0) >= 1, "invite prompt")
check(ui:FindFirstChild("DebugToggle") ~= nil, "debug button in Studio")

for _, e in frameErrors do
	print("    " .. e)
end
check(#frameErrors == 0, "no errors in the frame loop")
local clientWarns = 0
for _, w in Sim.warnings or {} do
	if string.find(w, "[Client]", 1, true) or string.find(w, "error", 1, true) then
		clientWarns += 1
		print("    " .. w)
	end
end
check(clientWarns == 0, "no client handler errors")
print(string.format("\n%d failures", #failures))
process.exit(if #failures > 0 then 1 else 0)
