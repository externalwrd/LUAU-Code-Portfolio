-- Made by Avia_player (Roblox) | externalwrd (Discord)

-- // Services
local Players = game:GetService("Players") -- GetService keeps working even if the service is renamed.
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- Holds the engine folder and the shared settings.
local RS = game:GetService("RunService") -- BindToRenderStep lets us pick exactly when our camera code runs.
local UIS = game:GetService("UserInputService") -- Input events and the mouse icon toggle.

-- // Idents
local plr = Players.LocalPlayer -- The local player owns the camera, input and values this module drives.
local cam = workspace.CurrentCamera -- Cached once because it is used every frame.

local movementFolder = plr:WaitForChild("MovementValues") -- WaitForChild because it may not have replicated yet.
local viewmodelEngineFolder = ReplicatedStorage.ViewmodelEngine -- Root of the engine's modules, assets and remotes.

local viewmodelValuesFolder -- Assigned in createViewmodelValues and shared with every tool.
local isAimingValue -- Aim flag that other client scripts can read.
local isFiringValue -- Fire flag that other client scripts can read.

-- // Requires
local globalSettings = require(ReplicatedStorage.GlobalSettings) -- Shared tuning values such as the default FOV.
local bridgesList = require(viewmodelEngineFolder.EngineBridges).bridgesList -- Bridges built on BridgeNet2 by ffrostfall (github.com/ffrostfall/BridgeNet2).

local aimingFocusModule = require(script.aimingFocus) -- Every module is required once here so the render step never calls require.
local viewmodelArmsModule = require(script.viewmodelArms) -- Viewmodel creation and per-frame arm updates.
local weaponHUDModule = require(script.weaponHUD) -- Builds the weapon HUD.
local weaponJammingModule = require(script.weaponJamming) -- Jam indicator UI.
local grenadesModule = require(script.grenades) -- Grenade handling for the tool.
local firemodeSelectModule = require(script.firemodeSelect) -- Firemode text on the HUD.
local muzzlePointerModule = require(script.muzzlePointer) -- On-screen pointer for the muzzle direction.
local paralaxScopeModule = require(script.AttachmentsModules.paralaxScope) -- Scope attachment cleanup.

-- // Constants
local VIEWMODEL_RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1 -- Runs right after the default camera so our offset isn't overwritten.
local IDLE_ANIMATION_PRIORITY = Enum.AnimationPriority.Idle -- Lowest priority, so fire and reload animations override it.
local THUMBSTICK_SENSITIVITY = 2 -- Scales the -1..1 stick range toward mouse-delta sized values.

local EQUIP_DEFAULTS = { -- Copied onto the tool object at the start of every equip.
	viewmodelEffectsCF = CFrame.identity, -- CFrame is immutable, so one shared value is safe.
	aimingOffset = CFrame.identity, -- No aiming offset until the player aims.
	effectSwayCF = CFrame.identity, -- No sway until the first frame updates it.
	cameraEffectsCF = CFrame.identity, -- No camera effect until a module adds one.
	swayMultiplier = 1, -- Neutral sway strength.
	bobbleSpeed = 8, -- Walk bob speed.
	bobbleAmount = 0.02, -- Walk bob size.
	mouseDelta = Vector2.zero, -- No look input yet.
	aiming = false, -- Never starts aimed.
}

local function noop() end -- Fallback releaser for types we don't know how to clean up.

local CACHE_RELEASERS = { -- Keyed by typeof() so each cached object costs one lookup instead of three blind pcalls.
	string = function(stepName) RS:UnbindFromRenderStep(stepName) end, -- Strings are render step names.
	RBXScriptConnection = function(connection) connection:Disconnect() end, -- Stops the event from firing.
	Instance = function(instance) instance:Destroy() end, -- Tweens, GUIs and any other instance.
	thread = task.cancel, -- Also stops threads that are still queued in the scheduler.
	table = function(object) -- Wrapper objects expose either Destroy or Disconnect.
		local release = object.Destroy or object.Disconnect or noop -- Prefers Destroy, falls back to Disconnect.
		release(object) -- Called with the object as self.
	end,
}

local SPRING_KEYS = setmetatable({}, { -- Memoizes "updated_<name>" so no string is built every frame.
	__index = function(keys, springName) -- Only runs the first time a spring name is seen.
		local key = "updated_" .. springName -- Builds the key once.
		rawset(keys, springName, key) -- rawset stores it without triggering any metamethods.
		return key -- Later lookups hit the table directly and skip __index.
	end,
})

-- // Class
local viewmodelTools = {} -- Class table that holds the Equip and UnEquip methods.
viewmodelTools.__index = viewmodelTools -- Missing keys on a tool object fall through to these methods.

local viewmodelClient = { -- Public API of this module.
	viewmodelTools = viewmodelTools, -- Exposed so other scripts can reach the class.
	canEquippTool = true, -- Equip lock toggled by the ragdoll handler.
}

-- // Error handling
local function reportError(errMsg) -- Shared xpcall handler for every protected call below.
	warn("[viewmodelClient]", debug.traceback(tostring(errMsg), 2)) -- Runs before unwinding, so the traceback keeps the failing frames.
end

-- // Handler modules
local function loadHandlerModules() -- Collects every module under this script that can handle events.
	local handlers = {} -- Filled below and returned once.

	for _, descendant in ipairs(script:GetDescendants()) do -- Includes nested folders like AttachmentsModules.
		if not descendant:IsA("ModuleScript") then continue end -- Skip folders and every other instance.

		local success, handler = xpcall(require, reportError, descendant) -- A broken module is reported instead of crashing the rest.
		if not success or type(handler) ~= "table" then continue end -- Only tables can expose callbacks.

		table.insert(handlers, handler) -- Keep it for dispatching.
	end

	return handlers -- Handed to the single module-level cache below.
end

local handlerModules = loadHandlerModules() -- Built once at load because the handler set never changes.

local function dispatchToHandlers(self, callbackName, ...) -- Forwards one event to every handler that implements it.
	for _, handler in ipairs(handlerModules) do -- Same order every time.
		local callback = handler[callbackName] -- Callbacks are optional per handler.
		if callback == nil then continue end -- Skip handlers that don't care about this event.

		xpcall(callback, reportError, self, ...) -- Isolated, so one faulty handler can't block the others.
	end
end

local function runCustomScenario(self, scenarioName, ...) -- Runs a tool-specific hook from its settings module.
	local scenarios = self.toolSettings.customScenarios -- Optional table, absent on most tools.
	local scenario = scenarios and scenarios[scenarioName] -- Nil-safe lookup of the requested hook.
	if scenario == nil then return end -- Nothing to run for this tool.

	task.spawn(scenario, ...) -- Own thread, so a yielding or erroring hook can't stall the caller.
end

-- // Equip helpers
local function getEquippingHumanoid() -- Returns the humanoid if equipping is allowed, otherwise nil.
	local character = plr.Character -- Can be nil while respawning.
	local humanoid = character and character:FindFirstChildOfClass("Humanoid") -- Non-yielding, unlike WaitForChild.
	if humanoid == nil or humanoid.Health <= 0 then return nil end -- No humanoid, or already dead.
	if humanoid.RootPart == nil or not viewmodelClient.canEquippTool then return nil end -- RootPart is engine-maintained; the lock blocks ragdolls.

	return humanoid -- The caller reuses it so the character isn't searched again.
end

local function initializeEquipState(self, humanoid) -- Resets what the feature modules expect to find on self.
	for key, value in pairs(EQUIP_DEFAULTS) do -- One loop replaces a dozen assignments.
		self[key] = value -- Copy each default onto the tool object.
	end

	self.springs = {} -- Mutable, so it is created fresh for every equip.
	self.aimingFOV = globalSettings.defaultFOV -- Read now so a changed default FOV is respected.
	self.Equipped = true -- Also acts as UnEquip's re-entrancy guard.
	self.humanoid = humanoid -- Saved for the death handler.
	self.humRootPart = humanoid.RootPart -- Saved for modules that need the character's position.

	viewmodelClient.currentEquippedSelf = self -- Lets other scripts find the active tool object.
end

local function startMuzzlePointer(self) -- Starts the muzzle pointer if the tool wants one.
	if self.toolSettings.muzzlePointerVisible == false then return end -- Visible unless the tool opts out.

	local pointerConnection = muzzlePointerModule.startPointer(self.toolModel.Handle.Firepoint, self.hudUI) -- Needs hudUI, so it runs after the HUD exists.
	self.muzzlePointerCon = pointerConnection -- Kept on the tool object for other modules.
	table.insert(self.equippingCache, pointerConnection) -- Released automatically on unequip.
end

-- // Per-frame update
local function onRenderStep(self, dt) -- Runs once per frame while the tool is equipped.
	self.dt = dt -- Feature modules read the frame time from the tool object.

	self.viewmodelEffectsCF = CFrame.identity -- Rebuilt every frame so modules compose onto a clean value.
	self.cameraEffectsCF = CFrame.identity -- Same reset for the camera offset.

	for springName, spring in pairs(self.springs) do -- Springs step first so modules see this frame's values.
		self[SPRING_KEYS[springName]] = spring:update(dt) -- Stored as self.updated_<springName>.
	end

	aimingFocusModule.onRender(self) -- Aiming focus effects for this frame.
	viewmodelArmsModule.onRenderStepped(self) -- Viewmodel arm updates for this frame.

	cam.CFrame *= self.cameraEffectsCF -- Post-multiplying applies the offset in the camera's local space, not world axes.
end

-- // Event binding
local function bindRenderStep(self) -- Hooks onRenderStep into the render loop.
	local stepName = "ViewmodelCameraUpdate_" .. self.toolName -- Unique per tool so bindings never collide.

	RS:BindToRenderStep(stepName, VIEWMODEL_RENDER_PRIORITY, function(dt) -- Our priority places us right after the camera.
		onRenderStep(self, dt) -- The closure carries self, since BindToRenderStep only passes dt.
	end)

	table.insert(self.equippingCache, stepName) -- The name is what UnbindFromRenderStep needs later.
end

local function onInputChanged(self, input) -- Translates gamepad look input into mouseDelta.
	if input.KeyCode ~= Enum.KeyCode.Thumbstick2 then return end -- Right stick only; mouse movement exits here cheaply.

	self.mouseDelta = Vector2.new(input.Position.X, input.Position.Y) * THUMBSTICK_SENSITIVITY -- Vector2 keeps mouseDelta's type consistent.
end

local function bindInputConnections(self) -- Connects player input to handlers and tool hooks.
	local cache = self.equippingCache -- Everything connected here is released through this table.

	table.insert(cache, UIS.InputBegan:Connect(function(input, gameProcessed) -- Fires for every key, click and button press.
		dispatchToHandlers(self, "onInputBegan", input, gameProcessed) -- Handlers decide what the input means.
		runCustomScenario(self, "onInputBegan", input, gameProcessed, self) -- Tool-specific reaction, with self passed last.
	end))

	table.insert(cache, UIS.InputChanged:Connect(function(input) -- Fires continuously for mouse and stick movement.
		onInputChanged(self, input) -- Forwarded so the closure stays one line.
	end))

	table.insert(cache, UIS.InputEnded:Connect(function(input, gameProcessed) -- Fires when a key or button is released.
		dispatchToHandlers(self, "onInputEnded", input, gameProcessed) -- Lets handlers end holds like aiming or firing.
	end))
end

local function onRagdolledChanged(self, character) -- Reacts to the Ragdolled attribute changing.
	local isRagdolled = character:GetAttribute("Ragdolled") ~= nil -- Any non-nil value counts as ragdolled.
	viewmodelClient.canEquippTool = not isRagdolled -- Locks equipping while ragdolled and unlocks it afterwards.
	if not isRagdolled then return end -- Nothing to unequip when the ragdoll just ended.

	self:UnEquip() -- A ragdolled character can't hold a viewmodel tool.
end

local function bindCharacterConnections(self) -- Connects events that come from the character itself.
	local cache = self.equippingCache -- Same release table as the input connections.
	local character = plr.Character -- Already validated by getEquippingHumanoid.

	table.insert(cache, self.humanoid.Died:Once(function() -- Once, because a humanoid only dies once.
		dispatchToHandlers(self, "onDeath") -- Handlers clean up their own state.
	end))

	table.insert(cache, character:GetAttributeChangedSignal("Ragdolled"):Connect(function() -- Fires only for this attribute, unlike AttributeChanged.
		onRagdolledChanged(self, character) -- Passes the character so the callback needs no lookup.
	end))
end

-- // Unequip helpers
local function releaseEquippingCache(self) -- Tears down everything an equip registered.
	local cache = self.equippingCache -- Connections, render step names and instances.

	for _, cachedObject in ipairs(cache) do -- Release in registration order.
		local release = CACHE_RELEASERS[typeof(cachedObject)] or noop -- Unknown types fall back to doing nothing.
		xpcall(release, reportError, cachedObject) -- One failing release can't leave the rest half torn down.
	end

	table.clear(cache) -- Emptied in place and reused for the next equip.
end

-- // Tool methods
function viewmodelTools:Equip() -- Called by Tool.Equipped.
	local humanoid = getEquippingHumanoid() -- Nil means equipping isn't allowed right now.
	if humanoid == nil then
		self.toolObj.Parent = plr.Backpack -- Hand the tool back instead of leaving it held without a viewmodel.
		return -- The Unequipped event this triggers exits at UnEquip's guard.
	end

	initializeEquipState(self, humanoid) -- Fresh state before any module runs.
	UIS.MouseIconEnabled = false -- The HUD draws its own crosshair.

	viewmodelArmsModule.onToolEquipped(self) -- First, because later modules read the viewmodel and tool model it sets up.
	weaponHUDModule.newHudUI(self) -- Creates self.hudUI.
	weaponJammingModule.weaponJammedUI(self) -- Jam indicator UI.
	grenadesModule.onEquip(self) -- Grenade setup for this tool.
	firemodeSelectModule.updateFiremodeText(self) -- Shows the current firemode.
	startMuzzlePointer(self) -- After the HUD, because it needs self.hudUI.

	bridgesList.AnimationReplicate:Fire({ -- Tells the server so other players see the idle pose.
		true, -- Play flag.
		self.toolSettingsModule.Animations.IdleR6, -- Idle animation stored under the tool's settings.
		IDLE_ANIMATION_PRIORITY, -- Lowest priority so actions override it.
		self.toolName, -- Identifies which tool the animation belongs to.
	})

	runCustomScenario(self, "onEquipp") -- Tool-specific equip hook; takes no arguments.

	bindRenderStep(self) -- Per-frame camera and viewmodel updates.
	bindInputConnections(self) -- Player input.
	bindCharacterConnections(self) -- Death and ragdoll events.
end

function viewmodelTools:UnEquip() -- Called by Tool.Unequipped and by the ragdoll handler.
	if not self.Equipped then return end -- Blocks the re-entrant call caused by reparenting the tool at the end.
	self.Equipped = false -- Cleared first so any re-entrant call exits at the guard.
	self.aiming = false -- Stops aiming state from leaking into the next equip.

	UIS.MouseIconEnabled = true -- Gives the system cursor back.
	isAimingValue.Value = false -- Resets the shared aim flag.
	isFiringValue.Value = false -- Resets the shared fire flag.
	cam.FieldOfView = globalSettings.defaultFOV -- Aiming changes the FOV, so it is restored explicitly.

	paralaxScopeModule.onToolUnEquipped(self.toolModel) -- Lets the scope module clean up its effects.

	releaseEquippingCache(self) -- Before the viewmodel is destroyed, so the render step can't touch it.

	bridgesList.AnimationReplicate:Fire({ false, true, IDLE_ANIMATION_PRIORITY, self.toolName, true }) -- Tells the server to stop the idle pose.

	self.toolModel.Parent = self.toolObj -- Rescued first, because destroying the viewmodel destroys its descendants.
	self.viewmodel:Destroy() -- Removes the first-person arms and everything left on them.

	if self.toolObj.Parent ~= plr.Character then return end -- Already in the Backpack, nothing to move.

	self.toolObj.Parent = plr.Backpack -- Unequips the tool for real so Roblox stops treating it as held.
end

-- // Constructor
function viewmodelClient.newViewmodelTool(toolObj: Tool) -- Builds the controller object for one tool.
	local self = setmetatable({}, viewmodelTools) -- The metatable gives it Equip and UnEquip.

	self.bridgesList = bridgesList -- Exposed because the feature modules fire bridges through self.
	self.equippingCache = {} -- Collects everything Equip registers for UnEquip to release.
	self.toolObj = toolObj -- The Tool instance being controlled.
	self.toolValues = toolObj:FindFirstChild("ToolValues") -- Optional, so FindFirstChild instead of indexing.
	self.toolName = toolObj.Name -- Doubles as the key into ToolSettings.

	self.toolSettingsModule = viewmodelEngineFolder.Assets.ToolSettings[self.toolName] -- Looked up once and used for both data and assets.
	self.toolSettings = require(self.toolSettingsModule) -- The tool's configuration table.

	self.viewmodelValuesFolder = viewmodelValuesFolder -- Shared aim and fire values for the modules.
	self.movementFolder = movementFolder -- Movement values for the modules that react to the player's motion.

	if self.toolSettings.isWeapon or self.toolSettings.hasCaster then -- Only tools that shoot or cast need a server caster.
		self.uniqueID_casting = viewmodelEngineFolder.RemoteFunctions.AssignCaster:InvokeServer(toolObj) -- Yields until the server answers, so the id exists before firing.
	end

	toolObj.Equipped:Connect(function() -- A closure, because Equipped passes the mouse, which would land in self.
		self:Equip() -- Starts the equip flow.
	end)

	toolObj.Unequipped:Connect(function() -- Same reason for the closure.
		self:UnEquip() -- Starts the unequip flow.
	end)

	return self -- Handed back to whatever manages the tools.
end

-- // Initialization
local function createBoolValue(name, parent) -- Avoids repeating the BoolValue setup.
	local boolValue = Instance.new("BoolValue") -- Created without the deprecated parent argument.
	boolValue.Name = name -- Other scripts find it by name.
	boolValue.Parent = parent -- Parented after the properties are set.

	return boolValue -- Stored in the module-level locals.
end

local function createViewmodelValues() -- Creates the folder that holds the shared values.
	viewmodelValuesFolder = Instance.new("Folder") -- Container for the values.
	viewmodelValuesFolder.Name = "ViewmodelValues" -- Name other scripts look for.

	isAimingValue = createBoolValue("IsAiming", viewmodelValuesFolder) -- Aim flag.
	isFiringValue = createBoolValue("IsFiring", viewmodelValuesFolder) -- Fire flag.

	viewmodelValuesFolder.Parent = plr -- Parented last so listeners see the finished structure at once.
end

function viewmodelClient.initializeClientScript() -- Must run before any tool is created.
	createViewmodelValues() -- Sets up the shared values.

	plr.CharacterAdded:Connect(function() -- Dying while ragdolled never fires the "cleared" signal on the new character.
		viewmodelClient.canEquippTool = true -- Unlocks equipping so every life starts clean.
	end)
end

return viewmodelClient -- The module's public API.
