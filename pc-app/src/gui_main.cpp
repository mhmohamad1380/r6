// R6 Replay Uploader: a small Windows program that sends Siege replays to your replay server.
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <string>
#include <memory>
#include <thread>
#include <vector>
#include <cstdio>

#include "core.hpp"
#include "highlights_window.hpp"
#include "live.hpp"
#include "recorder.hpp"
#include <filesystem>
#include "platform.hpp"

namespace {

constexpr wchar_t kClass[] = L"R6ReplayUploaderWnd";
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"R6ReplayUploader";

enum Id { IDC_SERVER = 101, IDC_TOKEN, IDC_SHOW, IDC_FOLDER, IDC_BROWSE, IDC_FIND, IDC_AUTOSTART, IDC_RAWFB, IDC_SAVE, IDC_STATUS, IDC_LOG, IDC_NOW, IDC_PAUSE, IDC_OPENLOG, IDC_PROGRESS, IDC_PROGTEXT, IDC_HIGHLIGHTS, IDC_LIVE, IDC_LIVESTAT };
enum Msg { WM_LOGLINE = WM_APP + 1, WM_STATUS, WM_TRAY, WM_CHECKED, WM_PROGRESS, WM_LIVESTAT };
constexpr int kHotCalibrate = 7;   // F8 while live clips are on
enum Menu { ID_OPEN = 201, ID_NOW, ID_PAUSE, ID_QUIT };

struct App {
  HINSTANCE inst = nullptr;
  HWND liveBox = nullptr, liveStat = nullptr;
  std::thread liver;
  std::condition_variable liveCv;
  HWND wnd = nullptr, server = nullptr, token = nullptr, folder = nullptr, autostart = nullptr, rawFallback = nullptr, status = nullptr, progress = nullptr, progText = nullptr, log = nullptr, pauseBtn = nullptr, saveBtn = nullptr;
  HFONT font = nullptr, bold = nullptr, big = nullptr;
  int dpi = 96;
  NOTIFYICONDATAW tray{};
  UINT taskbarCreated = 0;
  bool quitting = false, balloonShown = false;

  std::mutex mu;
  core::Config cfg;
  core::State state;
  std::condition_variable cv;
  std::atomic<bool> stop{false}, paused{false}, syncNow{false};
  std::thread worker, watcher;
  int uploaded = 0, waiting = 0, errors = 0;
  int logWidth = 0;   // widest log line in pixels, for the horizontal scroll bar
} A;

int S(int v) { return MulDiv(v, A.dpi, 96); }

std::wstring text_of(HWND h) {
  int n = GetWindowTextLengthW(h);
  std::wstring s((size_t)n + 1, L'\0');
  GetWindowTextW(h, s.data(), n + 1);
  s.resize((size_t)n);
  return s;
}

void post_log(const std::string& msg) { PostMessageW(A.wnd, WM_LOGLINE, 0, (LPARAM) new std::wstring(plat::from_utf8(msg))); }
void post_progress(const core::UploadStatus& st) { PostMessageW(A.wnd, WM_PROGRESS, 0, (LPARAM) new core::UploadStatus(st)); }
void post_progress_done() { PostMessageW(A.wnd, WM_PROGRESS, 1, 0); }
void post_status(const std::wstring& s) { PostMessageW(A.wnd, WM_STATUS, 0, (LPARAM) new std::wstring(s)); }

// ---------------------------------------------------------------- live clips (OBS replay buffer while playing)
// One recorder for the whole program: live clips and replay clips both use it.
rec::Recorder& recorder() {
  static std::unique_ptr<rec::Recorder> r = rec::make_recorder();
  return *r;
}

rec::Options recorder_options() {
  rec::Options o;
  std::wstring base = plat::env(L"LOCALAPPDATA");
  if (base.empty()) base = plat::app_data_dir();
  o.dir = (std::filesystem::path(base) / L"R6ReplayUploader" / L"recording").wstring();
  return o;
}

live::Clipper& clipper() {
  static live::Clipper c([](const std::string& m) { post_log(m); core::write_log_file(m); });
  return c;
}

live::Settings live_settings(const core::Config& c) {
  live::Settings s;
  s.enabled = c.live;
  s.use_obs = c.use_obs;
  s.obs_port = c.obs_port;
  s.obs_password = c.obs_password;
  s.min_score = c.live_min_score;
  s.offsets = c.live_offsets;
  s.server = c.server;
  s.token = c.token;
  s.clips_dir = plat::to_utf8((c.clips_dir.empty() ? clips::default_clips_dir() : c.clips_dir).wstring());
  return s;
}

const std::vector<std::wstring> kGame = {L"RainbowSix.exe", L"RainbowSix_BE.exe", L"RainbowSix_Vulkan.exe"};

// Keeps OBS's replay buffer on while Siege runs (starting OBS if it is installed and closed), and cuts and uploads what
// the uploader's round reading queued. Status goes to the line under the checkbox.
void liver_main() {
  bool startedObs = false;
  long long lastCheck = 0;
  std::unique_lock<std::mutex> lk(A.mu);
  while (!A.stop) {
    const core::Config c = A.cfg;
    lk.unlock();
    clipper().configure(live_settings(c));
    const long long t = GetTickCount64();
    if (t - lastCheck >= 10000) {
      lastCheck = t;
      const bool playing = c.live && plat::process_running(kGame);
      if (playing && c.use_obs && !startedObs && !plat::process_running({L"obs64.exe"})) {
        std::string err;
        if (plat::start_obs(err)) post_log("Live clips: started OBS (minimised) for this game session.");
        else post_log("Live clips: " + err);
        startedObs = true;   // once per game session, whether or not it worked
      }
      if (!playing) startedObs = false;
      PostMessageW(A.wnd, WM_LIVESTAT, 0, (LPARAM) new std::wstring(plat::from_utf8(clipper().keep_buffer(playing))));
    }
    clipper().drain();
    lk.lock();
    A.liveCv.wait_for(lk, std::chrono::seconds(2), [] { return A.stop.load(); });
  }
}

void save_live_offsets(const live::Settings& s) {
  core::Config c;
  core::load_config(c);
  c.live_offsets = s.offsets;
  core::save_config(c);
  std::lock_guard<std::mutex> g(A.mu);
  A.cfg.live_offsets = s.offsets;
}

void set_live(bool on) {
  core::Config c;
  core::load_config(c);
  c.live = on;
  core::save_config(c);
  {
    std::lock_guard<std::mutex> g(A.mu);
    A.cfg.live = on;
  }
  if (on) {
    if (!RegisterHotKey(A.wnd, kHotCalibrate, MOD_NOREPEAT, VK_F8)) RegisterHotKey(A.wnd, kHotCalibrate, MOD_NOREPEAT | MOD_CONTROL | MOD_ALT, VK_F8);
  } else {
    UnregisterHotKey(A.wnd, kHotCalibrate);
  }
  SetWindowTextW(A.liveStat, on ? L"Live clips: starting..." : L"Live clips are off.");
}

// ---------------------------------------------------------------- the background watcher
void worker_main() {
  std::unique_lock<std::mutex> lk(A.mu);
  while (!A.stop) {
    core::Config c = A.cfg;
    if (!c.configured()) {
      post_status(L"Not set up yet. Fill in the form and press Save.");
    } else if (A.paused) {
      post_status(L"Paused.");
    } else {
      lk.unlock();
      post_status(L"Checking for new replays...");
      core::Counts n = core::sync_once(c, A.state, post_log, post_progress, c.live ? core::RoundHook([](const std::string& round, double written) { clipper().on_round(round, written); A.liveCv.notify_all(); }) : core::RoundHook());
      post_progress_done();
      lk.lock();
      A.uploaded += n.uploaded();
      SYSTEMTIME t;
      GetLocalTime(&t);
      wchar_t when[16];
      swprintf_s(when, L"%02d:%02d", t.wHour, t.wMinute);
      std::wstring tail = L"Checked " + std::wstring(when) + L".  On the server: " + std::to_wstring(core::done_count(A.state)) + L".  Uploaded this session: " + std::to_wstring(A.uploaded) + (n.skipped ? L".  Not replays: " + std::to_wstring(n.skipped) : L"");
      if (n.update_needed) post_status(L"UPDATE NEEDED: " + plat::from_utf8(n.update_message));
      else if (n.error) post_status(L"Last upload did not complete. Will try again.  " + tail);
      else post_status(L"Watching for new replays.  " + tail);
    }
    A.cv.wait_for(lk, std::chrono::seconds(std::max(5, c.poll)), [] { return A.stop.load() || A.syncNow.load(); });
    A.syncNow = false;
  }
}

void sync_now();

// Wakes the worker as soon as the game has finished writing a replay, instead of waiting for the next poll.
void watcher_main() {
  std::unique_ptr<core::Watcher> w;
  core::fs::path watching;
  while (!A.stop) {
    core::Config c;
    {
      std::lock_guard<std::mutex> g(A.mu);
      c = A.cfg;
    }
    if (c.folder.empty()) {
      w.reset();
      std::this_thread::sleep_for(std::chrono::seconds(1));
      continue;
    }
    if (!w || watching != c.folder) {
      w = std::make_unique<core::Watcher>(c.folder);
      watching = c.folder;
    }
    if (w->wait_settled(1000)) sync_now();
  }
}

void start_worker() {
  A.worker = std::thread(worker_main);
  A.watcher = std::thread(watcher_main);
  clipper().on_settings_changed = save_live_offsets;
  clipper().use_recorder(&recorder());
  {   // version 1.6.0 kept a replay session's minutes in clip-sessions\<match>-recording; nothing is kept that way now
    std::error_code ec;
    for (const auto& e : std::filesystem::directory_iterator(clips::sessions_dir(), ec)) {
      const std::wstring n = e.path().filename().wstring();
      if (e.is_directory(ec) && n.size() > 10 && n.compare(n.size() - 10, 10, L"-recording") == 0) std::filesystem::remove_all(e.path(), ec);
    }
    std::filesystem::remove_all(std::filesystem::path(recorder_options().dir), ec);   // minutes left by a crash
  }
  clipper().timing_log = [](const std::string& line) { core::write_log_file(line); };
  clipper().recorder_options = recorder_options();
  A.liver = std::thread(liver_main);
}

void stop_worker() {
  {
    std::lock_guard<std::mutex> g(A.mu);
    A.stop = true;
  }
  A.cv.notify_all();
  A.liveCv.notify_all();
  if (A.worker.joinable()) A.worker.join();
  if (A.watcher.joinable()) A.watcher.join();
  if (A.liver.joinable()) A.liver.join();
}

void sync_now() {
  A.syncNow = true;
  A.cv.notify_all();
}

// ---------------------------------------------------------------- start with Windows
std::wstring installed_exe() {
  std::wstring base = plat::env(L"LOCALAPPDATA");
  return base + L"\\R6ReplayUploader\\R6ReplayUploader.exe";
}

std::wstring self_exe() {
  wchar_t buf[MAX_PATH * 2];
  GetModuleFileNameW(nullptr, buf, MAX_PATH * 2);
  return buf;
}

std::wstring shortcut_path() { return plat::env(L"APPDATA") + L"\\Microsoft\\Windows\\Start Menu\\Programs\\R6 Replay Uploader.lnk"; }

void make_shortcut(const std::wstring& target) {
  IShellLinkW* link = nullptr;
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_IShellLinkW, (void**)&link))) return;
  link->SetPath(target.c_str());
  link->SetDescription(L"Uploads Rainbow Six Siege replays to your replay server");
  IPersistFile* pf = nullptr;
  if (SUCCEEDED(link->QueryInterface(IID_IPersistFile, (void**)&pf))) {
    pf->Save(shortcut_path().c_str(), TRUE);
    pf->Release();
  }
  link->Release();
}

// Copies the program to a permanent place, so it keeps working if the downloaded copy is moved or deleted.
bool set_autostart(bool on) {
  if (on) {
    std::wstring target = installed_exe(), me = self_exe();
    std::error_code ec;
    std::filesystem::create_directories(std::filesystem::path(target).parent_path(), ec);
    if (_wcsicmp(me.c_str(), target.c_str()) != 0) {
      std::filesystem::copy_file(me, target, std::filesystem::copy_options::overwrite_existing, ec);   // one file: the reader is inside it
    }
    if (ec) target = me;   // could not copy (for example, the installed copy is running): use this one
    HKEY k;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &k, nullptr) != ERROR_SUCCESS) return false;
    std::wstring cmd = L"\"" + target + L"\" --background";
    bool ok = RegSetValueExW(k, kRunValue, 0, REG_SZ, (const BYTE*)cmd.c_str(), (DWORD)((cmd.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
    RegCloseKey(k);
    make_shortcut(target);
    return ok;
  }
  HKEY k;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &k) == ERROR_SUCCESS) {
    RegDeleteValueW(k, kRunValue);
    RegCloseKey(k);
  }
  DeleteFileW(shortcut_path().c_str());
  return true;
}

bool autostart_enabled() {
  HKEY k;
  bool on = false;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_QUERY_VALUE, &k) == ERROR_SUCCESS) {
    on = RegQueryValueExW(k, kRunValue, nullptr, nullptr, nullptr, nullptr) == ERROR_SUCCESS;
    RegCloseKey(k);
  }
  return on;
}

// ---------------------------------------------------------------- tray
void tray_add() {
  A.tray = {};
  A.tray.cbSize = sizeof(A.tray);
  A.tray.hWnd = A.wnd;
  A.tray.uID = 1;
  A.tray.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  A.tray.uCallbackMessage = WM_TRAY;
  A.tray.hIcon = (HICON)LoadImageW(A.inst, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
  if (!A.tray.hIcon) A.tray.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
  wcscpy_s(A.tray.szTip, L"R6 Replay Uploader");
  Shell_NotifyIconW(NIM_ADD, &A.tray);
}

void tray_balloon(const wchar_t* title, const wchar_t* text) {
  NOTIFYICONDATAW n = A.tray;
  n.uFlags = NIF_INFO;
  wcscpy_s(n.szInfoTitle, title);
  wcscpy_s(n.szInfo, text);
  n.dwInfoFlags = NIIF_INFO;
  Shell_NotifyIconW(NIM_MODIFY, &n);
}

void show_window() {
  ShowWindow(A.wnd, SW_SHOW);
  ShowWindow(A.wnd, SW_RESTORE);
  SetForegroundWindow(A.wnd);
}

void set_paused(bool p) {
  A.paused = p;
  SetWindowTextW(A.pauseBtn, p ? L"Resume" : L"Pause");
  sync_now();
}

void tray_menu() {
  HMENU m = CreatePopupMenu();
  AppendMenuW(m, MF_STRING, ID_OPEN, L"Open");
  AppendMenuW(m, MF_STRING, ID_NOW, L"Upload now");
  AppendMenuW(m, MF_STRING, ID_PAUSE, A.paused ? L"Resume" : L"Pause");
  AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(m, MF_STRING, ID_QUIT, L"Quit");
  POINT pt;
  GetCursorPos(&pt);
  SetForegroundWindow(A.wnd);   // so the menu closes when you click elsewhere
  TrackPopupMenu(m, TPM_RIGHTBUTTON, pt.x, pt.y, 0, A.wnd, nullptr);
  DestroyMenu(m);
}

// ---------------------------------------------------------------- form
void add_log(const std::wstring& line) {
  SYSTEMTIME t;
  GetLocalTime(&t);
  wchar_t stamp[16];
  swprintf_s(stamp, L"%02d:%02d  ", t.wHour, t.wMinute);
  const std::wstring full = stamp + line;
  int idx = (int)SendMessageW(A.log, LB_ADDSTRING, 0, (LPARAM)full.c_str());
  {
    HDC dc = GetDC(A.log);
    HGDIOBJ old = SelectObject(dc, A.font);
    SIZE sz{};
    GetTextExtentPoint32W(dc, full.c_str(), (int)full.size(), &sz);
    SelectObject(dc, old);
    ReleaseDC(A.log, dc);
    if (sz.cx + 12 > A.logWidth) { A.logWidth = sz.cx + 12; SendMessageW(A.log, LB_SETHORIZONTALEXTENT, (WPARAM)A.logWidth, 0); }
  }
  while (SendMessageW(A.log, LB_GETCOUNT, 0, 0) > 300) SendMessageW(A.log, LB_DELETESTRING, 0, 0), idx--;
  SendMessageW(A.log, LB_SETTOPINDEX, (WPARAM)std::max(0, idx), 0);
}

void browse() {
  BROWSEINFOW bi{};
  bi.hwndOwner = A.wnd;
  bi.lpszTitle = L"Choose the MatchReplay folder";
  bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
  if (PIDLIST_ABSOLUTE pidl = SHBrowseForFolderW(&bi)) {
    wchar_t path[MAX_PATH];
    if (SHGetPathFromIDListW(pidl, path)) SetWindowTextW(A.folder, path);
    CoTaskMemFree(pidl);
  }
}

void find_folder() {
  SetCursor(LoadCursor(nullptr, IDC_WAIT));
  auto found = core::discover();
  SetCursor(LoadCursor(nullptr, IDC_ARROW));
  if (found.empty()) {
    MessageBoxW(A.wnd, L"No MatchReplay folder was found.\n\nIt sits inside the game's install folder. Press Browse and choose it, or play one match first so the game creates it.", L"R6 Replay Uploader", MB_ICONINFORMATION);
    return;
  }
  SetWindowTextW(A.folder, found[0].first.wstring().c_str());
  add_log(L"Found " + found[0].first.wstring() + L" (" + std::to_wstring(found[0].second) + L" replays)");
  for (size_t i = 1; i < found.size(); i++) add_log(L"Also found " + found[i].first.wstring());
}

void save() {
  core::Config c;
  core::load_config(c);   // keeps what this form does not show (the Highlights window's OBS and ffmpeg settings)
  c.server = core::normalize_url(plat::to_utf8(text_of(A.server)));
  c.token = plat::to_utf8(text_of(A.token));
  c.folder = core::fs::path(text_of(A.folder));
  c.raw_fallback = SendMessageW(A.rawFallback, BM_GETCHECK, 0, 0) == BST_CHECKED;
  bool auto_ = SendMessageW(A.autostart, BM_GETCHECK, 0, 0) == BST_CHECKED;
  EnableWindow(A.saveBtn, FALSE);
  SetWindowTextW(A.saveBtn, L"Checking the server...");
  std::thread([c, auto_] {
    std::string msg;
    bool ok = core::check_server(c.server, c.token, msg);
    std::error_code ec;
    if (ok && !core::fs::is_directory(c.folder, ec)) {
      ok = false;
      msg = "That replay folder does not exist. Press Find or Browse.";
    }
    if (ok) {
      core::save_config(c);
      {
        std::lock_guard<std::mutex> g(A.mu);
        A.cfg = c;
      }
      sync_now();
      if (!set_autostart(auto_)) msg += " (Could not change the start-with-Windows setting.)";
    }
    PostMessageW(A.wnd, WM_CHECKED, ok ? 1 : 0, (LPARAM) new std::wstring(plat::from_utf8(msg)));
  }).detach();
}

HFONT make_font(int pt, int weight) {
  NONCLIENTMETRICSW ncm{};
  ncm.cbSize = sizeof(ncm);
  SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0);
  LOGFONTW lf = ncm.lfMessageFont;
  lf.lfHeight = -MulDiv(pt, A.dpi, 72);
  lf.lfWeight = weight;
  return CreateFontIndirectW(&lf);
}

HWND ctlpx(const wchar_t* cls, const wchar_t* text, DWORD style, int x, int y, int w, int h, int id, DWORD ex = 0) {
  HWND c = CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h, A.wnd, (HMENU)(INT_PTR)id, A.inst, nullptr);
  SendMessageW(c, WM_SETFONT, (WPARAM)A.font, TRUE);
  return c;
}

// The height in pixels that `text` needs at this width and font, so a section is always as tall as its text.
int text_height(const std::wstring& text, HFONT font, int width_px, int min_lines = 1) {
  HDC dc = GetDC(A.wnd);
  HGDIOBJ old = SelectObject(dc, font);
  RECT r{0, 0, width_px, 0};
  DrawTextW(dc, text.c_str(), -1, &r, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
  TEXTMETRICW tm{};
  GetTextMetricsW(dc, &tm);
  SelectObject(dc, old);
  ReleaseDC(A.wnd, dc);
  return std::max<int>(r.bottom, tm.tmHeight * min_lines);
}

// A block of wrapped text. Returns where the next thing starts.
int paragraph(const std::wstring& text, int y, HFONT font, int x, int w, int min_lines = 1, HWND* out = nullptr, int id = 0) {
  const int h = text_height(text, font, w, min_lines);
  HWND c = ctlpx(L"STATIC", text.c_str(), SS_LEFT, x, y, w, h, id);
  SendMessageW(c, WM_SETFONT, (WPARAM)font, TRUE);
  if (out) *out = c;
  return y + h;
}

void build_form() {
  A.font = make_font(9, FW_NORMAL);
  A.bold = make_font(9, FW_SEMIBOLD);
  A.big = make_font(15, FW_SEMIBOLD);
  const int m = S(20), W = S(440), gap = S(10), field = S(24), btn = S(28);
  int y = S(14);
  y = paragraph(L"R6 Replay Uploader", y, A.big, m, W) + S(6);
  y = paragraph(L"Sends your Siege replays to your replay server so the phone app can analyse them. Keep it running: the game keeps only the last 10 to 12 matches.", y, A.font, m, W) + gap;

  y = paragraph(L"Server address", y, A.font, m, W) + S(3);
  A.server = ctlpx(L"EDIT", L"", WS_TABSTOP | ES_AUTOHSCROLL, m, y, W, field, IDC_SERVER, WS_EX_CLIENTEDGE);
  y += field + gap;

  y = paragraph(L"Upload token (the PC's token, not the phone's)", y, A.font, m, W) + S(3);
  A.token = ctlpx(L"EDIT", L"", WS_TABSTOP | ES_AUTOHSCROLL | ES_PASSWORD, m, y, W - S(80), field, IDC_TOKEN, WS_EX_CLIENTEDGE);
  ctlpx(L"BUTTON", L"Show", WS_TABSTOP, m + W - S(72), y - 1, S(72), btn - S(1), IDC_SHOW);
  y += field + gap;

  y = paragraph(L"Replay folder: the one that holds a folder for each match", y, A.font, m, W) + S(3);
  A.folder = ctlpx(L"EDIT", L"", WS_TABSTOP | ES_AUTOHSCROLL, m, y, W - S(166), field, IDC_FOLDER, WS_EX_CLIENTEDGE);
  ctlpx(L"BUTTON", L"Browse...", WS_TABSTOP, m + W - S(160), y - 1, S(82), btn - S(1), IDC_BROWSE);
  ctlpx(L"BUTTON", L"Find", WS_TABSTOP, m + W - S(72), y - 1, S(72), btn - S(1), IDC_FIND);
  y += field + S(8);
  y = paragraph(L"Every .rec in it and its subfolders is checked. Replays the server does not have yet are uploaded, then new ones as they appear.", y, A.font, m, W) + S(8);

  const std::wstring auto_text = L"Start with Windows (installs a copy and a Start Menu shortcut)";
  const int ah = text_height(auto_text, A.font, W - S(22)) + S(4);
  A.autostart = ctlpx(L"BUTTON", auto_text.c_str(), WS_TABSTOP | BS_AUTOCHECKBOX | BS_MULTILINE, m, y, W, ah, IDC_AUTOSTART);
  y += ah + S(6);

  // Replays are read on this PC. When one cannot be read (a game update added something new), the file itself can go to the server.
  const std::wstring raw_text = L"If a replay cannot be read here, send the file itself to the server so it can be looked at";
  const int rh = text_height(raw_text, A.font, W - S(22)) + S(4);
  A.rawFallback = ctlpx(L"BUTTON", raw_text.c_str(), WS_TABSTOP | BS_AUTOCHECKBOX | BS_MULTILINE, m, y, W, rh, IDC_RAWFB);
  SendMessageW(A.rawFallback, BM_SETCHECK, BST_CHECKED, 0);
  y += rh + gap;

  const int sh = S(34);
  A.saveBtn = ctlpx(L"BUTTON", L"Save and start", WS_TABSTOP | BS_DEFPUSHBUTTON, m, y, W, sh, IDC_SAVE);
  SendMessageW(A.saveBtn, WM_SETFONT, (WPARAM)A.bold, TRUE);
  y += sh + S(14);

  // Status: up to three lines, since it carries the counts. Then the live upload bar.
  y = paragraph(L"Starting...", y, A.bold, m, W, 3, &A.status, IDC_STATUS) + S(6);
  A.progress = ctlpx(PROGRESS_CLASSW, L"", 0, m, y, W, S(14), IDC_PROGRESS);
  SendMessageW(A.progress, PBM_SETRANGE32, 0, 1000);
  y += S(14) + S(4);
  y = paragraph(L"No upload in progress.", y, A.font, m, W, 2, &A.progText, IDC_PROGTEXT) + S(8);

  const int logH = S(130);
  A.log = ctlpx(L"LISTBOX", L"", WS_TABSTOP | WS_VSCROLL | WS_HSCROLL | LBS_NOINTEGRALHEIGHT | LBS_NOSEL, m, y, W, logH, IDC_LOG, WS_EX_CLIENTEDGE);
  y += logH + gap;

  const int bw = S(104);
  ctlpx(L"BUTTON", L"Upload now", WS_TABSTOP, m, y, bw, btn, IDC_NOW);
  A.pauseBtn = ctlpx(L"BUTTON", L"Pause", WS_TABSTOP, m + bw + S(8), y, S(84), btn, IDC_PAUSE);
  ctlpx(L"BUTTON", L"Open log file", WS_TABSTOP, m + W - S(120), y, S(120), btn, IDC_OPENLOG);
  y += btn + S(8);
  const std::wstring live_text = L"Record live clips while I play: while Siege runs, this program records the screen, and after each round your best moments are cut and sent to the app";
  const int lh = text_height(live_text, A.font, W - S(22)) + S(4);
  A.liveBox = ctlpx(L"BUTTON", live_text.c_str(), WS_TABSTOP | BS_AUTOCHECKBOX | BS_MULTILINE, m, y, W, lh, IDC_LIVE);
  y += lh + S(2);
  y = paragraph(L"Live clips are off.", y, A.font, m + S(18), W - S(18), 2, &A.liveStat, IDC_LIVESTAT) + S(2);
  y = paragraph(L"Play Siege in Borderless mode so the screen can be recorded. Press F8 once, when a round's timer starts, to make clips exact.", y, A.font, m + S(18), W - S(18)) + S(8);
  ctlpx(L"BUTTON", L"Clips from replays, and recording settings...", WS_TABSTOP, m, y, W, btn, IDC_HIGHLIGHTS);
  y += btn + S(16);

  // Make the window exactly as tall as its content.
  RECT r{0, 0, S(480), y};
  AdjustWindowRect(&r, (DWORD)GetWindowLongPtrW(A.wnd, GWL_STYLE), FALSE);
  SetWindowPos(A.wnd, nullptr, 0, 0, r.right - r.left, r.bottom - r.top, SWP_NOMOVE | SWP_NOZORDER);
}

LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) {
  if (m == A.taskbarCreated && A.taskbarCreated) { tray_add(); return 0; }   // Explorer restarted
  switch (m) {
    case WM_CREATE: return 0;
    case WM_COMMAND:
      switch (LOWORD(w)) {
        case IDC_SAVE: save(); break;
        case IDC_BROWSE: browse(); break;
        case IDC_FIND: find_folder(); break;
        case IDC_NOW: case ID_NOW: sync_now(); break;
        case IDC_OPENLOG: {
          const std::wstring path = plat::from_utf8(core::log_file_path());
          if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) add_log(L"There is no log file yet. It is created with the first check.");
          else ShellExecuteW(h, L"open", L"notepad.exe", (L"\"" + path + L"\"").c_str(), nullptr, SW_SHOWNORMAL);
          break;
        }
        case IDC_PAUSE: case ID_PAUSE: set_paused(!A.paused); break;
        case IDC_HIGHLIGHTS: open_highlights_window(A.inst, nullptr, A.dpi, &recorder(), recorder_options()); break;
        case IDC_LIVE: set_live(SendMessageW(A.liveBox, BM_GETCHECK, 0, 0) == BST_CHECKED); break;
        case ID_OPEN: show_window(); break;
        case ID_QUIT: A.quitting = true; DestroyWindow(h); break;
        case IDC_SHOW: {
          bool hidden = SendMessageW(A.token, EM_GETPASSWORDCHAR, 0, 0) != 0;
          SendMessageW(A.token, EM_SETPASSWORDCHAR, hidden ? 0 : (WPARAM)L'*', 0);
          SetWindowTextW(GetDlgItem(h, IDC_SHOW), hidden ? L"Hide" : L"Show");
          InvalidateRect(A.token, nullptr, TRUE);
          break;
        }
      }
      return 0;
    case WM_LOGLINE: {
      std::unique_ptr<std::wstring> s((std::wstring*)l);
      add_log(*s);
      return 0;
    }
    case WM_PROGRESS: {
      if (w == 1) {   // this pass is over
        SendMessageW(A.progress, PBM_SETPOS, 0, 0);
        SetWindowTextW(A.progText, L"No upload in progress.");
        return 0;
      }
      std::unique_ptr<core::UploadStatus> st((core::UploadStatus*)l);
      if (st->phase == "Reading") {   // the replay is being read on this PC: no percentage to show yet
        SendMessageW(A.progress, PBM_SETPOS, 0, 0);
        SetWindowTextW(A.progText, (L"Reading " + std::to_wstring(st->index) + L" of " + std::to_wstring(st->of) + L" on this PC: " + plat::from_utf8(st->name)).c_str());
        return 0;
      }
      SendMessageW(A.progress, PBM_SETPOS, st->total ? (WPARAM)(st->sent * 1000 / st->total) : 1000, 0);
      const std::wstring line = L"Uploading " + std::to_wstring(st->index) + L" of " + std::to_wstring(st->of) + L": " + plat::from_utf8(st->name) + L"\r\n" +
                                std::to_wstring(st->percent()) + L"%   " + plat::from_utf8(core::human_size(st->sent) + " of " + core::human_size(st->total) + "   " + core::human_speed(st->bytes_per_second));
      SetWindowTextW(A.progText, line.c_str());
      return 0;
    }
    case WM_STATUS: {
      std::unique_ptr<std::wstring> s((std::wstring*)l);
      SetWindowTextW(A.status, s->c_str());
      wcscpy_s(A.tray.szTip, (L"R6 Replay Uploader: " + *s).substr(0, 120).c_str());
      A.tray.uFlags = NIF_TIP;
      Shell_NotifyIconW(NIM_MODIFY, &A.tray);
      return 0;
    }
    case WM_CHECKED: {
      std::unique_ptr<std::wstring> s((std::wstring*)l);
      EnableWindow(A.saveBtn, TRUE);
      SetWindowTextW(A.saveBtn, L"Save and start");
      if (w) {
        add_log(*s + L" Settings saved.");
        sync_now();
        ShowWindow(h, SW_HIDE);
        tray_balloon(L"R6 Replay Uploader is running", L"It sits in the tray and uploads new replays. Right-click the icon to open or quit.");
      } else {
        MessageBoxW(h, s->c_str(), L"R6 Replay Uploader", MB_ICONWARNING);
      }
      return 0;
    }
    case WM_HOTKEY:
      if (w == kHotCalibrate) {
        clipper().calibrate_now();
        MessageBeep(MB_ICONASTERISK);   // heard in the game
      }
      return 0;
    case WM_LIVESTAT: {
      std::unique_ptr<std::wstring> t((std::wstring*)l);
      SetWindowTextW(A.liveStat, t->c_str());
      return 0;
    }
    case WM_TRAY:
      if (LOWORD(l) == WM_LBUTTONUP || LOWORD(l) == WM_LBUTTONDBLCLK) show_window();
      else if (LOWORD(l) == WM_RBUTTONUP) tray_menu();
      return 0;
    case WM_CLOSE:
      if (!A.quitting) {   // closing the window keeps it running in the tray
        ShowWindow(h, SW_HIDE);
        if (!A.balloonShown) { A.balloonShown = true; tray_balloon(L"Still running", L"R6 Replay Uploader keeps watching for replays. Right-click this icon to quit."); }
        return 0;
      }
      break;
    case WM_DESTROY:
      Shell_NotifyIconW(NIM_DELETE, &A.tray);
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(h, m, w, l);
}

}  // namespace

int cli_run(int argc, char** argv);   // cli_main.cpp: the console commands, in this same program

// "R6ReplayUploader.exe clip cut" and the like run the console commands in the window that started them.
static bool run_command_line(int& code) {
  static const wchar_t* commands[] = {L"version", L"discover", L"setup", L"once", L"run", L"parse", L"highlights", L"clip", L"status", L"help", L"licenses"};
  int argc = 0;
  wchar_t** wargv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!wargv) return false;
  bool isCommand = false;
  if (argc > 1)
    for (const wchar_t* c : commands) isCommand |= _wcsicmp(wargv[1], c) == 0;
  if (!isCommand) { LocalFree(wargv); return false; }
  if (!AttachConsole(ATTACH_PARENT_PROCESS)) AllocConsole();   // started from a console: write there; else open one
  FILE* f = nullptr;
  freopen_s(&f, "CONOUT$", "w", stdout);
  freopen_s(&f, "CONOUT$", "w", stderr);
  SetConsoleOutputCP(CP_UTF8);
  std::vector<std::string> args;
  for (int i = 0; i < argc; i++) args.push_back(plat::to_utf8(wargv[i]));
  LocalFree(wargv);
  std::vector<char*> argv;
  for (auto& a : args) argv.push_back(a.data());
  std::fputs("\n", stdout);   // the console prompt was already printed: start on a fresh line
  code = cli_run((int)argv.size(), argv.data());
  std::fflush(stdout);
  return true;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR cmd, int) {
  int code = 0;
  if (run_command_line(code)) return code;
  HANDLE once = CreateMutexW(nullptr, TRUE, L"R6ReplayUploader.Singleton");
  if (GetLastError() == ERROR_ALREADY_EXISTS) {   // already running: bring that one forward
    if (HWND w = FindWindowW(kClass, nullptr)) { ShowWindow(w, SW_SHOW); ShowWindow(w, SW_RESTORE); SetForegroundWindow(w); }
    return 0;
  }
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  INITCOMMONCONTROLSEX icc{sizeof(icc), ICC_STANDARD_CLASSES | ICC_WIN95_CLASSES | ICC_PROGRESS_CLASS};
  InitCommonControlsEx(&icc);
  A.inst = inst;
  HDC dc = GetDC(nullptr);
  A.dpi = GetDeviceCaps(dc, LOGPIXELSX);
  ReleaseDC(nullptr, dc);
  A.taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
  const bool background = wcsstr(cmd, L"--background") != nullptr;

  WNDCLASSW wc{};
  wc.lpfnWndProc = proc;
  wc.hInstance = inst;
  wc.lpszClassName = kClass;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = GetSysColorBrush(COLOR_BTNFACE);
  wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
  RegisterClassW(&wc);

  RECT r{0, 0, S(480), S(600)};
  const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
  AdjustWindowRect(&r, style, FALSE);
  A.wnd = CreateWindowExW(0, kClass, L"R6 Replay Uploader", style, CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left, r.bottom - r.top, nullptr, nullptr, inst, nullptr);
  build_form();
  tray_add();

  core::Config c;
  const bool have = core::load_config(c) && c.configured();
  if (have) {
    A.cfg = c;
    A.state = core::load_state();
    SetWindowTextW(A.server, plat::from_utf8(c.server).c_str());
    SetWindowTextW(A.token, plat::from_utf8(c.token).c_str());
    SetWindowTextW(A.folder, c.folder.wstring().c_str());
    SendMessageW(A.rawFallback, BM_SETCHECK, c.raw_fallback ? BST_CHECKED : BST_UNCHECKED, 0);
  } else {
    auto f = core::discover();   // first run: suggest the folder
    if (!f.empty()) SetWindowTextW(A.folder, f[0].first.wstring().c_str());
  }
  SendMessageW(A.autostart, BM_SETCHECK, autostart_enabled() ? BST_CHECKED : BST_UNCHECKED, 0);
  {
    core::Config lc;
    core::load_config(lc);
    A.cfg.live = lc.live;
    A.cfg.use_obs = lc.use_obs;
    A.cfg.obs_port = lc.obs_port;
    A.cfg.obs_password = lc.obs_password;
    A.cfg.live_min_score = lc.live_min_score;
    A.cfg.live_offsets = lc.live_offsets;
    SendMessageW(A.liveBox, BM_SETCHECK, lc.live ? BST_CHECKED : BST_UNCHECKED, 0);
    if (lc.live) set_live(true);
  }
  start_worker();
  if (!(background && have)) ShowWindow(A.wnd, SW_SHOW);
  UpdateWindow(A.wnd);

  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    HWND hw = highlights_window();
    if (!IsDialogMessageW(A.wnd, &msg) && !(hw && IsDialogMessageW(hw, &msg))) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
  }
  stop_worker();
  recorder().stop();   // finish the last recorded minute
  CoUninitialize();
  if (once) CloseHandle(once);
  return 0;
}
