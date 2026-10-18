-- Made by Avia_player (Roblox) | externalwrd (Discord)

--[[
	viewmodelClient: client-side controller that turns a Tool into a first-person viewmodel tool.

	Flow:
	  newViewmodelTool(tool) builds one object per Tool (metatable class) and listens to Equipped/Unequipped.
	  Equip   -> validates the character, resets per-equip state, runs the feature modules (arms, HUD, jamming,
	             grenades, firemode, muzzle pointer), then binds the per-frame camera step, input and character events.
	  UnEquip -> releases everything Equip registered (tracked in equippingCache) and restores camera, mouse and tool.

	The feature modules live under this script and all receive `self` (the tool object). They share state
	through it instead of requiring each other, which keeps the dependency graph one-directional.

	Credits: BridgeNet2 by ffrostfall (https://github.com/ffrostfall/BridgeNet2) is the networking library behind
	the bridges in EngineBridges (used here for AnimationReplicate).
]]

-- // Services
-- GetService (rather than game.ServiceName) keeps working even if a service is renamed
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RS = game:GetService("RunService") -- BindToRenderStep lets us pick exactly when our camera code runs each frame
local UIS = game:GetService("UserInputService") -- Input events and the mouse icon toggle

-- // Idents
local plr = Players.LocalPlayer
local cam = workspace.CurrentCamera -- Cached once: it is read every frame, so a per-frame lookup would be repeated work

-- WaitForChild because the folder may not have replicated to the client yet when this module loads
local movementFolder = plr:WaitForChild("MovementValues")
local viewmodelEngineFolder = ReplicatedStorage.ViewmodelEngine

-- Assigned in createViewmodelValues; declared up here so newViewmodelTool and UnEquip share the same instances
local viewmodelValuesFolder
local isAimingValue
local isFiringValue

-- // Requires
-- Every module is required once here: require is cached anyway, but hoisting it removes the call from
-- Equip and, more importantly, from the per-frame render step
local globalSettings = require(ReplicatedStorage.GlobalSettings)
local bridgesList = require(viewmodelEngineFolder.EngineBridges).bridgesList

local aimingFocusModule = require(script.aimingFocus)
local viewmodelArmsModule = require(script.viewmodelArms)
local weaponHUDModule = require(script.weaponHUD)
local weaponJammingModule = require(script.weaponJamming)
local grenadesModule = require(script.grenades)
local firemodeSelectModule = require(script.firemodeSelect)
local muzzlePointerModule = require(script.muzzlePointer)
local paralaxScopeModule = require(script.AttachmentsModules.paralaxScope)

-- // Constants
-- Camera priority + 1 runs right after Roblox's own camera script has written cam.CFrame this frame, so the
-- additive `cam.CFrame *= effects` composes on top of it instead of being overwritten by it
local VIEWMODEL_RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

-- Idle is the lowest animation priority, so action animations (fire, reload) played elsewhere override it
local IDLE_ANIMATION_PRIORITY = Enum.AnimationPriority.Idle

-- Thumbstick positions are limited to -1..1 while mouse deltas are in pixels; the multiplier scales gamepad
-- look up so the sway code receives a value of a comparable size
local THUMBSTICK_SENSITIVITY = 2

-- Per-equip defaults copied onto `self` on every Equip. CFrame and Vector2 are immutable values, so one shared
-- instance is safe; `springs` is mutable and therefore created fresh in initializeEquipState instead
local EQUIP_DEFAULTS = {
	viewmodelEffectsCF = CFrame.identity,
	aimingOffset = CFrame.identity,
	effectSwayCF = CFrame.identity,
	cameraEffectsCF = CFrame.identity,
	swayMultiplier = 1,
	bobbleSpeed = 8,
	bobbleAmount = 0.02,
	mouseDelta = Vector2.zero,
	aiming = false,
}

local function noop() end

-- Dispatch table keyed by typeof(): one direct lookup per cached object, instead of calling Disconnect, Destroy
-- and coroutine.close on every object and relying on the wrong ones throwing
local CACHE_RELEASERS = {
	string = function(stepName) RS:UnbindFromRenderStep(stepName) end,
	RBXScriptConnection = function(connection) connection:Disconnect() end,
	Instance = function(instance) instance:Destroy() end,
	thread = task.cancel, -- task.cancel also stops threads that are still queued in the task scheduler
	table = function(object) -- Connection-like wrappers (maids, custom signals) expose Destroy or Disconnect
		local release = object.Destroy or object.Disconnect or noop
		release(object)
	end,
}

-- Metatable memoisation: "updated_" .. springName would allocate a new string for every spring every frame.
-- __index builds each key once, stores it with rawset, and every later lookup is a plain table read
local SPRING_KEYS = setmetatable({}, {
	__index = function(keys, springName)
		local key = "updated_" .. springName
		rawset(keys, springName, key)
		return key
	end,
})

-- // Class
-- Public API table. currentEquippedSelf is assigned in initializeEquipState; canEquippTool is the equip lock
-- that the ragdoll handler toggles
local viewmodelTools = {}
viewmodelTools.__index = viewmodelTools -- Missing keys on a tool object fall through to the methods below

local viewmodelClient = {
	viewmodelTools = viewmodelTools,
	canEquippTool = true,
}

-- // Error handling
-- Runs at the point of failure (before the stack unwinds), so the traceback shows the failing frames, which a
-- plain pcall would lose. Every protected call below shares this one reporter
local function reportError(errMsg)
	warn("[viewmodelClient]", debug.traceback(tostring(errMsg), 2))
end

-- // Handler modules
-- Requires every ModuleScript under this script so they can opt in to the events dispatched below
local function loadHandlerModules()
	local handlers = {}

	for _, descendant in ipairs(script:GetDescendants()) do
		if not descendant:IsA("ModuleScript") then continue end

		-- A handler that fails to load is reported and skipped instead of breaking every other handler
		local success, handler = xpcall(require, reportError, descendant)
		if not success or type(handler) ~= "table" then continue end

		table.insert(handlers, handler)
	end

	return handlers
end

-- Built once at load, not per tool or per equip: the set of handlers never changes, so every tool shares it
local handlerModules = loadHandlerModules()

-- Forwards an event to every handler that implements it. Callbacks are optional, so missing ones are skipped,
-- and xpcall isolates each call so one faulty handler cannot stop the others from receiving the event.
-- The varargs carry the event's own arguments through unchanged
local function dispatchToHandlers(self, callbackName, ...)
	for _, handler in ipairs(handlerModules) do
		local callback = handler[callbackName]
		if callback == nil then continue end

		xpcall(callback, reportError, self, ...)
	end
end

-- Runs a tool-specific hook from the tool's settings module (e.g. a one-off ability for a single weapon).
-- task.spawn starts it immediately but on its own thread: a hook that yields or errors cannot stall or
-- break the equip/input code that triggered it
local function runCustomScenario(self, scenarioName, ...)
	local scenarios = self.toolSettings.customScenarios
	local scenario = scenarios and scenarios[scenarioName]
	if scenario == nil then return end

	task.spawn(scenario, ...)
end

-- // Equip helpers
-- Returns the humanoid when equipping is allowed, otherwise nil. FindFirstChildOfClass instead of WaitForChild:
-- this is a yes/no gate, so it must answer immediately instead of yielding on a character that is missing.
-- Humanoid.RootPart is the engine-maintained root reference, so no name-based HumanoidRootPart lookup is needed
local function getEquippingHumanoid()
	local character = plr.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then return nil end
	if humanoid.RootPart == nil or not viewmodelClient.canEquippTool then return nil end

	return humanoid
end

-- Resets everything the feature modules expect to find on `self` at the start of an equip
local function initializeEquipState(self, humanoid)
	for key, value in pairs(EQUIP_DEFAULTS) do
		self[key] = value
	end

	self.springs = {} -- Filled by the feature modules; read every frame by onRenderStep
	self.aimingFOV = globalSettings.defaultFOV -- Read at equip time so a changed default FOV is respected
	self.Equipped = true -- UnEquip uses this as its re-entrancy guard
	self.humanoid = humanoid
	self.humRootPart = humanoid.RootPart

	viewmodelClient.currentEquippedSelf = self
end

-- The pointer needs self.hudUI (created by weaponHUD earlier in Equip), which is why it runs after the HUD module
local function startMuzzlePointer(self)
	if self.toolSettings.muzzlePointerVisible == false then return end

	local pointerConnection = muzzlePointerModule.startPointer(self.toolModel.Handle.Firepoint, self.hudUI)
	self.muzzlePointerCon = pointerConnection
	table.insert(self.equippingCache, pointerConnection)
end

-- // Per-frame update
local function onRenderStep(self, dt)
	self.dt = dt -- Published on the tool object because the feature modules read the frame time from it

	-- Effects are rebuilt from identity every frame so modules compose their offsets onto a clean value
	self.viewmodelEffectsCF = CFrame.identity
	self.cameraEffectsCF = CFrame.identity

	-- Springs step first so every module below sees this frame's values (stored as self.updated_<springName>)
	for springName, spring in pairs(self.springs) do
		self[SPRING_KEYS[springName]] = spring:update(dt)
	end

	aimingFocusModule.onRender(self)
	viewmodelArmsModule.onRenderStepped(self)

	-- Post-multiplying applies the offset in the camera's local space, so sway and recoil rotate relative to
	-- where the player is looking instead of along world axes
	cam.CFrame *= self.cameraEffectsCF
end

-- // Event binding
-- Every connection and the render step name are pushed into equippingCache so UnEquip can release them all
local function bindRenderStep(self)
	local stepName = "ViewmodelCameraUpdate_" .. self.toolName -- Unique per tool so two tools never share a binding

	-- The closure captures `self`; BindToRenderStep itself only hands us dt
	RS:BindToRenderStep(stepName, VIEWMODEL_RENDER_PRIORITY, function(dt)
		onRenderStep(self, dt)
	end)

	table.insert(self.equippingCache, stepName)
end

-- Right thumbstick drives look on gamepad. Thumbstick2 only arrives from gamepads, so no device check is needed.
-- Vector2 is rebuilt from the Vector3 position so mouseDelta keeps the same type as its default value
local function onInputChanged(self, input)
	if input.KeyCode ~= Enum.KeyCode.Thumbstick2 then return end

	self.mouseDelta = Vector2.new(input.Position.X, input.Position.Y) * THUMBSTICK_SENSITIVITY
end

local function bindInputConnections(self)
	local cache = self.equippingCache

	table.insert(cache, UIS.InputBegan:Connect(function(input, gameProcessed)
		dispatchToHandlers(self, "onInputBegan", input, gameProcessed)
		runCustomScenario(self, "onInputBegan", input, gameProcessed, self)
	end))

	-- InputChanged fires for mouse movement too; the guard inside onInputChanged keeps that path cheap
	table.insert(cache, UIS.InputChanged:Connect(function(input)
		onInputChanged(self, input)
	end))

	table.insert(cache, UIS.InputEnded:Connect(function(input, gameProcessed)
		dispatchToHandlers(self, "onInputEnded", input, gameProcessed)
	end))
end

-- Any non-nil "Ragdolled" attribute locks equipping and forces the tool away; clearing it unlocks again
local function onRagdolledChanged(self, character)
	local isRagdolled = character:GetAttribute("Ragdolled") ~= nil
	viewmodelClient.canEquippTool = not isRagdolled
	if not isRagdolled then return end

	self:UnEquip()
end

local function bindCharacterConnections(self)
	local cache = self.equippingCache
	local character = plr.Character

	-- Once: death happens a single time per humanoid, so the connection cleans itself up after firing
	table.insert(cache, self.humanoid.Died:Once(function()
		dispatchToHandlers(self, "onDeath")
	end))

	-- GetAttributeChangedSignal fires only for "Ragdolled", unlike AttributeChanged which wakes us for every attribute
	table.insert(cache, character:GetAttributeChangedSignal("Ragdolled"):Connect(function()
		onRagdolledChanged(self, character)
	end))
end

-- // Unequip helpers
-- Releases every cached object with the releaser that matches its type. xpcall keeps one failing release from
-- leaving the rest of the equip half torn down
local function releaseEquippingCache(self)
	local cache = self.equippingCache

	for _, cachedObject in ipairs(cache) do
		local release = CACHE_RELEASERS[typeof(cachedObject)] or noop
		xpcall(release, reportError, cachedObject)
	end

	table.clear(cache) -- Same table is reused for the next equip, and the bound connections above still point at it
end

-- // Tool methods
function viewmodelTools:Equip()
	local humanoid = getEquippingHumanoid()
	if humanoid == nil then
		-- Hand the tool back: otherwise Roblox leaves it held with no viewmodel. The Unequipped event this
		-- triggers reaches UnEquip, which exits immediately at its guard because nothing was equipped
		self.toolObj.Parent = plr.Backpack
		return
	end

	initializeEquipState(self, humanoid)
	UIS.MouseIconEnabled = false -- The HUD draws its own crosshair, so the system cursor would double it

	-- Order matters: later modules read objects the earlier ones create on `self` (viewmodel, toolModel, hudUI)
	viewmodelArmsModule.onToolEquipped(self)
	weaponHUDModule.newHudUI(self)
	weaponJammingModule.weaponJammedUI(self)
	grenadesModule.onEquip(self)
	firemodeSelectModule.updateFiremodeText(self)
	startMuzzlePointer(self)

	-- Positional payload consumed by the AnimationReplicate bridge handler, so other players see the idle pose
	bridgesList.AnimationReplicate:Fire({
		true,
		self.toolSettingsModule.Animations.IdleR6,
		IDLE_ANIMATION_PRIORITY,
		self.toolName,
	})

	runCustomScenario(self, "onEquipp") -- Hook takes no arguments, matching the tool settings modules

	bindRenderStep(self)
	bindInputConnections(self)
	bindCharacterConnections(self)
end

function viewmodelTools:UnEquip()
	-- Guard: moving the tool to the Backpack at the end of this method fires Unequipped, which calls UnEquip
	-- again. Equipped is cleared immediately below, so that re-entrant call (and any Unequipped for a tool
	-- that never finished equipping) exits here instead of cleaning up twice
	if not self.Equipped then return end
	self.Equipped = false
	self.aiming = false

	UIS.MouseIconEnabled = true
	isAimingValue.Value = false
	isFiringValue.Value = false
	cam.FieldOfView = globalSettings.defaultFOV -- Aiming changes the FOV, so it must be put back explicitly

	paralaxScopeModule.onToolUnEquipped(self.toolModel)

	-- Released before the viewmodel is destroyed so the render step can never touch a destroyed viewmodel
	releaseEquippingCache(self)

	bridgesList.AnimationReplicate:Fire({ false, true, IDLE_ANIMATION_PRIORITY, self.toolName, true })

	-- Rescue the tool model first: destroying the viewmodel destroys its descendants, including the model
	self.toolModel.Parent = self.toolObj
	self.viewmodel:Destroy()

	if self.toolObj.Parent ~= plr.Character then return end

	self.toolObj.Parent = plr.Backpack
end

-- // Constructor
function viewmodelClient.newViewmodelTool(toolObj: Tool)
	local self = setmetatable({}, viewmodelTools)

	self.bridgesList = bridgesList
	self.equippingCache = {}
	self.toolObj = toolObj
	self.toolValues = toolObj:FindFirstChild("ToolValues") -- Optional: not every tool has values
	self.toolName = toolObj.Name

	-- The settings module is looked up once and reused for both its data (require) and its child assets (Animations)
	self.toolSettingsModule = viewmodelEngineFolder.Assets.ToolSettings[self.toolName]
	self.toolSettings = require(self.toolSettingsModule)

	self.viewmodelValuesFolder = viewmodelValuesFolder
	self.movementFolder = movementFolder

	-- InvokeServer yields until the server answers, so the caster id exists before the tool can ever fire.
	-- Done once at construction instead of on every equip
	if self.toolSettings.isWeapon or self.toolSettings.hasCaster then
		self.uniqueID_casting = viewmodelEngineFolder.RemoteFunctions.AssignCaster:InvokeServer(toolObj)
	end

	-- Closures instead of method references: Tool.Equipped passes the mouse, which would land in `self`
	toolObj.Equipped:Connect(function()
		self:Equip()
	end)

	toolObj.Unequipped:Connect(function()
		self:UnEquip()
	end)

	return self
end

-- // Initialization
local function createBoolValue(name, parent)
	local boolValue = Instance.new("BoolValue")
	boolValue.Name = name
	boolValue.Parent = parent

	return boolValue
end

-- The folder is parented to the player last, so everything that listens for it sees the finished structure
local function createViewmodelValues()
	viewmodelValuesFolder = Instance.new("Folder")
	viewmodelValuesFolder.Name = "ViewmodelValues"

	isAimingValue = createBoolValue("IsAiming", viewmodelValuesFolder)
	isFiringValue = createBoolValue("IsFiring", viewmodelValuesFolder)

	viewmodelValuesFolder.Parent = plr
end

function viewmodelClient.initializeClientScript()
	createViewmodelValues()

	-- Dying while ragdolled never fires the "cleared" attribute signal on the new character, which would leave
	-- the equip lock stuck on forever, so every new life starts unlocked
	plr.CharacterAdded:Connect(function()
		viewmodelClient.canEquippTool = true
	end)
end

return viewmodelClient
