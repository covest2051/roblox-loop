return function(t)
	local Config = t.shared("Config")
	local Level = t.shared("Level")
	local Loop = t.shared("Loop")
	local Planner = t.shared("Planner")
	local Campaign = t.shared("Campaign")

	local CLOSE = math.floor(Config.Loop.CloseDelay / Config.Loop.Step + 0.5)
	local FULL = Config.Loop.WalkSpeed / Config.Grid.Tile * Config.Loop.Step -- клеток за шаг

	-- первый уровень кампании, где есть то, что нужно
	local function findLevel(pred)
		for n = 1, Campaign.Count do
			local lv = Campaign.level(n)
			local r = pred(lv)
			if r then
				return lv, r
			end
		end
		error("no campaign level with the feature")
	end
	local function plateOf(lv, color)
		for _, p in lv.plates do
			if p.kind == "switch" and p.color == color then
				return p
			end
		end
		return nil
	end
	local function startXY(lv)
		return lv.start.x + 0.5, lv.start.y + 0.5
	end

	-- запись по точкам (центры клеток) с постоянной скоростью; picks[i] — ключ в точке i
	local function makeRec(lv, waypoints, speed, picks)
		local sx, sy = startXY(lv)
		local rec = Loop.newRecording(sx, sy)
		local x, y = sx, sy
		local cx, cy = lv.start.x, lv.start.y
		local s = 0
		local path = {}
		for wi, wp in waypoints do
			local seg = Planner.route(lv, cx, cy, wp.x, wp.y)
			assert(seg, "route")
			for j, tile in seg do
				table.insert(
					path,
					{ x = tile.x, y = tile.y, pick = if j == #seg and picks then picks[wi] else nil }
				)
			end
			cx, cy = wp.x, wp.y
		end
		local i = 1
		local wantPick = {}
		for _, tile in path do
			if tile.pick then
				wantPick[tile.y * lv.w + tile.x + 1] = tile.pick
			end
		end
		while i <= #path do
			s += 1
			local budget = speed
			while budget > 1e-9 and i <= #path do
				local tx, ty = path[i].x + 0.5, path[i].y + 0.5
				local dx, dy = tx - x, ty - y
				local d = math.sqrt(dx * dx + dy * dy)
				if d <= budget then
					x, y = tx, ty
					budget -= d
					i += 1
				else
					x, y = x + dx / d * budget, y + dy / d * budget
					budget = 0
				end
			end
			rec.xs[s], rec.ys[s] = Loop.quantize(x), Loop.quantize(y)
			rec.n = s
			-- как у живого: ключ берётся при входе в клетку
			local ti = math.floor(rec.ys[s]) * lv.w + math.floor(rec.xs[s]) + 1
			if wantPick[ti] then
				rec.ev[s] = { "pick", wantPick[ti] }
				wantPick[ti] = nil
			end
		end
		return rec
	end

	-- живые боты: идут к клеткам; drive(st, bots) — один шаг для всех
	local function walker(lv, tx, ty, speed)
		return Planner.newBot(lv, 1, { { kind = "goto", x = tx, y = ty } }, { speed = speed or 1 })
	end
	local function stepAll(st, bots)
		local inputs = {}
		for id, bot in bots do
			local b = Loop.bodyOf(st, id)
			local x, y = Planner.drive(bot, st, b)
			inputs[id] = { x = x, y = y }
		end
		return Loop.step(st, inputs)
	end
	local function until_(st, bots, cond, max)
		local evs = {}
		for _ = 1, max or 200 do
			if cond() then
				return true, evs
			end
			for _, e in stepAll(st, bots) do
				table.insert(evs, e)
			end
		end
		return cond(), evs
	end
	local function at(st, id, x, y)
		local b = Loop.bodyOf(st, id)
		return b.tx == x and b.ty == y
	end

	t.test("switch plate opens its door; a body in the doorway holds it; closes after the delay", function()
		local lv, door = findLevel(function(lv)
			for _, d in lv.doors do
				if
					d.kind == "switch"
					and #Planner.gatesBetween(lv, 1, plateOf(lv, d.color).zone) == 0
					and d.parent == 1
				then
					return d
				end
			end
			return nil
		end)
		local s = plateOf(lv, door.color)
		local sx, sy = startXY(lv)
		local st = Loop.new(lv, {}, { { id = "a", x = sx, y = sy }, { id = "b", x = sx, y = sy } })
		t.ok(not st.doors[door.id].open, "closed at start")
		local bots = { a = walker(lv, s.x, s.y), b = walker(lv, door.frontP.x, door.frontP.y) }
		t.ok(
			until_(st, bots, function()
				return at(st, "a", s.x, s.y) and at(st, "b", door.frontP.x, door.frontP.y)
			end),
			"a on the switch, b at the door"
		)
		Loop.step(st, {})
		t.ok(st.plates[s.id] and st.doors[door.id].open, "pressed → open")
		bots = { b = walker(lv, door.x, door.y) }
		t.ok(
			until_(st, bots, function()
				return at(st, "b", door.x, door.y)
			end),
			"b stands in the doorway"
		)
		bots = { a = walker(lv, lv.start.x, lv.start.y) }
		t.ok(
			until_(st, bots, function()
				return at(st, "a", lv.start.x, lv.start.y)
			end),
			"a leaves the switch"
		)
		for _ = 1, 20 do
			Loop.step(st, {})
		end
		t.ok(not st.plates[s.id], "plate released")
		t.ok(st.doors[door.id].open, "door held open by b in the doorway")
		bots = { b = walker(lv, door.frontP.x, door.frontP.y) }
		t.ok(
			until_(st, bots, function()
				return at(st, "b", door.frontP.x, door.frontP.y)
			end),
			"b steps out"
		)
		local closedAfter = nil
		for i = 1, CLOSE + 3 do
			if not st.doors[door.id].open then
				closedAfter = i - 1
				break
			end
			Loop.step(st, {})
		end
		t.ok(
			closedAfter ~= nil and closedAfter >= CLOSE - 1 and closedAfter <= CLOSE + 1,
			"closes after the delay: " .. tostring(closedAfter)
		)
		-- закрытая дверь не пускает живого
		local b = Loop.bodyOf(st, "b")
		local bx, by = b.x, b.y
		local evs = Loop.step(st, { b = { x = door.x + 0.5, y = door.y + 0.5 } })
		local blocked = false
		for _, e in evs do
			blocked = blocked or e.t == "blocked"
		end
		t.ok(blocked and b.x == bx and b.y == by, "walking into a shut door is reverted")
	end)

	t.test("vault opens only with every gold plate pressed; touching the treasure wins", function()
		local lv = Campaign.level(1)
		local vp
		for _, p in lv.plates do
			if p.kind == "vault" then
				vp = p
			end
		end
		local vd = lv.doors[lv.vaultDoor]
		local sx, sy = startXY(lv)
		local st = Loop.new(lv, {}, { { id = "a", x = sx, y = sy }, { id = "b", x = sx, y = sy } })
		t.eq(select(1, Loop.vaultCount(st)), 0)
		local bots = { a = walker(lv, vp.x, vp.y), b = walker(lv, vd.frontP.x, vd.frontP.y) }
		until_(st, bots, function()
			return at(st, "b", vd.frontP.x, vd.frontP.y) and not at(st, "a", vp.x, vp.y)
		end, 60)
		t.ok(not st.doors[vd.id].open or at(st, "a", vp.x, vp.y), "vault shut until the plate")
		until_(st, bots, function()
			return at(st, "a", vp.x, vp.y)
		end)
		Loop.step(st, {})
		local n, total = Loop.vaultCount(st)
		t.ok(n == 1 and total == 1 and st.doors[vd.id].open, "vault open, lamps 1/1")
		local ok = until_(st, { b = walker(lv, lv.treasure.x, lv.treasure.y) }, function()
			return st.won
		end)
		t.ok(ok and Loop.over(st), "treasure → win")
	end)

	t.test("keys: picked up automatically, unlock the lock nearby, the lock stays open", function()
		local lv, door = findLevel(function(lv)
			for _, d in lv.doors do
				if d.kind == "lock" then
					for _, k in lv.keys do
						if
							#Planner.gatesBetween(lv, 1, k.zone) == 0
							and #Planner.gatesBetween(lv, 1, d.parent) == 0
						then
							return d
						end
					end
				end
			end
			return nil
		end)
		local key
		for _, k in lv.keys do
			if #Planner.gatesBetween(lv, 1, k.zone) == 0 then
				key = k
			end
		end
		local sx, sy = startXY(lv)
		local st = Loop.new(lv, {}, { { id = "a", x = sx, y = sy } })
		local ok, evs = until_(st, { a = walker(lv, key.x, key.y) }, function()
			return Loop.bodyOf(st, "a").carry ~= nil
		end)
		t.ok(ok and st.keys[key.id].state == "carried", "key picked")
		local picks = 0
		for _, e in evs do
			if e.t == "pick" then
				picks += 1
			end
		end
		t.eq(picks, 1)
		ok = until_(st, { a = walker(lv, door.frontP.x, door.frontP.y) }, function()
			return st.doors[door.id].unlocked
		end)
		t.ok(
			ok and st.keys[key.id].state == "used" and Loop.bodyOf(st, "a").carry == nil,
			"unlocked, key used"
		)
		until_(st, { a = walker(lv, lv.start.x, lv.start.y) }, function()
			return at(st, "a", lv.start.x, lv.start.y)
		end)
		t.ok(st.doors[door.id].open, "lock stays open for the rest of the loop")
		local rec = Loop.recordings(st)[1]
		local ev = {}
		for s, e in rec.ev do
			table.insert(ev, e[1] .. "@" .. s)
		end
		t.eq(#ev, 2, "recording has the pick and the unlock: " .. table.concat(ev, ","))
	end)

	-- уровень с ключом без ворот на пути и замком у зоны старта
	local function keyLevel()
		return findLevel(function(lv)
			for _, d in lv.doors do
				if d.kind == "lock" and d.parent == 1 then
					for _, k in lv.keys do
						if k.zone == 1 then
							return { door = d, key = k }
						end
					end
				end
			end
			return nil
		end)
	end

	t.test("a ghost replays its recording exactly: same positions, same events, every time", function()
		local lv, f = keyLevel()
		local sx, sy = startXY(lv)
		local st1 = Loop.new(lv, {}, { { id = "live", x = sx, y = sy } })
		local bot = Planner.newBot(lv, 1, {
			{ kind = "key", key = f.key.id },
			{ kind = "unlock", door = f.door.id },
			{ kind = "plate", plate = lv.plates[1].id },
		}, { speed = 0.9 })
		while not Loop.over(st1) do
			local b = st1.bodies[1]
			local x, y = Planner.drive(bot, st1, b)
			Loop.step(st1, { live = { x = x, y = y } })
			if bot.finished then
				Loop.finish(st1, "live")
			end
		end
		local rec = Loop.recordings(st1)[1]
		local function replay()
			local st = Loop.new(lv, { rec }, {})
			local track = {}
			while st.step < st.n do
				Loop.step(st, nil)
				local b = st.bodies[1]
				table.insert(track, b.x .. ":" .. b.y)
			end
			return st, table.concat(track, ";")
		end
		local a, ta = replay()
		local b, tb = replay()
		t.eq(Loop.logString(a), Loop.logString(b), "two replays — identical logs")
		t.eq(ta, tb)
		t.eq(a.paradoxes, 0)
		-- те же события, что и вживую (шаги совпадают)
		local function filt(st)
			local out = {}
			for _, e in st.log do
				if e.t == "pick" or e.t == "unlock" or e.t == "door" or e.t == "plate" then
					table.insert(out, e.t .. "@" .. e.step .. ":" .. tostring(e.door or e.plate or e.key))
				end
			end
			return table.concat(out, ",")
		end
		t.eq(filt(a), filt(st1), "ghost = what the live player did")
		local gx, gy = Loop.recAt(rec, rec.n)
		local g = a.bodies[1]
		t.ok(g.x == gx and g.y == gy, "after its recording ends the ghost stays put")
		t.ok(rec.n < a.n, "the recording ended early (rewind)")
		local p = Level.plateAt(lv, math.floor(gx), math.floor(gy))
		t.ok(p and a.plates[p.id], "and keeps the plate pressed to the end")
	end)

	t.test("PARADOX: someone takes the key first → the ghost shatters, stops acting", function()
		local lv, f = keyLevel()
		local rec = makeRec(
			lv,
			{ { x = f.key.x, y = f.key.y }, f.door.frontP },
			FULL * 0.5,
			{ [1] = f.key.id }
		)
		rec.ev[rec.n] = { "unlock", f.door.id }
		local sx, sy = startXY(lv)
		local st = Loop.new(lv, { rec }, { { id = "thief", x = sx, y = sy } })
		local _, evs = until_(st, { thief = walker(lv, f.key.x, f.key.y, 1) }, function()
			return st.bodies[1].broken
		end, 120)
		local par
		for _, e in evs do
			if e.t == "paradox" then
				par = e
			end
		end
		t.ok(par ~= nil and par.reason == "key", "paradox: key")
		t.eq(par.by, 2, "the thief holds it")
		t.ok(Loop.bodyOf(st, "thief").carry == f.key.id, "thief has the key")
		local g = st.bodies[1]
		local gx, gy = g.x, g.y
		for _ = 1, 60 do
			Loop.step(st, {})
		end
		t.ok(g.x == gx and g.y == gy, "shattered ghost stands still")
		t.ok(not st.doors[f.door.id].unlocked, "the lock it would open stays locked")
	end)

	t.test("the past has priority: same step → the ghost gets the key", function()
		local lv, f = keyLevel()
		local rec = makeRec(lv, { { x = f.key.x, y = f.key.y } }, FULL, { [1] = f.key.id })
		local sx, sy = startXY(lv)
		local st = Loop.new(lv, { rec }, { { id = "live", x = sx, y = sy } })
		-- живой идёт по той же записи, шаг в шаг
		for s = 1, rec.n + 2 do
			local x, y = Loop.recAt(rec, s)
			Loop.step(st, { live = { x = x, y = y } })
		end
		t.eq(st.paradoxes, 0)
		t.eq(st.bodies[1].carry, f.key.id, "ghost has it")
		t.eq(Loop.bodyOf(st, "live").carry, nil, "live does not")
	end)

	t.test(
		"PARADOX: a recording walks into a shut door → shatters in front of it, drops its key",
		function()
			local lv, f = findLevel(function(lv)
				for _, d in lv.doors do
					if d.kind == "switch" and d.parent == 1 then
						for _, k in lv.keys do
							if k.zone == 1 then
								return { door = d, key = k }
							end
						end
					end
				end
				return nil
			end)
			-- запись: взять ключ, пройти цветную дверь (её держал кто-то, кого в этой петле нет)
			local rec = makeRec(
				lv,
				{ { x = f.key.x, y = f.key.y }, f.door.frontP, f.door.frontC },
				FULL * 0.85,
				{ [1] = f.key.id }
			)
			local st = Loop.new(lv, { rec }, {})
			local par
			while st.step < st.n do
				for _, e in Loop.step(st, nil) do
					if e.t == "paradox" then
						par = e
					end
				end
			end
			t.ok(par ~= nil and par.reason == "door" and par.door == f.door.id, "paradox: door")
			local g = st.bodies[1]
			t.ok(
				g.broken and g.tx == f.door.frontP.x and g.ty == f.door.frontP.y,
				"stopped in front of the door"
			)
			local k = st.keys[f.key.id]
			t.ok(k.state == "lying" and k.x == g.tx and k.y == g.ty, "its key fell on the floor")
			-- а живой может её подобрать
			local sx, sy = startXY(lv)
			local st2 = Loop.new(lv, { rec }, { { id = "live", x = sx, y = sy } })
			local ok = until_(st2, { live = walker(lv, f.door.frontP.x, f.door.frontP.y, 0.5) }, function()
				return Loop.bodyOf(st2, "live").carry ~= nil
			end, 149)
			t.ok(ok, "the dropped key can be picked up")
		end
	)

	t.test("shattered ghosts do not press plates (chains are visible)", function()
		local lv, f = findLevel(function(lv)
			for _, d in lv.doors do
				if d.kind == "switch" and d.parent == 1 then
					local s = plateOf(lv, d.color)
					for _, k in lv.keys do
						if k.zone == 1 and s.zone == 1 then
							return { door = d, key = k, s = s }
						end
					end
				end
			end
			return nil
		end)
		-- призрак: взять ключ и встать на переключатель навсегда; вор забирает ключ раньше
		local rec = makeRec(
			lv,
			{ { x = f.key.x, y = f.key.y }, { x = f.s.x, y = f.s.y } },
			FULL * 0.4,
			{ [1] = f.key.id }
		)
		local sx, sy = startXY(lv)
		local st = Loop.new(lv, { rec }, { { id = "thief", x = sx, y = sy } })
		until_(st, { thief = walker(lv, f.key.x, f.key.y, 1) }, function()
			return st.bodies[1].broken
		end, 120)
		for _ = 1, 100 do
			Loop.step(st, {})
		end
		t.ok(st.bodies[1].broken, "ghost shattered at the key")
		t.ok(not st.plates[f.s.id] and not st.doors[f.door.id].open, "its switch is never pressed")
		-- без вора тот же призрак держит дверь
		local st2 = Loop.new(lv, { rec }, {})
		while st2.step < st2.n do
			Loop.step(st2, nil)
		end
		t.ok(st2.plates[f.s.id] and st2.doors[f.door.id].open, "undisturbed, it holds the door")
	end)

	t.test("live input through a wall or too far is reverted", function()
		local lv = Campaign.level(1)
		local sx, sy = startXY(lv)
		local st = Loop.new(lv, {}, { { id = "a", x = sx, y = sy } })
		local evs = Loop.step(st, { a = { x = sx + 6, y = sy } })
		local b = Loop.bodyOf(st, "a")
		local blocked = false
		for _, e in evs do
			blocked = blocked or e.t == "blocked"
		end
		t.ok(blocked and b.x == Loop.quantize(sx), "through the wall → back")
		Loop.step(st, { a = { x = sx + 0.2, y = sy } })
		t.near(b.x, sx + 0.2, 0.011, "a normal step is accepted")
	end)

	t.test("prediction from ghosts matches a real run", function()
		local lv = Campaign.level(9)
		local plan = assert(Planner.solve(lv))
		local ghosts = {}
		for i = 1, lv.k - 1 do
			table.insert(ghosts, plan.recs[i])
		end
		local pred = Loop.predict(lv, ghosts)
		local st = Loop.new(lv, ghosts, {})
		local opened = {}
		while st.step < st.n do
			for _, e in Loop.step(st, nil) do
				if e.t == "door" and e.open then
					opened[e.door] = opened[e.door] or e.step
				end
			end
		end
		for id, s in opened do
			t.ok(
				#pred.doors[id] > 0 and pred.doors[id][1][1] == s,
				"door " .. id .. " predicted at step " .. s
			)
		end
		t.ok(next(opened) ~= nil, "some door opens")
	end)

	t.test("recording format: quantized, interpolates smoothly", function()
		local rec = Loop.newRecording(1.234567, 2.5)
		t.eq(rec.x0, 1.23)
		rec.xs = { 2, 3 }
		rec.ys = { 2.5, 2.5 }
		rec.n = 2
		local x = Loop.recLerp(rec, 1.5)
		t.near(x, 2.5, 1e-9)
		local x0 = Loop.recLerp(rec, 0)
		t.near(x0, 1.23, 1e-9)
		local x9 = Loop.recLerp(rec, 9)
		t.near(x9, 3, 1e-9, "after the end it stays")
	end)
end
