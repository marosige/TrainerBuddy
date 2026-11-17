--[[
Trainer Buddy
  * Right-click an entry in the class / pet / profession trainer window to
    hide it (all ranks) or unhide it. Hidden entries disappear from the list.
  * "Train All" button left of the "Train" button. Skips hidden entries,
    shows the total price in its tooltip and buys as many as you can afford.
  * Settings > AddOns > Trainer Buddy (or /tb): options, plus every hidden
    entry grouped by trainer, with an Unhide button per entry.
  * Optional: upgrade action bar spells to the new rank after training, and
    a popup bar for newly learned spells.
]]

local ADDON = ...

local TRAINALL_WIDTH = 84  -- width of the Train All button

local db            -- = TrainerBuddyCharDB, set on ADDON_LOADED
local trainAllButton
local category      -- Settings category
local SetAutoReplace, autoCheck  -- forward
local RefreshPopup               -- forward

---------------------------------------------------------------------------
-- Hidden list
---------------------------------------------------------------------------

-- db.hidden is keyed by spell / recipe name (all ranks are hidden together)
local function IsHidden(name)
    return name ~= nil and db ~= nil and db.hidden[name] ~= nil
end

local function CountHidden()
    local n = 0
    for _ in pairs(db.hidden) do n = n + 1 end
    return n
end

-- Remember what the trainer's own tooltip shows, so the hidden list can show
-- the same description later, even for spells you have not learned yet.
local function CaptureTooltip(entry, index)
    if entry.spellID or (entry.lines and #entry.lines > 0) then return end
    if not index or not (C_TooltipInfo and C_TooltipInfo.GetTrainerService) then return end
    local ok, data = pcall(C_TooltipInfo.GetTrainerService, index)
    if not ok or not data then return end
    if TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(data) end

    if data.id and C_Spell.GetSpellName(data.id) == entry.name then
        entry.spellID = data.id
        return
    end
    local lines = {}
    for _, line in ipairs(data.lines or {}) do
        if TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(line) end
        local r, g, b = 1, 1, 1
        local c = line.leftColor
        if c then
            if c.GetRGB then r, g, b = c:GetRGB() else r, g, b = c.r or 1, c.g or 1, c.b or 1 end
        end
        lines[#lines + 1] = { line.leftText, line.rightText, r, g, b }
    end
    if #lines > 0 then entry.lines = lines end
end

-- Which group a trainer entry belongs to: class, pet, or the profession's name.
local function GetCategory(index)
    local ttype = C_Trainer and C_Trainer.GetTrainerType and C_Trainer.GetTrainerType()
    if ttype == Enum.TrainerType.Pet then return "Pet trainer" end
    if ttype == Enum.TrainerType.Tradeskills then
        local ok, line = pcall(GetTrainerServiceSkillLine, index)
        if ok and type(line) == "string" and line ~= "" then return line end
        return "Professions"
    end
    return "Class trainer"
end

local function Backfill(entry, texture, index)
    if not entry then return end
    if not entry.icon and texture then entry.icon = texture end
    CaptureTooltip(entry, index)
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
                local name, _, texture = GetTrainerServiceInfo(data.skillIndex)
                if IsHidden(name) then
                    Backfill(db.hidden[name], texture, data.skillIndex)
                    toRemove = toRemove or {}
                    toRemove[#toRemove + 1] = node
                end
            end
        end
        if toRemove and not db.showHidden then
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

local function HideEntry(name, icon, index)
    local entry = { name = name, icon = icon, category = GetCategory(index) }
    db.hidden[name] = entry
    CaptureTooltip(entry, index)
    RefreshTrainer()
    RefreshOptions()
end

local function UnhideEntry(name)
    db.hidden[name] = nil
    RefreshTrainer()
    RefreshOptions()
end

local function ShowContextMenu(button)
    local index = button:GetID()
    local name, _, icon = GetTrainerServiceInfo(index)
    if not name then return end

    MenuUtil.CreateContextMenu(button, function(owner, root)
        root:CreateTitle(name)
        if IsHidden(name) then
            root:CreateButton("Unhide " .. name, function()
                UnhideEntry(name)
            end)
        else
            root:CreateButton("Hide " .. name, function()
                HideEntry(name, icon, index)
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
            GameTooltip:AddLine("|cff88ccffRight-click:|r hide / unhide this entry")
            GameTooltip:Show()
        end
    end)
end

-- Runs after every (re)build of a trainer row.
local function DecorateButton(button)
    if button == ClassTrainerFrame.skillStepButton then return end
    HookSkillButton(button)
    if db.showHidden then
        local name = GetTrainerServiceInfo(button:GetID())
        if IsHidden(name) then
            button.name:SetText((button.name:GetText() or name) .. "  |cffb08cff(hidden)|r")
        end
    end
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
            if serviceType == "available" and not IsHidden(name) then
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

-- The old global GetCoinTextureString is gone in this client; it lives in C_CurrencyInfo now.
local function CoinString(amount)
    if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
        return C_CurrencyInfo.GetCoinTextureString(amount)
    elseif GetCoinTextureString then
        return GetCoinTextureString(amount)
    elseif GetMoneyString then
        return GetMoneyString(amount, true)
    end
    return amount .. "c"
end

local function FormatCost(amount, isPet)
    if isPet then return amount .. " TP" end
    return CoinString(amount)
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
        GameTooltip:Show()
    end)
    trainAllButton:SetScript("OnLeave", GameTooltip_Hide)
end

local function SetupTrainerFrame()
    CreateTrainAllButton()

    hooksecurefunc("ClassTrainerFrame_Update", ApplyFilter)
    hooksecurefunc("ClassTrainerFrame_InitServiceButton", DecorateButton)

    -- integrate into the trainer's Settings dropdown
    if Menu and Menu.ModifyMenu then
        Menu.ModifyMenu("MENU_TRAINER_FILTER", function(dropdown, root)
            -- 1) "Hidden" goes next to Available / Unavailable / Already Known
            local filters
            for _, desc in root:EnumerateElementDescriptions() do
                if not (desc.IsCheckbox and desc:IsCheckbox()) then
                    for _ in desc:EnumerateElementDescriptions() do
                        filters = desc   -- the "Filters" submenu (it has children)
                        break
                    end
                    if filters then break end
                end
            end
            local target = filters or root
            target:CreateCheckbox("Hidden",
                function() return db.showHidden end,
                function()
                    db.showHidden = not db.showHidden
                    RefreshTrainer()
                end)

            -- 2) our own options below the Blizzard ones
            root:CreateDivider()
            root:CreateCheckbox("Auto-upgrade action bars",
                function() return db.autoReplace end,
                function() SetAutoReplace(not db.autoReplace) end)
            root:CreateCheckbox("Popup for new spells",
                function() return db.showPopup end,
                function()
                    db.showPopup = not db.showPopup
                    RefreshPopup()
                end)
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

local OTHER = "Other"
local HEADER_HEIGHT = 30

local function BuildList()
    local groups, names = {}, {}
    for key, entry in pairs(db.hidden) do
        local cat = entry.category or OTHER
        if not groups[cat] then groups[cat] = {}; names[#names + 1] = cat end
        local g = groups[cat]
        g[#g + 1] = {
            key = key, name = entry.name, icon = entry.icon,
        }
    end
    -- class first, pets next, then professions alphabetically, unknown last
    local function rank(c)
        if c == "Class trainer" then return 1 end
        if c == "Pet trainer" then return 2 end
        if c == OTHER then return 4 end
        return 3
    end
    table.sort(names, function(x, y)
        if rank(x) ~= rank(y) then return rank(x) < rank(y) end
        return x < y
    end)

    db.collapsed = db.collapsed or {}
    local list = {}
    for _, cat in ipairs(names) do
        local g = groups[cat]
        table.sort(g, function(x, y) return x.name < y.name end)
        list[#list + 1] = { header = true, category = cat, count = #g }
        if not db.collapsed[cat] then
            for _, item in ipairs(g) do list[#list + 1] = item end
        end
    end
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

local ROW_HEIGHT = 47      -- same as the rows in the trainer window
local QUESTION_MARK = 134400  -- INV_Misc_QuestionMark

local function EntryIcon(data)
    if data.icon then return data.icon end
    -- entries hidden before icons were stored: look the spell up by name
    local tex = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(data.name)
    return tex or QUESTION_MARK
end

local CARD_WIDTH = 400   -- the card stays compact, so Restore is right next to the entry

local function ShowEntryTooltip(card)
    local d = card.data
    local entry = db.hidden[d.key]
    GameTooltip:SetOwner(card, "ANCHOR_RIGHT")
    if entry and entry.spellID then
        GameTooltip:SetSpellByID(entry.spellID)
    elseif entry and entry.lines and #entry.lines > 0 then
        for _, l in ipairs(entry.lines) do
            if l[2] and l[2] ~= "" then
                GameTooltip:AddDoubleLine(l[1] or "", l[2], l[3], l[4], l[5], 1, 1, 1)
            else
                GameTooltip:AddLine(l[1] or "", l[3], l[4], l[5], true)
            end
        end
    else
        -- not captured yet (visit the trainer once): try a lookup by name
        local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(d.name)
        if info and info.spellID then
            GameTooltip:SetSpellByID(info.spellID)
        else
            GameTooltip:AddLine(d.name, 1, 1, 1)
            GameTooltip:AddLine("Open this trainer once to load the description.", 0.6, 0.6, 0.6, true)
        end
    end
    GameTooltip:Show()
end

local function InitRow(row, data)
    if not row.card then
        row:SetHeight(ROW_HEIGHT)

        local card = CreateFrame("Button", nil, row, "BackdropTemplate")
        card:SetPoint("TOPLEFT", 6, -2)
        card:SetSize(CARD_WIDTH, ROW_HEIGHT - 4)
        card:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        card:SetBackdropColor(0.07, 0.07, 0.09, 0.8)
        card:SetBackdropBorderColor(0.28, 0.28, 0.32, 1)
        row.card = card

        -- thin gold accent on the left edge
        local accent = card:CreateTexture(nil, "ARTWORK")
        accent:SetColorTexture(0.85, 0.65, 0.15, 0.9)
        accent:SetPoint("TOPLEFT", 1, -1)
        accent:SetPoint("BOTTOMLEFT", 1, 1)
        accent:SetWidth(3)

        card.iconBG = card:CreateTexture(nil, "BORDER")
        card.iconBG:SetSize(36, 36)
        card.iconBG:SetPoint("LEFT", 12, 0)
        card.iconBG:SetColorTexture(0, 0, 0, 1)
        card.icon = card:CreateTexture(nil, "ARTWORK")
        card.icon:SetSize(32, 32)
        card.icon:SetPoint("CENTER", card.iconBG)
        card.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        card.btn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
        card.btn:SetSize(80, 22)
        card.btn:SetPoint("RIGHT", -10, 0)
        card.btn:SetText("Unhide")

        card.nameText = card:CreateFontString(nil, "ARTWORK", "GameFontNormal")
                card.nameText:SetPoint("LEFT", card.iconBG, "RIGHT", 10, 0)
        card.nameText:SetPoint("RIGHT", card.btn, "LEFT", -8, 0)
        card.nameText:SetJustifyH("LEFT")
        card.nameText:SetWordWrap(false)

        card:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.14, 0.12, 0.06, 0.95)
            self:SetBackdropBorderColor(1, 0.82, 0, 1)
            ShowEntryTooltip(self)
        end)
        card:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.07, 0.07, 0.09, 0.8)
            self:SetBackdropBorderColor(0.28, 0.28, 0.32, 1)
            GameTooltip_Hide()
        end)
    end

    local card = row.card
    card.data = data
    card.icon:SetTexture(EntryIcon(data))
    card.nameText:SetText(data.name)
    card.btn:SetScript("OnClick", function() RestoreEntry(data.key) end)
end

local function InitHeader(row, data)
    if not row.label then
        row:SetHeight(HEADER_HEIGHT)
        local btn = CreateFrame("Button", nil, row)
        btn:SetPoint("TOPLEFT", 6, -2)
        btn:SetSize(CARD_WIDTH, HEADER_HEIGHT - 4)
        row.btn = btn
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 0.82, 0, 0.08)
        row.arrow = btn:CreateTexture(nil, "ARTWORK")
        row.arrow:SetSize(14, 14)
        row.arrow:SetPoint("LEFT", 8, 0)
        row.label = btn:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        row.label:SetPoint("LEFT", row.arrow, "RIGHT", 6, 0)
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
    end
    local collapsed = db.collapsed and db.collapsed[data.category]
    row.arrow:SetTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    row.label:SetText(data.category .. "  |cffaaaaaa(" .. data.count .. ")|r")
    row.btn:SetScript("OnClick", function()
        db.collapsed = db.collapsed or {}
        db.collapsed[data.category] = not db.collapsed[data.category] or nil
        RefreshOptions()
    end)
end

local function BuildOptions()
    local panel = CreateFrame("Frame")
    panel.name = "Trainer Buddy"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Trainer Buddy")

    local function Section(text, anchor, offsetY)
        local h = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        h:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, offsetY)
        h:SetText(text)
        local line = panel:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(1, 0.82, 0, 0.35)
        line:SetHeight(1)
        line:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -4)
        line:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
        return h
    end

    -- Section 1: options
    local optHeader = Section("Options", title, -16)

    local auto = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    auto:SetPoint("TOPLEFT", optHeader, "BOTTOMLEFT", -4, -12)
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

    -- Section 2: hidden entries
    local hidHeader = Section("Hidden entries", pop, -14)

    local restoreAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    restoreAll:SetSize(110, 22)
    restoreAll:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    restoreAll:SetPoint("TOP", hidHeader, "TOP", 0, 2)
    restoreAll:SetText("Unhide all")
    restoreAll:SetScript("OnClick", function()
        wipe(db.hidden)
        RefreshOptions()
        RefreshTrainer()
    end)

    scrollBox = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", hidHeader, "BOTTOMLEFT", 0, -14)
    scrollBox:SetPoint("BOTTOMRIGHT", -36, 16)
    local scrollBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtentCalculator(function(index, elementData)
        return elementData.header and HEADER_HEIGHT or ROW_HEIGHT
    end)
    view:SetPadding(0, 0, 0, 0, 2)
    view:SetElementFactory(function(factory, elementData)
        if elementData.header then
            factory("Frame", InitHeader)
        else
            factory("Button", InitRow)
        end
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    emptyText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    emptyText:SetPoint("TOP", scrollBox, "TOP", 0, -20)
    emptyText:SetText("Nothing hidden.")

    panel:SetScript("OnShow", function()
        auto:SetChecked(db.autoReplace)
        pop:SetChecked(db.showPopup)
        RefreshOptions()
    end)

    category = Settings.RegisterCanvasLayoutCategory(panel, "Trainer Buddy")
    Settings.RegisterAddOnCategory(category)
end

---------------------------------------------------------------------------
-- "New spells" popup bar: freshly learned spells waiting to be dragged onto
-- your real action bars. Stays until you close it with the X.
---------------------------------------------------------------------------

local MAX_ACTION_SLOT = 180
local ICON_SIZE, ICON_GAP, PER_ROW = 45, 2, 6
local popup, popupButtons = nil, {}
local testSpells = {}   -- /tb test: shown even if already on a bar, never saved
local testActive = false  -- /tb test keeps the popup open even with no spells
local layout = {}   -- fixed slot positions: spellID or false (placed spells leave a hole)

local function BarCount(spellID)
    local n = 0
    for slot = 1, MAX_ACTION_SLOT do
        local actionType, id = GetActionInfo(slot)
        if actionType == "spell" and id == spellID then n = n + 1 end
    end
    return n
end

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

-- Same pieces the real action buttons are built from
local SLOT_ATLAS   = "UI-HUD-ActionBar-IconFrame-Slot"        -- empty slot
local BG_ATLAS     = "UI-HUD-ActionBar-IconFrame-Background"  -- behind the icon
local BORDER_ATLAS = "UI-HUD-ActionBar-IconFrame"             -- frame around the icon
local MASK_ATLAS   = "UI-HUD-ActionBar-IconFrame-Mask"        -- rounded icon corners
local HILITE_ATLAS = "UI-HUD-ActionBar-IconFrame-Mouseover"

local function HasAtlas(name)
    return type(name) == "string" and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local decorWarned

-- Decorations must never break the popup itself: report once and carry on.
local function SafeDecor(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and not decorWarned then
        decorWarned = true
        print("|cff66ccffTrainer Buddy|r: popup " .. what .. " failed: " .. tostring(err))
    end
    return ok
end

-- The popup is a small Blizzard window, styled like the Spellbook: portrait
-- frame with the addon logo, title bar, parchment page, and the real action
-- bar pieces (slots, dividers, border art) on the page.
local PAPER    = "Interface\\AddOns\\TrainerBuddy\\paper.tga"
local PORTRAIT = "Interface\\AddOns\\TrainerBuddy\\portrait.tga"
local FRAME_PAD = 14   -- side and bottom padding around the bar
local BAR_TOP  = 67   -- bar starts just below the portrait circle, same gap as the other sides
local dividerPool, vDividerPool

local function CreatePopup()
    local ok, frame = pcall(CreateFrame, "Frame", "TrainerBuddyNewSpells", UIParent, "PortraitFrameTemplate")
    if not ok then
        SafeDecor("window", error, frame, 0)
        frame = CreateFrame("Frame", "TrainerBuddyNewSpells", UIParent)
    end
    popup = frame
    popup:SetFrameStrata("MEDIUM")
    popup:SetClampedToScreen(true)
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")

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

    SafeDecor("title", function()
        if popup.SetTitle then popup:SetTitle("Place your new spells")
        elseif popup.TitleContainer then popup.TitleContainer.TitleText:SetText("Place your new spells") end
    end)
    SafeDecor("portrait", function()
        if popup.SetPortraitToAsset then popup:SetPortraitToAsset(PORTRAIT)
        elseif popup.PortraitContainer then popup.PortraitContainer.portrait:SetTexture(PORTRAIT) end
    end)
    SafeDecor("close button", function()
        popup.CloseButton:SetScript("OnClick", function()
            wipe(db.newSpells)
            wipe(testSpells)
            wipe(layout)
            testActive = false
            popup:Hide()
        end)
    end)

    -- parchment page under the title bar
    SafeDecor("paper", function()
        local paper = popup:CreateTexture(nil, "ARTWORK", nil, -2)
        paper:SetTexture(PAPER)
        paper:SetPoint("TOPLEFT", 4, -22)
        paper:SetPoint("BOTTOMRIGHT", -4, 4)
    end)

    -- the slots live on the page, framed like the real action bar
    popup.bar = CreateFrame("Frame", nil, popup)
    SafeDecor("bar art", function()
        local art = popup.bar:CreateTexture(nil, "BACKGROUND", nil, -3)
        art:SetAtlas("UI-HUD-ActionBar-Frame")
        art:SetPoint("TOPLEFT", -6, 6)
        art:SetPoint("BOTTOMRIGHT", 4, -5)
    end)
    SafeDecor("dividers", function()
        dividerPool = CreateFramePool("FRAME", popup.bar, "HorizontalDividerTemplate")
        vDividerPool = CreateFramePool("FRAME", popup.bar, "VerticalDividerTemplate")
    end)
    popup:Hide()
end

-- One action-bar-like slot: empty slot art, or background + masked icon + frame.
local function GetButton(i)
    local b = popupButtons[i]
    if b then return b end
    b = CreateFrame("Button", nil, popup.bar)
    b:SetSize(ICON_SIZE, ICON_SIZE)

    b.slot = b:CreateTexture(nil, "BACKGROUND", nil, 0)
    b.slot:SetAllPoints()
    b.bg = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.bg:SetAllPoints()
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetAllPoints()

    if HasAtlas(SLOT_ATLAS) then
        b.slot:SetAtlas(SLOT_ATLAS)
        b.bg:SetAtlas(BG_ATLAS)
        b.border:SetAtlas(BORDER_ATLAS)
        if b.CreateMaskTexture and HasAtlas(MASK_ATLAS) then
            local mask = b:CreateMaskTexture()
            mask:SetAtlas(MASK_ATLAS)
            mask:SetAllPoints(b.icon)
            b.icon:AddMaskTexture(mask)
        end
        b:SetHighlightTexture(HILITE_ATLAS, "ADD")
        b.icon:SetTexCoord(0, 1, 0, 1)
    else
        b.slot:SetColorTexture(0, 0, 0, 0.5)
        b.bg:Hide()
        b.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
        b.border:ClearAllPoints()
        b.border:SetPoint("CENTER")
        b.border:SetSize(ICON_SIZE * 1.8, ICON_SIZE * 1.8)
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end

    b:RegisterForDrag("LeftButton")
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnDragStart", function(self) if self.spellID then PickupSpellByID(self.spellID) end end)
    b:SetScript("OnClick", function(self) if self.spellID then PickupSpellByID(self.spellID) end end)
    b:SetScript("OnEnter", function(self)
        if not self.spellID then return end
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

    -- spells still waiting to be placed
    local valid = {}
    for spellID in pairs(db.newSpells) do
        if IsPlaceable(spellID) and not IsOnBar(spellID) then
            valid[spellID] = true
        else
            db.newSpells[spellID] = nil
        end
    end
    for spellID, baseline in pairs(testSpells) do
        -- a test spell counts as placed once it appears on one more bar slot
        if IsPlaceable(spellID) and BarCount(spellID) <= baseline then valid[spellID] = true end
    end

    -- placed spells leave a hole; nothing else moves
    local hadAny, placed = false, {}
    for i = 1, #layout do
        local id = layout[i]
        if id then
            hadAny = true
            if valid[id] then placed[id] = true else layout[i] = false end
        end
    end
    local fresh = {}
    for id in pairs(valid) do
        if not placed[id] then fresh[#fresh + 1] = id end
    end
    table.sort(fresh, function(a, b)
        return (C_Spell.GetSpellName(a) or "") < (C_Spell.GetSpellName(b) or "")
    end)
    for _, id in ipairs(fresh) do
        local put = false
        for i = 1, #layout do
            if not layout[i] then layout[i] = id; put = true; break end
        end
        if not put then layout[#layout + 1] = id end
    end

    -- everything placed: the window goes away on its own
    if next(valid) == nil and hadAny then
        wipe(layout)
        wipe(testSpells)
        testActive = false
    end
    if next(valid) == nil and #layout > 0 then wipe(layout) end

    if not (db.showPopup or testActive) or (next(valid) == nil and not testActive) then
        popup:Hide()
        return
    end
    local list = layout

    -- always whole rows of PER_ROW slots; empty ones are drawn as empty slots
    local slots = math.max(math.ceil(#layout / PER_ROW), 1) * PER_ROW   -- never shrinks while spells remain
    for i = 1, slots do
        local b = GetButton(i)
        local col, row = (i - 1) % PER_ROW, math.floor((i - 1) / PER_ROW)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", popup.bar, "TOPLEFT", col * (ICON_SIZE + ICON_GAP), -row * (ICON_SIZE + ICON_GAP))
        local spellID = list[i] or nil
        b.spellID = spellID
        local filled = spellID ~= nil
        if filled then b.icon:SetTexture(C_Spell.GetSpellTexture(spellID)) end
        b.icon:SetShown(filled)
        b.border:SetShown(filled)
        b.bg:SetShown(filled and b.bg:GetAtlas() ~= nil)
        b.slot:SetShown(not filled or not HasAtlas(SLOT_ATLAS))  -- empty slots show the slot art
        b:Show()
    end
    for i = slots + 1, #popupButtons do popupButtons[i]:Hide() end

    local cols = math.min(slots, PER_ROW)
    local rows = math.ceil(slots / PER_ROW)
    local barW = cols * (ICON_SIZE + ICON_GAP) - ICON_GAP
    local barH = rows * (ICON_SIZE + ICON_GAP) - ICON_GAP
    popup.bar:SetSize(barW, barH)
    local width = math.max(barW + 2 * FRAME_PAD, 236)   -- wide enough for the title
    popup:SetSize(width, BAR_TOP + barH + FRAME_PAD)
    popup.bar:ClearAllPoints()
    popup.bar:SetPoint("TOP", popup, "TOP", 0, -BAR_TOP)

    -- golden dividers like the real bar: between neighbours in a row, and between rows
    if dividerPool and vDividerPool then
        SafeDecor("dividers", function()
            dividerPool:ReleaseAll()
            vDividerPool:ReleaseAll()
            for i = 1, slots do
                local b = popupButtons[i]
                local col, row = (i - 1) % PER_ROW, math.floor((i - 1) / PER_ROW)
                if col > 0 then
                    local d = dividerPool:Acquire()
                    d:ClearAllPoints()
                    d:SetPoint("TOP", b, "TOP", 0, 0)
                    d:SetPoint("BOTTOM", b, "BOTTOM", 0, 0)
                    d:SetPoint("RIGHT", b, "LEFT", 5, 0)
                    d:SetFrameLevel(b:GetFrameLevel() + 2)
                    d:Show()
                end
                if row > 0 then
                    local d = vDividerPool:Acquire()
                    d:ClearAllPoints()
                    d:SetPoint("LEFT", b, "LEFT", 0, 0)
                    d:SetPoint("RIGHT", b, "RIGHT", 0, 0)
                    d:SetPoint("BOTTOM", b, "TOP", 0, -5)
                    d:SetFrameLevel(b:GetFrameLevel() + 2)
                    d:Show()
                end
            end
        end)
    end
    popup:Show()
end

-- /tb test [count]: fill the popup with random spells from your action bars,
-- so you can look at it without learning anything. Run again to clear it.
local function TestPopup(count)
    -- always replaces the previous test; no number = empty popup (like 0). Close it with the X.
    wipe(testSpells)
    wipe(layout)
    testActive = true
    count = tonumber(count) or 0
    local pool, seen = {}, {}
    for slot = 1, MAX_ACTION_SLOT do
        local actionType, id = GetActionInfo(slot)
        if actionType == "spell" and id and not seen[id] and IsPlaceable(id) then
            seen[id] = true
            pool[#pool + 1] = id
        end
    end
    count = math.min(math.max(count, 0), #pool)
    for _ = 1, count do
        local i = math.random(#pool)
        local id = table.remove(pool, i)
        testSpells[id] = BarCount(id)
    end
    RefreshPopup()
    print(("|cff66ccffTrainer Buddy|r: test popup with %d spell(s). Close it with the X."):format(count))
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
                local rankText = newRank and (" (rank " .. newRank .. ")") or ""
                ClearCursor()
                C_Spell.PickupSpell(newID)
                PlaceAction(slot)
                ClearCursor()
                print(("|cff66ccffTrainer Buddy|r: action slot %d -> %s%s"):format(slot, newName, rankText))
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

-- Profession ranks (Apprentice..Artisan) are separate spells; the one you actually
-- place on a bar is the profession itself (Fishing, Cooking, Alchemy...), at its highest rank.
local PROFESSION_RANKS = {
    {7620, 7731, 7732, 18248, 33095, 51294, 110410, 131474},   -- Fishing
    {2550, 3102, 3413, 18260, 33359, 51296, 158765},           -- Cooking
    {3273, 3274, 7924, 10846, 27028, 45542},                   -- First Aid
    {2575, 2576, 3564, 10248, 29354, 50310},                   -- Mining
    {2259, 3101, 3464, 11611, 28596, 51304},                   -- Alchemy
    {2018, 3100, 3538, 9785, 29844, 51300},                    -- Blacksmithing
    {7411, 7412, 7413, 13920, 28029, 51313},                   -- Enchanting
    {4036, 4037, 4038, 12656, 30350, 51306},                   -- Engineering
    {25229, 25230, 28894, 28895, 28897, 51311},                -- Jewelcrafting
    {2108, 3104, 3811, 10662, 32549, 51302},                   -- Leatherworking
    {3908, 3909, 3910, 12180, 26790, 51309},                   -- Tailoring
    {45357, 45358, 45359, 45360, 45361, 45363},                -- Inscription
}

local function ResolveProfessionSpell(spellID)
    for _, family in ipairs(PROFESSION_RANKS) do
        for _, id in ipairs(family) do
            if id == spellID then
                for i = #family, 1, -1 do
                    if IsPlayerSpell(family[i]) and IsPlaceable(family[i]) then return family[i] end
                end
                return spellID
            end
        end
    end
    return spellID
end

local function QueueLearnedSpell(spellID)
    if not db or not spellID then return end
    if db.autoReplace then
        pendingSpells[spellID] = true
        -- let several spells from one "Train All" arrive, then handle them together
        C_Timer.After(0.5, ProcessPendingSpells)
    end
    -- after the auto-upgrade had its chance, show what is still not on a bar
    C_Timer.After(1.2, function() AddToPopup(ResolveProfessionSpell(spellID)) end)
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
        TrainerBuddyCharDB = TrainerBuddyCharDB or {}
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
local function PrintHelp()
    local c = "|cff66ccff"
    print(c .. "Trainer Buddy|r commands:")
    print("  " .. c .. "/tb|r - open the settings and hidden list")
    print("  " .. c .. "/tb auto|r - toggle action bar auto-upgrade")
    print("  " .. c .. "/tb popup|r - toggle the new spells popup")
    print("  " .. c .. "/tb test [count]|r - preview the popup with N random spells (no number: empty)")
    print("  " .. c .. "/tb help|r - this list")
end

SlashCmdList["TRAINERBUDDY"] = function(msg)
    msg = strtrim((msg or ""):lower())
    if msg == "" then
        if category then Settings.OpenToCategory(category:GetID()) end
    elseif msg == "auto" then
        SetAutoReplace(not db.autoReplace)
    elseif msg == "popup" then
        db.showPopup = not db.showPopup
        print("|cff66ccffTrainer Buddy|r: new-spells popup " .. (db.showPopup and "ON" or "OFF"))
        RefreshPopup()
    elseif msg == "test" or msg:match("^test%s+%d+$") then
        TestPopup(msg:match("^test%s+(%d+)"))
    else
        PrintHelp()  -- "help" and anything unknown
    end
end
