--
-- $Date $Revision$
--

ARF = LibStub("AceAddon-3.0"):NewAddon(
    "AutoReFollow",
    "AceConsole-3.0",
    "AceEvent-3.0",
	"AceTimer-3.0",
	"AceComm-3.0"
)

-- constants
local defaultbackoff = 1
local exponent = 1.2
local mastermaintainperiod = 5
local slaveupdateperiod = 10

-- modes
local mMASTER		= 0x01
local mSLAVE		= 0x02

-- slave states
local sUNKNOWN 		= 0x010
local sFOLLOWING 	= 0x020
local sNOTFOLLOWING = 0x040
local sOOR 			= 0x080
local sINVEHICLE	= 0x100

-- state variables
local dodebug = false
local mode = mMASTER
local activated = false
local master = nil
local slaves = {}
local state = sUNKNOWN
local backoff = defaultbackoff
local timer = nil
local busyuntil = nil

-- debug output
function ARF:Debug(...)
    if dodebug then
        self:Print("DEBUG: ", ...)
    end
end

-- enable addon
function ARF:OnEnable()
	
	-- populate from saved variables
	if ARF_DB.mode == "slave" then
		mode = mSLAVE
	end
	if ARF_DB.debug == true then
		dodebug = true
	end

	-- register for addon messages
	self:RegisterComm("arf")

	-- register slash command
	self:RegisterChatCommand("arf", "SlashCommand")

	self:Print("AutoReFollow enabled")

end

-- handle /arf slash command
-- /arf activate
-- /arf deactivate
-- /arf debug (toggle)
-- /arf list
function ARF:SlashCommand(text)
    local command, rest = text:match("^(%S*)%s*(.-)$")
    if command == "activate" then
        if activated == false then
			self:MasterActivate()
        end
    elseif command == "deactivate" then
		if activated == true then
			self:MasterDeactivate()
		end
    elseif command == "debug" then
        dodebug = not dodebug
		if dodebug then
			self:Print("debug is now on")
		else
			self:Print("debug is now off")
		end
    elseif command == "list" then
		self:List()
    else
        self:Print("usage:")
		self:Print("  /arf activate")
        self:Print("  /arf deactivate")
        self:Print("  /arf debug")
        self:Print("  /arf list")
    end
end

-- handle group member changes
function ARF:UpdateGroup()

	if GetNumRaidMembers() > 0 then return end

	-- remove lame slaves
	for k, v in pairs(slaves) do
		if not UnitInParty(k) then
			self:DeactivateSlave(k)
		end
	end
	
	-- add new trusted members
	if GetNumPartyMembers() > 0 then
		for i = 1, GetNumPartyMembers() do
			local name = UnitName("party"..i, true)
			if not slaves[name] and NTL:IsUnitTrusted(name) then
				self:ActivateSlave(name)
			end
		end
	end
	
end

function ARF:ActivateSlave(name)
	if slaves[name] then return end
	slaves[name]= {}
	slaves[name].age = time()
	self:Debug("sending activate to", name)
	if UnitExists(name) and UnitExists(name) then self:SendCommMessage("arf", "ACTIVATE", "WHISPER", name) end
end

function ARF:DeactivateSlave(name)
	if not slaves[name] then return end
	slaves[name] = nil
	self:Debug("sending deactivate to", name)
	if UnitExists(name) and UnitExists(name) then self:SendCommMessage("arf", "DEACTIVATE", "WHISPER", name) end
end

-- handle autofollow changes
function ARF:AUTOFOLLOW_BEGIN(event, name)
	self:Debug("AUTOFOLLOW_BEGIN", name)
	if name == master then
		state = sFOLLOWING
		self:Debug("sent STATE FOLLOWING to master")
		if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "STATE FOLLOWING", "WHISPER", master) end
		backoff = defaultbackoff
	else
		self:Debug("auto following, but not my master")
	end
end

function ARF:AUTOFOLLOW_END()
	self:Debug("AUTOFOLLOW_END")
	state = sNOTFOLLOWING
	self:Debug("sent STATE NOTFOLLOWING to master")
	if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "STATE NOTFOLLOWING", "WHISPER", master) end
	busyuntil = time() + (slaveupdateperiod/2)
	self:RetryFollow()
end

-- handle vehicle entry
function ARF:UNIT_ENTERED_VEHICLE(event, unit)
	if unit == "player" then
		if state == sFOLLOWING then
			self:Debug("sent STATE INVEHICLE to master")
			if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "STATE INVEHICLE", "WHISPER", master) end
		end
	end
end

-- handle NPC gossip windows
function ARF:GOSSIP_SHOW(event)
		self:RetryFollow()
	end
end

-- handle combat ending
function ARF:PLAYER_REGEN_ENABLED()
	if state == sNOTFOLLOWING then
		self:TryFollow()
	end
end

-- activate on master
function ARF:MasterActivate()
	if mode == mSLAVE then
		self:Print("not master")
	end
	
	-- events
	self:RegisterEvent("PARTY_MEMBERS_CHANGED", "UpdateGroup")
	self:RegisterEvent("RAID_ROSTER_UPDATE", "UpdateGroup")
	
	-- set state
	activated = true
	
	-- activate trusted party members
	if GetNumRaidMembers() == 0 then
		if GetNumPartyMembers() > 0 then
			self:Debug("iterating party members")
			for i = 1, GetNumPartyMembers() do
				local name = UnitName("party"..i, true)
				if name ~= UnitName("player") and NTL:IsUnitTrusted(name) then
					self:ActivateSlave(name)
				end
			end
		end
	end
	
	-- schedule maintain slaves timer
	timer = self:ScheduleRepeatingTimer("MaintainSlaves", mastermaintainperiod)
	
	self:Print("activating")
	
end

-- activate on slave
function ARF:SlaveActivate(newmaster)

	-- events
	self:RegisterEvent("PLAYER_REGEN_ENABLED")
	self:RegisterEvent("AUTOFOLLOW_BEGIN")
	self:RegisterEvent("AUTOFOLLOW_END")
	self:RegisterEvent("GOSSIP_SHOW")
	self:RegisterEvent("UNIT_ENTERED_VEHICLE")
	self:RegisterEvent("ZONE_CHANGED", "ClearState")
	self:RegisterEvent("ZONE_CHANGED_INDOORS", "ClearState")
	self:RegisterEvent("ZONE_CHANGED_NEW_AREA", "ClearState")

	if not NTL:IsUnitTrusted(newmaster) then
		self:Print("ERROR: activate from untrusted master ", newmaster)
		return
	end
	
	-- set state
	activated = true
	master = newmaster
	
	-- schedule update state timer
	timer = self:ScheduleRepeatingTimer("UpdateMaster", slaveupdateperiod)

	self:Print("activating")
	
	self:TryFollow()
	
end

-- deactivate on master
function ARF:MasterDeactivate()

	if mode == mSLAVE then
		self:Print("not master")
	end

	--events
	self:UnregisterAllEvents()
	
	-- timer
	self:CancelTimer(timer, true)

	-- set state
	activated = false
	
	-- deactivate slaves
	for k, v in pairs(slaves) do
		self:DeactivateSlave(k)
	end
	
	self:Print("deactivating")
	
end

-- deactivate on slave
function ARF:SlaveDeactivate()

	-- events
	self:UnregisterAllEvents()
	
	-- timer
	self:CancelTimer(timer, true)
	
	-- set state
	activated = false
	state = sUNKNOWN
	
	self:Print("deactivating")
	
end

-- list state
function ARF:List()
end

-- handle incoming addon messages
function ARF:OnCommReceived(prefix, message, distribution, sender)
	if not activated then
		self:Print("received comms from", sender, "while not activated")
		if mode == mMASTER then
			self:MasterActivate()
		else
			self:SlaveActivate(sender)
		end
	end
	self:Debug("received message", prefix, message, distribution, sender)
	if prefix == "arf" then
		local command, data = message:match("^(%S*)%s*(.-)$")
		if mode == mMASTER then
			if not slaves[sender]then
				slaves[sender] = {}
			end
			slaves[sender].age = time()
			if command == "STATE" then
				self:Debug("received STATE from", sender)
				if data == "FOLLOWING" then
					self:Debug(sender, "state is FOLLOWING")
					if slaves[sender].state == sNOTFOLLOWING then
						self:Print(sender, "has resumed following")
					end
					slaves[sender].state = sFOLLOWING
				elseif data == "NOTFOLLOWING" then
					self:Debug(sender, "state is NOTFOLLOWING")
					slaves[sender].state = sNOTFOLLOWING
				elseif data == "OOR" then
					self:Debug(sender, "state is OOR")
					slaves[sender].state = sOOR
				elseif data == "INVEHICLE" then
					self:Debug(sender, "state is INVEHICLE")
					slaves[sender].state = sINVEHICLE
				elseif data == "UNKNOWN" then
					self:Debug(sender, "state is UNKNOWN")
					slaves[sender].state = sUNKNOWN
				end
			elseif command == "CANTFOLLOW" then
				self:Debug("received CANTFOLLOW from", sender)
				self:Print(sender, "can't follow you")
			elseif command == "CANTFOLLOWVEHICLE" then
				self:Debug("received CANTFOLLOWVEHICLE from", sender)
				self:Print(sender, "is in a vehicle and can't follow you")
			elseif command == "BUSY" then
				self:Debug("received BUSY from", sender)
				self:Print(sender, "is busy and will try to re-follow")
			end
		else
			if command == "FOLLOWME" then
				self:Debug("received FOLLOWME from", sender)
				self:TryFollow()
			elseif command == "ACTIVATE" then
				self:Debug("received ACTIVATE from", sender)
				self:SlaveActivate(sender)
			elseif command == "DEACTIVATE" then
				self:Debug("received DEACTIVATE from", sender)
				self:SlaveDeactivate()
			end
		end
	end
end

-- try to follow the master
function ARF:TryFollow()
	-- if we're in a vehicle, we can't re-follow
	if UnitInVehicle("player") then
		self:Debug("sent CANTFOLLOWVEHICLE to", master)
		if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "CANTFOLLOWVEHICLE", "WHISPER", master) end
		self:Debug("sent STATE INVEHICLE to", master)
		if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "STATE INVEHICLE", "WHISPER", master) end
	-- if we're in the middle of a spellcast, re-schedule with exponential backoff
	elseif UnitCastingInfo("player") then
		self:Debug("sent BUSY (casting) to", master)
		if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "BUSY", "WHISPER", master) end
		self:RetryFollow()
	-- if the master is OOR, tell them we can't follow
	elseif not CheckInteractDistance(master, 4) then
		self:Debug("sent CANTFOLLOW to", master)
		if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "CANTFOLLOW", "WHISPER", master) end
		self:Debug("sent STATE OOR to", master)
		if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "STATE OOR", "WHISPER", master) end
	-- if we're busy, we can't follow yet
	elseif busyuntil ~= nil and busyuntil > time() then
		self:Debug("sent BUSY (window) to", master)
		if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "BUSY", "WHISPER", master) end
		self:RetryFollow()
	else
		FollowUnit(master)
	end
end

-- reschedule a tryfollow with exponential backoff
function ARF:RetryFollow()
	if timer and self:TimeLeft(timer) > 0 then
		local timeleft = self:TimeLeft(timer)
		self:Debug("not re-scheduling TryFollow; will fire in", timeleft, "seconds")
	else
		self:Debug("backoff is", backoff)
		local newbackoff = backoff ^ exponent
		self:Debug("new backoff is", newbackoff)
		self:ScheduleTimer(TryFollow, newbackoff)
		backoff = newbackoff
	end
end

-- periodically maintain slaves
function ARF:MaintainSlaves()

	local now = time()
	local threshold = now - (slaveupdateperiod*2)

	self:Debug("doing periodic MaintainSlaves")
	
	-- iterate over known slaves
	for k, v in pairs(slaves) do
		self:Debug(k, "state is", v.state, "age is", v.age)
		if v.age < threshold then
			self:Debug(k, "is stale, setting state to UNKNOWN")
			v.state = sUNKNOWN
		end
		if v.state == sUNKNOWN or v.state == sNOTFOLLOWING then
			self:Debug(k, "is not following, sending FOLLOWME")
			if UnitInParty(k) and UnitExists(k) then self:SendCommMessage("arf", "FOLLOWME", "WHISPER", k) end
		end
	end

end

-- periodically update master
function ARF:UpdateMaster()

	self:Debug("doing periodic UpdateMaster")

	-- are we following?
	if state == sFOLLOWING then
		self:Debug("sent STATE FOLLOWING to", master)
		if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "STATE FOLLOWING", "WHISPER", master) end
	elseif state == sNOTFOLLOWING then
		-- is the master out of range?
		if not CheckInteractDistance(master, 4) then
			self:Debug("sent STATE OOR to", master)
			if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "STATE OOR", "WHISPER", master) end
		-- are we on a vehicle?
		elseif UnitInVehicle("player") then
			self:Debug("sent STATE INVEHICLE to", master)
			if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "STATE INVEHICLE", "WHISPER", master) end
		-- not following for no good reason
		else
			self:Debug("sent STATE NOTFOLLOWING to", master)
			if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "STATE NOTFOLLOWING", "WHISPER", master) end
		end
	end
	
end

-- our zone changed; assume that we're not following and push state to the master
function ARF:ClearState()
		self:Debug("sent STATE UNKNOWN to", master)
		if UnitInParty(master) and UnitExists(master) then self:SendCommMessage("arf", "STATE UNKNOWN", "WHISPER", master) end
end

--
-- EOF
