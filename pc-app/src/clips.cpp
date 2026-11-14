#include "clips.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <chrono>
#include <map>
#include <set>
#include <thread>

#include "core.hpp"
#include "platform.hpp"

namespace clips {

namespace fs = std::filesystem;
using mini::quote;

// ---------- small helpers ----------

std::string base64(const std::string& in) {
  static const char* t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  size_t i = 0;
  for (; i + 2 < in.size(); i += 3) {
    const unsigned v = ((unsigned char)in[i] << 16) | ((unsigned char)in[i + 1] << 8) | (unsigned char)in[i + 2];
    out += t[v >> 18];
    out += t[(v >> 12) & 63];
    out += t[(v >> 6) & 63];
    out += t[v & 63];
  }
  if (i + 1 == in.size()) {
    const unsigned v = (unsigned char)in[i] << 16;
    out += t[v >> 18];
    out += t[(v >> 12) & 63];
    out += "==";
  } else if (i + 2 == in.size()) {
    const unsigned v = ((unsigned char)in[i] << 16) | ((unsigned char)in[i + 1] << 8);
    out += t[v >> 18];
    out += t[(v >> 12) & 63];
    out += t[(v >> 6) & 63];
    out += '=';
  }
  return out;
}

static std::string sha256_raw(const std::string& data) {
  const std::string hex = core::sha256_bytes(data);
  std::string out;
  for (size_t i = 0; i + 1 < hex.size(); i += 2) out += (char)std::stoi(hex.substr(i, 2), nullptr, 16);
  return out;
}

// obs-websocket 5: secret = base64(sha256(password + salt)), answer = base64(sha256(secret + challenge)).
std::string obs_auth(const std::string& password, const std::string& salt, const std::string& challenge) {
  return base64(sha256_raw(base64(sha256_raw(password + salt)) + challenge));
}

static std::string fmt(double v) {
  char b[32];
  std::snprintf(b, sizeof b, "%.3f", v);
  return b;
}

// ---------- OBS ----------

Obs::~Obs() { close(); }

void Obs::close() {
  if (ws_) plat::ws_close(ws_);
  ws_ = nullptr;
}

bool Obs::connect(const std::string& host, int port, const std::string& password, std::string& error) {
  close();
  ws_ = plat::ws_open(host, port, error);
  if (!ws_) return false;
  std::string text;
  mini::Json hello;
  if (!plat::ws_recv(ws_, text, 5000) || !mini::parse(text, hello) || hello.at("op").num(-1) != 0) {
    error = "OBS did not say hello. Is that port OBS's WebSocket server?";
    close();
    return false;
  }
  const auto& d = hello.at("d");
  std::string identify = "{\"op\":1,\"d\":{\"rpcVersion\":1,\"eventSubscriptions\":0";
  const auto& auth = d.at("authentication");
  if (!auth.isNull()) {
    if (password.empty()) { error = "OBS asks for a password. Copy it from Tools > WebSocket Server Settings > Show Connect Info."; close(); return false; }
    identify += ",\"authentication\":" + quote(obs_auth(password, auth.at("salt").str(), auth.at("challenge").str()));
  }
  identify += "}}";
  mini::Json ok;
  if (!plat::ws_send(ws_, identify) || !plat::ws_recv(ws_, text, 5000) || !mini::parse(text, ok) || ok.at("op").num(-1) != 2) {
    error = auth.isNull() ? "OBS closed the connection." : "OBS did not accept the password.";
    close();
    return false;
  }
  return true;
}

bool Obs::request(const std::string& type, const std::string& data, mini::Json& response, std::string& error, int timeout_ms) {
  if (!ws_) { error = "not connected to OBS"; return false; }
  const std::string id = "r6-" + std::to_string(next_++);
  std::string msg = "{\"op\":6,\"d\":{\"requestType\":" + quote(type) + ",\"requestId\":" + quote(id);
  if (!data.empty()) msg += ",\"requestData\":" + data;
  msg += "}}";
  if (!plat::ws_send(ws_, msg)) { error = "the connection to OBS was lost"; close(); return false; }
  std::string text;
  for (int skipped = 0; skipped < 50; skipped++) {   // anything that is not our answer (an event) is passed over
    mini::Json j;
    if (!plat::ws_recv(ws_, text, timeout_ms)) { error = "OBS did not answer"; close(); return false; }
    if (!mini::parse(text, j) || j.at("op").num(-1) != 7 || j.at("d").at("requestId").str() != id) continue;
    const auto& st = j.at("d").at("requestStatus");
    if (!(st.at("result").type == mini::Json::Bool && st.at("result").b)) {
      error = st.at("comment").str("OBS refused " + type) + " (code " + std::to_string(st.at("code").num()) + ")";
      return false;
    }
    response = j.at("d").at("responseData");
    return true;
  }
  error = "OBS did not answer";
  return false;
}

bool Obs::start_record(std::string& error) {
  mini::Json r;
  return request("StartRecord", "", r, error);
}

bool Obs::stop_record(std::string& path, std::string& error) {
  mini::Json r;
  if (!request("StopRecord", "", r, error, 15000)) return false;
  path = r.at("outputPath").str();
  return true;
}

bool Obs::record_time(double& seconds, bool& active, std::string& error) {
  mini::Json r;
  if (!request("GetRecordStatus", "", r, error)) return false;
  active = r.at("outputActive").type == mini::Json::Bool && r.at("outputActive").b;
  seconds = r.at("outputDuration").n / 1000.0;
  return true;
}

bool Obs::replay_buffer_active(bool& active, std::string& error) {
  mini::Json r;
  if (!request("GetReplayBufferStatus", "", r, error)) return false;
  active = r.at("outputActive").type == mini::Json::Bool && r.at("outputActive").b;
  return true;
}

bool Obs::start_replay_buffer(std::string& error) {
  mini::Json r;
  return request("StartReplayBuffer", "", r, error);
}

bool Obs::save_replay_buffer(std::string& error) {
  mini::Json r;
  return request("SaveReplayBuffer", "", r, error);
}

bool Obs::last_replay(std::string& path, std::string& error) {
  mini::Json r;
  if (!request("GetLastReplayBufferReplay", "", r, error)) return false;
  path = r.at("savedReplayPath").str();
  return true;
}

// ---------- sessions ----------

std::string session_json(const Session& s) {
  std::string o = "{\"match_id\":" + quote(s.match_id) + ",\"recording\":" + quote(s.recording) + ",\"footage\":[";
  for (size_t i = 0; i < s.footage.size(); i++)
    o += (i ? "," : "") + std::string("{\"path\":") + quote(s.footage[i].path) + ",\"start\":" + fmt(s.footage[i].start) + ",\"end\":" + fmt(s.footage[i].end) + "}";
  o += "],\"rounds\":{";
  bool first = true;
  for (const auto& kv : s.rounds) {
    o += (first ? "" : ",") + quote(std::to_string(kv.first)) + ":{\"start\":" + fmt(kv.second.start) + ",\"plant\":" + fmt(kv.second.plant) + "}";
    first = false;
  }
  return o + "}}";
}

bool session_from_json(const std::string& text, Session& s) {
  mini::Json j;
  if (!mini::parse(text, j) || j.type != mini::Json::Obj) return false;
  s.match_id = j.at("match_id").str();
  s.recording = j.at("recording").str();
  s.footage.clear();
  for (const auto& f : j.at("footage").a) s.footage.push_back({f.at("path").str(), f.at("start").n, f.at("end").n});
  s.rounds.clear();
  for (const auto& kv : j.at("rounds").o) {
    RoundMark m;
    m.start = kv.second.at("start").isNull() ? -1 : kv.second.at("start").n;
    m.plant = kv.second.at("plant").isNull() ? -1 : kv.second.at("plant").n;
    s.rounds[std::atoi(kv.first.c_str())] = m;
  }
  return true;
}

// ---------- placing a highlight in the recording ----------

Placed place(const hl::Highlight& h, const RoundMark& m, const hl::Options& opt) {
  Placed p;
  if (m.start < 0) { p.why = "round " + std::to_string(h.round) + " has no start mark"; return p; }
  double first = 1e18, last = -1e18, firstKill = 1e18;
  for (const auto& k : h.kills) {
    double at;
    if (!k.post_plant) at = m.start + k.t;
    else if (m.plant >= 0 && k.clock >= 0) at = m.plant + (45.0 - k.clock);   // the defuser clock starts at 45 when the plant completes
    else { at = m.start + k.t; p.approx = true; }
    first = std::min(first, at);
    last = std::max(last, at);
    firstKill = std::min(firstKill, at);
  }
  if (h.clutch_vs > 0) first = std::min(first, m.start + h.begin);   // a clutch clip starts when the clutch did
  p.start = std::max(0.0, first - opt.pad_before);
  p.duration = last + opt.pad_after - p.start;
  p.thumb = firstKill;
  p.ok = p.duration > 0;
  if (!p.ok) p.why = "the marks put this moment before the recording started";
  return p;
}

// ---------- cutting ----------

std::string clip_name(const hl::Highlight& h) {
  std::string safe;
  for (char c : h.match_id) safe += (std::isalnum((unsigned char)c) || c == '-') ? c : '_';
  return safe + "_r" + std::to_string(h.round) + "_" + h.type + "_" + h.id.substr(0, 8) + ".mp4";
}

std::vector<std::string> cut_args(const std::string& recording, const Placed& p, const std::string& out_file, bool hardware_encoder) {
  // Seeking before -i is fast, and exact because the clip is re-encoded. 720p H.264 + AAC, with the index at the front
  // so phones can start playing before the whole file arrives.
  std::vector<std::string> a = {"-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-ss", fmt(p.start), "-i", recording, "-t", fmt(p.duration),
                                "-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=-2:'min(720,ih)'", "-pix_fmt", "yuv420p"};
  if (hardware_encoder) a.insert(a.end(), {"-c:v", "h264_mf", "-b:v", "6M"});   // Windows' own encoder, in ffmpeg builds without x264
  else a.insert(a.end(), {"-c:v", "libx264", "-preset", "veryfast", "-crf", "21"});
  a.insert(a.end(), {"-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", out_file});
  return a;
}

std::vector<std::string> thumb_args(const std::string& recording, const Placed& p, const std::string& out_file) {
  return {"-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-ss", fmt(p.thumb), "-i", recording, "-frames:v", "1", "-vf", "scale=-2:360", "-q:v", "4", out_file};
}

static std::vector<std::wstring> wide(const std::vector<std::string>& a) {
  std::vector<std::wstring> w;
  for (const auto& s : a) w.push_back(plat::from_utf8(s));
  return w;
}

static std::string last_line(const std::string& out) {
  std::string s = out;
  while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
  const size_t n = s.find_last_of('\n');
  return n == std::string::npos ? s : s.substr(n + 1);
}

std::vector<ClipResult> cut_all(const Session& s, const std::vector<hl::Highlight>& list, const std::string& ffmpeg, const std::string& out_dir, const ClipProgress& progress) {
  std::vector<ClipResult> out;
  std::error_code ec;
  fs::create_directories(fs::path(plat::from_utf8(out_dir)), ec);
  std::vector<const hl::Highlight*> mine;
  for (const auto& h : list)
    if (h.match_id == s.match_id) mine.push_back(&h);
  bool hardware = false;
  int done = 0;
  for (const auto* h : mine) {
    ClipResult r;
    r.id = h->id;
    auto it = s.rounds.find(h->round);
    const Placed p = place(*h, it == s.rounds.end() ? RoundMark{} : it->second);
    if (!p.ok) {
      r.error = p.why;
    } else {
      r.start = p.start;
      r.duration = p.duration;
      r.approx = p.approx;
      const std::string name = clip_name(*h);
      r.file = (fs::path(plat::from_utf8(out_dir)) / plat::from_utf8(name)).string();
      r.thumb = r.file.substr(0, r.file.size() - 4) + ".jpg";
      std::string mfErr;
      std::vector<rec::Part> parts;
      if (!s.footage.empty()) {   // the built-in recorder: marks and moments are wall-clock times, found in its pieces
        double cf = -1, ct = -1;
        if (!rec::parts_for(s.footage, p.start, p.start + p.duration, parts, &cf, &ct) && !(cf >= 0 && rec::parts_for(s.footage, cf, ct, parts))) {
          r.error = "that moment is not in the recording";
        } else {
          std::vector<std::wstring> files;
          std::vector<double> offs, lens;
          r.duration = 0;
          for (const auto& pt : parts) { files.push_back(plat::from_utf8(pt.path)); offs.push_back(pt.offset); lens.push_back(pt.length); r.duration += pt.length; }
          if (plat::cut_parts(files, offs, lens, plat::from_utf8(r.file), 720, mfErr)) {
            std::vector<rec::Part> tp;
            std::string e2;
            if (!rec::parts_for(s.footage, p.thumb, p.thumb + 0.05, tp) || !plat::grab_frame_jpeg(plat::from_utf8(tp[0].path), tp[0].offset, plat::from_utf8(r.thumb), 360, e2)) r.thumb.clear();
            r.ok = true;
          } else {
            r.error = mfErr == "not available" ? "nothing here can cut video: Windows' video engine is not available" : mfErr;
          }
        }
      } else if (plat::cut_video(plat::from_utf8(s.recording), p.start, p.duration, plat::from_utf8(r.file), 720, mfErr)) {
        std::string e2;
        if (!plat::grab_frame_jpeg(plat::from_utf8(s.recording), p.thumb, plat::from_utf8(r.thumb), 360, e2)) r.thumb.clear();
        r.ok = true;
      } else if (!ffmpeg.empty()) {   // Windows could not (or this is not Windows): ffmpeg, when there is one
        auto run = [&](bool hw) { return plat::run_helper(plat::from_utf8(ffmpeg), wide(cut_args(s.recording, p, r.file, hw)), 300000); };
        auto res = run(hardware);
        if (res.started && res.exit_code != 0 && !hardware && (res.output.find("Unknown encoder") != std::string::npos || res.output.find("libx264") != std::string::npos)) {
          hardware = true;   // this ffmpeg has no x264: use Windows' encoder from now on
          res = run(true);
        }
        if (!res.started) r.error = "ffmpeg could not be started";
        else if (res.timed_out) r.error = "ffmpeg took too long";
        else if (res.exit_code != 0) r.error = "ffmpeg: " + last_line(res.output);
        else {
          const auto t = plat::run_helper(plat::from_utf8(ffmpeg), wide(thumb_args(s.recording, p, r.thumb)), 60000);
          if (!t.started || t.exit_code != 0) r.thumb.clear();   // a clip without a picture is still a clip
          r.ok = true;
        }
      } else {
        r.error = mfErr == "not available" ? "nothing here can cut video: Windows' video engine is not available and there is no ffmpeg" : mfErr;
      }
    }
    out.push_back(r);
    done++;
    if (progress) progress(done, (int)mine.size(), (r.ok ? "Cut " : "Skipped ") + hl::describe(*h) + (r.ok ? "" : ": " + r.error));
  }
  // An index next to the clips: what each one shows, for the upload step and for people.
  std::string idx = "{\"match_id\":" + quote(s.match_id) + ",\"recording\":" + quote(s.recording) + ",\"clips\":[";
  bool first = true;
  for (size_t i = 0; i < out.size(); i++) {
    const auto& r = out[i];
    if (!r.ok) continue;
    idx += (first ? "" : ",") + std::string("{\"id\":") + quote(r.id) + ",\"file\":" + quote(fs::path(r.file).filename().string()) +
           ",\"thumb\":" + quote(r.thumb.empty() ? "" : fs::path(r.thumb).filename().string()) + ",\"start\":" + fmt(r.start) +
           ",\"duration\":" + fmt(r.duration) + ",\"approx\":" + (r.approx ? "true" : "false") + "}";
    first = false;
  }
  idx += "]}";
  std::ofstream(fs::path(plat::from_utf8(out_dir)) / "clips.json", std::ios::binary) << idx;
  return out;
}

std::string find_ffmpeg(const std::string& configured) {
  std::error_code ec0;
  if (!configured.empty() && fs::is_regular_file(fs::path(plat::from_utf8(configured)), ec0)) return configured;
  const std::wstring forced = plat::env(L"R6_FFMPEG");
  if (!forced.empty()) return plat::to_utf8(forced);
#ifdef _WIN32
  const wchar_t* exe = L"ffmpeg.exe";
  const wchar_t sep = L';';
#else
  const wchar_t* exe = L"ffmpeg";
  const wchar_t sep = L':';
#endif
  std::error_code ec;
  const fs::path here = fs::path(plat::program_dir());
  for (const fs::path& c : {here / exe, here / L"ffmpeg" / exe, here / L"ffmpeg" / L"bin" / exe})
    if (!here.empty() && fs::is_regular_file(c, ec)) return plat::to_utf8(c.wstring());
  const std::wstring path = plat::env(L"PATH");
  size_t a = 0;
  while (a <= path.size()) {
    size_t b = path.find(sep, a);
    if (b == std::wstring::npos) b = path.size();
    if (b > a) {
      const fs::path c = fs::path(path.substr(a, b - a)) / exe;
      if (fs::is_regular_file(c, ec)) return plat::to_utf8(c.wstring());
    }
    a = b + 1;
  }
  return {};
}

// ---------- uploading ----------

static std::string read_file(const fs::path& p) {
  std::ifstream in(p, std::ios::binary);
  return std::string((std::istreambuf_iterator<char>(in)), {});
}

UploadSummary upload_clips(const std::string& server, const std::string& token, const std::string& clip_dir, const std::vector<hl::Highlight>& list,
                           const ClipProgress& progress, size_t chunk, bool delete_after) {
  UploadSummary sum;
  const fs::path dir(plat::from_utf8(clip_dir));
  mini::Json idx;
  if (!mini::parse(read_file(dir / "clips.json"), idx)) { sum.stopped = true; sum.message = "there are no cut clips here yet"; return sum; }
  std::set<std::string> done;
  {
    std::ifstream in(dir / "uploaded.txt");
    for (std::string line; std::getline(in, line);) if (!line.empty()) done.insert(line);
  }
  auto remember = [&](const std::string& id) {
    done.insert(id);
    std::ofstream(dir / "uploaded.txt", std::ios::app) << id << "\n";
  };
  const auto& items = idx.at("clips").a;
  int n = 0;
  for (const auto& c : items) {
    n++;
    const std::string id = c.at("id").str();
    const hl::Highlight* h = nullptr;
    for (const auto& x : list) if (x.id == id) h = &x;
    auto say = [&](const std::string& m) { if (progress) progress(n, (int)items.size(), m); };
    if (done.count(id)) {
      sum.already++;
      if (delete_after) {
        std::error_code ec;
        fs::remove(dir / plat::from_utf8(c.at("file").str()), ec);
        if (!c.at("thumb").str().empty()) fs::remove(dir / plat::from_utf8(c.at("thumb").str()), ec);
      }
      continue;
    }
    if (!h) { sum.failed++; say("skipped a clip whose details are missing (" + id + ")"); continue; }
    const fs::path video = dir / plat::from_utf8(c.at("file").str());
    const std::string bytes = read_file(video);
    if (bytes.empty()) { sum.failed++; say("skipped " + c.at("file").str() + ": the file is missing"); continue; }
    char extra[96];
    std::snprintf(extra, sizeof extra, ",\"video\":{\"size\":%zu,\"duration\":%.2f}}", bytes.size(), std::max(0.5, c.at("duration").n));
    std::string body = hl::item_json(*h);
    body.pop_back();
    body += extra;
    // 1. the details: the server answers how much of the video it already has
    auto r = plat::http_post_json(server + "/v1/highlights", token, body);
    if (r.status == 0) { sum.stopped = true; sum.message = "cannot reach the server: " + r.error; return sum; }
    if (r.status == 401 || r.status == 403) { sum.stopped = true; sum.message = "the server did not accept the upload token"; return sum; }
    if (r.status == 507) { sum.stopped = true; sum.message = "the server's clip storage is full: delete some clips in the app"; return sum; }
    mini::Json j;
    if ((r.status != 200 && r.status != 201) || !mini::parse(r.body, j)) { sum.failed++; say("the server refused " + hl::describe(*h) + " (" + std::to_string(r.status) + "): " + last_line(r.body)); continue; }
    if (j.at("status").str() == "ready") {
      remember(id);
      sum.already++;
      say("already on the server: " + hl::describe(*h));
      if (delete_after) {
        std::error_code ec;
        fs::remove(video, ec);
        if (!c.at("thumb").str().empty()) fs::remove(dir / plat::from_utf8(c.at("thumb").str()), ec);
      }
      continue;
    }
    // 2. the video, in pieces; a lost connection is retried with growing waits, and resumes where the server is
    uint64_t pos = (uint64_t)j.at("received").n;
    int tries = 0;
    std::string status;
    while (pos < bytes.size()) {
      const std::string piece = bytes.substr((size_t)pos, chunk);
      r = plat::http_send("PUT", server + "/v1/highlights/" + id + "/video?offset=" + std::to_string(pos), token, piece, "application/octet-stream");
      mini::Json a;
      const bool parsed = mini::parse(r.body, a);
      if ((r.status == 200 || r.status == 409) && parsed && !a.at("received").isNull()) {
        pos = (uint64_t)a.at("received").n;
        status = a.at("status").str();
        tries = 0;
        say("Round " + std::to_string(h->round) + " " + h->type + ": " + std::to_string(pos * 100 / bytes.size()) + "% sent");
        continue;
      }
      if (r.status == 0 && ++tries <= 5) {
        std::this_thread::sleep_for(std::chrono::seconds(1 << (tries - 1)));
        auto st = plat::http_get(server + "/v1/highlights/" + id + "/upload", token);   // where did it stop?
        mini::Json sj;
        if (st.status == 200 && mini::parse(st.body, sj)) pos = (uint64_t)sj.at("received").n;
        continue;
      }
      status = "error";
      say("could not send " + hl::describe(*h) + ": " + (r.status == 0 ? r.error : std::to_string(r.status) + " " + last_line(r.body)));
      break;
    }
    if (status != "ready") { sum.failed++; if (status != "error") say("the server did not finish " + hl::describe(*h)); continue; }
    // 3. the picture (optional)
    const std::string thumb = c.at("thumb").str();
    if (!thumb.empty()) {
      const std::string jpg = read_file(dir / plat::from_utf8(thumb));
      if (!jpg.empty()) plat::http_send("PUT", server + "/v1/highlights/" + id + "/thumbnail", token, jpg, "image/jpeg");
    }
    remember(id);
    sum.sent++;
    say("uploaded " + hl::describe(*h));
    if (delete_after) {   // it is on the server now: no copy needs to stay on this PC
      std::error_code ec;
      fs::remove(video, ec);
      if (!thumb.empty()) fs::remove(dir / plat::from_utf8(thumb), ec);
    }
  }
  if (delete_after && !sum.stopped && sum.failed == 0) {   // every clip here is on the server: the folder can go
    std::error_code ec;
    fs::remove_all(dir, ec);
    // and the match folder above it, once its last round is gone
    if (fs::is_directory(dir.parent_path(), ec) && fs::is_empty(dir.parent_path(), ec)) fs::remove(dir.parent_path(), ec);
  }
  return sum;
}

// ---------- the shared workflow ----------

std::vector<MatchFolder> match_folders(const fs::path& root, int max) {
  std::map<fs::path, MatchFolder> by;
  std::error_code ec;
  for (auto it = fs::recursive_directory_iterator(root, fs::directory_options::skip_permission_denied, ec); !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
    if (!it->is_regular_file(ec) || it->path().extension() != ".rec") continue;
    auto& m = by[it->path().parent_path()];
    m.dir = it->path().parent_path();
    m.name = plat::to_utf8(m.dir.filename().wstring());
    m.files++;
    const auto t = (long long)fs::last_write_time(it->path(), ec).time_since_epoch().count();
    m.newest = std::max(m.newest, t);
  }
  std::vector<MatchFolder> out;
  for (auto& kv : by) out.push_back(kv.second);
  std::sort(out.begin(), out.end(), [](const MatchFolder& a, const MatchFolder& b) { return a.newest > b.newest; });
  if ((int)out.size() > max) out.resize((size_t)max);
  return out;
}

std::vector<mini::Json> read_match(const fs::path& dir, std::string& error, int* unreadable) {
  std::vector<mini::Json> rounds;
  std::vector<fs::path> files;
  std::error_code ec;
  for (const auto& e : fs::directory_iterator(dir, ec))
    if (e.is_regular_file(ec) && e.path().extension() == ".rec") files.push_back(e.path());
  std::sort(files.begin(), files.end());
  int bad = 0;
  for (const auto& f : files) {
    const auto r = core::read_replay(f, core::sha256_file(f), (uint64_t)fs::file_size(f, ec));
    if (r.helper_unusable) { error = "the replay reader cannot run here: " + r.reason; return {}; }
    mini::Json j;
    if (!r.ok || !mini::parse(r.payload, j)) { bad++; continue; }
    rounds.push_back(j.at("round"));
  }
  if (unreadable) *unreadable = bad;
  return rounds;
}

std::vector<int> rounds_to_mark(const std::vector<hl::Highlight>& list) {
  std::vector<int> r;
  for (const auto& h : list)
    if (std::find(r.begin(), r.end(), h.round) == r.end()) r.push_back(h.round);
  std::sort(r.begin(), r.end());
  return r;
}

fs::path sessions_dir() {
  const fs::path d = fs::path(plat::app_data_dir()) / L"clip-sessions";
  std::error_code ec;
  fs::create_directories(d, ec);
  return d;
}

static fs::path session_file(const std::string& match_id) {
  std::string safe;
  for (char c : match_id) safe += (std::isalnum((unsigned char)c) || c == '-') ? c : '_';
  return sessions_dir() / plat::from_utf8(safe + ".json");
}

bool load_session(const std::string& match_id, Session& s) {
  std::ifstream in(session_file(match_id), std::ios::binary);
  if (!in) return false;
  std::string text((std::istreambuf_iterator<char>(in)), {});
  return session_from_json(text, s) && s.match_id == match_id;
}

bool save_session(const Session& s) {
  const fs::path p = session_file(s.match_id), tmp = p.string() + ".tmp";
  {
    std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
    if (!(out << session_json(s))) return false;
  }
  std::error_code ec;
  fs::rename(tmp, p, ec);
  return !ec;
}

fs::path default_clips_dir() {
  const std::wstring home = plat::env(L"USERPROFILE");
  if (!home.empty()) return fs::path(home) / L"Videos" / L"R6 Highlights";
  return fs::path(plat::app_data_dir()) / L"clips";
}

}  // namespace clips
