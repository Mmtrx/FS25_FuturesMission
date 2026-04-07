--=======================================================================================================
-- SCRIPT
--
-- Purpose:     main function. Futures contracts dialog
-- Author:      Mmtrx
-- Changelog:
--  v0.0.0.1    26.03.2026  initial
--  v1.0.0.0    07.04.2026  add integration with FS25_MarketDynamics,
-- 													add savegame sync with MDM
--=======================================================================================================
-----------------------------------------------------------------------------
local modDirectory = g_currentModDirectory
local modName      = g_currentModName

source(modDirectory .."futuresMission.lua")
source(modDirectory .."contractStart.lua")

function debugPrint(text, ...)
	if Futures.debug == true then
		Logging.info("[FM] ".. text,...)
	end
end

Futures = {
	debug = true,
}
local Futures_mt = Class(Futures)

function Futures.new()
	local self = {}
	setmetatable(self, Futures_mt)
	self.isServer = g_server ~= nil 
	self.isClient = g_dedicatedServerInfo == nil
	self.directory = g_currentModDirectory
	self.mdmContracts = {}
	self.loadContracts = true 	-- try to load legacy MDM contracts from savegame
	self.doneContracts = false

	g_missionManager:registerMissionType(FuturesMission, FuturesMission.NAME, 
		FuturesMission.MAX_NUMINSTANCES)
	
	--[[ rewardPerHa for other mission types are loaded from map
	local data = g_missionManager:getMissionTypeDataByName(FuturesMission.NAME)
	data.rewardPerHa = FuturesMission.REWARD_PER_HA
	data.fruitTypeIndices = {}
	data.failureCostFactor = 0.1
	data.failureCostOfTotal = 0.95
	]]

	-- load and initiate contract start dialog:
	local fname = self.directory .."startContract.xml"
	if fileExists(fname) then
		-- init our contract start dialog
		self.contractStart = ContractStart.new()

		if g_gui:loadGui(fname, "startContract", self.contractStart) == nil 
			and not g_modIsLoaded.FS25_Financing then -- FS25_Financing swallows rc of loadGui()
			Logging.error("[FM] Error loading gui %s", fname)
			return nil
		end
	else
		Logging.error("[FM] Required file '%s' could not be found!", fname)
		return nil
	end

	addConsoleCommand("fmMission", "Force generating a futures mission for given field", "consoleGenMission", self, "fieldId")
	return self 
end
function Futures:consoleGenMission(fieldNo)
	-- generate futures mission for given fillType
	return g_missionManager:consoleGenerateMission(fillTypeTitle, "futuresMission")
end
function Futures:loadMap()
	-- body
	if g_modIsLoaded[modName] then
		g_currentMission.FuturesMission = self
		debugPrint("** loadMap: set g_currentMission.FuturesMission")
	end
	self.mdm = g_currentMission.MarketDynamics
	self.bcInt = self.mdm.bcIntegration
end
function Futures:update()
	if not g_currentMission:getIsServer() then return end
	--[[Savegame Sync:
		Get active MDM-native contracts for a farm — i.e. contracts that were
		created by MDM directly (not via BC/FuturesMission) and are still active.
		Call this on savegame load to take over tracking of any contracts that were 
		written before FM was activated. 
	]]
	if g_FuturesMission and g_FuturesMission.loadContracts then
		debugPrint("*** checking for saved active MDM contracts")
		local bcInt = self.bcInt
		for _, farm in ipairs(g_farmManager:getFarms()) do
			local fid = farm.farmId
			if fid == FarmManager.GUIDED_TOUR_FARM_ID or fid == FarmManager.SPECTATOR_FARM_ID then
				continue
			end
			debugPrint("**** checking contracts for farm %d", fid)
			self.mdmContracts[fid] = bcInt.getContractsForFarm(fid)
		end
		g_FuturesMission.loadContracts = false -- only do once
	end

	if self.doneContracts then return end
	
	-- try to create futures mission from saved contract one at a time
	self.doneContracts = true
	for _, farm in ipairs(g_farmManager:getFarms()) do
		local fid = farm.farmId
		if fid == FarmManager.GUIDED_TOUR_FARM_ID or fid == FarmManager.SPECTATOR_FARM_ID then
			continue
		end
		local mdmContracts = self.mdmContracts[fid]
		if #mdmContracts > 0 then 
			local cont = table.remove(mdmContracts)
			self:makeContract(fid, cont)
			self.doneContracts = false
			break  -- only start 1 contract per update tick
		end
	end
end
function Futures:makeContract(fid, cont)
	-- generate a futures mission from a saved mdm contract
	local env = g_currentMission.environment
	local bcInt = g_FuturesMission.bcInt
	-- cont.deliveryTime is endDate in ms
	-- months = end month - now month
	local endDay = math.floor(cont.deliveryTime / 86400000)
	local endMonth = env:getPeriodFromDay(endDay)
	local nowMonth = env:getPeriodFromDay(env.currentDay)
	local info = string.format("mdm contract %d: %s endDay %d, endMonth %d, nowMonth %d",
		cont.id, g_fillTypeManager:getFillTypeByIndex(cont.fillTypeIndex).title,
		endDay, endMonth, nowMonth)
	if endDay <= env.currentDay then
		debugPrint("%s expired. No FM mission generated.", info)
		return false
	end 
	-- create a futures contract
	local dup = FuturesMission.new(true, g_client ~= nil)
	dup.mdmId = cont.id
	if not dup:init(cont.fillTypeIndex, endMonth-nowMonth) then 
		-- possibly different sell station / npc. Moves end time to midnight
		Logging.warning("[FM] could not create futures mission from saved %s",info)
		dup:delete()
		return false
	end
	dup.pricePerLiter = cont.lockedPrice
	dup.expectedLiters = cont.quantity
	dup.depositedLiters = cont.delivered
	dup.reward = cont.quantity * cont.lockedPrice
	g_missionManager:registerMission(dup, g_missionManager:getMissionType(FuturesMission.NAME))

	-- start the futures contract
	dup.fromSavedMdm = true  -- prevents dup:start() from creating a new MDM contract
	local state = g_missionManager:startMission(dup, fid, false)
	if state ~= MissionStartState.OK then
		Logging.warning("[FM] could not start futures mission from saved %s. Start state %d",info, state)
		dup:delete()
		return false
	end
	debugPrint("%s mission generated.",info)
	return true
end

g_FuturesMission = Futures.new()
addModEventListener(g_FuturesMission)
