-- // Code

-- // Idents
local plr = game.Players.LocalPlayer

-- // Code
local wobble = {}
wobble.ORIGINAL_BREATH_WAVELENGHT = 0.025

function wobble.onRenderStep(self)
	-- || Constants
	self.BREATH_SPEED = self.BREATH_SPEED or 1
	self.BREATH_WAVELENGHT = self.BREATH_WAVELENGHT or wobble.ORIGINAL_BREATH_WAVELENGHT
	
	-- || Tick Values
	self.waveTime = (self.waveTime or 0) + self.dt
	
	-- || CFrames
	self.shakingCF = self.shakingCF or CFrame.new()
	local breathCF = CFrame.new()
	
	-- || Main Logic
	if self.humanoid.Health <= 50 then
		self.shakingCF = self.shakingCF:Lerp(
			CFrame.new(
				(math.random(-10,10)/100),
				(math.random(-10,10)/100),
				(math.random(-10,10)/100)
			), 0.05 *self.dt*60)
	else
		self.shakingCF = self.shakingCF:Lerp(CFrame.new(), 0.05 * self.dt*60)
	end
	
	-- || Functions
	local function nonFocusStrenght()
		breathCF = CFrame.new(
			0,
			math.cos(self.waveTime * (self.BREATH_SPEED * (self.humanoid.MaxHealth/self.humanoid.Health))) * self.BREATH_WAVELENGHT,
			0
		)
	end
	
	if self.aimFocusStrenght then
		if self.aimFocusStrenght <= 0.1 then
			nonFocusStrenght()
		else
			breathCF = CFrame.new(
				0,
				math.cos(self.waveTime * (self.BREATH_SPEED * (self.humanoid.MaxHealth/self.humanoid.Health))) * (self.BREATH_WAVELENGHT * self.aimFocusStrenght),
				0
			)
		end
	else
		nonFocusStrenght()
	end
	
	self.viewmodelEffectsCF *= breathCF * self.shakingCF
end

return wobble
