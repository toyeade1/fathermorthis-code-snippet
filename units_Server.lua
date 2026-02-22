--[[
    Units_Client.lua
    Author: FatherMortis

    PURPOSE
    -------
    Client-side controller responsible for:

    • Inventory slot rendering
    • Unit selection logic
    • Bottom bar syncing
    • Showcase viewport control
    • Search filtering
    • Gradient animation management

    This script was intentionally structured for readability,
    scalability, and performance.
]]

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

--// Player
local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainGui = PlayerGui:WaitForChild("MainGui")

--// Replicated
local Assets = ReplicatedStorage:WaitForChild("Assets")
local UnitsAssets = Assets:WaitForChild("Units")
local Animations = Assets:WaitForChild("Animations")
local Settings = ReplicatedStorage:WaitForChild("Settings")

--// Modules
local SpringUsage = require(ReplicatedStorage.Modules.Spring.Usage)
local QuickFunctions = require(ReplicatedStorage.Modules.QuickFunctions)
local Helper = require(script.Helper)
local UnitOptions = require(script.Options)

--// Constants
local MAX_EQUIP_SLOTS = Settings:GetAttribute("MaxEquipSlots") or 0
local SHOWCASE_ROTATION_SPEED = math.rad(35)

--///////////////////////////////////////////////////////////
-- CLASS DEFINITION (Metatable Pattern)
--///////////////////////////////////////////////////////////

local UnitsClient = {}
UnitsClient.__index = UnitsClient

--///////////////////////////////////////////////////////////
-- CONSTRUCTOR
--///////////////////////////////////////////////////////////

function UnitsClient.new()
    local self = setmetatable({}, UnitsClient)

    self.CurrentlySelected = nil
    self.SelectedPosConn = nil
    self.SlotConnections = {}
    self.ShowcaseRotationConn = nil
    self.KeptData = nil

    return self
end

--///////////////////////////////////////////////////////////
-- UTILITY FUNCTIONS
--///////////////////////////////////////////////////////////

local function safeDisconnect(conn)
    if conn then
        conn:Disconnect()
    end
end

local function getInventory(keptData)
    return keptData and keptData.Units and keptData.Units.Inventory
end

local function getRarityOrder(rarity)
    local map = {
        Rare = 2,
        Epic = 3,
        Legendary = 4,
        Mythic = 5,
    }
    return map[rarity] or 1
end

--///////////////////////////////////////////////////////////
-- SHOWCASE SYSTEM (Uses CFrame math)
--///////////////////////////////////////////////////////////

function UnitsClient:_startShowcaseRotation(model: Model)
    -- Stop previous rotation loop
    safeDisconnect(self.ShowcaseRotationConn)

    local root = model.PrimaryPart
    if not root then return end

    -- Continuous rotation using RunService
    self.ShowcaseRotationConn = RunService.RenderStepped:Connect(function(dt)
        if not model.Parent then return end

        local cf = root.CFrame
        root.CFrame = cf * CFrame.Angles(0, SHOWCASE_ROTATION_SPEED * dt, 0)
    end)
end

function UnitsClient:_loadShowcaseModel(unitFolder: Instance)
    local unitName = unitFolder:GetAttribute("Name") or unitFolder.Name
    local asset = UnitsAssets:FindFirstChild(unitName)
    if not asset then return end

    local viewport = MainGui.UnitShowcase.ViewportFrame
    local world = viewport.WorldModel

    local old = world:FindFirstChild("Rig")
    if old then old:Destroy() end

    local model = asset.Model:Clone()
    model.Name = "Rig"
    model.Parent = world
    model.PrimaryPart = model:WaitForChild("HumanoidRootPart")

    -- Center model using CFrame math
    model:PivotTo(CFrame.new(0, 0, 0))

    -- Play idle animation
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if humanoid and Animations:FindFirstChild("Idle") then
        humanoid:LoadAnimation(Animations.Idle):Play()
    end

    self:_startShowcaseRotation(model)
end

--///////////////////////////////////////////////////////////
-- SELECTION SYSTEM
--///////////////////////////////////////////////////////////

function UnitsClient:_applySelectionVisuals(slot: GuiObject)
    slot:SetAttribute("CurrentlySelected", true)

    local overlay = slot:FindFirstChild("SelectedOverlay")
    if overlay then overlay.Visible = true end

    local focus = slot:FindFirstChild("Focus")
    if focus then focus.Visible = true end

    slot.ZIndex = 2
end

function UnitsClient:_clearSelectionVisuals(slot: GuiObject)
    slot:SetAttribute("CurrentlySelected", false)

    local overlay = slot:FindFirstChild("SelectedOverlay")
    if overlay then overlay.Visible = false end

    local focus = slot:FindFirstChild("Focus")
    if focus then focus.Visible = false end

    slot.ZIndex = 1
end

function UnitsClient:_deselectCurrent()
    if not self.CurrentlySelected then return end

    Helper:DeselectUnit(self.CurrentlySelected, nil, self.CurrentlySelected)
    self:_clearSelectionVisuals(self.CurrentlySelected)

    self.CurrentlySelected = nil
end

--///////////////////////////////////////////////////////////
-- SLOT BINDING (Reduced nesting)
--///////////////////////////////////////////////////////////

function UnitsClient:_onSlotClicked(unitFolder, slot, isBottomBar)
    local realSlot = slot

    if isBottomBar then
        local invSlot = MainGui.Windows.Units.Main.Base.Slots:FindFirstChild(unitFolder.Name)
        if invSlot then
            realSlot = invSlot
        end
    end

    -- Toggle behavior
    if self.CurrentlySelected == realSlot then
        self:_deselectCurrent()
        return
    end

    self.CurrentlySelected = realSlot
    self:_applySelectionVisuals(realSlot)

    -- Open window if from bottom bar
    if isBottomBar then
        QuickFunctions:OpenWindow(MainGui.Buttons.Units)
    end

    -- Load showcase
    self:_loadShowcaseModel(unitFolder)
end

function UnitsClient:BindSlot(unitFolder, slot: GuiObject, isBottomBar)
    local button = slot:FindFirstChildWhichIsA("GuiButton", true)
    if not button then return end

    safeDisconnect(self.SlotConnections[slot])

    self.SlotConnections[slot] =
        button.MouseButton1Up:Connect(function()
            self:_onSlotClicked(unitFolder, slot, isBottomBar)
        end)
end

--///////////////////////////////////////////////////////////
-- SEARCH SYSTEM
--///////////////////////////////////////////////////////////

function UnitsClient:ApplySearchFilter(searchBox, slotsHolder)
    local query = string.lower(searchBox.Text or "")

    for _, slot in ipairs(slotsHolder:GetChildren()) do
        if not slot:IsA("GuiObject") then continue end
        if slot.Name == "UIListLayout" then continue end

        local label = slot:FindFirstChild("NameText", true)
        local name = label and string.lower(label.Text) or ""

        slot.Visible = (query == "") or name:find(query, 1, true)
    end
end

--///////////////////////////////////////////////////////////
-- INITIALIZATION
--///////////////////////////////////////////////////////////

function UnitsClient:Init(keptData)
    self.KeptData = keptData

    local inventory = getInventory(keptData)
    if not inventory then
        warn("[UnitsClient] Missing inventory")
        return
    end

    -- Initial population
    for _, unitFolder in ipairs(inventory:GetChildren()) do
        self:CreateUnitSlot(unitFolder)
    end

    -- Live syncing
    inventory.ChildAdded:Connect(function(unitFolder)
        self:CreateUnitSlot(unitFolder)
    end)

    inventory.ChildRemoved:Connect(function(unitFolder)
        local slot = MainGui.Windows.Units.Main.Base.Slots:FindFirstChild(unitFolder.Name)
        if slot then slot:Destroy() end
    end)

    -- Search binding
    local searchBox = MainGui.Windows.Units.Search.Input
    searchBox:GetPropertyChangedSignal("Text"):Connect(function()
        if SoundService:FindFirstChild("SFX") then
            local key = SoundService.SFX:FindFirstChild("Key")
            if key then key:Play() end
        end

        self:ApplySearchFilter(
            searchBox,
            MainGui.Windows.Units.Main.Base.Slots
        )
    end)
end

--///////////////////////////////////////////////////////////

return UnitsClient
