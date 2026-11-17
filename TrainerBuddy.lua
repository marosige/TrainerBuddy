--[[
Trainer Buddy
  * Right-click an entry in the class / profession trainer window:
      - hide this rank only
      - hide every rank of that spell / recipe
  * Hidden entries disappear from the trainer list.
  * "Train All" button left of the "Train" button. Skips hidden entries,
    shows the total price and buys as many as you can afford.
  * Settings > AddOns > Trainer Buddy (or /tb) lists everything you
    hid, with a Restore button per entry.
]]

local ADDON = ...

-- Layout tweaks for the Train All button / cost line.
local TRAINALL_WIDTH  = 84
local COST_OFFSET_Y   = 3

local db            -- = TrainerBuddyCharDB, set on ADDON_LOADED
local trainAllButton, costText
local category      -- Settings category
local SetAutoReplace, autoCheck  -- forward
local RefreshPopup               -- forward

---------------------------------------------------------------------------
-- Hidden list
---------------------------------------------------------------------------

local function AllKey(name)        return "A:" .. name end
local function RankKey(name, sub)  return "R:" .. name .. "|" .. sub end

local function IsHidden(name, sub)
    if not name or not db then return false end
    if db.hidden[AllKey(name)] then return true end
    if sub and sub ~= "" and db.hidden[RankKey(name, sub)] then return true end
    return false
end

local function CountHidden()
    local n = 0
    for _ in pairs(db.hidden) do n = n + 1 end
    return n
end

---------------------------------------------------------------------------
-- Trainer window handling
---------------------------------------------------------------------------

local UpdateTrainAll  -- forward

-- Remove hidden entries from the list the Blizzard frame just built.
local function ApplyFilter()
    local frame = ClassTrainerFrame
    if not frame or not frame.ScrollBox then return end

    local dp = frame.ScrollBox:GetDataProvider()
    if dp and next(db.hidden) then
        local toRemove
        for _, node in dp:EnumerateEntireRange() do
            local data = node:GetData()
            if data and data.skillIndex then
                local name, _, _, _, sub = GetTrainerServiceInfo(data.skillIndex)
                if IsHidden(name, sub) then
                    toRemove = toRemove or {}
                    toRemove[#toRemove + 1] = node
                end
            end
        end
        if toRemove then
            for _, node in ipairs(toRemove) do
                dp:Remove(node)
            end
        end
    end

    UpdateTrainAll()
end

local function RefreshTrainer()
    if ClassTrainerFrame and ClassTrainerFrame:IsShown() then
        ClassTrainerFrame.selectedService = nil
        ClassTrainerFrame_SetTrainButtonEnabled(false)
        ClassTrainerFrame_Update(true)
        ClassTrainer_SelectNearestLearnableSkill()
    end
end

local RefreshOptions  -- forward

local function HideEntry(name, sub, allRanks)
    if allRanks then
        db.hidden[AllKey(name)] = { name = name }
        -- rank-specific entries for this spell are redundant now
        for key, entry in pairs(db.hidden) do
            if entry.name == name and entry.sub then
                db.hidden[key] = nil
            end
        end
    else
        db.hidden[RankKey(name, sub)] = { name = name, sub = sub }
    end
    RefreshTrainer()
    RefreshOptions()
end

local function ShowContextMenu(button)
    local index = button:GetID()
    local name, _, _, _, sub = GetTrainerServiceInfo(index)
    if not name then return end
    sub = sub or ""

    MenuUtil.CreateContextMenu(button, function(owner, root)
        root:CreateTitle(name .. (sub ~= "" and (" (" .. sub .. ")") or ""))
        if sub ~= "" then
            root:CreateButton("Hide this rank only (" .. sub .. ")", function()
                HideEntry(name, sub, false)
            end)
            root:CreateButton("Hide all ranks of " .. name, function()
                HideEntry(name, sub, true)
            end)
        else
            root:CreateButton("Hide " .. name, function()
                HideEntry(name, sub, true)
            end)
        end
        root:CreateDivider()
        root:CreateButton("Open hidden list (" .. CountHidden() .. ")", function()
            if category then Settings.OpenToCategory(category:GetID()) end
        end)
    end)
end

local function HookSkillButton(button)
    if button.htHooked or button == ClassTrainerFrame.skillStepButton then return end
    button.htHooked = true
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:HookScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" then
            ShowContextMenu(self)
        end
    end)
    button:HookScript("OnEnter", function(self)
        if GameTooltip:IsOwned(self) then
            GameTooltip:AddLine("|cff88ccffRight-click:|r hide this entry")
            GameTooltip:Show()
        end
    end)
end

---------------------------------------------------------------------------
-- Train All
---------------------------------------------------------------------------

-- Returns list of {index, cost}, total cost, isPetTrainer
local function CollectTrainable()
    local list, total = {}, 0
    local isPet = C_Trainer.GetTrainerType() == Enum.TrainerType.Pet
    local stepIndex = GetTrainerServiceStepIndex and GetTrainerServiceStepIndex()

    for i = 1, GetNumTrainerServices() do
        if i ~= stepIndex then
            local name, serviceType, _, _, sub = GetTrainerServiceInfo(i)
            if serviceType == "available" and not IsHidden(name, sub) then
                local cost, isProfession = GetTrainerServiceCost(i)
                -- learning a profession itself needs a confirmation: leave it manual
                if not isProfession then
                    cost = cost or 0
                    list[#list + 1] = { index = i, cost = cost, name = name, sub = sub }
                    total = total + cost
                end
            end
        end
    end
    return list, total, isPet
end

local function GetBudget(isPet)
    if isPet then
        local points, used = C_PetInfo.GetPetTrainingPoints()
        return math.max((points or 0) - (used or 0), 0)
    end
    return GetMoney()
end

local function FormatCost(amount, isPet)
    if isPet then return amount .. " TP" end
    return GetCoinTextureString(amount)
end

function UpdateTrainAll()
    if not trainAllButton then return end

    local list, total, isPet = CollectTrainable()
    local budget = GetBudget(isPet)

    local affordable, left = 0, budget
    for _, entry in ipairs(list) do
        if entry.cost <= left then
            left = left - entry.cost
            affordable = affordable + 1
        end
    end

    trainAllButton.list, trainAllButton.total, trainAllButton.isPet = list, total, isPet
    trainAllButton.affordable = affordable
    trainAllButton:SetEnabled(affordable > 0)

    if #list > 0 then
        costText:SetText(FormatCost(total, isPet))
        if total > budget then
            costText:SetTextColor(1, 0.2, 0.2)
        else
            costText:SetTextColor(1, 1, 1)
        end
        costText:Show()
    else
        costText:Hide()
    end
end

local function TrainAll()
    local list, _, isPet = CollectTrainable()
    local budget = GetBudget(isPet)
    for _, entry in ipairs(list) do
        if entry.cost <= budget then
            budget = budget - entry.cost
            BuyTrainerService(entry.index)
        end
    end
end

local function CreateTrainAllButton()
    trainAllButton = CreateFrame("Button", "TrainerBuddyTrainAllButton", ClassTrainerFrame, "MagicButtonTemplate")
    trainAllButton:SetText("Train All")
    trainAllButton:SetWidth(TRAINALL_WIDTH)
    trainAllButton:SetPoint("RIGHT", ClassTrainerTrainButton, "LEFT", 0, 0)
    trainAllButton:SetScript("OnClick", TrainAll)
    trainAllButton:SetMotionScriptsWhileDisabled(true)  -- keep the tooltip when it is greyed out

    costText = trainAllButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    costText:SetPoint("BOTTOM", trainAllButton, "TOP", 0, COST_OFFSET_Y)

    trainAllButton:SetScript("OnEnter", function(self)
        local list, total, isPet = CollectTrainable()
        local budget = GetBudget(isPet)
        local MAX_LINES = 14

        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Train All")

        if #list == 0 then
            GameTooltip:AddLine("Nothing to train (hidden entries are skipped).", 1, 1, 1, true)
        else
            -- same order and rules as the real click: buy what still fits the budget
            local left = budget
            for i, entry in ipairs(list) do
                local affordable = entry.cost <= left
                if affordable then left = left - entry.cost end
                if i <= MAX_LINES then
                    local label = entry.name
                    if entry.sub and entry.sub ~= "" then label = label .. " (" .. entry.sub .. ")" end
                    if affordable then
                        GameTooltip:AddDoubleLine(label, FormatCost(entry.cost, isPet), 1, 1, 1, 1, 1, 1)
                    else
                        GameTooltip:AddDoubleLine(label, FormatCost(entry.cost, isPet), 1, 0.3, 0.3, 1, 0.3, 0.3)
                    end
                end
            end
            if #list > MAX_LINES then
                GameTooltip:AddLine("... and " .. (#list - MAX_LINES) .. " more", 0.7, 0.7, 0.7)
            end

            GameTooltip:AddLine(" ")
            if total > budget then
                GameTooltip:AddDoubleLine("Total cost:", FormatCost(total, isPet), 1, 0.82, 0, 1, 0.3, 0.3)
            else
                GameTooltip:AddDoubleLine("Total cost:", FormatCost(total, isPet), 1, 0.82, 0, 1, 1, 1)
            end
            GameTooltip:AddDoubleLine("You have:", FormatCost(budget, isPet), 1, 0.82, 0, 1, 1, 1)
            if total > budget then
                GameTooltip:AddLine("Red entries are skipped: not enough " .. (isPet and "training points." or "gold."), 1, 0.3, 0.3, true)
            end
        end
        GameTooltip:AddLine("Profession unlocks need the normal Train button.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    trainAllButton:SetScript("OnLeave", GameTooltip_Hide)
end

local function SetupTrainerFrame()
    CreateTrainAllButton()

    hooksecurefunc("ClassTrainerFrame_Update", ApplyFilter)
    hooksecurefunc("ClassTrainerFrame_InitServiceButton", HookSkillButton)

    -- entry in the Filter dropdown to open the hidden list
    if Menu and Menu.ModifyMenu then
        Menu.ModifyMenu("MENU_TRAINER_FILTER", function(dropdown, root)
            root:CreateDivider()
            root:CreateCheckbox("Auto-upgrade action bars",
                function() return db.autoReplace end,
                function() SetAutoReplace(not db.autoReplace) end)
            root:CreateButton("Hidden entries (" .. CountHidden() .. ")...", function()
                if category then Settings.OpenToCategory(category:GetID()) end
            end)
        end)
    end
end

---------------------------------------------------------------------------
-- Settings panel with the hidden list
---------------------------------------------------------------------------

local scrollBox, emptyText

local function BuildList()
    local list = {}
    for key, entry in pairs(db.hidden) do
        local label
        if entry.sub then
            label = entry.name .. "  |cffaaaaaa(" .. entry.sub .. " only)|r"
        else
            label = entry.name .. "  |cffaaaaaa(all ranks)|r"
        end
        list[#list + 1] = { key = key, label = label, sortName = entry.name .. (entry.sub or "") }
    end
    table.sort(list, function(a, b) return a.sortName < b.sortName end)
    return list
end

function RefreshOptions()
    if not scrollBox then return end
    local list = BuildList()
    scrollBox:SetDataProvider(CreateDataProvider(list))
    emptyText:SetShown(#list == 0)
end

local function RestoreEntry(key)
    db.hidden[key] = nil
    RefreshOptions()
    RefreshTrainer()
end

local function InitRow(row, data)
    if not row.text then
        row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        row.text:SetPoint("LEFT", 8, 0)
        row.text:SetJustifyH("LEFT")
        row.btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.btn:SetSize(90, 22)
        row.btn:SetPoint("RIGHT", -8, 0)
        row.btn:SetText("Restore")
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, 0.04)
    end
    row.text:SetText(data.label)
    row.btn:SetScript("OnClick", function() RestoreEntry(data.key) end)
end

local function BuildOptions()
    local panel = CreateFrame("Frame")
    panel.name = "Trainer Buddy"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Trainer Buddy")

    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetText("Entries you hid at a trainer (right-click an entry). Restore brings them back.")

    local restoreAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    restoreAll:SetSize(110, 22)
    restoreAll:SetPoint("TOPRIGHT", -16, -16)
    restoreAll:SetText("Restore all")
    restoreAll:SetScript("OnClick", function()
        wipe(db.hidden)
        RefreshOptions()
        RefreshTrainer()
    end)

    local auto = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    auto:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", -4, -8)
    auto.Text:SetText("Auto-upgrade action bar spells to the new rank after training")
    auto:SetChecked(db.autoReplace)
    auto:SetScript("OnClick", function(self) db.autoReplace = self:GetChecked() and true or false end)
    autoCheck = auto

    local pop = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    pop:SetPoint("TOPLEFT", auto, "BOTTOMLEFT", 0, 0)
    pop.Text:SetText("Show a popup bar with newly learned spells (drag them to your action bars)")
    pop:SetChecked(db.showPopup)
    pop:SetScript("OnClick", function(self)
        db.showPopup = self:GetChecked() and true or false
        RefreshPopup()
    end)

    scrollBox = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", 16, -126)
    scrollBox:SetPoint("BOTTOMRIGHT", -36, 16)
    local scrollBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(26)
    view:SetPadding(0, 0, 0, 0, 2)
    view:SetElementFactory(function(factory, elementData)
        factory("Button", InitRow)
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    emptyText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    emptyText:SetPoint("TOP", scrollBox, "TOP", 0, -20)
    emptyText:SetText("Nothing hidden.")

    panel:SetScript("OnShow", RefreshOptions)

    category = Settings.RegisterCanvasLayoutCategory(panel, "Trainer Buddy")
    Settings.RegisterAddOnCategory(category)
end

---------------------------------------------------------------------------
-- "New spells" popup bar: freshly learned spells waiting to be dragged onto
-- your real action bars. Stays until you close it with the X.
---------------------------------------------------------------------------

local MAX_ACTION_SLOT = 180
local ICON_SIZE, ICON_GAP, PER_ROW = 38, 6, 8
local popup, popupButtons = nil, {}

local function IsOnBar(spellID)
    for slot = 1, MAX_ACTION_SLOT do
        local actionType, id = GetActionInfo(slot)
        if actionType == "spell" and id == spellID then return true end
    end
    return false
end

local function IsPlaceable(spellID)
    if not IsPlayerSpell(spellID) then return false end
    if C_Spell.IsSpellPassive and C_Spell.IsSpellPassive(spellID) then return false end
    return C_Spell.GetSpellName(spellID) ~= nil
end

local function PickupSpellByID(spellID)
    ClearCursor()
    C_Spell.PickupSpell(spellID)
end

local function CreatePopup()
    popup = CreateFrame("Frame", "TrainerBuddyNewSpells", UIParent, "BackdropTemplate")
    popup:SetFrameStrata("MEDIUM")
    popup:SetClampedToScreen(true)
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    popup:SetBackdropColor(0, 0, 0, 0.85)

    local pos = db.popupPos
    if pos then
        popup:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        popup:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 220)
    end
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        db.popupPos = { point, relPoint, x, y }
    end)

    popup.title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    popup.title:SetPoint("TOPLEFT", 10, -8)
    popup.title:SetText("New spells - drag to your bars")

    popup.close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
    popup.close:SetPoint("TOPRIGHT", 2, 2)
    popup.close:SetScale(0.8)
    popup.close:SetScript("OnClick", function()
        wipe(db.newSpells)
        popup:Hide()
    end)
    popup:Hide()
end

local function GetButton(i)
    local b = popupButtons[i]
    if b then return b end
    b = CreateFrame("Button", nil, popup)
    b:SetSize(ICON_SIZE, ICON_SIZE)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.rank = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    b.rank:SetPoint("BOTTOMRIGHT", -2, 2)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:RegisterForDrag("LeftButton")
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnDragStart", function(self) PickupSpellByID(self.spellID) end)
    b:SetScript("OnClick", function(self) PickupSpellByID(self.spellID) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(self.spellID)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    popupButtons[i] = b
    return b
end

function RefreshPopup()
    if not db then return end
    if not popup then CreatePopup() end

    -- drop spells that are placed (or no longer valid)
    local list = {}
    for spellID in pairs(db.newSpells) do
        if IsPlaceable(spellID) and not IsOnBar(spellID) then
            list[#list + 1] = spellID
        else
            db.newSpells[spellID] = nil
        end
    end
    table.sort(list, function(a, b)
        return (C_Spell.GetSpellName(a) or "") < (C_Spell.GetSpellName(b) or "")
    end)

    if #list == 0 or not db.showPopup then
        popup:Hide()
        return
    end

    for i, spellID in ipairs(list) do
        local b = GetButton(i)
        local col, row = (i - 1) % PER_ROW, math.floor((i - 1) / PER_ROW)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", popup, "TOPLEFT", 10 + col * (ICON_SIZE + ICON_GAP), -26 - row * (ICON_SIZE + ICON_GAP))
        b.spellID = spellID
        b.icon:SetTexture(C_Spell.GetSpellTexture(spellID))
        local rank = tonumber((C_Spell.GetSpellSubtext(spellID) or ""):match("(%d+)"))
        b.rank:SetText(rank or "")
        b:Show()
    end
    for i = #list + 1, #popupButtons do popupButtons[i]:Hide() end

    local cols = math.min(#list, PER_ROW)
    local rows = math.ceil(#list / PER_ROW)
    popup:SetSize(math.max(20 + cols * (ICON_SIZE + ICON_GAP) - ICON_GAP, 190),
                  36 + rows * (ICON_SIZE + ICON_GAP) - ICON_GAP)
    popup:Show()
end

local function AddToPopup(spellID)
    if not db or not db.showPopup or not IsPlaceable(spellID) or IsOnBar(spellID) then return end
    db.newSpells[spellID] = true
    RefreshPopup()
end

local refreshTimer
local function QueueRefreshPopup()
    if refreshTimer then return end
    refreshTimer = C_Timer.NewTimer(0.3, function()
        refreshTimer = nil
        if popup and popup:IsShown() then RefreshPopup() end
    end)
end

---------------------------------------------------------------------------
-- Auto-upgrade action bar spells after learning a new rank (toggleable)
---------------------------------------------------------------------------

-- Spells that are NOT a new rank of the same name but replace an older spell
-- (druid forms). { [oldSpellID] = newSpellID }. These are the Classic IDs;
-- add more pairs here if Forever uses different ones.
local UPGRADES = {
    [5487]  = 9634,   -- Bear Form        -> Dire Bear Form
    [33943] = 40120,  -- Flight Form      -> Swift Flight Form
}

local pendingSpells = {}

local function RankOf(spellID)
    local sub = C_Spell.GetSpellSubtext(spellID)
    return sub and tonumber(sub:match("(%d+)")) or nil
end

local function UpgradeOnBars(newID)
    local newName = C_Spell.GetSpellName(newID)
    if not newName then return end
    local newRank = RankOf(newID)

    for slot = 1, MAX_ACTION_SLOT do
        local actionType, id = GetActionInfo(slot)
        if actionType == "spell" and id and id ~= newID then
            local replace = UPGRADES[id] == newID
            if not replace and newRank and C_Spell.GetSpellName(id) == newName then
                local oldRank = RankOf(id)
                replace = oldRank ~= nil and newRank > oldRank
            end
            if replace then
                ClearCursor()
                C_Spell.PickupSpell(newID)
                PlaceAction(slot)
                ClearCursor()
                print(("|cff66ccffTrainer Buddy|r: action slot %d -> %s%s"):format(
                    slot, newName, newRank and (" (rank " .. newRank .. ")") or ""))
            end
        end
    end
end

local function ProcessPendingSpells()
    if not db or not db.autoReplace then
        wipe(pendingSpells)
        return
    end
    if InCombatLockdown() or GetCursorInfo() then
        return  -- retried on PLAYER_REGEN_ENABLED / next learn event
    end
    for spellID in pairs(pendingSpells) do
        pendingSpells[spellID] = nil
        UpgradeOnBars(spellID)
    end
end

local function QueueLearnedSpell(spellID)
    if not db or not spellID then return end
    if db.autoReplace then
        pendingSpells[spellID] = true
        -- let several spells from one "Train All" arrive, then handle them together
        C_Timer.After(0.5, ProcessPendingSpells)
    end
    -- after the auto-upgrade had its chance, show what is still not on a bar
    C_Timer.After(1.2, function() AddToPopup(spellID) end)
end

function SetAutoReplace(value)
    db.autoReplace = value and true or false
    print("|cff66ccffTrainer Buddy|r: auto-upgrade action bar spells " .. (db.autoReplace and "ON" or "OFF"))
    if autoCheck then autoCheck:SetChecked(db.autoReplace) end
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_MONEY")
f:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        -- settings were called HideTrainerCharDB before the rename: carry them over
        if not TrainerBuddyCharDB then
            TrainerBuddyCharDB = HideTrainerCharDB or {}
        end
        HideTrainerCharDB = nil
        db = TrainerBuddyCharDB
        db.hidden = db.hidden or {}
        if db.autoReplace == nil then db.autoReplace = true end
        if db.showPopup == nil then db.showPopup = true end
        db.newSpells = db.newSpells or {}

        BuildOptions()
        EventUtil.ContinueOnAddOnLoaded("Blizzard_TrainerUI", SetupTrainerFrame)
    elseif event == "PLAYER_MONEY" then
        if trainAllButton and ClassTrainerFrame and ClassTrainerFrame:IsShown() then
            UpdateTrainAll()
        end
    elseif event == "LEARNED_SPELL_IN_SKILL_LINE" then
        QueueLearnedSpell(arg1)
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        QueueRefreshPopup()
    elseif event == "PLAYER_LOGIN" then
        C_Timer.After(2, RefreshPopup)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if next(pendingSpells) then C_Timer.After(0.5, ProcessPendingSpells) end
    end
end)

SLASH_TRAINERBUDDY1 = "/trainerbuddy"
SLASH_TRAINERBUDDY2 = "/tb"
SlashCmdList["TRAINERBUDDY"] = function(msg)
    msg = (msg or ""):lower()
    if msg == "auto" then
        SetAutoReplace(not db.autoReplace)
    elseif msg == "popup" then
        db.showPopup = not db.showPopup
        print("|cff66ccffTrainer Buddy|r: new-spells popup " .. (db.showPopup and "ON" or "OFF"))
        RefreshPopup()
    elseif category then
        Settings.OpenToCategory(category:GetID())
    end
end
