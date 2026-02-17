--[[
	Units_Client.lua
	Author: FatherMortis

	- Uses existing project modules:
		- ReplicatedStorage.Modules.Spring (and Spring.Usage)
		- ReplicatedStorage.Modules.QuickFunctions (OpenAndClose, QuickFunctions)
		- script.Helper
		- script.Options (UnitOptions)
]]

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

--// Player refs
local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainGui = PlayerGui:WaitForChild("MainGui")

--// Replicated refs (cache long paths once)
local Assets = ReplicatedStorage:WaitForChild("Assets")
local Remotes = Assets:WaitForChild("Remotes")
local Settings = ReplicatedStorage:WaitForChild("Settings")

local UnitsAssets = Assets:WaitForChild("Units")
local Animations = Assets:WaitForChild("Animations")
local Objects = Assets:WaitForChild("Objects")

local UnitsOptionsHandler = Remotes:WaitForChild("UnitOptionsHandler") -- kept for parity; used by other modules

--// UI refs
local Windows = MainGui:WaitForChild("Windows")
local Units_Window = Windows:WaitForChild("Units")

local Samples = MainGui:WaitForChild("Samples")
local Unit_Showcase = MainGui:WaitForChild("UnitShowcase")

local UnitsMain = Units_Window:WaitForChild("Main")
local Unit_Slots_Holder = UnitsMain.Base.Slots
local SearchBox = Units_Window.Search.Input

local unitTip = UnitsMain:WaitForChild("UnitTip")
local unitButtonTip = UnitsMain:WaitForChild("UnitButtonTip")

--// Options buttons
local Options = unitButtonTip.Options.ScrollingFrame
local equipButton = Options.Equip
local viewButton = Options.View
local cancelButton = Options.Cancel
local lockButton = Options.Lock

--// UI Buttons
local UIOptions = Units_Window:WaitForChild("BTNs"):WaitForChild("Content")
local UnequipAllButton = UIOptions.UnequipAll

--// Modules
local Spring = require(ReplicatedStorage.Modules:WaitForChild("Spring"))
local SpringUsage = require(ReplicatedStorage.Modules:WaitForChild("Spring"):WaitForChild("Usage"))
local OpenAndClose = require(ReplicatedStorage.Modules:WaitForChild("QuickFunctions"):WaitForChild("OpenAndClose"))
local QuickFunctions = require(ReplicatedStorage.Modules:WaitForChild("QuickFunctions"))
local Helper = require(script.Helper)
local UnitOptions = require(script.Options)

--// Constants
local DESIGN_RES = Vector2.new(1920, 1080)
local X_OFFSET_PX = 100
local Y_OFFSET_PX = 180

local MaxEquipSlots = Settings:GetAttribute("MaxEquipSlots") or 0

--// Debugger
-- This logger is intentionally lightweight:
-- - It adds consistent prefixes so logs are searchable in the output.
local DEBUG_ENABLED = false

local function debugPrint(...)
	if not DEBUG_ENABLED then
		return
	end
	print("[Units_Client]", ...)
end

local function debugWarn(...)
	if not DEBUG_ENABLED then
		return
	end
	warn("[Units_Client]", ...)
end

--// State
local Units_Client = {}
local CurrentlySelected: GuiObject? = nil
local SelectedPosConn: RBXScriptConnection? = nil

local SlotConnections: { [Instance]: RBXScriptConnection } = {}

--// Rarity / Type visual definitions
local RarityProperties = {
	Rare = { Order = 2, Color = Color3.fromRGB(0, 170, 255) },
	Epic = { Order = 3, Color = Color3.fromRGB(114, 57, 171) },
	Legendary = { Order = 4, Color = Color3.fromRGB(255, 220, 24) },
	Mythic = { Order = 5, Color = Color3.fromRGB(255, 0, 255) },
}

local UnitTypeProperties = {
	Roaming = { Order = 2, Color = Color3.fromRGB(0, 170, 255) },
	Stationary = { Order = 3, Color = Color3.fromRGB(114, 57, 171) },
	Guardian = { Order = 4, Color = Color3.fromRGB(255, 85, 0) },
}

--// Color helpers
local function lightenColor(color: Color3, factor: number): Color3
	return color:Lerp(Color3.new(1, 1, 1), factor)
end

local function darkenColor(color: Color3, factor: number): Color3
	factor = math.clamp(factor, 0, 1)
	return Color3.new(color.R * (1 - factor), color.G * (1 - factor), color.B * (1 - factor))
end

local function getRarityOrder(rarity: string): number
	local props = RarityProperties[rarity]
	return props and props.Order or 1
end

--// UI movement helpers
local function springToHudState()
	debugPrint("springToHudState()")
	SpringUsage:LaunchSpring(MainGui:WaitForChild("Buttons"), 1, 3, { Position = MainGui.Buttons:GetAttribute("Show") }, true)
	SpringUsage:LaunchSpring(MainGui:WaitForChild("HUD"), 1, 3, { Position = MainGui.HUD:GetAttribute("Show") }, true)
	SpringUsage:LaunchSpring(MainGui:WaitForChild("OtherButtons"), 1, 3, { Position = MainGui.OtherButtons:GetAttribute("Show") }, true)
	SpringUsage:LaunchSpring(Units_Window, 0.45, 3, { Position = Units_Window:GetAttribute("Show") }, true)
end

local function springToSelectedState()
	debugPrint("springToSelectedState()")
	SpringUsage:LaunchSpring(MainGui:WaitForChild("Buttons"), 1, 3, { Position = MainGui.Buttons:GetAttribute("Hide") }, true)
	SpringUsage:LaunchSpring(MainGui:WaitForChild("HUD"), 1, 3, { Position = MainGui.HUD:GetAttribute("Selected") }, true)
	SpringUsage:LaunchSpring(MainGui:WaitForChild("OtherButtons"), 1, 3, { Position = MainGui.OtherButtons:GetAttribute("Hide") }, true)
	SpringUsage:LaunchSpring(Units_Window, 0.45, 3, { Position = Units_Window:GetAttribute("Selected") }, true)
end

--// Gradient loop manager
local activeGradientLoop = {
	task = nil :: thread?,
	cancel = nil :: (() -> ())?
}

local function StartGradientLoop(gradientMap: { UIGradient }, speed: number): (() -> ())
	if activeGradientLoop.task then
		debugPrint("Cancelling existing gradient loop")
		task.cancel(activeGradientLoop.task)
		activeGradientLoop.task = nil
	end

	for _, gradient in ipairs(gradientMap) do
		if gradient and gradient:IsDescendantOf(game) then
			gradient.Offset = Vector2.new(-1.8, 0)
		end
	end

	activeGradientLoop.task = task.spawn(function()
		debugPrint("Gradient loop started; gradients:", #gradientMap)
		while Units_Window:IsDescendantOf(game) and Units_Window.Visible do
			local tweens = table.create(#gradientMap)

			for i, gradient in ipairs(gradientMap) do
				if gradient and gradient:IsDescendantOf(game) then
					local tween = TweenService:Create(
						gradient,
						TweenInfo.new(speed, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut),
						{ Offset = Vector2.new(2.5, 0) }
					)
					tween:Play()
					tweens[i] = tween
				end
			end

			if tweens[1] then
				local ok, err = pcall(function()
					tweens[1].Completed:Wait()
				end)
				if not ok then
					debugWarn("Gradient loop interrupted:", err)
					break
				end
			else
				task.wait(speed)
			end

			for _, gradient in ipairs(gradientMap) do
				if gradient and gradient:IsDescendantOf(game) then
					gradient.Offset = Vector2.new(-1.8, 0)
				end
			end
		end
		debugPrint("Gradient loop ended (window hidden or destroyed)")
	end)

	local function cancel()
		if activeGradientLoop.task then
			debugPrint("Gradient loop cancelled")
			task.cancel(activeGradientLoop.task)
			activeGradientLoop.task = nil
		end
	end

	activeGradientLoop.cancel = cancel
	return cancel
end

--// Data helpers
local function getInventory(KeptData)
	return KeptData and KeptData.Units and KeptData.Units.Inventory
end

local function getUnitFolderFromSlot(KeptData, slot: Instance): Instance?
	local inv = getInventory(KeptData)
	if not inv then
		return nil
	end
	return inv:FindFirstChild(slot.Name)
end

local function isUnitEquipped(KeptData, unitFolder: Instance): boolean
	if not KeptData or not KeptData.Units or not KeptData.Units.Equipped then
		return false
	end

	for i = 1, MaxEquipSlots do
		local slotName = "Unit" .. tostring(i)
		if KeptData.Units.Equipped:GetAttribute(slotName) == unitFolder.Name then
			return true
		end
	end

	return false
end

--// Selection helpers
local function clearSelectionVisuals(selectedSlot: GuiObject)
	selectedSlot:SetAttribute("CurrentlySelected", false)

	if selectedSlot:FindFirstChild("SelectedOverlay") then
		selectedSlot.SelectedOverlay.Visible = false
	end
	if selectedSlot:FindFirstChild("Focus") then
		selectedSlot.Focus.Visible = false
	end

	selectedSlot.ZIndex = 1
end

local function applySelectionVisuals(selectedSlot: GuiObject)
	selectedSlot:SetAttribute("CurrentlySelected", true)

	if selectedSlot:FindFirstChild("SelectedOverlay") then
		selectedSlot.SelectedOverlay.Visible = true
	end
	if selectedSlot:FindFirstChild("Focus") then
		selectedSlot.Focus.Visible = true
	end

	selectedSlot.ZIndex = 2
end

local function hideUnitPopups()
	Unit_Showcase.Visible = false
	unitTip.Visible = false
	unitButtonTip.Visible = false
end

local function deselectCurrentUnit()
	if not CurrentlySelected then
		return
	end

	debugPrint("Deselecting:", CurrentlySelected.Name)

	Helper:DeselectUnit(CurrentlySelected, nil, CurrentlySelected)
	clearSelectionVisuals(CurrentlySelected)

	CurrentlySelected = nil
	hideUnitPopups()
	springToHudState()

	if SelectedPosConn then
		SelectedPosConn:Disconnect()
		SelectedPosConn = nil
	end
end

--// Showcase
function Units_Client:UpdateShowcase(unitFolder: Instance)
	if not unitFolder then
		return
	end

	local uFName = unitFolder:GetAttribute("Name") or unitFolder.Name
	local unitAsset = UnitsAssets:FindFirstChild(uFName)
	if not unitAsset or not unitAsset:FindFirstChild("Model") then
		debugWarn("Missing unit asset/model for:", uFName)
		return
	end

	debugPrint("Showcase update for:", uFName)

	Unit_Showcase.Visible = true
	springToSelectedState()

	task.spawn(function()
		Unit_Showcase.ViewportFrame.ImageColor3 = Color3.new(0, 0, 0)
		SpringUsage:LaunchSpring(Unit_Showcase.ViewportFrame, 1, 0.1, { ImageColor3 = Color3.new(1, 1, 1) }, true)
	end)

	Unit_Showcase.ViewportFrame.UIScale.Scale = Unit_Showcase.ViewportFrame:GetAttribute("Default")
	SpringUsage:LaunchSpring(Unit_Showcase.ViewportFrame.UIScale, 0.45, 3, { Scale = 1 }, true)

	local world = Unit_Showcase.ViewportFrame.WorldModel
	local oldRig = world:FindFirstChild("Rig")
	if oldRig then
		oldRig:Destroy()
	end

	local unitModel = unitAsset.Model:Clone()
	unitModel:ScaleTo(1)
	unitModel.PrimaryPart = unitModel:WaitForChild("HumanoidRootPart")
	unitModel.Name = "Rig"
	unitModel.Parent = world

	-- Align to the world anchor rig if it exists
	local anchor = world:FindFirstChild("Rig")
	if anchor and anchor:FindFirstChild("PrimaryPart") then
		unitModel:PivotTo(anchor.PrimaryPart.CFrame)
	elseif anchor and anchor:FindFirstChild("HumanoidRootPart") then
		unitModel:PivotTo(anchor.HumanoidRootPart.CFrame)
	end

	local humanoid = unitModel:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local idleAnim = Animations:FindFirstChild("Idle")
		if idleAnim then
			humanoid:LoadAnimation(idleAnim):Play()
		end
	end
end

--// Tooltip placement + data
local function getRelativeScalePos(refUI: GuiObject, container: GuiObject, xOffsetPx: number, yOffsetPx: number)
	-- Convert absolute screen coordinates into container-relative Scale.
	local screenX = refUI.AbsolutePosition.X + refUI.AbsoluteSize.X + xOffsetPx
	local screenY = refUI.AbsolutePosition.Y + yOffsetPx

	local localX = screenX - container.AbsolutePosition.X
	local localY = screenY - container.AbsolutePosition.Y

	return localX / container.AbsoluteSize.X, localY / container.AbsoluteSize.Y
end

function Units_Client:OptionsTip(selectedSlot: GuiObject, tip: GuiObject)
	if not selectedSlot or not tip then
		return
	end

	local selectingSlot = Player:GetAttribute("SelectingProfileSlot")
	equipButton.Visible = not selectingSlot

	local unitFolder = getUnitFolderFromSlot(self.KeptData, selectedSlot)
	if not unitFolder then
		return
	end

	local unitNameKey = unitFolder:GetAttribute("Name") or unitFolder.Name
	local unitAsset = UnitsAssets:FindFirstChild(unitNameKey)
	if not unitAsset then
		debugWarn("Missing unit asset for tooltip:", unitNameKey)
		return
	end

	tip.UnitName.Text = unitAsset:GetAttribute("DisplayName") or "Unknown"
	tip.Level.Text = "Lv. " .. tostring(unitFolder:GetAttribute("Level") or 1)

	local rarity = unitAsset:GetAttribute("Rarity") or "Rare"
	tip.Rarity.Text = rarity

	do
		local rarityProps = RarityProperties[rarity]
		if rarityProps then
			local base = rarityProps.Color
			local light = lightenColor(base, 0.5)
			local dark = darkenColor(base, 0.15)

			local grad = ColorSequence.new({
				ColorSequenceKeypoint.new(0, light),
				ColorSequenceKeypoint.new(1, base),
			})

			tip.Rarity.UIGradient.Color = grad
			tip.Rarity.UIStroke.Color = dark
			tip.UIStroke.UIGradient.Color = grad
		end
	end

	local unitType = unitAsset:GetAttribute("UnitType") or "Roaming"
	tip.UnitType.Text = unitType

	do
		local typeProps = UnitTypeProperties[unitType]
		if typeProps then
			local base = typeProps.Color
			local light = lightenColor(base, 0.5)
			local dark = darkenColor(base, 0.15)

			local grad = ColorSequence.new({
				ColorSequenceKeypoint.new(0, light),
				ColorSequenceKeypoint.new(1, base),
			})

			tip.UnitType.UIGradient.Color = grad
			tip.UnitType.UIStroke.Color = dark
		end
	end

	local function updateTip()
		if not selectedSlot:IsDescendantOf(game) then
			return
		end
		local sx, sy = getRelativeScalePos(selectedSlot, UnitsMain, X_OFFSET_PX, Y_OFFSET_PX)
		tip.Position = UDim2.fromScale(sx, sy)
	end

	if SelectedPosConn then
		SelectedPosConn:Disconnect()
		SelectedPosConn = nil
	end

	SelectedPosConn = selectedSlot:GetPropertyChangedSignal("AbsolutePosition"):Connect(updateTip)
	updateTip()
end

--// Equip button visuals
function Units_Client:UpdateEquipButtonState(unitFolder: Instance)
	if not unitFolder or not self.KeptData then
		return
	end

	local equipped = isUnitEquipped(self.KeptData, unitFolder)
	if equipped then
		equipButton.Base.UIGradient.Color = equipButton:GetAttribute("Unequip")
		equipButton.Text.Text = "Unequip"
	else
		equipButton.Base.UIGradient.Color = equipButton:GetAttribute("Equip")
		equipButton.Text.Text = "Equip"
	end
end

--// Selection toggle
function Units_Client:ToggleUnit(selectedSlot: GuiObject)
	if not selectedSlot then
		return
	end

	-- Helper:DeselectUnit returns true when it handles a deselect (likely same-slot toggle)
	if Helper:DeselectUnit(selectedSlot, nil, CurrentlySelected) == true then
		debugPrint("ToggleUnit -> deselect by helper:", selectedSlot.Name)
		CurrentlySelected = nil
		hideUnitPopups()
		springToHudState()
		return
	end

	debugPrint("Selected:", selectedSlot.Name)

	CurrentlySelected = selectedSlot
	applySelectionVisuals(selectedSlot)

	local unitFolder = getUnitFolderFromSlot(self.KeptData, selectedSlot)
	if unitFolder then
		self:UpdateEquipButtonState(unitFolder)
	end

	self:OptionsTip(selectedSlot, unitButtonTip)
	unitTip.Visible = false
	unitButtonTip.Visible = true
end

--// Slot viewport rendering
function Units_Client:DefineSlot(unitFolder: Instance?, Unit_Slot: Instance, isBottomBar: boolean, isShowcase: boolean?)
	local unitModel: Model

	if unitFolder then
		local uFName = unitFolder:GetAttribute("Name") or unitFolder.Name
		local unitAsset = UnitsAssets:FindFirstChild(uFName)
		if unitAsset and unitAsset:FindFirstChild("Model") then
			unitModel = unitAsset.Model:Clone()
		else
			unitModel = Objects.Rig:Clone()
		end
	else
		unitModel = Objects.Rig:Clone()
	end

	local location = Unit_Slot.ViewportFrame.WorldModel
	if isShowcase then
		location = Unit_Slot.WorldModel
	end

	unitModel.Name = "Rig"
	unitModel:ScaleTo(1)
	unitModel.PrimaryPart = unitModel:WaitForChild("HumanoidRootPart")
	unitModel.Parent = location

	-- Align to existing anchor rig (we destroy it afterwards).
	local anchorRig = location:FindFirstChild("Rig")
	if anchorRig and anchorRig:FindFirstChild("PrimaryPart") then
		unitModel:PivotTo(anchorRig.PrimaryPart.CFrame)
	elseif anchorRig and anchorRig:FindFirstChild("HumanoidRootPart") then
		unitModel:PivotTo(anchorRig.HumanoidRootPart.CFrame)
	end

	local humanoid = unitModel:FindFirstChildOfClass("Humanoid")
	if humanoid and Animations:FindFirstChild("Idle") then
		humanoid:LoadAnimation(Animations.Idle):Play()
	end

	if anchorRig then
		anchorRig:Destroy()
	end

	return isBottomBar
end

--// Slot click binding
function Units_Client:BindSlot(unitFolder: Instance?, Unit_Slot: GuiObject, isBottomBar: boolean, canRegularOpen: boolean?)
	if SlotConnections[Unit_Slot] then
		SlotConnections[Unit_Slot]:Disconnect()
		SlotConnections[Unit_Slot] = nil
	end

	local button = Unit_Slot:FindFirstChild("TextButton", true)
	if not button or not button:IsA("GuiButton") then
		return
	end

	if unitFolder then
		SlotConnections[Unit_Slot] = button.MouseButton1Up:Connect(function()
			local realSlot = Unit_Slot

			if isBottomBar then
				local invSlot = Unit_Slots_Holder:FindFirstChild(unitFolder.Name)
				if invSlot then
					realSlot = invSlot
				end
			end

			if CurrentlySelected == realSlot then
				debugPrint("Clicked selected slot again -> deselect:", realSlot.Name)
				self:ToggleUnit(realSlot)
				CurrentlySelected = nil
				return
			end

			if isBottomBar then
				debugPrint("Bottom bar click -> opening Units window")
				QuickFunctions:OpenWindow(MainGui.Buttons.Units)
			end

			self:ToggleUnit(realSlot)
			self:UpdateShowcase(unitFolder)
			CurrentlySelected = realSlot
		end)

		return
	end

	if not canRegularOpen then
		return
	end

	SlotConnections[Unit_Slot] = button.MouseButton1Up:Connect(function()
		if not isBottomBar then
			return
		end
		if Units_Window.Visible then
			return
		end

		debugPrint("Clicked empty bottom bar slot -> opening Units window")
		CurrentlySelected = nil
		QuickFunctions:OpenWindow(MainGui.Buttons.Units)
	end)
end

--// Inventory slot creation/update
function Units_Client:CreateUnitSlot(unitFolder: Instance)
	if Unit_Slots_Holder:FindFirstChild(unitFolder.Name) then
		return
	end

	local Unit_Slot = Samples.sampleUnitSlot:Clone()
	Unit_Slot.Name = unitFolder.Name
	Unit_Slot.Visible = true
	Unit_Slot.Parent = Unit_Slots_Holder
	Unit_Slot:SetAttribute("UnitName", unitFolder:GetAttribute("UnitName"))

	self:DefineSlot(unitFolder, Unit_Slot, false)
	self:BindSlot(unitFolder, Unit_Slot, false)
	self:UpdateUnitSlot(unitFolder, Unit_Slot)
end

function Units_Client:UpdateUnitSlot(unitFolder: Instance, overrideSlot: GuiObject?)
	if not unitFolder then
		return
	end

	local Unit_Slot = overrideSlot or Unit_Slots_Holder:FindFirstChild(unitFolder.Name)
	if not Unit_Slot then
		return
	end

	local unitNameKey = unitFolder:GetAttribute("Name") or unitFolder.Name
	local unitAsset = UnitsAssets:FindFirstChild(unitNameKey)

	local displayName = unitAsset and unitAsset:GetAttribute("DisplayName") or "Unknown"
	local level = unitFolder:GetAttribute("Level") or 1
	local rarity = unitAsset and unitAsset:GetAttribute("Rarity") or "Rare"
	local equipped = unitFolder:GetAttribute("Equipped")

	local NameText = Unit_Slot:FindFirstChild("NameText", true)
	local LevelText = Unit_Slot:FindFirstChild("LevelText", true)
	local CrestStroke = Unit_Slot:FindFirstChild("MiddleStroke", true)
		and Unit_Slot.MiddleStroke:FindFirstChild("UIStroke")
	local Base = Unit_Slot:FindFirstChild("Base", true)

	if NameText then NameText.Text = displayName end
	if LevelText then LevelText.Text = tostring(level) end

	Unit_Slot.LayoutOrder = 100 - getRarityOrder(rarity)

	local rarityProps = RarityProperties[rarity]
	if rarityProps and Base then
		local baseColor = rarityProps.Color
		local light = lightenColor(baseColor, 0.5)

		local grad = ColorSequence.new({
			ColorSequenceKeypoint.new(0, light),
			ColorSequenceKeypoint.new(1, baseColor),
		})

		Base.ImageColor3 = darkenColor(baseColor, 0.3)
		Base.BackgroundColor3 = darkenColor(baseColor, 0.9)

		if Unit_Slot:FindFirstChild("UIGradient") then
			Unit_Slot.UIGradient.Color = grad
		end

		if Unit_Slot:FindFirstChild("GradientOverlay") and Unit_Slot.GradientOverlay:FindFirstChild("UIGradient") then
			local overlayGrad = Settings:WaitForChild("RarityOverlays"):GetAttribute(rarity)
			if overlayGrad then
				Unit_Slot.GradientOverlay.UIGradient.Color = overlayGrad
				if CrestStroke and CrestStroke:FindFirstChild("UIGradient") then
					CrestStroke.UIGradient.Color = overlayGrad
				end
			end
		end
	end

	-- Equipped highlight is only meaningful in the inventory list.
	if overrideSlot then
		return
	end

	if equipped then
		Unit_Slot.LayoutOrder = -9999
		if Unit_Slot:FindFirstChild("Tick") then
			Unit_Slot.Tick.Visible = true
		end
	else
		Unit_Slot.LayoutOrder = 100 - getRarityOrder(rarity)
		if Unit_Slot:FindFirstChild("Tick") then
			Unit_Slot.Tick.Visible = false
		end
	end
end

function Units_Client:RemoveUnitSlot(unitFolder: Instance)
	local slot = Unit_Slots_Holder:FindFirstChild(unitFolder.Name)
	if slot then
		slot:Destroy()
	end
end

--// Search filtering
function Units_Client:ApplySearchFilter()
	local query = string.lower(SearchBox.Text or "")

	for _, slot in ipairs(Unit_Slots_Holder:GetChildren()) do
		if not slot:IsA("GuiObject") then
			continue
		end
		if slot.Name == "UIListLayout" then
			continue
		end

		local label = slot:FindFirstChild("NameText", true)
		local name = label and string.lower(label.Text) or ""
		slot.Visible = (query == "") or (name:find(query, 1, true) ~= nil)
	end
end

--// Bottom bar syncing helpers
local function setBottomBarEmptyVisual(currentSlot: Instance, isEmpty: boolean)
	local unitFrame = currentSlot:WaitForChild("Unit")
	unitFrame.ImageTransparency = isEmpty and 1 or 0
	unitFrame.Empty.Visible = isEmpty

	for _, child in ipairs(unitFrame:GetChildren()) do
		if child:HasTag("EmptyInvis") then
			child.Visible = not isEmpty
		end
	end
end

function Units_Client:_UpdateBottomBarSlot(KeptData, slotKey: string, input: any)
	local hudSlots = MainGui:WaitForChild("HUD"):WaitForChild("Slots")
	local currentSlot = hudSlots:WaitForChild(slotKey)
	local unitFrame = currentSlot:WaitForChild("Unit")

	if input == "Locked" then
		debugPrint("BottomBar", slotKey, "is Locked")
		currentSlot:SetAttribute("UnitName", "")
		return
	end

	if input == "Empty" or input == nil then
		debugPrint("BottomBar", slotKey, "is Empty")
		setBottomBarEmptyVisual(currentSlot, true)
		self:DefineSlot(nil, unitFrame, true)
		self:BindSlot(nil, unitFrame, true, true)
		currentSlot:SetAttribute("UnitName", "")
		return
	end

	local inv = getInventory(KeptData)
	if not inv then
		return
	end

	local unitFolder = inv:FindFirstChild(input)
	if not unitFolder then
		debugWarn("BottomBar", slotKey, "references missing unit:", tostring(input))
		setBottomBarEmptyVisual(currentSlot, true)
		currentSlot:SetAttribute("UnitName", "")
		return
	end

	debugPrint("BottomBar", slotKey, "->", unitFolder.Name)

	setBottomBarEmptyVisual(currentSlot, false)
	self:DefineSlot(unitFolder, unitFrame, true)
	self:BindSlot(unitFolder, unitFrame, true)
	self:UpdateUnitSlot(unitFolder, unitFrame)

	currentSlot:SetAttribute("UnitName", unitFolder:GetAttribute("UnitName") or "")
end

--// Click outside to deselect
local function clickedInsideTaggedGui(tagName: string, x: number, y: number): boolean
	for _, guiObject in ipairs(CollectionService:GetTagged(tagName)) do
		if not guiObject:IsA("GuiObject") then
			continue
		end
		if not guiObject.Visible then
			continue
		end

		local pos = guiObject.AbsolutePosition
		local size = guiObject.AbsoluteSize

		if x >= pos.X and x <= pos.X + size.X and y >= pos.Y and y <= pos.Y + size.Y then
			return true
		end
	end

	return false
end

--// Init
function Units_Client:Init(KeptData)
	self.KeptData = KeptData

	local Inventory = getInventory(KeptData)
	if not Inventory then
		debugWarn("Init called without KeptData.Units.Inventory")
		return
	end

	debugPrint("Init inventory size:", #Inventory:GetChildren())

	-- Initial inventory UI
	for _, unitFolder in ipairs(Inventory:GetChildren()) do
		self:CreateUnitSlot(unitFolder)
	end

	-- Keep UI synced with inventory changes
	Inventory.ChildAdded:Connect(function(unitFolder)
		debugPrint("Inventory ChildAdded:", unitFolder.Name)
		self:CreateUnitSlot(unitFolder)
	end)

	Inventory.ChildRemoved:Connect(function(unitFolder)
		debugPrint("Inventory ChildRemoved:", unitFolder.Name)
		self:RemoveUnitSlot(unitFolder)
	end)

	-- Bottom bar initial + live updates
	for i = 1, MaxEquipSlots do
		local key = "Unit" .. tostring(i)
		local current = KeptData.Units.Equipped:GetAttribute(key)
		self:_UpdateBottomBarSlot(KeptData, key, current)

		KeptData.Units.Equipped:GetAttributeChangedSignal(key):Connect(function()
			local nextVal = KeptData.Units.Equipped:GetAttribute(key)
			self:_UpdateBottomBarSlot(KeptData, key, nextVal)
		end)
	end

	-- Watch per-unit attributes (level & equipped)
	for _, unitFolder in ipairs(Inventory:GetChildren()) do
		unitFolder:GetAttributeChangedSignal("Level"):Connect(function()
			self:UpdateUnitSlot(unitFolder)
		end)

		unitFolder:GetAttributeChangedSignal("Equipped"):Connect(function()
			self:UpdateUnitSlot(unitFolder)
		end)
	end

	-- Search box -> filter + feedback sound
	SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		if SoundService:FindFirstChild("SFX") and SoundService.SFX:FindFirstChild("Key") then
			SoundService.SFX.Key:Play()
		end
		self:ApplySearchFilter()
	end)

	-- Window visibility -> gradient loop + cleanup
	Units_Window:GetPropertyChangedSignal("Visible"):Connect(function()
		if Units_Window.Visible then
			debugPrint("Units window opened")

			task.delay(0.05, function()
				local cached = {}

				for _, slot in ipairs(Unit_Slots_Holder:GetChildren()) do
					if slot:IsA("ImageLabel") then
						local overlayGrad = slot:FindFirstChild("GradientOverlay", true)
							and slot.GradientOverlay:FindFirstChild("UIGradient")

						local strokeGrad = slot:FindFirstChild("MiddleStroke", true)
							and slot.MiddleStroke:FindFirstChild("UIStroke")
							and slot.MiddleStroke.UIStroke:FindFirstChild("UIGradient")

						if overlayGrad then table.insert(cached, overlayGrad) end
						if strokeGrad then table.insert(cached, strokeGrad) end
					end
				end

				StartGradientLoop(cached, 2.5)
			end)

			return
		end

		debugPrint("Units window closed -> clearing selection")

		CurrentlySelected = nil
		Players:SetAttribute("SelectingProfileSlot", nil)

		if activeGradientLoop.cancel then
			activeGradientLoop.cancel()
		end

		if SelectedPosConn then
			SelectedPosConn:Disconnect()
			SelectedPosConn = nil
		end
	end)

	-- Option buttons
	equipButton.MouseButton1Click:Connect(function()
		if not CurrentlySelected then
			return
		end

		local unitFolder = getUnitFolderFromSlot(KeptData, CurrentlySelected)
		if not unitFolder then
			return
		end

		-- If unequipping, close selection to avoid stale state (UI says selected but no longer equipped).
		if isUnitEquipped(KeptData, unitFolder) then
			deselectCurrentUnit()
		end

		debugPrint("Equip toggle:", unitFolder.Name)
		UnitOptions:ToggleEquip(unitFolder, KeptData)
	end)

	viewButton.MouseButton1Click:Connect(function()
		if not CurrentlySelected then
			return
		end

		local unitFolder = getUnitFolderFromSlot(KeptData, CurrentlySelected)
		if not unitFolder then
			return
		end

		debugPrint("View:", unitFolder.Name)
		UnitOptions:ToggleView(unitFolder, KeptData, Units_Window)
	end)

	cancelButton.MouseButton1Click:Connect(function()
		if not CurrentlySelected then
			return
		end

		debugPrint("Cancel selection:", CurrentlySelected.Name)
		self:ToggleUnit(CurrentlySelected)
	end)

	lockButton.MouseButton1Click:Connect(function()
		if not CurrentlySelected then
			return
		end

		local unitFolder = getUnitFolderFromSlot(KeptData, CurrentlySelected)
		if not unitFolder then
			return
		end

		debugPrint("Lock toggle:", unitFolder.Name)
		UnitOptions:ToggleLock(unitFolder, KeptData, Units_Window)
	end)

	UnequipAllButton.MouseButton1Click:Connect(function()
		debugPrint("Unequip all")
		UnitOptions:UnequipAll(self.KeptData)
		deselectCurrentUnit()
	end)

	-- Click-outside deselect (tag-protected)
	UserInputService.InputEnded:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end

		local t = input.UserInputType
		if t ~= Enum.UserInputType.Touch and t ~= Enum.UserInputType.MouseButton1 then
			return
		end

		if not Units_Window.Visible then
			return
		end
		if not CurrentlySelected then
			return
		end

		local mouseLocation = UserInputService:GetMouseLocation()
		local x, y = mouseLocation.X, mouseLocation.Y

		local protected = clickedInsideTaggedGui("DeselectProtection", x, y)
		if protected then
			debugPrint("Click inside DeselectProtection -> ignoring")
			return
		end

		debugPrint("Click outside -> deselect")
		deselectCurrentUnit()
	end)
end

return Units_Client
