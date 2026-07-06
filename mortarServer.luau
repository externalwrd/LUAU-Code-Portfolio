-- // Services
local CS = game:GetService("CollectionService")

-- // Idents
local mortarSystemFolder = game.ReplicatedStorage.MortarSystem
local mortarMovement = require(script.mortarMovement)
local mortarCharAnims = require(script.mortarCharAnims)

local fastCast = require(game.ReplicatedStorage.Resources.FastCastRedux)

-- // Instancing
local mortarShotsFolder = workspace:FindFirstChild("MortarShots") or Instance.new("Folder", workspace)
mortarShotsFolder.Name = "MortarShots"

-- // Constants
local MORTAR_VELOCITY = 300 -- Studs/s

-- // BridgeNet2
local bridgeNet = require(game.ReplicatedStorage.Resources.BridgeNet2)
local mortarBridge = bridgeNet.ReferenceBridge("MortarBridge")
local mortarReplicationBridge = bridgeNet.ReferenceBridge("MortarReplicationBridge")

-- // Values
local mortar_sm = {}
mortar_sm.mortars = {}
mortar_sm.mortars.__index = mortar_sm.mortars
mortar_sm.registeredMortars = {}

-- // Code
local function initializeMortars()
	-- || Loop Through Each Mortar
	for _, mortar : Model in pairs(CS:GetTagged("Mortar")) do
		mortar_sm.newMortar(mortar)
	end
	
	-- || On New Mortar Placed
	CS:GetInstanceAddedSignal("Mortar"):Connect(mortar_sm.newMortar)
end

function mortar_sm.newMortar(mortarModel : Model)
	-- || Values
	local self = setmetatable({}, mortar_sm.mortars)
	table.insert(mortar_sm.registeredMortars, self)
	
	self.mortarModel = mortarModel
	self.mortarSeat = mortarModel.GunnerySeat
	
	-- || Instancing
	self.mortarTraverseValue = Instance.new("NumberValue", self.mortarSeat) self.mortarTraverseValue.Name = "MortarTraverse"
	self.mortarElevationValue = Instance.new("NumberValue", self.mortarSeat) self.mortarElevationValue.Name = "MortarElevation"
	self.hitPredictionValue = Instance.new("Vector3Value", self.mortarSeat) self.hitPredictionValue.Name = "HitPrediction"
	self.roundLoadedValue = Instance.new("BoolValue", self.mortarSeat) self.roundLoadedValue.Name = "RoundLoaded"
	
	-- || Connections
	self.mortarSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
		if self.mortarSeat.Occupant ~= nil then
			-- || New User
			self.mortarUser = game.Players:GetPlayerFromCharacter(self.mortarSeat.Occupant.Parent)
			self.mortarCharacter = self.mortarSeat.Occupant.Parent
			self.mainLoopOn = true
			
			-- || Initializing
			task.delay(0.5,function() mortarCharAnims.setAnimation(self, "MortarIdle", true) end)
			self:LoadMortar()
			
			-- || Sending Bridge
			mortarBridge:Fire(self.mortarUser,{
				true,
				self.mortarSeat
			})
		else
			-- || Sending Bridge
			mortarBridge:Fire(self.mortarUser,{
				false
			})
			
			-- || Functions
			mortarCharAnims.deloadAnimations(self)
			
			-- || User Removed
			self.mortarUser = nil
			self.mortarCharacter = nil
			self.mainLoopOn = false
			self.roundLoadedValue.Value = false
		end
	end)
	
	task.spawn(function()
		while self.mortarModel and self.mortarModel.Parent ~= nil do
			-- || Updating Check
			if self.mainLoopOn == true then
				-- || Function Calling
				mortarMovement.updateMovement(self)

				-- || Hit Prediction
				self.hitPredictionValue.Value = require(script.getMortarLandingPosition)(
					MORTAR_VELOCITY, 
					self.mortarModel.Muzzle.CFrame
				)
			end

			-- || Refresh Time
			task.wait()
		end
	end)
	
	-- || Fast Cast
	self.caster = fastCast.new()
	self.castBehaviour = fastCast.newBehavior()
	
	self.castBehaviour.Acceleration = Vector3.new(0, -workspace.Gravity, 0)
	self.castBehaviour.AutoIgnoreContainer = true
	self.castBehaviour.MaxDistance = 2000
	
	self.castBehaviour.CosmeticBulletContainer = mortarShotsFolder
	self.castBehaviour.CosmeticBulletTemplate = mortarSystemFolder.Assets.Projectile
	
	-- || Controlling Caster Hits
	self.caster.RayHit:Connect(function(cast, result : RaycastResult, velocity, cosmeticBullet : BasePart)
		-- || Removing Mortar Shot
		cosmeticBullet:Destroy()
		
		-- || Reloading
		self:LoadMortar()
		
		-- || Explosion
		require(game.ReplicatedStorage.ViewmodelEngine.viewmodelServer_sm.sendingThrowables.onThrowableExploded)(
			self.mortarUser, 
			{
				["explosionSettings"] = {
					explosionType = "Explosive",
					explosionParticle = game.ReplicatedStorage.ViewmodelEngine.Assets.Explosions.MortarExplosion,

					explosionSound = "rbxassetid://4474833664",
					explosionSoundMaxDistance = 1000,
					explosionSoundMaxVolume = 5,

					ragdolledLenght = 2,
					radius = 25,
					shrapnelDamage = 50,
					explosionFlingVelocity = 5 -- || * mass
				}
			},
			result.Position
		)
	end)
	
	-- || Placing Mortarshot
	self.caster.LengthChanged:Connect(function(cast, lastPoint : Vector3, rayDirection : Vector3, lenght : number, segmentVelocity : Vector3, cosmeticBullet : BasePart)
		if cosmeticBullet then
			if not cosmeticBullet:HasTag("FlyingMissile") then
				cosmeticBullet:AddTag("FlyingMissile")
				
				cosmeticBullet.Flying:Play()
				cosmeticBullet.Whizz:Play()
			end
			
			local cosmeticBulletLenght = cosmeticBullet.Size.Z/2
			local offset = CFrame.new(0,0, -(lenght - cosmeticBulletLenght))
			cosmeticBullet.CFrame = CFrame.lookAt(lastPoint, lastPoint + rayDirection):ToWorldSpace(offset) * CFrame.Angles(math.rad(-90),0,0)
		end
	end)
	
	return self
end

function mortar_sm.mortars:LoadMortar()
	require(script.loadMortarShot)(self)
end

function mortar_sm.mortars:FireMortar()
	-- || Pre-Fire Checks
	local function preFiringChecks()
		if self.roundLoadedValue.Value == false then
			return false
		end
	end
	if preFiringChecks() == false then return end
	
	-- || Functions
	local function getCharactersFromPlayers()
		local tab = {}
		for _, plr : Player in pairs(game.Players:GetPlayers()) do
			if plr.Character then
				table.insert(tab, plr.Character)
			end
		end
		
		return unpack(tab)
	end
	
	-- || Value Placing
	self.roundLoadedValue.Value = false
	
	-- || Cast Params
	local castParams = RaycastParams.new()
	castParams.IgnoreWater = false
	castParams.FilterType = Enum.RaycastFilterType.Exclude
	castParams.FilterDescendantsInstances = {self.mortarModel, getCharactersFromPlayers()}
	self.castBehaviour.RaycastParams = castParams
	
	-- || Fire Caster
	local castFired = self.caster:Fire(
		self.mortarModel.Muzzle.Position,
		self.mortarModel.Muzzle.CFrame.LookVector,
		MORTAR_VELOCITY,
		self.castBehaviour
	)
	
	-- || Fire Animation
	mortarCharAnims.setAnimation(self, "MortarFire", true)
	
	-- || Fire Effects
	for _, effect : Object in pairs(self.mortarModel:GetDescendants()) do
		if effect:IsA("ParticleEmitter") then
			effect:Emit(effect.Rate)
		end
		
		if effect:IsA("PointLight") or effect:IsA("SpotLight") then
			effect.Enabled = true
			task.delay(0.5,function() effect.Enabled = false end)
		end
	end
	
	-- || Replication Bridge
	mortarReplicationBridge:Fire(bridgeNet.AllPlayers(),{
		"Fire",
		self.mortarModel
	})
end

local function listenToBridge()
	-- || Functions
	local function getRegisteredMortarPlayer(sender : Player)
		for _, mortarSelf in pairs(mortar_sm.registeredMortars) do
			if mortarSelf.mortarUser == sender then
				return mortarSelf
			end
		end
	end
	
	-- || Bridge
	mortarBridge:Connect(function(sender, packedData)
		local registeredMortar = getRegisteredMortarPlayer(sender)
		
		if registeredMortar then
			registeredMortar:FireMortar()
		end
	end)
end

function mortar_sm.initializeServerScript()
	initializeMortars()
	listenToBridge()
end

return mortar_sm
