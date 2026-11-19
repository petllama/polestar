//! Sim telemetry in the recorder (addon/Polestar_Recorder/Sim.lua, `/psrec sim`): out-of-combat
//! regeneration (`regen`), meals (`meal`), one record per combat (`pull`) and the health the player
//! lost to a single mob (`hit`), against tests/lua/stub_recorder.lua.

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
	assert_eq!(log.len(), 7);
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
		["kill|299|3|n|1429|5000|5000|45||0|", "pull|70|1|200|170|200|200|0|300|250|250|300|1|45|0|299|3|n|Beast|0|1|t|585:2||||0|0|", "hit|1|50|0|1|299|3|20:10;21:9;19:11|0|0",]
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
		["pull|30|1||150|150|200|0|300|300|300|300|0|0|0||||||||0:1||||0|0|hc", "meal|f|10|1|150|200|200|300|300|300", "pull|20|1|200|175|175|200|0|300|300|300|300|0|0|0||||||2|t|||20|f|10|0|",]
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
