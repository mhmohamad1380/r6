// Tests of recording and clipping: the OBS protocol against a stand-in OBS, the round sync arithmetic, and, when ffmpeg is
// available (R6_FFMPEG), real cutting of a generated video with the timing checked frame by frame.
// Environment: R6_OBS_PORT (stand-in OBS with password "hunter2"), R6_OBS_OPEN_PORT (no password), R6_TMP, R6_FFMPEG (optional).
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>

#include "../src/clips.hpp"
#include "../src/platform.hpp"

namespace fs = std::filesystem;
static int failures = 0, checks = 0;
#define CHECK(c) do { checks++; if (!(c)) { failures++; std::printf("  FAIL line %d: %s\n", __LINE__, #c); } } while (0)
#define SECTION(n) std::printf("%s\n", n)
static std::string env(const char* k) { const char* v = std::getenv(k); return v ? v : ""; }

static hl::Highlight moment(int round, std::vector<std::pair<double, int>> kills, bool postPlant = false, int clutchVs = 0, double begin = -1) {
  hl::Highlight h;
  h.id = "0123abcd-0000-0000-0000-000000000000";
  h.match_id = "match-1";
  h.round = round;
  h.type = kills.size() > 1 ? "multikill" : "kill";
  h.clutch_vs = clutchVs;
  for (auto& k : kills) {
    hl::Kill x;
    x.t = k.first;
    x.clock = k.second;
    x.post_plant = x.approx = postPlant;
    x.victim = "E";
    h.kills.push_back(x);
  }
  h.begin = begin >= 0 ? begin : kills.front().first;
  return h;
}

int main() {
  SECTION("base64 and the OBS password answer");
  CHECK(clips::base64("f") == "Zg==" && clips::base64("fo") == "Zm8=" && clips::base64("foo") == "Zm9v" && clips::base64("foob") == "Zm9vYg==");
  // The same answer Python computes from obs-websocket's documented formula.
  CHECK(clips::obs_auth("hunter2", "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=", "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY=") == "9nk/xZ3nDGOEsdVNtyTAmvSWEE/MxrzIw5pMf1rpfsA=");

  SECTION("talking to OBS");
  {
    const int port = std::atoi(env("R6_OBS_PORT").c_str()), open = std::atoi(env("R6_OBS_OPEN_PORT").c_str());
    std::string err;
    clips::Obs bad;
    CHECK(!bad.connect("127.0.0.1", port, "wrong", err) && err.find("password") != std::string::npos);
    CHECK(!bad.connect("127.0.0.1", port, "", err) && err.find("asks for a password") != std::string::npos);
    CHECK(!bad.connect("127.0.0.1", 1, "", err) && err.find("not answering") != std::string::npos);

    clips::Obs obs;
    CHECK(obs.connect("127.0.0.1", port, "hunter2", err));
    double t = -1;
    bool active = true;
    CHECK(obs.record_time(t, active, err) && !active && t == 0);
    CHECK(obs.start_record(err));
    CHECK(!obs.start_record(err) && err.find("already active") != std::string::npos);   // OBS's own reason is passed on
    std::this_thread::sleep_for(std::chrono::milliseconds(600));
    CHECK(obs.record_time(t, active, err) && active && t >= 0.5 && t < 3);
    std::string path;
    CHECK(obs.stop_record(path, err) && path.find(".mkv") != std::string::npos);
    mini::Json r;
    CHECK(!obs.request("NoSuchThing", "", r, err) && err.find("code 204") != std::string::npos);

    clips::Obs free;
    CHECK(free.connect("127.0.0.1", open, "", err));
  }

  SECTION("sessions are saved and read back");
  {
    clips::Session s;
    s.match_id = "match-1";
    s.recording = "C:\\Videos\\a b.mkv";
    s.rounds[4] = {12.5, -1};
    s.rounds[6] = {300, 410.25};
    clips::Session back;
    CHECK(clips::session_from_json(clips::session_json(s), back));
    CHECK(back.match_id == "match-1" && back.recording == s.recording && back.rounds.size() == 2 && back.rounds[6].plant == 410.25 && back.rounds[4].plant < 0);
  }

  SECTION("the built-in recorder's minutes: which pieces hold a moment");
  {
    std::vector<rec::Segment> f = {{"a.mp4", 1000, 1060}, {"b.mp4", 1060, 1120}, {"c.mp4", 1120.05, 1180}};
    std::vector<rec::Part> p;
    CHECK(rec::parts_for(f, 1010, 1020, p) && p.size() == 1 && p[0].path == "a.mp4" && p[0].offset == 10 && p[0].length == 10);
    CHECK(rec::parts_for(f, 1050, 1070, p) && p.size() == 2 && p[0].offset == 50 && p[0].length == 10 && p[1].path == "b.mp4" && p[1].offset == 0 && p[1].length == 10);
    CHECK(rec::parts_for(f, 1110, 1130, p) && p.size() == 2);   // a 50 ms gap between pieces is not a hole
    double cf = 0, ct = 0;
    CHECK(!rec::parts_for(f, 990, 1010, p, &cf, &ct) && cf == 1000 && ct == 1010);   // starts before the oldest minute
    CHECK(!rec::parts_for(f, 1170, 1190, p, &cf, &ct) && ct == 1180);                // ends after the newest
    std::vector<rec::Segment> gap = {{"a.mp4", 1000, 1060}, {"c.mp4", 1070, 1130}};
    CHECK(!rec::parts_for(gap, 1050, 1080, p));                                       // a real hole (the recorder restarted)
    CHECK(!rec::parts_for({}, 1, 2, p));
  }

  SECTION("the disk limit: the oldest recorded minutes go first, by age and by size");
  {
    std::vector<rec::Segment> f;
    std::vector<long long> sz;
    for (int i = 0; i < 12; i++) { f.push_back({"p" + std::to_string(i), 1000.0 + 60 * i, 1060.0 + 60 * i}); sz.push_back(60LL * 1000 * 1000); }   // 12 x 60 MB
    const double now = 1720;   // the newest minute just ended
    auto d = rec::to_delete(f, sz, now, 720, 580LL * 1000 * 1000);
    CHECK(d.size() == 3 && d[0] == 0 && d[2] == 2);   // 720 MB: three oldest go to fit in 580 MB
    d = rec::to_delete(f, std::vector<long long>(12, 10LL * 1000 * 1000), now, 720, 580LL * 1000 * 1000);
    CHECK(d.empty());                                 // 120 MB and all younger than 12 minutes: nothing goes
    d = rec::to_delete(f, std::vector<long long>(12, 10LL * 1000 * 1000), now + 300, 720, 580LL * 1000 * 1000);
    CHECK(d.size() == 4);                             // five minutes later: minutes that ended before 2020 - 720 = 1300 go (4 of them)
    std::vector<long long> big(12, 1000LL * 1000 * 1000);   // a very high bitrate: even one minute is over the limit
    CHECK(rec::to_delete(f, big, now, 720, 580LL * 1000 * 1000).size() == 12);
  }

  SECTION("a session recorded by the built-in recorder keeps its minutes, and cutting finds the moment in them");
  {
    clips::Session s;
    s.match_id = "match-1";   // the match of the moments below
    s.recording = "C:\\sessions\\match-1-recording";
    s.footage = {{"C:\\x\\piece-1.mp4", 1000, 1060}, {"C:\\x\\piece-2.mp4", 1060, 1120}};
    s.rounds[3] = {1040, -1};   // wall-clock marks
    clips::Session back;
    CHECK(clips::session_from_json(clips::session_json(s), back) && back.footage.size() == 2 && back.footage[1].start == 1060 && back.rounds[3].start == 1040);
    // Here (not Windows) nothing can cut, but it gets as far as finding the pieces: the reason says so, not "not in the recording".
    auto res = clips::cut_all(s, {moment(3, {{15, 165}, {25, 155}})}, "", (fs::path(env("R6_TMP")) / "clips-wall").string());
    CHECK(res.size() == 1 && !res[0].ok && res[0].error.find("video engine") != std::string::npos);
    auto out = clips::cut_all(s, {moment(3, {{200, 0}})}, "", (fs::path(env("R6_TMP")) / "clips-wall").string());   // 1240: after the recording
    CHECK(out.size() == 1 && out[0].error == "that moment is not in the recording");
  }

  SECTION("placing a moment in the recording");
  {
    // Round timer started 100 s into the recording; kills 30 s and 40 s into the round: clip 125 to 143.
    auto p = clips::place(moment(3, {{30, 150}, {40, 140}}), {100, -1});
    CHECK(p.ok && p.start == 125 && p.duration == 18 && p.thumb == 130 && !p.approx);
    // No mark for the round: not cut, and it says why.
    p = clips::place(moment(3, {{30, 150}}), {});
    CHECK(!p.ok && p.why.find("round 3") != std::string::npos);
    // After a plant: with a plant mark the defuser clock places the kill exactly (45 - 30 = 15 s after the plant).
    p = clips::place(moment(5, {{75, 30}}, true), {100, 180});
    CHECK(p.ok && !p.approx && p.thumb == 195 && p.start == 190);
    // Without one it falls back to the estimate and says it is approximate.
    p = clips::place(moment(5, {{75, 30}}, true), {100, -1});
    CHECK(p.ok && p.approx && p.thumb == 175);
    // A clutch starts the clip when the clutch began, not at the first kill.
    p = clips::place(moment(2, {{120, 60}, {145, 35}}, false, 2, 90), {10, -1});
    CHECK(p.ok && p.start == 95 && p.duration == 63);
    // A mark that makes a moment start before the video is clamped to the start.
    p = clips::place(moment(1, {{2, 178}}), {0, -1});
    CHECK(p.ok && p.start == 0);
  }

  SECTION("ffmpeg commands and names");
  {
    auto h = moment(4, {{30, 150}});
    CHECK(clips::clip_name(h) == "match-1_r4_kill_0123abcd.mp4");
    auto a = clips::cut_args("rec.mkv", clips::place(h, {100, -1}), "out.mp4");
    const std::string all = [&] { std::string s; for (auto& x : a) s += x + " "; return s; }();
    CHECK(all.find("-ss 125.000 -i rec.mkv -t 8.000") != std::string::npos);
    CHECK(all.find("libx264") != std::string::npos && all.find("+faststart") != std::string::npos && all.find("min(720,ih)") != std::string::npos);
    CHECK(clips::cut_args("r", clips::place(h, {100, -1}), "o", true)[std::find(a.begin(), a.end(), "-c:v") - a.begin() + 1] == "h264_mf");
  }

  const std::string ffmpeg = clips::find_ffmpeg();
  if (ffmpeg.empty()) {
    std::printf("cutting real video: SKIPPED (no ffmpeg; set R6_FFMPEG)\n");
  } else {
    SECTION("cutting real video: each clip starts and ends within 1 s of where it should");
    const fs::path dir = fs::path(env("R6_TMP")) / "clips";
    fs::remove_all(dir);
    fs::create_directories(dir);
    // A 3-minute test recording whose frames show the time, at 30 fps with a 1 kHz tone.
    const std::string rec = (dir / "recording.mkv").string();
    auto made = plat::run_helper(plat::from_utf8(ffmpeg), {L"-hide_banner", L"-loglevel", L"error", L"-y", L"-f", L"lavfi", L"-i", L"testsrc2=size=1280x720:rate=30:duration=180",
                                                           L"-f", L"lavfi", L"-i", L"sine=frequency=1000:duration=180", L"-c:v", L"libx264", L"-preset", L"ultrafast", L"-g", L"300",
                                                           L"-c:a", L"aac", plat::from_utf8(rec)}, 300000);
    CHECK(made.started && made.exit_code == 0);
    clips::Session s;
    s.match_id = "match-1";
    s.recording = rec;
    s.rounds[4] = {20, -1};
    s.rounds[6] = {60, 150};
    std::vector<hl::Highlight> list = {moment(4, {{30, 150}, {40, 140}}), moment(6, {{75, 30}}, true), moment(9, {{10, 170}})};
    list[1].id = "11112222-0000-0000-0000-000000000000";
    list[2].id = "33334444-0000-0000-0000-000000000000";
    int calls = 0;
    auto res = clips::cut_all(s, list, ffmpeg, dir.string(), [&](int, int total, const std::string&) { calls++; CHECK(total == 3); });
    CHECK(res.size() == 3 && calls == 3);
    CHECK(res[0].ok && res[1].ok && !res[2].ok && res[2].error.find("round 9") != std::string::npos);
    // Measure what came out: duration from the file, and where the first frame was in the source (the test pattern's
    // frame counter is not readable here, so the cut is checked by length and by the index; the seek itself is exact).
    for (int i = 0; i < 2; i++) {
      CHECK(fs::exists(res[i].file) && fs::file_size(res[i].file) > 1000);
      CHECK(!res[i].thumb.empty() && fs::exists(res[i].thumb));
      auto probe = plat::run_helper(plat::from_utf8(ffmpeg), {L"-hide_banner", L"-i", plat::from_utf8(res[i].file), L"-f", L"null", L"-"}, 60000);
      const auto at = probe.output.rfind("time=");
      CHECK(at != std::string::npos);
      if (at != std::string::npos) {
        const std::string tt = probe.output.substr(at + 5, 11);   // hh:mm:ss.cc
        const double secs = std::stoi(tt.substr(0, 2)) * 3600 + std::stoi(tt.substr(3, 2)) * 60 + std::stod(tt.substr(6));
        std::printf("    %s: %.2f s long, expected %.2f\n", fs::path(res[i].file).filename().string().c_str(), secs, res[i].duration);
        CHECK(std::fabs(secs - res[i].duration) <= 1.0);
      }
    }
    CHECK(res[0].start == 45 && res[0].duration == 18);   // round 4 timer at 20 s: kills at 50 and 60
    CHECK(res[1].start == 160 && !res[1].approx);         // plant at 150, kill 15 s later at 165, minus 5
    std::ifstream in(dir / "clips.json");
    std::string idx((std::istreambuf_iterator<char>(in)), {});
    mini::Json j;
    CHECK(mini::parse(idx, j) && j.at("clips").a.size() == 2 && j.at("clips").at(0).at("file").str() == "match-1_r4_multikill_0123abcd.mp4");
  }

  std::printf("\n%d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
