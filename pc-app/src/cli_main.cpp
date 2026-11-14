// Console commands: the same program logic for scripting and testing.  R6ReplayUploader.exe <command>
// In the Windows build they live in the one program (see gui_main.cpp); on Linux they build as a console program for tests.
#include <algorithm>
#include <cstdio>
#include <iostream>
#include <thread>

#include <fstream>
#include <set>
#include <sstream>

#include "core.hpp"
#include "clips.hpp"
#include "highlights.hpp"
#include "json.hpp"
#include "platform.hpp"

static const char* kReaderLicense = "MIT License\n\nCopyright (c) 2022 Benjamin Ryan\n\nPermission is hereby granted, free of charge, to any person obtaining a copy\nof this software and associated documentation files (the \"Software\"), to deal\nin the Software without restriction, including without limitation the rights\nto use, copy, modify, merge, publish, distribute, sublicense, and/or sell\ncopies of the Software, and to permit persons to whom the Software is\nfurnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all\ncopies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\nIMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\nFITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\nAUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\nLIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\nOUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\nSOFTWARE.\n";

static void out(const std::string& s) { std::fputs((s + "\n").c_str(), stdout); std::fflush(stdout); }

static std::string arg(int argc, char** argv, const std::string& name) {
  for (int i = 2; i + 1 < argc; i++)
    if (argv[i] == name) return argv[i + 1];
  return {};
}
static bool flag(int argc, char** argv, const std::string& name) {
  for (int i = 2; i < argc; i++)
    if (argv[i] == name) return true;
  return false;
}

int cli_run(int argc, char** argv) {
  std::string cmd = argc > 1 ? argv[1] : "help";
  if (cmd == "version") { out(core::kVersion); return 0; }
  if (cmd == "discover") {
    auto f = core::discover();
    if (f.empty()) out("No MatchReplay folder found.");
    for (auto& p : f) out(plat::to_utf8(p.first.wstring()) + "   (" + std::to_string(p.second) + " replay files)");
    return 0;
  }
  if (cmd == "setup") {
    core::Config c;
    core::load_config(c);
    if (!arg(argc, argv, "--server").empty()) c.server = core::normalize_url(arg(argc, argv, "--server"));
    if (!arg(argc, argv, "--token").empty()) c.token = arg(argc, argv, "--token");
    if (!arg(argc, argv, "--folder").empty()) c.folder = core::fs::path(plat::from_utf8(arg(argc, argv, "--folder")));
    if (c.folder.empty()) { auto f = core::discover(); if (!f.empty()) c.folder = f[0].first; }
    std::string msg;
    bool ok = core::check_server(c.server, c.token, msg);
    out(msg);
    if (!ok) return 1;
    if (c.folder.empty() || !core::fs::is_directory(c.folder)) { out("The replay folder does not exist."); return 1; }
    core::save_config(c);
    out("Saved. Folder: " + plat::to_utf8(c.folder.wstring()));
    return 0;
  }
  if (cmd == "once" || cmd == "run") {
    core::Config c;
    if (!core::load_config(c) || !c.configured()) { out("Not set up yet. Run: setup --server ... --token ..."); return 2; }
    auto st = core::load_state();
    core::Watcher watcher(c.folder);
    do {
      auto n = core::sync_once(c, st, out);
      if (cmd == "once") { out("done: " + std::to_string(n.parsed) + " parsed, " + std::to_string(n.duplicate) + " duplicate, " + std::to_string(n.known) + " already on the server, " + std::to_string(n.failed) + " failed, " + std::to_string(n.error) + " errors"); return n.error ? 1 : 0; }
      watcher.wait_settled(c.poll * 1000);   // a finished replay wakes this early; otherwise check every poll
    } while (true);
  }
  if (cmd == "parse") {   // reads one replay the way the app does and says what would be sent. Nothing is uploaded.
    if (argc < 3) { out("usage: parse <file.rec>"); return 2; }
    const core::fs::path rec(plat::from_utf8(argv[2]));
    const std::string sha = core::sha256_file(rec);
    const auto size = (uint64_t)core::fs::file_size(rec);
    const auto r = core::read_replay(rec, sha, size);
    if (r.helper_unusable) { out("The replay reader cannot run here: " + r.reason); return 3; }
    if (!r.ok) { out("Could not read it: " + r.reason); return 1; }
    out("read in " + std::to_string(r.seconds).substr(0, 4) + " s: " + core::human_size(r.payload.size()) + " to send instead of " + core::human_size(size));
    if (flag(argc, argv, "--show")) out(r.payload);
    return 0;
  }
  if (cmd == "status") {
    core::Config c;
    core::load_config(c);
    auto st = core::load_state();
    std::map<std::string, int> by;
    for (auto& kv : st)
      if (kv.first.size() == 64) by[kv.second]++;
    out("server: " + c.server + "\nfolder: " + plat::to_utf8(c.folder.wstring()));
    std::string s;
    for (auto& kv : by) s += std::to_string(kv.second) + " " + kv.first + "  ";
    out("uploaded: " + (s.empty() ? std::string("nothing yet") : s));
    return 0;
  }
  if (cmd == "highlights") {   // finds your best moments in replays. Reads only; nothing is uploaded.
    // highlights <file or folder>... [--player name,alias] [--min-score N] [--out highlights.json]
    std::vector<core::fs::path> files;
    std::set<std::string> valueArgs = {"--player", "--min-score", "--out"};
    for (int i = 2; i < argc; i++) {
      if (valueArgs.count(argv[i])) { i++; continue; }
      const core::fs::path p(plat::from_utf8(argv[i]));
      std::error_code ec;
      if (core::fs::is_directory(p, ec)) {
        for (const auto& e : core::fs::recursive_directory_iterator(p, ec))
          if (e.is_regular_file() && (e.path().extension() == ".rec" || e.path().extension() == ".json")) files.push_back(e.path());
      } else if (core::fs::is_regular_file(p, ec)) files.push_back(p);
    }
    if (files.empty()) { out("usage: highlights <replay folder, .rec or .json>... [--player name,alias] [--min-score N] [--out highlights.json]"); return 2; }
    std::sort(files.begin(), files.end());
    // Each file gives one or more rounds: a .rec through the reader; a .json from r6-dissect, the uploader, or the server's list.
    std::vector<mini::Json> rounds;
    int unreadable = 0, skippedOnServer = 0;
    auto addRound = [&](const std::string& text) {
      std::string err;
      const std::string t = core::trim_round(text, err);
      mini::Json j;
      if (t.empty() || !mini::parse(t, j)) { unreadable++; return; }
      rounds.push_back(j);
    };
    for (const auto& f : files) {
      if (f.extension() == ".rec") {
        const auto r = core::read_replay(f, core::sha256_file(f), (uint64_t)core::fs::file_size(f));
        if (r.helper_unusable) { out("The replay reader cannot run here: " + r.reason); return 3; }
        mini::Json j;
        if (!r.ok || !mini::parse(r.payload, j)) { unreadable++; continue; }
        rounds.push_back(j.at("round"));
        continue;
      }
      std::ifstream in(f, std::ios::binary);
      std::stringstream ss;
      ss << in.rdbuf();
      mini::Json j;
      if (!mini::parse(ss.str(), j)) { unreadable++; continue; }
      const mini::Json& list = j.type == mini::Json::Arr ? j : j.at("rounds");
      if (list.type == mini::Json::Arr) {
        for (const auto& x : list.a) {
          if (!x.at("status").isNull() && x.at("status").str() != "parsed") { skippedOnServer++; continue; }   // failed there: no data
          const mini::Json& d = x.at("data").isNull() ? (x.at("round").isNull() ? x : x.at("round")) : x.at("data");
          if (d.type == mini::Json::Obj) addRound(mini::dump(d));
        }
      } else addRound(j.at("round").isNull() ? ss.str() : mini::dump(j.at("round")));
    }
    std::vector<std::string> me;
    const std::string given = arg(argc, argv, "--player");
    for (size_t a = 0; a <= given.size() && !given.empty();) {
      size_t b = given.find(',', a);
      if (b == std::string::npos) b = given.size();
      if (b > a) me.push_back(given.substr(a, b - a));
      a = b + 1;
    }
    if (me.empty()) me = hl::recorder_names(rounds);
    if (me.empty()) { out("Could not tell who you are from these replays. Add --player YourName"); return 2; }
    hl::Options opt;
    if (!arg(argc, argv, "--min-score").empty()) opt.min_score = std::atoi(arg(argc, argv, "--min-score").c_str());
    const auto list = hl::detect(rounds, me, opt);
    std::string names;
    for (const auto& n : me) names += (names.empty() ? "" : ", ") + n;
    out(std::to_string(rounds.size()) + " rounds read" + (unreadable ? ", " + std::to_string(unreadable) + " could not be read" : "") + (skippedOnServer ? ", " + std::to_string(skippedOnServer) + " skipped (the server could not read them)" : "") + ". Player: " + names + ". " + std::to_string(list.size()) + " highlights.");
    for (size_t i = 0; i < list.size() && i < 15; i++) out("  " + std::to_string(i + 1) + ". " + hl::describe(list[i]));
    const std::string dest = arg(argc, argv, "--out");
    if (!dest.empty()) {
      std::ofstream(core::fs::path(plat::from_utf8(dest)), std::ios::binary) << hl::to_json(list, me);
      out("Saved " + dest);
    }
    return 0;
  }
  if (cmd == "clip") {   // record and cut highlights:  clip matches | find N | start N | mark ROUND [--plant] [--at S] | stop | cut
    const std::string sub = argc > 2 ? argv[2] : "";
    core::Config c;
    core::load_config(c);
    if (!arg(argc, argv, "--port").empty()) c.obs_port = std::atoi(arg(argc, argv, "--port").c_str());
    if (!arg(argc, argv, "--password").empty()) c.obs_password = arg(argc, argv, "--password");
    if (!arg(argc, argv, "--folder").empty()) c.folder = core::fs::path(plat::from_utf8(arg(argc, argv, "--folder")));
    const auto currentFile = clips::sessions_dir() / L"current.txt";
    auto current = [&]() { std::ifstream in(currentFile); std::string id; std::getline(in, id); return id; };
    auto pick = [&](const std::string& which) -> core::fs::path {   // a number from "clip matches", or a folder
      const auto list = clips::match_folders(c.folder);
      const int n = std::atoi(which.c_str());
      if (n >= 1 && n <= (int)list.size()) return list[(size_t)n - 1].dir;
      return core::fs::path(plat::from_utf8(which));
    };
    auto connect = [&](clips::Obs& obs) {
      std::string err;
      if (obs.connect("127.0.0.1", c.obs_port, c.obs_password, err)) return true;
      out("OBS: " + err);
      return false;
    };
    if (sub == "matches") {
      const auto list = clips::match_folders(c.folder);
      if (list.empty()) out("No matches found in " + plat::to_utf8(c.folder.wstring()));
      for (size_t i = 0; i < list.size(); i++) out(std::to_string(i + 1) + ". " + list[i].name + "  (" + std::to_string(list[i].files) + " rounds)");
      return 0;
    }
    if (sub == "find" || sub == "start") {
      if (argc < 4) { out("usage: clip " + sub + " <match number from 'clip matches', or a folder>"); return 2; }
      std::string err;
      int bad = 0;
      const auto rounds = clips::read_match(pick(argv[3]), err, &bad);
      if (!err.empty()) { out(err); return 3; }
      if (rounds.empty()) { out("No rounds could be read in that folder."); return 1; }
      const auto me = hl::recorder_names(rounds);
      const auto list = hl::detect(rounds, me);
      const std::string id = rounds.front().at("matchID").str();
      std::ofstream(clips::sessions_dir() / plat::from_utf8(id + ".highlights.json"), std::ios::binary) << hl::to_json(list, me);
      out(std::to_string(rounds.size()) + " rounds" + (bad ? " (" + std::to_string(bad) + " unreadable)" : "") + ", " + std::to_string(list.size()) + " highlights:");
      for (const auto& h : list) out("  " + hl::describe(h));
      std::string marks;
      for (int r : clips::rounds_to_mark(list)) marks += (marks.empty() ? "" : ", ") + std::to_string(r);
      if (sub == "find") { out(list.empty() ? "Nothing to record in this match." : "Rounds to record: " + marks); return 0; }
      if (list.empty()) { out("Nothing to record in this match."); return 1; }
      clips::Obs obs;
      if (!connect(obs)) return 1;
      if (!obs.start_record(err)) { out("OBS: " + err); return 1; }
      clips::Session s;
      s.match_id = id;
      clips::save_session(s);
      std::ofstream(currentFile) << id;
      out("Recording. Open this match's replay in Siege and play rounds " + marks + ". When each round's timer starts, run: clip mark <round>");
      return 0;
    }
    clips::Session s;
    const std::string id = current();
    if (id.empty() || !clips::load_session(id, s)) { out("No match is being recorded. Start with: clip start <match>"); return 2; }
    if (sub == "mark") {
      if (argc < 4) { out("usage: clip mark <round> [--plant] [--at seconds]"); return 2; }
      const int round = std::atoi(argv[3]);
      double at = -1;
      if (!arg(argc, argv, "--at").empty()) at = std::atof(arg(argc, argv, "--at").c_str());
      else {
        clips::Obs obs;
        bool active = false;
        std::string err;
        if (!connect(obs) || !obs.record_time(at, active, err) || !active) { out(err.empty() ? "OBS is not recording." : "OBS: " + err); return 1; }
      }
      auto& m = s.rounds[round];
      (flag(argc, argv, "--plant") ? m.plant : m.start) = at;
      clips::save_session(s);
      out("Round " + std::to_string(round) + (flag(argc, argv, "--plant") ? " plant" : " timer start") + " marked at " + std::to_string(at).substr(0, 7) + " s");
      return 0;
    }
    if (sub == "stop") {
      clips::Obs obs;
      std::string err, path;
      if (!connect(obs)) return 1;
      if (!obs.stop_record(path, err)) { out("OBS: " + err); return 1; }
      s.recording = path;
      clips::save_session(s);
      out("Saved the recording: " + path);
      return 0;
    }
    if (sub == "cut") {
      if (!arg(argc, argv, "--recording").empty()) { s.recording = arg(argc, argv, "--recording"); clips::save_session(s); }
      if (s.recording.empty()) { out("No recording yet. Run: clip stop   (or give --recording <file>)"); return 2; }
      const std::string ffmpeg = clips::find_ffmpeg(arg(argc, argv, "--ffmpeg").empty() ? c.ffmpeg : arg(argc, argv, "--ffmpeg"));
      std::ifstream in(clips::sessions_dir() / plat::from_utf8(id + ".highlights.json"), std::ios::binary);
      std::string text((std::istreambuf_iterator<char>(in)), {});
      std::vector<hl::Highlight> list;
      if (!hl::from_json(text, list)) { out("The highlight list for this match is missing. Run: clip find <match>"); return 2; }
      const std::string dir = arg(argc, argv, "--out").empty() ? plat::to_utf8(((c.clips_dir.empty() ? clips::default_clips_dir() : c.clips_dir) / plat::from_utf8(id)).wstring()) : arg(argc, argv, "--out");
      int ok = 0;
      for (const auto& r : clips::cut_all(s, list, ffmpeg, dir, [&](int done, int total, const std::string& line) { out(std::to_string(done) + "/" + std::to_string(total) + "  " + line); }))
        ok += r.ok;
      out(std::to_string(ok) + " clips in " + dir);
      return ok ? 0 : 1;
    }
    if (sub == "upload") {
      if (c.server.empty() || c.token.empty()) { out("Set up the server first: setup --server ... --token ..."); return 2; }
      std::ifstream in(clips::sessions_dir() / plat::from_utf8(id + ".highlights.json"), std::ios::binary);
      std::string text((std::istreambuf_iterator<char>(in)), {});
      std::vector<hl::Highlight> list;
      if (!hl::from_json(text, list)) { out("The highlight list for this match is missing. Run: clip find <match>"); return 2; }
      const std::string dir = arg(argc, argv, "--out").empty() ? plat::to_utf8(((c.clips_dir.empty() ? clips::default_clips_dir() : c.clips_dir) / plat::from_utf8(id)).wstring()) : arg(argc, argv, "--out");
      const size_t piece = arg(argc, argv, "--piece").empty() ? 4u << 20 : (size_t)std::atoll(arg(argc, argv, "--piece").c_str());
      const auto u = clips::upload_clips(c.server, c.token, dir, list, [&](int done, int total, const std::string& line) { out(std::to_string(done) + "/" + std::to_string(total) + "  " + line); }, piece);
      out(std::to_string(u.sent) + " uploaded, " + std::to_string(u.already) + " already there, " + std::to_string(u.failed) + " failed" + (u.stopped ? ". Stopped: " + u.message : ""));
      return (u.stopped || u.failed) ? 1 : 0;
    }
    out("usage: clip matches | find <match> | start <match> | mark <round> [--plant] [--at s] | stop | cut [--recording file] [--out dir] | upload");
    return 2;
  }
  if (cmd == "licenses") {
    out("R6 Replay Uploader includes r6-dissect (https://github.com/redraskal/r6-dissect), used under the MIT licence:\n\n" + std::string(kReaderLicense));
    return 0;
  }
  out("commands: setup, once, run, parse, highlights, clip, discover, status, licenses, version");
  return 0;
}

#ifndef R6_ONE_EXE
int main(int argc, char** argv) { return cli_run(argc, argv); }   // the console build used by the tests on Linux
#endif
