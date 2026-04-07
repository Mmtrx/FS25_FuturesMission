-------------------------- contract start dialog ---------------------------
ContractStart = {}
local ContractStart_mt = Class(ContractStart, YesNoDialog)

function ContractStart.new(target, custom_mt)
	local self = YesNoDialog.new(target, custom_mt or ContractStart_mt)
	self.amount = 1000
	return self
end
function ContractStart:init(m)
	-- set all texts of gui elements to show
	local i18n = g_i18n
	self.mission = m
	self.priceLocked = m.bcInt.getLockedPrice(m.fillTypeIndex)

	self.infoCrop:setText(m:getFillTypeTitle())
	self.infoMonth:setText(i18n:formatPeriod(m.endMonth))
	self.infoAmount:setText("n/a")
	self.infoPrice:setText(i18n:formatMoney(self.priceLocked*1000))
	local pct = m.bcInt.getPriceChangePercent(m.fillTypeIndex)
	self.infoChange:setText(string.format("%.1f%%", pct))

	local text = {}
	for i=1,10 do
		table.insert(text, string.format("%d", 1000*i) )
	end
	self.multiTextAmount:setTexts(text)	
	self.multiTextAmount:setState(1)	

	-- set hint text:
	if pct > 2. then
		self.hint:setText(string.format("%.1f%% above base - good time to lock in", pct))
		self.iconHint:applyProfile("FMiconPlus")
	elseif pct < -2. then
		self.hint:setText(string.format("%.1f%% below base - consider waiting", math.abs(pct)))
		self.iconHint:applyProfile("FMiconMinus")
	else
		self.hint:setText(string.format("Near baseline (%.1f%%) - neutral", pct))
		self.iconHint:applyProfile("FMiconNeutral")
	end
end
function ContractStart:onClickAmount(ix)
	-- MTO texts: 1..10
	self.infoAmount:setText(g_i18n:formatVolume(ix*1000)) 
	self.amount = ix*1000
	self.infoTotal:setText(g_i18n:formatMoney(self.priceLocked*self.amount)) 
	return self.amount
end
function ContractStart:futuresClickButton(button)
	-- callback from our start contract dialog. Esc doesn't start mission
	debugPrint("** ContractStart: Click %s", button.id)
	if button.id == "yesButton" then
		self.mission.expectedLiters = self.amount
		self.mission.reward = self.amount * self.priceLocked
		self:startContract()
	end
	self:close()
end
function ContractStart:startContract(ix)
	-- called from ContractStart dialog on yes button
	local m = self.mission
	m.pricePerLiter = self.priceLocked
	m.reward = self.amount * self.priceLocked
	sendMissionStart(m, false)		
end
function sendMissionStart(m, hasLeasing)
	-- send augmented mission start event to server
		local farmId = g_currentMission:getFarmId()
		local event = MissionStartEvent.new(m, farmId, hasLeasing)
		--event.newField = xxx, possibly set addtnl info here
		g_client:getServerConnection():sendEvent(event)
end

InGameMenuContractsFrame.startContract = Utils.overwrittenFunction(InGameMenuContractsFrame.startContract, 
	function(frCon, superf, wantsLease)
	-- overwrites InGameMenuContractsFrame:startContract()
	local futures = g_FuturesMission
	local m = frCon:getSelectedContract().mission
	if m.type.name ~= FuturesMission.NAME then
		superf(frCon, wantsLease)  		-- sends base game start evt 
	end
	 -- show futures contract dialog:
	futures.contractStart:init(m)
	g_gui:showDialog("startContract")  -- if yes button, start mission
end)
