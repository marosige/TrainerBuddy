--[[
Trainer Buddy
  * Right-click an entry in the class / profession trainer window:
      - hide this rank only
      - hide every rank of that spell / recipe
  * Hidden entries disappear from the trainer list.
  * "Train All" button left of the "Train" button. Skips hidden entries,
    shows the total price and buys as many as you can afford.
  * Settings > AddOns > Trainer Buddy (or /tb) lists everything you
    hid, with an Unhide button per entry.
]]

local ADDON = ...

-- Layout tweaks for the Train All button / cost line.
local TRAINALL_WIDTH  = 84

local db            -- = TrainerBuddyCharDB, set on ADDON_LOADED
local trainAllButton
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
    if not entry.category and index then entry.category = GetCategory(index) end
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
                local name, _, texture, _, sub = GetTrainerServiceInfo(data.skillIndex)
                if IsHidden(name, sub) then
                    Backfill(db.hidden[AllKey(name)] or db.hidden[RankKey(name, sub or "")], texture, data.skillIndex)
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

local function HideEntry(name, sub, allRanks, icon, index)
    local entry
    if allRanks then
        entry = { name = name, icon = icon, noRank = (sub == "") or nil }
        db.hidden[AllKey(name)] = entry
        -- rank-specific entries for this spell are redundant now
        for key, other in pairs(db.hidden) do
            if other.name == name and other.sub then
                db.hidden[key] = nil
            end
        end
    else
        entry = { name = name, sub = sub, icon = icon }
        db.hidden[RankKey(name, sub)] = entry
    end
    entry.category = index and GetCategory(index) or nil
    CaptureTooltip(entry, index)
    RefreshTrainer()
    RefreshOptions()
end

local function UnhideEntry(name, sub)
    db.hidden[AllKey(name)] = nil
    db.hidden[RankKey(name, sub)] = nil
    RefreshTrainer()
    RefreshOptions()
end

local function ShowContextMenu(button)
    local index = button:GetID()
    local name, _, icon, _, sub = GetTrainerServiceInfo(index)
    if not name then return end
    sub = sub or ""

    MenuUtil.CreateContextMenu(button, function(owner, root)
        root:CreateTitle(name)
        if IsHidden(name, sub) then
            root:CreateButton("Unhide " .. name, function()
                UnhideEntry(name, sub)
            end)
        else
            root:CreateButton("Hide " .. name, function()
                HideEntry(name, sub, true, icon, index)
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
        local name, _, _, _, sub = GetTrainerServiceInfo(button:GetID())
        if IsHidden(name, sub) then
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
            key = key, name = entry.name, sub = entry.sub, icon = entry.icon, noRank = entry.noRank,
            sortName = entry.name .. (entry.sub or ""),
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
        table.sort(g, function(x, y) return x.sortName < y.sortName end)
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
            if d.sub then GameTooltip:AddLine(d.sub) end
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
        card.nameText:SetPoint("TOPLEFT", card.iconBG, "TOPRIGHT", 10, -3)
        card.nameText:SetPoint("RIGHT", card.btn, "LEFT", -8, 0)
        card.nameText:SetJustifyH("LEFT")
        card.nameText:SetWordWrap(false)
        card.subText = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        card.subText:SetPoint("TOPLEFT", card.nameText, "BOTTOMLEFT", 0, -3)
        card.subText:SetJustifyH("LEFT")
        card.subText:SetTextColor(0.65, 0.65, 0.65)

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
    card.subText:SetText("")
    card.nameText:ClearAllPoints()
    card.nameText:SetPoint("LEFT", card.iconBG, "RIGHT", 10, 0)
    card.nameText:SetPoint("RIGHT", card.btn, "LEFT", -8, 0)
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
