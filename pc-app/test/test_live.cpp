// Tests of live clips: the stand-in OBS (with a replay buffer), a real replay server, a controlled clock, and a stand-in
// cutter that records where it was asked to cut. Checks the arithmetic that puts a moment in OBS's saved minutes.
// Environment: R6_OBS_LIVE_PORT (stand-in OBS, no password), R6_OBS_NOBUF_PORT (one without a replay buffer),
// R6_URL, R6_UP, R6_RD (replay server), R6_TEST_MP4 (a small MP4 to stand in for each cut clip), R6_TMP.
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "../src/live.hpp"
#include "../src/platform.hpp"

namespace fs = std::filesystem;
static int failures = 0, checks = 0;
#define CHECK(c) do { checks++; if (!(c)) { failures++; std::printf("  FAIL line %d: %s\n", __LINE__, #c); } } while (0)
#define SECTION(n) std::printf("%s\n", n)
static std::string env(const char* k) { const char* v = std::getenv(k); return v ? v : ""; }
static bool any(const std::vector<std::string>& v, const std::string& s) { for (auto& x : v) if (x.find(s) != std::string::npos) return true; return false; }

static std::string iso(double t) {   // seconds since 1970 -> "2026-11-10T20:00:00Z"
  const time_t tt = (time_t)t;
  struct tm g;
  gmtime_r(&tt, &g);
  char b[32];
  std::strftime(b, sizeof b, "%Y-%m-%dT%H:%M:%SZ", &g);
  return b;
}

// A ranked round recorded by "Me": kills given as (killer, victim, clock, headshot).
struct K { const char* a; const char* t; int clock; bool hs; };
static std::string round_json(double start, int number, const std::vector<K>& kills, const char* mode = "Ranked") {
  std::string players;
  const char* mates[] = {"Me", "A1", "A2", "A3", "A4"};
  for (int i = 0; i < 5; i++) players += std::string(i ? "," : "") + "{\"username\":\"" + mates[i] + "\",\"teamIndex\":0,\"profileID\":\"" + (i ? std::string("p") + mates[i] : "me-profile") + "\",\"operator\":{\"name\":\"Ash\"}}";
  for (int i = 0; i < 5; i++) players += ",{\"username\":\"E" + std::to_string(i) + "\",\"teamIndex\":1,\"profileID\":\"pE" + std::to_string(i) + "\",\"operator\":{\"name\":\"Jager\"}}";
  std::string ev;
  for (size_t i = 0; i < kills.size(); i++)
    ev += std::string(i ? "," : "") + "{\"type\":{\"name\":\"Kill\"},\"username\":\"" + kills[i].a + "\",\"target\":\"" + kills[i].t + "\",\"timeInSeconds\":" + std::to_string(kills[i].clock) + ",\"headshot\":" + (kills[i].hs ? "true" : "false") + "}";
  return "{\"matchID\":\"live-match-0001\",\"roundNumber\":" + std::to_string(number) + ",\"timestamp\":\"" + iso(start) + "\",\"map\":{\"name\":\"BankY10\"},\"matchType\":{\"name\":\"" + mode +
         "\"},\"recordingProfileID\":\"me-profile\",\"teams\":[{\"role\":\"Attack\",\"score\":1,\"won\":true},{\"role\":\"Defense\",\"score\":0,\"won\":false}],\"players\":[" + players + "],\"matchFeedback\":[" + ev + "]}";
}

struct Cut { std::string in; double start, length, thumb; size_t parts; std::vector<rec::Part> all; };

// Stands in for the built-in recorder: pieces of footage with known wall-clock times.
struct FakeRecorder : rec::Recorder {
  bool on = false;
  int flushes = 0, starts = 0, stops = 0;
  std::vector<rec::Segment> segs;
  bool start(const rec::Options&, std::string&) override { on = true; starts++; return true; }
  void stop() override { on = false; stops++; }
  bool running() const override { return on; }
  bool flush(std::string&) override { flushes++; return true; }
  std::vector<rec::Segment> segments() override { return segs; }
  std::string status() override { return on ? "recording the screen" : "stopped"; }
};

int main() {
  const fs::path tmp = fs::path(env("R6_TMP")) / "live";
  fs::remove_all(tmp);
  fs::create_directories(tmp);
  std::ifstream mp4in(env("R6_TEST_MP4"), std::ios::binary);
  const std::string mp4((std::istreambuf_iterator<char>(mp4in)), {});

  SECTION("times from the replay are read as UTC");
  CHECK(live::parse_utc("1970-01-01T00:01:05Z") == 65);
  CHECK(live::parse_utc("2026-10-30T13:45:56Z") == 1793367956);
  CHECK(live::parse_utc("2026-10-30T13:45:56") < 0);   // no zone: not trusted
  CHECK(live::parse_utc("yesterday") < 0);

  std::vector<std::string> log;
  live::Clipper c([&](const std::string& m) { log.push_back(m); });
  double T = 1800000000;   // the controlled "now"
  c.now = [&] { return T; };
  double bufferLength = 600;
  c.duration = [&](const std::string&, double& s, std::string&) { s = bufferLength; return true; };
  std::vector<Cut> cuts;
  c.cut = [&](const std::vector<rec::Part>& parts, const std::string& out, const std::string& thumb, const std::string&, double at, std::string&) {
    double len = 0;
    for (const auto& p : parts) len += p.length;
    cuts.push_back({parts[0].path, parts[0].offset, len, at, parts.size(), parts});
    std::ofstream(fs::path(out), std::ios::binary) << mp4;
    std::ofstream(fs::path(thumb), std::ios::binary) << std::string("\xff\xd8\xff\xe0jpeg", 8);
    return true;
  };
  live::Settings saved;
  int savedCalls = 0;
  c.on_settings_changed = [&](const live::Settings& s) { saved = s; savedCalls++; };
  live::Settings s;
  s.enabled = true;
  s.use_obs = true;   // these first sections drive OBS; the built-in recorder has its own section below
  s.obs_port = std::atoi(env("R6_OBS_LIVE_PORT").c_str());
  s.server = env("R6_URL");
  s.token = env("R6_UP");
  s.clips_dir = (tmp / "clips").string();
  c.configure(s);

  SECTION("the replay buffer is kept on while the game runs");
  CHECK(c.keep_buffer(false).find("waiting for Siege") != std::string::npos);
  CHECK(c.keep_buffer(true).find("recording") != std::string::npos);
  CHECK(any(log, "started OBS's replay buffer"));
  live::Settings off = s;
  off.enabled = false;
  c.configure(off);
  CHECK(c.keep_buffer(true) == "Live clips are off.");
  c.configure(s);

  SECTION("a 2K just after the round: saved, placed and cut where it happened (not yet calibrated: wider clip)");
  {
    // Round began 200 s ago; kills 30 s and 40 s after its timer started. Guess: the timer starts 60 s after the round begins.
    c.on_round(round_json(T - 200, 2, {{"Me", "E0", 150, true}, {"Me", "E1", 140, false}}));
    CHECK(any(log, "round 3: 1 moment saved"));
    CHECK(c.drain() == 1);
    CHECK(cuts.size() == 1);
    if (!cuts.empty()) {
      // The saved video (600 s) ends now: it starts at T-600. Timer at T-200+60 = 460 s into it. First kill 490, last 500.
      CHECK(cuts[0].start == 478 && cuts[0].length == 28 && cuts[0].thumb == 490);   // 12 s before, 6 s after
      CHECK(cuts[0].in.find("Replay 1.mkv") != std::string::npos);
      CHECK(!fs::exists(cuts[0].in));   // OBS's saved minutes are deleted once cut
    }
    CHECK(any(log, "1 clip uploaded"));
  }

  SECTION("old rounds (catching up on files) and small moments do not save the buffer");
  {
    const size_t before = cuts.size();
    log.clear();
    c.on_round(round_json(T - 7200, 1, {{"Me", "E0", 150, true}, {"Me", "E1", 140, false}}));   // two hours ago
    c.on_round(round_json(T - 100, 4, {{"Me", "E0", 150, false}}));                            // one plain kill: 1 point
    CHECK(c.drain() == 0 && cuts.size() == before && !any(log, "saved"));
  }

  SECTION("one key press calibrates the game mode, and clips become exact");
  {
    T += 1000;
    c.calibrate_now();   // pressed 50 s after the round began
    T += 150;            // the round's replay arrives later
    // round began at (T-150-50): kills 30 and 40 s after the timer
    c.on_round(round_json(T - 200, 5, {{"Me", "E2", 150, false}, {"Me", "E3", 140, true}}));
    CHECK(savedCalls == 1 && saved.offsets["Ranked"] == 50);
    CHECK(any(log, "calibrated for Ranked"));
    CHECK(c.drain() == 1);
    // Timer at T-200+50 = 450 s into the 600 s video: kills at 480 and 490; 5 s before, 3 s after.
    CHECK(cuts.size() >= 2 && cuts.back().start == 475 && cuts.back().length == 18);
    // Another mode is not calibrated by it.
    CHECK(saved.offsets.count("QuickMatch") == 0);
  }

  SECTION("a moment older than what OBS kept is skipped with advice, not cut wrong");
  {
    const size_t before = cuts.size();
    log.clear();
    bufferLength = 100;   // OBS kept only 100 s; the round's timer started 150 s ago
    c.on_round(round_json(T - 200, 6, {{"Me", "E0", 170, true}, {"Me", "E1", 165, true}}));
    CHECK(c.drain() == 0 && cuts.size() == before);
    CHECK(any(log, "before the recording's oldest minute"));
    bufferLength = 600;
  }

  SECTION("OBS without a replay buffer: a clear message, nothing saved");
  {
    live::Clipper n([&](const std::string& m) { log.push_back(m); });
    n.now = [&] { return T; };
    live::Settings ns = s;
    ns.obs_port = std::atoi(env("R6_OBS_NOBUF_PORT").c_str());
    n.configure(ns);
    log.clear();
    CHECK(n.keep_buffer(true).find("turn on OBS's replay buffer") != std::string::npos);
    CHECK(any(log, "Settings > Output > Replay Buffer"));
    n.on_round(round_json(T - 100, 7, {{"Me", "E0", 150, true}, {"Me", "E1", 140, false}}));
    CHECK(any(log, "not clipped"));
    CHECK(n.drain() == 0);
  }

  SECTION("the built-in recorder: records while the game runs, and a moment across two recorded minutes is joined");
  {
    FakeRecorder fr;
    live::Clipper b([&](const std::string& m) { log.push_back(m); });
    b.now = [&] { return T; };
    b.cut = c.cut;
    b.use_recorder(&fr);
    live::Settings bs = s;
    bs.use_obs = false;
    bs.offsets["Ranked"] = 50;   // calibrated
    b.configure(bs);
    log.clear();
    CHECK(b.keep_buffer(false).find("waiting for Siege") != std::string::npos && !fr.on);
    CHECK(b.keep_buffer(true).find("recording the screen") != std::string::npos && fr.on && fr.starts == 1);
    CHECK(any(log, "recording started (built-in recorder)"));
    // Twelve recorded minutes ending now, one piece per minute.
    for (int i = 12; i >= 1; i--) fr.segs.push_back({(tmp / ("piece-" + std::to_string(i) + ".mp4")).string(), T - 60.0 * i, T - 60.0 * (i - 1)});
    // Round began 230 s ago; its timer 50 s later, at T-180. Kills 28 s and 33 s in: T-152 and T-147.
    const size_t before = cuts.size();
    b.on_round(round_json(T - 230, 8, {{"Me", "E0", 152, true}, {"Me", "E1", 147, false}}));   // timer clock: 28 s and 33 s in
    CHECK(any(log, "1 moment found, cutting"));
    CHECK(b.drain() == 1 && fr.flushes == 1);
    CHECK(cuts.size() == before + 1);
    if (cuts.size() == before + 1) {
      // The clip (5 s before, 3 s after) runs from T-157 to T-144: inside the minute recorded from T-180 to T-120.
      const auto& cc = cuts.back();
      CHECK(cc.parts == 1 && cc.all[0].path.find("piece-3.mp4") != std::string::npos);
      CHECK(cc.all[0].offset == 23 && cc.length == 13);   // T-157 is 23 s into the piece that starts at T-180
    }
    // A moment that crosses a minute: round began T-240, timer at T-190, kills 8 s and 12 s in (T-182, T-178).
    b.on_round(round_json(T - 240, 9, {{"Me", "E2", 172, true}, {"Me", "E3", 168, false}}));
    CHECK(b.drain() == 1);
    if (!cuts.empty()) {
      const auto& cc = cuts.back();
      CHECK(cc.parts == 2);
      if (cc.parts == 2) {
        CHECK(cc.all[0].path.find("piece-4.mp4") != std::string::npos && cc.all[1].path.find("piece-3.mp4") != std::string::npos);
        CHECK(cc.all[0].offset == 53 && cc.all[0].length == 7 && cc.all[1].offset == 0 && cc.all[1].length == 5);   // T-187..T-180, then T-180..T-175
      }
    }
    // Older than the recording: skipped with a reason.
    log.clear();
    b.on_round(round_json(T - 800, 10, {{"Me", "E0", 150, true}, {"Me", "E1", 140, true}}));
    CHECK(b.drain() == 0 && any(log, "not in the recording"));
    // The game closes: recording stops once nothing is left to cut.
    CHECK(b.keep_buffer(false).find("waiting for Siege") != std::string::npos && !fr.on && fr.stops == 1);
  }

  SECTION("the phone sees the clips");
  {
    const auto r = plat::http_get(env("R6_URL") + "/v1/highlights", env("R6_RD"));
    mini::Json j;
    CHECK(r.status == 200 && mini::parse(r.body, j));
    int liveClips = 0;
    for (const auto& h : j.at("highlights").a) liveClips += h.at("match_id").str() == "live-match-0001" && h.at("status").str() == "ready";
    CHECK(liveClips == 4);   // two through OBS, two through the built-in recorder
  }

  std::printf("\n%d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
