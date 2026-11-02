--[[
	Hud — интерфейс петли.
	  Сверху: «ПЕТЛЯ 2 / 4», цветные точки петель (цвет = призрак), шкала времени петли
	          с метками событий призраков (🔑, ■ конец записи, двери по предсказанию), остаток.
	  Слева сверху: уровень и звёзды, сколько «тебя» нужно, монеты, кнопки
	          Уровни / Магазин / Вместе / Позвать друзей.
	  Справа снизу: большая ⟲ ПЕРЕМОТКА (R), ↶ Отменить (Z), ↺ Заново, 💡 Подсказка (H).
	  Окна: победа (звёзды, монеты, «Дальше»), «петли кончились» (отсчёт, +1 петля),
	        уровни (главы, звёзды), «Вместе» (забеги с местами), обучение на первых уровнях.
	Каждая группа — свой масштабируемый контейнер (HUD не меньше 0.75), окна вписаны в экран.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Campaign = require(Shared.Campaign)
local Config = require(Shared.Config)
local Profile = require(Shared.Profile)

local Ui = require(script.Parent.Ui)
local Lang = require(script.Parent.Lang)
local Ghosts = require(script.Parent.Ghosts)

local Make = Ui.Make
local C = Ui.colors

local Hud = {}

Hud.onRewind = nil :: (() -> ())?
Hud.onUndo = nil :: (() -> ())?
Hud.onRestart = nil :: (() -> ())?
Hud.onHint = nil :: (() -> ())?
Hud.onPlay = nil :: ((number) -> ())?
Hud.onShop = nil :: ((string?) -> ())?
Hud.onCoop = nil :: (() -> ())?
Hud.onJoin = nil :: ((number) -> ())?
Hud.onSolo = nil :: (() -> ())?
Hud.onInvite = nil :: (() -> ())?
Hud.onAdvance = nil :: ((boolean) -> ())?
Hud.onExtra = nil :: (() -> ())?

local player = Players.LocalPlayer
local refs: { [string]: any } = {}
local info = {
	n = 1,
	k = 2,
	loop = 1,
	total = 2,
	stars = "",
	coins = 0,
	passes = {},
	done = false,
	phase = "idle",
	outDeadline = 0,
	winAt = 0,
	winPause = Config.Loop.WinPause,
	tipSeen = {},
}
Hud.info = info

local toasts: { { label: TextLabel, t: number } } = {}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function call(fn, ...)
	if fn then
		fn(...)
	end
end

local function starsText(n: number): string
	return string.rep("★", n) .. string.rep("☆", 3 - n)
end

-------------------------------------------------------------------------------
-- Построение
-------------------------------------------------------------------------------
local function buildTop(root: ScreenGui)
	local top = Ui.scaled(
		Make("Frame", {
			Name = "Top",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 8),
			Size = UDim2.fromOffset(560, 92),
			BackgroundTransparency = 1,
			Parent = root,
		}),
		0.75
	)
	local bar = Ui.panel({ Name = "Bar", Size = UDim2.new(1, 0, 0, 74), Parent = top })
	refs.loopLabel = Ui.label({
		Name = "Loop",
		Position = UDim2.fromOffset(14, 4),
		Size = UDim2.fromOffset(220, 32),
		TextSize = 26,
		Font = Ui.fontBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = bar,
	})
	refs.dots = Make("Frame", {
		Name = "Dots",
		Position = UDim2.fromOffset(236, 10),
		Size = UDim2.fromOffset(220, 20),
		BackgroundTransparency = 1,
		Parent = bar,
	})
	refs.timeLeft = Ui.label({
		Name = "TimeLeft",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 4),
		Size = UDim2.fromOffset(90, 32),
		TextSize = 26,
		Font = Ui.fontBold,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
		Parent = bar,
	})
	local line = Make("Frame", {
		Name = "Timeline",
		Position = UDim2.fromOffset(14, 44),
		Size = UDim2.new(1, -28, 0, 14),
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
		Parent = bar,
	})
	Make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = line })
	refs.timeline = line
	refs.fill = Make("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = C.rewind,
		BorderSizePixel = 0,
		Parent = line,
	})
	Make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = refs.fill })
	refs.marks = Make("Frame", {
		Name = "Marks",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = line,
	})
	refs.toastBox = Make("Frame", {
		Name = "Toasts",
		Position = UDim2.fromOffset(0, 80),
		Size = UDim2.fromScale(1, 0),
		BackgroundTransparency = 1,
		Parent = top,
	})
	refs.top = top
end

local function smallButton(parent, name: string, text: string, x: number, y: number, w: number, fn)
	local b = Ui.button({
		Name = name,
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(w, 34),
		TextSize = 16,
		Text = text,
		Parent = parent,
	})
	b.Activated:Connect(fn)
	return b
end

local function buildInfo(root: ScreenGui)
	local box = Ui.scaled(
		Make("Frame", {
			Name = "Info",
			Position = UDim2.fromOffset(12, 52),
			Size = UDim2.fromOffset(270, 160),
			BackgroundTransparency = 1,
			Parent = root,
		}),
		0.75
	)
	local p = Ui.panel({ Name = "Panel", Size = UDim2.fromOffset(270, 84), Parent = box })
	refs.levelLabel = Ui.label({
		Name = "Level",
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.fromOffset(250, 26),
		TextSize = 21,
		Font = Ui.fontBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = p,
	})
	refs.needLabel = Ui.label({
		Name = "Need",
		Position = UDim2.fromOffset(12, 32),
		Size = UDim2.fromOffset(250, 20),
		TextSize = 16,
		TextColor3 = C.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = p,
	})
	refs.coins = Ui.label({
		Name = "Coins",
		Position = UDim2.fromOffset(12, 54),
		Size = UDim2.fromOffset(250, 24),
		TextSize = 19,
		Font = Ui.fontBold,
		TextColor3 = C.gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "● 0",
		Parent = p,
	})
	refs.levelsBtn = smallButton(box, "LevelsButton", "", 0, 90, 84, function()
		Hud.openLevels()
	end)
	refs.shopBtn = smallButton(box, "ShopButton", "", 90, 90, 84, function()
		call(Hud.onShop, nil)
	end)
	refs.coopBtn = smallButton(box, "CoopButton", "", 180, 90, 90, function()
		call(Hud.onCoop)
	end)
	refs.inviteBtn = smallButton(box, "InviteButton", "", 0, 126, 270, function()
		call(Hud.onInvite)
	end)
	refs.inviteBtn.BackgroundColor3 = Color3.fromRGB(40, 110, 80)
	refs.info = box
end

local function buildActions(root: ScreenGui)
	local box = Ui.scaled(
		Make("Frame", {
			Name = "Actions",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -16, 1, -16),
			Size = UDim2.fromOffset(220, 230),
			BackgroundTransparency = 1,
			Parent = root,
		}),
		0.75
	)
	local rw = Ui.button({
		Name = "Rewind",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.fromOffset(220, 96),
		BackgroundColor3 = C.rewind,
		TextSize = 28,
		Text = "",
		Parent = box,
	})
	Ui.stroke(rw, Color3.fromRGB(200, 190, 255), 2)
	refs.rewindKey = Ui.label({
		Name = "Key",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -6),
		Size = UDim2.new(1, -10, 0, 18),
		TextSize = 13,
		TextColor3 = Color3.fromRGB(220, 215, 255),
		Text = "",
		Parent = rw,
	})
	rw.Activated:Connect(function()
		call(Hud.onRewind)
	end)
	refs.rewind = rw
	local undo = Ui.button({
		Name = "Undo",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, -104),
		Size = UDim2.fromOffset(220, 40),
		TextSize = 18,
		Text = "",
		Parent = box,
	})
	undo.Activated:Connect(function()
		call(Hud.onUndo)
	end)
	refs.undo = undo
	local restart = Ui.button({
		Name = "Restart",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, -150),
		Size = UDim2.fromOffset(106, 36),
		TextSize = 15,
		Text = "",
		Parent = box,
	})
	restart.Activated:Connect(function()
		call(Hud.onRestart)
	end)
	refs.restart = restart
	local hint = Ui.button({
		Name = "Hint",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -114, 1, -150),
		Size = UDim2.fromOffset(106, 36),
		TextSize = 15,
		BackgroundColor3 = Color3.fromRGB(110, 90, 30),
		Text = "",
		Parent = box,
	})
	hint.Activated:Connect(function()
		call(Hud.onHint)
	end)
	refs.hint = hint
	refs.actions = box
end

local function modal(root: ScreenGui, name: string, w: number, h: number)
	local f = Ui.scaled(
		Ui.panel({
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(w, h),
			BackgroundTransparency = 0.05,
			Visible = false,
			ZIndex = 6,
			Parent = root,
		}),
		0.5
	)
	Ui.stroke(f, C.rewind, 2)
	return f
end

local function buildPanels(root: ScreenGui)
	-- центр: крупное сообщение
	refs.center = Ui.scaled(
		Ui.label({
			Name = "Center",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.3),
			Size = UDim2.fromOffset(700, 70),
			TextSize = 46,
			Font = Ui.fontBold,
			Text = "",
			TextTransparency = 1,
			TextStrokeTransparency = 1,
			Parent = root,
		}),
		0.6
	)
	refs.centerT = 0
	-- обучение
	refs.tip = Ui.scaled(
		Ui.panel({
			Name = "Tip",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 108),
			Size = UDim2.fromOffset(560, 62),
			BackgroundColor3 = Color3.fromRGB(30, 26, 70),
			Visible = false,
			Parent = root,
		}),
		0.75
	)
	refs.tipText = Ui.label({
		Name = "Text",
		Position = UDim2.fromOffset(12, 4),
		Size = UDim2.new(1, -56, 1, -8),
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = refs.tip,
	})
	local tipClose = Ui.button({
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(36, 36),
		Text = "✕",
		Parent = refs.tip,
	})
	tipClose.Activated:Connect(function()
		refs.tip.Visible = false
	end)

	-- победа
	local win = modal(root, "Win", 440, 300)
	refs.win = win
	refs.winTitle = Ui.label({
		Name = "Title",
		Position = UDim2.fromOffset(0, 12),
		Size = UDim2.new(1, 0, 0, 40),
		TextSize = 32,
		Font = Ui.fontBold,
		TextColor3 = C.gold,
		Text = "",
		Parent = win,
	})
	refs.winStars = Ui.label({
		Name = "Stars",
		Position = UDim2.fromOffset(0, 56),
		Size = UDim2.new(1, 0, 0, 50),
		TextSize = 46,
		TextColor3 = C.gold,
		Text = "",
		Parent = win,
	})
	refs.winBody = Ui.label({
		Name = "Body",
		Position = UDim2.fromOffset(20, 110),
		Size = UDim2.new(1, -40, 0, 104),
		TextSize = 18,
		Text = "",
		Parent = win,
	})
	refs.winNext = Ui.button({
		Name = "Next",
		Position = UDim2.new(0.5, 6, 1, -58),
		Size = UDim2.new(0.5, -26, 0, 44),
		BackgroundColor3 = C.robux,
		TextSize = 20,
		Text = "",
		Parent = win,
	})
	refs.winNext.Activated:Connect(function()
		win.Visible = false
		call(Hud.onAdvance, false)
	end)
	refs.winAgain = Ui.button({
		Name = "Again",
		Position = UDim2.new(0, 20, 1, -58),
		Size = UDim2.new(0.5, -26, 0, 44),
		TextSize = 20,
		Text = "",
		Parent = win,
	})
	refs.winAgain.Activated:Connect(function()
		win.Visible = false
		call(Hud.onAdvance, true)
	end)

	-- петли кончились
	local out = modal(root, "Out", 460, 250)
	refs.out = out
	refs.outTitle = Ui.label({
		Name = "Title",
		Position = UDim2.fromOffset(0, 12),
		Size = UDim2.new(1, 0, 0, 36),
		TextSize = 28,
		Font = Ui.fontBold,
		TextColor3 = C.warn,
		Text = "",
		Parent = out,
	})
	refs.outBody = Ui.label({
		Name = "Body",
		Position = UDim2.fromOffset(20, 52),
		Size = UDim2.new(1, -40, 0, 70),
		TextSize = 17,
		Text = "",
		Parent = out,
	})
	refs.outTimer = Ui.label({
		Name = "Timer",
		Position = UDim2.fromOffset(0, 124),
		Size = UDim2.new(1, 0, 0, 24),
		TextSize = 16,
		TextColor3 = C.dim,
		Text = "",
		Parent = out,
	})
	refs.outExtra = Ui.button({
		Name = "Extra",
		Position = UDim2.new(0.5, 6, 1, -60),
		Size = UDim2.new(0.5, -26, 0, 46),
		BackgroundColor3 = C.robux,
		TextSize = 19,
		Text = "",
		Parent = out,
	})
	refs.outExtra.Activated:Connect(function()
		call(Hud.onExtra)
	end)
	refs.outUndo = Ui.button({
		Name = "UndoNow",
		Position = UDim2.new(0, 20, 1, -60),
		Size = UDim2.new(0.5, -26, 0, 46),
		TextSize = 19,
		Text = "",
		Parent = out,
	})
	refs.outUndo.Activated:Connect(function()
		out.Visible = false
		call(Hud.onUndo)
	end)

	-- уровни
	local lv = modal(root, "Levels", 720, 520)
	refs.levels = lv
	Ui.label({
		Name = "Title",
		Position = UDim2.fromOffset(16, 10),
		Size = UDim2.new(1, -80, 0, 36),
		TextSize = 26,
		Font = Ui.fontBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = lv,
	})
	local lvClose = Ui.button({
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 10),
		Size = UDim2.fromOffset(44, 40),
		BackgroundColor3 = Color3.fromRGB(110, 50, 44),
		Text = "✕",
		Parent = lv,
	})
	lvClose.Activated:Connect(function()
		lv.Visible = false
	end)
	refs.levelsBody = Make("ScrollingFrame", {
		Name = "Body",
		Position = UDim2.fromOffset(14, 58),
		Size = UDim2.new(1, -28, 1, -70),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = lv,
	})

	-- вместе
	local co = modal(root, "Coop", 520, 420)
	refs.coop = co
	Ui.label({
		Name = "Title",
		Position = UDim2.fromOffset(16, 10),
		Size = UDim2.new(1, -80, 0, 34),
		TextSize = 24,
		Font = Ui.fontBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = co,
	})
	Ui.label({
		Name = "Desc",
		Position = UDim2.fromOffset(16, 46),
		Size = UDim2.new(1, -32, 0, 40),
		TextSize = 15,
		TextColor3 = C.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = co,
	})
	local coClose = Ui.button({
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 10),
		Size = UDim2.fromOffset(44, 40),
		BackgroundColor3 = Color3.fromRGB(110, 50, 44),
		Text = "✕",
		Parent = co,
	})
	coClose.Activated:Connect(function()
		co.Visible = false
	end)
	refs.coopBody = Make("ScrollingFrame", {
		Name = "Body",
		Position = UDim2.fromOffset(14, 92),
		Size = UDim2.new(1, -28, 1, -150),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = co,
	})
	refs.coopSolo = Ui.button({
		Name = "Solo",
		Position = UDim2.new(0, 14, 1, -50),
		Size = UDim2.new(0.5, -20, 0, 38),
		Text = "",
		Parent = co,
	})
	refs.coopSolo.Activated:Connect(function()
		co.Visible = false
		call(Hud.onSolo)
	end)
	refs.coopInvite = Ui.button({
		Name = "Invite",
		Position = UDim2.new(0.5, 6, 1, -50),
		Size = UDim2.new(0.5, -20, 0, 38),
		BackgroundColor3 = Color3.fromRGB(40, 110, 80),
		Text = "",
		Parent = co,
	})
	refs.coopInvite.Activated:Connect(function()
		call(Hud.onInvite)
	end)
end

local function relabel()
	refs.rewind.Text = Lang.t("ui.rewind")
	refs.rewindKey.Text = Lang.t("ui.rewindKey")
	refs.undo.Text = Lang.t("ui.undo")
	refs.restart.Text = Lang.t("ui.restart")
	local free = info.passes and info.passes.Oracle
	refs.hint.Text = if free
		then Lang.t("ui.hint")
		else Lang.t("ui.hint") .. " ● " .. Config.Rewards.HintCost
	refs.levelsBtn.Text = Lang.t("ui.levels")
	refs.shopBtn.Text = Lang.t("ui.shop")
	refs.coopBtn.Text = Lang.t("ui.coop")
	refs.inviteBtn.Text = Lang.t("ui.invite")
	refs.levels.Title.Text = Lang.t("levels.title")
	refs.coop.Title.Text = Lang.t("coop.title")
	refs.coop.Desc.Text = Lang.t("coop.desc")
	refs.coopSolo.Text = Lang.t("coop.leave")
	refs.coopInvite.Text = Lang.t("ui.invite")
	refs.winNext.Text = Lang.t("win.next")
	refs.winAgain.Text = Lang.t("win.again")
	refs.outTitle.Text = Lang.t("loop.out")
	refs.outBody.Text = Lang.t("loop.outHint")
	refs.outUndo.Text = Lang.t("ui.undo")
	Hud.refreshInfo()
end

function Hud.build()
	local root = Ui.screen()
	local hud = Make("Frame", {
		Name = "Hud",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = root,
	})
	buildTop(hud :: any)
	buildInfo(hud :: any)
	buildActions(hud :: any)
	buildPanels(root)
	refs.hud = hud
	relabel()
	Lang.onChange(relabel)
	Hud.layout()
	Ui.onViewport(Hud.layout)
end

--[[
	Раскладка под экран. Широкий: шкала петли по центру, инфо слева, кнопки справа снизу.
	Узкий (телефон, ширины не хватает на шкалу и инфо рядом): шкала прижата вправо,
	обучение — под ней справа; левый низ свободен для стика.
]]
function Hud.layout()
	local vp = Ui.viewport()
	local s = refs.top.UIScale.Scale
	local topW = 560 * s
	local infoW = 270 * refs.info.UIScale.Scale
	local narrow = (vp.X - topW) / 2 < infoW + 24
	if narrow then
		refs.top.AnchorPoint = Vector2.new(1, 0)
		refs.top.Position = UDim2.new(1, -12, 0, 8)
		refs.tip.AnchorPoint = Vector2.new(1, 0)
		refs.tip.Position = UDim2.new(1, -12, 0, 8 + 84 * s)
		refs.tip.Size = UDim2.fromOffset(math.min(560, (vp.X - infoW - 48) / refs.tip.UIScale.Scale), 74)
	else
		refs.top.AnchorPoint = Vector2.new(0.5, 0)
		refs.top.Position = UDim2.new(0.5, 0, 0, 8)
		refs.tip.AnchorPoint = Vector2.new(0.5, 0)
		refs.tip.Position = UDim2.new(0.5, 0, 0, 8 + 100 * s)
		refs.tip.Size = UDim2.fromOffset(560, 62)
	end
	refs.narrow = narrow
end

-------------------------------------------------------------------------------
-- Состояние
-------------------------------------------------------------------------------
function Hud.refreshInfo()
	local stars = Profile.starsOf({ stars = info.stars } :: any, info.n)
	refs.levelLabel.Text = Lang.t("ui.level", { n = info.n }) .. "  " .. starsText(stars)
	refs.needLabel.Text = Lang.t("ui.need", { k = info.k })
	refs.coins.Text = "● " .. tostring(info.coins)
end

function Hud.setProfile(p)
	info.coins = p.coins or 0
	info.stars = p.stars or ""
	info.passes = p.passes or {}
	info.saved = p.saved
	Ghosts.setOracle(info.passes.Oracle == true)
	relabel()
	if refs.levels.Visible then
		Hud.openLevels()
	end
end

function Hud.toast(text: string, color: Color3?)
	local l = Ui.label({
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.fromOffset(0, #toasts * 32),
		BackgroundColor3 = C.panel,
		BackgroundTransparency = 0.25,
		TextSize = 18,
		Font = Ui.fontBold,
		TextColor3 = color or C.text,
		Text = text,
		Parent = refs.toastBox,
	})
	Make("UICorner", { CornerRadius = UDim.new(0, 8), Parent = l })
	table.insert(toasts, { label = l, t = os.clock() })
	while #toasts > 3 do
		toasts[1].label:Destroy()
		table.remove(toasts, 1)
	end
	for i, tt in toasts do
		tt.label.Position = UDim2.fromOffset(0, (i - 1) * 32)
	end
end

function Hud.center(text: string, color: Color3?, secs: number?)
	refs.center.Text = text
	refs.center.TextColor3 = color or C.text
	refs.centerT = os.clock() + (secs or 1.6)
end

function Hud.setLevel(p)
	info.n = p.n
	info.k = p.k
	info.phase = "idle"
	refs.win.Visible = false
	refs.out.Visible = false
	Hud.refreshInfo()
	local key = Campaign.Tips[p.n]
	if key and not info.tipSeen[p.n] then
		info.tipSeen[p.n] = true
		refs.tipText.Text = Lang.t(key)
		refs.tip.Visible = true
	else
		refs.tip.Visible = false
	end
end

local function rebuildDots()
	for _, c in refs.dots:GetChildren() do
		c:Destroy()
	end
	local n = math.max(info.total, info.loop)
	for i = 1, n do
		local d = Make("Frame", {
			Name = "Dot" .. i,
			Position = UDim2.fromOffset((i - 1) * 24, 0),
			Size = UDim2.fromOffset(18, 18),
			BackgroundColor3 = if i < info.loop
				then Ui.loopColor(i)
				elseif i == info.loop then Ui.loopColor(i)
				else C.panel2,
			BackgroundTransparency = if i <= info.loop then 0 else 0.2,
			BorderSizePixel = 0,
			Parent = refs.dots,
		})
		Make("UICorner", { CornerRadius = UDim.new(1, 0), Parent = d })
		if i == info.loop then
			Ui.stroke(d, Color3.new(1, 1, 1), 2)
		end
	end
end

local function rebuildMarks()
	for _, c in refs.marks:GetChildren() do
		c:Destroy()
	end
	local L = Config.Loop.Length
	for i, m in Ghosts.timeline() do
		local x = math.clamp(m.t / L, 0, 1)
		Ui.label({
			Name = "Mark" .. i,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(x, 0.5),
			Size = UDim2.fromOffset(18, 18),
			TextSize = 14,
			Font = Ui.fontBold,
			TextColor3 = m.color,
			Text = m.glyph,
			Parent = refs.marks,
		})
	end
end

function Hud.startLoop(p)
	info.loop = p.loop
	info.total = p.total
	info.k = p.k
	info.phase = "play"
	info.done = p.spectator == true
	info.spectator = p.spectator == true
	refs.out.Visible = false
	refs.win.Visible = false
	refs.loopLabel.Text = Lang.t("ui.loop", { n = p.loop, total = p.total })
	refs.loopLabel.TextColor3 = Ui.loopColor(p.loop)
	rebuildDots()
	rebuildMarks()
	refs.rewind.BackgroundColor3 = C.rewind
	refs.rewind.AutoButtonColor = true
	if p.spectator then
		Hud.center(Lang.t("ui.waitNext"), C.dim, 3)
	elseif p.loop >= p.total then
		Hud.center(Lang.t("loop.last"), C.warn, 1.4)
	else
		Hud.center(Lang.t("loop.start", { n = p.loop }), Ui.loopColor(p.loop), 1.2)
	end
	Hud.refreshInfo()
end

function Hud.done()
	info.done = true
	refs.rewind.BackgroundColor3 = Color3.fromRGB(70, 70, 90)
	refs.rewind.AutoButtonColor = false
	Hud.center(Lang.t("ui.done"), C.dim, 2)
end

function Hud.rewind()
	info.phase = "rewind"
	Hud.center(Lang.t("loop.rewinding"), C.rewind, 1.1)
end

function Hud.paradox(e)
	local key = if e.reason == "key" then "loop.paradoxKey" else "loop.paradoxDoor"
	local g = Ghosts.state.ghosts[e.body]
	local loopNo = g and g.rec.loop or e.rec or 0
	Hud.center(Lang.t(key, { n = loopNo }), C.paradox, 2.4)
	Hud.toast(Lang.t("loop.paradoxHint"), C.paradox)
end

function Hud.showWin(p)
	info.phase = "won"
	info.winAt = os.clock()
	info.winPause = p.pause or Config.Loop.WinPause
	info.coins = info.coins
	refs.winTitle.Text = Lang.t("win.title")
	refs.winStars.Text = starsText(p.stars)
	local lines = {
		Lang.t("win.loops", { n = p.loops, k = p.needed }),
		Lang.t("win.coins", { n = p.coins }),
	}
	if p.stars >= 3 then
		table.insert(lines, Lang.t("win.perfect"))
	elseif p.stars == 2 then
		table.insert(lines, Lang.t("win.star2"))
	else
		table.insert(lines, Lang.t("win.star1"))
	end
	if not p.next then
		table.insert(lines, Lang.t("win.end"))
	end
	refs.winBody.Text = table.concat(lines, "\n")
	refs.winNext.Visible = p.next ~= nil
	refs.win.Visible = true
	refs.out.Visible = false
	Hud.center(Lang.t("win.title"), C.gold, 2.5)
end

function Hud.showOut(p)
	info.phase = "out"
	info.outDeadline = p.deadline
	info.outLoop = p.loop
	refs.outExtra.Visible = p.canExtra == true
	refs.outExtra.Text = Lang.t("loop.extra", { n = p.robux or Config.Products.ExtraLoop.robux })
	refs.out.Visible = true
end

function Hud.undone(p)
	refs.out.Visible = false
	Hud.toast(Lang.t("loop.undone", { n = p.loop }), C.warn)
end

function Hud.openLevels()
	local body = refs.levelsBody
	for _, c in body:GetChildren() do
		c:Destroy()
	end
	Make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = body })
	local d = { stars = info.stars } :: any
	local order = 0
	for _, ch in Campaign.Chapters do
		order += 1
		Ui.label({
			Name = "Chapter_" .. ch.first,
			LayoutOrder = order,
			Size = UDim2.new(1, -10, 0, 26),
			TextSize = 19,
			Font = Ui.fontBold,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = C.gold,
			Text = Lang.t(ch.key),
			Parent = body,
		})
		order += 1
		local grid = Make("Frame", {
			LayoutOrder = order,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -10, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = body,
		})
		Make("UIGridLayout", {
			CellSize = UDim2.fromOffset(104, 74),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = grid,
		})
		for n = ch.first, ch.last do
			local open = Profile.unlocked(d, n)
			local s = Profile.starsOf(d, n)
			local b = Ui.button({
				Name = "L" .. n,
				LayoutOrder = n,
				BackgroundColor3 = if n == info.n then C.rewind elseif open then C.button else C.panel2,
				AutoButtonColor = open,
				TextSize = 15,
				Text = if open
					then string.format(
						"<b>%d</b>\n%s\n%s",
						n,
						starsText(s),
						Lang.t("levels.need", { k = Campaign.Specs[n].k })
					)
					else tostring(n) .. "\n" .. Lang.t("levels.locked"),
				RichText = true,
				Parent = grid,
			})
			b.Activated:Connect(function()
				if open then
					refs.levels.Visible = false
					call(Hud.onPlay, n)
				end
			end)
		end
	end
	refs.levels.Visible = true
end

function Hud.showRuns(list, mine: number?)
	local body = refs.coopBody
	for _, c in body:GetChildren() do
		c:Destroy()
	end
	Make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = body })
	local shown = 0
	for i, r in list do
		if r.id ~= mine then
			shown += 1
			local row = Ui.panel({
				Name = "Run_" .. r.id,
				LayoutOrder = i,
				BackgroundColor3 = C.panel2,
				Size = UDim2.new(1, -10, 0, 48),
				Parent = body,
			})
			Ui.label({
				Position = UDim2.fromOffset(10, 0),
				Size = UDim2.new(1, -130, 1, 0),
				TextSize = 16,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = Lang.t("coop.entry", {
					name = table.concat(r.names, ", "),
					n = r.n,
					p = r.count,
					max = r.max,
				}),
				Parent = row,
			})
			local full = r.count >= r.max
			local b = Ui.button({
				Name = "Join",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -8, 0.5, 0),
				Size = UDim2.fromOffset(110, 36),
				BackgroundColor3 = if full then C.panel else C.robux,
				AutoButtonColor = not full,
				Text = if full then Lang.t("coop.full") else Lang.t("coop.join"),
				Parent = row,
			})
			b.Activated:Connect(function()
				if not full then
					refs.coop.Visible = false
					call(Hud.onJoin, r.id)
				end
			end)
		end
	end
	if shown == 0 then
		Ui.label({
			Name = "None",
			Size = UDim2.new(1, -10, 0, 60),
			TextSize = 17,
			TextColor3 = C.dim,
			Text = Lang.t("coop.none"),
			Parent = body,
		})
	end
	refs.coop.Visible = true
end

function Hud.isModalOpen(): boolean
	return refs.levels.Visible or refs.coop.Visible or refs.win.Visible or refs.out.Visible
end

-------------------------------------------------------------------------------
-- Кадр
-------------------------------------------------------------------------------
local lastTick = -1
Hud.onTick = nil :: ((number) -> ())?

function Hud.update(_dt: number)
	local L = Config.Loop.Length
	local t = Ghosts.loopTime()
	if info.phase == "play" then
		refs.fill.Size = UDim2.fromScale(math.clamp(t / L, 0, 1), 1)
		local left = math.max(0, L - t)
		refs.timeLeft.Text = string.format("%.1f", left)
		refs.timeLeft.TextColor3 = if left < 3 then C.warn else C.text
		local sec = math.ceil(left)
		if left < 3.5 and sec ~= lastTick and sec > 0 then
			lastTick = sec
			call(Hud.onTick, sec)
		end
	elseif info.phase == "rewind" then
		local f = refs.fill.Size.X.Scale
		refs.fill.Size = UDim2.fromScale(math.max(0, f - _dt / Config.Loop.Rewind), 1)
	end
	if info.phase == "out" then
		local left = math.max(0, info.outDeadline - now())
		refs.outTimer.Text =
			Lang.t("loop.outAuto", { n = info.outLoop or 0, t = string.format("%.0f", left) })
	end
	if refs.win.Visible and info.phase == "won" then
		local left = math.max(0, info.winPause - (os.clock() - info.winAt))
		refs.winNext.Text = Lang.t("win.next") .. string.format(" (%.0f)", left)
	end
	-- центр: плавное исчезание
	local ct = refs.centerT - os.clock()
	local a = if ct > 0.4 then 0 elseif ct > 0 then 1 - ct / 0.4 else 1
	refs.center.TextTransparency = a
	refs.center.TextStrokeTransparency = math.max(a, 0.4)
	-- тосты живут 3 с
	for i = #toasts, 1, -1 do
		if os.clock() - toasts[i].t > 3 then
			toasts[i].label:Destroy()
			table.remove(toasts, i)
		end
	end
	local _ = player
end

return Hud
