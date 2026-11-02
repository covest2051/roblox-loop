--[[
	SelfTest — проверки внутри движка (запускается в Studio при старте и кнопкой DBG).
	Пишет в Output строки [SELFTEST] PASS/WARN/FAIL и итог RESULT.
]]

local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Loop = require(Shared.Loop)
local Planner = require(Shared.Planner)

local LoopService = require(script.Parent.LoopService)

local SelfTest = {}

function SelfTest.run(): { string }
	local lines = {}
	local pass, warns, total = 0, 0, 0
	local function check(name: string, fn: () -> (boolean | string, string?))
		total += 1
		local ok, res, detail = pcall(fn)
		local line
		if not ok then
			line = "[SELFTEST] FAIL " .. name .. ": " .. tostring(res)
		elseif res == true then
			pass += 1
			line = "[SELFTEST] PASS " .. name .. (if detail then " (" .. detail .. ")" else "")
		elseif res == "warn" then
			pass += 1
			warns += 1
			line = "[SELFTEST] WARN " .. name .. (if detail then ": " .. detail else "")
		else
			line = "[SELFTEST] FAIL " .. name .. (if detail then ": " .. detail else "")
		end
		print(line)
		table.insert(lines, line)
	end

	local p1 = Players:GetPlayers()[1]
	local run = p1 and LoopService.runOf(p1)

	check("streaming off, characters spawn after the world", function()
		return Workspace.StreamingEnabled == false and Players.CharacterAutoLoads == false
	end)

	check("level built from primitives", function()
		if not run then
			return "warn", "no player in a level"
		end
		local m = run.model
		local doors, plates = #m.Doors:GetChildren(), #m.Plates:GetChildren()
		local ok = doors == #run.lv.doors and plates == #run.lv.plates and m:FindFirstChild("Treasure") ~= nil
		return ok,
			string.format(
				"level %d: %d doors, %d plates, %d instances",
				run.n,
				doors,
				plates,
				#m:GetDescendants()
			)
	end)

	check("player stands in the level", function()
		if not run or not p1.Character then
			return "warn", "no character"
		end
		local root = p1.Character:FindFirstChild("HumanoidRootPart") :: BasePart
		local pos = root.CFrame.Position - run.origin
		local inside = pos.X > 0
			and pos.Z > 0
			and pos.X < run.lv.w * Config.Grid.Tile
			and pos.Z < run.lv.h * Config.Grid.Tile
		return inside, string.format("at %.0f, %.0f, %.0f from the level corner", pos.X, pos.Y, pos.Z)
	end)

	check("loop clock runs on server time", function()
		if not run or not run.st then
			return "warn", "no loop yet"
		end
		local expect = math.floor((Workspace:GetServerTimeNow() - run.loopStart) / Config.Loop.Step)
		if run.phase ~= "play" then
			return true, "phase " .. run.phase
		end
		return math.abs(expect - run.st.step) <= 2,
			string.format("step %d, clock says %d", run.st.step, expect)
	end)

	check("ghosts replay deterministically", function()
		if not run or #run.ghosts == 0 then
			return "warn", "no ghosts yet (finish a loop with ⟲)"
		end
		local function runOnce()
			local st = Loop.new(run.lv, run.ghosts, {})
			while st.step < st.n and not st.won do
				Loop.step(st, nil)
			end
			return Loop.logString(st)
		end
		return runOnce() == runOnce(), #run.ghosts .. " ghosts, identical event logs"
	end)

	check("current level: solvable in exactly k", function()
		if not run then
			return "warn", "no level"
		end
		local plan = LoopService.planFor(run.n)
		if not plan then
			return false, "no plan"
		end
		local ok = Planner.verify(run.lv, plan.recs)
		local lower = Planner.canWin(run.lv, run.lv.k - 1)
		return ok and lower == false, string.format("k = %d, D = %.1f", run.lv.k, plan.metrics.D)
	end)

	check("products configured", function()
		local missing = {}
		for _, k in Config.ProductOrder do
			if Config.Products[k].id == 0 then
				table.insert(missing, k)
			end
		end
		for _, k in Config.PassOrder do
			if Config.Passes[k].id == 0 then
				table.insert(missing, k)
			end
		end
		if #missing > 0 then
			return "warn", "ID = 0 (emulated in Studio): " .. table.concat(missing, ", ")
		end
		return true
	end)

	check("player data saves", function()
		if not p1 then
			return "warn", "no players"
		end
		if p1:GetAttribute("DataSaved") ~= true then
			return "warn",
				"DataStore off: Game Settings → Security → Enable Studio Access to API Services"
		end
		return true
	end)

	check("PolicyService answers", function()
		if not p1 then
			return "warn", "no players"
		end
		local info = PolicyService:GetPolicyInfoForPlayerAsync(p1)
		return true, "ArePaidRandomItemsRestricted=" .. tostring(info.ArePaidRandomItemsRestricted)
	end)

	local result = string.format("[SELFTEST] RESULT %d/%d passed, %d warnings", pass, total, warns)
	print(result)
	table.insert(lines, result)
	return lines
end

return SelfTest
