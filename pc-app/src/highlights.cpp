#include "highlights.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <map>
#include <set>

#include "core.hpp"

namespace hl {

static std::string lower(std::string s) {
  for (auto& c : s) c = (char)std::tolower((unsigned char)c);
  return s;
}
static std::string trim(const std::string& s) {
  size_t a = 0, b = s.size();
  while (a < b && std::isspace((unsigned char)s[a])) a++;
  while (b > a && std::isspace((unsigned char)s[b - 1])) b--;
  return s.substr(a, b - a);
}
static std::string key(const std::string& s) { return lower(trim(s)); }
static std::string name_of(const mini::Json& v) { return v.type == mini::Json::Obj ? v.at("name").str() : v.str(); }

std::vector<std::string> recorder_names(const std::vector<mini::Json>& rounds) {
  // The profile that recorded most of the rounds is the person at this PC; a few files from someone else's game don't count.
  std::map<std::string, int> count;
  for (const auto& r : rounds) {
    const std::string id = r.at("recordingProfileID").str();
    if (!id.empty()) count[id]++;
  }
  std::string me;
  int best = 0;
  for (const auto& kv : count)
    if (kv.second > best) { best = kv.second; me = kv.first; }
  std::vector<std::string> out;   // every name that profile used, in case they renamed
  for (const auto& r : rounds)
    for (const auto& p : r.at("players").a) {
      const std::string n = p.at("username").str();
      if (!me.empty() && p.at("profileID").str() == me && !n.empty() && std::find(out.begin(), out.end(), n) == out.end()) out.push_back(n);
    }
  return out;
}

static std::string stable_id(const std::string& seed) {
  const std::string h = core::sha256_bytes(seed);
  return h.substr(0, 8) + "-" + h.substr(8, 4) + "-" + h.substr(12, 4) + "-" + h.substr(16, 4) + "-" + h.substr(20, 12);
}

std::vector<Highlight> detect_round(const mini::Json& r, const std::vector<std::string>& me_names, const Options& opt) {
  std::vector<Highlight> out;
  std::set<std::string> me;
  for (const auto& n : me_names) me.insert(key(n));
  const auto& players = r.at("players").a;
  std::map<std::string, int> team;
  std::map<std::string, std::string> op;
  const mini::Json* mine = nullptr;
  for (const auto& p : players) {
    const std::string k = key(p.at("username").str());
    if (k.empty()) continue;
    team[k] = (int)p.at("teamIndex").num(-1);
    op[k] = name_of(p.at("operator"));
    if (me.count(k) && !mine) mine = &p;
  }
  if (!mine) return out;
  const std::string meKey = key(mine->at("username").str());
  const int myTeam = team[meKey];
  const auto& teams = r.at("teams");
  const mini::Json& t = teams.at((size_t)std::max(myTeam, 0));
  const bool won = t.at("won").type == mini::Json::Bool && t.at("won").b;
  const std::string side = t.at("role").str();

  // Walk the events in order, keeping who is alive and where the clock is.
  std::map<int, int> alive;
  for (const auto& kv : team) alive[kv.second]++;
  const int startedWithUs = alive[myTeam];
  int enemiesTotal = 0;
  for (const auto& kv : alive)
    if (kv.first != myTeam) enemiesTotal += kv.second;
  bool meAlive = true, planted = false, firstKillSeen = false;
  double lastActionT = 0, plantAt = -1;
  int clutchVs = 0;
  double clutchFrom = -1;
  struct Mine { Kill k; bool entry = false, winner = false, inClutch = false; };
  std::vector<Mine> kills;

  for (const auto& e : r.at("matchFeedback").a) {
    const std::string type = name_of(e.at("type"));
    const int clock = (int)e.at("timeInSeconds").num(-1);
    if (type.find("Plant") != std::string::npos && type.find("Complete") != std::string::npos) {
      planted = true;
      plantAt = lastActionT;   // the plant's own time is not usable: the last moment before it is the best we know
      continue;
    }
    double tNow = lastActionT;
    bool approx = false;
    if (clock >= 0) {
      if (!planted) tNow = lastActionT = std::max(lastActionT, opt.round_length - clock);
      else { tNow = plantAt + std::max(0.0, 45.0 - clock); approx = true; }
    }
    const bool kill = type == "Kill", death = type == "Death";
    if (!kill && !death) continue;
    const std::string victim = key(kill ? e.at("target").str() : e.at("username").str());
    const std::string killer = kill ? key(e.at("username").str()) : "";
    auto vt = team.find(victim);
    const bool friendly = kill && vt != team.end() && team.count(killer) && team[killer] == vt->second;
    if (vt != team.end()) alive[vt->second] = std::max(0, alive[vt->second] - 1);
    int enemiesAlive = 0;
    for (const auto& kv : alive)
      if (kv.first != myTeam) enemiesAlive += kv.second;

    if (kill && killer == meKey && !friendly) {
      Mine m;
      m.k.t = tNow;
      m.k.clock = clock;
      m.k.post_plant = planted;
      m.k.approx = approx;
      m.k.headshot = e.at("headshot").type == mini::Json::Bool && e.at("headshot").b;
      m.k.victim = e.at("target").str();
      m.k.victim_operator = op[victim];
      m.entry = !firstKillSeen;
      m.winner = won && enemiesAlive == 0;
      m.inClutch = clutchVs > 0;
      kills.push_back(m);
    }
    if (kill && !friendly) firstKillSeen = true;
    if (victim == meKey) meAlive = false;
    // The moment the player becomes the last one standing with enemies left: a clutch starts.
    if (meAlive && clutchVs == 0 && startedWithUs >= 2 && alive[myTeam] == 1 && enemiesAlive >= 1) {
      clutchVs = enemiesAlive;
      clutchFrom = tNow;
    }
  }
  if (kills.empty()) return out;

  const bool ace = (int)kills.size() >= std::max(enemiesTotal, 4);
  const bool clutchWon = clutchVs > 0 && won;

  // Group kills into moments: an ace is one moment, a won clutch keeps its kills together, else kills within the window.
  std::vector<std::vector<Mine>> groups;
  for (const auto& m : kills) {
    const bool join = !groups.empty() &&
                      (ace || (clutchWon && m.inClutch && groups.back().back().inClutch) || m.k.t - groups.back().back().k.t <= opt.window);
    if (join) groups.back().push_back(m);
    else groups.push_back({m});
  }

  const std::string matchId = r.at("matchID").str();
  const int roundNo = (int)r.at("roundNumber").num(0) + 1;
  for (const auto& g : groups) {
    Highlight h;
    h.match_id = matchId;
    h.round = roundNo;
    h.map_raw = name_of(r.at("map"));
    h.map = core::map_display_name(h.map_raw);
    h.mode = name_of(r.at("matchType"));
    h.played_at = r.at("timestamp").str();
    h.op = name_of(mine->at("operator"));
    h.side = side;
    h.won = won;
    const bool clutch = clutchWon && std::any_of(g.begin(), g.end(), [](const Mine& m) { return m.inClutch; });
    int score = 0;
    bool entry = false, winner = false, allHs = true;
    for (const auto& m : g) {
      h.kills.push_back(m.k);
      score += 1 + (m.k.headshot ? 1 : 0);
      entry |= m.entry;
      winner |= m.winner;
      allHs &= m.k.headshot;
      h.approx |= m.k.approx;
    }
    const int n = (int)g.size();
    if (n >= 2) score += 3 * (n - 1);
    if (ace && n == (int)kills.size()) score += 10;
    if (clutch) { score += 5 * clutchVs; h.clutch_vs = clutchVs; }
    if (winner) score += 2;
    if (entry) score += 1;
    h.score = score;

    if (ace && n == (int)kills.size()) h.tags.push_back("ace");
    if (clutch) h.tags.push_back("clutch");
    if (n >= 2) h.tags.push_back("multikill");
    if (entry) h.tags.push_back("entry");
    if (winner) h.tags.push_back("round_winner");
    if (allHs) h.tags.push_back("headshot");
    h.type = h.tags.empty() ? "kill" : (h.tags[0] == "round_winner" ? (allHs ? "headshot" : "kill") : h.tags[0]);

    double first = g.front().k.t, last = g.back().k.t;
    if (clutch && clutchFrom >= 0) first = std::min(first, clutchFrom);
    h.begin = first;
    h.from = std::max(0.0, first - opt.pad_before);
    h.to = last + opt.pad_after;
    char seed[160];
    std::snprintf(seed, sizeof seed, "|%d|%d|", roundNo, g.front().k.clock);
    h.id = stable_id(matchId + seed + key(g.front().k.victim));
    if (h.score >= opt.min_score) out.push_back(h);
  }
  return out;
}

std::vector<Highlight> detect(const std::vector<mini::Json>& rounds, const std::vector<std::string>& me, const Options& opt) {
  std::vector<Highlight> all;
  for (const auto& r : rounds) {
    auto h = detect_round(r, me, opt);
    all.insert(all.end(), h.begin(), h.end());
  }
  std::stable_sort(all.begin(), all.end(), [](const Highlight& a, const Highlight& b) {
    if (a.score != b.score) return a.score > b.score;
    if (a.played_at != b.played_at) return a.played_at > b.played_at;   // newer first among equals
    return a.round < b.round;
  });
  return all;
}

static std::string num(double v) {
  char b[32];
  std::snprintf(b, sizeof b, "%.1f", v);
  return b;
}

std::string item_json(const Highlight& h) {
  using mini::quote;
  std::string o = std::string("{\"id\":") + quote(h.id) + ",\"match_id\":" + quote(h.match_id) + ",\"round\":" + std::to_string(h.round) +
                  ",\"type\":" + quote(h.type) + ",\"tags\":[";
  for (size_t k = 0; k < h.tags.size(); k++) o += (k ? "," : "") + quote(h.tags[k]);
  o += "],\"score\":" + std::to_string(h.score) + ",\"clutch_vs\":" + std::to_string(h.clutch_vs) + ",\"won\":" + (h.won ? "true" : "false") +
       ",\"side\":" + quote(h.side) + ",\"operator\":" + quote(h.op) + ",\"map\":" + quote(h.map) + ",\"mode\":" + quote(h.mode) +
       ",\"played_at\":" + quote(h.played_at) + ",\"clip\":{\"begin\":" + num(h.begin) + ",\"from\":" + num(h.from) + ",\"to\":" + num(h.to) +
       ",\"approx\":" + (h.approx ? "true" : "false") + "},\"kills\":[";
  for (size_t k = 0; k < h.kills.size(); k++) {
    const auto& x = h.kills[k];
    o += (k ? "," : "") + std::string("{\"t\":") + num(x.t) + ",\"clock\":" + std::to_string(x.clock) + ",\"victim\":" + quote(x.victim) +
         ",\"victim_operator\":" + quote(x.victim_operator) + ",\"headshot\":" + (x.headshot ? "true" : "false") +
         ",\"post_plant\":" + (x.post_plant ? "true" : "false") + "}";
  }
  return o + "]}";
}

std::string to_json(const std::vector<Highlight>& list, const std::vector<std::string>& me) {
  using mini::quote;
  std::string o = "{\"schema\":1,\"player\":[";
  for (size_t i = 0; i < me.size(); i++) o += (i ? "," : "") + quote(me[i]);
  o += "],\"time\":\"seconds since the round timer started; approx=true means after a plant\",\"highlights\":[";
  for (size_t i = 0; i < list.size(); i++) o += (i ? "," : "") + item_json(list[i]);
  return o + "]}";
}

bool from_json(const std::string& text, std::vector<Highlight>& out) {
  mini::Json j;
  if (!mini::parse(text, j) || j.at("highlights").type != mini::Json::Arr) return false;
  for (const auto& x : j.at("highlights").a) {
    Highlight h;
    h.id = x.at("id").str();
    h.match_id = x.at("match_id").str();
    h.round = (int)x.at("round").num();
    h.type = x.at("type").str();
    for (const auto& t : x.at("tags").a) h.tags.push_back(t.str());
    h.score = (int)x.at("score").num();
    h.clutch_vs = (int)x.at("clutch_vs").num();
    h.won = x.at("won").b;
    h.side = x.at("side").str();
    h.op = x.at("operator").str();
    h.map = x.at("map").str();
    h.mode = x.at("mode").str();
    h.played_at = x.at("played_at").str();
    const auto& c = x.at("clip");
    h.from = c.at("from").n;
    h.to = c.at("to").n;
    h.begin = c.at("begin").isNull() ? h.from : c.at("begin").n;
    h.approx = c.at("approx").b;
    for (const auto& k : x.at("kills").a) {
      Kill kk;
      kk.t = k.at("t").n;
      kk.clock = (int)k.at("clock").num(-1);
      kk.victim = k.at("victim").str();
      kk.victim_operator = k.at("victim_operator").str();
      kk.headshot = k.at("headshot").b;
      kk.post_plant = kk.approx = k.at("post_plant").b;
      h.kills.push_back(kk);
    }
    if (h.id.empty() || h.match_id.empty() || h.kills.empty()) return false;
    out.push_back(h);
  }
  return true;
}

static std::string clockText(double t) {
  const int s = (int)std::lround(t);
  char b[16];
  std::snprintf(b, sizeof b, "%d:%02d", s / 60, s % 60);
  return b;
}

std::string describe(const Highlight& h) {
  std::string what;
  const int n = (int)h.kills.size();
  if (h.type == "ace") what = "ACE";
  else if (n >= 2) what = std::to_string(n) + "K";
  else what = "1 kill";
  if (h.clutch_vs) what += " clutch 1v" + std::to_string(h.clutch_vs);
  for (const auto& t : h.tags) {
    if (t == "entry") what += ", entry";
    if (t == "round_winner") what += ", round winner";
    if (t == "headshot") what += n >= 2 ? ", all headshots" : ", headshot";
  }
  return "Round " + std::to_string(h.round) + " on " + h.map + ": " + what + (h.op.empty() ? "" : " as " + h.op) + ", " + std::to_string(h.score) +
         " points. Clip " + clockText(h.from) + " to " + clockText(h.to) + " after the timer starts" + (h.approx ? " (approximate, after the plant)" : "");
}

}  // namespace hl
