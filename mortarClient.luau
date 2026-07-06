-- // Services
local RS = game:GetService("RunService")
local UIS = game:GetService("UserInputService")

-- // Idents
local plr = game.Players.LocalPlayer
local cam = workspace.CurrentCamera

local viewmodelClient = require(game.ReplicatedStorage.ViewmodelEngine.viewmodelClient_cm)
local mortarHudModule = require(script.hudUI)
local mortarReplicationModule = require(script.mortarReplication_cm)

-- // BridgeNet2
local bridgeNet = require(game.ReplicatedStorage.Resources.BridgeNet2)
local mortarBridge = bridgeNet.ReferenceBridge("MortarBridge")
local mortarReplicationBridge = bridgeNet.ReferenceBridge("MortarReplicationBridge")

-- // Values
local mortarCache = {}

-- // Code
local mortar_cm = {}

local function listenToBridges()
	mortarBridge:Connect(function(packedData)
		if packedData[1] == true then
			-- || Entered Mortar
			mortar_cm.onMortarEntered(unpack(packedData))
			
		elseif packedData[1] == false then
			-- || Exited Mortar
			mortar_cm.onMortarExit(unpack(packedData))
		end
	end) 
	
	mortarReplicationBridge:Connect(function(packedData)
		mortarReplicationModule.onBridgeRecieved(unpack(packedData))
	end)
end

function mortar_cm.onMortarEntered(mortarStatus : boolean, mortarSeat : VehicleSeat)
	-- || Values
	local cameraPart = mortarSeat.Parent.CamPart
	
	-- || Tool Equippment
	if viewmodelClient.currentEquippedSelf then viewmodelClient.currentEquippedSelf:UnEquip() end
	viewmodelClient.canEquippTool = false
	
	-- || Camera
	cam.CameraType = Enum.CameraType.Scriptable
	--plr.CameraMode = Enum.CameraMode.Classic
	
	-- || HUD UI
	local hudUI = mortarHudModule.createHUD()
	
	-- || Connections
	local renderStepCon = RS.RenderStepped:Connect(function(dt)
		-- || Calling Functions
		require(script.cameraPlacer)(cameraPart)
		mortarHudModule.updateHUD(hudUI, mortarSeat)
	end)
	
	local inpBeganCon = UIS.InputBegan:Connect(function(input, gpe)
		--if gpe then return end
		
		-- || Values
		local globalKeybinds = require(game.ReplicatedStorage.GlobalKeybinds)
		
		-- || Check
		if globalKeybinds.isInputMatching(input, globalKeybinds["Fire Mortar"][globalKeybinds.usingType()]) then
			mortarBridge:Fire()
		end
	end)
	
	-- || Caching
	table.insert(mortarCache, hudUI)
	table.insert(mortarCache, renderStepCon)
	table.insert(mortarCache, inpBeganCon)
end

function mortar_cm.onMortarExit()
	-- || Clearing Cache
	for _, cacheObj in pairs(mortarCache) do
		pcall(function() cacheObj:Disconnect() end)
		pcall(function() coroutine.close(cacheObj) end)
		pcall(function() cacheObj:Destroy() end)
	end
	
	-- || Placing Camera
	cam.CameraType = Enum.CameraType.Custom
	
	-- || Allowing equipping
	viewmodelClient.canEquippTool = true
end

function mortar_cm.initializeClientScript()
	listenToBridges()
end

return mortar_cm
