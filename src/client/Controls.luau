--[[
	Controls — клавиши и камера. Ходьба — стандартная (WASD / стик), прыжка нет.
	  R — ⟲ перемотка (закончить свою петлю здесь), Z / Backspace — ↶ отменить петлю,
	  H — подсказка. На телефоне те же действия — кнопки HUD справа снизу.
	Камера: при входе в уровень — сверху под углом, чтобы был виден весь уровень.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Controls = {}

Controls.onRewind = nil :: (() -> ())?
Controls.onUndo = nil :: (() -> ())?
Controls.onHint = nil :: (() -> ())?

local player = Players.LocalPlayer

local function bind(name: string, fn: () -> (), ...)
	ContextActionService:BindAction(name, function(_, state)
		if state == Enum.UserInputState.Begin then
			fn()
		end
		return Enum.ContextActionResult.Sink
	end, false, ...)
end

function Controls.build()
	bind("LoopRewind", function()
		if Controls.onRewind then
			Controls.onRewind()
		end
	end, Enum.KeyCode.R, Enum.KeyCode.ButtonX)
	bind("LoopUndo", function()
		if Controls.onUndo then
			Controls.onUndo()
		end
	end, Enum.KeyCode.Z, Enum.KeyCode.Backspace, Enum.KeyCode.ButtonY)
	bind("LoopHint", function()
		if Controls.onHint then
			Controls.onHint()
		end
	end, Enum.KeyCode.H)
	local function onChar(ch: Model)
		local hum = ch:WaitForChild("Humanoid", 10) :: Humanoid?
		if hum then
			hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		end
		task.defer(Controls.overview)
	end
	player.CharacterAdded:Connect(onChar)
	if player.Character then
		task.spawn(onChar, player.Character)
	end
end

-- Камера сверху-сбоку: отъехать подальше (MinZoom на кадр) и наклонить вниз
function Controls.overview()
	local cam = Workspace.CurrentCamera
	local ch = player.Character
	local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not cam or not root then
		return
	end
	local p = root.CFrame.Position
	cam.CFrame = CFrame.lookAt(p + Vector3.new(0, 44, 30), p)
	pcall(function()
		local min = player.CameraMinZoomDistance
		player.CameraMinZoomDistance = 52
		task.defer(function()
			player.CameraMinZoomDistance = min
		end)
	end)
end

return Controls
