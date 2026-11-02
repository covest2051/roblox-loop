--[[
	Баланс на ботах: каждый уровень кампании решается ровно за k петель (не за k − 1),
	сложность растёт плавно, ожидания в решении мало, мастерство важно (новичок без
	«передач» и «наугад» проигрывают), а «ничего не делать» никогда не выгодно.
]]
return function(t)
	local Config = t.shared("Config")
	local Planner = t.shared("Planner")
	local Campaign = t.shared("Campaign")

	local plans = {}
	local function planOf(n)
		if plans[n] == nil then
			plans[n] = Planner.solve(Campaign.level(n)) or false
		end
		return plans[n] or nil
	end

	t.test("every level: impossible with k − 1 (exhaustive search of the relaxed model)", function()
		for n = 1, Campaign.Count do
			local lv = Campaign.level(n)
			local won, explored = Planner.canWin(lv, lv.k - 1)
			t.eq(won, false, string.format("L%d with %d bodies (explored %d states)", n, lv.k - 1, explored))
			local wonK = Planner.canWin(lv, lv.k)
			t.eq(wonK, true, "L" .. n .. " relaxed model solvable with k")
		end
	end)

	t.test("every level: the solver wins in exactly k loops, played loop by loop", function()
		local usable = Config.Loop.Length - Config.Plan.FinishSlack
		for n = 1, Campaign.Count do
			local lv = Campaign.level(n)
			local plan = planOf(n)
			t.ok(plan ~= nil, "L" .. n .. " has a plan")
			local ok, info = Planner.verify(lv, plan.recs)
			t.ok(
				ok,
				"L"
					.. n
					.. " verified loop by loop: "
					.. tostring(info and (info.reason or (info.event and info.event.t)))
			)
			t.ok(
				plan.metrics.finish <= usable + 1e-6,
				string.format("L%d finishes at %.1fs ≤ %.1fs", n, plan.metrics.finish, usable)
			)
			local r = Planner.play(lv, "pro", { plan = plan })
			t.ok(r.won and r.loop == lv.k and r.paradoxes == 0, "L" .. n .. " the bot head wins in loop k")
			local short = Planner.play(lv, "pro", { plan = plan, loops = lv.k - 1 })
			t.ok(not short.won, "L" .. n .. " not in k − 1 loops")
		end
	end)

	t.test("boredom: little waiting in every solution", function()
		local worst, worstMean = 0, 0
		for n = 1, Campaign.Count do
			local m = planOf(n).metrics
			t.ok(m.idleMax <= Config.Plan.MaxIdle, string.format("L%d longest wait %.1fs", n, m.idleMax))
			t.ok(
				m.idleMean <= Config.Plan.MeanIdle,
				string.format("L%d mean wait %.1fs per loop", n, m.idleMean)
			)
			worst = math.max(worst, m.idleMax)
			worstMean = math.max(worstMean, m.idleMean)
		end
		print(string.format("    boredom: longest wait %.1fs, worst mean %.1fs per loop", worst, worstMean))
	end)

	t.test("difficulty rises smoothly: small steps inside chapters, every chapter harder", function()
		local Ds = {}
		for n = 1, Campaign.Count do
			Ds[n] = planOf(n).metrics.D
		end
		local prevStart, prevMax, prevMean = -1, -1, -1
		local line = {}
		for c, ch in Campaign.Chapters do
			local sum, mx = 0, 0
			for n = ch.first, ch.last do
				sum += Ds[n]
				mx = math.max(mx, Ds[n])
				if n > ch.first then
					local d = Ds[n] - Ds[n - 1]
					t.ok(
						d >= -2.5,
						string.format("L%d: no dip inside a chapter (%.1f → %.1f)", n, Ds[n - 1], Ds[n])
					)
					t.ok(
						d <= 5,
						string.format("L%d: no jump inside a chapter (%.1f → %.1f)", n, Ds[n - 1], Ds[n])
					)
				end
				table.insert(line, string.format("%.0f", Ds[n]))
			end
			local mean = sum / (ch.last - ch.first + 1)
			t.ok(Ds[ch.first] >= prevStart, "chapter " .. c .. " starts no easier than the last one started")
			t.ok(mx > prevMax and mean > prevMean, "chapter " .. c .. " is harder")
			prevStart, prevMax, prevMean = Ds[ch.first], mx, mean
			table.insert(line, "|")
		end
		print("    D: " .. table.concat(line, " "))
		t.ok(Ds[Campaign.Count] > Ds[1] * 10, "the last level is far harder than the first")
	end)

	t.test("skill matters: baselines vs the solver", function()
		local res = { pro = 0, novice = 0, novice1 = 0, random = 0, idle = 0 }
		local byChapter = {}
		for c in Campaign.Chapters do
			byChapter[c] = { novice = 0, total = 0 }
		end
		for n = 1, Campaign.Count do
			local lv = Campaign.level(n)
			local plan = planOf(n)
			local c = Campaign.chapterOf(n)
			byChapter[c].total += 1
			if Planner.play(lv, "pro", { plan = plan }).won then
				res.pro += 1
			end
			if Planner.play(lv, "novice", {}).won then
				res.novice += 1
				byChapter[c].novice += 1
			end
			-- новичок с «Лишней петлёй»: держит дверь навсегда, поэтому ему нужен ещё один «я»
			if Planner.play(lv, "novice", { loops = lv.k + 1 }).won then
				res.novice1 += 1
			end
			for seed = 1, 3 do
				if Planner.play(lv, "random", { seed = seed * 7 + n, loops = lv.k + 2 }).won then
					res.random += 1
				end
			end
			if Planner.play(lv, "idle", { loops = lv.k + 2 }).won then
				res.idle += 1
			end
		end
		local parts = {}
		for c, b in byChapter do
			table.insert(parts, string.format("ch%d %d/%d", c, b.novice, b.total))
		end
		print(
			string.format(
				"    solver %d/30 · novice %d/30 (%s) · novice+1 loop %d/30 · random %d/90 · idle %d/30",
				res.pro,
				res.novice,
				table.concat(parts, ", "),
				res.novice1,
				res.random,
				res.idle
			)
		)
		t.eq(res.pro, Campaign.Count, "solver wins everything")
		t.eq(res.idle, 0, "doing nothing never wins")
		t.eq(res.random, 0, "random play never wins")
		t.ok(res.novice >= 3 and res.novice <= 12, "a novice without relays clears only the easy levels")
		t.ok(byChapter[1].novice >= 2, "chapter 1 is fair to a novice")
		t.eq(byChapter[4].novice + byChapter[5].novice, 0, "chapters 4–5 need real planning")
		t.ok(res.novice1 > res.novice, "an extra loop really helps (worth buying)")
	end)

	t.test("humans are slower: the solution survives a 0.3 s reaction delay", function()
		local ok = 0
		for n = 1, Campaign.Count do
			local lv = Campaign.level(n)
			local plan = planOf(n)
			-- живой «человек» в каждой петле — бот с задержкой реакции 0.3 с и полной скоростью
			local r = Planner.play(lv, "pro", { plan = plan, speed = 1, reaction = 0.3 })
			if r.won then
				ok += 1
			end
		end
		print(string.format("    reaction 0.3 s + full speed: %d/30 levels still won by the plan", ok))
		t.ok(ok >= 24, "timing slack is enough for people")
	end)
end
