return function(t)
	local Config = t.shared("Config")
	local Level = t.shared("Level")
	local Campaign = t.shared("Campaign")
	local Planner = t.shared("Planner")

	local function floodAll(lv)
		-- все клетки пола связаны (двери считаем проходимыми)
		local seen, n, total = {}, 0, 0
		for y = 0, lv.h - 1 do
			for x = 0, lv.w - 1 do
				if Level.isFloor(lv, x, y) then
					total += 1
				end
			end
		end
		local stack = { { lv.start.x, lv.start.y } }
		seen[Level.idx(lv, lv.start.x, lv.start.y)] = true
		while #stack > 0 do
			local c = table.remove(stack)
			n += 1
			for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				local x, y = c[1] + d[1], c[2] + d[2]
				local i = Level.idx(lv, x, y)
				if Level.isFloor(lv, x, y) and not seen[i] then
					seen[i] = true
					table.insert(stack, { x, y })
				end
			end
		end
		return n, total
	end

	t.test("same spec and seed → the same level", function()
		local sp = Campaign.Specs[20]
		local a = Level.generate(sp, Campaign.Seeds[20])
		local b = Level.generate(sp, Campaign.Seeds[20])
		t.ok(a and b)
		t.eq(table.concat(a.cells, ""), table.concat(b.cells, ""))
		t.eq(#a.doors, #b.doors)
		for i, p in a.plates do
			t.ok(p.x == b.plates[i].x and p.y == b.plates[i].y and p.kind == b.plates[i].kind)
		end
		local c = Level.generate(sp, Campaign.Seeds[20] + 1)
		t.ok(
			c == nil
				or table.concat(c.cells, "") ~= table.concat(a.cells, "")
				or #c.plates ~= #a.plates
				or c.plates[1].x ~= a.plates[1].x,
			"another seed — another level"
		)
	end)

	local function checkLevel(lv, name)
		-- рамка из стен, всё связано
		for x = 0, lv.w - 1 do
			t.ok(not Level.isFloor(lv, x, 0) and not Level.isFloor(lv, x, lv.h - 1), name .. " border")
		end
		for y = 0, lv.h - 1 do
			t.ok(not Level.isFloor(lv, 0, y) and not Level.isFloor(lv, lv.w - 1, y), name .. " border")
		end
		local n, total = floodAll(lv)
		t.eq(n, total, name .. " all floor connected")
		-- k − 1 золотых плит на разных клетках, сокровище в хранилище
		local vault, seen = 0, {}
		for _, p in lv.plates do
			local i = Level.idx(lv, p.x, p.y)
			t.ok(not seen[i], name .. " one item per tile")
			seen[i] = true
			t.ok(Level.isFloor(lv, p.x, p.y) and not Level.doorAt(lv, p.x, p.y), name .. " plate on floor")
			t.eq(Level.zoneAt(lv, p.x, p.y), p.zone, name .. " plate zone")
			t.ok(p.zone ~= lv.vaultZone, name .. " no plates in the vault")
			if p.kind == "vault" then
				vault += 1
			end
		end
		for _, k in lv.keys do
			local i = Level.idx(lv, k.x, k.y)
			t.ok(not seen[i], name .. " key tile is free")
			seen[i] = true
		end
		for _, s in lv.starts do
			t.ok(not seen[Level.idx(lv, s.x, s.y)], name .. " start tiles are free")
			t.ok(Level.isFloor(lv, s.x, s.y), name .. " start on floor")
		end
		t.eq(vault, lv.k - 1, name .. " k − 1 vault plates")
		t.eq(Level.zoneAt(lv, lv.treasure.x, lv.treasure.y), lv.vaultZone, name .. " treasure in the vault")
		t.eq(#lv.starts, Config.Loop.MaxPlayers, name .. " a start tile for every co-op player")
		-- хранилище — лист дерева зон, вход только через дверь хранилища
		for _, z in lv.zones do
			t.ok(z.parent ~= lv.vaultZone, name .. " vault is a leaf")
		end
		t.eq(lv.zones[lv.vaultZone].gate, lv.vaultDoor, name .. " vault door")
		-- двери в стенах, с полом по обе стороны в правильных зонах
		for _, d in lv.doors do
			t.ok(Level.isFloor(lv, d.x, d.y), name .. " door tile")
			t.eq(Level.zoneAt(lv, d.frontP.x, d.frontP.y), d.parent, name .. " door parent side")
			t.eq(Level.zoneAt(lv, d.frontC.x, d.frontC.y), d.child, name .. " door child side")
			t.eq(math.abs(d.frontP.x - d.frontC.x) + math.abs(d.frontP.y - d.frontC.y), 2, name .. " fronts")
			local sideA, sideB
			if d.axis == "x" then
				sideA, sideB = Level.isFloor(lv, d.x, d.y - 1), Level.isFloor(lv, d.x, d.y + 1)
			else
				sideA, sideB = Level.isFloor(lv, d.x - 1, d.y), Level.isFloor(lv, d.x + 1, d.y)
			end
			t.ok(not sideA and not sideB, name .. " door is in a wall")
			-- переключатель / ключ — не за своими воротами
			local function under(z)
				local cur = lv.zones[z]
				while cur do
					if cur.id == d.child then
						return true
					end
					cur = cur.parent and lv.zones[cur.parent]
				end
				return false
			end
			if d.kind == "switch" then
				local found = false
				for _, p in lv.plates do
					if p.kind == "switch" and p.color == d.color then
						found = true
						t.ok(not under(p.zone), name .. " switch before its door")
					end
				end
				t.ok(found, name .. " switch exists")
			elseif d.kind == "lock" then
				local before = false
				for _, k in lv.keys do
					before = before or not under(k.zone)
				end
				t.ok(before, name .. " a key before the lock")
			end
		end
		-- уровень помещается в слот сервера
		t.ok(math.max(lv.w, lv.h) * Config.Grid.Tile < Config.Grid.SlotGap - 40, name .. " fits a slot")
	end

	t.test("campaign levels are well-formed", function()
		t.eq(Campaign.Count, 30)
		for n = 1, Campaign.Count do
			local lv = Campaign.level(n)
			t.ok(lv ~= nil, "level " .. n .. " builds")
			checkLevel(lv, "L" .. n)
			t.eq(lv.k, Campaign.Specs[n].k)
		end
	end)

	t.test("random specs: either a valid level or a reason", function()
		local ok, bad = 0, 0
		for seed = 1, 120 do
			local sp = Campaign.Specs[(seed % Campaign.Count) + 1]
			local lv, why = Level.generate(sp, seed * 31)
			if lv then
				ok += 1
				checkLevel(lv, "seed" .. seed)
			else
				bad += 1
				t.ok(type(why) == "string", "reason")
			end
		end
		t.ok(ok >= 40, "enough valid levels: " .. ok)
	end)

	t.test("zone tree paths", function()
		local lv = Campaign.level(22)
		for _, z in lv.zones do
			local path = Planner.gatesBetween(lv, 1, z.id)
			t.eq(#path, z.depth, "depth = gates on the path")
			local back = Planner.gatesBetween(lv, z.id, 1)
			t.eq(#back, #path)
		end
		t.eq(#Planner.gatesBetween(lv, 1, 1), 0)
	end)

	t.test("chapters cover the campaign in order", function()
		local next = 1
		for _, ch in Campaign.Chapters do
			t.eq(ch.first, next)
			next = ch.last + 1
		end
		t.eq(next - 1, Campaign.Count)
	end)
end
