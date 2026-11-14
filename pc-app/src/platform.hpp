// What the uploader needs from the operating system. Implemented for Windows in platform_win.cpp.
#pragma once
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace plat {

struct HttpResult {
  int status = 0;          // 0 when the server could not be reached
  std::string body;
  std::string error;       // set when status == 0
};

// url is the full address. bearer may be empty.
HttpResult http_get(const std::string& url, const std::string& bearer);
HttpResult http_post_empty(const std::string& url, const std::string& bearer);
HttpResult http_post_json(const std::string& url, const std::string& bearer, const std::string& json);
// Any method with a body held in memory (PUT of a clip piece, PATCH ...). content_type may be empty.
HttpResult http_send(const std::string& method, const std::string& url, const std::string& bearer, const std::string& body, const std::string& content_type);
// Streams the file as the request body (Content-Type application/octet-stream).
// onProgress(sent, total) is called as the bytes go out.
using UploadProgress = std::function<void(uint64_t sent, uint64_t total)>;
HttpResult http_upload(const std::string& url, const std::string& bearer, const std::wstring& file_path, const UploadProgress& onProgress = nullptr);

// Encrypts a secret for the current Windows user (DPAPI). Returns hex; empty on failure.
std::string protect(const std::string& plain);
std::string unprotect(const std::string& hex);

std::vector<std::wstring> registry_install_dirs();   // where Ubisoft Connect says Siege is installed
std::vector<std::wstring> fixed_drives();            // "C:\\", "D:\\" ...
std::wstring env(const wchar_t* name);
std::wstring app_data_dir();                         // %APPDATA%\R6ReplayUploader (created)

struct FileInfo {
  uint64_t size = 0;
  uint64_t mtime = 0;   // seconds
  uint64_t now = 0;     // seconds, same clock
  bool ok = false;
};
FileInfo file_info(const std::wstring& path);

// Asks the OS to say when something inside a folder (and below it) changes.
using WatchHandle = void*;
WatchHandle watch_open(const std::wstring& folder);   // null when the folder cannot be watched (yet)
bool watch_wait(WatchHandle h, int ms);               // true if something changed during the wait
void watch_close(WatchHandle h);

// Runs the replay reader (a separate program that turns a .rec into JSON). No window, low priority, killed after timeout_ms.
struct RunResult {
  bool started = false;     // false when the program could not be launched at all
  bool timed_out = false;
  uint32_t exit_code = 0;
  std::string output;       // what it printed (stdout and stderr together), the first 16 KB
};
RunResult run_helper(const std::wstring& exe, const std::vector<std::wstring>& args, int timeout_ms);
std::wstring helper_path();   // the replay reader, unpacked from inside this program on first use (empty if that fails)
std::wstring program_dir();   // the folder this program is in, with a trailing separator

// A WebSocket client, for OBS's remote control (ws://127.0.0.1:4455). Text messages only.
// On Windows 7 (no WebSocket support in WinHTTP) ws_open fails with a message instead of the program failing to start.
using WsHandle = void*;
WsHandle ws_open(const std::string& host, int port, std::string& error);
bool ws_send(WsHandle h, const std::string& text);
bool ws_recv(WsHandle h, std::string& text, int timeout_ms);   // false on timeout or when the other side closed
void ws_close(WsHandle h);

// Cuts [start, start + duration] seconds of a video into an H.264/AAC MP4 at most max_height tall, and saves a JPEG still.
// Windows does this with its own video engine (Media Foundation); elsewhere these return false ("not available").
bool cut_video(const std::wstring& in, double start, double duration, const std::wstring& out, int max_height, std::string& error);
// The same, joining pieces of several files in order (a clip that crosses from one recorded minute to the next).
bool cut_parts(const std::vector<std::wstring>& files, const std::vector<double>& offsets, const std::vector<double>& lengths, const std::wstring& out, int max_height, std::string& error);
bool video_duration(const std::wstring& in, double& seconds, std::string& error);
// Whether a program with one of these file names (e.g. L"RainbowSix.exe") is running. Reads the process list only.
bool process_running(const std::vector<std::wstring>& names);
// Starts OBS Studio (minimised to the tray, with its replay buffer on) if it is installed. Does not touch the game.
bool start_obs(std::string& error);
bool grab_frame_jpeg(const std::wstring& in, double at, const std::wstring& out, int height, std::string& error);

std::string to_utf8(const std::wstring& w);
std::wstring from_utf8(const std::string& s);

}  // namespace plat
