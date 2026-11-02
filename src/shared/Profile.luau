--[[
	Profile — данные игрока и все операции над ними. Чистые функции:
	сервер хранит профиль в DataStore, тесты проверяют правила (дубликаты, покупки,
	звёзды и открытие уровней, журнал чеков).
	Звёзды хранятся строкой цифр ("3210…", символ n — уровень n): DataStore не любит
	таблицы с дырявыми числовыми ключами.
]]

local Shared = script.Parent
local Config = require(Shared.Config)
local Catalog = require(Shared.Catalog)

local Profile = {}

Profile.Version = 1

export type Data = {
	v: number,
	coins: number,
	owned: { [string]: boolean },
	equipped: { skin: string, trail: string, rewind: string },
	stars: string,
	loops: number, -- петель сыграно
	clears: number, -- уровней пройдено (с повторами)
	perfects: number, -- ★★★
	paradoxes: number,
	earned: number,
	chests: number,
	receipts: { string },
}

local STATS = { "loops", "clears", "perfects", "paradoxes", "earned", "chests" }

function Profile.new(): Data
	local owned = {}
	for _, kind in Catalog.Kinds do
		owned[Catalog.Default[kind]] = true
	end
	return {
		v = Profile.Version,
		coins = 0,
		owned = owned,
		equipped = {
			skin = Catalog.Default.skin,
			trail = Catalog.Default.trail,
			rewind = Catalog.Default.rewind,
		},
		stars = "",
		loops = 0,
		clears = 0,
		perfects = 0,
		paradoxes = 0,
		earned = 0,
		chests = 0,
		receipts = {},
	}
end

-- Приводит сохранённые данные к текущему формату (новые поля, неизвестные предметы)
function Profile.migrate(raw: any): Data
	local d = Profile.new()
	if type(raw) ~= "table" then
		return d
	end
	if type(raw.coins) == "number" then
		d.coins = math.max(0, math.floor(raw.coins))
	end
	for _, key in STATS do
		if type(raw[key]) == "number" then
			(d :: any)[key] = math.max(0, math.floor(raw[key]))
		end
	end
	if type(raw.stars) == "string" then
		d.stars = string.gsub(raw.stars, "[^0-3]", "0")
	end
	if type(raw.owned) == "table" then
		for id, v in raw.owned do
			if v == true and type(id) == "string" and Catalog.get(id) then
				d.owned[id] = true
			end
		end
	end
	if type(raw.equipped) == "table" then
		for _, kind in Catalog.Kinds do
			local id = raw.equipped[kind]
			local item = type(id) == "string" and Catalog.get(id)
			if item and item.kind == kind then
				(d.equipped :: any)[kind] = id
			end
		end
	end
	if type(raw.receipts) == "table" then
		for _, r in raw.receipts do
			if type(r) == "string" then
				table.insert(d.receipts, r)
			end
		end
	end
	return d
end

function Profile.addCoins(d: Data, n: number)
	d.coins = math.max(0, d.coins + math.floor(n))
end

-- Монеты, заработанные в игре (учитываются в статистике)
function Profile.earn(d: Data, n: number)
	if n > 0 then
		Profile.addCoins(d, n)
		d.earned += math.floor(n)
	end
end

function Profile.starsOf(d: Data, n: number): number
	return tonumber(string.sub(d.stars, n, n)) or 0
end

function Profile.totalStars(d: Data): number
	local s = 0
	for i = 1, #d.stars do
		s += tonumber(string.sub(d.stars, i, i)) or 0
	end
	return s
end

-- Записать результат уровня. Возвращает (первое прохождение?, сколько новых звёзд)
function Profile.recordClear(d: Data, n: number, stars: number): (boolean, number)
	local old = Profile.starsOf(d, n)
	local first = old == 0
	if stars > old then
		while #d.stars < n do
			d.stars ..= "0"
		end
		d.stars = string.sub(d.stars, 1, n - 1) .. tostring(stars) .. string.sub(d.stars, n + 1)
	end
	d.clears += 1
	if stars >= 3 then
		d.perfects += 1
	end
	return first, math.max(0, stars - old)
end

-- Уровень открыт: первый, или пройден предыдущий
function Profile.unlocked(d: Data, n: number): boolean
	return n <= 1 or Profile.starsOf(d, n - 1) > 0 or Profile.starsOf(d, n) > 0
end

-- Следующий непройденный уровень (для автозапуска при входе)
function Profile.nextLevel(d: Data, count: number): number
	for n = 1, count do
		if Profile.starsOf(d, n) == 0 then
			return n
		end
	end
	return count
end

function Profile.owns(d: Data, id: string): boolean
	return d.owned[id] == true
end

-- Выдать предмет. Дубликат → возврат монет. Возвращает { id, dup, refund }
function Profile.grantItem(d: Data, id: string): { id: string, dup: boolean, refund: number }
	if d.owned[id] then
		local refund = Catalog.refund(id)
		Profile.addCoins(d, refund)
		return { id = id, dup = true, refund = refund }
	end
	d.owned[id] = true
	return { id = id, dup = false, refund = 0 }
end

-- Покупка за монеты
function Profile.buyWithCoins(d: Data, id: string): (boolean, string?)
	local item = Catalog.get(id)
	if not item or not Catalog.isTradable(item) then
		return false, "shop.notForSale"
	end
	if d.owned[id] then
		return false, "shop.owned"
	end
	local price = Catalog.price(id) :: number
	if d.coins < price then
		return false, "shop.noCoins"
	end
	d.coins -= price
	d.owned[id] = true
	return true, nil
end

-- Надеть. hasVip — для VIP-предметов не нужно владение, нужен геймпасс.
function Profile.equip(d: Data, id: string, hasVip: boolean): boolean
	local item = Catalog.get(id)
	if not item then
		return false
	end
	local ok = d.owned[id] or (item.rarity == "Vip" and hasVip)
	if not ok then
		return false
	end
	(d.equipped :: any)[item.kind] = id
	return true
end

-- Что реально надето (VIP-предмет снимается, если геймпасса больше нет)
function Profile.effective(d: Data, kind: string, hasVip: boolean): string
	local id = (d.equipped :: any)[kind]
	local item = Catalog.get(id)
	if not item or item.kind ~= kind then
		return Catalog.Default[kind]
	end
	if item.rarity == "Vip" and not hasVip then
		return Catalog.Default[kind]
	end
	if item.rarity ~= "Vip" and not d.owned[id] then
		return Catalog.Default[kind]
	end
	return id
end

-- Для прямой покупки за Robux: выбранный предмет, если он этой редкости и ещё не куплен,
-- иначе любой некупленный этой редкости. nil — всё уже есть.
function Profile.pickDirect(d: Data, rarity: string, wanted: string?): string?
	local item = wanted and Catalog.get(wanted)
	if item and item.rarity == rarity and not d.owned[wanted :: string] then
		return wanted
	end
	for _, it in Catalog.ofRarity(rarity) do
		if not d.owned[it.id] then
			return it.id
		end
	end
	return nil
end

function Profile.hasReceipt(d: Data, purchaseId: string): boolean
	return table.find(d.receipts, purchaseId) ~= nil
end

function Profile.addReceipt(d: Data, purchaseId: string)
	table.insert(d.receipts, purchaseId)
	while #d.receipts > Config.DataStore.ReceiptLog do
		table.remove(d.receipts, 1)
	end
end

return Profile
