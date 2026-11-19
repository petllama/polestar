//! Sim telemetry in the recorder (addon/Polestar_Recorder/Sim.lua, `/psrec sim`): out-of-combat
//! regeneration (`regen`), meals (`meal`), one record per combat (`pull`) and the health the player
//! lost to a single mob (`hit`), the character sheet (`char`, SimChar.lua), the pet (`pet`) and a death's
//! context (`simdeath`), against tests/lua/stub_recorder.lua.

use crate::recorder::{run, run_with, strings};
use forge_addontest::truthy;
use serde_json::json;

/// Recording on, sim telemetry on, spell names the client would give, a full player.
const SETUP: &str = r#"
local W = stub.world
W.spells[433], W.spells[430], W.spells[17], W.spells[139], W.spells[1454] = "Food", "Drink", "Power Word: Shield", "Renew", "Life Tap"
W.hp, W.hpMax = 200, 200
W.power[0], W.powerMax[0] = 300, 300
W.stats = { 20, 20, 22, 30, 25 }
cmd("on")
local function hp(v) W.hp = v; stub.fire("UNIT_HEALTH", "player") end
local function mana(v) W.power[0] = v; stub.fire("UNIT_POWER_FREQUENT", "player", "MANA") end
local function aura(list) W.auras = list; stub.fire("UNIT_AURA", "player", { isFullUpdate = true }) end
local function cast(spell) stub.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", spell) end
local function fight() W.combat = true; stub.fire("PLAYER_REGEN_DISABLED") end
local function calm() W.combat = false; stub.fire("PLAYER_REGEN_ENABLED") end
local function mob(token, id, name, lvl, threat)
	local g = stub.creature(id, name)
	stub.setUnit(token, g, name)
	local u = W.units[token]
	u.lvl, u.cls, u.ctype, u.ptype, u.threat, u.combat = lvl, "normal", "Beast", 1, threat, true
	return g
end
"#;

fn sim(script: &str) -> serde_json::Value {
	run(&format!("{SETUP}{script}"))
}

#[test]
fn nothing_is_recorded_until_sim_is_turned_on() {
	let out = sim(r#"
		hp(100)
		stub.advance(2)
		hp(106)
		fight()
		stub.advance(2)
		hp(90)
		calm()
		stub.advance(5)
		logout()
		emit({ recs = recs("regen meal pull hit"), log = #(PolestarRecorderDB.simlog or {}), on = PolestarRecorderDB.simOn == true })"#);
	assert_eq!(out["recs"], json!({}));
	assert_eq!(out["log"], 0);
	assert!(!truthy(&out["on"]));
}

#[test]
fn regen_is_aggregated_per_resource_and_state_and_a_meal_records_the_rest_thresholds() {
	let out = sim(r#"
		cmd("sim on")
		hp(50)
		mana(40)
		for _ = 1, 5 do
			stub.advance(2)
			hp(W.hp + 6)
			mana(W.power[0] + 10)
		end
		mana(W.power[0] - 30) -- a spell: the five-second rule starts
		stub.advance(2)
		mana(W.power[0] + 10)
		aura({ { auraInstanceID = 7, name = "Drink", spellId = 430, duration = 18, expirationTime = stub.now + 18 } })
		stub.advance(2)
		mana(W.power[0] + 50)
		stub.advance(1)
		aura({})
		-- a heal of the player's own: not natural regen
		cast(2050)
		stub.advance(1)
		hp(W.hp + 40)
		logout()
		emit({ recs = recs("regen meal rest"), bad = malformed(), log = PolestarRecorderDB.simlog })"#);
	let mut recs = strings(&out["recs"]);
	recs.sort();
	assert_eq!(
		recs,
		[
			"meal|d|3|1|80|80|200|70|120|300",
			"regen|h|h|1|25|30|200|1|40|40|40|60:1|0|",
			"regen|h|n|1|25|30|200|5|30|6|6|20:4|0|",
			"regen|m|5|1|25|30|300|1|10|10|10|20:1|0|0",
			"regen|m|e|1|25|30|300|1|50|50|50|20:1|0|0",
			"regen|m|n|1|25|30|300|5|50|10|10|20:4|0|0",
			"rest|d|3",
		]
	);
	assert_eq!(out["bad"], json!({}));
	// The local copy: kind, server epoch in tenths, the character id, then the same fields.
	let log = strings(&out["log"]);
	// the copy's own context line first: race and class tokens, level
	assert_eq!(log[0].split('\t').skip(3).collect::<Vec<_>>(), ["Human", "WARRIOR", "1"]);
	assert!(log[0].starts_with("ctx\t"));
	// the regen and meal lines, and the `char` snapshot /psrec sim on asked for
	assert_eq!(log.len(), 8);
	assert!(log.iter().any(|l| l.starts_with("char\t")));
	let meal = log.iter().find(|l| l.starts_with("meal\t")).unwrap();
	let f: Vec<&str> = meal.split('\t').collect();
	assert!(f[1].parse::<u64>().unwrap() > 17_910_000_000, "{meal}");
	assert_eq!(f[2].len(), 10);
	assert_eq!(f[3..].join("|"), "d|3|1|80|80|200|70|120|300");
}

#[test]
fn a_pull_against_one_mob_records_its_swings_kills_casts_and_target() {
	let out = sim(r#"
		cmd("sim on")
		local wolf = mob("target", 299, "Young Wolf", 3, nil)
		W.units.target.pmax = 0
		stub.fire("PLAYER_TARGET_CHANGED")
		stub.setUnit("nameplate1", wolf, "Young Wolf")
		W.units.nameplate1.threat, W.units.nameplate1.combat, W.units.nameplate1.lvl = 1, true, 3
		stub.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
		stub.advance(5)
		fight()
		cast(585)
		stub.advance(2)
		hp(190)
		stub.advance(2.1)
		hp(181)
		mana(250)
		stub.advance(1.9)
		hp(170)
		hp(200) -- a heal: no swing
		cast(585)
		stub.advance(1)
		stub.partyKill(wolf)
		stub.unitDied(wolf)
		stub.xpLine("Young Wolf", 45)
		calm()
		stub.advance(4)
		logout()
		emit({ recs = recs("pull hit kill"), bad = malformed() })"#);
	assert_eq!(
		strings(&out["recs"]),
		["kill|299|3|n|1429|5000|5000|45||0|", "pull|70|1|200|170|200|200|0|300|250|250|300|1|45|0|299|3|n|Beast|0|1|t|585:2||||0|0||||||", "hit|1|50|0|1|299|3|20:10;21:9;19:11|0|0",]
	);
	assert_eq!(out["bad"], json!({}));
}

#[test]
fn secret_values_leave_fields_empty_and_say_so_and_a_second_pull_counts_the_gap_and_the_meal() {
	let out = sim(r#"
		cmd("sim on")
		-- the client keeps health and the cast spell secret in this fight
		W.hp = stub.secret()
		fight()
		stub.fire("UNIT_HEALTH", "player")
		cast(stub.secret())
		stub.advance(3)
		W.hp = 150
		calm()
		stub.advance(4)
		-- eat, then a pull against two mobs: no `hit` (more than one mob)
		aura({ { auraInstanceID = 9, name = "Food", spellId = 433, duration = 21, expirationTime = stub.now + 21 } })
		stub.advance(10)
		hp(200)
		aura({})
		stub.advance(6)
		mob("nameplate1", 299, "Young Wolf", 3, 1)
		mob("nameplate2", 299, "Young Wolf", 3, 0)
		stub.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
		stub.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
		fight()
		stub.advance(1)
		hp(180)
		stub.advance(1)
		hp(175)
		calm()
		stub.advance(4)
		logout()
		emit({ recs = recs("pull hit meal"), bad = malformed() })"#);
	assert_eq!(
		strings(&out["recs"]),
		[
			"pull|30|1||150|150|200|0|300|300|300|300|0|0|0||||||||0:1||||0|0|hc|||||",
			"meal|f|10|1|150|200|200|300|300|300",
			"pull|20|1|200|175|175|200|0|300|300|300|300|0|0|0||||||2|t|||20|f|10|0||||||",
		]
	);
	assert_eq!(out["bad"], json!({}));
}

#[test]
fn the_setting_and_the_local_copy_survive_a_reload_and_clear_deletes_the_copy() {
	let saved = r#"
PolestarRecorderDB = { schema = 2, enabled = true, install = "k3j9x0q2m7ab", seq = 4, acked = 4, chunks = {}, maps = {},
	simOn = true, simlog = { "pull\t17910000000\tk3j9x0q2m7\t20" } }
PolestarRecorderCharDB = { id = "k3j9x0q2m7" }"#;
	let out = run_with(
		r#"
		local log = PolestarRecorderDB.simlog
		local before = { on = PolestarRecorderDB.simOn, n = #log, first = log[1], second = log[2]:match("^ctx\t") ~= nil }
		cmd("clear")
		cmd("clear confirm")
		emit({ before = before, after = #(PolestarRecorderDB.simlog or {}), on = PolestarRecorderDB.simOn })"#,
		"",
		true,
		Some(saved),
	);
	assert!(truthy(&out["before"]["on"]));
	// the saved line, then this session's context line
	assert_eq!(out["before"]["n"], 2);
	assert_eq!(out["before"]["first"], "pull\t17910000000\tk3j9x0q2m7\t20");
	assert!(truthy(&out["before"]["second"]));
	// cleared; the fresh session's context line only
	assert_eq!(out["after"], 1);
	assert!(truthy(&out["on"]), "clearing keeps the setting");
}

/// The character sheet the stub gives, with talents and two items.
const SHEET: &str = r#"
W.talents = {
	configID = 7, treeIDs = { 500 },
	nodes = {
		[101] = { ID = 101, ranksPurchased = 3, activeEntry = { entryID = 11 } },
		[102] = { ID = 102, ranksPurchased = 0, entryIDs = { 12 } },
		[103] = { ID = 103, activeRank = 1, entryIDs = { 13 } },
	},
	entries = { [11] = { definitionID = 21 }, [12] = { definitionID = 22 }, [13] = { definitionID = 23 } },
	defs = { [21] = { spellID = 14520 }, [22] = { spellID = 14521 }, [23] = {} },
}
W.inventory[1] = "|cff1eff00|Hitem:7046:0:0:0|h[Azure Silk Hood]|h|r"
W.inventory[16] = "|cffffffff|Hitem:2208:241:0|h[Poniard]|h|r"
W.statsBase = { 18, 19, 20, 21, 22 }
W.sheet.sp = { [2] = 5, [6] = 12 }
W.sheet.spellCrit = { [2] = 1.5, [6] = 2.25 }
W.regen.mana = 1.234
"#;

#[test]
fn char_is_written_at_sim_on_level_up_talents_and_settled_gear_out_of_combat_and_only_when_it_changed() {
	let out = sim(&format!(
		"{SHEET}{}",
		r#"
		cmd("sim on")
		stub.advance(2)
		-- a level up in a fight: written once out of combat
		fight()
		W.level, W.hpMax = 2, 220
		stub.fire("PLAYER_LEVEL_UP", 2)
		stub.advance(5)
		local function nchar()
			local n = 0
			for _, l in ipairs(PolestarRecorderDB.simlog or {}) do
				if l:match("^char\t") then n = n + 1 end
			end
			return n
		end
		local inFight = nchar()
		calm()
		stub.advance(4)
		-- a talent point; then a talent event that changed nothing
		W.talents.nodes[102].ranksPurchased = 1
		stub.fire("CHARACTER_POINTS_CHANGED", -1)
		stub.advance(4)
		stub.fire("PLAYER_TALENT_UPDATE")
		stub.advance(4)
		-- equipment: settles 10 s, then at most once in 3 minutes
		W.inventory[5] = "|cff1eff00|Hitem:6:0|h[Robe]|h|r"
		stub.fire("PLAYER_EQUIPMENT_CHANGED", 5, false)
		stub.advance(11)
		W.inventory[6] = "|cff1eff00|Hitem:7:0|h[Belt]|h|r"
		stub.fire("PLAYER_EQUIPMENT_CHANGED", 6, false)
		stub.advance(60)
		local limited = nchar()
		stub.advance(120)
		-- a value the client keeps secret: empty, and said
		W.sheet.crit = stub.secret()
		stub.fire("PLAYER_LEVEL_UP", 2)
		stub.advance(4)
		logout()
		emit({ recs = recs("char"), bad = malformed(), inFight = inFight, limited = limited })"#
	));
	assert_eq!(out["bad"], json!({}));
	assert_eq!(out["inFight"], 1, "the level up waits for the fight's end");
	assert_eq!(out["limited"], 4, "the second equipment change waits for the 3 minutes");
	let recs = strings(&out["recs"]);
	let stats = "18:20;19:20;20:22;21:30;22:25";
	let tail = "0|525|450|2:150;3:0;4:0;5:0;6:225;7:0|0|0|410|500|0|123|0|0|1050|1825|260|||||||";
	assert_eq!(
		recs,
		[
			format!("char|1|WARRIOR|Human|{stats}|200|300|50|45|30|2:5;3:0;4:0;5:0;6:12;7:0|{tail}1:7046:;16:2208:241|101:3:14520;103:1:|o|"),
			format!("char|2|WARRIOR|Human|{stats}|220|300|50|45|30|2:5;3:0;4:0;5:0;6:12;7:0|{tail}1:7046:;16:2208:241|101:3:14520;103:1:|l|"),
			format!("char|2|WARRIOR|Human|{stats}|220|300|50|45|30|2:5;3:0;4:0;5:0;6:12;7:0|{tail}1:7046:;16:2208:241|101:3:14520;102:1:14521;103:1:|t|"),
			format!("char|2|WARRIOR|Human|{stats}|220|300|50|45|30|2:5;3:0;4:0;5:0;6:12;7:0|{tail}1:7046:;5:6:;16:2208:241|101:3:14520;102:1:14521;103:1:|g|"),
			format!("char|2|WARRIOR|Human|{stats}|220|300|50|45|30|2:5;3:0;4:0;5:0;6:12;7:0|{tail}1:7046:;5:6:;6:7:;16:2208:241|101:3:14520;102:1:14521;103:1:|g|"),
			format!("char|2|WARRIOR|Human|{stats}|220|300|50|45|30|2:5;3:0;4:0;5:0;6:12;7:0|{}1:7046:;5:6:;6:7:;16:2208:241|101:3:14520;102:1:14521;103:1:|l|s", tail.replacen("0|525|", "0||", 1)),
		]
	);
}

/// A warlock's Imp: summoned, then a pull in which it dies.
const IMP: &str = r#"
local function imp(hp)
	stub.setUnit("pet", "Pet-0-4372-0-12-416-00000A0001", "Imp")
	local u = W.units.pet
	u.lvl, u.hp, u.hpMax, u.ptype, u.pw, u.pmax, u.family, u.armor = 12, hp, 200, 0, 300, 300, "Imp", 60
	stub.fire("UNIT_PET", "player")
end
"#;

#[test]
fn the_pet_is_snapshot_on_summon_pull_start_and_death_and_the_pull_keeps_its_health() {
	let out = sim(&format!(
		"{IMP}{}",
		r#"
		cmd("sim on")
		imp(180)
		stub.advance(2)
		fight()
		stub.advance(1)
		W.units.pet.hp = 120
		stub.fire("UNIT_HEALTH", "pet")
		stub.advance(1)
		W.units.pet.hp, W.units.pet.dead = 0, true
		stub.fire("UNIT_HEALTH", "pet")
		stub.setUnit("pet", nil)
		stub.fire("UNIT_PET", "player")
		calm()
		stub.advance(4)
		-- summoned again; a pull it lives through
		imp(200)
		fight()
		stub.advance(1)
		W.units.pet.hp = 150
		stub.fire("UNIT_HEALTH", "pet")
		W.units.pet.hp = stub.secret() -- secret at the pull's end
		calm()
		stub.advance(4)
		-- a hunter's pet: happiness, loyalty and training points
		W.pet = { happiness = 3, damage = 125, loyalty = "Loyalty Level 4", tpTotal = 120, tpUsed = 40 }
		stub.setUnit("pet", "Pet-0-4372-0-12-1131-00000A0002", "Wolf")
		local u = W.units.pet
		u.lvl, u.hp, u.hpMax, u.ptype, u.pw, u.pmax, u.family, u.armor = 11, 300, 300, 2, 100, 100, "Wolf", 400
		stub.fire("UNIT_PET", "player")
		logout()
		emit({ recs = recs("pet pull"), bad = malformed() })"#
	));
	assert_eq!(out["bad"], json!({}));
	assert_eq!(
		strings(&out["recs"]),
		[
			"pet|s|416|Imp|12|180|200|0|300|300||||0|0|60|",
			"pet|b|416|Imp|12|180|200|0|300|300||||0|0|60|",
			"pet|d|416|Imp|12|0|200|0|300|300||||0|0|60|",
			"pet|g|416||||||||||||||",
			"pull|20|1|200|200|200|200|0|300|300|300|300|0|0|0||||||||||||0|0||180|0||200|1",
			"pet|s|416|Imp|12|200|200|0|300|300||||0|0|60|",
			"pet|b|416|Imp|12|200|200|0|300|300||||0|0|60|",
			"pet|e|416|Imp|12||200|0|300|300||||0|0|60|h",
			"pull|10|1|200|200|200|200|0|300|300|300|300|0|0|0||||||||||4||0|0|e|200|150||200|0",
			"pet|s|1131|Wolf|11|300|300|2|100|100|3|125|4|120|40|400|",
		]
	);
}

#[test]
fn a_death_writes_its_context_once_alive_with_the_time_and_how_and_resurrection_sickness() {
	let out = sim(&format!(
		"{IMP}{}",
		r#"
		cmd("sim on")
		W.spells[15007] = "Resurrection Sickness"
		imp(200)
		local wolf = mob("target", 299, "Young Wolf", 3, nil)
		W.units.target.pmax = 0
		stub.fire("PLAYER_TARGET_CHANGED")
		stub.advance(2)
		fight()
		cast(585)
		for _, v in ipairs({ 180, 160, 130, 100, 70, 40, 10 }) do
			stub.advance(2)
			hp(v)
		end
		stub.advance(1)
		hp(0)
		W.dead = true
		stub.fire("PLAYER_DEAD")
		calm()
		stub.advance(4)
		-- released: a ghost (not alive yet)
		W.ghost = true
		stub.fire("PLAYER_ALIVE")
		stub.advance(60)
		local asGhost = #recs("simdeath")
		-- the spirit healer
		stub.fire("CONFIRM_XP_LOSS")
		W.dead, W.ghost = false, false
		W.hp = 100
		W.debuffs = { { name = "Resurrection Sickness", spellId = 15007, duration = 600 } }
		stub.fire("PLAYER_UNGHOST")
		stub.advance(2)
		-- a second death, out of combat, still dead at logout
		W.debuffs = {}
		W.dead = true
		stub.fire("PLAYER_DEAD")
		stub.advance(3)
		logout()
		emit({ recs = recs("simdeath revive"), bad = malformed(), asGhost = asGhost })"#
	));
	assert_eq!(out["bad"], json!({}));
	assert_eq!(out["asGhost"], 0);
	assert_eq!(
		strings(&out["recs"]),
		[
			"revive|1429|5000|5000|s",
			"simdeath|1|1429|5000|5000|Northshire Valley|150|200|200|0|300|300||299|3|n|Beast|0|20:30;20:30;20:30;20:30;10:10||585:1|200|200|0|||0|64|s|1|",
			// out of combat: no pull, the maximum health only; still dead at logout
			"simdeath|1|1429|5000|5000|Northshire Valley|||200|||||||||||||200|200||||0||||",
		]
	);
}
