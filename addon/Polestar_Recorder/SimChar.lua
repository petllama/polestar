-- Sim telemetry's character snapshot (docs/RECORDING.md, "Sim telemetry"):
-- the `char` record, the stats, gear and talents a leveling simulator's
-- gear budget is checked against. Only while /psrec sim is on and
-- recording; written at /psrec sim on and at every session's start (login or
-- reload, START_DELAY after PLAYER_ENTERING_WORLD, when the stats and talents
-- have loaded), after a level up, after talents change, and when equipment
-- changes settle (at most once per GEAR_SECONDS), always out of combat (the
-- client restricts unit stats in combat). The level, talent and gear ones are
-- not written when equal to the character's last one (its text is kept per
-- character in PolestarRecorderCharDB.simChar); the session's and /psrec sim
-- on's always are, because Polestar Client deletes uploaded chunks and a
-- session must carry its own sheet.
--
-- A read the client keeps secret (or one that fails) leaves its fields empty
-- and sets the snapshot's `secret` letter (s stats, g gear, t talents); the
-- snapshot is written with what was readable, never dropped.
--
-- APIs, verified against .ref/wow-ui-source-forever (Blizzard_APIDocumentation
-- Generated, Camelot PaperDollFrame): UnitStat (base, effective), UnitArmor,
-- UnitHealthMax, UnitPowerMax, UnitAttackPower / UnitRangedAttackPower (base,
-- posBuff, negBuff), GetSpellBonusDamage(school 2-7), GetSpellBonusHealing,
-- GetCritChance, GetRangedCritChance, GetSpellCritChance(school),
-- GetHitModifier, GetSpellHitModifier, GetDodgeChance, GetParryChance,
-- GetBlockChance, GetManaRegen (base, casting), GetHealthRegen, UnitDamage,
-- UnitRangedDamage, UnitAttackSpeed (all SecretWhenUnitStatsRestricted),
-- GetInventoryItemLink, and the talents as Forever keeps them: one C_Traits
-- tree per class (GetConfigInfo, GetTreeNodes, GetNodeInfo, GetEntryInfo,
-- GetDefinitionInfo), the config Polestar's Compat.TalentConfigs picks when
-- Polestar is loaded, else the same order (C_SpecializationInfo's active spec
-- group's config, then C_ClassTalents.GetActiveConfigID).

local ADDON, ns = ...

local select, type, pairs, ipairs, pcall, next, unpack, tonumber, floor, concat, format = select, type, pairs, ipairs, pcall, next, unpack, tonumber, math.floor, table.concat, string.format
local GetTime = GetTime
local usable, Num, Str = ns.Usable, ns.Num, ns.Str

local SETTLE = 3 -- seconds after a level up or talent change before the snapshot
local GEAR_SETTLE = 10 -- seconds after the last equipment change
local GEAR_SECONDS = 180 -- equipment changes write at most this often
local START_DELAY = 10 -- seconds after a session starts (talents load late)
local SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 } -- every slot but shirt (4) and tabard (19)
local TALENT_CAP = 100 -- most talent nodes listed
local WHY = { "o", "l", "t", "g" } -- the reasons' order in `why`

local function pack(...) return { n = select("#", ...), ... } end

local secret -- the snapshot's secret letters while it reads

local function read(letter, fn, ...)
	if type(fn) ~= "function" then return nil end
	local r = pack(pcall(fn, ...))
	if not r[1] then
		secret[letter] = true -- a read that failed is as unknown as a secret one
		return nil
	end
	for i = 2, r.n do
		if r[i] ~= nil and not usable(r[i]) then
			r[i] = nil
			secret[letter] = true
		end
	end
	return r[2], r[3], r[4], r[5], r[6], r[7], r[8]
end

local function whole(v) return type(v) == "number" and floor(v + 0.5) or nil end
local function cent(v) return type(v) == "number" and floor(v * 100 + 0.5) or nil end

local function stats()
	local out = {}
	for i = 1, 5 do
		local base, eff = read("s", UnitStat, "player", i)
		out[i] = format("%s:%s", whole(base) or "", whole(eff) or "")
	end
	return concat(out, ";")
end

local function ap(fn)
	local base, pos, neg = read("s", fn, "player")
	if type(base) ~= "number" then return nil end
	return whole(base + (type(pos) == "number" and pos or 0) + (type(neg) == "number" and neg or 0))
end

-- school:value for the spell schools 2-7 (holy .. arcane), value by fn.
local function schools(fn, scale)
	local out = {}
	for school = 2, 7 do
		local v = read("s", fn, school)
		if type(v) == "number" then out[#out + 1] = format("%d:%d", school, floor(v * scale + 0.5)) end
	end
	return #out > 0 and concat(out, ";") or nil
end

-- slot:itemId:enchantId of every equipped item.
local function gear()
	local out = {}
	for _, slot in ipairs(SLOTS) do
		local link = read("g", GetInventoryItemLink, "player", slot)
		if Str(link) then
			local id, enchant = link:match("item:(%d+):(%d*)")
			if id then
				enchant = tonumber(enchant)
				out[#out + 1] = format("%d:%s:%s", slot, id, (enchant and enchant > 0) and enchant or "")
			end
		end
	end
	return #out > 0 and concat(out, ";") or nil
end

local function configs()
	local P = Polestar
	if type(P) == "table" and type(P.Compat) == "table" and type(P.Compat.TalentConfigs) == "function" then
		local ok, list = pcall(P.Compat.TalentConfigs)
		if ok and type(list) == "table" then return list end
	end
	local out = {}
	local S = C_SpecializationInfo
	if S and S.GetActiveSpecGroup and S.GetCombatConfigIDForSpecGroup then
		local g = Num(read("t", S.GetActiveSpecGroup))
		local c = g and Num(read("t", S.GetCombatConfigIDForSpecGroup, g))
		if c then out[1] = c end
	end
	local CT = C_ClassTalents
	local c = CT and Num(read("t", CT.GetActiveConfigID))
	if c and c ~= out[1] then out[#out + 1] = c end
	return out
end

-- nodeId:rank:spellId of every node with points, of the class tree.
local function talents()
	local T = C_Traits
	if not (T and T.GetConfigInfo and T.GetTreeNodes and T.GetNodeInfo) then return nil end
	local config = configs()[1]
	if not config then return nil end
	local info = read("t", T.GetConfigInfo, config)
	local tree = type(info) == "table" and type(info.treeIDs) == "table" and Num(info.treeIDs[1]) or nil
	if not tree then return nil end
	local ids = read("t", T.GetTreeNodes, tree)
	if type(ids) ~= "table" then return nil end
	local out = {}
	for _, id in ipairs(ids) do
		if #out >= TALENT_CAP then break end
		local n = read("t", T.GetNodeInfo, config, id)
		local node = type(n) == "table" and Num(n.ID) or nil
		if node and node ~= 0 then
			local rank = Num(n.ranksPurchased) or Num(n.activeRank)
			if rank and rank > 0 then
				local entry = type(n.activeEntry) == "table" and Num(n.activeEntry.entryID) or (type(n.entryIDs) == "table" and Num(n.entryIDs[1])) or nil
				local spell
				if entry and T.GetEntryInfo and T.GetDefinitionInfo then
					local e = read("t", T.GetEntryInfo, config, entry)
					local def = type(e) == "table" and Num(e.definitionID) or nil
					local d = def and read("t", T.GetDefinitionInfo, def)
					spell = type(d) == "table" and Num(d.spellID) or nil
				end
				out[#out + 1] = format("%d:%d:%s", node, rank, spell or "")
			end
		end
	end
	return #out > 0 and concat(out, ";") or nil
end

-- fn(...) for a part of the snapshot; an error leaves the part empty and
-- sets its letter instead of losing the whole snapshot.
local function part(letter, fn, ...)
	local ok, v = pcall(fn, ...)
	if ok then return v end
	secret[letter] = true
	return nil
end

-- The snapshot's fields (docs/RECORDING.md `char`), without `why` and `secret`.
local function snapshot()
	local _, class = UnitClass("player")
	local _, race = UnitRace("player")
	local f, n = {}, 0
	local function add(v)
		n = n + 1
		f[n] = v
	end
	add(whole(Num(UnitLevel("player"))))
	add(Str(class))
	add(Str(race))
	add(part("s", stats))
	add(whole(read("s", UnitHealthMax, "player")))
	add(whole(read("s", UnitPowerMax, "player", 0)))
	local base, eff = read("s", UnitArmor, "player")
	add(whole(eff) or whole(base))
	add(part("s", ap, UnitAttackPower))
	add(part("s", ap, UnitRangedAttackPower))
	add(part("s", schools, GetSpellBonusDamage, 1))
	add(whole(read("s", GetSpellBonusHealing)))
	add(cent(read("s", GetCritChance)))
	add(cent(read("s", GetRangedCritChance)))
	add(part("s", schools, GetSpellCritChance, 100))
	add(cent(read("s", GetHitModifier)))
	add(cent(read("s", GetSpellHitModifier)))
	add(cent(read("s", GetDodgeChance)))
	add(cent(read("s", GetParryChance)))
	add(cent(read("s", GetBlockChance)))
	local mr, mrc = read("s", GetManaRegen)
	add(cent(mr))
	add(cent(mrc))
	add(cent((read("s", GetHealthRegen))))
	local mainMin, mainMax, offMin, offMax = read("s", UnitDamage, "player")
	local mainSpeed, offSpeed = read("s", UnitAttackSpeed, "player")
	add(cent(mainMin))
	add(cent(mainMax))
	add(cent(mainSpeed))
	local hasOff = type(offSpeed) == "number" and offSpeed > 0
	add(hasOff and cent(offMin) or nil)
	add(hasOff and cent(offMax) or nil)
	add(hasOff and cent(offSpeed) or nil)
	local rSpeed, rMin, rMax = read("s", UnitRangedDamage, "player")
	local hasRanged = type(rSpeed) == "number" and rSpeed > 0
	add(hasRanged and cent(rMin) or nil)
	add(hasRanged and cent(rMax) or nil)
	add(hasRanged and cent(rSpeed) or nil)
	add(part("g", gear))
	add(part("t", talents))
	return f, n
end

---------------------------------------------------------------------------
-- When
---------------------------------------------------------------------------

local why = {} -- reasons waiting
local due = nil -- GetTime() the pending snapshot is due, nil when none
local token = nil
local lastGear = -math.huge
local afterCombat = false

local function active() return ns.SimOn() and ns.Recording() end

local function inCombat()
	local v = UnitAffectingCombat and UnitAffectingCombat("player")
	return not usable(v) or v == true
end

local function write()
	due, token = nil, nil
	if not active() then
		why = {}
		return
	end
	if inCombat() then
		afterCombat = true
		return
	end
	secret = {}
	local f, n = snapshot()
	local s = ""
	for _, c in ipairs({ "s", "g", "t" }) do
		if secret[c] then s = s .. c end
	end
	local parts = {}
	for i = 1, n do parts[i] = ns.Field(f[i]) end
	local text = concat(parts, "\t") .. "\t" .. s
	local w = ""
	for _, c in ipairs(WHY) do
		if why[c] then w = w .. c end
	end
	local gearAsked, always = why.g, why.o
	why = {}
	local char = ns.CharDB()
	if char.simChar == text and not always then return end
	f[n + 1], f[n + 2] = w, s
	if ns.SimEmit(GetTime(), "char", unpack(f, 1, n + 2)) then
		char.simChar = text
		if gearAsked then lastGear = GetTime() end
	end
end

local function ask(reason, delay)
	if not active() then return end
	why[reason] = true
	local at = GetTime() + delay
	if due and due <= at then return end
	due = at
	local mine = {}
	token = mine
	C_Timer.After(delay, function()
		if token == mine then write() end
	end)
end

-- Sim.lua at /psrec sim on.
function ns.SimCharNow(reason) ask(reason or "o", 1) end

ns.On("PLAYER_LEVEL_UP", function() ask("l", SETTLE) end)
for _, ev in ipairs({ "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE", "TRAIT_CONFIG_UPDATED" }) do
	ns.On(ev, function() ask("t", SETTLE) end)
end
ns.On("PLAYER_EQUIPMENT_CHANGED", function()
	local wait = math.max(GEAR_SETTLE, lastGear + GEAR_SECONDS - GetTime())
	ask("g", wait)
end)
ns.On("PLAYER_REGEN_ENABLED", function()
	if afterCombat then
		afterCombat = false
		local r = next(why)
		if r then ask(r, SETTLE) end
	end
end)

ns.OnSession(function()
	why, due, token, afterCombat, lastGear = {}, nil, nil, false, -math.huge
	ask("o", START_DELAY)
end)
