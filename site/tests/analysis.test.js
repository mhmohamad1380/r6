// The website's analyses (public/analysis.js) on hand-built rounds. Run: node --test site/tests
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const ctx = { window: {} };
vm.runInNewContext(fs.readFileSync(path.join(__dirname, "..", "public", "analysis.js"), "utf8"), ctx);
const A = ctx.window.R6A;

const US = ["me", "a1", "a2", "a3", "a4"], THEM = ["e1", "e2", "e3", "e4", "e5"];
let n = 0;
/** A round: kills as [killer, victim, seconds left], "plant" for a plant by me. */
function round({ match = "m1", number = 0, won = true, attack = true, kills = [], at = Date.UTC(2026, 10, 1, 20, 0, 0), map = "Map(407987100456)" }) {
  n++;
  const feedback = kills.map((k) => (k === "plant" ? { type: { name: "DefuserPlantComplete" }, username: "me", timeInSeconds: 40 } : { type: { name: "Kill" }, username: k[0], target: k[1], headshot: !!k[3], timeInSeconds: k[2] }));
  return A.normalize({
    header: {
      matchID: match, roundNumber: number, timestamp: new Date(at).toISOString(), map, matchType: "Ranked", site: "1F Lobby",
      teams: [{ role: attack ? "Attack" : "Defense", won }, { role: attack ? "Defense" : "Attack", won: !won }],
      players: [...US.map((u) => ({ username: u, teamIndex: 0, operator: { name: "Ash" } })), ...THEM.map((u) => ({ username: u, teamIndex: 1, operator: { name: "Jager" } }))],
    },
    matchFeedback: feedback,
  });
}
const mine = (rounds) => rounds.map((r) => A.analyzeRound(r, "me"));

test("timing puts kills and deaths in 30-second slices and the post-plant slice", () => {
  const rs = [round({ kills: [["me", "e1", 170], ["me", "e2", 150], ["e3", "a1", 31], ["me", "e4", 1], "plant", ["e5", "me", 20]] })];
  const t = A.timing(mine(rs));
  assert.deepEqual([...t.kills], [1, 1, 0, 0, 0, 1, 0]);
  assert.deepEqual([...t.deaths], [0, 0, 0, 0, 0, 0, 1]);
  assert.equal(t.rounds, 1);
});

test("kills per round counts 0 to 5", () => {
  const rs = [round({ kills: [] }), round({ kills: [["me", "e1", 100], ["me", "e2", 90]] }), round({ kills: THEM.map((e, i) => ["me", e, 150 - i]) })];
  assert.deepEqual([...A.killsPerRound(mine(rs))], [1, 0, 1, 0, 0, 1]);
});

test("the first kill: who got it and how the round went", () => {
  const rs = [
    round({ won: true, kills: [["a1", "e1", 160]] }),
    round({ won: false, kills: [["e1", "a2", 160]] }),
    round({ won: false, kills: [["e1", "me", 160]] }),
    round({ won: true, kills: [["me", "e1", 160]] }),
  ];
  const o = A.openingImpact(mine(rs));
  assert.equal(o.teamFirst.rounds, 2); assert.equal(o.teamFirst.wins, 2);
  assert.equal(o.teamFirstDeath.rounds, 2); assert.equal(o.teamFirstDeath.wins, 0);
  assert.equal(o.youFirst.rounds, 1); assert.equal(o.youFirstDeath.rounds, 1);
});

test("a clutch is counted once, against the enemies alive when it started", () => {
  const lastAlive = [["e1", "a1", 150], ["e1", "a2", 140], ["e2", "a3", 130], ["e1", "a4", 120]];   // 1 v 5
  const rs = [
    round({ won: true, kills: [["me", "e5", 170], ...lastAlive, ["me", "e1", 60], ["me", "e2", 50], ["me", "e3", 40], ["me", "e4", 30]] }),   // 1v4 won
    round({ won: false, kills: [...lastAlive, ["e3", "me", 100]] }),   // 1v5 lost
    round({ won: false, kills: [["e1", "me", 170]] }),   // died first: no clutch
  ];
  const c = A.clutches(mine(rs));
  assert.equal(c.rounds, 2); assert.equal(c.wins, 1);
  assert.equal(c.vs[3].rounds, 1); assert.equal(c.vs[3].wins, 1);
  assert.equal(c.vs[4].rounds, 1); assert.equal(c.vs[4].wins, 0);
});

test("sessions split at a 90-minute break and count the nth match", () => {
  const H = 3600 * 1000, t0 = Date.UTC(2026, 10, 1, 18);
  const rs = [
    round({ match: "a", at: t0 }), round({ match: "a", number: 1, at: t0 + 0.5 * H }),
    round({ match: "b", at: t0 + 1 * H }),
    round({ match: "c", at: t0 + 4 * H }),
  ];
  const matches = A.groupMatches(rs).map((m) => A.matchView(m, "me"));
  const s = A.sessions(matches);
  assert.equal(s.count, 2);
  assert.equal(s.nth[0].matches, 2); assert.equal(s.nth[1].matches, 1);
  assert.equal(s.avgMatches, 1.5);
});

test("rolling average and the per-match series run oldest first", () => {
  assert.deepEqual([...A.rolling([1, null, 3, 5], 2)], [1, 1, 3, 4]);
  const rs = [round({ match: "new", at: Date.UTC(2026, 10, 2) }), round({ match: "old", at: Date.UTC(2026, 10, 1), won: false })];
  const series = A.matchSeries(A.groupMatches(rs).map((m) => A.matchView(m, "me")));
  assert.deepEqual([...series.map((x) => x.id)], ["old", "new"]);
  assert.equal(series[0].winRate, 0);
});

test("findings need enough rounds and name a real side gap", () => {
  assert.equal(A.findings(mine([round({})]), []).length, 0);
  const rs = [];
  for (let i = 0; i < 12; i++) rs.push(round({ match: "m" + i, attack: true, won: i < 10 }), round({ match: "m" + i, number: 1, attack: false, won: i < 3 }));
  const matches = A.groupMatches(rs).map((m) => A.matchView(m, "me"));
  const f = A.findings(mine(rs), matches);
  const side = f.find((x) => x.title === "Stronger on attack");
  assert.ok(side, JSON.stringify(f));
  assert.match(side.text, /83% of rounds won on attack, 25% on defense/);
});

test("real replay fixtures go through every analysis without errors", () => {
  const dir = path.join(__dirname, "..", "..", "mobile", "test", "fixtures", "replays", "trimmed");
  const rs = fs.readdirSync(dir).map((f) => A.normalize(JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")))).filter(Boolean);
  assert.ok(rs.length >= 5);
  const me = rs[0].players[0].name;
  const all = rs.map((r) => A.analyzeRound(r, me));
  const matches = A.groupMatches(rs).map((m) => A.matchView(m, me));
  A.timing(all); A.killsPerRound(all); A.openingImpact(all); A.clutches(all); A.byDaypart(matches); A.sessions(matches); A.findings(all, matches); A.matchSeries(matches);
});
