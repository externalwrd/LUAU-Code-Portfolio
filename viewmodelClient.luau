-- Made by Avia_player (Roblox) | externalwrd (Discord)

-- // Services
-- Get the services used by this script.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RS = game:GetService("RunService")
local UIS = game:GetService("UserInputService")

-- // Idents
local plr = Players.LocalPlayer
local cam = workspace.CurrentCamera

local viewmodelValuesFolder
local isAimingValue
local isFiringValue

local movementFolder = plr:WaitForChild("MovementValues")

local viewmodelEngineFolder = ReplicatedStorage.ViewmodelEngine

-- // Requireies
local bridgeNet2Module = require(ReplicatedStorage.Resources.BridgeNet2)
local aimingFocusModule = require(script.aimingFocus)
local globalSettings = require(game.ReplicatedStorage.GlobalSettings)

-- // Values
local viewmodelClient = {}
viewmodelClient.viewmodelTools = {}
viewmodelClient.viewmodelTools.__index = viewmodelClient.viewmodelTools

viewmodelClient.currentEquippedSelf = nil
viewmodelClient.canEquippTool = true

-- Finds every handler ModuleScript under this script, requires each one, and
-- stores the resulting tables on the tool instance.
local function collectHandlerModules(toolInstance)
	local handlers = {}
	for _, descendant in ipairs(script:GetDescendants()) do
		if descendant:IsA("ModuleScript") then
			local ok, reqModule = pcall(require, descendant)
			if ok then
				table.insert(handlers, reqModule)
			else
				warn("[viewmodelClient] failed to require handler module", descendant:GetFullName(), reqModule)
			end
		end
	end
	toolInstance.handlerModules = handlers
end

-- // Code

local function preEquippingChecks(self)
	-- Returns true if the character exists, is alive, and tool equipping is
	-- currently allowed; otherwise returns false.
	if plr.Character then
		if plr.Character:WaitForChild("Humanoid").Health > 0 then
			if viewmodelClient.canEquippTool == true then
				return true
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

	self.mouseDelta = Vector2.new(0, 0)

	self.aiming = false
	self.Equipped = true

	self.humanoid = plr.Character.Humanoid
	self.humRootPart = plr.Character.HumanoidRootPart

	viewmodelClient.currentEquippedSelf = self

	-- Build the handler module list the first time this tool is equipped.
	if not self.handlerModules then
		collectHandlerModules(self)
	end

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
	-- Runs once per frame, right after Roblox updates the camera, to apply
	-- viewmodel/camera sway, bob, and spring effects.
	local renderStepName = "ViewmodelCameraUpdate_" .. self.toolName
	RS:BindToRenderStep(renderStepName, Enum.RenderPriority.Camera.Value + 1, function(dt)
		-- || Placing Values
		self.dt = dt
		self.viewmodelEffectsCF = CFrame.new()
		self.cameraEffectsCF = CFrame.new()

		-- || Updating Springs
		for springName, spring in pairs(self.springs) do
			self["updated_" .. springName] = spring.update(spring, dt)
		end

		-- || Requiring Rendering Modules
		aimingFocusModule.onRender(self)
		require(script.viewmodelArms).onRenderStepped(self)

		-- || Placing Camera Value
		cam.CFrame *= self.cameraEffectsCF
	end)
	-- Store the render step's name so it can be unbound in UnEquip.
	table.insert(self.equippingCache, renderStepName)

	-- || Input Handling
	local inpBeganCon = UIS.InputBegan:Connect(function(input, gameProccessed)
		-- Calls onInputBegan on every cached handler module.
		for _, reqModule in ipairs(self.handlerModules) do
			local succ, errMsg = pcall(function()
				if reqModule.onInputBegan ~= nil then
					reqModule.onInputBegan(self, input, gameProccessed)
				end
			end)
			if not succ then
				warn("[viewmodelClient] onInputBegan handler error:", errMsg)
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
		-- Updates mouseDelta from the right thumbstick when a gamepad is in use.
		if input.KeyCode == Enum.KeyCode.Thumbstick2 and UIS.GamepadEnabled == true then
			self.mouseDelta = input.Position * 2
		end
	end)
	table.insert(self.equippingCache, inpChangedCon)

	local inpEndCon = UIS.InputEnded:Connect(function(input, gameProccessed)
		-- Calls onInputEnded on every cached handler module.
		for _, reqModule in ipairs(self.handlerModules) do
			local succ, errMsg = pcall(function()
				if reqModule.onInputEnded ~= nil then
					reqModule.onInputEnded(self, input, gameProccessed)
				end
			end)
			if not succ then
				warn("[viewmodelClient] onInputEnded handler error:", errMsg)
			end
		end
	end)
	table.insert(self.equippingCache, inpEndCon)

	-- Calls onDeath on every cached handler module when the humanoid dies.
	local deathCon = self.humanoid.Died:Once(function()
		for _, reqModule in ipairs(self.handlerModules) do
			pcall(function()
				if reqModule.onDeath ~= nil then
					reqModule.onDeath(self)
				end
			end)
		end
	end)
	table.insert(self.equippingCache, deathCon)

	-- Watches the character's "Ragdolled" attribute and unequips the tool
	-- while ragdolled, blocking re-equipping until it clears.
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
	table.insert(self.equippingCache, ragdolledCon)
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
	-- Unbinds the render step and disconnects/destroys every other cached
	-- connection or instance from this equip.
	for _, cacheObj in ipairs(self.equippingCache) do
		if typeof(cacheObj) == "string" then
			pcall(function() RS:UnbindFromRenderStep(cacheObj) end)
		else
			pcall(function() cacheObj:Disconnect() end)
			pcall(function() cacheObj:Destroy() end)
			pcall(function() coroutine.close(cacheObj) end)
		end
	end
	self.equippingCache = {}

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

function viewmodelClient.newViewmodelTool(toolObj: Tool)
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

	-- Requests a caster from the server for weapons or tools that need one.
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

	return self
end

local function createViewmodelValues()
	-- || Instancing
	-- Creates the ViewmodelValues folder and its IsAiming/IsFiring BoolValues,
	-- then parents them into the player.
	viewmodelValuesFolder = Instance.new("Folder")
	viewmodelValuesFolder.Name = "ViewmodelValues"

	isAimingValue = Instance.new("BoolValue")
	isAimingValue.Name = "IsAiming"
	isAimingValue.Parent = viewmodelValuesFolder

	isFiringValue = Instance.new("BoolValue")
	isFiringValue.Name = "IsFiring"
	isFiringValue.Parent = viewmodelValuesFolder

	viewmodelValuesFolder.Parent = plr
end

function viewmodelClient.initializeClientScript()
	-- || Calling Functions
	createViewmodelValues()
end

return viewmodelClient
