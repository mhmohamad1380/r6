"use strict";

/* The same reading of a replay as the Android app (analytics/replay_stats.dart, identity.dart, data/replay.dart).
   Pure functions: rounds in, numbers out. Nothing here touches the page. */
(() => {
  const IDS = {
    "355496559878": "Bank", "413779563590": "Bank", "2697268122": "Bartlett University", "305979357167": "Border", "407987100456": "Border",
    "259816839773": "Chalet", "407558616688": "Chalet", "837214085": "Clubhouse", "407193663917": "Clubhouse", "42090092951": "Coastline",
    "2609221242": "Consulate", "379218689149": "Consulate", "418126004176": "Consulate", "365284490964": "Emerald Plains", "329867321446": "Favela",
    "126196841359": "Fortress", "127951053400": "Hereford Base", "237873412352": "House", "1378191338": "Kafe Dostoyevsky", "413845419788": "Kafe Dostoyevsky",
    "1460220617": "Kanal", "388073319671": "Lair", "417890697769": "Lair", "378595635123": "Nighthaven Labs", "418119057546": "Nighthaven Labs",
    "231702797556": "Oregon", "362605108559": "Outback", "2609218856": "Presidential Plane", "276279025182": "Skyscraper", "405306299908": "Stadium",
    "270063334510": "Stadium Bravo", "199824623654": "Theme Park", "53627213396": "Tower", "88107330328": "Villa", "1767965020": "Yacht",
    // identified from their bombsite and spawn names in real replays
    "398899676157": "Fortress", "409325881472": "Villa", "430788891316": "Theme Park", "434715462383": "Oregon", "436375283234": "Coastline", "441408792952": "Kanal", "441825219764": "Outback",
  };
  const DISPLAY = ["Bank", "Border", "Calypso Casino", "Chalet", "Close Quarter", "Clubhouse", "Coastline", "Consulate", "District", "Emerald Plains", "Favela", "Fortress",
    "Hereford Base", "House", "Kafe Dostoyevsky", "Kanal", "Lair", "Nighthaven Labs", "Oregon", "Outback", "Presidential Plane", "Skyscraper",
    "Stadium Alpha", "Stadium Bravo", "Theme Park", "Tower", "Villa", "Yacht"];
  const key = (s) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
  const BY_KEY = Object.fromEntries(DISPLAY.map((n) => [key(n), n]));

  /** "Map(407987100456)" -> Border, "BorderY10" -> Border. An id newer than the table shows as "Unknown map" with its last digits. */
  function mapName(raw) {
    const s = String(raw).trim();
    const m = /^Map\((\d+)\)$/.exec(s);
    const id = m ? m[1] : /^\d{6,}$/.test(s) ? s : null;
    if (id) return IDS[id] || "Unknown map " + (id.length > 4 ? id.slice(-4) : id);
    const base = s.replace(/(Y\d+|2020)$/, "");
    return BY_KEY[key(base)] || base.replace(/(?<=[a-z0-9])(?=[A-Z])/g, " ");
  }

  const text = (v) => (v == null ? null : typeof v === "object" ? text(v.name) : String(v));
  const num = (v) => (typeof v === "number" ? Math.trunc(v) : typeof v === "string" && /^-?\d+$/.test(v) ? parseInt(v, 10) : null);
  const same = (a, b) => a != null && b != null && String(a).trim().toLowerCase() === String(b).trim().toLowerCase();
  const KEEP = new Set(["Kill", "LocateObjective", "OperatorSwap", "PlayerLeave", "Other"]);
  const keep = (t) => KEEP.has(t) || t.includes("Plant") || t.includes("Disable") || t.includes("Defus");

  /** One stored round (the server's trimmed r6-dissect JSON) as the app reads it; null when it has no id or map. */
  function normalize(d, uploadedAt) {
    const h = d.header || d;
    const id = text(h.matchID), rawMap = text(h.map);
    if (!id || !rawMap) return null;
    const events = [];
    let planted = false, defused = false;
    for (const e of d.matchFeedback || h.matchFeedback || []) {
      const type = text(e.type) || "Other";
      if (!keep(type)) continue;
      const ev = { type, actor: e.username || null, target: e.target || null, headshot: e.headshot === true, remaining: num(e.timeInSeconds), operator: text(e.operator), message: e.message || null };
      ev.kill = type === "Kill";
      ev.plant = type.includes("Plant") && type.includes("Complete");
      ev.defuse = type.includes("Disable") && type.includes("Complete");   // DefuserDisableComplete; "DefuserPlantComplete" is a plant
      planted ||= ev.plant;
      defused ||= ev.defuse;
      events.push(ev);
    }
    const teams = (h.teams || []).map((t) => ({ role: text(t.role) || "", score: num(t.score) ?? 0, won: t.won === true, attack: (text(t.role) || "").toLowerCase().startsWith("att"), condition: t.winCondition || null }));
    const kills = events.filter((e) => e.kill);
    return {
      matchId: id, number: num(h.roundNumber) ?? 1, at: Date.parse(text(h.timestamp) || "") || Date.parse(uploadedAt || "") || null,
      map: mapName(rawMap), matchType: text(h.matchType) || "Unknown", mode: text(h.gamemode), site: h.site || null,
      teams, planted, defused, recorder: text(h.recordingProfileID),
      players: (h.players || []).map((p) => ({ name: p.username || "", team: num(p.teamIndex) ?? 0, operator: text(p.operator), profileId: p.profileID || null })),
      events, timed: kills.length > 0 && kills.every((e) => e.remaining != null),
    };
  }

  /** Who the replays belong to: the profile that recorded them, or else the one name in nearly every round of several matches. */
  function detectPlayer(rounds) {
    if (!rounds.length) return null;
    const byProfile = {};
    for (const r of rounds) if (r.recorder) byProfile[r.recorder] = (byProfile[r.recorder] || 0) + 1;
    const profiles = Object.entries(byProfile);
    if (profiles.length) {
      const top = profiles.reduce((a, b) => (b[1] > a[1] ? b : a))[0];
      const mine = rounds.filter((r) => r.recorder === top).sort((a, b) => (b.at || 0) - (a.at || 0));
      for (const r of mine) for (const p of r.players) if (p.profileId === top && p.name) return { name: p.name, how: "recorded", rounds: byProfile[top] };
    }
    if (new Set(rounds.map((r) => r.matchId)).size < 2) return null;
    const count = {};
    for (const r of rounds) for (const n of new Set(r.players.map((p) => p.name))) count[n] = (count[n] || 0) + 1;
    const sorted = Object.entries(count).sort((a, b) => b[1] - a[1]);
    if (!sorted.length || sorted[0][1] / rounds.length < 0.9) return null;
    if (sorted.length > 1 && sorted[1][1] / rounds.length >= 0.8) return null;
    return { name: sorted[0][0], how: "common", rounds: sorted[0][1] };
  }

  /** How one player's round went. KOST: a Kill, an Objective play, Survival or being Traded. */
  function analyzeRound(r, me) {
    const player = r.players.find((p) => same(p.name, me)) || null;
    const out = { round: r, name: me, player, present: player != null, kills: 0, headshots: 0, teamKills: 0, died: false, left: false, opening: "none", objective: false, traded: null, avenged: false };
    if (!player) return out;
    const teamOf = (n) => { const p = r.players.find((q) => same(q.name, n)); return p ? p.team : null; };
    const friendly = (e) => teamOf(e.actor) != null && teamOf(e.actor) === teamOf(e.target);
    const kills = r.events.filter((e) => e.kill);
    let deathIdx = null;
    kills.forEach((e, i) => {
      if (same(e.actor, me)) {
        if (friendly(e)) out.teamKills++;
        else { out.kills++; if (e.headshot) out.headshots++; }
      }
      if (same(e.target, me) && !out.died) { out.died = true; deathIdx = i; }
    });
    for (const e of kills) {
      if (friendly(e)) continue;
      if (same(e.actor, me)) out.opening = "kill";
      if (same(e.target, me)) out.opening = "death";
      break;
    }
    let traded = false;
    if (out.died && deathIdx != null) {
      const killer = kills[deathIdx].actor, at = kills[deathIdx].remaining;
      for (let j = deathIdx + 1; j < kills.length; j++) {
        const e = kills[j];
        if (same(e.target, killer) && teamOf(e.actor) === player.team && !same(e.actor, me)) {
          out.avenged = true;
          if (at != null && e.remaining != null && at - e.remaining <= 5) traded = true;
        }
      }
    }
    out.left = r.events.some((e) => e.type === "PlayerLeave" && same(e.actor, me));
    out.objective = r.events.some((e) => (e.plant || e.defuse) && same(e.actor, me));
    out.traded = r.timed ? (out.died ? traded : false) : null;
    out.team = player.team < r.teams.length ? r.teams[player.team] : null;
    out.attack = out.team ? out.team.attack : false;
    out.won = out.team ? out.team.won : null;
    out.survived = !out.died && !out.left;
    out.kost = out.kills > 0 || out.objective || out.survived || out.traded === true;
    return out;
  }

  const ratio = (a, b) => (b === 0 ? null : a / b);

  function summarize(all) {
    const rs = all.filter((r) => r.present);
    const n = (f) => rs.filter(f).length;
    const s = {
      rounds: rs.length, wins: n((r) => r.won === true), kills: rs.reduce((a, r) => a + r.kills, 0), headshots: rs.reduce((a, r) => a + r.headshots, 0),
      deaths: n((r) => r.died), openingKills: n((r) => r.opening === "kill"), openingDeaths: n((r) => r.opening === "death"), kostRounds: n((r) => r.kost),
      survivedRounds: n((r) => r.survived), avengedDeaths: n((r) => r.died && r.avenged), tradedDeaths: n((r) => r.died && r.traded === true),
      allTimed: rs.every((r) => r.round.timed),
    };
    s.losses = s.rounds - s.wins;
    s.kost = ratio(s.kostRounds, s.rounds);
    s.survival = ratio(s.survivedRounds, s.rounds);
    s.kd = ratio(s.kills, s.deaths);
    s.headshotRate = ratio(s.headshots, s.kills);
    s.openingRate = ratio(s.openingKills, s.openingKills + s.openingDeaths);
    s.winRate = ratio(s.wins, s.rounds);
    s.kostIsLowerBound = !s.allTimed;
    return s;
  }

  /** Round results by map, bombsite and side. */
  function siteStats(all) {
    const acc = new Map();
    for (const r of all) {
      if (!r.present || !r.round.site || r.won == null) continue;
      const k = [r.round.map, r.round.site, r.attack].join("|");
      const a = acc.get(k) || { map: r.round.map, site: r.round.site, attack: r.attack, rounds: 0, wins: 0 };
      a.rounds++;
      if (r.won) a.wins++;
      acc.set(k, a);
    }
    return [...acc.values()].sort((a, b) => b.rounds - a.rounds);
  }

  /** Groups of my rounds under any label (map, operator, side). */
  function groupBy(all, label) {
    const acc = new Map();
    for (const r of all) {
      if (!r.present) continue;
      const k = label(r);
      if (!k) continue;
      (acc.get(k) || acc.set(k, []).get(k)).push(r);
    }
    return [...acc.entries()].map(([name, list]) => ({ name, ...summarize(list), matches: new Set(list.map((r) => r.round.matchId)).size })).sort((a, b) => b.rounds - a.rounds);
  }

  /** Everyone's totals across a match's rounds, with the rules used for the player. */
  function leaderboard(rounds) {
    const names = new Map();
    for (const r of rounds) for (const p of r.players) if (!names.has(p.name)) names.set(p.name, p.team);
    return [...names.entries()].map(([name, team]) => ({ name, team, ...summarize(rounds.map((r) => analyzeRound(r, name))) })).sort((a, b) => b.kills - a.kills);
  }

  /** Rounds grouped by match, rounds in order, newest match first. */
  function groupMatches(rounds) {
    const by = new Map();
    for (const r of rounds) (by.get(r.matchId) || by.set(r.matchId, []).get(r.matchId)).push(r);
    const out = [...by.values()].map((l) => l.sort((a, b) => a.number - b.number));
    return out.sort((a, b) => (b[0].at || 0) - (a[0].at || 0));
  }

  /** The match as the player saw it: rounds won against lost. Equal means it has no clear result (a draw or a partial recording). */
  function matchView(rounds, me) {
    const mine = rounds.map((r) => analyzeRound(r, me));
    const present = mine.filter((m) => m.present);
    const wins = present.filter((m) => m.won === true).length, losses = present.filter((m) => m.won === false).length;
    return { rounds, mine, sum: summarize(mine), wins, losses, won: wins === losses ? null : wins > losses, first: rounds[0] };
  }

  /* ---------- trends and deeper analyses (the charts on the website) ---------- */

  const rate = (wins, rounds) => ({ rounds, wins, rate: rounds ? wins / rounds : null });

  /** One point per match, oldest first: what the form chart draws. */
  function matchSeries(matches) {
    return matches.filter((m) => m.sum.rounds > 0).sort((a, b) => (a.first.at || 0) - (b.first.at || 0)).map((m) => ({
      id: m.first.matchId, at: m.first.at, map: m.first.map, won: m.won, wins: m.wins, losses: m.losses,
      kost: m.sum.kost, kd: m.sum.kd, winRate: m.sum.winRate, headshotRate: m.sum.headshotRate, kills: m.sum.kills, deaths: m.sum.deaths, rounds: m.sum.rounds,
    }));
  }

  /** The average of the last n values at each point (nulls skipped). */
  function rolling(values, n) {
    return values.map((_, i) => {
      const w = values.slice(Math.max(0, i - n + 1), i + 1).filter((v) => v != null);
      return w.length ? w.reduce((a, b) => a + b, 0) / w.length : null;
    });
  }

  /** When in the round the player kills and dies: 30-second slices of the round clock, and a slice after the plant
      (the clock then shows the defuser timer). Only rounds with kill times count. */
  const TIMING = ["3:00–2:31", "2:30–2:01", "2:00–1:31", "1:30–1:01", "1:00–0:31", "0:30–0:00", "After plant"];
  function timing(all) {
    const kills = TIMING.map(() => 0), deaths = TIMING.map(() => 0);
    let rounds = 0;
    for (const x of all) {
      if (!x.present || !x.round.timed) continue;
      rounds++;
      let planted = false;
      const teamOf = (n) => { const p = x.round.players.find((q) => same(q.name, n)); return p ? p.team : null; };
      for (const e of x.round.events) {
        if (e.plant) planted = true;
        if (!e.kill || e.remaining == null) continue;
        const slot = planted ? 6 : Math.min(5, Math.max(0, Math.floor((180 - Math.min(e.remaining, 180)) / 30)));
        if (same(e.actor, x.name) && teamOf(e.target) !== teamOf(e.actor)) kills[slot]++;
        if (same(e.target, x.name)) deaths[slot]++;
      }
    }
    return { labels: TIMING, kills, deaths, rounds };
  }

  /** How many rounds had 0, 1, 2, 3, 4 and 5 kills. */
  function killsPerRound(all) {
    const counts = [0, 0, 0, 0, 0, 0];
    for (const x of all) if (x.present) counts[Math.min(5, x.kills)]++;
    return counts;
  }

  /** Round wins after the round's first kill: when the player's team got it, and when the team lost it. */
  function openingImpact(all) {
    const out = { teamFirst: rate(0, 0), teamFirstDeath: rate(0, 0), youFirst: rate(0, 0), youFirstDeath: rate(0, 0) };
    const add = (k, won) => { out[k].rounds++; if (won) out[k].wins++; out[k].rate = out[k].wins / out[k].rounds; };
    for (const x of all) {
      if (!x.present || x.won == null) continue;
      const teamOf = (n) => { const p = x.round.players.find((q) => same(q.name, n)); return p ? p.team : null; };
      const first = x.round.events.find((e) => e.kill && teamOf(e.actor) != null && teamOf(e.actor) !== teamOf(e.target));
      if (!first) continue;
      add(teamOf(first.actor) === x.player.team ? "teamFirst" : "teamFirstDeath", x.won);
      if (x.opening === "kill") add("youFirst", x.won);
      if (x.opening === "death") add("youFirstDeath", x.won);
    }
    return out;
  }

  /** Clutches: the player is the last one alive on their team with enemies still up. vs[n] = { rounds, wins } for 1vN. */
  function clutches(all) {
    const vs = [1, 2, 3, 4, 5].map(() => rate(0, 0));
    for (const x of all) {
      if (!x.present || x.won == null) continue;
      const alive = new Map(x.round.players.map((p) => [p.name.toLowerCase(), p.team]));
      const count = (t) => [...alive.values()].filter((v) => v === t).length;
      const mineT = x.player.team;
      for (const e of x.round.events) {
        if (!(e.kill || e.type === "PlayerLeave")) continue;
        const gone = (e.kill ? e.target : e.actor) || "";
        alive.delete(gone.toLowerCase());
        if (!alive.has(x.name.toLowerCase())) break;
        const enemies = alive.size - count(mineT);
        if (count(mineT) === 1 && enemies >= 1) {
          const v = vs[Math.min(5, enemies) - 1];
          v.rounds++;
          if (x.won) v.wins++;
          v.rate = v.wins / v.rounds;
          break;
        }
      }
    }
    const total = vs.reduce((a, v) => a + v.rounds, 0), won = vs.reduce((a, v) => a + v.wins, 0);
    return { vs, ...rate(won, total) };
  }

  /** Round wins by the time of day the match started (the viewer's clock). */
  const DAYPARTS = [["Night", 0], ["Morning", 6], ["Afternoon", 12], ["Evening", 18]];
  function byDaypart(matches) {
    const acc = DAYPARTS.map(([name]) => ({ name, matches: 0, rounds: 0, wins: 0, kills: 0, deaths: 0 }));
    for (const m of matches) {
      if (!m.first.at) continue;
      const a = acc[Math.floor(new Date(m.first.at).getHours() / 6)];
      a.matches++; a.rounds += m.sum.rounds; a.wins += m.sum.wins; a.kills += m.sum.kills; a.deaths += m.sum.deaths;
    }
    return acc.map((a) => ({ ...a, rate: a.rounds ? a.wins / a.rounds : null, kd: a.deaths ? a.kills / a.deaths : null }));
  }

  /** Sessions: matches with less than 90 minutes between the end of one and the start of the next. Returns the sessions
      and how the 1st, 2nd, 3rd and 4th-or-later match of a session went. */
  function sessions(matches) {
    const sorted = matches.filter((m) => m.first.at).sort((a, b) => a.first.at - b.first.at);
    const list = [];
    let cur = null, lastEnd = 0;
    for (const m of sorted) {
      const end = Math.max(...m.rounds.map((r) => r.at || 0), m.first.at);
      if (!cur || m.first.at - lastEnd > 90 * 60 * 1000) list.push((cur = []));
      cur.push(m);
      lastEnd = end;
    }
    const nth = [0, 1, 2, 3].map((i) => ({ name: i < 3 ? ["1st", "2nd", "3rd"][i] + " match" : "4th and later", matches: 0, rounds: 0, wins: 0, kostRounds: 0 }));
    for (const s of list) s.forEach((m, i) => {
      const a = nth[Math.min(3, i)];
      a.matches++; a.rounds += m.sum.rounds; a.wins += m.sum.wins; a.kostRounds += m.sum.kostRounds;
    });
    return {
      list, count: list.length, avgMatches: list.length ? sorted.length / list.length : null,
      nth: nth.map((a) => ({ ...a, rate: a.rounds ? a.wins / a.rounds : null, kost: a.rounds ? a.kostRounds / a.rounds : null })),
    };
  }

  /** Plain-language findings, strongest first. Each needs enough rounds to mean something. */
  function findings(all, matches) {
    const out = [];
    const p = (v) => Math.round(v * 100) + "%";
    const maps = groupBy(all, (r) => r.round.map).filter((g) => g.rounds >= 10 && g.winRate != null).sort((a, b) => b.winRate - a.winRate);
    if (maps.length >= 2 && maps[0].winRate - maps[maps.length - 1].winRate >= 0.15) {
      const best = maps[0], worst = maps[maps.length - 1];
      out.push({ tone: "info", weight: best.winRate - worst.winRate, title: "Map gap", text: `You win ${p(best.winRate)} of rounds on ${best.name} but ${p(worst.winRate)} on ${worst.name}.` });
    }
    const sides = groupBy(all, (r) => (r.team ? (r.attack ? "attack" : "defense") : null)).filter((g) => g.rounds >= 10);
    if (sides.length === 2 && Math.abs(sides[0].winRate - sides[1].winRate) >= 0.1) {
      const [hi, lo] = sides[0].winRate > sides[1].winRate ? sides : [sides[1], sides[0]];
      out.push({ tone: "info", weight: hi.winRate - lo.winRate, title: "Stronger on " + hi.name, text: `${p(hi.winRate)} of rounds won on ${hi.name}, ${p(lo.winRate)} on ${lo.name}.` });
    }
    const o = openingImpact(all);
    if (o.teamFirst.rounds >= 8 && o.teamFirstDeath.rounds >= 8) {
      out.push({ tone: "info", weight: (o.teamFirst.rate - o.teamFirstDeath.rate) * 0.8, title: "The first kill decides a lot", text: `When your team gets the first kill you win ${p(o.teamFirst.rate)} of rounds; when it loses it, ${p(o.teamFirstDeath.rate)}.` });
    }
    const s = summarize(all);
    if (s.openingKills + s.openingDeaths >= 10) {
      const good = s.openingRate >= 0.5;
      out.push({ tone: good ? "good" : "bad", weight: Math.abs(s.openingRate - 0.5) * 1.5, title: good ? "You win your opening duels" : "Opening duels are costly", text: `You took ${s.openingKills} of ${s.openingKills + s.openingDeaths} opening duels (${p(s.openingRate)}).` + (good ? "" : " Try to take first contact only with a teammate ready to trade.") });
    }
    if (s.allTimed && s.deaths >= 10) {
      const alone = 1 - s.avengedDeaths / s.deaths;
      if (alone >= 0.5) out.push({ tone: "bad", weight: alone - 0.4, title: "Dying alone", text: `${p(alone)} of your deaths were never answered by a teammate. Play closer to your team.` });
    }
    const t = timing(all);
    const deaths = t.deaths.reduce((a, b) => a + b, 0);
    if (deaths >= 10 && t.deaths[0] / deaths >= 0.35) {
      out.push({ tone: "bad", weight: t.deaths[0] / deaths, title: "Early deaths", text: `${p(t.deaths[0] / deaths)} of your deaths come in the first 30 seconds of a round.` });
    }
    const c = clutches(all);
    if (c.rounds >= 5) out.push({ tone: c.rate >= 0.3 ? "good" : "info", weight: Math.abs(c.rate - 0.25), title: "Clutches", text: `You were last alive ${c.rounds} times and won ${c.wins} of those rounds (${p(c.rate)}).` });
    const ses = sessions(matches);
    const first = ses.nth[0], late = ses.nth[3];
    if (first.rounds >= 30 && late.rounds >= 30 && first.rate - late.rate >= 0.1) {
      out.push({ tone: "bad", weight: first.rate - late.rate, title: "Long sessions hurt", text: `You win ${p(first.rate)} of rounds in the first match of a session but ${p(late.rate)} from the 4th match on. Take a break after three.` });
    }
    const series = matchSeries(matches).filter((m) => m.kost != null);
    if (series.length >= 10) {
      const recent = series.slice(-5), before = series.slice(0, -5);
      const avg = (l) => l.reduce((a, m) => a + m.kost, 0) / l.length;
      const d = avg(recent) - avg(before);
      if (Math.abs(d) >= 0.06) out.push({ tone: d > 0 ? "good" : "bad", weight: Math.abs(d) * 2, title: d > 0 ? "Improving" : "Recent dip", text: `Your KOST in the last 5 matches is ${p(avg(recent))}, against ${p(avg(before))} before.` });
    }
    const ops = groupBy(all, (r) => r.player && r.player.operator).filter((g) => g.rounds >= 8 && g.kost != null).sort((a, b) => b.kost - a.kost);
    if (ops.length >= 2) out.push({ tone: "good", weight: 0.05, title: "Best operator", text: `${ops[0].name}: ${p(ops[0].kost)} KOST over ${ops[0].rounds} rounds.` });
    return out.sort((a, b) => b.weight - a.weight);
  }

  window.R6A = { mapName, normalize, detectPlayer, analyzeRound, summarize, siteStats, groupBy, leaderboard, groupMatches, matchView, same,
    matchSeries, rolling, timing, killsPerRound, openingImpact, clutches, byDaypart, sessions, findings, TIMING };
})();
