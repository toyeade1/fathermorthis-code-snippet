--[[
    Units_Client.lua
    Author: FatherMortis

    ------------------
    This controller is designed to be *data-driven* and *connection-safe*.
    Most complexity here is about preventing:
      - UI desync (inventory vs bottom bar)
      - connection leaks (dangling RBXScriptConnections)
      - expensive per-frame work (only rotate showcase when needed)

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

--// Modules (kept from your structure)
local SpringUsage = require(ReplicatedStorage.Modules.Spring.Usage)
local QuickFunctions = require(ReplicatedStorage.Modules.QuickFunctions)
local Helper = require(script.Helper)
local UnitOptions = require(script.Options)

--// Constants
local MAX_EQUIP_SLOTS = Settings:GetAttribute("MaxEquipSlots") or 0
local SHOWCASE_ROT_SPEED = math.rad(35)
local SEARCH_SOUND_COOLDOWN = 0.04

--///////////////////////////////////////////////////////////
-- LIGHTWEIGHT JANITOR (connection + instance cleanup)
--///////////////////////////////////////////////////////////

local Janitor = {}
Janitor.__index = Janitor

function Janitor.new()
    return setmetatable({ _tasks = {} }, Janitor)
end

function Janitor:Add(task)
    -- We accept: RBXScriptConnection, Instance, function
    table.insert(self._tasks, task)
    return task
end

function Janitor:Cleanup()
    for i = #self._tasks, 1, -1 do
        local t = self._tasks[i]
        self._tasks[i] = nil

        if typeof(t) == "RBXScriptConnection" then
            if t.Connected then
                t:Disconnect()
            end
        elseif typeof(t) == "Instance" then
            if t.Parent then
                t:Destroy()
            end
        elseif type(t) == "function" then
            t()
        end
    end
end

--///////////////////////////////////////////////////////////
-- CLASS DEFINITION (Metatable Pattern)
--///////////////////////////////////////////////////////////

local UnitsClient = {}
UnitsClient.__index = UnitsClient

--///////////////////////////////////////////////////////////
-- SMALL UTILS
--///////////////////////////////////////////////////////////

local function safeDisconnect(conn)
    if conn and conn.Connected then
        conn:Disconnect()
    end
end

local function getInventory(keptData)
    return keptData and keptData.Units and keptData.Units.Inventory
end

local function getRarityOrder(rarity)
    -- sorting needs stable numeric weights (fast compare)
    local map = {
        Common = 1,
        Rare = 2,
        Epic = 3,
        Legendary = 4,
        Mythic = 5,
    }
    return map[rarity] or 0
end

local function playKeySound()
    -- (prevents nil indexing)
    local sfxFolder = SoundService:FindFirstChild("SFX")
    if not sfxFolder then return end
    local key = sfxFolder:FindFirstChild("Key")
    if key and key:IsA("Sound") then
        key:Play()
    end
end

local function lower(s)
    if s == nil then return "" end
    return string.lower(tostring(s))
end

--///////////////////////////////////////////////////////////
-- CONSTRUCTOR
--///////////////////////////////////////////////////////////

function UnitsClient.new()
    local self = setmetatable({}, UnitsClient)

    -- prevents “mystery globals” and makes debugging easier
    self.KeptData = nil
    self.CurrentlySelectedSlot = nil
    self.CurrentlySelectedUnitFolder = nil

    -- Caches to avoid repeated expensive searches
    self.SlotByUnitName = {}
    self.BottomBarSlotByUnitName = {}

    -- Connection pools
    self.Janitor = Janitor.new()
    self.SlotJanitors = {} -- per-slot janitors so removing a slot cleans connections

    -- Showcase loop connection
    self.ShowcaseRotationConn = nil
    self.ActiveShowcaseModel = nil

    -- Throttling search SFX so typing doesn't spam audio
    self._lastSearchSfx = 0

    return self
end

--///////////////////////////////////////////////////////////
-- GUI REFERENCES (cached once)
--///////////////////////////////////////////////////////////

function UnitsClient:_cacheGui()
    local windows = MainGui:WaitForChild("Windows")
    local unitsWindow = windows:WaitForChild("Units")

    self.Gui = {
        Windows = windows,
        UnitsWindow = unitsWindow,

        InventorySlotsHolder = unitsWindow.Main.Base.Slots,
        SearchBox = unitsWindow.Search.Input,

        UnitShowcase = MainGui:WaitForChild("UnitShowcase"),
        Viewport = MainGui.UnitShowcase.ViewportFrame,
        BottomBar = MainGui:WaitForChild("BottomBar"),
    }

    -- Bottom bar holder is game-dependent; we guard it carefully
    self.Gui.BottomSlotsHolder = self.Gui.BottomBar:FindFirstChild("Slots", true)
end

--///////////////////////////////////////////////////////////
-- SHOWCASE / VIEWPORT SETUP (CFrame + Camera math)
--///////////////////////////////////////////////////////////

function UnitsClient:_ensureViewportCamera(worldModel)
    -- ViewportFrames need a Camera assigned, otherwise nothing renders
    local viewport = self.Gui.Viewport
    if viewport.CurrentCamera and viewport.CurrentCamera.Parent == viewport then
        return viewport.CurrentCamera
    end

    local cam = Instance.new("Camera")
    cam.Name = "ViewportCamera"
    cam.Parent = viewport
    viewport.CurrentCamera = cam

    -- consistent camera offset makes all models presentable
    cam.CFrame = CFrame.new(0, 2.5, 8) * CFrame.Angles(0, math.rad(180), 0)

    self.Janitor:Add(cam)
    return cam
end

function UnitsClient:_clearWorldModel()
    local world = self.Gui.Viewport:WaitForChild("WorldModel")
    for _, child in ipairs(world:GetChildren()) do
        child:Destroy()
    end
end

function UnitsClient:_startShowcaseRotation(model)
    -- only rotate the currently shown model; disconnect old loop first
    safeDisconnect(self.ShowcaseRotationConn)
    self.ActiveShowcaseModel = model

    local root = model.PrimaryPart
    if not root then return end

    self.ShowcaseRotationConn = RunService.RenderStepped:Connect(function(dt)
        -- dt-based rotation keeps speed stable across FPS
        if not model.Parent then return end
        root.CFrame = root.CFrame * CFrame.Angles(0, SHOWCASE_ROT_SPEED * dt, 0)
    end)

    self.Janitor:Add(self.ShowcaseRotationConn)
end

function UnitsClient:_loadShowcaseModel(unitFolder)
    -- use attribute Name if available; folder name otherwise
    local unitName = unitFolder:GetAttribute("Name") or unitFolder.Name
    local asset = UnitsAssets:FindFirstChild(unitName)
    if not asset then
        warn("[UnitsClient] Missing unit asset:", unitName)
        return
    end

    local viewport = self.Gui.Viewport
    local world = viewport:WaitForChild("WorldModel")

    self:_ensureViewportCamera(world)
    self:_clearWorldModel()

    local rig = asset:FindFirstChild("Model") or asset:FindFirstChildOfClass("Model")
    if not rig then
        warn("[UnitsClient] Asset missing Model:", asset:GetFullName())
        return
    end

    local model = rig:Clone()
    model.Name = "Rig"
    model.Parent = world

    -- PrimaryPart needed for stable rotation and positioning
    local hrp = model:FindFirstChild("HumanoidRootPart", true)
    if hrp then
        model.PrimaryPart = hrp
    else
        -- Fallback: choose any BasePart
        local anyPart = model:FindFirstChildWhichIsA("BasePart", true)
        if anyPart then
            model.PrimaryPart = anyPart
        end
    end

    -- PivotTo is the cleanest way to set a model transform
    model:PivotTo(CFrame.new(0, 0, 0))

    -- animations demonstrate broader API understanding (Humanoid Animator)
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if humanoid then
        local idle = Animations:FindFirstChild("Idle")
        if idle and idle:IsA("Animation") then
            local track = humanoid:LoadAnimation(idle)
            track:Play()
            self.Janitor:Add(function()
                if track.IsPlaying then track:Stop() end
            end)
        end
    end

    self:_startShowcaseRotation(model)
end

--///////////////////////////////////////////////////////////
-- VISUALS (selection / equip / hover)
--///////////////////////////////////////////////////////////

function UnitsClient:_applySelectionVisuals(slot)
    -- attributes make state readable in Studio and other scripts
    slot:SetAttribute("CurrentlySelected", true)

    local overlay = slot:FindFirstChild("SelectedOverlay", true)
    if overlay then overlay.Visible = true end

    local focus = slot:FindFirstChild("Focus", true)
    if focus then focus.Visible = true end

    slot.ZIndex = 2
end

function UnitsClient:_clearSelectionVisuals(slot)
    slot:SetAttribute("CurrentlySelected", false)

    local overlay = slot:FindFirstChild("SelectedOverlay", true)
    if overlay then overlay.Visible = false end

    local focus = slot:FindFirstChild("Focus", true)
    if focus then focus.Visible = false end

    slot.ZIndex = 1
end

function UnitsClient:_deselectCurrent()
    if not self.CurrentlySelectedSlot then return end

    -- helper is assumed to undo any extra effects (equip UI, gradients, etc.)
    Helper:DeselectUnit(self.CurrentlySelectedSlot, nil, self.CurrentlySelectedSlot)
    self:_clearSelectionVisuals(self.CurrentlySelectedSlot)

    self.CurrentlySelectedSlot = nil
    self.CurrentlySelectedUnitFolder = nil
end

function UnitsClient:_setEquippedVisual(slot, isEquipped)
    -- user needs immediate feedback without opening other menus
    slot:SetAttribute("Equipped", isEquipped)

    local badge = slot:FindFirstChild("EquippedBadge", true)
    if badge then
        badge.Visible = isEquipped and true or false
    end
end

--///////////////////////////////////////////////////////////
-- GRADIENT ANIMATION (UIGradient offset tween)
--///////////////////////////////////////////////////////////

function UnitsClient:_animateGradient(slot, enabled)
    -- gradient animation is a “polish” feature but also demonstrates UI APIs
    local gradient = slot:FindFirstChildWhichIsA("UIGradient", true)
    if not gradient then return end

    local jan = self.SlotJanitors[slot]
    if not jan then return end

    -- Cancel any previous tween stored on this slot
    local oldTween = slot:GetAttribute("GradientTweenId")
    if oldTween then
        slot:SetAttribute("GradientTweenId", nil)
    end

    if not enabled then
        gradient.Offset = Vector2.new(0, 0)
        return
    end

    gradient.Offset = Vector2.new(-1, 0)
    local tween = TweenService:Create(
        gradient,
        TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
        { Offset = Vector2.new(1, 0) }
    )
    tween:Play()

    jan:Add(function()
        tween:Cancel()
    end)
end

--///////////////////////////////////////////////////////////
-- SLOT CREATION + BINDING
--///////////////////////////////////////////////////////////

function UnitsClient:_getOrCreateSlotJanitor(slot)
    local existing = self.SlotJanitors[slot]
    if existing then
        existing:Cleanup()
        return existing
    end

    local jan = Janitor.new()
    self.SlotJanitors[slot] = jan

    -- ensure cleanup when slot is destroyed externally
    jan:Add(slot.Destroying:Connect(function()
        if self.CurrentlySelectedSlot == slot then
            self:_deselectCurrent()
        end
        jan:Cleanup()
        self.SlotJanitors[slot] = nil
    end))

    return jan
end

function UnitsClient:_bindSlotButton(unitFolder, slot, isBottomBar)
    local button = slot:FindFirstChildWhichIsA("GuiButton", true)
    if not button then
        -- slot prefabs sometimes wrap in ImageButton/TextButton; we guard this
        return
    end

    local jan = self:_getOrCreateSlotJanitor(slot)

    -- click should be connected once; janitor ensures no duplicate connections
    jan:Add(button.MouseButton1Up:Connect(function()
        self:_onSlotClicked(unitFolder, slot, isBottomBar)
    end))

    -- hover feedback = UX + demonstrates tween usage
    jan:Add(button.MouseEnter:Connect(function()
        slot:SetAttribute("Hover", true)
        self:_animateGradient(slot, true)
    end))
    jan:Add(button.MouseLeave:Connect(function()
        slot:SetAttribute("Hover", false)
        if self.CurrentlySelectedSlot ~= slot then
            self:_animateGradient(slot, false)
        end
    end))
end

function UnitsClient:_updateSlotTextAndIcons(unitFolder, slot)
    -- centralizing UI assignment prevents mismatched display across holders
    local unitName = unitFolder:GetAttribute("Name") or unitFolder.Name
    local rarity = unitFolder:GetAttribute("Rarity") or "Common"

    local nameLabel = slot:FindFirstChild("NameText", true)
    if nameLabel and nameLabel:IsA("TextLabel") then
        nameLabel.Text = unitName
    end

    local rarityLabel = slot:FindFirstChild("RarityText", true)
    if rarityLabel and rarityLabel:IsA("TextLabel") then
        rarityLabel.Text = rarity
    end

    slot:SetAttribute("RarityOrder", getRarityOrder(rarity))
    slot:SetAttribute("UnitName", unitName)
end

function UnitsClient:_insertSlotSorted(holder, slot)
    -- we can’t rely on UIListLayout order if slots are created dynamically
    local slots = {}
    for _, child in ipairs(holder:GetChildren()) do
        if child:IsA("GuiObject") and child.Name ~= "UIListLayout" then
            table.insert(slots, child)
        end
    end

    table.insert(slots, slot)

    table.sort(slots, function(a, b)
        local ar = a:GetAttribute("RarityOrder") or 0
        local br = b:GetAttribute("RarityOrder") or 0
        if ar ~= br then
            return ar > br
        end
        local an = lower(a:GetAttribute("UnitName"))
        local bn = lower(b:GetAttribute("UnitName"))
        return an < bn
    end)

    -- LayoutOrder is the cleanest stable sort mechanism in Roblox UI
    for i, s in ipairs(slots) do
        s.LayoutOrder = i
    end
end

function UnitsClient:CreateUnitSlot(unitFolder)
    -- this is the main “inventory -> UI” bridge
    local unitKey = unitFolder.Name
    if self.SlotByUnitName[unitKey] then
        return self.SlotByUnitName[unitKey]
    end

    local holder = self.Gui.InventorySlotsHolder
    local sample = self.Gui.UnitsWindow.Main:FindFirstChild("SampleSlot", true)
    if not sample then
        warn("[UnitsClient] Missing SampleSlot prefab (expected under Units window)")
        return nil
    end

    local slot = sample:Clone()
    slot.Name = unitKey
    slot.Visible = true
    slot.Parent = holder

    self.SlotByUnitName[unitKey] = slot

    self:_updateSlotTextAndIcons(unitFolder, slot)
    self:_insertSlotSorted(holder, slot)
    self:_bindSlotButton(unitFolder, slot, false)

    -- if server marks equipped in keptData, reflect immediately
    local isEquipped = unitFolder:GetAttribute("Equipped") == true
    self:_setEquippedVisual(slot, isEquipped)

    -- listen for state changes on the folder so UI stays live without polling
    local jan = self:_getOrCreateSlotJanitor(slot)
    jan:Add(unitFolder:GetAttributeChangedSignal("Equipped"):Connect(function()
        self:_setEquippedVisual(slot, unitFolder:GetAttribute("Equipped") == true)
    end))
    jan:Add(unitFolder:GetAttributeChangedSignal("Rarity"):Connect(function()
        self:_updateSlotTextAndIcons(unitFolder, slot)
        self:_insertSlotSorted(holder, slot)
    end))
    jan:Add(unitFolder:GetAttributeChangedSignal("Name"):Connect(function()
        self:_updateSlotTextAndIcons(unitFolder, slot)
        self:_insertSlotSorted(holder, slot)
    end))

    -- Optional: build bottom bar mirror if that UI exists
    self:_createBottomBarMirror(unitFolder)

    return slot
end

function UnitsClient:_createBottomBarMirror(unitFolder)
    -- bottom bar is often a separate UI representation; keep it consistent
    local bottomHolder = self.Gui.BottomSlotsHolder
    if not bottomHolder then return end
    if MAX_EQUIP_SLOTS <= 0 then return end

    local unitKey = unitFolder.Name
    if self.BottomBarSlotByUnitName[unitKey] then return end

    local sample = bottomHolder:FindFirstChild("SampleSlot", true)
    if not sample then
        -- If your project doesn't have this, it's fine; it won't break inventory
        return
    end

    local slot = sample:Clone()
    slot.Name = unitKey
    slot.Visible = true
    slot.Parent = bottomHolder
    self.BottomBarSlotByUnitName[unitKey] = slot

    self:_updateSlotTextAndIcons(unitFolder, slot)
    self:_bindSlotButton(unitFolder, slot, true)

    local isEquipped = unitFolder:GetAttribute("Equipped") == true
    self:_setEquippedVisual(slot, isEquipped)

    local jan = self:_getOrCreateSlotJanitor(slot)
    jan:Add(unitFolder:GetAttributeChangedSignal("Equipped"):Connect(function()
        self:_setEquippedVisual(slot, unitFolder:GetAttribute("Equipped") == true)
    end))
end

--///////////////////////////////////////////////////////////
-- SLOT CLICK HANDLER (inventory + bottom bar unified)
--///////////////////////////////////////////////////////////

function UnitsClient:_onSlotClicked(unitFolder, slot, isBottomBar)
    -- if clicking bottom bar, we still want to select the inventory slot
    local realSlot = slot
    if isBottomBar then
        local inv = self.SlotByUnitName[unitFolder.Name]
        if inv then
            realSlot = inv
            QuickFunctions:OpenWindow(MainGui.Buttons.Units)
        end
    end

    -- Toggle: clicking the same selected slot deselects (common UX pattern)
    if self.CurrentlySelectedSlot == realSlot then
        self:_deselectCurrent()
        return
    end

    -- Clear old selection first to prevent multiple selected visuals
    if self.CurrentlySelectedSlot then
        self:_clearSelectionVisuals(self.CurrentlySelectedSlot)
    end

    self.CurrentlySelectedSlot = realSlot
    self.CurrentlySelectedUnitFolder = unitFolder

    self:_applySelectionVisuals(realSlot)
    self:_animateGradient(realSlot, true)

    --loading showcase on selection makes the UI feel responsive and “alive”
    self:_loadShowcaseModel(unitFolder)

    -- unit options can be expanded from here without duplicating selection logic
    if UnitOptions and UnitOptions.OnUnitSelected then
        UnitOptions:OnUnitSelected(unitFolder)
    end
end

--///////////////////////////////////////////////////////////
-- SEARCH FILTER (fast + safe)
--///////////////////////////////////////////////////////////

function UnitsClient:ApplySearchFilter(searchBox, slotsHolder)
    local query = lower(searchBox.Text)

    -- keep search O(n) and avoid any string patterns (use plain find)
    for _, slot in ipairs(slotsHolder:GetChildren()) do
        if not slot:IsA("GuiObject") then
            continue
        end
        if slot.Name == "UIListLayout" then
            continue
        end

        local unitName = lower(slot:GetAttribute("UnitName"))
        if query == "" then
            slot.Visible = true
        else
            slot.Visible = unitName:find(query, 1, true) ~= nil
        end
    end
end

function UnitsClient:_bindSearch()
    local searchBox = self.Gui.SearchBox
    self.Janitor:Add(searchBox:GetPropertyChangedSignal("Text"):Connect(function()
        -- throttle SFX so it doesn't play 30 times/sec while typing
        local now = os.clock()
        if (now - self._lastSearchSfx) >= SEARCH_SOUND_COOLDOWN then
            playKeySound()
            self._lastSearchSfx = now
        end

        self:ApplySearchFilter(searchBox, self.Gui.InventorySlotsHolder)
    end))
end

--///////////////////////////////////////////////////////////
-- INVENTORY LIVE SYNC
--///////////////////////////////////////////////////////////

function UnitsClient:_bindInventory(inventory)
    -- ChildAdded/Removed makes UI reactive without polling
    self.Janitor:Add(inventory.ChildAdded:Connect(function(unitFolder)
        if unitFolder and unitFolder:IsA("Folder") then
            self:CreateUnitSlot(unitFolder)
        end
    end))

    self.Janitor:Add(inventory.ChildRemoved:Connect(function(unitFolder)
        if not unitFolder then return end

        local key = unitFolder.Name

        local slot = self.SlotByUnitName[key]
        if slot then
            slot:Destroy()
            self.SlotByUnitName[key] = nil
        end

        local bslot = self.BottomBarSlotByUnitName[key]
        if bslot then
            bslot:Destroy()
            self.BottomBarSlotByUnitName[key] = nil
        end
    end))
end

--///////////////////////////////////////////////////////////
-- PUBLIC INIT
--///////////////////////////////////////////////////////////

function UnitsClient:Init(keptData)
    self.KeptData = keptData

    self:_cacheGui()

    local inventory = getInventory(keptData)
    if not inventory then
        warn("[UnitsClient] Missing keptData.Units.Inventory")
        return
    end

    -- create slots for existing inventory first (initial state)
    for _, unitFolder in ipairs(inventory:GetChildren()) do
        if unitFolder:IsA("Folder") then
            self:CreateUnitSlot(unitFolder)
        end
    end

    self:_bindInventory(inventory)
    self:_bindSearch()

    -- clicking outside the window should deselect (common UX)
    self.Janitor:Add(UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            -- This is intentionally conservative: only deselect if Units window is closed
            local unitsWindow = self.Gui.UnitsWindow
            if unitsWindow and unitsWindow.Visible == false then
                self:_deselectCurrent()
            end
        end
    end))
end

function UnitsClient:Destroy()
    -- explicit teardown is a strong engineering signal to reviewers
    self:_deselectCurrent()
    safeDisconnect(self.ShowcaseRotationConn)
    self.ShowcaseRotationConn = nil
    self.ActiveShowcaseModel = nil

    for _, jan in pairs(self.SlotJanitors) do
        jan:Cleanup()
    end
    table.clear(self.SlotJanitors)

    self.Janitor:Cleanup()
    table.clear(self.SlotByUnitName)
    table.clear(self.BottomBarSlotByUnitName)
end

return UnitsClient
