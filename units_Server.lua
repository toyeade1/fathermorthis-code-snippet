-- @ Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")
local GuiService = game:GetService("GuiService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Remotes = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Remotes")
local UnitsOptionsHandler = Remotes:WaitForChild("UnitOptionsHandler")

-- @ Player References
local Player = Players.LocalPlayer
local Mouse = Player:GetMouse()
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainGui = PlayerGui:WaitForChild("MainGui")

-- @ GUI References
local Samples = MainGui:WaitForChild("Samples")
local Windows = MainGui:WaitForChild("Windows")
local Units_Window = Windows:WaitForChild("Units")
local Unit_Slots_Holder = Units_Window.Main.Base.Slots
local Unit_Showcase = MainGui:WaitForChild("UnitShowcase")
local SearchBox = Units_Window.Search.Input
local toolTipParent = Units_Window:WaitForChild("Main")
local unitTip = toolTipParent:WaitForChild("UnitTip")
local unitButtonTip = toolTipParent:WaitForChild("UnitButtonTip")

-- @ Options/Buttons
local Options = unitButtonTip.Options.ScrollingFrame
local equipButton = Options.Equip
local viewButton = Options.View
local cancelButton = Options.Cancel
local lockButton = Options.Lock
--local selectButton = Options.Select

-- Options/UI Buttons
local UIOptions = Units_Window:WaitForChild("BTNs"):WaitForChild("Content")
local unequipAllButton = UIOptions.UnequipAll

-- @ Important Variables
local CurrentlySelected = nil
local SelectedPosConn = nil
local MaxEquipSlots = ReplicatedStorage.Settings:GetAttribute("MaxEquipSlots")

local SlotConnections = {} 
local UnitSlotsDictionary = {}
local PreviousUnitSlotsDictionary = {}

-- @ Modules
local Classes = ReplicatedStorage:WaitForChild("Classes")
local Modules = ReplicatedStorage:WaitForChild("Modules")

-- @ Requires
local Spring = require(ReplicatedStorage.Modules:WaitForChild("Spring"))
local SpringUsage = require(ReplicatedStorage.Modules:WaitForChild("Spring"):WaitForChild("Usage"))
local OpenAndClose = require(ReplicatedStorage.Modules:WaitForChild("QuickFunctions"):WaitForChild("OpenAndClose"))
local QuickFunctions = require(ReplicatedStorage.Modules:WaitForChild("QuickFunctions"))
local Helper = require(script.Helper)
local UnitOptions = require(script.Options)

-- @ ToolTip Stats
local DESIGN_RES = Vector2.new(1920, 1080)
local X_OFFSET_PX = 100
local Y_OFFSET_PX = 180
local X_OFF_SCALE = X_OFFSET_PX / DESIGN_RES.X
local Y_OFF_SCALE = Y_OFFSET_PX / DESIGN_RES.Y

-- @ Main Module
local Units_Client = {}

-- @ Rarity Definitions
local RarityProperties = {
	Rare = { Order = 2, Color = Color3.fromRGB(0, 170, 255) },
	Epic = { Order = 3, Color = Color3.fromRGB(114, 57, 171) },
	Legendary = { Order = 4, Color = Color3.fromRGB(255, 220, 24) },
	Mythic = { Order = 5, Color = Color3.fromRGB(255, 0, 255) },
}

-- @ UnitType Definitions
local UnitTypeProperties = {
	Roaming = { Order = 2, Color = Color3.fromRGB(0, 170, 255) },
	Stationary = { Order = 3, Color = Color3.fromRGB(114, 57, 171) },
	Guardian = { Order = 4, Color = Color3.fromRGB(255, 85, 0) },
}

-- @ Helper: Lighten Color
local function lightenColor(color, factor)
	return color:Lerp(Color3.new(1, 1, 1), factor)
end

-- @ Helper: Darken Color
local function darkenColor(color, factor)
	factor = math.clamp(factor, 0, 1)
	return Color3.new(color.R * (1 - factor), color.G * (1 - factor), color.B * (1 - factor))
end

-- @ Helper: Get Sort Order by Rarity
local function getRarityOrder(rarity)
	return RarityProperties[rarity] and RarityProperties[rarity].Order or 1
end

-- @ Helper: Deselect Current Unit
local function deselectCurrentUnit()
	if CurrentlySelected then
		Helper:DeselectUnit(CurrentlySelected, nil, CurrentlySelected)
		CurrentlySelected:SetAttribute("CurrentlySelected", false)
		CurrentlySelected.SelectedOverlay.Visible = false
		CurrentlySelected.Focus.Visible = false
		CurrentlySelected.ZIndex = 1
		CurrentlySelected = nil

		Unit_Showcase.Visible = false
		unitTip.Visible = false
		unitButtonTip.Visible = false
		
		local moveTarget = { Position = MainGui:WaitForChild("Buttons"):GetAttribute("Show") }
		SpringUsage:LaunchSpring(MainGui:WaitForChild("Buttons"), 1, 3, moveTarget, true)

		local moveTarget2 = { Position = MainGui:WaitForChild("HUD"):GetAttribute("Show") }
		SpringUsage:LaunchSpring(MainGui:WaitForChild("HUD"), 1, 3, moveTarget2, true)
		
		local moveTarget3 = { Position = MainGui:WaitForChild("OtherButtons"):GetAttribute("Show") }
		SpringUsage:LaunchSpring(MainGui:WaitForChild("OtherButtons"), 1, 3, moveTarget3, true)

		local startProps = { Position = Units_Window:GetAttribute("Show") }
		SpringUsage:LaunchSpring(Units_Window, 0.45, 3, startProps, true)
	end
end

-- @ Helper: This will allow for the gradient of each button to be looped.

local activeGradientLoop = {}

local function StartGradientLoop(gradientMap: { UIGradient }, speed: number)
	-- Cancel existing loop if active
	if activeGradientLoop.task then
		activeGradientLoop.task:Cancel()
		activeGradientLoop.task = nil
	end

	-- Set initial offset
	for _, gradient in ipairs(gradientMap) do
		if gradient and gradient:IsDescendantOf(game) then
			gradient.Offset = Vector2.new(-1.8, 0)
		end
	end

	activeGradientLoop.task = task.spawn(function()
		while Units_Window and Units_Window:IsDescendantOf(game) and Units_Window.Visible do
			local tweens = {}

			-- Tween all gradients forward
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

			-- Wait for one tween to complete (they're all same speed)
			local ok, err = pcall(function()
				if tweens[1] then
					tweens[1].Completed:Wait()
				else
					task.wait(speed)
				end
			end)

			-- Reset offsets after the tween
			for i, gradient in ipairs(gradientMap) do
				if gradient and gradient:IsDescendantOf(game) then
					if gradient.Parent:IsA("UIStroke") then
						local parent = gradient.Parent
						local props = {
							Color = gradient.Color,
							Rotation = gradient.Rotation,
							Transparency = gradient.Transparency,
						}
						gradient:Destroy()
						local newGradient = Instance.new("UIGradient")
						for prop, val in props do
							newGradient[prop] = val
						end
						newGradient.Offset = Vector2.new(-1.8, 0)
						newGradient.Parent = parent
						gradientMap[i] = newGradient
					else
						gradient.Offset = Vector2.new(-1.8, 0)
					end
				end
			end
		end

		activeGradientLoop.task = nil
	end)

	return function()
		if activeGradientLoop.task then
			activeGradientLoop.task:Cancel()
			activeGradientLoop.task = nil
		end
	end
end

-- @ Showcase Unit Preview
function Units_Client:UpdateShowcase(unitFolder)
	local uFName = unitFolder:GetAttribute("Name") or unitFolder.Name

	Unit_Showcase.Visible = true

	local moveTarget = {
		Position = MainGui:WaitForChild("Buttons"):GetAttribute("Hide")
	}
	SpringUsage:LaunchSpring(MainGui:WaitForChild("Buttons"), 1, 3, moveTarget, true)

	local moveTarget2 = {
		Position = MainGui:WaitForChild("HUD"):GetAttribute("Selected")
	}
	SpringUsage:LaunchSpring(MainGui:WaitForChild("HUD"), 1, 3, moveTarget2, true)
	
	local moveTarget3 = {
		Position = MainGui:WaitForChild("OtherButtons"):GetAttribute("Hide")
	}
	SpringUsage:LaunchSpring(MainGui:WaitForChild("OtherButtons"), 1, 3, moveTarget3, true)

	local startProps = { Position = Units_Window:GetAttribute("Selected") }
	SpringUsage:LaunchSpring(Units_Window, 0.45, 3, startProps, true)

	task.spawn(function()
		Unit_Showcase.ViewportFrame.ImageColor3 = Color3.new(0, 0, 0)
		
		local revealColor = {
			ImageColor3 = Color3.new(255, 255, 255)
		}
		SpringUsage:LaunchSpring(Unit_Showcase.ViewportFrame, 1, 0.1, revealColor, true)
	end)
	
	Unit_Showcase.ViewportFrame.UIScale.Scale = Unit_Showcase.ViewportFrame:GetAttribute("Default")
	SpringUsage:LaunchSpring(Unit_Showcase.ViewportFrame.UIScale, 0.45, 3, { Scale = 1 }, true)

	local Unit_To_View = ReplicatedStorage.Assets.Units[uFName].Model:Clone()
	Unit_To_View:ScaleTo(1)
	Unit_To_View.PrimaryPart = Unit_To_View:WaitForChild("HumanoidRootPart")
	Unit_To_View.Parent = Unit_Showcase.ViewportFrame.WorldModel
	Unit_To_View:PivotTo(Unit_Showcase.ViewportFrame.WorldModel.Rig.PrimaryPart.CFrame)
	Unit_To_View.Humanoid:LoadAnimation(ReplicatedStorage.Assets.Animations.Idle):Play()

	Unit_Showcase.ViewportFrame.WorldModel.Rig:Destroy()
	Unit_To_View.Name = "Rig"
end

-- @ Options Tip for Unit
function Units_Client:OptionsTip(selectedSlot, tip)
	local function getRelativeScalePos(refUI, container, xOffsetPx, yOffsetPx)
		local screenX = refUI.AbsolutePosition.X + refUI.AbsoluteSize.X + xOffsetPx
		local screenY = refUI.AbsolutePosition.Y + yOffsetPx

		local localX  = screenX - container.AbsolutePosition.X
		local localY  = screenY - container.AbsolutePosition.Y

		local sx = localX / container.AbsoluteSize.X
		local sy = localY / container.AbsoluteSize.Y
		
		local selectingSlot = Player:GetAttribute("SelectingProfileSlot")
		if selectingSlot then
			equipButton.Visible = false
		else
			equipButton.Visible = true
		end
		
		return sx, sy
		
	end

	local function updateTip()
		if not selectedSlot then return end
		local sx, sy = getRelativeScalePos(selectedSlot, toolTipParent, X_OFFSET_PX, Y_OFFSET_PX)
		tip.Position = UDim2.fromScale(sx, sy)
	end

	local function hookSlot()
		if SelectedPosConn then SelectedPosConn:Disconnect() end
		SelectedPosConn = selectedSlot:GetPropertyChangedSignal("AbsolutePosition"):Connect(updateTip)
		updateTip()
	end
	
	local UnitInInventory = self.KeptData.Units.Inventory[selectedSlot.Name]
	tip.UnitName.Text = ReplicatedStorage.Assets.Units[UnitInInventory:GetAttribute("Name")]:GetAttribute("DisplayName")
	tip.Level.Text = "Lv. " .. UnitInInventory:GetAttribute("Level")

	local Rarity = ReplicatedStorage.Assets.Units[UnitInInventory:GetAttribute("Name")]:GetAttribute("Rarity")
	tip.Rarity.Text = Rarity

	local RarityBaseColor = RarityProperties[Rarity].Color
	local LightColor = lightenColor(RarityBaseColor, 0.5)
	local DarkColor = darkenColor(RarityBaseColor, 0.15)

	local RarityGradient = ColorSequence.new{
		ColorSequenceKeypoint.new(0, LightColor),
		ColorSequenceKeypoint.new(1, RarityBaseColor)
	}

	tip.Rarity.UIGradient.Color = RarityGradient
	tip.Rarity.UIStroke.Color = DarkColor
	
	tip.UIStroke.UIGradient.Color = RarityGradient

	local UnitType = ReplicatedStorage.Assets.Units[UnitInInventory:GetAttribute("Name")]:GetAttribute("UnitType")
	
	local UnitTypeBaseColor = UnitTypeProperties[UnitType].Color
	local LightColor = lightenColor(UnitTypeBaseColor, 0.5)
	local DarkColor = darkenColor(UnitTypeBaseColor, 0.15)

	local UnitTypeGradient = ColorSequence.new{
		ColorSequenceKeypoint.new(0, LightColor),
		ColorSequenceKeypoint.new(1, UnitTypeBaseColor)
	}
	
	tip.UnitType.Text = UnitType
	tip.UnitType.UIGradient.Color = UnitTypeGradient
	tip.UnitType.UIStroke.Color = DarkColor
	
	hookSlot()
end

-- @ Update Equip Button State
function Units_Client:UpdateEquipButtonState(unitFolder, KeptData)
	local isEquipped = false

	for i = 1, MaxEquipSlots do
		if KeptData.Units.Equipped:GetAttribute("Unit"..i) == unitFolder.Name then
			isEquipped = true
			break
		end
	end

	-- @ toggle logic
	if isEquipped then
		equipButton.Base.UIGradient.Color = equipButton:GetAttribute("Unequip")
		equipButton.Text.Text = "Unequip"
	else
		equipButton.Base.UIGradient.Color = equipButton:GetAttribute("Equip")
		equipButton.Text.Text = "Equip"
	end
end

-- @ Select Unit
function Units_Client:ToggleUnit(selectedSlot)
	if Helper:DeselectUnit(selectedSlot, nil, CurrentlySelected) == true then 
		CurrentlySelected = nil 

		local moveTarget = {
			Position = MainGui:WaitForChild("Buttons"):GetAttribute("Show")
		}
		SpringUsage:LaunchSpring(MainGui:WaitForChild("Buttons"), 1, 3, moveTarget, true)

		local moveTarget2 = {
			Position = MainGui:WaitForChild("HUD"):GetAttribute("Show")
		}
		SpringUsage:LaunchSpring(MainGui:WaitForChild("HUD"), 1, 3, moveTarget2, true)
		
		local moveTarget3 = {
			Position = MainGui:WaitForChild("OtherButtons"):GetAttribute("Show")
		}
		SpringUsage:LaunchSpring(MainGui:WaitForChild("OtherButtons"), 1, 3, moveTarget3, true)

		local startProps = { Position = Units_Window:GetAttribute("Show") }
		SpringUsage:LaunchSpring(Units_Window, 0.45, 3, startProps, true)

		Unit_Showcase.Visible = false

		return
	end

	CurrentlySelected = selectedSlot

	self:OptionsTip(selectedSlot, unitButtonTip)

	selectedSlot:SetAttribute("CurrentlySelected", true)
	selectedSlot.SelectedOverlay.Visible = true
	selectedSlot.Focus.Visible = true
	selectedSlot.ZIndex = 2

--	toolTipParent.Visible = true

	local unitName = selectedSlot.Name
	local Inventory = self.KeptData.Units.Inventory
	local unitFolder = Inventory:FindFirstChild(unitName)

	if unitFolder then
		self:UpdateEquipButtonState(unitFolder, self.KeptData)
	end
	
	unitTip.Visible = false
	unitButtonTip.Visible = true
end

-- @ Define Slot with Unit Info From Folder
function Units_Client:DefineSlot(unitFolder, Unit_Slot, isBottomBar, isShowcase)
	local uFName = ""
	local Unit_To_View 
	
	if unitFolder then
		uFName = unitFolder:GetAttribute("Name") or unitFolder.Name
		Unit_To_View = ReplicatedStorage.Assets.Units[uFName].Model:Clone()
	else
		Unit_To_View = ReplicatedStorage.Assets.Objects.Rig:Clone()
	end
	
	local Location = Unit_Slot.ViewportFrame.WorldModel
	if isShowcase then Location = Unit_Slot.WorldModel end
	
	Unit_To_View.Name = "Rig"
	Unit_To_View:ScaleTo(1)
	Unit_To_View.PrimaryPart = Unit_To_View:WaitForChild("HumanoidRootPart")
	Unit_To_View.Parent = Location
	Unit_To_View:PivotTo(Location.Rig.PrimaryPart.CFrame)
	Unit_To_View.Humanoid:LoadAnimation(ReplicatedStorage.Assets.Animations.Idle):Play()

	Location.Rig:Destroy()
	
	return isBottomBar
end


function Units_Client:BindSlot(unitFolder, Unit_Slot, isBottomBar, canRegularOpen)
	if SlotConnections[Unit_Slot] then
		SlotConnections[Unit_Slot]:Disconnect()
		SlotConnections[Unit_Slot] = nil
	end

	if unitFolder ~= nil then
		local realSlot = isBottomBar
			and Unit_Slots_Holder:FindFirstChild(unitFolder.Name)
			or Unit_Slot
		
		SlotConnections[Unit_Slot] = Unit_Slot.TextButton.MouseButton1Up:Connect(function()
			local realSlot = isBottomBar
				and Unit_Slots_Holder:FindFirstChild(unitFolder.Name)
				or Unit_Slot

			local toggled = false

			if CurrentlySelected == realSlot then
				if toggled == false then toggled = true self:ToggleUnit(realSlot) end
				CurrentlySelected = nil
				return
			end

			if isBottomBar then
				QuickFunctions:OpenWindow(
					MainGui:WaitForChild("Buttons"):WaitForChild("Units")
				)
			end

			if toggled == false then toggled = true self:ToggleUnit(realSlot) end
			self:UpdateShowcase(unitFolder)
			CurrentlySelected = realSlot
		end)
	elseif canRegularOpen then
		SlotConnections[Unit_Slot] = Unit_Slot.TextButton.MouseButton1Up:Connect(function()
			if isBottomBar  and Units_Window.Visible == false then
				CurrentlySelected = nil
				
				QuickFunctions:OpenWindow(
					MainGui:WaitForChild("Buttons"):WaitForChild("Units")
				)
			end
		end)		
	end
end

-- @ Create Unit Slot From Folder
function Units_Client:CreateUnitSlot(unitFolder)
	if Unit_Slots_Holder:FindFirstChild(unitFolder.Name) then return end

	local Unit_Slot = Samples.sampleUnitSlot:Clone()
	Unit_Slot.Name = unitFolder.Name
	Unit_Slot.Visible = true
	Unit_Slot.Parent = Unit_Slots_Holder
	
	Unit_Slot:SetAttribute("UnitName", unitFolder:GetAttribute("UnitName"))

	self:BindSlot(unitFolder, Unit_Slot, self:DefineSlot(unitFolder, Unit_Slot))
	self:UpdateUnitSlot(unitFolder, Unit_Slot)
end

-- @ Update Unit Slot Info
function Units_Client:UpdateUnitSlot(unitFolder, BottomBarSlot)
	local Unit_Slot = Unit_Slots_Holder:FindFirstChild(unitFolder.Name)
	if not Unit_Slot and not BottomBarSlot then return end

	if BottomBarSlot then Unit_Slot = BottomBarSlot end
		
	local UnitName = ReplicatedStorage.Assets.Units[unitFolder:GetAttribute("Name")]:GetAttribute("DisplayName") or "Unknown"
	local Level = unitFolder:GetAttribute("Level") or 1
	local Rarity = ReplicatedStorage.Assets.Units[unitFolder:GetAttribute("Name")]:GetAttribute("Rarity") or "Rare"
	local Equipped = unitFolder:GetAttribute("Equipped")

	local NameText = Unit_Slot:FindFirstChild("NameText", true)
	local LevelText = Unit_Slot:FindFirstChild("LevelText", true)
	local Crest = Unit_Slot.MiddleStroke:WaitForChild("UIStroke")
	local Base = Unit_Slot:FindFirstChild("Base", true)

	if NameText then NameText.Text = UnitName end
	if LevelText then LevelText.Text = tostring(Level) end

	Unit_Slot.LayoutOrder = 100 - getRarityOrder(Rarity)

	local BaseColor = RarityProperties[Rarity].Color
	local LightColor = lightenColor(BaseColor, 0.5)
	local Gradient = ColorSequence.new{
		ColorSequenceKeypoint.new(0, LightColor),
		ColorSequenceKeypoint.new(1, BaseColor)
	}

	Base.ImageColor3 = darkenColor(BaseColor, 0.3)
	Base.BackgroundColor3 = darkenColor(BaseColor, 0.9)
	Crest.UIGradient.Color = ReplicatedStorage.Settings.RarityOverlays:GetAttribute(Rarity) -- Gradient
	Unit_Slot.UIGradient.Color = Gradient
	Unit_Slot.GradientOverlay.UIGradient.Color = ReplicatedStorage.Settings.RarityOverlays:GetAttribute(Rarity)
	
	-- @ Equipped Highlight
	if not BottomBarSlot then
		if Equipped then
			Unit_Slot.LayoutOrder = -9999
			Unit_Slot.Tick.Visible = true
		else
			Unit_Slot.LayoutOrder = 100 - getRarityOrder(Rarity)
			Unit_Slot.Tick.Visible = false
		end
	end
end

-- @ Remove Unit Slot
function Units_Client:RemoveUnitSlot(unitFolder)
	local slot = Unit_Slots_Holder:FindFirstChild(unitFolder.Name)
	if slot then slot:Destroy() end
end

-- @ Apply Search Filter on Unit Names
function Units_Client:ApplySearchFilter()
	local query = string.lower(SearchBox.Text)
	for _, slot in ipairs(Unit_Slots_Holder:GetChildren()) do
		if slot:IsA("GuiObject") and slot.Name ~= "UIListLayout" then
			local name = string.lower((slot:FindFirstChild("NameText") and slot.NameText.Text) or "")
			slot.Visible = (query == "") or name:find(query, 1, true) ~= nil
		end
	end
end

-- @ Set Up GUI and Real-Time Syncing
function Units_Client:Init(KeptData)
	self.KeptData = KeptData
	
	local Inventory = KeptData.Units.Inventory

	-- @ Initial Population
	for _, unitFolder in ipairs(Inventory:GetChildren()) do
		self:CreateUnitSlot(unitFolder)
	end

	-- @ Real-Time Add/Remove
	Inventory.ChildAdded:Connect(function(unitFolder)
		self:CreateUnitSlot(unitFolder)
	end)

	Inventory.ChildRemoved:Connect(function(unitFolder)
		self:RemoveUnitSlot(unitFolder)
	end)

	-- @ Function for Updating BottomBar
	local function UpdateBottomBar(input, slot)
		local currentSlot = MainGui:WaitForChild("HUD"):WaitForChild("Slots"):WaitForChild(slot)
		if input ~= "Empty" and input ~= "Locked" then
			currentSlot.Unit.ImageTransparency = 0
			currentSlot.Unit.Empty.Visible = false
			for _, UIInstance in pairs (currentSlot.Unit:GetChildren()) do
				if UIInstance:HasTag("EmptyInvis") then
					UIInstance.Visible = true
				end
			end
			
			local UnitFolder = Inventory[input]
			self:BindSlot(UnitFolder, currentSlot:WaitForChild("Unit"), self:DefineSlot(UnitFolder, currentSlot:WaitForChild("Unit"), true))
			self:UpdateUnitSlot(UnitFolder, currentSlot:WaitForChild("Unit"))
			
			currentSlot:SetAttribute("UnitName", UnitFolder:GetAttribute("UnitName"))
		elseif input == "Empty" then
			currentSlot.Unit.ImageTransparency = 1
			currentSlot.Unit.Empty.Visible = true
			for _, UIInstance in pairs (currentSlot.Unit:GetChildren()) do
				if UIInstance:HasTag("EmptyInvis") then
					UIInstance.Visible = false
				end
			end
			
			self:DefineSlot(nil, currentSlot.Unit, true)
			self:BindSlot(nil, currentSlot:WaitForChild("Unit"), true, true)
			
			currentSlot:SetAttribute("UnitName", "")
		elseif input == "Locked" then
			
			currentSlot:SetAttribute("UnitName", "")
		end
	end
	
	-- @ Initial BottomBar Population
	for i = 1, MaxEquipSlots do
		local UnitData_Slot_Input = KeptData.Units.Equipped:GetAttribute("Unit" .. tostring(i))
		UpdateBottomBar(UnitData_Slot_Input, "Unit" .. tostring(i))
		
		KeptData.Units.Equipped:GetAttributeChangedSignal("Unit" .. tostring(i)):Connect(function() -- @ Listen for Future BottomBar Updates
			local newInput = KeptData.Units.Equipped:GetAttribute("Unit" .. tostring(i))
			UpdateBottomBar(newInput, "Unit" .. tostring(i))
		end)
	end

	-- @ Listen to when Unit Window is invisible
	Units_Window:GetPropertyChangedSignal("Visible"):Connect(function()
		if Units_Window.Visible then
			task.delay(0.05, function()
				local cachedItems = {}
				for _, slot in Unit_Slots_Holder:GetChildren() do
					if slot:IsA("ImageLabel") then
						table.insert(cachedItems, slot.GradientOverlay.UIGradient)
						table.insert(cachedItems, slot.MiddleStroke.UIStroke.UIGradient)
					end
				end
				StartGradientLoop(cachedItems, 2.5)
			end)
		else
			CurrentlySelected = nil
			Players:SetAttribute("SelectingProfileSlot", nil)

			if activeGradientLoop.cancel then
				activeGradientLoop.cancel()
			end

			if SelectedPosConn then SelectedPosConn:Disconnect() end
		end
	end)

	-- @ Attribute Watchers
	for _, unitFolder in ipairs(Inventory:GetChildren()) do
		unitFolder:GetAttributeChangedSignal("Level"):Connect(function()
			self:UpdateUnitSlot(unitFolder)
		end)
		unitFolder:GetAttributeChangedSignal("Equipped"):Connect(function()
			self:UpdateUnitSlot(unitFolder)
		end)
	end

	-- @ Search Box Input
	SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		SoundService.SFX.Key:Play()
		self:ApplySearchFilter()
	end)
	
	-- @ Add Unit Option Connections
	local EquipButton = equipButton.MouseButton1Click:Connect(function()
		if CurrentlySelected then
			local unitName = CurrentlySelected.Name
			local Inventory = KeptData.Units.Inventory
			local unitFolder = Inventory:FindFirstChild(unitName)

			if unitFolder then
				local equipped = false
				local equippedSlot = nil

				for i = 1, MaxEquipSlots do
					local slotName = "Unit" .. tostring(i)
					local current = KeptData.Units.Equipped:GetAttribute(slotName)

					if current == unitFolder.Name then
						equipped = true
						equippedSlot = slotName
						break
					end
				end
				
				if equipped == true then deselectCurrentUnit() end
				
				UnitOptions:ToggleEquip(unitFolder, KeptData)
			end
		end
	end)
		
	local ViewButton = viewButton.MouseButton1Click:Connect(function()
		if CurrentlySelected then
			local unitName = CurrentlySelected.Name
			local Inventory = KeptData.Units.Inventory
			local unitFolder = Inventory:FindFirstChild(unitName)

			if unitFolder then
				UnitOptions:ToggleView(unitFolder, KeptData, Units_Window)
			end
		end
	end)
		
	local CancelButton = cancelButton.MouseButton1Click:Connect(function()
		if CurrentlySelected then
			local unitName = CurrentlySelected.Name
			local Inventory = KeptData.Units.Inventory
			local unitFolder = Inventory:FindFirstChild(unitName)

			if unitFolder then
				self:ToggleUnit(CurrentlySelected)
			end
		end
	end)
	
	local LockButton = lockButton.MouseButton1Click:Connect(function()
		if CurrentlySelected then
			local unitName = CurrentlySelected.Name
			local Inventory = KeptData.Units.Inventory
			local unitFolder = Inventory:FindFirstChild(unitName)

			if unitFolder then
				UnitOptions:ToggleLock(unitFolder, KeptData, Units_Window)
			end
		end
	end)
	
	local unequipAllButton = unequipAllButton.MouseButton1Click:Connect(function()
		UnitOptions:UnequipAll(Units_Client.KeptData)
		deselectCurrentUnit()
	end)
	
	UserInputService.InputEnded:Connect(function(input, gameProcessed)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			local function clickedInsideTaggedGui(tagName, x, y)
				for _, guiObject in ipairs(CollectionService:GetTagged(tagName)) do
					if guiObject:IsA("GuiObject") and guiObject.Visible then
						local pos = guiObject.AbsolutePosition
						local size = guiObject.AbsoluteSize
						if x >= pos.X and x <= pos.X + size.X and y >= pos.Y and y <= pos.Y + size.Y then
							return true
						end
					end
				end
				return false
			end

			local mouseLocation = UserInputService:GetMouseLocation()
			local x, y = mouseLocation.X, mouseLocation.Y
			local DeselectProtection = clickedInsideTaggedGui("DeselectProtection", x, y)

			if Units_Window.Visible and not DeselectProtection and CurrentlySelected then
				deselectCurrentUnit()
			end
		end
	end)
end

return Units_Client