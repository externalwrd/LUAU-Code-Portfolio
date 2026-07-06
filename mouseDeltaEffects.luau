-- // Services
local UIS = game:GetService("UserInputService")

-- // Idents
local plr = game.Players.LocalPlayer
local cam = workspace.CurrentCamera
local mouse = plr:GetMouse()

local viewmodelEngineFolder = game.ReplicatedStorage.ViewmodelEngine

-- // Requieries
local springModule = require(game.ReplicatedStorage.Resources.SpringModule)

-- // Code
local mouseDeltaEffects = {}

local function mouseDeltaArmPositionOffsetFX(self)
	-- || Lerp values
	local osX, osY, osZ = self.effectSwayCF:ToEulerAnglesXYZ()
	
	self.armsOriY = math.clamp(
		(-self.mdX * 2),
		-5, 10
	) * self.swayMultiplier
	
	self.armsOriX = math.clamp(
		(-self.mdY * 1),
		-5, 5
	) * self.swayMultiplier
	
	self.armsPosX = math.clamp(
		(-self.mdX / 20),
		-0.2, 0.4
	) * self.swayMultiplier
	
	self.armsPosY = math.clamp(
		(self.armsPosY or 0) + osX / 2,
		-10, 10
	) * self.swayMultiplier
	
	self.armsPosZ = math.clamp(
		osY / 10,
		-0.5, 0.5
	) * self.swayMultiplier

	-- || Lerps
	self.effectSwayCF = self.effectSwayCF:Lerp(
		CFrame.new(self.armsPosX,0,self.armsPosZ) * CFrame.Angles(math.rad(self.armsOriX), math.rad(self.armsOriY),0)
		, 0.1 *self.dt*60
	)
	
	-- || Final Positioning
	self.viewmodelEffectsCF *= self.effectSwayCF
end

function mouseDeltaEffects.onRenderStep(self)
	-- || Defining Values
	if not UIS.GamepadEnabled then
		self.mouseDelta = UIS:GetMouseDelta()
	end
	
	self.mdX = self.mouseDelta.X / (self.dt * 60)
	self.mdY = self.mouseDelta.Y / (self.dt * 60)
	
	-- || Calling Effects
	mouseDeltaArmPositionOffsetFX(self)
end

return mouseDeltaEffects
