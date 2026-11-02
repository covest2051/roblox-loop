--[[
	Config — все числа баланса и ID товаров в одном месте.
	После правки: `lune run tests/run.luau` (тест решателя скажет, если уровень стал
	нерешаемым за K петель или решаемым за K−1, тест скуки — если в решении долго ждать).
]]

local Config = {}

Config.Version = "1.0.0"

-- Мир уровня. Клетка (x, y) уровня → мир: origin + ((x + 0.5)·Tile, 0, (y + 0.5)·Tile)
Config.Grid = {
	Tile = 6, -- studs
	WallH = 9,
	FloorY = 0, -- верх пола относительно origin
	SlotGap = 420, -- расстояние между экземплярами уровней на сервере
	SlotsPerRow = 4,
	BaseY = 200, -- уровни висят в «безвременье»
}

-- Петля
Config.Loop = {
	Length = 15, -- с
	Step = 0.1, -- шаг модели (150 шагов)
	CloseDelay = 0.3, -- дверь закрывается не сразу
	Rewind = 1.2, -- с между петлями (все бегут назад по своим следам)
	MaxPlayers = 4, -- живых в одном уровне
	WalkSpeed = 16, -- studs/s (StarterPlayer.CharacterWalkSpeed)
	SpeedSlack = 1.6, -- сервер: допуск к скорости живого
	OutWait = 12, -- с окна «петли кончились», потом сама отмена последней петли
	PayHold = 30, -- с: окно ждёт, пока открыт промпт «Лишней петли» (один раз)
	WinPause = 6, -- с экрана победы до следующего уровня
	ShadowAhead = 1.5, -- тень будущего: на сколько секунд вперёд
	PathAhead = 3, -- пунктир будущего пути
}

-- Решатель и генератор (бот-«голова»)
Config.Plan = {
	SpeedFactor = 0.85, -- боты ходят на 85% скорости: запас для человека
	FinishSlack = 1.5, -- решение должно успевать за Length − FinishSlack
	ReleaseMargin = 0.6, -- держать плиту ещё столько после прохода будущего «я»
	MaxIdle = 6, -- с подряд ожидания в решении (скука)
	MeanIdle = 3.5, -- с ожидания в среднем на петлю
	MaxAssignments = 400, -- перебор ролей
	BfsStates = 600000, -- предел состояний полного перебора
	MaxAttempts = 400, -- попыток генерации на уровень
}

-- Палитры. Цвет петли — номер призрака (1 оранжевый, 2 синий, …): игрок быстро запоминает.
Config.LoopColors = {
	{ 255, 150, 60 },
	{ 80, 180, 255 },
	{ 120, 235, 120 },
	{ 200, 120, 255 },
	{ 255, 95, 150 },
	{ 255, 225, 80 },
	{ 90, 235, 220 },
	{ 240, 240, 240 },
}
-- Цвета переключателей: символ + цвет (двери и плиты одного цвета)
Config.SwitchColors = {
	{ name = "A", rgb = { 40, 225, 210 }, glyph = "◆" },
	{ name = "B", rgb = { 255, 80, 200 }, glyph = "●" },
	{ name = "C", rgb = { 170, 240, 60 }, glyph = "▲" },
	{ name = "D", rgb = { 120, 140, 255 }, glyph = "■" },
}
Config.VaultColor = { 255, 200, 60 }
Config.KeyColor = { 255, 235, 150 }
Config.LockColor = { 230, 130, 50 }

Config.Rewards = {
	FirstBase = 20, -- первое прохождение: 20 + 10·K
	FirstPerK = 10,
	Repeat = 5,
	StarBonus = 5, -- за каждую новую звезду
	DoubleCoins = 2,
	VipBonus = 0.1,
	HintCost = 40,
}

Config.Timing = {
	Step = 0.1, -- шаг серверной логики (= Loop.Step)
}

-- Цены косметики в монетах и возврат за дубликат
Config.Rarity = {
	Common = { weight = 6000, price = 250, refund = 60, color = { 200, 205, 215 } },
	Rare = { weight = 2800, price = 600, refund = 150, color = { 90, 170, 255 } },
	Epic = { weight = 1000, price = 1500, refund = 400, color = { 190, 110, 255 } },
	Legendary = { weight = 200, price = 4000, refund = 1000, color = { 255, 190, 60 } },
}
Config.RarityOrder = { "Common", "Rare", "Epic", "Legendary" }
Config.WeightTotal = 10000 -- веса в сотых долях процента: 6000 = 60.00%

--[[
	ID товаров из Creator Hub (Monetization → Passes / Developer Products).
	Пока ID = 0: в Studio покупка эмулируется, в живой игре кнопка неактивна («скоро»).
	robux — рекомендуемые цены (настоящую цену игра берёт из GetProductInfo).
]]
Config.Passes = {
	DoubleCoins = { id = 0, robux = 149 },
	Vip = { id = 0, robux = 249 },
	Oracle = { id = 0, robux = 199 },
}
Config.PassOrder = { "Oracle", "DoubleCoins", "Vip" }
Config.Products = {
	ExtraLoop = { id = 0, robux = 19 },
	Coins500 = { id = 0, robux = 25, coins = 500 },
	Coins3000 = { id = 0, robux = 99, coins = 3000 },
	Chest = { id = 0, robux = 35 },
	DirectRare = { id = 0, robux = 49, rarity = "Rare" },
	DirectEpic = { id = 0, robux = 99, rarity = "Epic" },
	DirectLegendary = { id = 0, robux = 199, rarity = "Legendary" },
}
Config.ProductOrder =
	{ "ExtraLoop", "Coins500", "Coins3000", "Chest", "DirectRare", "DirectEpic", "DirectLegendary" }
Config.ChestFallbackCoins = 500 -- если капсула недоступна игроку по политике

Config.DataStore = {
	Name = "LoopProfiles_v1",
	AutosaveEvery = 90,
	Retries = 4,
	ReceiptLog = 100,
}

-- Встроенные звуки клиента (rbxasset://). Свои — rbxassetid://<id>.
Config.Sounds = {
	Rewind = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.5, Speed = 0.45 },
	Start = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.45, Speed = 1.1 },
	Plate = { Id = "rbxasset://sounds/clickfast.wav", Volume = 0.35, Speed = 1 },
	Door = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.25, Speed = 0.6 },
	Key = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.5, Speed = 1.6 },
	Unlock = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 0.5, Speed = 1.4 },
	Paradox = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 0.8, Speed = 0.5 },
	Win = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.8, Speed = 0.9 },
	Tick = { Id = "rbxasset://sounds/clickfast.wav", Volume = 0.25, Speed = 1 },
	Button = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.2, Speed = 0.8 },
}

return Config
