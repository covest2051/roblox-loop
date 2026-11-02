--[[
	Прогон сервера на заглушке движка: уровень строится из примитивов, игрок появляется на
	старте, боты ВЕДУТ ПЕРСОНАЖЕЙ игроков по решению (та же голова Planner): петля за петлёй,
	⟲, призраки на сервере повторяют записи (двери открываются сами), победа, звёзды и монеты;
	детерминизм при дрожании кадров; парадокс (украли ключ у прошлого себя); отмена;
	«петли кончились» + «Лишняя петля» (окно ждёт оплату один раз); кооператив (общие
	призраки, вход со следующей петли); подсказка; покупки, PolicyService, чеки, сбой DataStore.
	Запуск (после rojo build): lune run tests/engine/server_sim.luau build/game.rbxl
]]

local process = require("@lune/process")
local roblox = require("@lune/roblox")
local task = require("@lune/task")
local Sim = require("./Sim")

local CFrame, Vector3 = roblox.CFrame, roblox.Vector3

local failures = {}
local function check(cond, msg)
	print((if cond then "  ✓ " else "  ✗ ") .. msg)
	if not cond then
		table.insert(failures, msg)
	end
end

local game = Sim.loadPlace(process.args[1] or "build/game.rbxl")
local RS = game:GetService("ReplicatedStorage")
local ws = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local function shared(name)
	return Sim.require(RS.Shared[name])
end
local Config = shared("Config")
local Catalog = shared("Catalog")
local Campaign = shared("Campaign")
local Loop = shared("Loop")
local Bots = require("../lib/Bots").make(shared)

local T = Config.Grid.Tile
local STEP = Config.Loop.Step
Sim.virtualTime = 1000

local function tick(dt)
	Sim.virtualTime += dt
	Sim.signalOf(RunService, "Heartbeat"):Fire(dt)
	task.wait()
end
local function ticks(seconds, dt)
	local d = dt or 0.05
	for _ = 1, math.floor(seconds / d + 0.5) do
		tick(d)
	end
end
local function waitUntil(fn, timeout)
	local t0 = os.clock()
	while not fn() do
		if os.clock() - t0 > timeout then
			return false
		end
		task.wait(0.02)
	end
	return true
end
local function sentTo(player, kind)
	local out = {}
	for _, s in Sim.sent do
		if (s.player == player or s.player == "all") and s.payload and s.payload.t == kind then
			table.insert(out, s.payload)
		end
	end
	return out
end
local function last(player, kind)
	local l = sentTo(player, kind)
	return l[#l]
end
local function action(player, payload)
	Sim.signalOf(RS.Remotes.ClientAction, "OnServerEvent"):Fire(player, payload)
	task.wait(0.03)
end

print("== boot")
local server = game:GetService("ServerScriptService").Server
local alice = Sim.addPlayer("Alice")
Sim.runScript(server)
check(
	waitUntil(function()
		return ws:GetAttribute("WorldReady") == true
	end, 20),
	"server ready"
)
local LS = Sim.require(server.LoopService)
local Data = Sim.require(server.DataService)
check(
	waitUntil(function()
		return alice.Character ~= nil and LS.runOf(alice) ~= nil
	end, 8),
	"Alice gets a level and a character"
)
local run = LS.runOf(alice)
check(run.n == 1, "a new player starts at level 1")
local model = ws.Levels:FindFirstChild("Run_" .. run.id)
check(
	model ~= nil and model:FindFirstChild("Floor") and model:FindFirstChild("Walls"),
	"level built from primitives"
)
check(
	#model.Doors:GetChildren() == #run.lv.doors and #model.Plates:GetChildren() == #run.lv.plates,
	"doors and plates"
)
check(
	model:FindFirstChild("Treasure") ~= nil and model:FindFirstChild("Start") ~= nil,
	"treasure and start pad"
)
local floorTiles = 0
for y = 0, run.lv.h - 1 do
	for x = 0, run.lv.w - 1 do
		local Level = shared("Level")
		if Level.isFloor(run.lv, x, y) and not Level.doorAt(run.lv, x, y) then
			floorTiles += 1
		end
	end
end
check(#model.Floor:GetChildren() == floorTiles, "a floor tile per cell (" .. floorTiles .. ")")
local root = alice.Character.HumanoidRootPart
check(
	root.CollisionGroup == "Players" and Sim.collidable["Players|Players"] == false,
	"players pass through each other"
)
check(#sentTo(alice, "level") >= 1 and last(alice, "level").n == 1, "client told about the level")

local function posOf(p)
	local r = p.Character.HumanoidRootPart
	local c = r.CFrame.Position - run.origin
	return c.X / T, c.Z / T
end
local function moveTo(p, x, y)
	local r = p.Character.HumanoidRootPart
	r.CFrame = CFrame.new(run.origin + Vector3.new(x * T, 3, y * T))
end

-- дойти до фазы play
local function untilPhase(r, phase, maxSec)
	local t = 0
	while r.phase ~= phase and t < (maxSec or 5) do
		tick(0.05)
		t += 0.05
	end
	return r.phase == phase
end
check(untilPhase(run, "play"), "rewind → play")
local sx, sy = posOf(alice)
local s0 = run.lv.starts[1]
check(math.floor(sx) == s0.x and math.floor(sy) == s0.y, "standing on the start tile")
check(not root.Anchored, "free to move")
local lp = last(alice, "loop")
check(lp ~= nil and lp.loop == 1 and lp.total == run.lv.k and #lp.ghosts == 0, "loop 1 / k announced")

--[[
	Сыграть петлю ботом: персонаж идёт по записи «я» номер i из решения, на конце записи
	нажимает ⟲. jitter — шаги кадров случайной длины (детерминизм не должен зависеть).
]]
local function playLoop(p, r, plan, i, jitter, onStep)
	local rec = plan.recs[i]
	local guard = 0
	while r.phase == "play" and guard < 2000 do
		guard += 1
		local s = r.st.step
		local x, y = Loop.recAt(rec, s + 1)
		moveTo(p, x, y)
		if onStep then
			onStep(s)
		end
		local dt = if jitter then 0.016 + math.random() * 0.15 else STEP
		tick(dt)
		if r.st.step >= rec.n and i < r.lv.k and r.phase == "play" then
			local b = Loop.bodyOf(r.st, p.UserId)
			if b and not b.done then
				action(p, { t = "rewind" })
			end
		end
	end
end

print("== level 1 by the bot head: loop by loop")
local lv1, plan1 = Bots.plan(1)
check(lv1.k == 2, "level 1 needs 2 of you")
playLoop(alice, run, plan1, 1, false)
check(#sentTo(alice, "done") >= 1, "⟲ ends my loop early (done)")
check(run.phase == "rewind" and #run.ghosts == 1, "loop over → rewind, 1 ghost")
local g1 = run.ghosts[1]
check(
	g1.owner == alice.UserId and g1.loop == 1 and g1.skin == Catalog.Default.skin,
	"ghost knows owner, loop, look"
)
local liveLog = {}
for _, e in run.st.log do
	if e.t == "plate" or e.t == "door" then
		table.insert(liveLog, e.t .. e.step .. tostring(e.on or e.open))
	end
end
check(untilPhase(run, "play"), "loop 2 starts")
lp = last(alice, "loop")
check(lp.loop == 2 and #lp.ghosts == 1 and #lp.ghosts[1].xs == g1.n, "loop 2 sends the ghost recording")
check(type(lp.ghosts[1].ev) == "table", "events packed as a list")
local vaultDoor = model.Doors:FindFirstChild("VaultDoor")
local openedAt = nil
local wins0 = Data.get(alice).clears
local coins0 = Data.get(alice).coins
playLoop(alice, run, plan1, 2, true, function(s)
	if not openedAt and vaultDoor:GetAttribute("Open") then
		openedAt = s
	end
end)
check(openedAt ~= nil, "the ghost opens the vault on the server (step " .. tostring(openedAt) .. ")")
check(vaultDoor.CanCollide == false or run.phase ~= "play", "open door has no collision")
-- детерминизм: призрак (с дрожанием кадров) сделал то же, что живой в петле 1
local ghostLog = {}
for _, e in run.st.log do
	if (e.t == "plate" or e.t == "door") and e.step <= g1.n + 3 then
		table.insert(ghostLog, e.t .. e.step .. tostring(e.on or e.open))
	end
end
local same = #liveLog > 0
for i, s in liveLog do
	same = same and ghostLog[i] == s
end
check(same, "ghost replay = live loop, step for step, with jittery frames (" .. #liveLog .. " events)")
local won = last(alice, "won")
check(run.phase == "won" and won ~= nil, "treasure → vault cracked")
check(won and won.stars == 3 and won.first, "★★★ for exactly k loops")
check(Data.get(alice).clears == wins0 + 1 and string.sub(Data.get(alice).stars, 1, 1) == "3", "stars saved")
check(
	Data.get(alice).coins - coins0 == won.coins and won.coins > 0,
	"coins credited: +" .. tostring(won and won.coins)
)
check(alice.leaderstats.Stars.Value == 3, "leaderstats Stars")

print("== next level")
ticks(Config.Loop.WinPause + 0.2)
check(run.n == 2 and run.phase == "rewind", "next level after the pause")
check(ws.Levels:FindFirstChild("Run_" .. run.id) ~= model and model.Parent == nil, "old level removed")
model = ws.Levels:FindFirstChild("Run_" .. run.id)
check(last(alice, "level").n == 2, "client told")

print("== paradox: steal the key from your past self")
local keyN = nil
for n = 1, Campaign.Count do
	local lv = Campaign.level(n)
	if #lv.keys > 0 and lv.k <= 3 then
		local plan = LS.planFor(n)
		for _, ev in plan.recs[1].ev do
			if ev[1] == "pick" then
				keyN = keyN or n
			end
		end
	end
end
check(keyN ~= nil, "a level where loop 1 picks a key: " .. tostring(keyN))
action(alice, { t = "debug", cmd = "level", arg = keyN })
check(run.n == keyN, "debug: level " .. keyN)
untilPhase(run, "play")
local lvK, planK = Bots.plan(keyN)
playLoop(alice, run, planK, 1, false)
untilPhase(run, "play")
-- петля 2: бежим прямо к ключу, быстрее прошлого себя
local kx, ky = Bots.thief(lvK)
local par = nil
local guard = 0
while run.phase == "play" and guard < 400 and not par do
	guard += 1
	local x, y = posOf(alice)
	local dx, dy = kx - x, ky - y
	local d = math.sqrt(dx * dx + dy * dy)
	local stepLen = Config.Loop.WalkSpeed / T * STEP
	if d > 0.01 then
		local s = math.min(d, stepLen)
		-- по маршруту, чтобы не сквозь стены
		local Planner = shared("Planner")
		local path = Planner.route(lvK, math.floor(x), math.floor(y), math.floor(kx), math.floor(ky))
		local nx, ny = kx, ky
		if path and #path > 0 then
			nx, ny = path[1].x + 0.5, path[1].y + 0.5
		end
		local ddx, ddy = nx - x, ny - y
		local dd = math.max(1e-6, math.sqrt(ddx * ddx + ddy * ddy))
		moveTo(alice, x + ddx / dd * math.min(s, dd), y + ddy / dd * math.min(s, dd))
	end
	tick(STEP)
	for _, ev in sentTo(alice, "ev") do
		for _, e in ev.list do
			if e.t == "paradox" then
				par = e
			end
		end
	end
end
check(par ~= nil and par.reason == "key", "PARADOX event: the key is gone")
check(run.st.bodies[1].broken, "ghost shattered on the server")
action(alice, { t = "undo" })
check(run.phase == "rewind" and #run.ghosts == 0, "↶ undo erases loop 1")
check(last(alice, "undone").loop == 1, "client told")
untilPhase(run, "play")
check(last(alice, "loop").loop == 1, "back to loop 1")

print("== out of loops → extra loop (the window waits for the payment once)")
action(alice, { t = "debug", cmd = "out" })
check(run.phase == "out", "out of loops")
local out = last(alice, "out")
check(
	out ~= nil and out.deadline > Sim.virtualTime and out.canExtra,
	"out window with a deadline and +1 loop"
)
local Products = Config.Products
local savedId = Products.ExtraLoop.id
Products.ExtraLoop.id = 424242
local Monetization = Sim.require(server.Monetization)
-- карта id → ключ строится при старте; добавим тестовый id
local deadline0 = run.phaseEnd
action(alice, { t = "product", key = "ExtraLoop" })
check(Sim.prompts[#Sim.prompts] and Sim.prompts[#Sim.prompts].id == 424242, "purchase prompt opened")
check(
	run.phaseEnd >= Sim.virtualTime + Config.Loop.PayHold - 0.5 and run.phaseEnd > deadline0,
	"window held while paying"
)
local held = run.phaseEnd
action(alice, { t = "product", key = "ExtraLoop" })
check(run.phaseEnd == held, "held only once")
Products.ExtraLoop.id = savedId
check(Monetization.grant(alice, "ExtraLoop", "PID-EXTRA"), "receipt granted")
check(run.extra == 1 and run.phase == "rewind", "+1 loop → the next loop starts")
untilPhase(run, "play")
check(last(alice, "loop").total >= run.lv.k + 1 - #run.ghosts + (last(alice, "loop").loop - 1), "budget grew")

print("== out of loops → auto undo")
action(alice, { t = "debug", cmd = "out" })
ticks(Config.Loop.OutWait + 0.3, 0.1)
check(last(alice, "undone") and last(alice, "undone").auto == true, "the last loop is erased by itself")
check(run.phase == "rewind" or run.phase == "play", "and play goes on")

print("== hint")
action(alice, { t = "debug", cmd = "restart" })
untilPhase(run, "play")
local d = Data.get(alice)
d.coins = 0
action(alice, { t = "hint" })
check(last(alice, "toast").key == "loop.hintNoCoins", "a hint costs coins")
d.coins = 100
action(alice, { t = "hint" })
local h = last(alice, "hint")
check(h ~= nil and h.rec and h.self == 1 and #h.rec.xs > 0, "hint: the path of 'you #1'")
check(d.coins == 100 - Config.Rewards.HintCost, "paid once")
action(alice, { t = "hint" })
check(d.coins == 100 - Config.Rewards.HintCost, "again on this level — free")

print("== co-op: shared ghosts, joining with the next loop")
local bob = Sim.addPlayer("Bob")
Sim.signalOf(Players, "PlayerAdded"):Fire(bob)
check(
	waitUntil(function()
		tick(0.05)
		return LS.runOf(bob) ~= nil and bob.Character ~= nil
	end, 8),
	"Bob gets his own level"
)
local bobRun = LS.runOf(bob)
check(bobRun ~= run and bobRun.slot ~= run.slot, "in another slot")
action(bob, { t = "runs" })
local rl = last(bob, "runs")
check(rl and #rl.list >= 2, "Bob sees the open levels")
untilPhase(run, "play")
action(bob, { t = "join", id = run.id })
check(
	LS.runOf(bob) == run and table.find(run.pending, bob) ~= nil,
	"Bob joins Alice: waits for the next loop"
)
check(ws.Levels:FindFirstChild("Run_" .. bobRun.id) == nil, "Bob's empty level is freed")
check(last(bob, "loop") and last(bob, "loop").spectator, "Bob watches the current loop")
check(bob.Character.HumanoidRootPart.Anchored, "frozen until then")
action(alice, { t = "rewind" })
check(
	waitUntil(function()
		tick(0.05)
		return run.phase == "play" and #run.lives == 2
	end, 5),
	"next loop: both alive"
)
local lp2 = last(bob, "loop")
check(lp2 and #lp2.ghosts == #run.ghosts and #lp2.lives == 2, "same ghosts for both")
check(
	lp2.total == lp2.loop + math.ceil((run.lv.k + run.extra - #run.ghosts) / 2) - 1,
	"loop budget shared by two"
)
action(alice, { t = "rewind" })
action(bob, { t = "rewind" })
check(
	waitUntil(function()
		tick(0.05)
		return run.phase ~= "play"
	end, 3),
	"loop ends when both are done"
)
local byOwner = {}
for _, g in run.ghosts do
	byOwner[g.owner] = (byOwner[g.owner] or 0) + 1
end
check(byOwner[bob.UserId] == 1 and (byOwner[alice.UserId] or 0) >= 1, "each player left a ghost")
action(bob, { t = "solo" })
check(LS.runOf(bob) ~= run and #run.members == 1, "Bob goes solo")

print("== shop and cosmetics")
d = Data.get(alice)
d.coins = 0
action(alice, { t = "buyCoins", id = "skin_glass" })
check(last(alice, "toast").key == "shop.noCoins" and not d.owned.skin_glass, "can't buy without coins")
d.coins = 1000
action(alice, { t = "buyCoins", id = "skin_glass" })
check(d.owned.skin_glass and d.coins == 1000 - Config.Rarity.Common.price, "bought for coins")
check(alice:GetAttribute("Skin") == "skin_glass", "new ghost look for everyone")
d.coins = 2000
action(alice, { t = "buyCoins", id = "trail_fire" })
check(
	alice.Character.HumanoidRootPart.LoopTrail:GetAttribute("Item") == "trail_fire",
	"trail on the character"
)
action(alice, { t = "buyCoins", id = "skin_gold" })
check(not d.owned.skin_gold, "VIP item not for sale")
action(alice, { t = "restart" })
untilPhase(run, "play")
action(alice, { t = "rewind" })
waitUntil(function()
	tick(0.05)
	return run.phase ~= "play"
end, 3)
check(run.ghosts[#run.ghosts].skin == "skin_glass", "the new ghost wears it")

print("== passes")
action(alice, { t = "pass", key = "Vip" })
check(alice:GetAttribute("Pass_Vip") == true, "VIP emulated in Studio")
action(alice, { t = "equip", id = "skin_gold" })
check(alice:GetAttribute("Skin") == "skin_gold", "VIP wears the golden look")
check(alice.Character.Head:FindFirstChild("VipTag") ~= nil, "VIP tag")
action(alice, { t = "pass", key = "Oracle" })
check(alice:GetAttribute("Pass_Oracle") == true, "Oracle")

print("== capsule and PolicyService")
action(alice, { t = "product", key = "Chest" })
local cr = last(alice, "chestResult")
check(cr ~= nil and Catalog.get(cr.id) ~= nil, "capsule gives an item: " .. tostring(cr and cr.id))
Sim.policyRestricted = true
local carol = Sim.addPlayer("Carol")
Sim.signalOf(Players, "PlayerAdded"):Fire(carol)
check(
	waitUntil(function()
		tick(0.05)
		return Data.get(carol) ~= nil and LS.runOf(carol) ~= nil
	end, 6),
	"late joiner gets a profile and a level"
)
task.wait(0.2)
action(carol, { t = "profile" })
check(last(carol, "profile").chestAllowed == false, "restricted region: capsule hidden")
action(carol, { t = "product", key = "Chest" })
check(
	last(carol, "toast").key == "shop.chestRestricted" and last(carol, "chestResult") == nil,
	"restricted region: capsule refused by the server"
)
action(carol, { t = "product", key = "DirectEpic", item = "skin_hologram" })
check(Data.get(carol).owned.skin_hologram == true, "restricted region: direct purchase works")
action(carol, { t = "product", key = "DirectEpic", item = "skin_glass" })
check(not Data.get(carol).owned.skin_glass, "direct purchase checks rarity")
Sim.policyRestricted = false
Sim.policyFail = true
local dave = Sim.addPlayer("Dave")
Sim.signalOf(Players, "PlayerAdded"):Fire(dave)
waitUntil(function()
	tick(0.05)
	return Data.get(dave) ~= nil
end, 5)
task.wait(0.2)
action(dave, { t = "product", key = "Chest" })
check(last(dave, "chestResult") == nil, "policy request fails → capsule treated as restricted")
Sim.policyFail = false

print("== receipts are idempotent")
local c1 = d.coins
check(Monetization.grant(alice, "Coins500", "PID-1"), "grant ok")
check(Monetization.grant(alice, "Coins500", "PID-1"), "repeat ok")
check(d.coins == c1 + 500, "coins added once (" .. (d.coins - c1) .. ")")
check(Sim.processReceipt ~= nil, "ProcessReceipt is set")

print("== data saving")
check(Data.save(alice), "save works")
local stored = Sim.dataStores[Config.DataStore.Name]["u_" .. alice.UserId]
check(
	stored and stored.coins == d.coins and stored.owned.skin_glass and stored.stars == d.stars,
	"profile stored"
)
Sim.dataFail = true
local erin = Sim.addPlayer("Erin")
Sim.signalOf(Players, "PlayerAdded"):Fire(erin)
check(
	waitUntil(function()
		tick(0.05)
		return Data.get(erin) ~= nil and LS.runOf(erin) ~= nil
	end, 15),
	"data outage: player still gets a temp profile and a level"
)
check(erin:GetAttribute("DataSaved") == false, "temp profile is marked unsaved")
Sim.dataFail = false

print("== player leaves")
local daveRun = LS.runOf(dave)
Sim.signalOf(Players, "PlayerRemoving"):Fire(dave)
task.wait(0.1)
dave.Parent = nil
check(LS.runOf(dave) == nil and ws.Levels:FindFirstChild("Run_" .. daveRun.id) == nil, "his level is removed")

print("== autoplay (Studio): the server plays a whole level by the solution")
action(alice, { t = "debug", cmd = "level", arg = 9 })
action(alice, { t = "debug", cmd = "autoplay" })
local wonBefore = #sentTo(alice, "won")
check(
	waitUntil(function()
		tick(0.1)
		return #sentTo(alice, "won") > wonBefore
	end, 30),
	"autoplay cracks level 9 in k loops"
)
check(last(alice, "won").loops == Campaign.level(9).k, "in exactly k loops")
action(alice, { t = "debug", cmd = "autoplay" })

print("== selftest")
action(alice, { t = "debug", cmd = "selftest" })
check(
	waitUntil(function()
		return #sentTo(alice, "selftest") > 0
	end, 20),
	"selftest finished"
)
local stl = last(alice, "selftest")
local fails = 0
for _, line in stl and stl.lines or {} do
	print("    " .. line)
	if string.find(line, "FAIL", 1, true) then
		fails += 1
	end
end
check(fails == 0, "selftest has no FAIL")

print("== warnings")
local errs = 0
for _, w in Sim.warnings or {} do
	if string.find(w, "error", 1, true) or string.find(w, "[Actions]", 1, true) then
		errs += 1
		print("    " .. w)
	end
end
check(errs == 0, "no runtime errors")
print(string.format("\n%d failures", #failures))
process.exit(if #failures > 0 then 1 else 0)
