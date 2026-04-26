--=======================================================================================================
-- SCRIPT
--
-- Purpose:     futures contracts.
-- Author:      Mmtrx
-- Changelog:
--  v1.0.0.0    17.03.2026  initial
--  v1.1.0.0    25.04.2026  add MP sync
--=======================================================================================================
FuturesMission = {
	NAME = "futuresMission",
	MAX_NUMINSTANCES = 9,
	MIN_DURATION = 2, 		-- delivery time in months
	MAX_DURATION = 9, 		

	debug = true,
}
local FuturesMission_mt = Class(FuturesMission, AbstractMission)
InitObjectClass(FuturesMission, "FuturesMission")

function FuturesMission.registerSavegameXMLPaths(schema, key)
	FuturesMission:superClass().registerSavegameXMLPaths(schema, key)
	local mkey = string.format("%s.futures", key)
	schema:register(XMLValueType.STRING, mkey .. "#fillType", "Name of the fill type")
	schema:register(XMLValueType.INT, mkey .. "#duration", "in months")
	schema:register(XMLValueType.INT, mkey .. "#npcIndex", "Index of NPC")
	schema:register(XMLValueType.FLOAT, mkey .. "#price", "Locked price/liter")
	schema:register(XMLValueType.FLOAT, mkey .. "#expectedLiters", "Expected liters")
	schema:register(XMLValueType.FLOAT, mkey .. "#depositedLiters", "Deposited liters")
	schema:register(XMLValueType.STRING, mkey .. "#sellingStationPlaceableUniqueId", "Unique id of the selling point")
	schema:register(XMLValueType.INT, mkey .. "#unloadingStationIndex", "Index of the unloading station")
end
function FuturesMission.new(isServer, isClient, customMt)
	local self = AbstractMission.new(isServer, isClient, 
		g_i18n:getText("contract_futures_title"),
		g_i18n:getText("contract_futures_desc"), 
		customMt or FuturesMission_mt)

	self.fillTypeIndex = FillType.UNKNOWN 
	self.pendingSellingStationId = nil
	self.sellingStation = nil
	self.depositedLiters = 0
	self.expectedLiters = 0
	self.pricePerLiter = 0
	self.priceOriginal = 0
	self.reward = 0
	self.lastFillSoldTime = -1
	self.mapHotspots = {}
	self.modName = g_currentModName
	self.extraProgressText = g_i18n:getText("fm_extraProgress", self.modName)
	self.progFormatted = false
	self.missionProgressText = g_i18n:getText("fm_missionProgress", self.modName)
	-- 
	self.mdm = g_currentMission.MarketDynamics
	self.bcInt = self.mdm.bcIntegration
	self.mdmId = nil
	return self
end
function FuturesMission:init(fillTypeIndex, duration)
	-- duration in months
	local ok = FuturesMission:superClass().init(self)

	if fillTypeIndex == nil then return false end  

	self.months = duration
	self.fillTypeIndex = fillTypeIndex
	self.npcIndex = FuturesMission.getRandomNpcIndex()

	local sellStation, priceOriginal = self:getRandomSellPoint(fillTypeIndex)
	if sellStation == nil or priceOriginal <= 0 then
		return false
	end
	self:setSellingStation(sellStation)
	self.priceOriginal = priceOriginal

	if self.bcInt then
	 self.pricePerLiter = self.bcInt.getLockedPrice(fillTypeIndex)
	 self.reward = self.pricePerLiter *1000 -- just as placeholder
	end
	local env = g_currentMission.environment
	local monoDay = env.currentMonotonicDay
	local endDay = monoDay + 
		(env.daysPerPeriod - env:getDayInPeriodFromDay(monoDay)) -- end of curr month
	endDay = endDay + duration * env.daysPerPeriod
	self:setEndDate(endDay, 86399999)

	self.endMonth = env:getPeriodFromDay(endDay)	

	-- set current MDM price /amount from player dialog at mission start
	return ok
end
function FuturesMission:delete()
	if self.sellingStation ~= nil then
		self.sellingStation.missions[self] = nil
	end
	if self.sellingStationMapHotspot ~= nil then
		table.removeElement(self.mapHotspots, self.sellingStationMapHotspot)
		g_currentMission:removeMapHotspot(self.sellingStationMapHotspot)

		self.sellingStationMapHotspot:delete()
		self.sellingStationMapHotspot = nil
		self.addSellingStationHotspot = false
	end
	FuturesMission:superClass().delete(self)
end
function FuturesMission:update(dt)
	FuturesMission:superClass().update(self, dt)
	if self.status == MissionStatus.RUNNING and not self.addSellingStationHotspot then
		if g_localPlayer ~= nil and g_localPlayer.farmId == self.farmId then
			self:addHotspot()
		end
	end
	if self.pendingSellingStationId ~= nil then
		self:tryToResolveSellingStation()
	end
	if self.isServer then
		if self.lastFillSoldTime > 0 then
			self.lastFillSoldTime = self.lastFillSoldTime - 1
			if self.lastFillSoldTime == 0 then
				local percent = math.floor((self.completion * 100) + 0.5)
				g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, 
					string.format(self.missionProgressText, percent, self:getLocation()))
			end
		end
	end
end
function FuturesMission:writeStream(streamId, connection)
	NetworkUtil.writeNodeObject(streamId, self.sellingStation)
	streamWriteUIntN(streamId, self.fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
	streamWriteUInt16(streamId, math.floor(self.pricePerLiter * 1000 + 0.5))
	streamWriteFloat32(streamId, self.expectedLiters)
	if streamWriteBool(streamId, self.depositedLiters > 0) then
		streamWriteFloat32(streamId, self.depositedLiters)
	end
	streamWriteUInt8(streamId, self.npcIndex or 1)
	--streamWriteBool(streamId, self.sellingStationRemoved == true)
	FuturesMission:superClass().writeStream(self, streamId, connection)
end
function FuturesMission:readStream(streamId, connection)
	self.pendingSellingStationId = NetworkUtil.readNodeObjectId(streamId)
	self.fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
	self.pricePerLiter = streamReadUInt16(streamId) / 1000
	self.expectedLiters = streamReadFloat32(streamId)
	if streamReadBool(streamId) then
		self.depositedLiters = streamReadFloat32(streamId)
	end
	self.npcIndex = streamReadUInt8(streamId)
	--self.sellingStationRemoved = streamReadBool(streamId)
	FuturesMission:superClass().readStream(self, streamId, connection)
end
function FuturesMission:writeUpdateStream(streamId, connection, dirtyMask)
	FuturesMission:superClass().writeUpdateStream(self, streamId, connection, dirtyMask)
	if streamWriteBool(streamId, self.depositedLiters > 0) then
		streamWriteFloat32(streamId, self.depositedLiters)
	end
	--streamWriteBool(streamId, self.sellingStationRemoved == true)
end
function FuturesMission:readUpdateStream(streamId, timestamp, connection)
	FuturesMission:superClass().readUpdateStream(self, streamId, timestamp, connection)
	if streamReadBool(streamId) then
		self.depositedLiters = streamReadFloat32(streamId)
	end
	--self.sellingStationRemoved = streamReadBool(streamId)
end
function FuturesMission:saveToXMLFile(xmlFile, key)
	local hKey = string.format("%s.futures", key)
	xmlFile:setValue(hKey .. "#fillType", 
		g_fillTypeManager.fillTypes[self.fillTypeIndex].name)
	xmlFile:setValue(hKey .. "#duration", self.months)
	xmlFile:setValue(hKey .. "#npcIndex", self.npcIndex)
	xmlFile:setValue(hKey .. "#price", self.pricePerLiter)
	xmlFile:setValue(hKey .. "#expectedLiters", self.expectedLiters)
	xmlFile:setValue(hKey .. "#depositedLiters", self.depositedLiters)
	if self.sellingStation ~= nil then 
		local placeable = self.sellingStation.owningPlaceable 
		if placeable == nil then
			local v34 = self.sellingStation.getName and self.sellingStation:getName() or "unknown"
			Logging.xmlWarning(xmlFile, "Unable to retrieve placeable of sellingStation \'%s\' for saving futures mission \'%s\' ", v34, key)
			return
		end
		local index = g_currentMission.storageSystem:getPlaceableUnloadingStationIndex(placeable, self.sellingStation)
		if index == nil then
			local v36 = self.sellingStation.getName and self.sellingStation:getName() or (placeable.getName and placeable:getName() or "unknown")
			Logging.xmlWarning(xmlFile, "Unable to retrieve unloading station index of sellingStation \'%s\' for saving futures mission \'%s\' ", v36, key)
			return
		end
		xmlFile:setValue(hKey .. "#sellingStationPlaceableUniqueId", placeable:getUniqueId())
		xmlFile:setValue(hKey .. "#unloadingStationIndex", index)
	end
	FuturesMission:superClass().saveToXMLFile(self, xmlFile, key)
end
function FuturesMission:loadFromXMLFile(xmlFile, key)
	if not FuturesMission:superClass().loadFromXMLFile(self, xmlFile, key) then return false
	end
	self.endMonth = g_currentMission.environment:getPeriodFromDay(self.endDate.endDay)	

	local hKey = string.format("%s.futures", key)
	local name = xmlFile:getValue(hKey.."#fillType")
	local ft = g_fillTypeManager:getFillTypeIndexByName(name)
	if ft == nil then 
		Logging.xmlError(xmlFile, "FillType \'%s\' not defined", name)
		return false
	end
	self.fillTypeIndex = ft

	local npcIndex = xmlFile:getValue(hKey .. "#npcIndex")
	if npcIndex == nil or g_npcManager:getNPCByIndex(npcIndex) == nil then
		npcIndex = FuturesMission.getRandomNpcIndex()
		Logging.xmlWarning(xmlFile, "Failed to retrieve valid NPC index from saved mission, trying to assign a new one. (%s)", hKey)
	end
	self.npcIndex = npcIndex

	self.months = xmlFile:getValue(hKey .. "#duration")
	self.pricePerLiter = xmlFile:getValue(hKey .. "#price", self.pricePerLiter)
	self.expectedLiters = xmlFile:getValue(hKey .. "#expectedLiters", self.expectedLiters)
	self.depositedLiters = xmlFile:getValue(hKey .. "#depositedLiters", self.depositedLiters)
	local v43 = xmlFile:getValue(hKey .. "#sellingStationPlaceableUniqueId")
	if v43 == nil then
		Logging.xmlError(xmlFile, "No sellingStationPlaceable uniqueId given for futures mission at \'%s\'", hKey)
		return false
	end
	local index = xmlFile:getValue(hKey .. "#unloadingStationIndex")
	if index == nil then
		Logging.xmlError(xmlFile, "No unloading station index given for futures mission at \'%s\'", hKey)
		return false
	end
	self.sellingStationPlaceableUniqueId = v43
	self.unloadingStationIndex = index
	debugPrint("* futures from savegame: %s in %s mon",name,self.months)
	return true
end
function FuturesMission:getVehicleGroupFromIdentifier(identifier, ...)
	-- This is used to fix incorrectly checked nil of 'self.vehiclesToLoad' in
	-- AbstractMission:loadFromXMLFile, this should only have been done when
	-- 'self.spawnedVehicles' was true.
	return {}, 1, "No vehicles", nil
end
function FuturesMission:onSavegameLoaded()
	if self.sellingStationPlaceableUniqueId == nil or self.unloadingStationIndex == nil
	 then return
	end
	local placeable = g_currentMission.placeableSystem:getPlaceableByUniqueId(self.sellingStationPlaceableUniqueId)
	if placeable ~= nil then
		local sellingStation = g_currentMission.storageSystem:getPlaceableUnloadingStation(placeable, self.unloadingStationIndex)
		if sellingStation ~= nil then
			if self.pricePerLiter <= 0 then
				-- Try and resolve the price, if not then just destroy the mission
				self.pricePerLiter = sellingStation:getEffectiveFillTypePrice(self.fillTypeIndex)
			end
			self:setSellingStation(sellingStation)
			if self:getWasStarted() and not self:getIsFinished() then
				sellingStation.missions[self] = self
			end

			FuturesMission:superClass().onSavegameLoaded(self)
		else
			Logging.error("[FuturesMission] Failed to retrieve unloadingStation with index '%d' for placeable sellingStation '%s'", self.unloadingStationIndex, placeable.configFileName)
			g_missionManager:markMissionForDeletion(self)
		end
	else
		Logging.error("FuturesMission] Selling station placeable with uniqueId '%s' no longer available", self.sellingStationPlaceableUniqueId)
		g_missionManager:markMissionForDeletion(self)
	end
end
function FuturesMission:setSellingStation(sellingStation)
	if sellingStation == nil then
		Logging.devError("[FM] Failed to set sellingStation, value was nil")
		return
	end
	self.pendingSellingStationId = nil
	self.sellingStation = sellingStation

	--self:updateTexts()

	local placeable = sellingStation.owningPlaceable

	if placeable ~= nil and placeable.getHotspot ~= nil then
		local hotspot = placeable:getHotspot()

		if hotspot ~= nil then
			self.sellingStationMapHotspot = HarvestMissionHotspot.new()
			self.sellingStationMapHotspot:setWorldPosition(hotspot:getWorldPosition())

			table.addElement(self.mapHotspots, self.sellingStationMapHotspot)

			-- Should only be true if mission is already active
			if self.addSellingStationHotspot then
				g_currentMission:addMapHotspot(self.sellingStationMapHotspot)
			end
		end
	end
end
function FuturesMission:addHotspot()
	if self.sellingStationMapHotspot ~= nil then
		g_currentMission:addMapHotspot(self.sellingStationMapHotspot)
	end
	self.addSellingStationHotspot = true
end
function FuturesMission:removeHotspot()
	if self.sellingStationMapHotspot ~= nil then
		g_currentMission:removeMapHotspot(self.sellingStationMapHotspot)
	end
	self.addSellingStationHotspot = false
end
function FuturesMission:getRandomSellPoint(fillTypeIndex)
	local numSellPoints = 0
	local sellPoints = {}

	for _, unloadingStation in pairs(g_currentMission.storageSystem:getUnloadingStations()) do
		if unloadingStation.isSellingPoint and unloadingStation.allowMissions and unloadingStation.owningPlaceable ~= nil and unloadingStation.acceptedFillTypes[fillTypeIndex] then
			local pricePerLitre = unloadingStation:getEffectiveFillTypePrice(fillTypeIndex)
			if pricePerLitre > 0 then
				table.insert(sellPoints, {
					sellingStation = unloadingStation,
					pricePerLitre = pricePerLitre
				})
				numSellPoints += 1
			end
		end
	end
	if numSellPoints > 0 then
		local index = numSellPoints > 1 and math.random(numSellPoints) or 1
		local sellPoint = sellPoints[index]
		return sellPoint.sellingStation, sellPoint.pricePerLitre
	end

	return nil, 0
end
function FuturesMission.getRandomNpcIndex()
	-- body-- todo; ()
	return g_npcManager:getRandomIndex()
end
function FuturesMission:getStealingCosts()
	-- calc 15% price for missing amount
	local penPerc = self.bcInt.getPenaltyPercent(self.farmId) / 100
	local reimb = (self.pricePerLiter or 0) * self.depositedLiters 
	local penalty = (self.expectedLiters-self.depositedLiters)* penPerc * self.pricePerLiter
	return math.min(reimb, penalty)
end
function FuturesMission.getMissionTypeName(_)
	return FuturesMission.NAME
end
function FuturesMission:getDaysLeft()
	local env = g_currentMission.environment
	local endDay = self.endDate.endDay

	return endDay - env.currentMonotonicDay 
end
function FuturesMission:getDetails()
	local details = FuturesMission:superClass().getDetails(self)

	if self.pendingSellingStationId ~= nil then
		self:tryToResolveSellingStation()
	end

	local i18n = g_i18n
	local unitText = i18n:getVolumeUnit(false) -- Use short version to match other mission types

	table.insert(details, {
		title = i18n:getText("contract_details_harvesting_sellingStation"),
		value = self:getSellingStationName()
	})
	table.insert(details, {
		title = i18n:getText("infohud_fillType"),
		value = self:getFillTypeTitle()
	})
	table.insert(details, {
		title = i18n:getText("fm_locked_price"),
		value = i18n:formatMoney(self.pricePerLiter*1000, 0)
	})
	if self:getWasStarted() then
		if not self.progFormatted then 
			-- update extra progress text with curent penalty %
			local penalty = self.bcInt.getPenaltyPercent(self.farmId)
			self.extraProgressText = string.format(self.extraProgressText, penalty)
			self.progFormatted = true
		end
		table.insert(details, {
			title = i18n:getText("contract_total"),
			value = i18n:formatVolume(self.expectedLiters, 0, unitText)
		})
		table.insert(details, {
			title = i18n:getText("contract_progress"),
			value = i18n:formatVolume(self.depositedLiters, 0, unitText)
		})
	end
	table.insert(details, {
		title = i18n:getText("ui_pendingMissionTimeLeftTitle"),
		value = i18n:formatNumDay(self:getDaysLeft())
	})

	return details
end
function FuturesMission:getExtraProgressText()
	return self.extraProgressText or ""
end
function FuturesMission:getCompletion()
	if self.expectedLiters <= 0 then
		return 0
	end
	return math.max(math.min(1, self.depositedLiters/self.expectedLiters), 
		0.00001) 
end
function FuturesMission:getLocation()
	return string.format("%s by %s", self:getFillTypeTitle(), 
		g_i18n:formatPeriod(self.endMonth))
end
function FuturesMission:getReward()
	return self.reward or 0
end
function FuturesMission.getRewardMultiplier()
	if g_currentMission.missionInfo.economicDifficulty ~= EconomicDifficulty.HARD then
		return 1.4
	end
	return 1.2
end
function FuturesMission:getNPC()
	return g_npcManager:getNPCByIndex(self.npcIndex)
end
function FuturesMission:getFarmlandId()
	return self.farmlandId or FarmlandManager.NO_OWNER_FARM_ID -- GUI does not do a nil check so just use 0
end
function FuturesMission:getMapHotspots()
	return self.mapHotspots
end
function FuturesMission:getFillTypeTitle()
	if self.fillTypeTitle == nil then
		local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(self.fillTypeIndex)

		if fillTypeDesc ~= nil then
			self.fillTypeTitle = fillTypeDesc.title
		end
	end
	return self.fillTypeTitle or "Unknown"
end
function FuturesMission:getSellingStationName()
	local sellingStation = self.sellingStation

	if sellingStation ~= nil then
		if sellingStation.getName ~= nil then
			return sellingStation:getName() or "Unknown"
		elseif sellingStation.owningPlaceable ~= nil and sellingStation.owningPlaceable.getName ~= nil then
			return owningPlaceable:getName() or "Unknown"
		end
	end
	return "Unknown"
end
function FuturesMission:validate()
	-- to delete mission templates when end date is next month
	local env = g_currentMission.environment
	local monthsLeft = self:getDaysLeft() / env.daysPerPeriod
	if monthsLeft <= 1 then 
		debugPrint("contract %s invalidated", self:getLocation())
	end
	return monthsLeft > 1 
end
function FuturesMission:tryToResolveSellingStation()
	HarvestMission.tryToResolveSellingStation(self)
end
function FuturesMission:fillSold(delta)
	local applying = math.min(self.expectedLiters -self.depositedLiters, delta)
	self.depositedLiters = self.depositedLiters + applying
	self.bcInt.recordDelivery(self.mdmId, applying)

	if self.depositedLiters >= self.expectedLiters then
		if self.sellingStation ~= nil then
			-- Remove mission from the Selling Station and start selling
			self.sellingStation.missions[self] = nil 
		end
	end
	self.lastFillSoldTime = 30 -- Reset notification timer
end
function FuturesMission:hasLeasableVehicles()
	return false
end
function getRandomFilltypeMonth()
	-- return a crop fillType and duration in months, that are not already offered
	missionType = g_missionManager:getMissionType(FuturesMission.NAME)

	local data = missionType.data
	local validFillTypes, ignoreFillTypes, ignoreMonths = {}, {}, {{}}
	--local cropFillTypeMissions, addCropFillTypesOnly = 0, true

	local invalidFillTypes = data.invalidFillTypes or {}
	local missions = g_missionManager:getMissionsByType(missionType.typeId)

	if missions ~= nil then
		local environment = g_currentMission.environment

		-- don't return a fillType/month already used in a futures mission
		for _, mission in ipairs (missions) do
			ft = mission.fillTypeIndex
			if ignoreMonths[ft] == nil then
				ignoreMonths[ft] = {}
			end
			ignoreMonths[ft][environment:getPeriodFromDay(mission.endDate.endDay)] = true
		end
	end

	local function getIsValidMissionFillType(fillTypeIndex)
		if ignoreFillTypes[fillTypeIndex] or invalidFillTypes[fillTypeIndex] then
			return false
		end
		return true
	end
	for _, unloadingStation in pairs(g_currentMission.storageSystem:getUnloadingStations()) do
		if unloadingStation.isSellingPoint and unloadingStation.allowMissions and unloadingStation.owningPlaceable ~= nil then
			for fillTypeIndex, _ in pairs (unloadingStation.acceptedFillTypes) do
				if getIsValidMissionFillType(fillTypeIndex) then
					--ignoreFillTypes[fillTypeIndex] = true
					-- get only crop fillTypes
					if g_fruitTypeManager:getFruitTypeIndexByFillTypeIndex(fillTypeIndex) ~= nil then
						table.insert(validFillTypes, fillTypeIndex)
					end
				end
			end
		end
	end
	local ft, dur
	local numValidFillTypes = #validFillTypes
	if numValidFillTypes > 0 then
		if numValidFillTypes == 1 then
			ft = validFillTypes[1]
		elseif numValidFillTypes == 2 then
			ft = validFillTypes[math.random() < 0.5 and 1 or 2]
		else 
			Utils.shuffle(validFillTypes)
			ft = validFillTypes[math.random(numValidFillTypes)]
		end
		--debugPrint("found fillType %d %s",ft,g_fillTypeManager:getFillTypeTitleByIndex(ft))
		local duration, m = {}
		local env = g_currentMission.environment
		for p = FuturesMission.MIN_DURATION, FuturesMission.MAX_DURATION do
			m = env.currentPeriod + p -- could be > 12, next year
			if ignoreMonths[ft] == nil or not ignoreMonths[ft][m%12] then 
				table.insert(duration, p)
			end
		end
		if #duration > 0 then 
			Utils.shuffle(duration)
			dur = duration[math.random(#duration)]
		end
	end
	--debugPrint("return ft %s / duration %s", ft, dur)
	return ft, dur
end
function FuturesMission.tryGenerateMission()
	--[[
	(generic) mission in NEW list just has: fillType, sellstation, delivery date
	once active, we set:
		locked price 	= current price at contract start
		amount 			= to be entered by player

	delete generic mission 1 month prior to delivery month (and generate a new one)
	generate up to MAX_NUMINSTANCES missions for random delivery times between 2 and 9 months, 
	for random crops
	]]
	local data = g_missionManager:getMissionTypeDataByName(FuturesMission.NAME)	

	if FuturesMission.canRun(data)  then  
	   local fillTypeIndex, endMonth = getRandomFilltypeMonth()
	   if fillTypeIndex ~= nil and endMonth ~= nil then
		   local mission = FuturesMission.new(true, g_client ~= nil)
		   if mission:init(fillTypeIndex, endMonth) then
		   	debugPrint("new mission: %s", mission:getLocation())
			  return mission
		   else
			   mission:delete()
		   end
	   end
	end 
	return nil
end
function FuturesMission.canRun(data)
	if data == nil then
		data = g_missionManager:getMissionTypeDataByName(FuturesMission.NAME)
	end
	if data == nil or data.numInstances == nil or data.maxNumInstances == nil then
		return false
	end
	return data.numInstances < data.maxNumInstances
end
function FuturesMission:start()
	-- called by MissionManager:startMission(), Server only
	if self.pendingSellingStationId ~= nil then
		self:tryToResolveSellingStation()
	end
	if self.sellingStation == nil or not FuturesMission:superClass().start(self) then
		return false
	end
	self.sellingStation.missions[self] = self

	if self.fromSavedMdm then return true end 
	
	-- create a duplicate as NEW mission
	local dup = FuturesMission.new(true, g_client ~= nil)
	dup:init(self.fillTypeIndex, self.months)  -- possibly different sell station / npc
	g_missionManager:registerMission(dup, self.type)

	-- MDM integration: Create a new futures contract.
	-- params = { farmId, fillTypeIndex, fillTypeName, quantity, lockedPrice, deliveryTimeMs }
	local params = {
		farmId        = self.farmId,
		fillTypeIndex = self.fillTypeIndex,
		fillTypeName  = self:getFillTypeTitle(),
		quantity      = self.expectedLiters,       
		lockedPrice   = self.pricePerLiter,    -- per liter at contract creation
		deliveryTimeMs= self.bcInt.getDeliveryMs(self.months), -- absolute game time (ms)
	}
	self.mdmId = self.bcInt.onBCContractCreated(params)
	return true
end
function FuturesMission:finish(finishState)
	if self.sellingStation ~= nil then
		self.sellingStation.missions[self] = nil
	end
	self:removeHotspot()

	if g_currentMission:getFarmId() == self.farmId then
		-- show mission result message. Normally done by AbstractFieldMission:finish()
		local title = self:getLocation()

		if finishState == MissionFinishState.SUCCESS then
			g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, 
				string.format(g_i18n:getText("fm_finished", self.modName), title))

			self.bcInt.onBCContractFulfilled(self.mdmId)
		else
			self.reimbursement = (self.pricePerLiter or 0) * self.depositedLiters 
			-- Will be recalculated but do it now so client can have correct value in GUI

			if finishState == MissionFinishState.FAILED then
				if self.sellingStationRemoved then -- not used yet
					g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, 
						string.format(g_i18n:getText("fm_sellingStationRemoved", self.modName), title))
				else
					g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, 
						string.format(g_i18n:getText("fm_failed", self.modName), title))
				end

			elseif finishState == MissionFinishState.TIMED_OUT then
				g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, 
					string.format(g_i18n:getText("fm_timedOut", self.modName), title))
			end
			self.bcInt.onBCContractDefaulted(self.mdmId)
		end
	end

	FuturesMission:superClass().finish(self, finishState)
end
--[[ possible future use
function FuturesMission:roundToWholeBales(liters)
	local baleSizes = g_baleManager:getPossibleCapacitiesForFillType(self.fillTypeIndex)
	local minBales = math.huge
	local minBaleIndex = 1

	for i = 1, #baleSizes do
		local bales = math.floor(liters * 0.95 / baleSizes[i])
		if bales < minBales then
			minBales = bales
			minBaleIndex = i
		end
	end
	return math.max(minBales * baleSizes[minBaleIndex], liters - 10000)
end]]