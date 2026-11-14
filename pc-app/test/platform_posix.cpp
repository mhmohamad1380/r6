// Test-only stand-in for platform_win.cpp so core.cpp can run natively on Linux against a real server.
// Plain HTTP over sockets, a reversible fake for DPAPI, and fake "drives" and "registry" taken from the environment.
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <functional>
#include <sstream>

#include "../src/platform.hpp"

namespace plat {

std::string to_utf8(const std::wstring& w) {
  std::string o;
  for (wchar_t c : w) {
    unsigned cp = (unsigned)c;
    if (cp < 0x80) o += (char)cp;
    else if (cp < 0x800) { o += (char)(0xC0 | (cp >> 6)); o += (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) { o += (char)(0xE0 | (cp >> 12)); o += (char)(0x80 | ((cp >> 6) & 0x3F)); o += (char)(0x80 | (cp & 0x3F)); }
    else { o += (char)(0xF0 | (cp >> 18)); o += (char)(0x80 | ((cp >> 12) & 0x3F)); o += (char)(0x80 | ((cp >> 6) & 0x3F)); o += (char)(0x80 | (cp & 0x3F)); }
  }
  return o;
}

std::wstring from_utf8(const std::string& s) {
  std::wstring w;
  for (size_t i = 0; i < s.size();) {
    unsigned char c = (unsigned char)s[i];
    unsigned cp, n;
    if (c < 0x80) { cp = c; n = 1; }
    else if (c < 0xE0) { cp = c & 0x1F; n = 2; }
    else if (c < 0xF0) { cp = c & 0x0F; n = 3; }
    else { cp = c & 0x07; n = 4; }
    for (unsigned k = 1; k < n && i + k < s.size(); k++) cp = (cp << 6) | ((unsigned char)s[i + k] & 0x3F);
    w += (wchar_t)cp;
    i += n;
  }
  return w;
}

std::wstring env(const wchar_t* name) {
  const char* v = std::getenv(to_utf8(name).c_str());
  return v ? from_utf8(v) : std::wstring();
}

std::wstring app_data_dir() {
  std::string base = std::getenv("APPDATA") ? std::getenv("APPDATA") : "/tmp";
  std::filesystem::path p = std::filesystem::path(base) / "R6ReplayUploader";
  std::error_code ec;
  std::filesystem::create_directories(p, ec);
  return from_utf8(p.string());
}

static std::vector<std::wstring> split_env(const char* name) {
  std::vector<std::wstring> out;
  const char* v = std::getenv(name);
  if (!v) return out;
  std::stringstream ss(v);
  std::string part;
  while (std::getline(ss, part, ':'))
    if (!part.empty()) out.push_back(from_utf8(part));
  return out;
}
std::vector<std::wstring> fixed_drives() { return split_env("R6_TEST_DRIVES"); }
std::vector<std::wstring> registry_install_dirs() { return split_env("R6_TEST_INSTALL"); }

FileInfo file_info(const std::wstring& path) {
  FileInfo fi;
  struct stat st;
  if (stat(to_utf8(path).c_str(), &st) != 0) return fi;
  fi.size = (uint64_t)st.st_size;
  fi.mtime = (uint64_t)st.st_mtime;
  fi.now = (uint64_t)std::time(nullptr);
  fi.ok = true;
  return fi;
}

std::string protect(const std::string& plain) {   // fake, reversible, and not readable as plain text
  static const char* h = "0123456789abcdef";
  std::string o;
  for (unsigned char c : plain) { c ^= 0x5A; o += h[c >> 4]; o += h[c & 15]; }
  return o;
}
std::string unprotect(const std::string& hex) {
  std::string o;
  for (size_t i = 0; i + 1 < hex.size(); i += 2) o += (char)(std::strtoul(hex.substr(i, 2).c_str(), nullptr, 16) ^ 0x5A);
  return o;
}

// ---------------------------------------------------------------- plain HTTP/1.1
static HttpResult request(const std::string& url, const char* method, const std::string& bearer, uint64_t length, const std::function<bool(int)>& body, const char* content_type) {
  HttpResult r;
  if (url.rfind("http://", 0) != 0) { r.error = "https is not supported by the test shim"; return r; }
  std::string rest = url.substr(7), hostport = rest.substr(0, rest.find('/')), path = rest.find('/') == std::string::npos ? "/" : rest.substr(rest.find('/'));
  std::string host = hostport.substr(0, hostport.find(':')), port = hostport.find(':') == std::string::npos ? "80" : hostport.substr(hostport.find(':') + 1);
  addrinfo hints{}, *res = nullptr;
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo(host.c_str(), port.c_str(), &hints, &res) != 0) { r.error = "the server name was not found"; return r; }
  int fd = socket(res->ai_family, SOCK_STREAM, 0);
  if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) { freeaddrinfo(res); close(fd); r.error = "cannot connect to the server"; return r; }
  freeaddrinfo(res);
  std::string head = std::string(method) + " " + path + " HTTP/1.1\r\nHost: " + hostport + "\r\nConnection: close\r\nContent-Length: " + std::to_string(length) + "\r\n";
  if (!bearer.empty()) head += "Authorization: Bearer " + bearer + "\r\n";
  if (content_type) head += std::string("Content-Type: ") + content_type + "\r\n";
  head += "\r\n";
  if (send(fd, head.data(), head.size(), MSG_NOSIGNAL) < 0 || (body && !body(fd))) { close(fd); r.error = "the connection was interrupted"; return r; }
  std::string all;
  char buf[65536];
  for (ssize_t n; (n = recv(fd, buf, sizeof(buf), 0)) > 0;) all.append(buf, (size_t)n);
  close(fd);
  size_t split = all.find("\r\n\r\n");
  if (all.rfind("HTTP/1.1 ", 0) != 0 || split == std::string::npos) { r.error = "the server did not answer"; return r; }
  r.status = std::atoi(all.substr(9, 3).c_str());
  r.body = all.substr(split + 4);
  return r;
}

HttpResult http_get(const std::string& url, const std::string& bearer) { return request(url, "GET", bearer, 0, nullptr, nullptr); }
HttpResult http_post_empty(const std::string& url, const std::string& bearer) { return request(url, "POST", bearer, 0, nullptr, nullptr); }
HttpResult http_post_json(const std::string& url, const std::string& bearer, const std::string& json) {
  return request(url, "POST", bearer, json.size(), [&](int fd) { return send(fd, json.data(), json.size(), MSG_NOSIGNAL) == (ssize_t)json.size(); }, "application/json");
}
HttpResult http_send(const std::string& method, const std::string& url, const std::string& bearer, const std::string& data, const std::string& content_type) {
  return request(url, method.c_str(), bearer, data.size(), [&](int fd) { return data.empty() || send(fd, data.data(), data.size(), MSG_NOSIGNAL) == (ssize_t)data.size(); },
                 content_type.empty() ? nullptr : content_type.c_str());
}
HttpResult http_upload(const std::string& url, const std::string& bearer, const std::wstring& file_path, const UploadProgress& onProgress) {
  std::ifstream in(std::filesystem::path(to_utf8(file_path)), std::ios::binary);
  if (!in) { HttpResult r; r.error = "the file could not be opened"; return r; }
  uint64_t size = file_info(file_path).size;
  uint64_t sent = 0;
  if (onProgress) onProgress(0, size);
  return request(url, "POST", bearer, size, [&](int fd) {
    char buf[1 << 16];
    while (in.read(buf, sizeof(buf)) || in.gcount() > 0) {
      std::streamsize n = in.gcount();
      for (std::streamsize off = 0; off < n;) {
        ssize_t w = send(fd, buf + off, (size_t)(n - off), MSG_NOSIGNAL);
        if (w <= 0) return false;
        off += w;
        sent += (uint64_t)w;
        if (onProgress) onProgress(sent, size);
      }
    }
    return true;
  }, "application/octet-stream");
}

bool cut_video(const std::wstring&, double, double, const std::wstring&, int, std::string& error) { error = "not available"; return false; }
bool grab_frame_jpeg(const std::wstring&, double, const std::wstring&, int, std::string& error) { error = "not available"; return false; }
bool video_duration(const std::wstring&, double&, std::string& error) { error = "not available"; return false; }
bool cut_parts(const std::vector<std::wstring>&, const std::vector<double>&, const std::vector<double>&, const std::wstring&, int, std::string& error) { error = "not available"; return false; }
bool start_obs(std::string& error) { error = "not available"; return false; }
bool process_running(const std::vector<std::wstring>&) { return std::getenv("R6_TEST_GAME_RUNNING") != nullptr; }

std::wstring program_dir() {
  const char* v = std::getenv("R6_PROGRAM_DIR");
  return v ? from_utf8(std::string(v) + "/") : std::wstring();
}

// Stand-in for launching the replay reader: the Linux build of r6-dissect, named by R6_DISSECT.
std::wstring helper_path() {
  const char* v = std::getenv("R6_DISSECT");
  return v ? from_utf8(v) : std::wstring();
}

RunResult run_helper(const std::wstring& exe, const std::vector<std::wstring>& args, int timeout_ms) {
  RunResult r;
  const std::string path = to_utf8(exe);
  if (access(path.c_str(), X_OK) != 0) return r;
  int fds[2];
  if (pipe(fds) != 0) return r;
  std::vector<std::string> a{path};
  for (const auto& x : args) a.push_back(to_utf8(x));
  pid_t pid = fork();
  if (pid == 0) {
    dup2(fds[1], 1);
    dup2(fds[1], 2);
    close(fds[0]);
    close(fds[1]);
    std::vector<char*> argv;
    for (auto& s : a) argv.push_back(s.data());
    argv.push_back(nullptr);
    execv(path.c_str(), argv.data());
    _exit(127);
  }
  close(fds[1]);
  r.started = pid > 0;
  const auto t0 = std::time(nullptr);
  char buf[4096];
  for (;;) {
    fd_set set;
    FD_ZERO(&set);
    FD_SET(fds[0], &set);
    timeval tv{0, 100000};
    if (select(fds[0] + 1, &set, nullptr, nullptr, &tv) > 0) {
      ssize_t n = read(fds[0], buf, sizeof buf);
      if (n <= 0) break;
      if (r.output.size() < 16384) r.output.append(buf, (size_t)n);
    }
    if ((std::time(nullptr) - t0) * 1000 > timeout_ms) { kill(pid, SIGKILL); r.timed_out = true; break; }
  }
  int st = 0;
  waitpid(pid, &st, 0);
  close(fds[0]);
  r.exit_code = WIFEXITED(st) ? (uint32_t)WEXITSTATUS(st) : 0xC0000005u;
  return r;
}

// Stand-in for the OS change notification: compares a snapshot of the folder.
static std::string snapshot(const std::string& dir) {
  std::string o;
  std::error_code ec;
  for (std::filesystem::recursive_directory_iterator it(dir, ec), end; !ec && it != end; it.increment(ec)) {
    struct stat st;
    if (stat(it->path().c_str(), &st) == 0) o += it->path().string() + ":" + std::to_string(st.st_size) + ":" + std::to_string(st.st_mtime) + ";";
  }
  return o;
}
struct Watch { std::string dir, last; };
WatchHandle watch_open(const std::wstring& folder) {
  std::string d = to_utf8(folder);
  if (!std::filesystem::is_directory(d)) return nullptr;
  return new Watch{d, snapshot(d)};
}
bool watch_wait(WatchHandle h, int ms) {
  auto* w = static_cast<Watch*>(h);
  for (int waited = 0; waited < ms; waited += 50) {
    std::string now = snapshot(w->dir);
    if (now != w->last) { w->last = now; return true; }
    usleep(50 * 1000);
  }
  return false;
}
void watch_close(WatchHandle h) { delete static_cast<Watch*>(h); }


// ---------- WebSocket over a plain socket (what WinHTTP does on Windows), for talking to a stand-in OBS in tests ----------
namespace {
struct PWs { int fd = -1; };
bool send_all(int fd, const std::string& d) {
  size_t off = 0;
  while (off < d.size()) {
    ssize_t n = ::send(fd, d.data() + off, d.size() - off, MSG_NOSIGNAL);
    if (n <= 0) return false;
    off += (size_t)n;
  }
  return true;
}
bool read_exact(int fd, std::string& out, size_t n, int timeout_ms) {
  out.clear();
  while (out.size() < n) {
    fd_set rs;
    FD_ZERO(&rs);
    FD_SET(fd, &rs);
    timeval tv{timeout_ms / 1000, (timeout_ms % 1000) * 1000};
    if (select(fd + 1, &rs, nullptr, nullptr, &tv) <= 0) return false;
    char buf[4096];
    ssize_t r = ::recv(fd, buf, std::min(sizeof buf, n - out.size()), 0);
    if (r <= 0) return false;
    out.append(buf, (size_t)r);
  }
  return true;
}
}  // namespace

WsHandle ws_open(const std::string& host, int port, std::string& error) {
  addrinfo hints{}, *res = nullptr;
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &res) != 0 || !res) { error = "cannot resolve " + host; return nullptr; }
  int fd = socket(res->ai_family, SOCK_STREAM, 0);
  bool ok = fd >= 0 && connect(fd, res->ai_addr, res->ai_addrlen) == 0;
  freeaddrinfo(res);
  const std::string req = "GET / HTTP/1.1\r\nHost: " + host + ":" + std::to_string(port) + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
  std::string head;
  if (ok) ok = send_all(fd, req);
  while (ok && head.find("\r\n\r\n") == std::string::npos) {
    std::string c;
    ok = read_exact(fd, c, 1, 3000);
    head += c;
  }
  if (!ok || head.find(" 101 ") == std::string::npos) {
    if (fd >= 0) close(fd);
    error = "OBS is not answering on " + host + ":" + std::to_string(port);
    return nullptr;
  }
  auto* w = new PWs();
  w->fd = fd;
  return w;
}

bool ws_send(WsHandle h, const std::string& text) {
  auto* w = (PWs*)h;
  std::string f;
  f += (char)0x81;
  const size_t n = text.size();
  if (n < 126) f += (char)(0x80 | n);
  else if (n < 65536) { f += (char)(0x80 | 126); f += (char)(n >> 8); f += (char)(n & 0xff); }
  else { f += (char)(0x80 | 127); for (int i = 7; i >= 0; i--) f += (char)((uint64_t)n >> (8 * i)); }
  const unsigned char mask[4] = {0x12, 0x34, 0x56, 0x78};
  f.append((const char*)mask, 4);
  for (size_t i = 0; i < n; i++) f += (char)(text[i] ^ mask[i % 4]);
  return w && send_all(w->fd, f);
}

bool ws_recv(WsHandle h, std::string& text, int timeout_ms) {
  auto* w = (PWs*)h;
  if (!w) return false;
  text.clear();
  for (;;) {
    std::string hdr, ext, payload;
    if (!read_exact(w->fd, hdr, 2, timeout_ms)) return false;
    const unsigned char b0 = (unsigned char)hdr[0], b1 = (unsigned char)hdr[1];
    uint64_t n = b1 & 0x7f;
    if (n == 126) { if (!read_exact(w->fd, ext, 2, timeout_ms)) return false; n = ((unsigned char)ext[0] << 8) | (unsigned char)ext[1]; }
    else if (n == 127) { if (!read_exact(w->fd, ext, 8, timeout_ms)) return false; n = 0; for (int i = 0; i < 8; i++) n = (n << 8) | (unsigned char)ext[i]; }
    if (n && !read_exact(w->fd, payload, (size_t)n, timeout_ms)) return false;
    const int op = b0 & 0x0f;
    if (op == 8) return false;                // closed
    if (op == 9 || op == 10) continue;        // ping / pong
    text += payload;
    if (b0 & 0x80) return true;
  }
}

void ws_close(WsHandle h) {
  auto* w = (PWs*)h;
  if (!w) return;
  const char bye[] = {(char)0x88, (char)0x82, 0, 0, 0, 0, 0x03, (char)0xE8};   // a masked close frame, code 1000
  send_all(w->fd, std::string(bye, sizeof bye));
  close(w->fd);
  delete w;
}
}  // namespace plat
