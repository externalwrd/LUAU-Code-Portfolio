-- Made by Avia_player (Roblox) | externalwrd (Discord)

-- // Services
local RS = game:GetService("RunService")
local CAS = game:GetService("ContextActionService")
local CP = game:GetService("ContentProvider")
local UIS = game:GetService("UserInputService")
local CS = game:GetService("CollectionService")

-- // Idents
local plr = game.Players.LocalPlayer
local cam = workspace.CurrentCamera

local viewmodelValuesFolder 
local isAimingValue 
local isFiringValue

local movementFolder = plr:WaitForChild("MovementValues")

local viewmodelEngineFolder = game.ReplicatedStorage.ViewmodelEngine

-- // Requireies
local bridgeNet2Module = require(game.ReplicatedStorage.Resources.BridgeNet2)
local aimingFocusModule = require(script.aimingFocus)
local globalSettings = require(game.ReplicatedStorage.GlobalSettings)

-- // Values
local viewmodelClient = {}
viewmodelClient.viewmodelTools = {}
viewmodelClient.viewmodelTools.__index = viewmodelClient.viewmodelTools

viewmodelClient.currentEquippedSelf = nil
viewmodelClient.canEquippTool = true

-- // Code

local function preEquippingChecks(self)
	if plr.Character then
		if plr.Character:WaitForChild("Humanoid").Health > 0 then
			if viewmodelClient.canEquippTool == true then
				
			else
				return false
			end
		else
			return false
		end
	else
		return false
	end
end

function viewmodelClient.viewmodelTools:Equip()
	-- || Equpping Checks
	if preEquippingChecks(self) == false then return end
	
	-- || Editing Values
	self.springs = {}
	
	self.viewmodelEffectsCF = CFrame.new()
	
	self.aimingFOV = globalSettings.defaultFOV
	self.aimingOffset = CFrame.new()
	self.effectSwayCF = CFrame.new()
	self.cameraEffectsCF = CFrame.new()
	
	self.swayMultiplier = 1
	self.bobbleSpeed = 8
	self.bobbleAmount = 0.02
	
	self.mouseDelta = Vector2.new(0,0)
	
	self.aiming = false
	self.Equipped = true
	
	self.humanoid = plr.Character.Humanoid
	self.humRootPart = plr.Character.HumanoidRootPart
	
	viewmodelClient.currentEquippedSelf = self
	
	--plr.CameraMode = Enum.CameraMode.LockFirstPerson
	UIS.MouseIconEnabled = false
	
	-- || Requiring Handling Modules
	require(script.viewmodelArms).onToolEquipped(self)
	require(script.weaponHUD).newHudUI(self)
	require(script.weaponJamming).weaponJammedUI(self)
	require(script.grenades).onEquip(self)
	require(script.firemodeSelect).updateFiremodeText(self)
	
	if self.toolSettings.muzzlePointerVisible ~= false then
		self.muzzlePointerCon = require(script.muzzlePointer).startPointer(self.toolModel.Handle.Firepoint, self.hudUI)
		table.insert(self.equippingCache, self.muzzlePointerCon)
	end
	
	-- || Replicating Idle Animation
	self.bridgesList.AnimationReplicate:Fire({
		true, 
		viewmodelEngineFolder.Assets.ToolSettings[self.toolName].Animations.IdleR6,
		Enum.AnimationPriority.Idle,
		self.toolName
	})
	
	-- || Custom Scenarios
	if self.toolSettings.customScenarios ~= nil then
		if self.toolSettings.customScenarios.onEquipp ~= nil then
			task.spawn(function()
				self.toolSettings.customScenarios.onEquipp()
			end)
		end
	end
	
	-- || Updating Every Frame
	local renderStepCon = RS.RenderStepped:Connect(function(dt)
		-- || Placing Values
		self.dt = dt
		self.viewmodelEffectsCF = CFrame.new()
		self.cameraEffectsCF = CFrame.new()
		
		-- || Updating Springs
		for springName, spring in pairs(self.springs) do
			self["updated_"..springName] = spring.update(spring,dt)
		end
		
		-- || Requiring Rendering Modules
		aimingFocusModule.onRender(self)
		require(script.viewmodelArms).onRenderStepped(self)
		
		-- || Placing Camera Value
		cam.CFrame *= self.cameraEffectsCF
	end)
	table.insert(self.equippingCache, renderStepCon)
	
	-- || Input Handling
	local inpBeganCon = UIS.InputBegan:Connect(function(input, gameProccessed)
		-- || Calling functions from framework
		for _, module : Object in pairs(script:GetDescendants()) do
			if module:IsA("ModuleScript") then
				local reqModule = require(module)
				
				local succ, errMsg = pcall(function()
					if reqModule.onInputBegan ~= nil then
						reqModule.onInputBegan(self, input, gameProccessed)
					end
				end)
			end
		end
		
		-- || Custom Scenarios
		if self.toolSettings.customScenarios ~= nil then
			if self.toolSettings.customScenarios.onInputBegan ~= nil then
				self.toolSettings.customScenarios.onInputBegan(input, gameProccessed, self)
			end
		end
	end)
	table.insert(self.equippingCache, inpBeganCon)
	
	local inpChangedCon = UIS.InputChanged:Connect(function(input, gameProccessed)
		-- || Console Values
		if input.KeyCode == Enum.KeyCode.Thumbstick2 and UIS.GamepadEnabled == true then
			self.mouseDelta = input.Position * 2
		end
	end)
	table.insert(self.equippingCache, inpChangedCon)
	
	local inpEndCon = UIS.InputEnded:Connect(function(input, gameProccessed)
		-- || Calling functions from framework
		for _, module : Object in pairs(script:GetDescendants()) do
			if module:IsA("ModuleScript") then
				local reqModule = require(module)

				pcall(function()
					if reqModule.onInputEnded ~= nil then
						reqModule.onInputEnded(self, input, gameProccessed)
					end
				end)
			end
		end
	end)
	table.insert(self.equippingCache, inpEndCon)
	
	local deathCon = self.humanoid.Died:Once(function()
		-- || Calling functions from framework
		for _, module : Object in pairs(script:GetDescendants()) do
			if module:IsA("ModuleScript") then
				local reqModule = require(module)

				pcall(function()
					if reqModule.onDeath ~= nil then
						reqModule.onDeath(self)
					end
				end)
			end
		end
	end)
	table.insert(self.equippingCache, deathCon)
	
	local ragdolledCon = plr.Character.AttributeChanged:Connect(function(attName)
		if attName == "Ragdolled" then
			if plr.Character:GetAttribute(attName) ~= nil then
				-- || Ragdolled
				viewmodelClient.canEquippTool = false
				self:UnEquip()
			else
				-- || Unragdolled
				viewmodelClient.canEquippTool = true
			end
		end
	end)
end

function viewmodelClient.viewmodelTools:UnEquip()
	-- || Editing Values
	UIS.MouseIconEnabled = true
	
	isAimingValue.Value = false
	isFiringValue.Value = false
	self.Equipped = false
	self.aiming = false
	--UIS.MouseDeltaSensitivity = 1
	cam.FieldOfView = globalSettings.defaultFOV
	
	-- || Attachment Modules
	require(script.AttachmentsModules.paralaxScope).onToolUnEquipped(self.toolModel)
	
	-- || Removing Cache
	for _, cacheObj in pairs(self.equippingCache) do
		pcall(function() cacheObj:Disconnect() end)
		pcall(function() cacheObj:Destroy() end)
		pcall(function() coroutine.close(cacheObj) end)
	end
	
	-- || Removing replicated idle anim
	self.bridgesList.AnimationReplicate:Fire({
		false, 
		true,
		Enum.AnimationPriority.Idle,
		self.toolName,
		true
	})
	
	-- || Unequipping Viewmodel
	self.toolModel.Parent = self.toolObj
	self.viewmodel:Destroy()
	--self.viewmodel.Parent = self.toolObj
	
	-- || Placing tool back into backpack
	if self.toolObj.Parent == plr.Character then
		self.toolObj.Parent = plr.Backpack
	end
end

function viewmodelClient.newViewmodelTool(toolObj : Tool)
	local self = setmetatable({}, viewmodelClient.viewmodelTools)
	
	-- || Placing Default Values
	self.bridgesList = require(viewmodelEngineFolder.EngineBridges).bridgesList
	
	self.equippingCache = {}
	self.toolObj = toolObj
	self.toolValues = toolObj:FindFirstChild("ToolValues")
	
	self.toolName = self.toolObj.Name
	self.toolSettings = require(viewmodelEngineFolder.Assets.ToolSettings[self.toolName])
	
	self.viewmodelValuesFolder = viewmodelValuesFolder
	self.movementFolder = movementFolder
	
	if self.toolSettings.isWeapon == true or self.toolSettings.hasCaster == true then
		self.uniqueID_casting = viewmodelEngineFolder.RemoteFunctions.AssignCaster:InvokeServer(toolObj)
	end
	
	-- || Connections
	self.toolObj.Equipped:Connect(function()
		self:Equip()
	end)
	
	self.toolObj.Unequipped:Connect(function()
		self:UnEquip()
	end)
end

local function createViewmodelValues()
	-- || Instancing
	viewmodelValuesFolder = Instance.new("Folder", plr)
	isAimingValue = Instance.new("BoolValue", viewmodelValuesFolder)
	isFiringValue = Instance.new("BoolValue", viewmodelValuesFolder)
	
	-- || Editing Parentecies
	viewmodelValuesFolder.Name = "ViewmodelValues"
	isAimingValue.Name = "IsAiming"
	isFiringValue.Name = "IsFiring"
end

function viewmodelClient.initializeClientScript()
	-- || Calling Functions
	createViewmodelValues()
end

return viewmodelClient
