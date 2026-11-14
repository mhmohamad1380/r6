// Native tests of the exact core.cpp that ships in the Windows exe, against a real replay server.
// Environment: R6_URL, R6_UP, R6_RD, R6_SAMPLES (folder with quick_1.rec, ranked_2.rec, corrupted.rec), R6_TMP.
#include <sys/stat.h>
#include <utime.h>

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <set>

#include "../src/core.hpp"
#include "../src/json.hpp"
#include "../src/platform.hpp"

namespace fs = std::filesystem;
static int failures = 0, checks = 0;
#define CHECK(c) do { checks++; if (!(c)) { failures++; std::printf("  FAIL line %d: %s\n", __LINE__, #c); } } while (0)
#define SECTION(n) std::printf("%s\n", n)

static std::string getenv_s(const char* k) { const char* v = std::getenv(k); return v ? v : ""; }

static void age(const fs::path& p, int seconds) {
  struct utimbuf t{std::time(nullptr) - seconds, std::time(nullptr) - seconds};
  utime(p.c_str(), &t);
}
static fs::path put(const fs::path& dir, const std::string& name, const std::string& bytes, int old = 60) {
  fs::create_directories(dir);
  std::ofstream(dir / name, std::ios::binary) << bytes;
  age(dir / name, old);
  return dir / name;
}
static std::string slurp(const fs::path& p) { std::ifstream f(p, std::ios::binary); return {std::istreambuf_iterator<char>(f), {}}; }
static bool any_has(const std::vector<std::string>& v, const std::string& s) { for (auto& x : v) if (x.find(s) != std::string::npos) return true; return false; }

int main() {
  const std::string url = getenv_s("R6_URL"), url2 = getenv_s("R6_URL2"), url3 = getenv_s("R6_URL3"), UP = getenv_s("R6_UP"), RD = getenv_s("R6_RD"), samples = getenv_s("R6_SAMPLES"), tmp = getenv_s("R6_TMP");
  fs::remove_all(tmp);
  fs::create_directories(tmp);

  SECTION("map names and the round summary in the log");
  CHECK(core::map_display_name("Map(407987100456)") == "Border");
  CHECK(core::map_display_name("ClubHouseY10") == "Clubhouse");
  CHECK(core::map_display_name("KafeDostoyevskyY10") == "Kafe Dostoyevsky");
  CHECK(core::map_display_name("Map(434715462383)") == "Oregon");
  CHECK(core::map_display_name("Map(999999999999)") == "Unknown map 9999");
  CHECK(core::map_display_name("NewPlaceY12") == "New Place");
  {
    const std::string round = R"({"matchID":"m","roundNumber":2,"map":{"name":"BorderY10","id":1},"matchType":{"name":"Ranked","id":2},"recordingProfileID":"me",
      "teams":[{"role":"Attack","score":2,"won":true},{"role":"Defense","score":1,"won":false}],
      "players":[{"username":"Alex","teamIndex":0,"profileID":"me","operator":{"name":"Ash","id":1}},{"username":"Bo","teamIndex":1,"profileID":"x"}],
      "matchFeedback":[{"type":{"name":"Kill","id":0},"username":"alex","target":"Bo","headshot":true},{"type":{"name":"Kill","id":0},"username":"Alex","target":"Cy","headshot":false}]})";
    const std::string s = core::round_summary(round);
    CHECK(s == "Round 3 on Border (Ranked): you attacked and won. 2 kills, 1 headshot, survived as Ash");
    std::string died = round;
    died.replace(died.rfind("]}"), 2, R"(,{"type":{"name":"Death","id":1},"username":"Alex"}]})");
    CHECK(core::round_summary(died).find(", died as Ash") != std::string::npos);
    std::string other = round;
    other.replace(other.find("\"profileID\":\"me\""), 16, "\"profileID\":\"zz\"");
    CHECK(core::round_summary(other) == "Round 3 on Border (Ranked): Attack won");
    CHECK(core::round_summary("not json").empty());
  }
  setenv("APPDATA", (tmp + "/appdata").c_str(), 1);

  SECTION("json");
  {
    mini::Json j;
    CHECK(mini::parse(R"({"results":[{"status":"parsed","id":7,"error":null,"x":[1,2.5,-3e2,true,false]}],"s":"a\"b\\c\né😀"})", j));
    CHECK(j.at("results").at(0).at("status").str() == "parsed");
    CHECK(j.at("results").at(0).at("id").num() == 7);
    CHECK(j.at("results").at(0).at("error").isNull());
    CHECK(j.at("results").at(0).at("x").at(2).n == -300);
    CHECK(j.at("results").at(0).at("x").at(3).b == true);
    CHECK(j.at("s").str() == "a\"b\\c\n\xC3\xA9\xF0\x9F\x98\x80");
    CHECK(j.at("missing").at(5).at("deeper").str("fallback") == "fallback");
    for (const char* bad : {"", "{", "[1,]", "{\"a\":}", "{\"a\" 1}", "nul", "[1 2]", "\"abc", "{\"a\":1} x"}) { mini::Json b; CHECK(!mini::parse(bad, b)); }
    std::string deep(200, '['); mini::Json d; CHECK(!mini::parse(deep, d));
  }

  SECTION("addresses");
  CHECK(core::normalize_url("  replays.example.com/ ") == "https://replays.example.com");
  CHECK(core::normalize_url("http://10.0.0.5:8090///") == "http://10.0.0.5:8090");
  CHECK(core::normalize_url("") == "");

  SECTION("settings and memory");
  {
    core::Config c;
    CHECK(!core::load_config(c));
    c.server = "https://x.example"; c.token = "S3cret-Tok_en"; c.folder = fs::path(tmp) / "Replays"; c.poll = 33;
    CHECK(core::save_config(c));
    core::Config b;
    CHECK(core::load_config(b));
    CHECK(b.server == c.server && b.token == c.token && b.folder == c.folder && b.poll == 33 && b.configured());
    CHECK(slurp(fs::path(tmp) / "appdata/R6ReplayUploader/config.ini").find("S3cret") == std::string::npos);   // not stored as plain text
    core::State s = core::load_state();
    CHECK(s.empty());
    core::remember(s, "a|1|2", "parsed");
    core::remember(s, "b|3|4", "skipped");
    core::State t = core::load_state();
    CHECK(t.size() == 1 && t["a|1|2"] == "parsed" && !t.count("b|3|4"));   // an old silent "skipped" is forgotten, so the file is looked at again and explained
  }

  SECTION("finding the folder");
  {
    fs::path root = fs::path(tmp) / "pc";
    put(root / "Ubi/MatchReplay/Match-1", "r1.rec", "x"); put(root / "Ubi/MatchReplay/Match-1", "r2.rec", "x");
    fs::path lib = root / "BigDisk";
    put(lib / "steamapps/common/Tom Clancy's Rainbow Six Siege/MatchReplay", "a.rec", "x");
    put(lib / "steamapps/common/Tom Clancy's Rainbow Six Siege/MatchReplay", "b.rec", "x");
    put(lib / "steamapps/common/Tom Clancy's Rainbow Six Siege/MatchReplay/sub", "c.REC", "x");
    put(root / "Steam/steamapps", "libraryfolders.vdf", "\"libraryfolders\"\n{\n \"0\"\n {\n  \"path\"\t\t\"" + lib.string() + "\"\n }\n}\n");
    setenv("R6_TEST_DRIVES", root.c_str(), 1);
    setenv("R6_TEST_INSTALL", (root / "Ubi").c_str(), 1);
    auto found = core::discover();
    CHECK(found.size() == 2);
    CHECK(found.size() == 2 && found[0].second == 3 && found[0].first.string().find("BigDisk") != std::string::npos);   // most replays first; Steam library from the vdf
    CHECK(found.size() == 2 && found[1].second == 2);
    CHECK(core::count_rec(root / "Ubi/MatchReplay") == 2);
    CHECK(core::count_rec(root / "nope") == 0);
    auto cand = core::candidate_folders();
    std::set<std::string> uniq; for (auto& p : cand) uniq.insert(p.string());
    CHECK(uniq.size() == cand.size());   // no duplicates
    unsetenv("R6_TEST_DRIVES"); unsetenv("R6_TEST_INSTALL");
    CHECK(core::discover().empty());
  }

  SECTION("deciding what to send");
  {
    fs::path d = fs::path(tmp) / "scan";
    std::string real = slurp(fs::path(samples) / "quick_1.rec");
    auto old = put(d, "old.rec", real, 120);
    auto fresh = put(d, "fresh.rec", real, 0);
    auto empty = put(d, "empty.rec", "", 120);
    auto nested = put(d / "Match-2", "n.rec", real, 200);
    put(d, "notes.txt", "hi", 300);
    CHECK(core::looks_like_replay(old));
    CHECK(!core::looks_like_replay(put(d, "t.rec", "not a replay at all", 100)));
    CHECK(core::looks_like_replay(put(d, "plain.rec", std::string("dissect\0", 8) + "rest of a plain replay", 100)));   // what current game versions write
    CHECK(!core::looks_like_replay(put(d, "short.rec", "dissec", 100)));
    fs::remove(d / "plain.rec"); fs::remove(d / "short.rec");
    CHECK(core::is_stable(old) && !core::is_stable(fresh) && !core::is_stable(empty));
    core::State s;
    CHECK(core::sha256_bytes("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    CHECK(core::sha256_bytes("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    CHECK(core::sha256_bytes(std::string(1000, 'a')) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3");
    CHECK(core::sha256_file(old) == core::sha256_bytes(real));   // streamed and whole agree on a real 9 MB replay
    CHECK(core::sha256_file(fs::path(tmp) / "missing.rec").empty());
    auto list = core::scan(d, s);
    CHECK(list.size() == 3);   // old, nested, t.rec: not the fresh one, not the empty one, not the .txt
    CHECK(list.size() == 3 && list[0] == nested);   // oldest first
    core::remember(s, core::sha256_file(old), "parsed");
    CHECK(core::scan(d, s).size() == 1);   // nested has the same bytes as old: it is the same replay, wherever it sits
    CHECK(core::file_key(old) != core::file_key(nested));
    CHECK(core::fingerprint(old, s) == core::sha256_file(old) && s[core::file_key(old)] == "#" + core::sha256_file(old));   // remembered, so not read twice
    core::State reloaded = core::load_state();
    CHECK(reloaded.count(core::file_key(old)));
  }

  SECTION("talking to the server");
  {
    std::string m;
    CHECK(core::check_server(url, UP, m) && m.find("accepted") != std::string::npos);
    CHECK(!core::check_server(url, RD, m) && m.find("READ token") != std::string::npos);
    CHECK(!core::check_server(url, "nonsense", m) && m.find("does not accept") != std::string::npos);
    CHECK(!core::check_server(url + "/nope", UP, m) && m.find("not a replay server") != std::string::npos);
    CHECK(!core::check_server("http://127.0.0.1:1", UP, m) && m.find("Could not reach") != std::string::npos);
    CHECK(!core::check_server("", UP, m));
  }

  // ---- The new way: each replay is read on this PC with the bundled reader and only small JSON is sent. ----
  const std::string realReader = getenv_s("R6_DISSECT_REAL"), payloadDir = getenv_s("R6_PAYLOADS");
  setenv("R6_DISSECT", realReader.c_str(), 1);
  auto reader_script = [&](const std::string& name, const std::string& body) {
    fs::path p = fs::path(tmp) / name;
    std::ofstream(p) << "#!/bin/sh\n" << body;
    fs::permissions(p, fs::perms::owner_all);
    return p;
  };

  SECTION("reading replays on this PC");
  {
    fs::path d = fs::path(tmp) / "local";
    const std::string q = slurp(fs::path(samples) / "quick_1.rec"), r = slurp(fs::path(samples) / "ranked_2.rec");
    auto a = put(d / "Match-A", "quick_1.rec", q, 300), b = put(d / "Match-B", "ranked_2.rec", r, 200);
    core::Config cfg; cfg.server = url; cfg.token = UP; cfg.folder = d;
    core::State st;
    std::vector<std::string> log;
    auto lg = [&](const std::string& s) { log.push_back(s); };
    // What the app sends, saved so a script can compare it with the server's reference trim of the same replay.
    for (const auto& f : {a, b}) {
      auto lr = core::read_replay(f, core::sha256_file(f), (uint64_t)fs::file_size(f));
      CHECK(lr.ok && !lr.helper_unusable);
      std::ofstream(fs::path(payloadDir) / (f.filename().string() + ".json")) << lr.payload;
      std::printf("    %s: %zu bytes of JSON instead of %llu bytes of replay (%.0fx smaller), read in %.2f s\n", f.filename().c_str(), lr.payload.size(), (unsigned long long)fs::file_size(f), (double)fs::file_size(f) / (double)lr.payload.size(), lr.seconds);
      CHECK(lr.payload.size() < 8000 && lr.payload.find("\"schema_version\":1") != std::string::npos && lr.payload.find(core::kParserVersion) != std::string::npos);
      CHECK(lr.payload.find("\"gameVersion\"") != std::string::npos && lr.payload.find("\"spawn\"") != std::string::npos);   // kept since 1.3.0
      CHECK(lr.payload.find("\"stats\"") == std::string::npos && lr.payload.find("heroName") == std::string::npos);   // only the fields the apps read
      CHECK(!lr.summary.empty() && lr.summary.rfind("Round ", 0) == 0);
      std::printf("    summary: %s\n", lr.summary.c_str());
    }
    auto n = core::sync_once(cfg, st, lg);
    CHECK(n.parsed == 2 && n.local == 2 && n.error == 0 && n.fell_back == 0);
    CHECK(any_has(log, "on this PC") && any_has(log, "instead of") && any_has(log, "Upload complete"));
    CHECK(!any_has(log, "50%"));   // no raw upload happened
    CHECK(n.bytes < 20000);        // a few KB for two rounds, not tens of MB
    auto stats = plat::http_get(url + "/v1/stats", RD).body;
    CHECK(stats.find("\"parsed\":2") != std::string::npos && stats.find("\"recs\":0") != std::string::npos);   // stored, and no .rec ever reached the server
    auto rounds = plat::http_get(url + "/v1/rounds?after=0", RD).body;
    CHECK(rounds.find(std::string("\"parser\":\"client:") + core::kParserVersion + "\"") != std::string::npos && rounds.find("matchFeedback") != std::string::npos);
    log.clear();
    CHECK(core::sync_once(cfg, st, lg).uploaded() == 0 && log.empty());   // nothing new: nothing read or sent
    core::State fresh;   // a new install: the server already has them, so nothing is read or sent
    log.clear();
    n = core::sync_once(cfg, fresh, lg);
    CHECK(n.known == 2 && n.parsed == 0 && !any_has(log, "on this PC") && any_has(log, "already on the server"));
    put(d / "Match-A", "copy-of-quick.rec", q, 100);   // renamed copy of a replay the server has
    log.clear();
    n = core::sync_once(cfg, fresh, lg);
    CHECK(n.parsed == 0 && !any_has(log, "on this PC"));
  }

  SECTION("a replay this PC cannot read");
  {
    fs::path d = fs::path(tmp) / "unreadable";
    const std::string bad = slurp(fs::path(samples) / "corrupted.rec");
    put(d / "Match-C", "broken.rec", bad, 300);
    core::Config cfg; cfg.server = url; cfg.token = UP; cfg.folder = d;
    std::vector<std::string> log;
    auto lg = [&](const std::string& s) { log.push_back(s); };
    {   // by default the file itself is sent so the server can look at it, and the log says so
      core::State st;
      auto n = core::sync_once(cfg, st, lg);
      CHECK(n.local == 0 && n.fell_back == 1 && n.failed == 1);
      CHECK(any_has(log, "could not be read on this PC") && any_has(log, "sending the file itself") && any_has(log, "turn this off"));
      CHECK(core::is_done(st, core::sha256_file(d / "Match-C" / "broken.rec")));   // not retried on every pass
      log.clear();
      CHECK(core::sync_once(cfg, st, lg).uploaded() == 0 && log.empty());
    }
    {   // switched off: only the failure and its reason are recorded, and no big file is sent
      put(d / "Match-D", "broken2.rec", bad + std::string(64, 'x'), 300);
      cfg.raw_fallback = false;
      core::State st;
      log.clear();
      auto n = core::sync_once(cfg, st, lg);
      CHECK(n.fell_back == 0 && n.failed == 1 && any_has(log, "could not be read on this PC") && any_has(log, "recording the failure"));
      CHECK(plat::http_get(url + "/v1/rounds?after=0", RD).body.find("The PC could not read this replay") != std::string::npos);
      CHECK(plat::http_get(url + "/v1/stats", RD).body.find("\"recs\":1") != std::string::npos);   // still only the one fallback file
    }
    {   // too big to send whole: the failure is recorded instead, even with the fallback on
      const std::string big = std::string("dissect\0", 8) + std::string((size_t)core::kRawFallbackMax + 1024, 'z');
      put(d / "Match-E", "huge.rec", big, 300);
      cfg.raw_fallback = true;
      core::State st;
      log.clear();
      auto n = core::sync_once(cfg, st, lg);
      CHECK(n.failed >= 1 && any_has(log, "too large to send whole"));
    }
  }

  SECTION("a failed round is retried when the reader improves");
  {
    const std::string r = slurp(fs::path(samples) / "ranked_2.rec");
    fs::path d = fs::path(tmp) / "retry";
    put(d / "Match-F", "later.rec", r, 300);
    const std::string sha = core::sha256_file(d / "Match-F" / "later.rec");
    core::Config cfg; cfg.server = url3; cfg.token = UP; cfg.folder = d; cfg.raw_fallback = false;
    std::vector<std::string> log;
    auto lg = [&](const std::string& s) { log.push_back(s); };
    // An older reader failed on a new operator and the server holds that failure.
    CHECK(plat::http_post_json(url3 + "/v1/parsed", UP, core::failure_payload("later.rec", sha, r.size(), "panic: role unknown for operator ID 123456789")).status == 200);
    // This reader fails on it too (simulated): the failure is kept, not retried again by the same version.
    setenv("R6_DISSECT", reader_script("failing_reader.sh", "echo 'panic: role unknown for operator ID 123456789'\necho 'goroutine 1 [running]:'\nexit 2\n").c_str(), 1);
    core::State st;
    auto n = core::sync_once(cfg, st, lg);
    CHECK(n.parsed == 0 && n.local == 0 && any_has(log, "role unknown") && any_has(log, "reader does not know"));
    CHECK(core::is_done(st, sha) && st.at(sha) == std::string("failed:") + core::kParserVersion);
    log.clear();
    CHECK(core::sync_once(cfg, st, lg).uploaded() == 0 && log.empty());
    // A new reader version (an updated uploader), simulated by a fresh memory and the real reader: the failure is replaced.
    setenv("R6_DISSECT", realReader.c_str(), 1);
    core::State later;
    log.clear();
    n = core::sync_once(cfg, later, lg);
    CHECK(n.parsed == 1 && n.local == 1 && any_has(log, "on this PC"));
    auto rounds = plat::http_get(url3 + "/v1/rounds?after=0", RD).body;
    CHECK(rounds.find("The PC could not read this replay") == std::string::npos && rounds.find("\"status\":\"parsed\"") != std::string::npos);
    CHECK(core::is_done(later, core::sha256_file(d / "Match-F" / "later.rec")));
    const std::string v = core::kParserVersion;
    CHECK(!core::is_done({{"h", "failed"}}, "h") && !core::is_done({{"h", "failed:0.9.0"}}, "h") && core::is_done({{"h", "failed:" + v}}, "h"));
    CHECK(core::is_done({{"h", "parsed"}}, "h") && !core::is_done({{"h", "invalid:0.9.0"}}, "h") && core::is_done({{"h", "invalid:" + v}}, "h"));
  }

  SECTION("when the server needs a newer reader, or refuses the data");
  {
    const std::string r = slurp(fs::path(samples) / "ranked_2.rec");
    fs::path d = fs::path(tmp) / "refused";
    put(d / "Match-G", "r1.rec", r, 300);
    core::Config cfg; cfg.token = UP; cfg.folder = d;
    std::vector<std::string> log;
    auto lg = [&](const std::string& s) { log.push_back(s); };
    {   // HTTP 426: the message is shown, the pass stops, and the replay waits for an updated uploader
      cfg.server = getenv_s("R6_OLD_URL");
      core::State st;
      auto n = core::sync_once(cfg, st, lg);
      CHECK(n.update_needed && n.error == 1 && n.parsed == 0);
      CHECK(any_has(log, "Please update your uploader") && n.update_message.find("9.0.0") != std::string::npos);
      CHECK(!core::is_done(st, core::sha256_file(d / "Match-G" / "r1.rec")));
    }
    {   // HTTP 422: the server's reason is shown, and the same reader does not send it again
      cfg.server = getenv_s("R6_STRICT_URL");
      core::State st;
      log.clear();
      auto n = core::sync_once(cfg, st, lg);
      CHECK(n.rejected == 1 && !n.update_needed && any_has(log, "did not accept the data") && any_has(log, "exactly 2 teams"));
      CHECK(core::is_done(st, core::sha256_file(d / "Match-G" / "r1.rec")));
      log.clear();
      CHECK(core::sync_once(cfg, st, lg).uploaded() == 0 && log.empty());
    }
  }

  SECTION("a reader this PC cannot run");
  {
    // A reader that crashes at once with no output, the way an older Windows refuses a newer program.
    setenv("R6_DISSECT", reader_script("crashing_reader.sh", "kill -SEGV $$\n").c_str(), 1);
    const std::string q = slurp(fs::path(samples) / "quick_1.rec");
    fs::path d = fs::path(tmp) / "unusable";
    put(d / "Match-H", "u1.rec", q, 300);
    core::Config cfg; cfg.server = url3; cfg.token = UP; cfg.folder = d;   // server 3 has not seen quick_1
    std::vector<std::string> log;
    auto lg = [&](const std::string& s) { log.push_back(s); };
    core::State st;
    auto n = core::sync_once(cfg, st, lg);
    CHECK(n.local == 0 && n.error == 0 && n.uploaded() == 1 && any_has(log, "Cannot read replays here") && any_has(log, "the old way"));
    CHECK(any_has(log, "Upload complete"));   // and the replay still arrived, whole
    setenv("R6_DISSECT", realReader.c_str(), 1);
  }

  // The old way: with no reader next to the program, whole files go to the server (and an old server gets them the same way).
  setenv("R6_DISSECT", "", 1);
  SECTION("uploading real replays (reader missing: whole files)");
  {
    fs::path d = fs::path(tmp) / "live";
    std::string q = slurp(fs::path(samples) / "quick_1.rec"), r = slurp(fs::path(samples) / "ranked_2.rec"), bad = slurp(fs::path(samples) / "corrupted.rec");
    put(d / "Match-A", "R01.rec", q, 300);
    put(d / "Match-B", "R05.rec", r, 200);
    core::Config cfg; cfg.server = url2; cfg.token = UP; cfg.folder = d;
    core::State st;
    std::vector<std::string> log;
    auto lg = [&](const std::string& s) { log.push_back(s); };
    auto n = core::sync_once(cfg, st, lg);
    CHECK(n.parsed == 2 && n.error == 0 && n.uploaded() == 2);
    CHECK(any_has(log, "R01.rec: parsed") && any_has(log, "R05.rec: parsed"));
    CHECK(any_has(log, "reader could not be unpacked") && n.local == 0);
    CHECK(any_has(log, "Uploading 1 of 2: R01.rec") && any_has(log, "Upload complete") && any_has(log, "MB/s") && any_has(log, "R01.rec: 50%"));   // start, percentage, speed, outcome
    CHECK(any_has(log, "Done: 2 uploaded"));
    CHECK(slurp(core::log_file_path()).find("Upload complete") != std::string::npos);   // kept in the log file too
    CHECK(core::human_size(9854768) == "9.4 MB" && core::human_speed(3.2 * 1048576) == "3.2 MB/s" && core::human_speed(51200) == "50 KB/s");
    log.clear();
    n = core::sync_once(cfg, st, lg);
    CHECK(n.uploaded() == 0 && log.empty());   // nothing new: nothing sent
    CHECK(core::load_state().size() >= 2);     // remembered on disk too

    put(d, "copy-of-R01.rec", q, 100);
    n = core::sync_once(cfg, st, lg);
    CHECK(n.uploaded() == 0 && n.skipped == 0);   // same bytes as R01.rec, so the same replay: nothing to send
    CHECK(core::scan(d, st).empty());

    put(d, "notes.rec", "this is not a replay", 100);
    auto stats_before = plat::http_get(url2 + "/v1/stats", RD).body;
    log.clear();
    n = core::sync_once(cfg, st, lg);
    CHECK(n.skipped == 1 && n.uploaded() == 0);
    CHECK(any_has(log, "notes.rec: NOT uploaded") && any_has(log, "starts with 74 68 69 73") && any_has(log, "28 B5 2F FD") && any_has(log, "dissect"));   // says why, with the first bytes
    CHECK(plat::http_get(url2 + "/v1/stats", RD).body == stats_before);   // it never left the PC

    // A big batch of non-replays is summarised, not listed 159 times.
    for (int i = 0; i < 6; i++) put(d / "Other", "x" + std::to_string(i) + ".rec", "not a replay " + std::to_string(i), 100);
    log.clear();
    n = core::sync_once(cfg, st, lg);
    CHECK(n.skipped == 6 && log.size() == 4 && any_has(log, "and 3 more files"));

    put(d, "broken.rec", bad, 100);
    log.clear();
    n = core::sync_once(cfg, st, lg);
    CHECK(n.failed == 1 && any_has(log, "broken.rec: failed"));
    CHECK(core::sync_once(cfg, st, lg).uploaded() == 0);   // a failed file is not retried forever

    SECTION("  problems on the way");
    put(d, "later.rec", r + "x", 100);   // different bytes: not a duplicate; not a valid replay though it starts right
    for (auto* who : {"wrong", "read"}) {
      core::Config bc = cfg; bc.token = std::string(who) == "wrong" ? "bad-token" : RD;
      log.clear();
      auto e = core::sync_once(bc, st, lg);
      const char* want = std::string(who) == "wrong" ? "rejected the upload token" : "READ token";
      CHECK(e.error == 1 && any_has(log, want));
      CHECK(core::scan(d, st).size() == 1);   // and the file is still waiting
      if (!(e.error == 1 && any_has(log, want))) { std::printf("    [%s] error=%d log:", who, e.error); for (auto& l : log) std::printf(" | %s", l.c_str()); std::printf("\n"); }
    }
    core::Config down = cfg; down.server = "http://127.0.0.1:1";
    log.clear();
    auto e = core::sync_once(down, st, lg);
    CHECK(e.error == 1 && any_has(log, "Will try again"));
    CHECK(core::scan(d, st).size() == 1);   // the file is still waiting
    n = core::sync_once(cfg, st, lg);        // server is back
    CHECK(n.uploaded() == 1);
    CHECK(core::scan(d, st).empty());

    core::Config gone = cfg; gone.folder = fs::path(tmp) / "no-such-folder";
    log.clear();
    core::sync_once(gone, st, lg);
    CHECK(any_has(log, "folder is missing"));
  }

  SECTION("what the server already has");
  {
    // The usual shape: a root folder, one folder per match, several .rec in each.
    fs::path d = fs::path(tmp) / "root";
    std::string q = slurp(fs::path(samples) / "quick_1.rec"), r = slurp(fs::path(samples) / "ranked_2.rec");
    core::Config cfg; cfg.server = url2; cfg.token = UP; cfg.folder = d;
    std::vector<std::string> log;
    auto lg = [&](const std::string& s) { log.push_back(s); };
    put(d / "Match-2026-01", "R01.rec", q + "", 400);
    put(d / "Match-2026-01", "R02.rec", r, 390);
    put(d / "Match-2026-02", "R01.rec", q, 300);   // the same bytes as another match's R01: still one replay
    core::State fresh;   // a brand-new install: it remembers nothing
    auto stats0 = plat::http_get(url2 + "/v1/stats", RD).body;
    auto n = core::sync_once(cfg, fresh, lg);
    CHECK(n.known >= 2 && n.parsed == 0 && n.uploaded() == 0 && n.error == 0);   // both are already on the server from the earlier section
    CHECK(plat::http_get(url2 + "/v1/stats", RD).body == stats0);                 // and nothing was sent again
    CHECK(any_has(log, "already on the server"));
    log.clear();
    CHECK(core::sync_once(cfg, fresh, lg).known == 0 && log.empty());           // remembered now

    // A new match folder appears while the app runs.
    put(d / "Match-2026-03", "R01.rec", q + "tail", 100);   // a different file the server has never seen
    CHECK(core::scan(d, fresh).size() == 1);
    n = core::sync_once(cfg, fresh, lg);
    CHECK(n.uploaded() == 1 && n.known == 0);   // it is not a valid replay, so the server marks it failed, but it was sent once
    CHECK(core::sync_once(cfg, fresh, lg).uploaded() == 0);

    // A server from before /v1/known existed answers 404 to it: the files are just sent, and it ignores duplicates.
    const std::string legacyUrl = getenv_s("R6_LEGACY_URL");
    CHECK(plat::http_post_json(legacyUrl + "/v1/known", UP, "{\"hashes\":[]}").status == 404);
    core::Config old = cfg; old.server = legacyUrl;
    core::State legacy;
    log.clear();
    n = core::sync_once(old, legacy, lg);
    CHECK(n.error == 0 && n.known == 0 && n.duplicate >= 2);   // R01, R02 were already stored: the server says duplicate
    CHECK(core::sync_once(old, legacy, lg).uploaded() == 0);
  }

  SECTION("noticing new files");
  {
    fs::path d = fs::path(tmp) / "watched";
    fs::create_directories(d);
    core::Watcher w(d, 1);
    CHECK(w.wait_settled(1500));              // what is already there counts once
    CHECK(!w.wait_settled(1500));             // then quiet
    put(d / "Match-9", "R01.rec", "x", 0);
    CHECK(w.wait_settled(4000));              // a file in a new subfolder is noticed and the wait ends once it settles
    CHECK(!w.wait_settled(1500));
    core::Watcher late(fs::path(tmp) / "not-yet", 1);
    CHECK(!late.wait_settled(600));           // folder missing: no error, nothing to report
    fs::create_directories(fs::path(tmp) / "not-yet");
    CHECK(late.wait_settled(4000));           // the game created it later and the watcher found it
  }

  std::printf("\n%d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
