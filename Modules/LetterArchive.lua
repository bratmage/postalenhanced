local Postal = LibStub("AceAddon-3.0"):GetAddon("PostalEnhanced")
local Postal_LetterArchive = Postal:NewModule("LetterArchive", "AceEvent-3.0", "AceHook-3.0")

Postal_LetterArchive.description = "Keeps permanent per-character copies of sent and saved letters."

local _G = getfenv(0)
local archiveFrame
local openMailSaveButton
local sendDelayFrame
local originalMailFrameWidth
local hiddenVanillaMailRegions
local currentArchive = "sent"
local selectedIndex
local archiveFilters = {
	sent = "",
	saved = "",
}
local visibleRows = 7
local rowHeight = 32
local listWidth = 225
local bodyWidth = 365
local bodyHeight = 315
local archiveMailFrameWidth = 720
local maxBodyLength = 500
local maxComposeLength = 8000
local maxSubjectLength = 50
local tokenLength = 6
local sendDelaySeconds = 0.75

StaticPopupDialogs["POSTAL_LETTERARCHIVE_DELETE"] = {
	text = "Delete this archived letter?",
	button1 = DELETE,
	button2 = CANCEL,
	OnAccept = function()
		Postal_LetterArchive:DeleteSelected()
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
}

local function LetterDate()
	return date("%Y-%m-%d %H:%M")
end

local function StopSendDelay()
	if sendDelayFrame then
		sendDelayFrame:SetScript("OnUpdate", nil)
		sendDelayFrame:Hide()
	end
end

local function SetArchiveFrameSize(enabled)
	if not MailFrame then return end
	if not originalMailFrameWidth then
		originalMailFrameWidth = MailFrame:GetWidth()
	end
	if enabled then
		MailFrame:SetWidth(archiveMailFrameWidth)
	else
		MailFrame:SetWidth(originalMailFrameWidth)
	end
end

local function IsPfUIStyled()
	return (_G["pfUI"] or (IsAddOnLoaded and IsAddOnLoaded("pfUI"))) and MailFrame and MailFrame.backdrop
end

local function SetVanillaMailArtHidden(hidden)
	if not MailFrame or IsPfUIStyled() then return end

	if hidden then
		if hiddenVanillaMailRegions then return end
		hiddenVanillaMailRegions = {}
		local regions = { MailFrame:GetRegions() }
		for i = 1, #regions do
			local region = regions[i]
			if region and region.GetObjectType and region:GetObjectType() == "Texture" then
				tinsert(hiddenVanillaMailRegions, {
					region = region,
					wasShown = region:IsShown(),
				})
				region:Hide()
			end
		end
	elseif hiddenVanillaMailRegions then
		for i = 1, #hiddenVanillaMailRegions do
			local entry = hiddenVanillaMailRegions[i]
			if entry.region and entry.wasShown then
				entry.region:Show()
			end
		end
		hiddenVanillaMailRegions = nil
	end
end

local function UpdateVanillaArchiveBackdrop()
	if not archiveFrame or not archiveFrame.vanillaBackdrop then return end
	if archiveFrame:IsVisible() and not IsPfUIStyled() then
		archiveFrame.vanillaBackdrop:Show()
	else
		archiveFrame.vanillaBackdrop:Hide()
	end
end

local function GetArchive(kind)
	local db = Postal.db.char.LetterArchive
	if not db then
		Postal.db.char.LetterArchive = { sent = {}, saved = {} }
		db = Postal.db.char.LetterArchive
	end
	if not db[kind] then db[kind] = {} end
	return db[kind]
end

local function SafeText(text)
	if text and text ~= "" then return text end
	return "(no subject)"
end

local function HasBodyText(text)
	return text and strtrim(text) ~= ""
end

local function FilterMatch(text, filter)
	if not filter or filter == "" then return true end
	if not text then return false end
	return strfind(strupper(text), strupper(filter), 1, true) ~= nil
end

local function LetterMatchesFilter(kind, letter, filter)
	if kind == "sent" then
		return FilterMatch(letter.to, filter)
	end
	return FilterMatch(letter.to, filter) or FilterMatch(letter.from, filter)
end

local function GetMultipartMarker(token, part, total)
	return format("[[Postal:%s:%d/%d]]\n", token, part, total)
end

local function ParseMultipartSubject(subject)
	if not subject then return end
	local token, part, total, cleanSubject = strmatch(subject, "^%[P([0-9A-F]+)%-(%d+)/(%d+)%]%s*(.*)$")
	if token then
		return token, tonumber(part), tonumber(total), cleanSubject
	end
end

local function ParseMultipartBody(body)
	if not body then return end
	local token, part, total, cleanBody = strmatch(body, "^%[%[Postal:([0-9A-F]+):(%d+)/(%d+)%]%]\n?(.*)$")
	if token then
		return token, tonumber(part), tonumber(total), cleanBody or ""
	end
end

local function GetPartBodyLength(total)
	local marker = GetMultipartMarker(strrep("F", tokenLength), total, total)
	local length = maxBodyLength - strlen(marker)
	if length < 100 then length = 100 end
	return length
end

local function GetSplitPartCount(body)
	local length = strlen(body or "")
	if length == 0 then return 1 end
	local total = math.ceil(length / GetPartBodyLength(2))
	if total < 2 then total = 2 end
	while true do
		local nextTotal = math.ceil(length / GetPartBodyLength(total))
		if nextTotal == total then return total end
		total = nextTotal
	end
end

local function GetLimitedSubject(subject)
	subject = subject or ""
	if strlen(subject) > maxSubjectLength then
		subject = strsub(subject, 1, maxSubjectLength)
	end
	return subject
end

local function GenerateToken()
	return format("%06X", random(0, 0xFFFFFF))
end

local function SplitBody(body, total)
	local parts = {}
	local start = 1
	local length = strlen(body)
	local partLength = GetPartBodyLength(total)
	while start <= length do
		local finish = start + partLength - 1
		if finish < length then
			local splitAt
			for i = finish, start + 350, -1 do
				local char = strsub(body, i, i)
				if char == "\n" or char == " " then
					splitAt = i
					break
				end
			end
			if splitAt then finish = splitAt end
		else
			finish = length
		end
		tinsert(parts, strsub(body, start, finish))
		start = finish + 1
		while strsub(body, start, start) == " " do
			start = start + 1
		end
	end
	return parts
end

local function ResolveOpenMailID()
	local mailID = OpenMailFrame and OpenMailFrame.openMailID
	if not mailID then mailID = InboxFrame and InboxFrame.openMailID end
	if mailID and mailID >= 1 and mailID <= GetInboxNumItems() then
		return mailID
	end
end

local function CaptureOutgoingContents()
	local contents = {
		items = {},
		money = 0,
		cod = 0,
	}

	for i = 1, ATTACHMENTS_MAX_SEND do
		local name, texture, count, quality = GetSendMailItem(i)
		if name then
			tinsert(contents.items, {
				name = name,
				count = count or 1,
				texture = texture,
				quality = quality,
			})
		end
	end

	if SendMailMoney and MoneyInputFrame_GetCopper then
		contents.money = MoneyInputFrame_GetCopper(SendMailMoney) or 0
	end
	if SendMailCOD and MoneyInputFrame_GetCopper then
		contents.cod = MoneyInputFrame_GetCopper(SendMailCOD) or 0
	end

	if #contents.items == 0 and contents.money == 0 and contents.cod == 0 then
		return nil
	end
	return contents
end

local function IsPlainLetterAttachment(name, link)
	if not name then return true end
	local lowerName = strlower(name)
	if lowerName == "plain letter" or lowerName == "letter" then return true end
	return not link
end

local function CaptureInboxContents(mailID)
	local contents = {
		items = {},
		money = 0,
		cod = 0,
	}
	local _, _, _, _, money, cod = GetInboxHeaderInfo(mailID)
	contents.money = money or 0
	contents.cod = cod or 0

	for i = 1, ATTACHMENTS_MAX_RECEIVE do
		local name, texture, count, quality = GetInboxItem(mailID, i)
		local link = GetInboxItemLink and GetInboxItemLink(mailID, i)
		if name and not IsPlainLetterAttachment(name, link) then
			tinsert(contents.items, {
				name = name,
				count = count or 1,
				texture = texture,
				quality = quality,
				link = link,
			})
		end
	end

	if #contents.items == 0 and contents.money == 0 and contents.cod == 0 then
		return nil
	end
	return contents
end

local function MergeContents(target, source)
	if not source then return target end
	if not target then
		target = { items = {}, money = 0, cod = 0 }
	end
	target.money = (target.money or 0) + (source.money or 0)
	target.cod = (target.cod or 0) + (source.cod or 0)
	if source.items then
		for i = 1, #source.items do
			tinsert(target.items, source.items[i])
		end
	end
	return target
end

local function GetContentsSummary(contents)
	if not contents then return nil end
	local summary = {}
	if contents.money and contents.money > 0 then
		tinsert(summary, "Money: "..Postal:GetMoneyString(contents.money))
	end
	if contents.cod and contents.cod > 0 then
		tinsert(summary, "COD: "..Postal:GetMoneyString(contents.cod))
	end
	if contents.items then
		for i = 1, #contents.items do
			local item = contents.items[i]
			if item.count and item.count > 1 then
				tinsert(summary, "Item: "..item.name.." x"..item.count)
			else
				tinsert(summary, "Item: "..item.name)
			end
		end
	end
	if #summary == 0 then return nil end
	return table.concat(summary, "\n")
end

function Postal_LetterArchive:OnEnable()
	if not archiveFrame then
		self:CreateMailTabs()
		self:CreateArchiveFrame()
		self:CreateOpenMailSaveButton()
		self:CreateSendDelayFrame()
	end
	if MailFrameTab3 then MailFrameTab3:Show() end
	if MailFrameTab4 then MailFrameTab4:Show() end
	if openMailSaveButton then openMailSaveButton:Show() end

	self:RawHook("SendMailFrame_Reset", true)
	self:RawHook("SendMailFrame_SendMail", true)
	self:RawHook("MailFrameTab_OnClick", true)
	self:RawHook("InboxFrame_OnClick", true)
	self:HookScript(SendMailBodyEditBox, "OnTextChanged")
	self:HookScript(SendMailSubjectEditBox, "OnTextChanged")

	self:RegisterEvent("MAIL_SHOW")
end

function Postal_LetterArchive:OnDisable()
	if archiveFrame then archiveFrame:Hide() end
	UpdateVanillaArchiveBackdrop()
	SetVanillaMailArtHidden(false)
	if openMailSaveButton then openMailSaveButton:Hide() end
	if MailFrameTab3 then MailFrameTab3:Hide() end
	if MailFrameTab4 then MailFrameTab4:Hide() end
	SetArchiveFrameSize(false)
	if PanelTemplates_SetNumTabs then
		PanelTemplates_SetNumTabs(MailFrame, 2)
	end
end

function Postal_LetterArchive:MAIL_SHOW()
	self:RegisterEvent("MAIL_CLOSED", "Reset")
	self:RegisterEvent("PLAYER_LEAVING_WORLD", "Reset")
	if openMailSaveButton then openMailSaveButton:Show() end
	self:ApplyComposeLimits()
end

function Postal_LetterArchive:Reset()
	self:UnregisterEvent("MAIL_CLOSED")
	self:UnregisterEvent("PLAYER_LEAVING_WORLD")
	self.multipartQueue = nil
	StopSendDelay()
	SetArchiveFrameSize(false)
	if archiveFrame then archiveFrame:Hide() end
	UpdateVanillaArchiveBackdrop()
	SetVanillaMailArtHidden(false)
	selectedIndex = nil
end

function Postal_LetterArchive:CreateSendDelayFrame()
	sendDelayFrame = CreateFrame("Frame")
	sendDelayFrame:Hide()
end

function Postal_LetterArchive:CreateMailTabs()
	if not _G["MailFrameTab3"] then
		local tab = CreateFrame("Button", "MailFrameTab3", MailFrame, "CharacterFrameTabButtonTemplate")
		tab:SetID(3)
		tab:SetText("Sent")
		tab:SetPoint("LEFT", MailFrameTab2, "RIGHT", -16, 0)
		tab:SetScript("OnClick", function() Postal_LetterArchive:ShowArchive("sent") end)
	end

	if not _G["MailFrameTab4"] then
		local tab = CreateFrame("Button", "MailFrameTab4", MailFrame, "CharacterFrameTabButtonTemplate")
		tab:SetID(4)
		tab:SetText("Saved")
		tab:SetPoint("LEFT", MailFrameTab3, "RIGHT", -16, 0)
		tab:SetScript("OnClick", function() Postal_LetterArchive:ShowArchive("saved") end)
	end

	if PanelTemplates_SetNumTabs then
		PanelTemplates_SetNumTabs(MailFrame, 4)
	end
	if PanelTemplates_EnableTab then
		PanelTemplates_EnableTab(MailFrame, 3)
		PanelTemplates_EnableTab(MailFrame, 4)
	end
end

function Postal_LetterArchive:CreateArchiveFrame()
	archiveFrame = CreateFrame("Frame", "PostalLetterArchiveFrame", MailFrame)
	archiveFrame:SetPoint("TOPLEFT", MailFrame, "TOPLEFT", 16, -60)
	archiveFrame:SetPoint("BOTTOMRIGHT", MailFrame, "BOTTOMRIGHT", -34, 76)
	archiveFrame:Hide()

	archiveFrame.vanillaBackdrop = CreateFrame("Frame", "PostalLetterArchiveVanillaBackdrop", archiveFrame)
	archiveFrame.vanillaBackdrop:SetPoint("TOPLEFT", archiveFrame, "TOPLEFT", -8, 18)
	archiveFrame.vanillaBackdrop:SetPoint("BOTTOMRIGHT", archiveFrame, "BOTTOMRIGHT", 8, -6)
	archiveFrame.vanillaBackdrop:SetFrameLevel(archiveFrame:GetFrameLevel())
	archiveFrame.vanillaBackdrop:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	archiveFrame.vanillaBackdrop:Hide()

	archiveFrame.title = archiveFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	archiveFrame.title:SetPoint("TOP", archiveFrame, "TOP", 0, 2)

	archiveFrame.empty = archiveFrame:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	archiveFrame.empty:SetPoint("CENTER", archiveFrame, "CENTER", -125, 0)
	archiveFrame.empty:SetText("No archived letters.")

	archiveFrame.filterLabel = archiveFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	archiveFrame.filterLabel:SetPoint("TOPLEFT", archiveFrame, "TOPLEFT", 4, -28)
	archiveFrame.filterLabel:SetText("Filter:")

	archiveFrame.filterBox = CreateFrame("EditBox", "PostalLetterArchiveFilterEditBox", archiveFrame, "InputBoxTemplate")
	archiveFrame.filterBox:SetWidth(listWidth - 54)
	archiveFrame.filterBox:SetHeight(20)
	archiveFrame.filterBox:SetAutoFocus(false)
	archiveFrame.filterBox:SetPoint("LEFT", archiveFrame.filterLabel, "RIGHT", 8, 0)
	archiveFrame.filterBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	archiveFrame.filterBox:SetScript("OnTextChanged", function(self)
		archiveFilters[currentArchive] = self:GetText() or ""
		selectedIndex = nil
		Postal_LetterArchive:UpdateList()
		Postal_LetterArchive:UpdateBody()
	end)

	archiveFrame.rows = {}
	for i = 1, visibleRows do
		local row = CreateFrame("Button", "PostalLetterArchiveRow"..i, archiveFrame)
		row:SetWidth(listWidth)
		row:SetHeight(rowHeight)
		if i == 1 then
			row:SetPoint("TOPLEFT", archiveFrame, "TOPLEFT", 0, -56)
		else
			row:SetPoint("TOPLEFT", archiveFrame.rows[i - 1], "BOTTOMLEFT", 0, 0)
		end
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		row:SetScript("OnClick", function(self) Postal_LetterArchive:SelectLetter(self.index) end)

		row.subject = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		row.subject:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -4)
		row.subject:SetWidth(listWidth - 10)
		row.subject:SetJustifyH("LEFT")

		row.meta = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		row.meta:SetPoint("TOPLEFT", row.subject, "BOTTOMLEFT", 0, -2)
		row.meta:SetWidth(listWidth - 10)
		row.meta:SetJustifyH("LEFT")

		archiveFrame.rows[i] = row
	end

	archiveFrame.detail = CreateFrame("Frame", "PostalLetterArchiveDetailFrame", archiveFrame)
	archiveFrame.detail:SetPoint("TOPLEFT", archiveFrame, "TOPLEFT", listWidth + 20, -28)
	archiveFrame.detail:SetWidth(bodyWidth)
	archiveFrame.detail:SetHeight(bodyHeight)

	archiveFrame.header = archiveFrame.detail:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	archiveFrame.header:SetPoint("TOPLEFT", archiveFrame.detail, "TOPLEFT", 0, 0)
	archiveFrame.header:SetWidth(bodyWidth)
	archiveFrame.header:SetJustifyH("LEFT")
	archiveFrame.header:SetJustifyV("TOP")

	archiveFrame.scroll = CreateFrame("ScrollFrame", "PostalLetterArchiveScrollFrame", archiveFrame, "FauxScrollFrameTemplate")
	archiveFrame.scroll:SetPoint("TOPLEFT", archiveFrame.rows[1], "TOPLEFT", 0, 0)
	archiveFrame.scroll:SetPoint("BOTTOMRIGHT", archiveFrame.rows[visibleRows], "BOTTOMRIGHT", -10, 0)
	archiveFrame.scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, rowHeight, function() Postal_LetterArchive:UpdateList() end)
	end)

	archiveFrame.bodyScroll = CreateFrame("ScrollFrame", "PostalLetterArchiveBodyScroll", archiveFrame, "UIPanelScrollFrameTemplate")
	archiveFrame.bodyScroll:SetPoint("TOPLEFT", archiveFrame.detail, "TOPLEFT", 0, -48)
	archiveFrame.bodyScroll:SetWidth(bodyWidth + 24)
	archiveFrame.bodyScroll:SetHeight(bodyHeight - 48)

	archiveFrame.body = CreateFrame("EditBox", "PostalLetterArchiveBodyEditBox", archiveFrame.bodyScroll)
	archiveFrame.body:SetMultiLine(true)
	archiveFrame.body:SetAutoFocus(false)
	archiveFrame.body:SetFontObject(GameFontHighlight)
	archiveFrame.body:SetWidth(bodyWidth)
	archiveFrame.body:SetHeight(bodyHeight - 48)
	archiveFrame.body:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	archiveFrame.bodyScroll:SetScrollChild(archiveFrame.body)

	archiveFrame.deleteButton = CreateFrame("Button", "PostalLetterArchiveDeleteButton", archiveFrame, "UIPanelButtonTemplate")
	archiveFrame.deleteButton:SetWidth(90)
	archiveFrame.deleteButton:SetHeight(22)
	archiveFrame.deleteButton:SetPoint("BOTTOMRIGHT", archiveFrame, "BOTTOMRIGHT", -6, 4)
	archiveFrame.deleteButton:SetText(DELETE)
	archiveFrame.deleteButton:SetScript("OnClick", function()
		if selectedIndex then StaticPopup_Show("POSTAL_LETTERARCHIVE_DELETE") end
	end)

	archiveFrame.copyButton = CreateFrame("Button", "PostalLetterArchiveCopyButton", archiveFrame, "UIPanelButtonTemplate")
	archiveFrame.copyButton:SetWidth(100)
	archiveFrame.copyButton:SetHeight(22)
	archiveFrame.copyButton:SetPoint("RIGHT", archiveFrame.deleteButton, "LEFT", -4, 0)
	archiveFrame.copyButton:SetText("Save Copy")
	archiveFrame.copyButton:SetScript("OnClick", function() Postal_LetterArchive:SaveSelectedCopy() end)

	archiveFrame.moveDownButton = CreateFrame("Button", "PostalLetterArchiveMoveDownButton", archiveFrame, "UIPanelButtonTemplate")
	archiveFrame.moveDownButton:SetWidth(34)
	archiveFrame.moveDownButton:SetHeight(22)
	archiveFrame.moveDownButton:SetPoint("RIGHT", archiveFrame.copyButton, "LEFT", -4, 0)
	archiveFrame.moveDownButton:SetText("Down")
	archiveFrame.moveDownButton:SetScript("OnClick", function() Postal_LetterArchive:MoveSavedLetter(1) end)

	archiveFrame.moveUpButton = CreateFrame("Button", "PostalLetterArchiveMoveUpButton", archiveFrame, "UIPanelButtonTemplate")
	archiveFrame.moveUpButton:SetWidth(24)
	archiveFrame.moveUpButton:SetHeight(22)
	archiveFrame.moveUpButton:SetPoint("RIGHT", archiveFrame.moveDownButton, "LEFT", -4, 0)
	archiveFrame.moveUpButton:SetText("Up")
	archiveFrame.moveUpButton:SetScript("OnClick", function() Postal_LetterArchive:MoveSavedLetter(-1) end)
end

function Postal_LetterArchive:CreateOpenMailSaveButton()
	openMailSaveButton = CreateFrame("Button", "PostalOpenMailSaveButton", OpenMailFrame, "UIPanelButtonTemplate")
	openMailSaveButton:SetWidth(70)
	openMailSaveButton:SetHeight(22)
	openMailSaveButton:SetText("Save")
	openMailSaveButton:SetPoint("RIGHT", OpenMailReplyButton, "LEFT", -4, 0)
	openMailSaveButton:SetScript("OnClick", function() Postal_LetterArchive:SaveOpenMail() end)
	openMailSaveButton:Show()
end

function Postal_LetterArchive:MailFrameTab_OnClick(button, tab)
	self.hooks["MailFrameTab_OnClick"](button, tab)
	if tab == 1 or tab == 2 then
		SetArchiveFrameSize(false)
		if archiveFrame then archiveFrame:Hide() end
		UpdateVanillaArchiveBackdrop()
		SetVanillaMailArtHidden(false)
	end
end

function Postal_LetterArchive:InboxFrame_OnClick(button, index)
	local mailID = index or button
	if OpenMailFrame then OpenMailFrame.openMailID = mailID end
	if InboxFrame then InboxFrame.openMailID = mailID end
	local result = self.hooks["InboxFrame_OnClick"](button, index)
	self:ShowCombinedInboxLetter(mailID)
	return result
end

function Postal_LetterArchive:OnTextChanged(editbox, ...)
	if editbox == SendMailBodyEditBox or editbox == SendMailSubjectEditBox then
		self:ApplyComposeLimits()
	end
end

function Postal_LetterArchive:ApplyComposeLimits()
	if not SendMailBodyEditBox or not SendMailSubjectEditBox then return end
	if SendMailBodyEditBox.SetMaxLetters then
		SendMailBodyEditBox:SetMaxLetters(maxComposeLength)
	end

	local body = SendMailBodyEditBox:GetText() or ""
	local total = GetSplitPartCount(body)
	if SendMailSubjectEditBox.SetMaxLetters then
		SendMailSubjectEditBox:SetMaxLetters(maxSubjectLength)
	end

	local subject = SendMailSubjectEditBox:GetText() or ""
	if strlen(subject) > maxSubjectLength then
		SendMailSubjectEditBox:SetText(strsub(subject, 1, maxSubjectLength))
	end
end

function Postal_LetterArchive:SendMailFrame_SendMail()
	local recipient = strtrim(SendMailNameEditBox:GetText() or "")
	local subject = SendMailSubjectEditBox:GetText() or ""
	local body = SendMailBodyEditBox:GetText() or ""

	self:ApplyComposeLimits()
	if strlen(body) <= maxBodyLength then
		return self.hooks["SendMailFrame_SendMail"]()
	end

	if recipient == "" then
		Postal:Print("Enter a recipient before sending a long letter.")
		return
	end

	local total = GetSplitPartCount(body)
	local parts = SplitBody(body, total)
	total = #parts
	local cleanSubject = GetLimitedSubject(subject)
	self.multipartQueue = {
		recipient = recipient,
		subject = cleanSubject,
		body = body,
		contents = CaptureOutgoingContents(),
		parts = parts,
		token = GenerateToken(),
		nextPart = 1,
	}
	self:SendNextMultipartPart()
end

function Postal_LetterArchive:ScheduleNextMultipartPart()
	if not sendDelayFrame then self:CreateSendDelayFrame() end
	local elapsedTime = 0
	sendDelayFrame:SetScript("OnUpdate", function(frame, elapsed)
		elapsedTime = elapsedTime + elapsed
		if elapsedTime < sendDelaySeconds then return end
		frame:SetScript("OnUpdate", nil)
		frame:Hide()
		Postal_LetterArchive:SendNextMultipartPart()
	end)
	sendDelayFrame:Show()
end

function Postal_LetterArchive:SendNextMultipartPart()
	local queue = self.multipartQueue
	if not queue then return end

	if queue.nextPart > #queue.parts then
		self:FinishMultipartSend()
		return
	end

	local part = queue.nextPart
	local total = #queue.parts
	local body = GetMultipartMarker(queue.token, part, total)..queue.parts[part]
	queue.nextPart = queue.nextPart + 1
	-- When this is page one, the compose frame's current items, money, and COD ride along.
	SendMail(queue.recipient, queue.subject, body)

	if queue.nextPart <= total then
		self:ScheduleNextMultipartPart()
	else
		self:FinishMultipartSend()
	end
end

function Postal_LetterArchive:FinishMultipartSend()
	local queue = self.multipartQueue
	if not queue then return end

	if HasBodyText(queue.body) then
		self:AddLetter("sent", {
			to = queue.recipient,
			subject = SafeText(queue.subject),
			body = queue.body,
			contents = queue.contents,
			date = LetterDate(),
			time = time(),
			pages = #queue.parts,
		})
	end
	Postal:Print(format("Sent long letter as %d parts.", #queue.parts))
	self.multipartQueue = nil
	StopSendDelay()
end

function Postal_LetterArchive:SendMailFrame_Reset()
	local recipient = strtrim(SendMailNameEditBox:GetText() or "")
	local subject = SendMailSubjectEditBox:GetText() or ""
	local body = SendMailBodyEditBox:GetText() or ""

	if self.multipartQueue then
		self.hooks["SendMailFrame_Reset"]()
		self:ApplyComposeLimits()
		return
	end

	if HasBodyText(body) then
		self:AddLetter("sent", {
			to = recipient,
			subject = SafeText(subject),
			body = body,
			contents = CaptureOutgoingContents(),
			date = LetterDate(),
			time = time(),
		})
	end

	self.hooks["SendMailFrame_Reset"]()
	self:ApplyComposeLimits()
end

function Postal_LetterArchive:AddLetter(kind, letter)
	tinsert(GetArchive(kind), 1, letter)
	if archiveFrame and archiveFrame:IsVisible() and currentArchive == kind then
		if LetterMatchesFilter(kind, letter, archiveFilters[kind]) then
			selectedIndex = 1
		end
		self:UpdateList()
		self:UpdateBody()
	end
end

function Postal_LetterArchive:SaveOpenMail()
	local mailID = ResolveOpenMailID()
	if not mailID then
		Postal:Print("No open letter to save.")
		return
	end

	local combined = self:GetCombinedInboxLetter(mailID)
	local sender, subject, body, contents
	if combined then
		sender = combined.sender
		subject = combined.subject
		body = combined.body
		contents = combined.contents
	else
		local _
		_, _, sender, subject = GetInboxHeaderInfo(mailID)
		body = GetInboxText(mailID)
		contents = CaptureInboxContents(mailID)
	end
	if (not body or body == "") and OpenMailBodyText then
		body = OpenMailBodyText:GetText()
	end

	self:AddLetter("saved", {
		from = sender or UNKNOWN,
		subject = SafeText(subject),
		body = body or "",
		contents = contents,
		date = LetterDate(),
		time = time(),
	})
	Postal:Print("Saved letter: "..SafeText(subject))
end

function Postal_LetterArchive:GetCombinedInboxLetter(mailID)
	local _, _, sender, subject = GetInboxHeaderInfo(mailID)
	local body = GetInboxText(mailID) or ""
	local token, part, total, cleanBody = ParseMultipartBody(body)
	local cleanSubject = subject

	if not token then
		token, part, total, cleanSubject = ParseMultipartSubject(subject)
		if token then
			cleanBody = body
		else
			return
		end
	end

	local parts = {}
	local contents
	for i = 1, GetInboxNumItems() do
		local _, _, partSender, partSubject = GetInboxHeaderInfo(i)
		local partBody = GetInboxText(i) or ""
		local partToken, partNumber, partTotal, partCleanBody = ParseMultipartBody(partBody)
		local partCleanSubject
		if not partToken then
			partToken, partNumber, partTotal, partCleanSubject = ParseMultipartSubject(partSubject)
			partCleanBody = partBody
		end
		if partToken == token and partTotal == total and partSender == sender then
			parts[partNumber] = partCleanBody or ""
			contents = MergeContents(contents, CaptureInboxContents(i))
			if partCleanSubject and partCleanSubject ~= "" then
				cleanSubject = partCleanSubject
			end
		end
	end

	for i = 1, total do
		if not parts[i] then
			return {
				sender = sender,
				subject = cleanSubject,
				body = format("This is part %d of %d. The full long letter will display here once all parts are in your mailbox.", part or 1, total),
				contents = contents,
				incomplete = true,
			}
		end
	end

	return {
		sender = sender,
		subject = cleanSubject,
		body = table.concat(parts, ""),
		contents = contents,
	}
end

function Postal_LetterArchive:ShowCombinedInboxLetter(mailID)
	local combined = self:GetCombinedInboxLetter(mailID)
	if not combined then return end

	if OpenMailSubject and OpenMailSubject.SetText then
		OpenMailSubject:SetText(SafeText(combined.subject))
	end
	if OpenMailBodyText and OpenMailBodyText.SetText then
		OpenMailBodyText:SetText(combined.body or "")
	end
	if OpenMailScrollFrame then
		OpenMailScrollFrame:UpdateScrollChildRect()
		if OpenMailScrollFrameScrollBar then
			OpenMailScrollFrameScrollBar:SetValue(0)
		end
	end
end

function Postal_LetterArchive:SaveSelectedCopy()
	if not selectedIndex then return end
	local source = GetArchive(currentArchive)[selectedIndex]
	if not source then return end

	self:AddLetter("saved", {
		from = source.from,
		to = source.to,
		subject = source.subject,
		body = source.body,
		contents = source.contents,
		date = LetterDate(),
		time = time(),
	})
	Postal:Print("Saved a copy of: "..SafeText(source.subject))
end

function Postal_LetterArchive:ShowArchive(kind)
	currentArchive = kind
	selectedIndex = nil

	InboxFrame:Hide()
	SendMailFrame:Hide()
	if OpenMailFrame then OpenMailFrame:Hide() end
	SetArchiveFrameSize(true)
	archiveFrame:Show()
	SetVanillaMailArtHidden(true)
	UpdateVanillaArchiveBackdrop()
	archiveFrame.filterBox:SetText(archiveFilters[kind] or "")

	if PanelTemplates_SetTab then
		PanelTemplates_SetTab(MailFrame, kind == "sent" and 3 or 4)
	end
	MailFrame.selectedTab = kind == "sent" and 3 or 4

	self:UpdateList()
	self:UpdateBody()
end

function Postal_LetterArchive:SelectLetter(index)
	selectedIndex = index
	self:UpdateList()
	self:UpdateBody()
end

function Postal_LetterArchive:MoveSavedLetter(direction)
	if currentArchive ~= "saved" or not selectedIndex then return end
	local archive = GetArchive("saved")
	local targetIndex = selectedIndex + direction
	if targetIndex < 1 or targetIndex > #archive then return end

	local letter = archive[selectedIndex]
	if not letter then return end

	tremove(archive, selectedIndex)
	tinsert(archive, targetIndex, letter)
	selectedIndex = targetIndex
	self:UpdateList()
	self:UpdateBody()
end

function Postal_LetterArchive:DeleteSelected()
	local archive = GetArchive(currentArchive)
	if selectedIndex and archive[selectedIndex] then
		tremove(archive, selectedIndex)
		selectedIndex = nil
		self:UpdateList()
		self:UpdateBody()
	end
end

function Postal_LetterArchive:UpdateList()
	local archive = GetArchive(currentArchive)
	local filter = archiveFilters[currentArchive] or ""
	local filtered = {}
	for i = 1, #archive do
		if LetterMatchesFilter(currentArchive, archive[i], filter) then
			tinsert(filtered, i)
		end
	end
	archiveFrame.filteredIndexes = filtered
	local count = #filtered
	local offset = FauxScrollFrame_GetOffset(archiveFrame.scroll)
	local selectedVisible

	archiveFrame.title:SetText(currentArchive == "sent" and "Sent" or "Saved")
	archiveFrame.filterLabel:SetText(currentArchive == "sent" and "To:" or "To/From:")
	archiveFrame.filterBox:SetWidth(currentArchive == "sent" and (listWidth - 34) or (listWidth - 72))
	if count == 0 then
		archiveFrame.empty:Show()
		if filter ~= "" then
			archiveFrame.empty:SetText("No matching letters.")
		else
			archiveFrame.empty:SetText("No archived letters.")
		end
	else
		archiveFrame.empty:Hide()
	end
	FauxScrollFrame_Update(archiveFrame.scroll, count, visibleRows, rowHeight)

	for _, archiveIndex in ipairs(filtered) do
		if archiveIndex == selectedIndex then
			selectedVisible = true
			break
		end
	end
	if not selectedVisible then
		selectedIndex = filtered[1]
	end

	for i = 1, visibleRows do
		local index = filtered[offset + i]
		local row = archiveFrame.rows[i]
		local letter = archive[index]
		if letter then
			row.index = index
			row.subject:SetText(SafeText(letter.subject))
			if currentArchive == "sent" then
				row.meta:SetText((letter.date or "").."  To: "..(letter.to or ""))
			else
				row.meta:SetText((letter.date or "").."  From: "..(letter.from or letter.to or ""))
			end
			row:Show()
			if index == selectedIndex then
				row:LockHighlight()
			else
				row:UnlockHighlight()
			end
		else
			row.index = nil
			row:Hide()
		end
	end
end

function Postal_LetterArchive:UpdateBody()
	local archive = GetArchive(currentArchive)
	local letter = selectedIndex and archive[selectedIndex]
	if not letter then
		archiveFrame.header:SetText("")
		archiveFrame.body:SetText("")
		archiveFrame.deleteButton:Disable()
		archiveFrame.copyButton:Disable()
		archiveFrame.moveUpButton:Disable()
		archiveFrame.moveDownButton:Disable()
		return
	end

	local header
	if currentArchive == "sent" then
		header = "To: "..(letter.to or "").."\nSubject: "..SafeText(letter.subject).."\nDate: "..(letter.date or "")
	else
		header = "From: "..(letter.from or "").."\nSubject: "..SafeText(letter.subject).."\nDate: "..(letter.date or "")
	end
	local contentsSummary = GetContentsSummary(letter.contents)
	if contentsSummary then
		header = header.."\n"..contentsSummary
	end

	archiveFrame.header:SetText(header)
	archiveFrame.body:SetText(letter.body or "")
	archiveFrame.body:SetCursorPosition(0)
	if archiveFrame.bodyScroll and archiveFrame.bodyScroll.UpdateScrollChildRect then
		archiveFrame.bodyScroll:UpdateScrollChildRect()
	end
	if PostalLetterArchiveBodyScrollScrollBar then
		PostalLetterArchiveBodyScrollScrollBar:SetValue(0)
	end
	archiveFrame.deleteButton:Enable()
	if currentArchive ~= "saved" then
		archiveFrame.copyButton:Enable()
		archiveFrame.moveUpButton:Hide()
		archiveFrame.moveDownButton:Hide()
	else
		archiveFrame.copyButton:Disable()
		archiveFrame.moveUpButton:Show()
		archiveFrame.moveDownButton:Show()
		if selectedIndex and selectedIndex > 1 then
			archiveFrame.moveUpButton:Enable()
		else
			archiveFrame.moveUpButton:Disable()
		end
		if selectedIndex and selectedIndex < #archive then
			archiveFrame.moveDownButton:Enable()
		else
			archiveFrame.moveDownButton:Disable()
		end
	end
end
