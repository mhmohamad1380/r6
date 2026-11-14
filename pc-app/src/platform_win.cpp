// Windows implementation of platform.hpp: WinHTTP, DPAPI, registry, drives, file times.
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <winhttp.h>
#include <wincrypt.h>

#include <filesystem>
#include <fstream>
#include <functional>
#include <mutex>
#include <string>

#include "platform.hpp"

namespace plat {

std::string to_utf8(const std::wstring& w) {
  if (w.empty()) return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
  std::string s((size_t)n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n, nullptr, nullptr);
  return s;
}

std::wstring from_utf8(const std::string& s) {
  if (s.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring w((size_t)n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
  return w;
}

std::wstring env(const wchar_t* name) {
  DWORD n = GetEnvironmentVariableW(name, nullptr, 0);
  if (n == 0) return {};
  std::wstring v(n, L'\0');
  GetEnvironmentVariableW(name, v.data(), n);
  v.resize(n - 1);
  return v;
}

std::wstring app_data_dir() {
  std::wstring base = env(L"APPDATA");
  if (base.empty()) base = env(L"TEMP");
  std::filesystem::path p = std::filesystem::path(base) / L"R6ReplayUploader";
  std::error_code ec;
  std::filesystem::create_directories(p, ec);
  return p.wstring();
}

std::vector<std::wstring> fixed_drives() {
  std::vector<std::wstring> out;
  DWORD mask = GetLogicalDrives();
  for (int i = 0; i < 26; i++) {
    if (!(mask & (1u << i))) continue;
    std::wstring root = std::wstring(1, (wchar_t)(L'A' + i)) + L":\\";
    if (GetDriveTypeW(root.c_str()) == DRIVE_FIXED) out.push_back(root);
  }
  return out;
}

std::vector<std::wstring> registry_install_dirs() {
  std::vector<std::wstring> out;
  // Ubisoft Connect records where each game is installed. Siege is game id 635.
  const wchar_t* keys[] = {L"SOFTWARE\\WOW6432Node\\Ubisoft\\Launcher\\Installs\\635", L"SOFTWARE\\Ubisoft\\Launcher\\Installs\\635"};
  for (const wchar_t* key : keys) {
    for (REGSAM view : {KEY_WOW64_64KEY, KEY_WOW64_32KEY}) {
      HKEY h;
      if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, key, 0, KEY_READ | view, &h) != ERROR_SUCCESS) continue;
      wchar_t buf[1024];
      DWORD size = sizeof(buf), type = 0;
      if (RegQueryValueExW(h, L"InstallDir", nullptr, &type, (LPBYTE)buf, &size) == ERROR_SUCCESS && type == REG_SZ) out.emplace_back(buf);
      RegCloseKey(h);
    }
  }
  return out;
}

FileInfo file_info(const std::wstring& path) {
  FileInfo fi;
  WIN32_FILE_ATTRIBUTE_DATA d;
  if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &d)) return fi;
  auto secs = [](const FILETIME& f) { return (((uint64_t)f.dwHighDateTime << 32) | f.dwLowDateTime) / 10000000ull; };
  FILETIME now;
  GetSystemTimeAsFileTime(&now);
  fi.size = ((uint64_t)d.nFileSizeHigh << 32) | d.nFileSizeLow;
  fi.mtime = secs(d.ftLastWriteTime);
  fi.now = secs(now);
  fi.ok = true;
  return fi;
}

// ---------------------------------------------------------------- DPAPI
static std::string to_hex(const BYTE* d, DWORD n) {
  static const char* h = "0123456789abcdef";
  std::string s;
  for (DWORD i = 0; i < n; i++) { s += h[d[i] >> 4]; s += h[d[i] & 15]; }
  return s;
}

std::string protect(const std::string& plain) {
  DATA_BLOB in{(DWORD)plain.size(), (BYTE*)plain.data()}, out{};
  if (!CryptProtectData(&in, L"R6 replay uploader token", nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &out)) return {};
  std::string hex = to_hex(out.pbData, out.cbData);
  LocalFree(out.pbData);
  return hex;
}

std::string unprotect(const std::string& hex) {
  if (hex.size() % 2) return {};
  std::vector<BYTE> raw;
  for (size_t i = 0; i < hex.size(); i += 2) raw.push_back((BYTE)std::strtoul(hex.substr(i, 2).c_str(), nullptr, 16));
  DATA_BLOB in{(DWORD)raw.size(), raw.data()}, out{};
  if (!CryptUnprotectData(&in, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &out)) return {};
  std::string s((char*)out.pbData, out.cbData);
  LocalFree(out.pbData);
  return s;
}

// ---------------------------------------------------------------- WinHTTP
static std::string explain(DWORD e) {
  switch (e) {
    case ERROR_WINHTTP_NAME_NOT_RESOLVED: return "the server name was not found";
    case ERROR_WINHTTP_CANNOT_CONNECT: return "cannot connect to the server";
    case ERROR_WINHTTP_CONNECTION_ERROR: return "the connection was interrupted";
    case ERROR_WINHTTP_TIMEOUT: return "the server did not answer in time";
    case ERROR_WINHTTP_SECURE_FAILURE: return "the server's security certificate is not trusted";
    case ERROR_WINHTTP_INVALID_URL: return "the server address is not valid";
    default: return "network error " + std::to_string((unsigned long)e);
  }
}

struct Handle {
  HINTERNET h = nullptr;
  ~Handle() { if (h) WinHttpCloseHandle(h); }
};

static HttpResult request(const std::string& url, const wchar_t* verb, const std::string& bearer, uint64_t length, const std::function<bool(HINTERNET)>& write_body, const wchar_t* content_type) {
  HttpResult res;
  std::wstring w = from_utf8(url);
  wchar_t host[256] = {}, path[2048] = {};
  URL_COMPONENTS uc{};
  uc.dwStructSize = sizeof(uc);
  uc.lpszHostName = host; uc.dwHostNameLength = 255;
  uc.lpszUrlPath = path; uc.dwUrlPathLength = 2047;
  uc.dwSchemeLength = (DWORD)-1;
  wchar_t extra[2048] = {};
  uc.lpszExtraInfo = extra; uc.dwExtraInfoLength = 2047;
  if (!WinHttpCrackUrl(w.c_str(), 0, 0, &uc)) { res.error = explain(ERROR_WINHTTP_INVALID_URL); return res; }
  const bool secure = uc.nScheme == INTERNET_SCHEME_HTTPS;

  Handle ses;
  ses.h = WinHttpOpen(L"R6ReplayUploader/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (!ses.h) ses.h = WinHttpOpen(L"R6ReplayUploader/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (!ses.h) { res.error = explain(GetLastError()); return res; }
  DWORD tls = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | 0x2000 /* TLS 1.3 where available */;
  WinHttpSetOption(ses.h, WINHTTP_OPTION_SECURE_PROTOCOLS, &tls, sizeof(tls));   // needed on Windows 7
  WinHttpSetTimeouts(ses.h, 10000, 15000, 300000, 300000);

  Handle con;
  con.h = WinHttpConnect(ses.h, host, uc.nPort, 0);
  if (!con.h) { res.error = explain(GetLastError()); return res; }
  std::wstring full = std::wstring(path) + extra;
  Handle req;
  req.h = WinHttpOpenRequest(con.h, verb, full.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, secure ? WINHTTP_FLAG_SECURE : 0);
  if (!req.h) { res.error = explain(GetLastError()); return res; }

  std::wstring headers;
  if (!bearer.empty()) headers += L"Authorization: Bearer " + from_utf8(bearer) + L"\r\n";
  if (content_type) headers += std::wstring(L"Content-Type: ") + content_type + L"\r\n";
  if (!WinHttpSendRequest(req.h, headers.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : headers.c_str(), (DWORD)-1, WINHTTP_NO_REQUEST_DATA, 0, (DWORD)length, 0)) {
    res.error = explain(GetLastError());
    return res;
  }
  if (write_body && !write_body(req.h)) { res.error = explain(GetLastError()); return res; }
  if (!WinHttpReceiveResponse(req.h, nullptr)) { res.error = explain(GetLastError()); return res; }

  DWORD code = 0, sz = sizeof(code);
  WinHttpQueryHeaders(req.h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &code, &sz, WINHTTP_NO_HEADER_INDEX);
  res.status = (int)code;
  for (;;) {
    DWORD avail = 0;
    if (!WinHttpQueryDataAvailable(req.h, &avail) || avail == 0) break;
    std::string chunk(avail, '\0');
    DWORD got = 0;
    if (!WinHttpReadData(req.h, chunk.data(), avail, &got) || got == 0) break;
    if (res.body.size() < (1u << 20)) res.body.append(chunk.data(), got);
  }
  return res;
}

HttpResult http_get(const std::string& url, const std::string& bearer) { return request(url, L"GET", bearer, 0, nullptr, nullptr); }

HttpResult http_post_empty(const std::string& url, const std::string& bearer) { return request(url, L"POST", bearer, 0, nullptr, nullptr); }

HttpResult http_post_json(const std::string& url, const std::string& bearer, const std::string& json) {
  auto body = [&](HINTERNET req) {
    DWORD written = 0;
    return WinHttpWriteData(req, json.data(), (DWORD)json.size(), &written) != FALSE;
  };
  return request(url, L"POST", bearer, json.size(), body, L"application/json");
}

HttpResult http_send(const std::string& method, const std::string& url, const std::string& bearer, const std::string& data, const std::string& content_type) {
  auto body = [&](HINTERNET req) {
    DWORD written = 0;
    return data.empty() || WinHttpWriteData(req, data.data(), (DWORD)data.size(), &written) != FALSE;
  };
  const std::wstring verb = from_utf8(method), type = from_utf8(content_type);
  return request(url, verb.c_str(), bearer, data.size(), body, type.empty() ? nullptr : type.c_str());
}

HttpResult http_upload(const std::string& url, const std::string& bearer, const std::wstring& file_path, const UploadProgress& onProgress) {
  std::ifstream in(std::filesystem::path(file_path), std::ios::binary);
  if (!in) { HttpResult r; r.error = "the file could not be opened"; return r; }
  uint64_t size = file_info(file_path).size;
  auto body = [&](HINTERNET req) {
    std::vector<char> buf(256 << 10);   // small enough for a smooth percentage on a slow line
    uint64_t left = size;
    if (onProgress) onProgress(0, size);
    while (left > 0) {
      in.read(buf.data(), (std::streamsize)std::min<uint64_t>(buf.size(), left));
      std::streamsize n = in.gcount();
      if (n <= 0) { SetLastError(ERROR_READ_FAULT); return false; }
      DWORD written = 0;
      if (!WinHttpWriteData(req, buf.data(), (DWORD)n, &written)) return false;
      left -= (uint64_t)n;
      if (onProgress) onProgress(size - left, size);
    }
    return true;
  };
  return request(url, L"POST", bearer, size, body, L"application/octet-stream");
}

std::wstring program_dir() {
  wchar_t buf[MAX_PATH * 2];
  DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH * 2);
  std::wstring me(buf, n);
  size_t slash = me.find_last_of(L"\\/");
  return slash == std::wstring::npos ? L"" : me.substr(0, slash + 1);
}

namespace {
uint64_t fnv1a(const unsigned char* p, size_t n) {
  uint64_t h = 1469598103934665603ULL;
  for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ULL; }
  return h;
}
bool same_file(const std::wstring& path, const unsigned char* data, size_t n) {
  std::ifstream in(std::filesystem::path(path), std::ios::binary);
  if (!in) return false;
  std::string got((std::istreambuf_iterator<char>(in)), {});
  return got.size() == n && fnv1a((const unsigned char*)got.data(), got.size()) == fnv1a(data, n);
}
}  // namespace

// The reader is stored inside this program (resource 2). It runs as its own process, so a replay that crashes it
// cannot take this program down; for that it is written out once to %LOCALAPPDATA%\R6ReplayUploader\reader, under a
// name that changes with its contents, and checked byte for byte before each first use.
std::wstring helper_path() {
  static std::wstring cached;
  static std::mutex mu;
  std::lock_guard<std::mutex> g(mu);
  if (!cached.empty()) return cached;
  HRSRC res = FindResourceW(nullptr, MAKEINTRESOURCEW(2), MAKEINTRESOURCEW(10) /* RT_RCDATA */);
  HGLOBAL h = res ? LoadResource(nullptr, res) : nullptr;
  const auto* data = h ? (const unsigned char*)LockResource(h) : nullptr;
  const size_t n = res ? SizeofResource(nullptr, res) : 0;
  if (!data || n == 0) {   // a build without the reader inside: look next to the program
    cached = program_dir() + L"r6-dissect.exe";
    return cached;
  }
  wchar_t name[64];
  swprintf(name, 64, L"r6-dissect-%016llx.exe", (unsigned long long)fnv1a(data, n));
  std::wstring base = env(L"LOCALAPPDATA");
  if (base.empty()) base = app_data_dir();
  const std::filesystem::path dir = std::filesystem::path(base) / L"R6ReplayUploader" / L"reader";
  const std::wstring path = (dir / name).wstring();
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);
  if (!same_file(path, data, n)) {
    const std::wstring tmp = path + L".tmp";
    {
      std::ofstream out(std::filesystem::path(tmp), std::ios::binary | std::ios::trunc);
      out.write((const char*)data, (std::streamsize)n);
      if (!out) return {};
    }
    if (!MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING) || !same_file(path, data, n)) return {};
    // Older copies from earlier versions are no longer needed.
    for (const auto& e : std::filesystem::directory_iterator(dir, ec))
      if (e.path().filename().wstring().rfind(L"r6-dissect-", 0) == 0 && e.path().wstring() != path) std::filesystem::remove(e.path(), ec);
  }
  cached = path;
  return cached;
}

RunResult run_helper(const std::wstring& exe, const std::vector<std::wstring>& args, int timeout_ms) {
  RunResult r;
  SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
  HANDLE rd = nullptr, wr = nullptr;
  if (!CreatePipe(&rd, &wr, &sa, 0)) return r;
  SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
  HANDLE nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, nullptr);

  std::wstring cmd = L"\"" + exe + L"\"";
  for (const auto& a : args) {
    // Windows command-line quoting: backslashes are only special right before a quote.
    std::wstring q = L" \"";
    size_t slashes = 0;
    for (wchar_t c : a) {
      if (c == L'\\') { slashes++; continue; }
      if (c == L'"') q.append(slashes * 2 + 1, L'\\');
      else q.append(slashes, L'\\');
      slashes = 0;
      q += c;
    }
    q.append(slashes * 2, L'\\');
    cmd += q + L"\"";
  }
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = nul;
  si.hStdOutput = wr;
  si.hStdError = wr;
  PROCESS_INFORMATION pi{};
  // A program this Windows cannot run (for example one built for a newer Windows) must fail quietly, not pop up an error box.
  const UINT oldMode = SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
  const BOOL ok = CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW | BELOW_NORMAL_PRIORITY_CLASS, nullptr, nullptr, &si, &pi);
  SetErrorMode(oldMode);
  CloseHandle(wr);
  if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
  if (!ok) { CloseHandle(rd); return r; }
  r.started = true;

  const ULONGLONG deadline = GetTickCount64() + (ULONGLONG)timeout_ms;
  auto drain = [&] {
    for (;;) {
      DWORD avail = 0;
      if (!PeekNamedPipe(rd, nullptr, 0, nullptr, &avail, nullptr) || avail == 0) break;
      char buf[4096];
      DWORD got = 0;
      if (!ReadFile(rd, buf, (DWORD)std::min<DWORD>(avail, sizeof(buf)), &got, nullptr) || got == 0) break;
      if (r.output.size() < 16384) r.output.append(buf, got);
    }
  };
  for (;;) {
    drain();
    if (WaitForSingleObject(pi.hProcess, 40) == WAIT_OBJECT_0) break;
    if (GetTickCount64() > deadline) {
      TerminateProcess(pi.hProcess, 1);
      WaitForSingleObject(pi.hProcess, 2000);
      r.timed_out = true;
      break;
    }
  }
  drain();
  DWORD code = 0;
  GetExitCodeProcess(pi.hProcess, &code);
  r.exit_code = code;
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  CloseHandle(rd);
  return r;
}

WatchHandle watch_open(const std::wstring& folder) {
  HANDLE h = FindFirstChangeNotificationW(folder.c_str(), TRUE, FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE);
  return h == INVALID_HANDLE_VALUE ? nullptr : h;
}

bool watch_wait(WatchHandle h, int ms) {
  if (WaitForSingleObject((HANDLE)h, (DWORD)ms) != WAIT_OBJECT_0) return false;
  FindNextChangeNotification((HANDLE)h);
  return true;
}

void watch_close(WatchHandle h) { if (h) FindCloseChangeNotification((HANDLE)h); }

// ---------- WebSocket (WinHTTP, Windows 8 and newer; looked up at run time so Windows 7 still starts the program) ----------

namespace {
using CompleteUpgradeFn = HINTERNET(WINAPI*)(HINTERNET, DWORD_PTR);
using SendFn = DWORD(WINAPI*)(HINTERNET, WINHTTP_WEB_SOCKET_BUFFER_TYPE, void*, DWORD);
using ReceiveFn = DWORD(WINAPI*)(HINTERNET, void*, DWORD, DWORD*, WINHTTP_WEB_SOCKET_BUFFER_TYPE*);
using CloseFn = DWORD(WINAPI*)(HINTERNET, USHORT, void*, DWORD);
struct WsApi {
  CompleteUpgradeFn upgrade = nullptr;
  SendFn send = nullptr;
  ReceiveFn receive = nullptr;
  CloseFn close = nullptr;
  bool ok() const { return upgrade && send && receive && close; }
};
const WsApi& ws_api() {
  static WsApi a = [] {
    WsApi x;
    HMODULE m = GetModuleHandleW(L"winhttp.dll");
    if (!m) m = LoadLibraryW(L"winhttp.dll");
    if (m) {
      x.upgrade = (CompleteUpgradeFn)(void*)GetProcAddress(m, "WinHttpWebSocketCompleteUpgrade");
      x.send = (SendFn)(void*)GetProcAddress(m, "WinHttpWebSocketSend");
      x.receive = (ReceiveFn)(void*)GetProcAddress(m, "WinHttpWebSocketReceive");
      x.close = (CloseFn)(void*)GetProcAddress(m, "WinHttpWebSocketClose");
    }
    return x;
  }();
  return a;
}
struct Ws {
  HINTERNET session = nullptr, connect = nullptr, socket = nullptr;
  DWORD timeout = 0;
};
void ws_free(Ws* w) {
  if (w->socket) WinHttpCloseHandle(w->socket);
  if (w->connect) WinHttpCloseHandle(w->connect);
  if (w->session) WinHttpCloseHandle(w->session);
  delete w;
}
}  // namespace

WsHandle ws_open(const std::string& host, int port, std::string& error) {
  const WsApi& api = ws_api();
  if (!api.ok()) { error = "this version of Windows cannot talk to OBS (Windows 8 or newer is needed)"; return nullptr; }
  auto* w = new Ws();
  w->session = WinHttpOpen(L"R6ReplayUploader", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (w->session) w->connect = WinHttpConnect(w->session, from_utf8(host).c_str(), (INTERNET_PORT)port, 0);
  HINTERNET req = w->connect ? WinHttpOpenRequest(w->connect, L"GET", L"/", nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0) : nullptr;
  bool ok = req && WinHttpSetTimeouts(req, 3000, 3000, 5000, 5000) &&
            WinHttpSetOption(req, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nullptr, 0) &&
            WinHttpSendRequest(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0, nullptr, 0, 0, 0) && WinHttpReceiveResponse(req, nullptr);
  if (ok) {
    DWORD status = 0, len = sizeof status;
    WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &len, WINHTTP_NO_HEADER_INDEX);
    ok = status == 101;
    if (ok) w->socket = api.upgrade(req, 0);
    ok = w->socket != nullptr;
  }
  if (req) WinHttpCloseHandle(req);
  if (!ok) {
    error = "OBS is not answering on " + host + ":" + std::to_string(port) + ". Is OBS open, with Tools > WebSocket Server Settings > Enable turned on?";
    ws_free(w);
    return nullptr;
  }
  return w;
}

bool ws_send(WsHandle h, const std::string& text) {
  auto* w = (Ws*)h;
  return w && ws_api().send(w->socket, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, (void*)text.data(), (DWORD)text.size()) == NO_ERROR;
}

bool ws_recv(WsHandle h, std::string& text, int timeout_ms) {
  auto* w = (Ws*)h;
  if (!w) return false;
  if (w->timeout != (DWORD)timeout_ms) {
    DWORD t = (DWORD)timeout_ms;
    WinHttpSetOption(w->socket, WINHTTP_OPTION_RECEIVE_TIMEOUT, &t, sizeof t);
    w->timeout = t;
  }
  text.clear();
  char buf[8192];
  for (;;) {
    DWORD got = 0;
    WINHTTP_WEB_SOCKET_BUFFER_TYPE type;
    if (ws_api().receive(w->socket, buf, sizeof buf, &got, &type) != NO_ERROR) return false;
    if (type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) return false;
    text.append(buf, got);
    if (type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE || type == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE) return true;
    if (text.size() > (8u << 20)) return false;   // nothing OBS sends is this large
  }
}

void ws_close(WsHandle h) {
  auto* w = (Ws*)h;
  if (!w) return;
  if (w->socket) ws_api().close(w->socket, 1000, nullptr, 0);
  ws_free(w);
}

}  // namespace plat
