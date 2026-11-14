#include "live.hpp"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <thread>

#include <algorithm>

#include "json.hpp"
#include "platform.hpp"

namespace live {

namespace fs = std::filesystem;
using mini::quote;

double wall_now() {
  return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
}

// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
static long long days_from_civil(int y, int m, int d) {
  y -= m <= 2;
  const long long era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = (unsigned)(y - era * 400);
  const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + (long long)doe - 719468;
}

double parse_utc(const std::string& iso) {
  int y, mo, d, h, mi;
  double s;
  if (std::sscanf(iso.c_str(), "%d-%d-%dT%d:%d:%lf", &y, &mo, &d, &h, &mi, &s) != 6) return -1;
  if (iso.find('Z') == std::string::npos && iso.find("+00:00") == std::string::npos) return -1;   // only UTC times are trusted
  return (double)days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s;
}

double default_offset(const std::string& mode) {
  // Operator selection plus the preparation phase. A guess: one key press replaces it with the real value.
  return mode == "QuickMatch" ? 45 : 60;
}

void Clipper::configure(const Settings& s) {
  std::lock_guard<std::mutex> g(mu_);
  const bool reconnect = s.obs_port != s_.obs_port || s.obs_password != s_.obs_password;
  s_ = s;
  if (reconnect) {
    std::lock_guard<std::mutex> o(obs_mu_);
    obs_.close();
  }
}

Settings Clipper::settings() {
  std::lock_guard<std::mutex> g(mu_);
  return s_;
}

bool Clipper::connect(std::string& error) {   // obs_mu_ held
  if (obs_.connected()) return true;
  const Settings s = settings();
  return obs_.connect("127.0.0.1", s.obs_port, s.obs_password, error);
}

std::string Clipper::keep_buffer(bool game_running) {
  const Settings s = settings();
  if (builtin()) {
    bool idle;
    {
      std::lock_guard<std::mutex> g(mu_);
      idle = jobs_.empty();
    }
    if (!s.enabled || !game_running) {
      if (startedRecorder_ && recorder_->running() && idle) {   // the game closed: stop recording (after the last cuts)
        recorder_->stop();
        startedRecorder_ = false;
      }
      return s.enabled ? "Live clips: waiting for Siege to start." : "Live clips are off.";
    }
    if (!recorder_->running()) {
      std::string err;
      if (!recorder_->start(recorder_options, err)) return "Live clips: the recorder could not start: " + err;
      startedRecorder_ = true;
      say("Live clips: recording started (built-in recorder).");
    }
    return "Live clips: " + recorder_->status();
  }
  if (!s.enabled) return "Live clips are off.";
  if (!game_running) return "Live clips: waiting for Siege to start.";
  std::lock_guard<std::mutex> o(obs_mu_);
  std::string err;
  if (!connect(err)) return "Live clips: " + err;
  bool active = false;
  // When the replay buffer is not enabled in OBS's settings, even asking about it fails: try to start it either way.
  if (obs_.replay_buffer_active(active, err) && active) { warned_buffer_ = false; return "Live clips: recording (OBS replay buffer on)."; }
  if (!obs_.connected()) return "Live clips: lost the connection to OBS (" + err + ").";
  if (obs_.start_replay_buffer(err)) { say("Live clips: started OBS's replay buffer."); return "Live clips: recording (OBS replay buffer on)."; }
  if (!warned_buffer_) say("Live clips: OBS would not start its replay buffer (" + err + "). In OBS: Settings > Output > Replay Buffer > tick Enable, and set it to 10 minutes.");
  warned_buffer_ = true;
  return "Live clips: turn on OBS's replay buffer (Settings > Output > Replay Buffer).";
}

void Clipper::calibrate_now() {
  std::lock_guard<std::mutex> g(mu_);
  press_ = now();
  say("Live clips: marked the round timer start. It is used when this round's replay arrives.");
}

void Clipper::on_round(const std::string& round_json, double replay_written) {
  Settings s = settings();
  if (!s.enabled) return;
  mini::Json r;
  if (!mini::parse(round_json, r) || r.type != mini::Json::Obj) return;
  const double start = parse_utc(r.at("timestamp").str());
  const double t = now();
  if (start < 0 || t - start > 15 * 60 || t < start) return;   // an old round (catching up on files), or a clock problem
  const std::string mode = r.at("matchType").type == mini::Json::Obj ? r.at("matchType").at("name").str() : r.at("matchType").str();

  // Calibration: a key press during this round tells how long after the round's start its timer began.
  {
    std::lock_guard<std::mutex> g(mu_);
    if (press_ >= start && press_ <= start + 420) {
      const double off = press_ - start;
      s_.offsets[mode] = off;
      s = s_;
      press_ = -1;
      char b[160];
      std::snprintf(b, sizeof b, "Live clips: calibrated for %s. The round timer starts %.0f s after a round begins; clips are now exact.", mode.c_str(), off);
      say(b);
      if (on_settings_changed) on_settings_changed(s_);
    }
  }
  const auto it = s.offsets.find(mode);
  const bool calibrated = it != s.offsets.end();
  {
    // One line per round, kept in the log: from a few of these the gap between a round's start and its timer can be
    // worked out without the calibration key (a round that ends in a wipe ends at its last kill).
    int lastClock = -1, kills = 0;
    for (const auto& e : r.at("matchFeedback").a) {
      const std::string ty = e.at("type").type == mini::Json::Obj ? e.at("type").at("name").str() : e.at("type").str();
      if (ty == "Kill") { kills++; lastClock = (int)e.at("timeInSeconds").num(-1); }
    }
    char b[240];
    std::snprintf(b, sizeof b, "Live clips timing: %s round %d, began %.0f, replay written %+.1f s after that, %d kills, last at clock %d, offset %s",
                  mode.c_str(), (int)r.at("roundNumber").num(0) + 1, start, replay_written > 0 ? replay_written - start : -1.0, kills, lastClock,
                  calibrated ? std::to_string(it->second).c_str() : "not calibrated");
    if (timing_log) timing_log(b);
  }
  hl::Options opt;
  if (!calibrated) { opt.pad_before = 12; opt.pad_after = 6; }   // a guess: wider clips so the moment is inside
  const auto me = hl::recorder_names({r});
  std::vector<hl::Highlight> list;
  for (const auto& h : hl::detect_round(r, me, opt))
    if (h.score >= s.min_score) list.push_back(h);
  if (list.empty()) return;

  Job j;
  j.list = list;
  j.match_id = list[0].match_id;
  j.round = list[0].round;
  j.mode = mode;
  j.round_start = start;
  j.calibrated = calibrated;
  j.offset = calibrated ? it->second : default_offset(mode);
  if (builtin()) {   // the recorder keeps the last minutes on disk: nothing to save now, the cutting finds them
    if (!recorder_->running()) { say("Live clips: round " + std::to_string(j.round) + " not clipped: the recorder was not running."); return; }
    j.saved_at = t;
    std::lock_guard<std::mutex> g(mu_);
    jobs_.push_back(j);
    say("Live clips: round " + std::to_string(j.round) + ": " + std::to_string(list.size()) + " moment" + (list.size() == 1 ? "" : "s") + " found, cutting...");
    return;
  }
  // OBS: save its buffer now, it moves on every second.
  std::string err, before, path;
  double saved = 0;
  {
    std::lock_guard<std::mutex> o(obs_mu_);
    bool active = false;
    if (!connect(err) || !obs_.replay_buffer_active(active, err)) { say("Live clips: round " + std::to_string(list[0].round) + " not clipped: OBS " + err); return; }
    if (!active) { say("Live clips: round " + std::to_string(list[0].round) + " not clipped: OBS's replay buffer is off."); return; }
    obs_.last_replay(before, err);   // to tell the new file from the previous one
    if (!obs_.save_replay_buffer(err)) { say("Live clips: OBS did not save its buffer: " + err); return; }
    saved = now();
    for (int i = 0; i < 40; i++) {
      std::string e2;
      if (obs_.last_replay(path, e2) && !path.empty() && path != before) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(250));
    }
  }
  if (path.empty() || path == before) { say("Live clips: OBS saved its buffer but did not say where."); return; }
  j.video = path;
  j.saved_at = saved;
  std::lock_guard<std::mutex> g(mu_);
  jobs_.push_back(j);
  say("Live clips: round " + std::to_string(j.round) + ": " + std::to_string(list.size()) + " moment" + (list.size() == 1 ? "" : "s") + " saved, cutting...");
}

static std::string fmt(double v) {
  char b[32];
  std::snprintf(b, sizeof b, "%.3f", v);
  return b;
}

static long long folder_bytes(const std::string& dir) {
  long long n = 0;
  std::error_code ec;
  for (const auto& e : fs::directory_iterator(fs::path(plat::from_utf8(dir)), ec))
    if (e.is_regular_file(ec)) n += (long long)e.file_size(ec);
  return n;
}

// Sends every cut round that is not on the server yet, oldest first; a round that fails stays for the next try.
// What waits may not grow past rec::kPendingClipBytes: the oldest waiting clips are dropped first.
int Clipper::upload_pending(const Settings& s, const std::string& what) {
  int sent = 0;
  long long waiting = 0;
  for (const auto& p : pending_) waiting += folder_bytes(p.first);
  while (waiting > rec::kPendingClipBytes && pending_.size() > 1) {
    std::error_code ec;
    waiting -= folder_bytes(pending_.front().first);
    fs::remove_all(fs::path(plat::from_utf8(pending_.front().first)), ec);
    say("Live clips: the server has been unreachable for a while; dropped the oldest clips that were waiting, to keep within the disk limit.");
    pending_.erase(pending_.begin());
  }
  for (auto it = pending_.begin(); it != pending_.end();) {
    const auto up = clips::upload_clips(s.server, s.token, it->first, it->second, nullptr, 4 * 1024 * 1024, true);
    sent += up.sent;
    if (up.stopped || up.failed) {
      say("Live clips: " + what + ": not uploaded yet" + (up.stopped ? " (" + up.message + ")" : "") + ". Trying again after the next round.");
      if (up.stopped) break;   // the server is unreachable or full: no point trying the others now
      ++it;
    } else {
      it = pending_.erase(it);
    }
  }
  if (sent) say("Live clips: " + what + ": " + std::to_string(sent) + " clip" + (sent == 1 ? "" : "s") + " uploaded. Open the app to watch.");
  return sent;
}

int Clipper::drain() {
  int sent = 0;
  for (;;) {
    Job j;
    {
      std::lock_guard<std::mutex> g(mu_);
      if (jobs_.empty()) return sent;
      j = jobs_.front();
      jobs_.pop_front();
    }
    const Settings s = settings();
    // The footage: the recorder's pieces, or the one file OBS saved (which ends when it was saved).
    std::vector<rec::Segment> footage;
    std::string err;
    if (j.video.empty()) {
      if (!recorder_) continue;
      if (!recorder_->flush(err)) { say("Live clips: " + err); }
      footage = recorder_->segments();
    } else {
      double length = 0;
      auto dur = duration ? duration : [](const std::string& v, double& sec, std::string& e) { return plat::video_duration(plat::from_utf8(v), sec, e); };
      if (!dur(j.video, length, err)) { say("Live clips: cannot read OBS's saved video: " + err); continue; }
      footage.push_back({j.video, j.saved_at - length, j.saved_at});
    }
    // Everything in wall-clock seconds: the round timer started at round start + offset.
    clips::RoundMark mark;
    mark.start = j.round_start + j.offset;
    hl::Options opt;
    if (!j.calibrated) { opt.pad_before = 12; opt.pad_after = 6; }
    const fs::path dir = fs::path(plat::from_utf8(s.clips_dir)) / L"live" / plat::from_utf8(j.match_id) / plat::from_utf8("round-" + std::to_string(j.round));
    std::error_code ec;
    fs::create_directories(dir, ec);
    std::string idx = "{\"match_id\":" + quote(j.match_id) + ",\"recording\":" + quote(j.video.empty() ? "built-in recorder" : j.video) + ",\"clips\":[";
    int cut = 0;
    for (const auto& h : j.list) {
      clips::Placed p = clips::place(h, mark, opt);
      if (!p.ok) continue;
      double first = 1e18, last = -1e18;   // the kills themselves must be in the footage; the padding may be trimmed
      for (const auto& k : h.kills) { first = std::min(first, mark.start + k.t); last = std::max(last, mark.start + k.t); }
      if (h.clutch_vs > 0) first = std::min(first, mark.start + h.begin);
      std::vector<rec::Part> parts;
      double cf = -1, ct = -1;
      if (!rec::parts_for(footage, p.start, p.start + p.duration, parts, &cf, &ct)) {
        if (cf < 0 || cf > first - 0.5 || ct < last + 0.5 || !rec::parts_for(footage, cf, ct, parts)) {
          say("Live clips: " + hl::describe(h) + " is not in the recording" + (cf < 0 || cf > first ? " (it happened before the recording's oldest minute)" : "") + ".");
          continue;
        }
        p.start = cf;
        p.duration = ct - cf;
      }
      // The still: the frame of the first kill, from the piece that holds it.
      std::vector<rec::Part> tp;
      rec::parts_for(footage, p.thumb, p.thumb + 0.05, tp);
      const std::string name = clips::clip_name(h);
      const std::string out = plat::to_utf8((dir / plat::from_utf8(name)).wstring());
      const std::string thumb = out.substr(0, out.size() - 4) + ".jpg";
      std::string e;
      bool ok;
      if (this->cut) {
        ok = this->cut(parts, out, thumb, tp.empty() ? "" : tp[0].path, tp.empty() ? 0 : tp[0].offset, e);
      } else {
        std::vector<std::wstring> files;
        std::vector<double> offs, lens;
        for (const auto& pt : parts) { files.push_back(plat::from_utf8(pt.path)); offs.push_back(pt.offset); lens.push_back(pt.length); }
        ok = plat::cut_parts(files, offs, lens, plat::from_utf8(out), 720, e);
        std::string e2;
        if (ok && (tp.empty() || !plat::grab_frame_jpeg(plat::from_utf8(tp[0].path), tp[0].offset, plat::from_utf8(thumb), 360, e2))) fs::remove(fs::path(plat::from_utf8(thumb)), ec);
      }
      if (!ok) { say("Live clips: could not cut " + hl::describe(h) + ": " + e); continue; }
      const bool hasThumb = fs::exists(fs::path(plat::from_utf8(thumb)), ec);
      idx += (cut ? "," : "") + std::string("{\"id\":") + quote(h.id) + ",\"file\":" + quote(name) + ",\"thumb\":" + quote(hasThumb ? fs::path(plat::from_utf8(thumb)).filename().string() : "") +
             ",\"start\":" + fmt(p.start) + ",\"duration\":" + fmt(p.duration) + ",\"approx\":" + (j.calibrated && !p.approx ? "false" : "true") + "}";
      cut++;
    }
    idx += "]}";
    std::ofstream(dir / L"clips.json", std::ios::binary) << idx;
    if (!j.video.empty() && !s.keep_buffer_files) fs::remove(fs::path(plat::from_utf8(j.video)), ec);   // the minutes OBS saved are not needed any more
    if (!cut) continue;
    if (s.server.empty() || s.token.empty()) { say("Live clips: " + std::to_string(cut) + " clips cut in " + plat::to_utf8(dir.wstring()) + " (no server set up, so not uploaded)."); continue; }
    pending_.push_back({plat::to_utf8(dir.wstring()), j.list});
    sent += upload_pending(s, "round " + std::to_string(j.round));
  }
}

}  // namespace live
