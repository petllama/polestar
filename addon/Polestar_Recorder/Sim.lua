-- Sim telemetry (docs/RECORDING.md, "Sim telemetry"): what a leveling
-- simulator needs to calibrate its model against real play. Off until the
-- player types /psrec sim on (and only while recording is on):
--   - `regen`: out-of-combat health and mana gains, a record per resource and
--     state a minute at most (count, sum, smallest, largest, the gaps between
--     gains as a histogram), with the Spirit, Intellect, pool size and level
--     they came with, and the client's own regen rates;
--   - `meal`: a Food or Drink aura from start to end, with health and mana at
--     sitting down and standing up (the rest thresholds);
--   - `pull`: one record per combat: its length, health and power at the
--     start, lowest and end, kills and XP (Finds.lua's kill records), death,
--     the target seen just before it, how many hostile nameplates fought at
--     once, the player's own casts and items, the time since the previous
--     pull and the eating or drinking in between;
--   - `hit`: the player's health losses in a pull against one mob (the mob's
--     swings: time since the previous loss and the amount), with armor;
--   - `pet`: the pet's family, level, pools, happiness, loyalty, training
--     points and armor when it is summoned or changes, goes, dies, and at
--     each pull's start and end (the pull also keeps the pet's health);
--   - `simdeath`: a death's context (the pull so far, its target, the last
--     health losses, items used, the pet, rested XP, the last meal, group)
--     written once the player is alive again, with the seconds it took and
--     how (spirit healer, corpse, resurrected) and Resurrection Sickness.
-- The `char` snapshot (stats, gear, talents) is SimChar.lua's.
-- Each record also goes into a local copy (PolestarRecorderDB.simlog, at
-- most SIMLOG_BYTES) that an upload's acknowledgement does not delete: the
-- uploader's library may not know these kinds yet.
--
-- Forever's combat log is closed (Finds.lua), and the client makes values
-- secret: UnitHealth always (SecretReturns, in and out of combat), UnitPower
-- for every power type the client does not flag as never secret (mana was
-- secret in and out of combat in the first real sessions), UnitStat and the
-- regen rates when unit stats are restricted (combat), aura data in combat,
-- unit identity, UNIT_SPELLCAST_SUCCEEDED's spell. Every read goes through
-- ns.Num/ns.Str: a secret value reads as unknown, leaves its field empty and
-- sets a letter in the pull's `secret` field, so the data says what could not
-- be seen. /psrec sim shows what reads now.
--
-- Health and power that are secret out of combat stay secret all session, so
-- they are probed once per session (`unavailable`, out of combat): then the
-- Recorder stops reading them (no UNIT_HEALTH/UNIT_POWER_FREQUENT work, no
-- `regen` or `hit` for that resource, empty health/power fields in `pull` and
-- `meal` with `h`/`p` still in `secret`) and says so once, in the session's
-- `ctx` line of the local copy. Timing keeps working: `pull` lengths, gaps and
-- the rest between pulls, `meal` lengths (Food/Drink auras are readable out of
-- combat), kills, XP, casts.
--
-- No non-secret proxy for the current health or mana exists in the client's
-- API documentation (checked for Forever, Blizzard_APIDocumentationGenerated):
-- UnitHealthMissing/UnitHealthPercent/UnitGetIncomingHeals are SecretReturns,
-- UnitPowerMissing/UnitPowerPercent follow UnitPower, a StatusBar's GetValue
-- and GetMinMaxValues return secrets for a secret bar value (the
-- PlayerFrame's bars), UNIT_HEALTH/UNIT_POWER_* carry only the unit and the
-- power token, UNIT_COMBAT's amount is a SecretValue, and
-- C_CombatText.GetCurrentEventInfo is SecretReturns. What stays readable for
-- the player: UnitHealthMax and UnitPowerMax (secret only for units that are
-- not player-controlled), GetHealthRegen (no secret flag at all), and
-- GetManaRegen/GetPowerRegen/UnitStat out of combat: the `char` snapshot
-- keeps those (the client's own regen rates per level, Spirit and gear).
--
-- APIs, verified against .ref/wow-ui-source-forever (Blizzard_APIDocumentation
-- Generated): UnitHealth / UnitHealthMax, UnitPower / UnitPowerMax /
-- UnitPowerType, UnitStat (effective is the 2nd return), UnitArmor (effective
-- 2nd), GetHealthRegen, GetManaRegen (base, casting), UnitCreatureType (a
-- localised name), UnitClassification, UnitLevel, UnitCanAttack,
-- UnitAffectingCombat, UnitThreatSituation, C_UnitAuras.GetAuraDataByIndex,
-- NAME_PLATE_UNIT_ADDED / REMOVED, UNIT_HEALTH, UNIT_POWER_FREQUENT,
-- UNIT_SPELLCAST_SUCCEEDED, UNIT_SPELLCAST_CHANNEL_START / STOP,
-- PLAYER_REGEN_DISABLED / ENABLED, PLAYER_DEAD, PLAYER_ALIVE, PLAYER_UNGHOST,
-- UNIT_PET, UnitCreatureFamily, UnitIsDead, GetPetHappiness (happiness,
-- damage percentage), GetPetLoyalty (a text), GetPetTrainingPoints (total,
-- spent), GetXPExhaustion, IsInGroup, GetSubZoneText. The client has no API
-- for sitting, so `regen` cannot tell sitting from standing.

local ADDON, ns = ...
local L = ns.L

local type, pairs, ipairs, pcall, floor, concat, format, select = type, pairs, ipairs, pcall, math.floor, table.concat, string.format, select
local GetTime = GetTime
local usable, Num, Str = ns.Usable, ns.Num, ns.Str

local REGEN_SECONDS = 60 -- a `regen` record per resource and state at most this often
local FSR_SECONDS = 5 -- mana gains this soon after spending mana are inside the five-second rule
local CAST_WINDOW = 2 -- a gain this soon after the player's own cast may be its heal
local SHORT_AURA = 60 -- another unit's helpful aura of at most this many seconds may be a heal over time
local PULL_DELAY = 3.5 -- seconds after combat ends before `pull` is written (Finds.lua links kills within 3 s)
local KILL_SLACK = 1 -- a kill this long before the pull or after its end counts for it
local TARGET_FRESH = 30 -- a target read this long before combat is the pull's target
local PLATE_TICK = 0.5 -- seconds between nameplate counts in combat
local HIT_CAP = 40 -- most health losses listed per pull
local LOSS_CAP = 5 -- the last health losses a `simdeath` lists
local SICKNESS_SPELL = 15007 -- Resurrection Sickness
local SICKNESS_DELAY = 1.5 -- seconds after alive again before the debuff is looked for
local DEATH_PULL_SLACK = 2 -- a pull that ended this long before PLAYER_DEAD is the death's
local CAST_CAP = 24 -- most distinct spells (and items) listed per pull
local GAP_CAP = 300 -- gaps (tenths of a second) above this share one bin
local SIMLOG_BYTES = 512 * 1024 -- the local copy keeps the newest records up to this size
local TENTHS_FORMAT = "%.0f" -- epoch tenths pass 2^31: the client's "%d" takes 32-bit integers only
ns.SIMLOG_BYTES = SIMLOG_BYTES

---------------------------------------------------------------------------
-- Spells by name (Classic ids; the names match every rank in the client's
-- language, also ranks Forever renumbered)
---------------------------------------------------------------------------

local ABSORB_IDS = { 17, 1463, 11426, 7812 } -- Power Word: Shield, Mana Shield, Ice Barrier, Sacrifice
local HOT_IDS = { 139, 774, 8936 } -- Renew, Rejuvenation, Regrowth
local SELF_DAMAGE_IDS = { 1454, 2687, 1949 } -- Life Tap, Bloodrage, Hellfire
local FOOD_SPELL, DRINK_SPELL = 433, 430

local names -- spell name -> "a" absorb | "h" heal over time | "s" self-damage; built on first use
local foodName, drinkName

local function buildNames()
	names = {}
	for _, list in ipairs({ { ABSORB_IDS, "a" }, { HOT_IDS, "h" }, { SELF_DAMAGE_IDS, "s" } }) do
		for _, id in ipairs(list[1]) do
			local n = ns.SpellName(id)
			if Str(n) then names[n] = list[2] end
		end
	end
	foodName = Str(ns.SpellName(FOOD_SPELL)) or false
	drinkName = Str(ns.SpellName(DRINK_SPELL)) or false
end

local function spellKind(spell)
	if not names then buildNames() end
	local n = spell and Str(ns.SpellName(spell))
	return n and names[n] or nil
end

-- "f" food, "d" drink, "b" both of an aura name, else nil (World.lua's rule).
local function mealKind(name)
	if not Str(name) then return nil end
	if not names then buildNames() end
	local food = foodName and name:find(foodName, 1, true)
	local drink = drinkName and name:find(drinkName, 1, true)
	if food and drink then return "b" end
	if name == foodName then return "f" end
	if name == drinkName then return "d" end
	return nil
end

---------------------------------------------------------------------------
-- The setting and the local copy
---------------------------------------------------------------------------

local on = false
local keepContext -- forward (Events)
local simlog = {} -- lines: kind, server epoch (tenths of a second), charId, the record's fields
local simBytes = 0

local function save()
	local db = ns.DB()
	db.simOn = on or nil
	db.simlog = #simlog > 0 and simlog or nil
end

local keepFailed = false -- an error in the local copy was reported this session

function ns.SimOn() return on end

function ns.SetSim(v)
	local was = on
	on = v and true or false
	save()
	if on and not was and ns.Recording() then
		-- the snapshot is asked for first: nothing below may keep it from coming
		if ns.SimCharNow then ns.SimCharNow("o") end
		keepContext()
		ns.SimPetNow()
	end
end

function ns.SimStats()
	return { records = #simlog, bytes = simBytes }
end

function ns.SimClear()
	simlog, simBytes = {}, 0
	save()
end

local function trim()
	if simBytes <= SIMLOG_BYTES then return end
	-- keep the newest three quarters of the cap
	local keep, bytes, from = SIMLOG_BYTES * 3 / 4, 0, #simlog + 1
	while from > 1 and bytes + #simlog[from - 1] + 1 <= keep do
		from = from - 1
		bytes = bytes + #simlog[from] + 1
	end
	local out = {}
	for i = from, #simlog do out[#out + 1] = simlog[i] end
	simlog, simBytes = out, bytes
end

-- Appends a line to the local copy: kind, server time (tenths of a second),
-- the character id, the fields. The time is formatted with "%.0f": the
-- client's "%d" raises an error above 2^31, and server time in tenths is far
-- above it (the cause of the empty copy and the missing `char` of the first
-- real sessions).
local function append(t, kind, ...)
	local parts = { kind, format(TENTHS_FORMAT, floor((GetServerTime() - (GetTime() - t)) * 10 + 0.5)), ns.CharId() or "" }
	for i = 1, select("#", ...) do parts[#parts + 1] = ns.Field((select(i, ...))) end
	local line = concat(parts, "\t")
	simlog[#simlog + 1] = line
	simBytes = simBytes + #line + 1
	trim()
	ns.DB().simlog = simlog
end

-- append, never raising: a failing local copy must not cost the caller its
-- record (the chunk's) or what it does next. The first error of a session is
-- passed to the error handler.
local function keep(t, kind, ...)
	local ok, err = pcall(append, t, kind, ...)
	if not ok and not keepFailed then
		keepFailed = true
		geterrorhandler()(err)
	end
	return ok
end

-- Writes a record at GetTime() time t into the chunk and the local copy.
local function emit(t, kind, ...)
	if not on or not ns.RecAt(t, kind, ...) then return false end
	keep(t, kind, ...)
	return true
end
ns.SimEmit = emit

ns.On("ADDON_LOADED", function(_, name)
	if name ~= ADDON then return end
	local db = PolestarRecorderDB
	on = type(db) == "table" and db.simOn == true
	simlog, simBytes = {}, 0
	if type(db) == "table" and type(db.simlog) == "table" then
		for _, line in ipairs(db.simlog) do
			if type(line) == "string" then
				simlog[#simlog + 1] = line
				simBytes = simBytes + #line + 1
			end
		end
	end
	trim()
	save()
end)

---------------------------------------------------------------------------
-- Reads. secret[letter] is set while a pull runs and a read was secret.
---------------------------------------------------------------------------

local pull -- the running pull, or nil
local readable = {} -- letter -> true (read) | false (secret) at the last try, for /psrec sim
-- h, p -> true when the player's health / power was secret out of combat this
-- session (then never read again until the next session), false readable, nil
-- not probed yet
local unavailable = {}

local sink -- a snapshot's own secret letters while it reads (pet, simdeath), or nil

local function note(letter, v)
	if v == nil then return nil end
	if not usable(v) then
		readable[letter] = false
		if pull then pull.secret[letter] = true end
		if sink then sink[letter] = true end
		return nil
	end
	readable[letter] = true
	return v
end

local function call(letter, fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b = pcall(fn, ...)
	if not ok then return nil end
	return note(letter, a), note(letter, b)
end

local function round(v) return v and floor(v + 0.5) or nil end

-- Secret letters of a set, in the documented order.
local SECRET_ORDER = { "h", "p", "a", "n", "c", "s", "t", "e", "i" }

local function flags(set)
	local s = ""
	for _, c in ipairs(SECRET_ORDER) do
		if set[c] then s = s .. c end
	end
	return s
end


-- A number read, rounded: records hold whole numbers.
local function num(letter, fn, ...)
	local a = call(letter, fn, ...)
	return type(a) == "number" and round(a) or nil
end

-- Health and the player's power, current and maximum. A resource that is
-- unavailable this session is not read: its current value is nil and its
-- letter is set as a secret read would set it; the maximum is still read.
local function skipped(letter)
	readable[letter] = false
	if pull then pull.secret[letter] = true end
	if sink then sink[letter] = true end
end

local function health()
	if unavailable.h then
		skipped("h")
		return nil, num("h", UnitHealthMax, "player")
	end
	return num("h", UnitHealth, "player"), num("h", UnitHealthMax, "player")
end

local function power(pt)
	if pt == nil then return nil, nil end
	if unavailable.p then
		skipped("p")
		return nil, num("p", UnitPowerMax, "player", pt)
	end
	return num("p", UnitPower, "player", pt), num("p", UnitPowerMax, "player", pt)
end

local function powerType()
	local pt = num("p", UnitPowerType, "player")
	return pt
end

local function stat(i)
	local cur, eff = call("s", UnitStat, "player", i)
	if type(eff) == "number" then return round(eff) end
	return type(cur) == "number" and round(cur) or nil
end

local function armor()
	local base, eff = call("s", UnitArmor, "player")
	if type(eff) == "number" then return round(eff) end
	return type(base) == "number" and round(base) or nil
end

local function level() return Num(UnitLevel and UnitLevel("player")) end

local function inCombat()
	local v = UnitAffectingCombat and UnitAffectingCombat("player")
	return usable(v) and v == true
end

-- Decides, out of combat, whether the player's health and power are secret
-- for this session (Forever: UnitHealth always is, mana was too). Undecided
-- (nil) in combat or without the function; then tried again after a pull.
local function probeUnavailable()
	if inCombat() then return end
	if unavailable.h == nil and type(UnitHealth) == "function" then
		local ok, v = pcall(UnitHealth, "player")
		if ok and v ~= nil then unavailable.h = not usable(v) end
	end
	if unavailable.p == nil and type(UnitPower) == "function" then
		local okt, pt = pcall(UnitPowerType or function() end, "player")
		pt = okt and Num(pt) or 0
		local ok, v = pcall(UnitPower, "player", pt)
		if ok and v ~= nil then unavailable.p = not usable(v) end
	end
end

-- The letters of what is unavailable this session ("h", "p", "hp" or "").
local function unavailableLetters()
	return (unavailable.h and "h" or "") .. (unavailable.p and "p" or "")
end
ns.SimUnavailable = unavailableLetters

-- Rates per second times 10, of the client's own regen readings.
local function rate10(v)
	if type(v) ~= "number" then return nil end
	return floor(v * 10 + 0.5)
end

---------------------------------------------------------------------------
-- Auras: meals (Food, Drink), absorbs, heals over time from others
---------------------------------------------------------------------------

local meal = nil -- { kind, at, hp0, mp0 } while eating or drinking
local lastMealEnd = nil -- GetTime() a meal last ended
local hotUntil = -math.huge -- a heal over time may tick until then
local absorbing = nil -- true/false at the last readable scan, nil unknown
local mealsSince = { flags = "", seconds = 0 } -- meals since the last pull ended

local function hasFlag(s, c) return s:find(c, 1, true) ~= nil end

local function endMeal(now)
	local m = meal
	meal = nil
	if not m then return end
	local hp1, hpMax = health()
	local mp1, mpMax = power(0)
	local secs = now - m.at
	emit(now, "meal", m.kind, floor(secs + 0.5), level(), m.hp0, hp1, hpMax, m.mp0, mp1, mpMax)
	for c in m.kind:gmatch(".") do
		if not hasFlag(mealsSince.flags, c) then mealsSince.flags = mealsSince.flags .. c end
	end
	mealsSince.seconds = mealsSince.seconds + secs
	lastMealEnd = now
end

local function scanAuras()
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
	local now = GetTime()
	local mk, absorb, unreadable = nil, false, false
	for i = 1, 40 do
		local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
		if not ok or not a then break end
		if not usable(a) then
			unreadable = true
			break
		end
		local name = Str(a.name)
		if not name then
			unreadable = true
		else
			mk = mk or mealKind(name)
			local spell = Num(a.spellId)
			local kind = (spell and spellKind(spell)) or (names and names[name])
			if kind == "a" then absorb = true end
			local dur, exp = Num(a.duration), Num(a.expirationTime)
			local src = Str(a.sourceUnit)
			if exp and dur and dur > 0 and (kind == "h" or (dur <= SHORT_AURA and src ~= "player" and not mealKind(name))) then
				if exp > hotUntil then hotUntil = exp end
			end
		end
	end
	if unreadable then
		readable.a = false
		if pull then pull.secret.a = true end
		return
	end
	readable.a = true
	absorbing = absorb
	if pull and absorb then pull.absorb = true end
	if mk and not meal and not pull then
		meal = { kind = mk, at = now }
		meal.hp0 = health()
		meal.mp0 = power(0)
	elseif not mk and meal then
		endMeal(now)
	end
end

---------------------------------------------------------------------------
-- Regen: out-of-combat gains, aggregated per resource and state
---------------------------------------------------------------------------

-- States: e eating (health) or drinking (mana) aura, a the player channels
-- (bandage, Evocation), h maybe a heal (own cast within CAST_WINDOW, a heal
-- over time), 5 mana inside the five-second rule, n natural.
local agg = {} -- res -> { key, state, level, spi, int, max, n, sum, lo, hi, gaps = {}, t0 }
local last = { h = {}, m = {} } -- res -> { v, max, rise }
local lastSpend = -math.huge -- the last mana decrease
local lastCast = -math.huge -- the player's last successful cast
local channeling = false

local function flushRegen(res, now)
	local a = agg[res]
	agg[res] = nil
	if not a or a.n == 0 then return end
	local bins, keys = {}, {}
	for g, c in pairs(a.gaps) do keys[#keys + 1] = g end
	table.sort(keys)
	for _, g in ipairs(keys) do bins[#bins + 1] = format("%d:%d", g, a.gaps[g]) end
	local rate, rate5
	if res == "h" then
		local ok, r = pcall(GetHealthRegen or function() end)
		rate = ok and rate10(note("s", r)) or nil
	else
		local ok, r, r5 = pcall(GetManaRegen or function() end)
		if ok then rate, rate5 = rate10(note("s", r)), rate10(note("s", r5)) end
	end
	emit(a.t0, "regen", res, a.state, a.level, a.spi, a.int, a.max, a.n, a.sum, a.lo, a.hi, concat(bins, ";"), rate, rate5)
end

local function regenState(res, now)
	if meal and (res == "h" and (meal.kind == "f" or meal.kind == "b") or res == "m" and (meal.kind == "d" or meal.kind == "b")) then
		return "e"
	end
	if channeling then return "a" end
	if now - lastCast <= CAST_WINDOW or now <= hotUntil then return "h" end
	if res == "m" and now - lastSpend < FSR_SECONDS then return "5" end
	return "n"
end

local function gain(res, amount, gap, maxv, now)
	local state = regenState(res, now)
	local lvl, spi, int = level(), stat(5), stat(4)
	local key = concat({ state, lvl or "", spi or "", int or "", maxv }, "|")
	local a = agg[res]
	if a and (a.key ~= key or now - a.t0 >= REGEN_SECONDS) then
		flushRegen(res, now)
		a = nil
	end
	if not a then
		a = { key = key, state = state, level = lvl, spi = spi, int = int, max = maxv, n = 0, sum = 0, gaps = {}, t0 = now }
		agg[res] = a
	end
	a.n = a.n + 1
	a.sum = a.sum + amount
	if not a.lo or amount < a.lo then a.lo = amount end
	if not a.hi or amount > a.hi then a.hi = amount end
	if gap then
		local g = floor(gap * 2 + 0.5) * 5 -- tenths of a second, in half-second bins
		if g > GAP_CAP then g = GAP_CAP end
		a.gaps[g] = (a.gaps[g] or 0) + 1
	end
end

local function observe(res, cur, maxv)
	local s = last[res]
	local now = GetTime()
	if cur == nil or maxv == nil then
		s.v, s.max, s.rise = nil, nil, nil
		return
	end
	if s.v and s.max == maxv then
		if cur > s.v then
			if not pull and not inCombat() then
				-- the gap counts only between gains below a full pool
				gain(res, cur - s.v, s.rise and now - s.rise or nil, maxv, now)
			end
			s.rise = now
		elseif cur < s.v and res == "m" then
			lastSpend = now
		end
	else
		s.rise = nil
	end
	if cur >= maxv then s.rise = nil end
	s.v, s.max = cur, maxv
end

---------------------------------------------------------------------------
-- Pulls and hits
---------------------------------------------------------------------------

local target = nil -- the last target read out of combat: { at, npc, lvl, cls, ctype, mana }
local plates = {} -- nameplate unit tokens shown
local lastPullEnd = nil
local plateTicker
local waiting = {} -- pulls that ended, waiting PULL_DELAY for their kills

local function readTarget()
	if inCombat() then return end
	local k, npc = ns.Ref("target")
	if k ~= "c" or not npc then return end
	local attack = UnitCanAttack and UnitCanAttack("player", "target")
	if not (usable(attack) and attack) then return end
	local t = { at = GetTime(), npc = npc }
	t.lvl = num("t", UnitLevel, "target")
	t.cls = ns.Cls(call("t", UnitClassification, "target"))
	local ctype = call("t", UnitCreatureType, "target")
	t.ctype = Str(ctype) and ns.ListText(ctype) or nil
	local pt = num("t", UnitPowerType, "target")
	local pmax = num("t", UnitPowerMax, "target", 0)
	if pt ~= nil then t.mana = (pt == 0 and pmax and pmax > 0) and true or false end
	target = t
end

-- Hostile nameplate units fighting now: with threat on the player when the
-- client says so ("t"), else in combat at all ("c").
local function countPlates()
	local p = pull
	if not p then return end
	local n, how = 0, nil
	for token in pairs(plates) do
		local ok, attack = pcall(UnitCanAttack, "player", token)
		if ok and usable(attack) and attack then
			-- a number: the player is on the unit's threat list; nil: not
			local okt, threat = false, nil
			if UnitThreatSituation then okt, threat = pcall(UnitThreatSituation, "player", token) end
			if okt and usable(threat) then
				readable.n = true
				how = "t"
				if type(threat) == "number" then n = n + 1 end
			else
				if okt then
					readable.n = false
					p.secret.n = true
				end
				local okc, c = pcall(UnitAffectingCombat, token)
				if okc and usable(c) then
					how = how or "c"
					if c then n = n + 1 end
				elseif okc then
					p.secret.n = true
				end
			end
		end
	end
	if how and (not p.mobsHow or how == "t") then p.mobsHow = how end
	if how and (p.mobs == nil or n > p.mobs) then p.mobs = n end
end

local function low(p, key, v)
	if v ~= nil and (p[key] == nil or v < p[key]) then p[key] = v end
end

---------------------------------------------------------------------------
-- The pet: `pet` snapshots, and its health in the pull. Its reads go
-- through petRead: a secret value sets the pull's `e` and the snapshot's
-- own letter (h health, p power, i identity, s stats).
---------------------------------------------------------------------------

local petSeen = nil -- { guid, npc, dead } of the pet last seen, nil without one

local function petRead(letter, fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c = pcall(fn, ...)
	if not ok then return nil end
	local out = { a, b, c }
	for i = 1, 3 do
		local v = out[i]
		if v ~= nil and not usable(v) then
			out[i] = nil
			readable.e = false
			if pull then pull.secret.e = true end
			if sink then sink[letter] = true end
		elseif v ~= nil then
			readable.e = true
		end
	end
	return out[1], out[2], out[3]
end

local function petNum(v) return type(v) == "number" and round(v) or nil end

local function petExists()
	local ok, v = pcall(UnitExists or function() end, "pet")
	return ok and usable(v) and v == true
end

local function petHealth()
	local cur, mx = petRead("h", UnitHealth, "pet"), petRead("h", UnitHealthMax, "pet")
	return petNum(cur), petNum(mx)
end

-- A name field: no `|`, tabs or newlines, at most 100 characters.
local function placeName(v)
	if not Str(v) then return nil end
	local s = v:gsub("[|\t\r\n]", " ")
	return s:sub(1, 100)
end

local function petSnapshot(why)
	local s = {}
	sink = s
	local _, npc = ns.ParseGUID(petRead("i", UnitGUID, "pet"))
	local family = placeName(petRead("i", UnitCreatureFamily, "pet"))
	local lvl = petNum(petRead("i", UnitLevel, "pet"))
	local hp, hpMax = petHealth()
	local pt = petNum(petRead("p", UnitPowerType, "pet"))
	local pw, pwMax
	if pt then pw, pwMax = petNum(petRead("p", UnitPower, "pet", pt)), petNum(petRead("p", UnitPowerMax, "pet", pt)) end
	local happy, dmg = petRead("s", GetPetHappiness)
	local loyalty = petRead("s", GetPetLoyalty)
	loyalty = Str(loyalty) and tonumber(loyalty:match("%d+")) or nil
	local tpTotal, tpUsed = petRead("s", GetPetTrainingPoints)
	local base, eff = petRead("s", UnitArmor, "pet")
	sink = nil
	emit(GetTime(), "pet", why, npc, family, lvl, hp, hpMax, pt, pw, pwMax, petNum(happy), petNum(dmg), loyalty,
		petNum(tpTotal), petNum(tpUsed), petNum(eff) or petNum(base), flags(s))
end

-- UNIT_PET (and a session's start): a new pet, or the pet gone.
local function petChanged()
	if petExists() then
		local g = Str(petRead("i", UnitGUID, "pet"))
		if not petSeen or petSeen.dead or (g and g ~= petSeen.guid) then
			local _, npc = ns.ParseGUID(g)
			petSeen = { guid = g, npc = npc }
			petSnapshot("s")
			local p = pull
			if p and not p.hadPet then
				p.hadPet, p.petDied = true, "0"
				p.petHp0, p.petHpMax = petHealth()
				p.petHpMin = p.petHp0
			end
		end
	elseif petSeen then
		local p = pull
		if p and p.hadPet and p.petDied == "0" then p.petDied = "g" end
		emit(GetTime(), "pet", "g", petSeen.npc, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, "")
		petSeen = nil
	end
end

-- UNIT_HEALTH of the pet: its lowest in the pull, its death (health 0 or
-- UnitIsDead), and its revival.
local function petHealthChanged()
	if not petExists() then return end
	local cur, mx = petHealth()
	local p = pull
	if p and p.hadPet then
		low(p, "petHpMin", cur)
		if mx then p.petHpMax = mx end
	end
	local dead = petRead("i", UnitIsDead, "pet")
	if cur == 0 or dead == true then
		if petSeen and not petSeen.dead then
			petSeen.dead = true
			if p and p.hadPet then p.petDied = "1" end
			petSnapshot("d")
		end
	elseif cur and cur > 0 and petSeen and petSeen.dead then
		petSeen.dead = false
		petSnapshot("s")
	end
end

local function startPull()
	local now = GetTime()
	for res in pairs(agg) do flushRegen(res, now) end
	last.h.rise, last.m.rise = nil, nil
	if meal then endMeal(now) end
	local p = { t0 = now, secret = {}, casts = {}, items = {}, hits = {}, more = 0, selfx = 0, kills = 0, xp = 0 }
	pull = p
	p.level = level()
	p.pt = powerType()
	p.hp0, p.hpMax = health()
	p.pw0, p.pwMax = power(p.pt)
	p.hpMin, p.pwMin = p.hp0, p.pw0
	p.lastHp, p.lastHit = p.hp0, now
	p.armor = armor()
	scanAuras()
	p.absorb = absorbing
	if target and now - target.at <= TARGET_FRESH then p.target = target end
	p.gap = lastPullEnd and now - lastPullEnd or nil
	p.ate, p.restSec = mealsSince.flags, mealsSince.seconds
	mealsSince = { flags = "", seconds = 0 }
	if petExists() then
		p.hadPet, p.petDied = true, "0"
		p.petHp0, p.petHpMax = petHealth()
		p.petHpMin = p.petHp0
		petSnapshot("b")
	end
	countPlates()
	if C_Timer and C_Timer.NewTicker then plateTicker = C_Timer.NewTicker(PLATE_TICK, countPlates) end
end

local function list(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys)
	local out = {}
	for i = 1, math.min(#keys, CAST_CAP) do out[i] = format("%d:%d", keys[i], t[keys[i]]) end
	return #out > 0 and concat(out, ";") or nil
end

local function secretFlags(p) return flags(p.secret) end

local function writePull(p)
	local t = p.target or {}
	local mana = t.mana
	if mana ~= nil then mana = mana and 1 or 0 end
	local absorb = p.absorb
	if absorb ~= nil then absorb = absorb and 1 or 0 end
	emit(p.t1, "pull", floor((p.t1 - p.t0) * 10 + 0.5), p.level, p.hp0, p.hpMin, p.hp1, p.hpMax, p.pt, p.pw0, p.pwMin, p.pw1, p.pwMax,
		p.kills, p.xp, p.died and 1 or 0, t.npc, t.lvl, t.cls, t.ctype, mana, p.mobs, p.mobsHow, list(p.casts), list(p.items),
		p.gap and floor(p.gap + 0.5) or nil, p.ate, floor(p.restSec + 0.5), absorb, secretFlags(p),
		p.petHp0, p.petHpMin, p.petHp1, p.petHpMax, p.petDied)
	if #p.hits > 0 and (p.mobs == nil or p.mobs <= 1) then
		emit(p.t1, "hit", p.level, p.armor, absorb, p.mobs, t.npc, t.lvl, concat(p.hits, ";"), p.more, p.selfx)
	end
end

local function endPull()
	local p = pull
	if not p then return end
	pull = nil
	if plateTicker then
		plateTicker:Cancel()
		plateTicker = nil
	end
	local now = GetTime()
	p.t1 = now
	p.hp1 = health()
	p.pw1 = power(p.pt)
	low(p, "hpMin", p.hp1)
	low(p, "pwMin", p.pw1)
	if p.hadPet and petExists() then
		-- the pull is no longer running: its pet reads say `e` here
		local s = {}
		sink = s
		local hp1, mx = petHealth()
		sink = nil
		if s.h then p.secret.e = true end
		p.petHp1 = hp1
		if mx then p.petHpMax = mx end
		low(p, "petHpMin", hp1)
		petSnapshot("e")
	end
	lastPullEnd = now
	if unavailable.h == nil or unavailable.p == nil then probeUnavailable() end
	waiting[#waiting + 1] = p
	C_Timer.After(PULL_DELAY, function()
		for i = #waiting, 1, -1 do
			if waiting[i] == p then table.remove(waiting, i) end
		end
		writePull(p)
	end)
	-- the pool's state after combat starts the regen watch afresh
	last.h.v, last.h.max = health()
	last.m.v, last.m.max = power(0)
end

-- Finds.lua: every kill record written (at the time of the death), to the
-- running pull or one that ended within PULL_DELAY.
-- A kill flagged tapped (another player's tag) counts when it gave XP: a
-- tapped kill gives none, and the flag came out 1 on most kills that did in
-- the first real sessions (Finds.lua's CanLootUnit check).
function ns.SimKill(t, xp, tapped)
	local gained = Num(xp)
	if not on or type(t) ~= "number" or (tapped == true and not (gained and gained > 0)) then return end
	local p = pull
	if not (p and t >= p.t0 - KILL_SLACK) then
		p = nil
		for i = #waiting, 1, -1 do
			local w = waiting[i]
			if t >= w.t0 - KILL_SLACK and t <= w.t1 + KILL_SLACK then
				p = w
				break
			end
		end
	end
	if not p then return end
	p.kills = p.kills + 1
	p.xp = p.xp + (gained or 0)
end

-- World.lua: an item the player used (bags, action bars, quest items).
function ns.SimItem(id)
	local p = pull
	if not (on and p and Num(id)) then return end
	p.items[id] = (p.items[id] or 0) + 1
end

local selfDamageUntil = -math.huge

local function combatHealth()
	local p = pull
	local cur = health()
	if cur == nil then return end
	low(p, "hpMin", cur)
	local now = GetTime()
	if p.lastHp and cur < p.lastHp then
		if now <= selfDamageUntil then
			p.selfx = p.selfx + 1
		elseif #p.hits < HIT_CAP then
			p.hits[#p.hits + 1] = format("%d:%d", floor((now - p.lastHit) * 10 + 0.5), p.lastHp - cur)
			p.lastHit = now
		else
			p.more = p.more + 1
			p.lastHit = now
		end
	end
	p.lastHp = cur
end


---------------------------------------------------------------------------
-- Deaths: `simdeath`, the context taken at PLAYER_DEAD, written once the
-- player is alive again (or at logout while still dead).
---------------------------------------------------------------------------

local deathCtx = nil

local function lastLosses(hits)
	local from = math.max(1, #hits - LOSS_CAP + 1)
	local out = {}
	for i = from, #hits do out[#out + 1] = hits[i] end
	return #out > 0 and concat(out, ";") or nil
end

local function takeDeath()
	local now = GetTime()
	local p = pull
	if not p then
		local w = waiting[#waiting]
		if w and now - w.t1 <= DEATH_PULL_SLACK then p = w end
	end
	local s = {}
	sink = s
	local d = { at = now, level = level(), P = ns.P(), sub = placeName(GetSubZoneText and GetSubZoneText()) }
	if p then
		d.tenths = floor((now - p.t0) * 10 + 0.5)
		d.hp0, d.hpMax, d.pt, d.pw0, d.pwMax, d.mobs = p.hp0, p.hpMax, p.pt, p.pw0, p.pwMax, p.mobs
		local t = p.target or {}
		d.npc, d.npcLevel, d.cls, d.ctype = t.npc, t.lvl, t.cls, t.ctype
		if t.mana ~= nil then d.caster = t.mana and 1 or 0 end
		d.losses, d.items, d.casts = lastLosses(p.hits), list(p.items), list(p.casts)
		d.petDied = p.petDied
		for c in pairs(p.secret) do s[c] = true end
	else
		local _, mx = health()
		d.hpMax = mx
	end
	if petExists() then d.petHp, d.petHpMax = petHealth() end
	d.rested = round(Num(GetXPExhaustion and GetXPExhaustion()))
	d.restSince = lastMealEnd and floor(now - lastMealEnd + 0.5) or nil
	local okg, g = pcall(IsInGroup or function() end)
	if okg and usable(g) and g ~= nil then d.group = g and 1 or 0 end
	sink = nil
	d.secret = s
	deathCtx = d
end

-- Resurrection Sickness on the player: 1, 0, or nil when the debuffs are unreadable.
local function sickness()
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil end
	local name = Str(ns.SpellName(SICKNESS_SPELL))
	for i = 1, 40 do
		local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HARMFUL")
		if not ok or not a then break end
		if not usable(a) then return nil end
		local id, n = Num(a.spellId), Str(a.name)
		if id == nil and n == nil then return nil end
		if id == SICKNESS_SPELL or (name and n == name) then return 1 end
	end
	return 0
end

local function writeDeath(d, at, dead, how, sick)
	emit(at, "simdeath", d.level, d.P, d.sub, d.tenths, d.hp0, d.hpMax, d.pt, d.pw0, d.pwMax, d.mobs, d.npc, d.npcLevel, d.cls,
		d.ctype, d.caster, d.losses, d.items, d.casts, d.petHp, d.petHpMax, d.petDied, d.rested, d.restSince, d.group,
		dead, how, sick, flags(d.secret))
end

local function alive()
	local d = deathCtx
	if not d then return end
	local ok, ghost = pcall(UnitIsDeadOrGhost or function() end, "player")
	if ok and usable(ghost) and ghost then return end
	deathCtx = nil
	local now = GetTime()
	local dead, how = floor(now - d.at + 0.5), ns.ReviveHow
	C_Timer.After(SICKNESS_DELAY, function() writeDeath(d, now, dead, how, sickness()) end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function active() return on and ns.Recording() end

-- The local copy's own `ctx` line (never a chunk record: the chunk's
-- `session` says it): the character's race and class tokens and level, so
-- the copy reads without the chunks an upload deleted.
-- Its last field says once per session which of the player's health (`h`)
-- and power (`p`) are secret even out of combat, so not recorded this
-- session (empty: readable, or not known yet).
keepContext = function()
	local _, race = UnitRace("player")
	local _, class = UnitClass("player")
	probeUnavailable()
	keep(GetTime(), "ctx", Str(race), Str(class), level(), unavailableLetters())
end

ns.On("PLAYER_REGEN_DISABLED", function()
	if active() then startPull() end
end)

ns.On("PLAYER_REGEN_ENABLED", function()
	if active() then endPull() end
end)

ns.On("PLAYER_DEAD", function()
	if pull then pull.died = true end
	if active() then takeDeath() end
end)

ns.On("PLAYER_ALIVE", function()
	if active() then alive() end
end)

ns.On("PLAYER_UNGHOST", function()
	if active() then alive() end
end)

ns.On("UNIT_PET", function(_, unit)
	if unit == "player" and active() then petChanged() end
end)

ns.On("UNIT_HEALTH", function(_, unit)
	if unit == "pet" and active() then
		petHealthChanged()
		return
	end
	if unit ~= "player" or unavailable.h or not active() then return end
	if pull then
		combatHealth()
	else
		observe("h", health())
	end
end)

ns.On("UNIT_MAXHEALTH", function(_, unit)
	if unit ~= "player" or unavailable.h or not active() or pull then return end
	observe("h", health())
end)

ns.On("UNIT_POWER_FREQUENT", function(_, unit)
	if unit ~= "player" or unavailable.p or not active() then return end
	local p = pull
	if p then
		local cur = power(p.pt)
		low(p, "pwMin", cur)
		local mana = (p.pt == 0) and cur or power(0)
		if mana and last.m.v and mana < last.m.v then lastSpend = GetTime() end
		if mana then last.m.v = mana end
		return
	end
	observe("m", power(0))
end)

ns.On("UNIT_AURA", function(_, unit)
	if unit ~= "player" or not active() then return end
	scanAuras()
end)

ns.On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spell)
	if unit ~= "player" or not active() then return end
	local now = GetTime()
	lastCast = now
	local id = Num(spell)
	if spell ~= nil and id == nil then
		readable.c = false
		if pull then pull.secret.c = true end
	elseif id then
		readable.c = true
	end
	if spellKind(id) == "s" then selfDamageUntil = now + 0.5 end
	local p = pull
	if p then
		local k = id or 0
		p.casts[k] = (p.casts[k] or 0) + 1
	end
end)

ns.On("UNIT_SPELLCAST_CHANNEL_START", function(_, unit, _, spell)
	if unit ~= "player" or not active() then return end
	channeling = true
	if spellKind(Num(spell)) == "s" then selfDamageUntil = math.huge end
end)

ns.On("UNIT_SPELLCAST_CHANNEL_STOP", function(_, unit)
	if unit ~= "player" then return end
	channeling = false
	if selfDamageUntil == math.huge then selfDamageUntil = GetTime() + 0.5 end
end)

ns.On("PLAYER_TARGET_CHANGED", function()
	if active() then readTarget() end
end)

ns.On("NAME_PLATE_UNIT_ADDED", function(_, token)
	if Str(token) then plates[token] = true end
end)

ns.On("NAME_PLATE_UNIT_REMOVED", function(_, token)
	if Str(token) then plates[token] = nil end
end)

-- A new session: what was measured before the reload is not continued.
ns.OnSession(function()
	agg = {}
	last = { h = {}, m = {} }
	pull, meal, target, lastPullEnd, lastMealEnd, deathCtx, petSeen = nil, nil, nil, nil, nil, nil, nil
	mealsSince = { flags = "", seconds = 0 }
	hotUntil, lastSpend, lastCast, selfDamageUntil, channeling = -math.huge, -math.huge, -math.huge, -math.huge, false
	unavailable, keepFailed = {}, false
	if active() then
		probeUnavailable()
		last.h.v, last.h.max = health()
		last.m.v, last.m.max = power(0)
		scanAuras()
		keepContext()
		petChanged()
	end
end)

ns.OnLogout(function()
	-- the copy goes into the table the client saves now, whatever happened to
	-- the one it was put in before
	save()
	if not active() then return end
	local now = GetTime()
	for res in pairs(agg) do flushRegen(res, now) end
	if meal then endMeal(now) end
	-- still dead: the context without the revival
	if deathCtx then
		writeDeath(deathCtx, now, nil, nil, nil)
		deathCtx = nil
	end
end)

-- /psrec sim on: the pet as it is now.
function ns.SimPetNow()
	petSeen = nil
	petChanged()
end

-- What /psrec sim shows: each read now (true readable, false secret, nil
-- not tried or no API), and the letters of the last pull that were secret.
function ns.SimProbe()
	local was = pull
	pull = nil
	health()
	power(powerType() or 0)
	stat(5)
	armor()
	if UnitExists and usable(UnitExists("target")) and UnitExists("target") then call("t", UnitCreatureType, "target") end
	if petExists() then petHealth() end
	for token in pairs(plates) do
		num("n", UnitThreatSituation, "player", token)
		break
	end
	pull = was
	local out = {}
	for k, v in pairs(readable) do out[k] = v end
	return out
end
