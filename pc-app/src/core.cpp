#include "core.hpp"

#include <algorithm>
#include <chrono>
#include <thread>
#include <cstdint>
#include <cstring>
#include <ctime>
#include <cstdio>
#include <cctype>
#include <fstream>
#include <initializer_list>
#include <set>
#include <sstream>

#include "json.hpp"
#include "platform.hpp"

namespace core {

static std::string trim(std::string s) {
  size_t a = 0, b = s.size();
  while (a < b && std::isspace((unsigned char)s[a])) a++;
  while (b > a && std::isspace((unsigned char)s[b - 1])) b--;
  return s.substr(a, b - a);
}

std::string normalize_url(std::string url) {
  url = trim(url);
  while (!url.empty() && url.back() == '/') url.pop_back();
  if (!url.empty() && url.find("://") == std::string::npos) url = "https://" + url;
  return url;
}

static fs::path data_dir() { return fs::path(plat::app_data_dir()); }

bool load_config(Config& c) {
  std::ifstream in(data_dir() / "config.ini");
  if (!in) return false;
  std::string line;
  std::string plain, enc;
  while (std::getline(in, line)) {
    auto eq = line.find('=');
    if (eq == std::string::npos) continue;
    std::string k = trim(line.substr(0, eq)), v = trim(line.substr(eq + 1));
    if (k == "server") c.server = v;
    else if (k == "folder") c.folder = fs::path(plat::from_utf8(v));
    else if (k == "poll") c.poll = std::max(5, std::atoi(v.c_str()));
    else if (k == "raw_fallback") c.raw_fallback = v != "0";
    else if (k == "token_enc") enc = v;
    else if (k == "obs_port") c.obs_port = std::atoi(v.c_str()) > 0 ? std::atoi(v.c_str()) : 4455;
    else if (k == "obs_password_enc") c.obs_password = plat::unprotect(v);
    else if (k == "obs_password") c.obs_password = v;
    else if (k == "ffmpeg") c.ffmpeg = v;
    else if (k == "clips_dir") c.clips_dir = fs::path(plat::from_utf8(v));
    else if (k == "live") c.live = v == "1";
    else if (k == "use_obs") c.use_obs = v == "1";
    else if (k == "live_min_score") c.live_min_score = std::max(1, std::atoi(v.c_str()));
    else if (k == "live_offsets") {   // Ranked=47.0;QuickMatch=33.0
      std::stringstream ss(v);
      std::string part;
      while (std::getline(ss, part, ';')) {
        const auto e = part.find('=');
        if (e != std::string::npos) c.live_offsets[part.substr(0, e)] = std::atof(part.substr(e + 1).c_str());
      }
    }
    else if (k == "token") plain = v;
  }
  c.token = enc.empty() ? plain : plat::unprotect(enc);
  return true;
}

bool save_config(const Config& c) {
  std::ofstream out(data_dir() / "config.ini", std::ios::trunc);
  if (!out) return false;
  out << "server=" << c.server << "\n";
  out << "folder=" << plat::to_utf8(c.folder.wstring()) << "\n";
  out << "poll=" << c.poll << "\n";
  out << "raw_fallback=" << (c.raw_fallback ? 1 : 0) << "\n";
  std::string enc = plat::protect(c.token);   // the token is encrypted for this Windows user
  if (!enc.empty()) out << "token_enc=" << enc << "\n";
  else out << "token=" << c.token << "\n";
  out << "obs_port=" << c.obs_port << "\n";
  if (!c.obs_password.empty()) {
    const std::string pe = plat::protect(c.obs_password);
    if (!pe.empty()) out << "obs_password_enc=" << pe << "\n";
    else out << "obs_password=" << c.obs_password << "\n";
  }
  if (!c.ffmpeg.empty()) out << "ffmpeg=" << c.ffmpeg << "\n";
  if (!c.clips_dir.empty()) out << "clips_dir=" << plat::to_utf8(c.clips_dir.wstring()) << "\n";
  out << "live=" << (c.live ? 1 : 0) << "\n";
  out << "live_min_score=" << c.live_min_score << "\n";
  out << "use_obs=" << (c.use_obs ? 1 : 0) << "\n";
  if (!c.live_offsets.empty()) {
    out << "live_offsets=";
    bool first = true;
    for (const auto& kv : c.live_offsets) { out << (first ? "" : ";") << kv.first << "=" << kv.second; first = false; }
    out << "\n";
  }
  return true;
}

State load_state() {
  State s;
  std::ifstream in(data_dir() / "uploaded.txt");
  std::string line;
  while (std::getline(in, line)) {
    auto tab = line.rfind('\t');
    if (tab == std::string::npos) continue;
    const std::string v = line.substr(tab + 1);
    if (v == "skipped") s.erase(line.substr(0, tab));   // version 1.0 and 1.1 skipped files without saying why: look again and explain
    else s[line.substr(0, tab)] = v;
  }
  return s;
}

int done_count(const State& s) {
  int n = 0;
  for (const auto& kv : s)
    if (kv.first.size() == 64) n++;
  return n;
}

void remember(State& s, const std::string& key, const std::string& status) {
  s[key] = status;
  std::ofstream out(data_dir() / "uploaded.txt", std::ios::app);
  out << key << '\t' << status << '\n';
}

bool check_server(const std::string& server, const std::string& token, std::string& message) {
  if (server.empty() || token.empty()) {
    message = "Enter the server address and the upload token.";
    return false;
  }
  auto h = plat::http_get(server + "/health", "");
  if (h.status == 0) {
    message = "Could not reach the server: " + h.error;
    return false;
  }
  if (h.status != 200 || h.body.find("\"ok\"") == std::string::npos) {
    message = "That address is not a replay server.";
    return false;
  }
  // An upload request with no files is answered 400 when the token is right and 401/403 when it is not.
  auto r = plat::http_post_empty(server + "/v1/upload", token);
  if (r.status == 401) { message = "The server does not accept that token."; return false; }
  if (r.status == 403) { message = "That is the READ token (for the phone). The PC needs the UPLOAD token."; return false; }
  if (r.status == 0) { message = "Could not reach the server: " + r.error; return false; }
  if (r.status != 400 && r.status != 200) { message = "The server answered " + std::to_string(r.status) + "."; return false; }
  message = "Connected. The upload token is accepted.";
  return true;
}

// ---------------------------------------------------------------- finding the folder
static const char* kGame = "Tom Clancy's Rainbow Six Siege";

static std::vector<fs::path> steam_libraries() {
  std::vector<fs::path> bases, libs;
  for (const wchar_t* v : {L"ProgramFiles(x86)", L"ProgramFiles"}) {
    std::wstring e = plat::env(v);
    if (!e.empty()) bases.push_back(fs::path(e) / L"Steam");
  }
  for (const auto& d : plat::fixed_drives()) bases.push_back(fs::path(d) / L"Steam");
  for (const auto& b : bases) {
    libs.push_back(b);
    std::ifstream in(b / L"steamapps" / L"libraryfolders.vdf");
    std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    size_t pos = 0;
    while ((pos = text.find("\"path\"", pos)) != std::string::npos) {
      pos += 6;
      size_t q1 = text.find('"', pos), q2 = q1 == std::string::npos ? q1 : text.find('"', q1 + 1);
      if (q2 == std::string::npos) break;
      std::string p = text.substr(q1 + 1, q2 - q1 - 1), fixed;
      for (size_t i = 0; i < p.size(); i++) {   // the file doubles its backslashes
        if (p[i] == '\\' && i + 1 < p.size() && p[i + 1] == '\\') i++;
        fixed += p[i];
      }
      libs.push_back(fs::path(plat::from_utf8(fixed)));
    }
  }
  return libs;
}

std::vector<fs::path> candidate_folders() {
  std::vector<fs::path> c;
  for (const auto& d : plat::registry_install_dirs()) c.push_back(fs::path(d) / L"MatchReplay");
  for (const auto& l : steam_libraries()) c.push_back(l / L"steamapps" / L"common" / kGame / L"MatchReplay");
  const wchar_t* rel[] = {
      L"Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher\\games",
      L"Program Files\\Ubisoft\\Ubisoft Game Launcher\\games",
      L"Ubisoft Game Launcher\\games",
      L"Ubisoft\\Ubisoft Game Launcher\\games",
      L"Games\\Ubisoft Game Launcher\\games",
      L"Program Files (x86)\\Steam\\steamapps\\common",
      L"SteamLibrary\\steamapps\\common",
      L"Program Files\\Epic Games",
  };
  for (const auto& d : plat::fixed_drives())
    for (const wchar_t* r : rel) c.push_back(fs::path(d) / r / kGame / L"MatchReplay");
  std::set<std::wstring> seen;
  std::vector<fs::path> out;
  for (auto& p : c) {
    std::wstring k = p.wstring();
    std::transform(k.begin(), k.end(), k.begin(), [](wchar_t ch) { return (wchar_t)std::towlower(ch); });
    if (seen.insert(k).second) out.push_back(p);
  }
  return out;
}

static bool is_rec(const fs::path& p) {
  std::wstring e = p.extension().wstring();
  std::transform(e.begin(), e.end(), e.begin(), [](wchar_t ch) { return (wchar_t)std::towlower(ch); });
  return e == L".rec";
}

int count_rec(const fs::path& folder) {
  std::error_code ec;
  int n = 0;
  for (fs::recursive_directory_iterator it(folder, fs::directory_options::skip_permission_denied, ec), end; !ec && it != end; it.increment(ec))
    if (it->is_regular_file(ec) && is_rec(it->path())) n++;
  return n;
}

std::vector<std::pair<fs::path, int>> discover() {
  std::vector<std::pair<fs::path, int>> found;
  std::error_code ec;
  for (const auto& p : candidate_folders())
    if (fs::is_directory(p, ec)) found.emplace_back(p, count_rec(p));
  std::stable_sort(found.begin(), found.end(), [](auto& a, auto& b) { return a.second > b.second; });
  return found;
}

// ---------------------------------------------------------------- deciding what to send
namespace {
struct Sha256 {
  uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  unsigned char buf[64];
  size_t fill = 0;
  uint64_t total = 0;

  static uint32_t rr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
  void block(const unsigned char* p) {
    static const uint32_t k[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
    uint32_t w[64];
    for (int i = 0; i < 16; i++) w[i] = (uint32_t)p[i * 4] << 24 | (uint32_t)p[i * 4 + 1] << 16 | (uint32_t)p[i * 4 + 2] << 8 | p[i * 4 + 3];
    for (int i = 16; i < 64; i++) {
      uint32_t s0 = rr(w[i - 15], 7) ^ rr(w[i - 15], 18) ^ (w[i - 15] >> 3), s1 = rr(w[i - 2], 17) ^ rr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
      uint32_t t1 = hh + (rr(e, 6) ^ rr(e, 11) ^ rr(e, 25)) + ((e & f) ^ (~e & g)) + k[i] + w[i];
      uint32_t t2 = (rr(a, 2) ^ rr(a, 13) ^ rr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
      hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
  }
  void update(const unsigned char* p, size_t n) {
    total += n;
    while (n > 0) {
      size_t take = std::min(n, sizeof(buf) - fill);
      std::memcpy(buf + fill, p, take);
      fill += take; p += take; n -= take;
      if (fill == 64) { block(buf); fill = 0; }
    }
  }
  std::string hex() {
    uint64_t bits = total * 8;
    unsigned char pad = 0x80;
    update(&pad, 1);
    pad = 0;
    while (fill != 56) update(&pad, 1);
    unsigned char len[8];
    for (int i = 0; i < 8; i++) len[i] = (unsigned char)(bits >> (56 - 8 * i));
    update(len, 8);
    static const char* d = "0123456789abcdef";
    std::string o;
    for (uint32_t v : h)
      for (int i = 28; i >= 0; i -= 4) o += d[(v >> i) & 15];
    return o;
  }
};
}  // namespace

std::string sha256_bytes(const std::string& data) {
  Sha256 s;
  s.update(reinterpret_cast<const unsigned char*>(data.data()), data.size());
  return s.hex();
}

std::string sha256_file(const fs::path& p) {
  std::ifstream in(p, std::ios::binary);
  if (!in) return {};
  Sha256 s;
  std::vector<char> buf(1 << 20);
  while (in.read(buf.data(), (std::streamsize)buf.size()) || in.gcount() > 0) s.update(reinterpret_cast<const unsigned char*>(buf.data()), (size_t)in.gcount());
  return s.hex();
}

std::string file_key(const fs::path& p) {
  auto fi = plat::file_info(p.wstring());
  return plat::to_utf8(p.wstring()) + "|" + std::to_string(fi.size) + "|" + std::to_string(fi.mtime);
}

std::string fingerprint(const fs::path& p, State& s) {
  const std::string key = file_key(p);
  auto it = s.find(key);
  if (it != s.end() && it->second.size() == 65 && it->second[0] == '#') return it->second.substr(1);
  std::string h = sha256_file(p);
  if (h.empty()) return h;
  remember(s, key, "#" + h);
  return h;
}

bool is_stable(const fs::path& p) {
  auto fi = plat::file_info(p.wstring());
  return fi.ok && fi.size > 0 && fi.now >= fi.mtime && (fi.now - fi.mtime) >= (uint64_t)kStableSeconds;
}

bool looks_like_replay(const fs::path& p) {
  std::ifstream in(p, std::ios::binary);
  unsigned char h[8] = {};
  in.read(reinterpret_cast<char*>(h), 8);
  const std::streamsize n = in.gcount();
  const bool zstd = n >= 4 && h[0] == 0x28 && h[1] == 0xB5 && h[2] == 0x2F && h[3] == 0xFD;
  const bool plain = n >= 8 && std::memcmp(h, "dissect\0", 8) == 0;   // current game versions write the .rec uncompressed
  return zstd || plain;
}

std::vector<fs::path> scan(const fs::path& folder, State& state) {
  std::vector<std::pair<uint64_t, fs::path>> found;
  std::error_code ec;
  for (fs::recursive_directory_iterator it(folder, fs::directory_options::skip_permission_denied, ec), end; !ec && it != end; it.increment(ec)) {
    if (!it->is_regular_file(ec) || !is_rec(it->path())) continue;
    const fs::path& p = it->path();
    if (!is_stable(p)) continue;
    const std::string h = fingerprint(p, state);
    if (h.empty() || is_done(state, h)) continue;
    found.emplace_back(plat::file_info(p.wstring()).mtime, p);
  }
  std::sort(found.begin(), found.end(), [](auto& a, auto& b) { return a.first < b.first; });
  std::vector<fs::path> out;
  for (auto& f : found) out.push_back(f.second);
  return out;
}

std::string human_size(uint64_t b) {
  char buf[32];
  if (b >= (1ull << 20)) std::snprintf(buf, sizeof buf, "%.1f MB", (double)b / (1 << 20));
  else if (b >= 1024) std::snprintf(buf, sizeof buf, "%.0f KB", (double)b / 1024);
  else std::snprintf(buf, sizeof buf, "%llu B", (unsigned long long)b);
  return buf;
}

std::string human_speed(double bps) {
  char buf[32];
  if (bps >= (1 << 20)) std::snprintf(buf, sizeof buf, "%.1f MB/s", bps / (1 << 20));
  else std::snprintf(buf, sizeof buf, "%.0f KB/s", bps / 1024);
  return buf;
}

static std::string header_hex(const fs::path& p) {
  std::ifstream in(p, std::ios::binary);
  unsigned char h[8] = {};
  in.read(reinterpret_cast<char*>(h), 8);
  std::string o = "it starts with";
  char b[4];
  for (std::streamsize i = 0; i < in.gcount(); i++) { std::snprintf(b, sizeof b, " %02X", h[i]); o += b; }
  return in.gcount() == 0 ? "it is empty" : o;
}

std::string log_file_path() { return plat::to_utf8((data_dir() / "uploader.log").wstring()); }

static std::string stamp(const char* fmt) {
  std::time_t t = std::time(nullptr);
  char buf[32];
  std::strftime(buf, sizeof buf, fmt, std::localtime(&t));
  return buf;
}

void write_log_file(const std::string& msg) {
  const fs::path p = data_dir() / "uploader.log";
  std::error_code ec;
  if (fs::exists(p, ec) && fs::file_size(p, ec) > (1u << 20)) fs::rename(p, data_dir() / "uploader.log.old", ec);   // keep one older copy
  std::ofstream out(p, std::ios::app);
  out << stamp("%Y-%m-%d %H:%M:%S") << "  " << msg << "\n";
}

static std::string url_encode(const std::string& s) {
  static const char* hex = "0123456789ABCDEF";
  std::string o;
  for (unsigned char c : s) {
    if (std::isalnum(c) || c == '-' || c == '.' || c == '_' || c == '~') o += (char)c;
    else { o += '%'; o += hex[c >> 4]; o += hex[c & 15]; }
  }
  return o;
}


bool is_done(const State& s, const std::string& sha) {
  auto it = s.find(sha);
  if (it == s.end()) return false;
  const std::string& v = it->second;
  const bool failure = v == "failed" || v.rfind("failed:", 0) == 0 || v.rfind("invalid:", 0) == 0;
  if (!failure) return true;
  // A failure is final only for the reader that produced it. A newer reader may cope with what an older one could not
  // (a game patch added an operator), and a plain "failed" comes from version 1.1.0 and earlier, which read on the server.
  return v == std::string("failed:") + kParserVersion || v == std::string("invalid:") + kParserVersion;
}

std::string failure_reason(const std::string& output) {
  std::vector<std::string> lines;
  std::stringstream ss(output);
  for (std::string l; std::getline(ss, l);) {
    // strip colour codes
    std::string c;
    for (size_t i = 0; i < l.size(); i++) {
      if (l[i] == '\x1b' && i + 1 < l.size() && l[i + 1] == '[') { while (i < l.size() && l[i] != 'm') i++; continue; }
      c += l[i];
    }
    c = trim(c);
    if (!c.empty()) lines.push_back(c);
  }
  for (const auto& l : lines) {
    if (l.rfind("panic:", 0) == 0) return l.substr(0, 280) + (l.find("role unknown") != std::string::npos ? ". The game has an operator this reader does not know yet." : "");
  }
  for (const auto& l : lines)
    if (l.find("FTL") != std::string::npos || l.find("error=") != std::string::npos) return l.substr(0, 300);
  return lines.empty() ? "the reader failed" : lines.back().substr(0, 300);
}

// The fields the apps read from r6-dissect's output, and nothing else. The server's trim_dissect() does the same
// and a test compares the two on real replays, so the apps see exactly what they saw before.
std::string trim_round(const std::string& dissect_json, std::string& error) {
  mini::Json full;
  if (!mini::parse(dissect_json, full) || full.type != mini::Json::Obj) { error = "the reader's output is not JSON"; return {}; }
  const mini::Json& h = full.o.count("header") ? full.at("header") : full;
  auto pick = [](const mini::Json& from, std::initializer_list<const char*> keys) {
    mini::Json out;
    out.type = mini::Json::Obj;
    for (const char* k : keys) {
      auto it = from.o.find(k);
      if (it != from.o.end() && it->second.type != mini::Json::Null) out.o[k] = it->second;
    }
    return out;
  };
  mini::Json out = pick(h, {"matchID", "roundNumber", "roundsPerMatch", "timestamp", "map", "matchType", "gamemode", "site", "recordingProfileID", "overtimeRoundNumber", "roundsPerMatchOvertime", "gameVersion"});
  auto list = [&](const mini::Json& src, std::initializer_list<const char*> keys) {
    mini::Json arr;
    arr.type = mini::Json::Arr;
    for (const auto& x : src.a) arr.a.push_back(pick(x, keys));
    return arr;
  };
  out.o["teams"] = list(h.at("teams"), {"role", "score", "startingScore", "won", "winCondition"});
  out.o["players"] = list(h.at("players"), {"username", "teamIndex", "operator", "profileID", "spawn"});
  const mini::Json& events = full.o.count("matchFeedback") ? full.at("matchFeedback") : h.at("matchFeedback");
  out.o["matchFeedback"] = list(events, {"type", "username", "target", "headshot", "timeInSeconds", "operator", "message"});
  if (out.at("matchID").type != mini::Json::Str || events.type != mini::Json::Arr) { error = "the reader's output has no match id or events"; return {}; }
  return mini::dump(out);
}

// ---------- a one-line summary of a round, for the log ----------

std::string map_display_name(const std::string& raw) {
  // Numeric ids from the r6-dissect source (dissect/map_string.go); the same table as the phone app's map_names.dart.
  static const std::map<std::string, const char*> ids = {
    {"355496559878", "Bank"}, {"413779563590", "Bank"}, {"2697268122", "Bartlett University"}, {"305979357167", "Border"}, {"407987100456", "Border"},
    {"259816839773", "Chalet"}, {"407558616688", "Chalet"}, {"837214085", "Clubhouse"}, {"407193663917", "Clubhouse"}, {"42090092951", "Coastline"},
    {"2609221242", "Consulate"}, {"379218689149", "Consulate"}, {"418126004176", "Consulate"}, {"365284490964", "Emerald Plains"}, {"329867321446", "Favela"},
    {"126196841359", "Fortress"}, {"127951053400", "Hereford Base"}, {"237873412352", "House"}, {"1378191338", "Kafe Dostoyevsky"}, {"413845419788", "Kafe Dostoyevsky"},
    {"1460220617", "Kanal"}, {"388073319671", "Lair"}, {"417890697769", "Lair"}, {"378595635123", "Nighthaven Labs"}, {"418119057546", "Nighthaven Labs"},
    {"231702797556", "Oregon"}, {"362605108559", "Outback"}, {"2609218856", "Presidential Plane"}, {"276279025182", "Skyscraper"}, {"405306299908", "Stadium"},
    {"270063334510", "Stadium Bravo"}, {"199824623654", "Theme Park"}, {"53627213396", "Tower"}, {"88107330328", "Villa"}, {"1767965020", "Yacht"},
    // identified from their bombsite and spawn names in real replays
    {"398899676157", "Fortress"}, {"409325881472", "Villa"}, {"430788891316", "Theme Park"}, {"434715462383", "Oregon"}, {"436375283234", "Coastline"}, {"441408792952", "Kanal"}, {"441825219764", "Outback"},
  };
  static const char* names[] = {"Bank", "Border", "Calypso Casino", "Chalet", "Close Quarter", "Clubhouse", "Coastline", "Consulate", "District", "Emerald Plains", "Favela", "Fortress",
    "Hereford Base", "House", "Kafe Dostoyevsky", "Kanal", "Lair", "Nighthaven Labs", "Oregon", "Outback", "Presidential Plane", "Skyscraper",
    "Stadium Alpha", "Stadium Bravo", "Theme Park", "Tower", "Villa", "Yacht"};
  auto key = [](const std::string& x) { std::string k; for (unsigned char c : x) if (std::isalnum(c)) k += (char)std::tolower(c); return k; };
  std::string s = raw, id;
  if (s.rfind("Map(", 0) == 0 && s.size() > 5 && s.back() == ')') id = s.substr(4, s.size() - 5);
  else if (s.size() >= 6 && std::all_of(s.begin(), s.end(), [](unsigned char c) { return std::isdigit(c); })) id = s;
  if (!id.empty()) {
    auto it = ids.find(id);
    return it != ids.end() ? it->second : "Unknown map " + (id.size() > 4 ? id.substr(id.size() - 4) : id);
  }
  // "BorderY10" or "Theme Park2020": drop the season suffix.
  size_t end = s.size();
  if (end > 4 && s.compare(end - 4, 4, "2020") == 0) end -= 4;
  else {
    size_t d = end;
    while (d > 0 && std::isdigit((unsigned char)s[d - 1])) d--;
    if (d < end && d > 0 && s[d - 1] == 'Y') end = d - 1;
  }
  const std::string base = s.substr(0, end);
  for (const char* n : names) if (key(n) == key(base)) return n;
  std::string spaced;
  for (size_t i = 0; i < base.size(); i++) {
    if (i && std::isupper((unsigned char)base[i]) && std::isalnum((unsigned char)base[i - 1]) && !std::isupper((unsigned char)base[i - 1])) spaced += ' ';
    spaced += base[i];
  }
  return spaced;
}

static std::string name_of(const mini::Json& v) { return v.type == mini::Json::Obj ? v.at("name").str() : v.str(); }

static bool same_name(const std::string& a, const std::string& b) {
  if (a.empty() || a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); i++) if (std::tolower((unsigned char)a[i]) != std::tolower((unsigned char)b[i])) return false;
  return true;
}

std::string round_summary(const std::string& round_json) {
  mini::Json r;
  if (!mini::parse(round_json, r) || r.type != mini::Json::Obj) return "";
  const int number = (int)r.at("roundNumber").n + 1;
  std::string head = "Round " + std::to_string(number) + " on " + map_display_name(name_of(r.at("map")));
  const std::string type = name_of(r.at("matchType"));
  if (!type.empty() && type.rfind("MatchType(", 0) != 0) {
    std::string words;   // QuickMatch -> Quick Match
    for (size_t i = 0; i < type.size(); i++) {
      if (i && std::isupper((unsigned char)type[i]) && std::islower((unsigned char)type[i - 1])) words += ' ';
      words += type[i];
    }
    head += " (" + words + ")";
  }
  // Who recorded the round: that is the person at this PC.
  const std::string me = r.at("recordingProfileID").str();
  const mini::Json* mine = nullptr;
  for (size_t i = 0; !r.at("players").at(i).isNull(); i++)
    if (!me.empty() && r.at("players").at(i).at("profileID").str() == me) mine = &r.at("players").at(i);
  const auto& teams = r.at("teams");
  if (!mine) {
    for (size_t i = 0; !teams.at(i).isNull(); i++)
      if (teams.at(i).at("won").type == mini::Json::Bool && teams.at(i).at("won").b) return head + ": " + teams.at(i).at("role").str() + " won";
    return head;
  }
  const std::string name = mine->at("username").str();
  const mini::Json& team = teams.at((size_t)mine->at("teamIndex").n);
  const bool attack = team.at("role").str() == "Attack";
  const bool won = team.at("won").type == mini::Json::Bool && team.at("won").b;
  int kills = 0, hs = 0;
  bool died = false;
  for (size_t i = 0; !r.at("matchFeedback").at(i).isNull(); i++) {
    const auto& e = r.at("matchFeedback").at(i);
    const std::string t = name_of(e.at("type"));
    if (t == "Kill" && same_name(e.at("username").str(), name)) { kills++; if (e.at("headshot").type == mini::Json::Bool && e.at("headshot").b) hs++; }
    if ((t == "Kill" && same_name(e.at("target").str(), name)) || (t == "Death" && same_name(e.at("username").str(), name))) died = true;
  }
  std::string out = head + ": you " + (attack ? "attacked" : "defended") + " and " + (won ? "won" : "lost") + ". " + std::to_string(kills) + (kills == 1 ? " kill" : " kills");
  if (hs) out += ", " + std::to_string(hs) + (hs == 1 ? " headshot" : " headshots");
  const std::string op = name_of(mine->at("operator"));
  return out + (died ? ", died" : ", survived") + (op.empty() ? "" : " as " + op);
}

static std::string payload_head(const std::string& file, const std::string& sha, uint64_t size) {
  return std::string("{\"schema_version\":1,\"parser_version\":") + mini::quote(kParserVersion) + ",\"parser\":{\"name\":\"r6-dissect\",\"build\":" + mini::quote(kParserBuild) + "},\"source\":{\"sha256\":" + mini::quote(sha) + ",\"size\":" + std::to_string(size) + ",\"file\":" + mini::quote(file) + "}";
}

std::string failure_payload(const std::string& file, const std::string& sha, uint64_t size, const std::string& reason) {
  return payload_head(file, sha, size) + ",\"failed\":{\"reason\":" + mini::quote(reason.empty() ? "the reader failed" : reason.substr(0, 290)) + "}}";
}

LocalRead read_replay(const fs::path& rec, const std::string& sha, uint64_t size) {
  LocalRead r;
  const fs::path helper = fs::path(plat::helper_path());
  std::error_code ec;
  if (helper.empty() || !fs::is_regular_file(helper, ec)) { r.helper_unusable = true; r.reason = "the replay reader is missing"; return r; }
  const fs::path tmpdir = data_dir() / "tmp";
  fs::create_directories(tmpdir, ec);
  const fs::path out = tmpdir / (sha.substr(0, 16) + ".json");
  fs::remove(out, ec);
  const auto t0 = std::chrono::steady_clock::now();
  const auto run = plat::run_helper(helper.wstring(), {rec.wstring(), L"-o", out.wstring()}, 120000);
  r.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  if (!run.started) { r.helper_unusable = true; r.reason = "the replay reader could not be started"; return r; }
  if (run.timed_out) { r.reason = "reading took longer than 2 minutes"; fs::remove(out, ec); return r; }
  if (run.exit_code != 0) {
    // 0xC00000xx with nothing printed is Windows refusing to run the program (a missing system function on an older Windows).
    if (run.exit_code >= 0xC0000000u && trim(run.output).empty()) { r.helper_unusable = true; r.reason = "this version of Windows cannot run the replay reader"; return r; }
    r.reason = failure_reason(run.output);
    fs::remove(out, ec);
    return r;
  }
  std::ifstream in(out, std::ios::binary);
  std::string json((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  in.close();
  fs::remove(out, ec);
  if (json.empty()) { r.reason = "the reader produced no output"; return r; }
  std::string err;
  const std::string round = trim_round(json, err);
  if (round.empty()) { r.reason = err; return r; }
  r.payload = payload_head(plat::to_utf8(rec.filename().wstring()), sha, size) + ",\"round\":" + round + "}";
  r.summary = round_summary(round);
  r.ok = true;
  return r;
}

static bool server_reads_parsed(const Config& cfg) {
  auto h = plat::http_get(cfg.server + "/health", "");
  mini::Json j;
  return h.status == 200 && mini::parse(h.body, j) && j.at("parsed").type == mini::Json::Bool && j.at("parsed").b;
}

Counts sync_once(const Config& cfg, State& state, const Logger& log, const Progress& progress, const RoundHook& onRound) {
  const auto say = [&](const std::string& m) {
    write_log_file(m);
    log(stamp("%H:%M:%S") + "  " + m);
  };
  Counts n;
  std::error_code ec;
  if (!fs::is_directory(cfg.folder, ec)) {
    say("The replay folder is missing: " + plat::to_utf8(cfg.folder.wstring()));
    return n;
  }
  struct Item { fs::path path; std::string name, sha; };
  std::vector<Item> todo;
  for (const auto& p : scan(cfg.folder, state)) {
    const std::string name = plat::to_utf8(p.filename().wstring()), sha = fingerprint(p, state);
    if (!looks_like_replay(p)) {   // never sent: not a Siege replay
      remember(state, sha, "skipped");
      n.skipped++;
      if (n.skipped <= 3) say(name + ": NOT uploaded, " + human_size(plat::file_info(p.wstring()).size) + ", " + header_hex(p) + ". A replay starts with dissect (64 69 73 73 65 63 74 00) or 28 B5 2F FD");
      continue;
    }
    todo.push_back({p, name, sha});
  }
  if (n.skipped > 3) say("... and " + std::to_string(n.skipped - 3) + " more files that are not in the replay format, " + std::to_string(n.skipped) + " in all. They are not sent.");
  if (todo.empty()) return n;
  say("Found " + std::to_string(todo.size()) + " replay" + (todo.size() == 1 ? "" : "s") + " to check against the server");
  // Check the token with a tiny request first. A server that rejects a token answers at once and closes
  // the connection, which would look like a network error halfway through streaming a big file.
  auto pre = plat::http_post_empty(cfg.server + "/v1/upload", cfg.token);
  if (pre.status == 0) {
    n.error++;
    say("Cannot reach the server: " + pre.error + ". Will try again.");
    return n;
  }
  if (pre.status == 401 || pre.status == 403) {
    n.error++;
    say(pre.status == 403 ? "That is the READ token. The PC needs the UPLOAD token." : "The server rejected the upload token. Check it in the settings.");
    return n;
  }
  // Ask the server what it already has. This is what makes "already uploaded" true across reinstalls,
  // new PCs and copied or renamed files. An older server without this call just gets the files (it ignores duplicates).
  std::set<std::string> have, failedOnServer;
  for (size_t i = 0; i < todo.size(); i += 500) {
    std::string body = "{\"hashes\":[";
    for (size_t k = i; k < std::min(todo.size(), i + 500); k++) body += (k > i ? ",\"" : "\"") + todo[k].sha + "\"";
    body += "]}";
    auto r = plat::http_post_json(cfg.server + "/v1/known", cfg.token, body);
    mini::Json j;
    if (r.status != 200 || !mini::parse(r.body, j)) break;
    const mini::Json& arr = j.at("known");
    for (size_t k = 0; !arr.at(k).isNull(); k++) have.insert(arr.at(k).str());
    const mini::Json& bad = j.at("failed");   // stored as failed there: worth another try with this reader
    for (size_t k = 0; !bad.at(k).isNull(); k++) failedOnServer.insert(bad.at(k).str());
  }
  for (const auto& it : todo) {
    if (!have.count(it.sha)) continue;
    if (failedOnServer.count(it.sha) && !is_done(state, it.sha)) { have.erase(it.sha); continue; }   // try again with this reader
    if (failedOnServer.count(it.sha)) continue;   // this reader already failed on it: leave it
    remember(state, it.sha, "on server");
    n.known++;
  }
  if (n.known) say(std::to_string(n.known) + " replay" + (n.known == 1 ? " is" : "s are") + " already on the server.");
  const auto pending = [&](const Item& it) { return !have.count(it.sha) && !is_done(state, it.sha) && !failedOnServer.count(it.sha); };
  const auto pendingRetry = [&](const Item& it) { return failedOnServer.count(it.sha) && !is_done(state, it.sha); };
  int toSend = 0;
  for (const auto& it : todo)
    if (pending(it) || pendingRetry(it)) toSend++;
  if (toSend == 0) return n;

  // Where each replay is read: on this PC when the bundled reader runs here and the server understands the result, else on the server.
  bool local = true;
  if (!server_reads_parsed(cfg)) { local = false; say("This server reads replays itself, so the files are sent whole."); }
  else if (!fs::is_regular_file(fs::path(plat::helper_path()), ec)) { local = false; say("The replay reader could not be unpacked, so the files are sent whole."); }
  int index = 0;
  for (const auto& it : todo) {
    if (!(pending(it) || pendingRetry(it))) continue;
    index++;
    const uint64_t fileSize = plat::file_info(it.path.wstring()).size;
    bool needRaw = !local;   // this replay goes to the server as the file itself

    if (local) {
      say("Reading " + std::to_string(index) + " of " + std::to_string(toSend) + ": " + it.name + " (" + human_size(fileSize) + ") on this PC");
      if (progress) progress(UploadStatus{it.name, 0, 0, 0, index, toSend, "Reading"});
      const LocalRead lr = read_replay(it.path, it.sha, fileSize);
      if (lr.helper_unusable) {
        local = false;
        needRaw = true;
        say("Cannot read replays here: " + lr.reason + ". Sending the files themselves, the old way.");
      } else {
        std::string body = lr.payload;
        bool failedRead = !lr.ok;
        if (lr.ok) {
          char took[32];
          std::snprintf(took, sizeof took, "%.1f", lr.seconds);
          say(it.name + ": read in " + took + " s. Sending " + human_size(body.size()) + " instead of " + human_size(fileSize));
          if (!lr.summary.empty()) say("  " + lr.summary);
          if (onRound) {   // live clips: before the upload, since OBS's buffer moves on every second
            mini::Json pj;
            const auto fi = plat::file_info(it.path.wstring());
            // When the game finished writing the replay, on the wall clock (file times use another clock).
            const double written = fi.ok ? std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count() - (double)(fi.now - fi.mtime) : -1;
            if (mini::parse(body, pj)) onRound(mini::dump(pj.at("round")), written);
          }
        } else {
          say(it.name + ": could not be read on this PC: " + lr.reason);
          if (cfg.raw_fallback && fileSize <= kRawFallbackMax) {
            say(it.name + ": sending the file itself so the server can look at it (you can turn this off in the settings)");
            needRaw = true;
            n.fell_back++;
          } else {
            body = failure_payload(it.name, it.sha, fileSize, lr.reason);
            say(it.name + (fileSize > kRawFallbackMax ? ": too large to send whole, " : ": ") + "recording the failure on the server");
          }
        }
        if (!needRaw) {
          const auto t0 = std::chrono::steady_clock::now();
          if (progress) progress(UploadStatus{it.name, body.size(), body.size(), 0, index, toSend, "Uploading"});
          auto r = plat::http_post_json(cfg.server + "/v1/parsed", cfg.token, body);
          const double secs = std::max(0.001, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
          mini::Json j;
          const bool parsedJson = mini::parse(r.body, j);
          if (r.status == 0) { n.error++; say(it.name + ": NOT complete, " + r.error + ". Will try again."); break; }
          if (r.status == 401 || r.status == 403) { n.error++; say(it.name + ": NOT complete. The server rejected the upload token. Check it in the settings."); break; }
          if (r.status == 426) {
            n.error++;
            n.update_needed = true;
            n.update_message = parsedJson && !j.at("message").str().empty() ? j.at("message").str() : "Please update your uploader.";
            say(it.name + ": NOT sent. " + n.update_message);
            break;   // every other replay would be refused the same way
          }
          if (r.status == 422 || r.status == 413) {
            const std::string why = parsedJson && !j.at("message").str().empty() ? j.at("message").str() : (r.status == 413 ? "the data was too large" : "the data was not accepted");
            n.rejected++;
            remember(state, it.sha, std::string("invalid:") + kParserVersion);
            say(it.name + ": the server did not accept the data: " + why);
            continue;
          }
          const mini::Json& res = j.at("results").at(0);
          if (r.status != 200 || !parsedJson || res.isNull()) { n.error++; say(it.name + ": NOT complete, the server answered " + std::to_string(r.status) + ". Will try again."); break; }
          const std::string status = res.at("status").str("?"), err = res.at("error").str();
          if (status == "parsed") n.parsed++;
          else if (status == "duplicate") n.duplicate++;
          else if (status == "failed") n.failed++;
          else n.rejected++;
          if (!failedRead && (status == "parsed" || status == "duplicate")) n.local++;   // read here and sent as small JSON
          n.bytes += body.size();
          // A failure is only final for this reader version, even when the server answers "duplicate" because it already holds one.
          remember(state, it.sha, (failedRead || status == "failed") ? std::string("failed:") + kParserVersion : status);
          char took[32];
          std::snprintf(took, sizeof took, "%.1f s", secs);
          say(it.name + ": " + status + (err.empty() ? "" : " (" + err + ")") + (failedRead ? "" : ". Upload complete: " + human_size(body.size()) + " in " + took));
          continue;
        }
      }
    }
    if (!needRaw) continue;
    const uint64_t total = plat::file_info(it.path.wstring()).size;
    say("Uploading " + std::to_string(index) + " of " + std::to_string(toSend) + ": " + it.name + " (" + human_size(total) + ")");
    const auto t0 = std::chrono::steady_clock::now();
    auto elapsed = [&] { return std::max(0.001, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count()); };
    uint64_t sent = 0;
    int mark = 25;
    auto last_ui = t0;
    auto onProgress = [&](uint64_t s, uint64_t t) {
      sent = s;
      UploadStatus st{it.name, s, t, (double)s / elapsed(), index, toSend};
      const auto now = std::chrono::steady_clock::now();
      if (progress && (s >= t || now - last_ui >= std::chrono::milliseconds(150))) { progress(st); last_ui = now; }
      while (mark < 100 && st.percent() >= mark) {
        say(it.name + ": " + std::to_string(mark) + "%  " + human_size(s) + " of " + human_size(t) + "  " + human_speed(st.bytes_per_second));
        mark += 25;
      }
    };
    auto r = plat::http_upload(cfg.server + "/v1/upload/raw?filename=" + url_encode(it.name), cfg.token, it.path.wstring(), onProgress);
    const std::string where = std::to_string(total ? (int)(sent * 100 / total) : 0) + "% (" + human_size(sent) + " of " + human_size(total) + ")";
    if (r.status == 0) {
      n.error++;
      say(it.name + ": NOT complete, stopped at " + where + ": " + r.error + ". Will try again.");
      break;   // the server is probably unreachable: keep the files for the next pass
    }
    if (r.status == 401 || r.status == 403) {
      n.error++;
      say(it.name + ": NOT complete. The server rejected the upload token. Check it in the settings.");
      break;
    }
    mini::Json j;
    if (r.status != 200 || !mini::parse(r.body, j)) {
      n.error++;
      say(it.name + ": NOT complete, the server answered " + std::to_string(r.status) + ". Will try again.");
      break;
    }
    const mini::Json& res = j.at("results").at(0);
    const std::string status = res.at("status").str("?"), err = res.at("error").str();
    if (status == "parsed") n.parsed++;
    else if (status == "duplicate") n.duplicate++;
    else if (status == "failed") n.failed++;
    else n.rejected++;
    n.bytes += total;
    remember(state, it.sha, status == "failed" ? std::string("failed:") + kParserVersion : status);
    const double secs = elapsed();
    char took[48];
    std::snprintf(took, sizeof took, "%.1f s", secs);
    say(it.name + ": " + status + (err.empty() ? "" : " (" + err + ")") + ". Upload complete: " + human_size(total) + " in " + took + ", average " + human_speed((double)total / secs));
  }
  if (n.uploaded() > 0) say("Done: " + std::to_string(n.uploaded()) + " uploaded (" + human_size(n.bytes) + "), " + std::to_string(n.known) + " already on the server" + (n.error ? ", " + std::to_string(n.error) + " problem(s), will retry" : ""));
  return n;
}

// ---------------------------------------------------------------- noticing new files
static long long now_ms() { return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

Watcher::Watcher(fs::path folder, int quiet_seconds) : folder_(std::move(folder)), quiet_(quiet_seconds) {}

Watcher::~Watcher() { if (handle_) plat::watch_close(handle_); }

bool Watcher::wait_settled(int ms) {
  const long long end = now_ms() + ms;
  for (;;) {
    if (!handle_) {
      handle_ = plat::watch_open(folder_.wstring());   // the game creates the folder after the first match: keep trying
      if (handle_) { pending_ = true; last_ms_ = now_ms(); }   // whatever is there already counts as a change
    }
    const long long left = end - now_ms();
    if (left <= 0) return false;
    const int slice = (int)std::min<long long>(left, 500);
    if (!handle_) {
      std::this_thread::sleep_for(std::chrono::milliseconds(slice));
      continue;
    }
    if (plat::watch_wait(handle_, slice)) {
      pending_ = true;
      last_ms_ = now_ms();
    } else if (pending_ && now_ms() - last_ms_ >= quiet_ * 1000LL) {
      pending_ = false;
      return true;
    }
  }
}

}  // namespace core
