// The Highlights window: find a match's best moments, record its replay with OBS while the player plays it in Siege,
// mark each round's start with a key, and cut one clip per moment with ffmpeg.
//
// Nothing here touches the game. The player opens and plays the replay; OBS records the screen; F9 and F10 are ordinary
// Windows hotkeys that only tell this program "the round timer just started" and "the defuser was just planted".
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <commdlg.h>
#include <shellapi.h>

#include <algorithm>
#include <condition_variable>
#include <deque>
#include <set>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "clips.hpp"
#include "core.hpp"
#include "highlights_window.hpp"
#include "platform.hpp"

namespace {

constexpr wchar_t kClass[] = L"R6HighlightsWnd";
enum Id { IDH_PORT = 401, IDH_PASS, IDH_CONNECT, IDH_OBSSTAT, IDH_MATCH, IDH_FIND, IDH_LIST, IDH_START, IDH_STOP, IDH_UNDO, IDH_NEXT, IDH_FFSTAT, IDH_FFBROWSE, IDH_CUT, IDH_OPEN, IDH_LOG, IDH_USEOBS };
enum Msg { WMH_LOG = WM_APP + 40, WMH_OBS, WMH_FOUND, WMH_MARK, WMH_RECORDING, WMH_STOPPED, WMH_CUTDONE, WMH_FOOTAGE };
enum Hot { HOT_START = 1, HOT_PLANT = 2 };

struct Found {
  std::string match_id, error;
  std::vector<hl::Highlight> list;
  std::vector<std::string> me;
  int rounds = 0, unreadable = 0;
};
struct Mark { int round; bool plant; double at; std::string error; };

struct State {
  HINSTANCE inst = nullptr;
  HWND wnd = nullptr, owner = nullptr;
  HWND port = nullptr, pass = nullptr, obsStat = nullptr, match = nullptr, list = nullptr, next = nullptr, ffStat = nullptr, log = nullptr;
  HWND connectBtn = nullptr, findBtn = nullptr, startBtn = nullptr, stopBtn = nullptr, undoBtn = nullptr, cutBtn = nullptr, openBtn = nullptr;
  HFONT font = nullptr, bold = nullptr, big = nullptr;
  int dpi = 96;
  core::Config cfg;
  std::vector<clips::MatchFolder> matches;
  std::vector<hl::Highlight> highlights;
  std::vector<int> rounds;   // rounds with highlights, in order: the ones to mark
  clips::Session session;
  bool obsOk = false, recording = false, busy = false, cutting = false;
  std::wstring hotStart = L"F9", hotPlant = L"F10";
  std::vector<std::pair<int, bool>> markOrder;   // for undo
  std::mutex obsMu;
  clips::Obs obs;   // used from worker threads only, under obsMu
  // The built-in recorder (shared with live clips; owned by the main window), unless the player chose OBS.
  rec::Recorder* rec = nullptr;
  rec::Options recOpts;
  bool startedRecorder = false;
  // Cutting as it goes (built-in recorder): each moment is cut, uploaded and deleted soon after it was played, so the
  // session never needs more than the recorder's rolling minutes on disk.
  std::mutex qMu;
  std::condition_variable qCv;
  std::deque<std::pair<hl::Highlight, clips::RoundMark>> queue;
  std::set<std::string> queued;
  bool stopping = false;
  std::thread worker;
  int clipsSent = 0, clipsFailed = 0;
  double sessionStart = 0;
  HWND useObsBox = nullptr;
  bool use_obs() const { return cfg.use_obs || !rec; }
} H;

constexpr UINT_PTR kCutTimer = 9;

double wall_clock() { return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count(); }

int S(int v) { return MulDiv(v, H.dpi, 96); }

std::wstring w(const std::string& s) { return plat::from_utf8(s); }
std::string u(const std::wstring& s) { return plat::to_utf8(s); }

std::wstring text_of(HWND h) {
  int n = GetWindowTextLengthW(h);
  std::wstring s((size_t)n + 1, L'\0');
  GetWindowTextW(h, s.data(), n + 1);
  s.resize((size_t)n);
  return s;
}

void post_log(const std::string& m) { PostMessageW(H.wnd, WMH_LOG, 0, (LPARAM) new std::wstring(w(m))); }

void add_log(const std::wstring& line) {
  SYSTEMTIME t;
  GetLocalTime(&t);
  wchar_t stamp[16];
  wsprintfW(stamp, L"%02d:%02d:%02d  ", t.wHour, t.wMinute, t.wSecond);
  const LRESULT i = SendMessageW(H.log, LB_ADDSTRING, 0, (LPARAM)(stamp + line).c_str());
  SendMessageW(H.log, LB_SETTOPINDEX, (WPARAM)i, 0);
}

HFONT make_font(int pt, int weight) {
  NONCLIENTMETRICSW ncm{};
  ncm.cbSize = sizeof(ncm);
  SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0);
  LOGFONTW lf = ncm.lfMessageFont;
  lf.lfHeight = -MulDiv(pt, H.dpi, 72);
  lf.lfWeight = weight;
  return CreateFontIndirectW(&lf);
}

HWND ctl(const wchar_t* cls, const wchar_t* text, DWORD style, int x, int y, int wd, int ht, int id, DWORD ex = 0) {
  HWND c = CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | style, x, y, wd, ht, H.wnd, (HMENU)(INT_PTR)id, H.inst, nullptr);
  SendMessageW(c, WM_SETFONT, (WPARAM)H.font, TRUE);
  return c;
}

int text_height(const std::wstring& text, HFONT font, int width_px, int min_lines = 1) {
  HDC dc = GetDC(H.wnd);
  HGDIOBJ old = SelectObject(dc, font);
  RECT r{0, 0, width_px, 0};
  DrawTextW(dc, text.c_str(), -1, &r, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
  TEXTMETRICW tm{};
  GetTextMetricsW(dc, &tm);
  SelectObject(dc, old);
  ReleaseDC(H.wnd, dc);
  return std::max<int>(r.bottom, tm.tmHeight * min_lines);
}

int paragraph(const std::wstring& text, int y, HFONT font, int x, int wd, int min_lines = 1, HWND* out = nullptr, int id = 0) {
  const int h = text_height(text, font, wd, min_lines);
  HWND c = ctl(L"STATIC", text.c_str(), SS_LEFT | SS_NOPREFIX, x, y, wd, h, id);
  SendMessageW(c, WM_SETFONT, (WPARAM)font, TRUE);
  if (out) *out = c;
  return y + h;
}

// ---------------------------------------------------------------- what the window shows

std::wstring clock_text(double s) {
  const int t = (int)(s + 0.5);
  wchar_t b[16];
  wsprintfW(b, L"%d:%02d", t / 60, t % 60);
  return b;
}

int next_round() {
  for (int r : H.rounds) {
    auto it = H.session.rounds.find(r);
    if (it == H.session.rounds.end() || it->second.start < 0) return r;
  }
  return 0;
}

bool round_needs_plant(int r) {
  for (const auto& h : H.highlights)
    if (h.round == r && h.approx) return true;
  return false;
}

std::string ffmpeg() { return clips::find_ffmpeg(H.cfg.ffmpeg); }

void refresh() {
  // The big line: exactly what to do now.
  std::wstring next;
  const bool ready = !H.use_obs() || H.obsOk;
  if (!ready) next = L"First connect to OBS (step 1).";
  else if (H.highlights.empty()) next = L"Pick a match and press Find highlights (step 2).";
  else if (!H.recording && H.session.recording.empty()) next = L"Press Start recording, then open this match's replay in Siege.";
  else if (H.recording) {
    const int r = next_round();
    if (r) {
      next = L"Go to round " + std::to_wstring(r) + L" in the replay. Press " + H.hotStart + L" the moment its timer starts counting down from 3:00.";
      int last = H.markOrder.empty() ? 0 : H.markOrder.back().first;
      if (last && round_needs_plant(last) && H.session.rounds[last].plant < 0) next += L" (Round " + std::to_wstring(last) + L" has a moment after the plant: press " + H.hotPlant + L" when the defuser goes down.)";
    } else {
      next = H.use_obs() ? L"Every round is marked. Let the last moment play out, then press Stop recording."
                         : L"Every round is marked. Clips are cut and uploaded as each moment ends. Press Stop recording when the last one has played.";
    }
  } else next = L"Recording saved. Press Cut and upload: the clips appear in the phone app.";
  SetWindowTextW(H.next, next.c_str());

  // The list: each moment, and whether its round is marked.
  SendMessageW(H.list, LB_RESETCONTENT, 0, 0);
  for (const auto& h : H.highlights) {
    auto it = H.session.rounds.find(h.round);
    const bool marked = it != H.session.rounds.end() && it->second.start >= 0;
    std::wstring line = (marked ? L"[marked]  " : L"                ") + w(hl::describe(h));
    SendMessageW(H.list, LB_ADDSTRING, 0, (LPARAM)line.c_str());
  }
  SendMessageW(H.list, LB_SETHORIZONTALEXTENT, (WPARAM)S(1400), 0);

  const std::string ff = ffmpeg();
  SetWindowTextW(H.ffStat, ff.empty() ? L"Clips are cut with Windows' own video engine: nothing to install."
                                     : (L"Clips are cut with Windows' own video engine (and " + w(ff) + L" if Windows cannot read a recording).").c_str());
  EnableWindow(H.findBtn, !H.busy && !H.recording && !H.matches.empty());
  EnableWindow(H.startBtn, ready && !H.highlights.empty() && !H.recording && !H.busy);
  EnableWindow(H.stopBtn, H.recording);
  EnableWindow(H.undoBtn, H.recording && !H.markOrder.empty());
  EnableWindow(H.cutBtn, !H.recording && !H.session.recording.empty() && !H.cutting);
  EnableWindow(H.connectBtn, !H.recording && H.use_obs());
  EnableWindow(H.port, H.use_obs());
  EnableWindow(H.pass, H.use_obs());
  EnableWindow(H.useObsBox, !H.recording && H.rec);
  if (!H.use_obs()) SetWindowTextW(H.obsStat, L"Not needed: the built-in recorder records the screen.");
  EnableWindow(H.match, !H.recording && !H.busy);
}

void load_matches() {
  SendMessageW(H.match, CB_RESETCONTENT, 0, 0);
  H.matches = clips::match_folders(H.cfg.folder);
  for (const auto& m : H.matches) {
    const std::wstring line = w(m.name) + L"   (" + std::to_wstring(m.files) + L" rounds)";
    SendMessageW(H.match, CB_ADDSTRING, 0, (LPARAM)line.c_str());
  }
  if (!H.matches.empty()) SendMessageW(H.match, CB_SETCURSEL, 0, 0);
  else add_log(L"No matches found in the replay folder. Set it in the main window first.");
}

// ---------------------------------------------------------------- actions (slow parts run on worker threads)

void save_settings() {
  core::Config c;
  core::load_config(c);
  c.obs_port = _wtoi(text_of(H.port).c_str()) > 0 ? _wtoi(text_of(H.port).c_str()) : 4455;
  c.obs_password = u(text_of(H.pass));
  c.ffmpeg = H.cfg.ffmpeg;
  core::save_config(c);
  H.cfg.obs_port = c.obs_port;
  H.cfg.obs_password = c.obs_password;
}

// Before each OBS action: reconnect if OBS was restarted or the link dropped. Call with obsMu held.
bool ensure_obs(std::string& err) {
  if (H.obs.connected()) return true;
  return H.obs.connect("127.0.0.1", H.cfg.obs_port, H.cfg.obs_password, err);
}

void connect_obs() {
  save_settings();
  SetWindowTextW(H.obsStat, L"Connecting...");
  const int port = H.cfg.obs_port;
  const std::string pass = H.cfg.obs_password;
  std::thread([port, pass] {
    std::string err;
    bool ok;
    {
      std::lock_guard<std::mutex> g(H.obsMu);
      ok = H.obs.connect("127.0.0.1", port, pass, err);
    }
    PostMessageW(H.wnd, WMH_OBS, ok ? 1 : 0, (LPARAM) new std::wstring(w(ok ? "Connected to OBS." : err)));
  }).detach();
}

void find_highlights() {
  const LRESULT i = SendMessageW(H.match, CB_GETCURSEL, 0, 0);
  if (i < 0 || i >= (LRESULT)H.matches.size()) return;
  H.busy = true;
  refresh();
  const auto dir = H.matches[(size_t)i].dir;
  add_log(L"Reading the match's replays...");
  std::thread([dir] {
    auto* f = new Found();
    const auto rounds = clips::read_match(dir, f->error, &f->unreadable);
    f->rounds = (int)rounds.size();
    if (!rounds.empty()) {
      f->me = hl::recorder_names(rounds);
      f->list = hl::detect(rounds, f->me);
      f->match_id = rounds.front().at("matchID").str();
      std::ofstream(clips::sessions_dir() / w(f->match_id + ".highlights.json"), std::ios::binary) << hl::to_json(f->list, f->me);
    }
    PostMessageW(H.wnd, WMH_FOUND, 0, (LPARAM)f);
  }).detach();
}

void register_hotkeys() {
  // Plain F9 and F10 if nothing else has them, else with Ctrl+Alt.
  H.hotStart = L"F9";
  H.hotPlant = L"F10";
  if (!RegisterHotKey(H.wnd, HOT_START, MOD_NOREPEAT, VK_F9)) {
    RegisterHotKey(H.wnd, HOT_START, MOD_NOREPEAT | MOD_CONTROL | MOD_ALT, VK_F9);
    H.hotStart = L"Ctrl+Alt+F9";
  }
  if (!RegisterHotKey(H.wnd, HOT_PLANT, MOD_NOREPEAT, VK_F10)) {
    RegisterHotKey(H.wnd, HOT_PLANT, MOD_NOREPEAT | MOD_CONTROL | MOD_ALT, VK_F10);
    H.hotPlant = L"Ctrl+Alt+F10";
  }
}

void unregister_hotkeys() {
  UnregisterHotKey(H.wnd, HOT_START);
  UnregisterHotKey(H.wnd, HOT_PLANT);
}

// Queues every marked moment whose clip has been played (or, at the end, every marked moment).
void queue_ready(bool all) {
  const double now = wall_clock();
  std::lock_guard<std::mutex> g(H.qMu);
  for (const auto& h : H.highlights) {
    if (H.queued.count(h.id)) continue;
    auto it = H.session.rounds.find(h.round);
    if (it == H.session.rounds.end() || it->second.start < 0) continue;
    double end = it->second.start + h.to;
    if (h.approx && it->second.plant < 0) end += 60;   // give the player time to press the plant key
    if (!all && now < end + 2) continue;
    H.queued.insert(h.id);
    H.queue.push_back({h, it->second});
  }
  H.qCv.notify_all();
}

void cut_worker() {
  for (;;) {
    std::pair<hl::Highlight, clips::RoundMark> job;
    {
      std::unique_lock<std::mutex> lk(H.qMu);
      H.qCv.wait(lk, [] { return !H.queue.empty() || H.stopping; });
      if (H.queue.empty()) break;   // stopping, and nothing left
      job = H.queue.front();
      H.queue.pop_front();
    }
    const hl::Highlight& h = job.first;
    std::string err;
    H.rec->flush(err);   // the last seconds must be in a finished minute
    clips::Session one;
    one.match_id = h.match_id;
    one.recording = "built-in recorder";
    one.rounds[h.round] = job.second;
    one.footage = H.rec->segments();
    const auto base = H.cfg.clips_dir.empty() ? clips::default_clips_dir() : H.cfg.clips_dir;
    const std::string dir = u((base / w(h.match_id) / w(h.id.substr(0, 8))).wstring());
    const auto res = clips::cut_all(one, {h}, ffmpeg(), dir);
    if (res.empty() || !res[0].ok) {
      H.clipsFailed++;
      post_log("Could not cut " + hl::describe(h) + ": " + (res.empty() ? std::string("no result") : res[0].error));
      continue;
    }
    if (H.cfg.server.empty() || H.cfg.token.empty()) { post_log("Cut " + hl::describe(h) + " (no server set up: kept in " + dir + ")"); continue; }
    const auto up = clips::upload_clips(H.cfg.server, H.cfg.token, dir, {h}, nullptr, 4 * 1024 * 1024, true);
    if (up.sent || up.already) { H.clipsSent++; post_log("Uploaded " + hl::describe(h)); }
    else { H.clipsFailed++; post_log("Cut " + hl::describe(h) + " but could not upload it" + (up.stopped ? ": " + up.message : "") + ". It is in " + dir); }
  }
  // Session over: stop the recorder (which deletes its minutes) unless live clips use it.
  core::Config c;
  core::load_config(c);
  if (H.startedRecorder && !c.live) H.rec->stop();
  H.startedRecorder = false;
  PostMessageW(H.wnd, WMH_FOOTAGE, 0, 0);
}

void start_recording() {
  H.busy = true;
  refresh();
  if (!H.use_obs()) {   // the built-in recorder: it keeps the last minutes; each moment is cut soon after it was played
    std::thread([] {
      std::string err;
      bool ok = true;
      if (!H.rec->running()) {
        ok = H.rec->start(H.recOpts, err);
        H.startedRecorder = ok;
      }
      PostMessageW(H.wnd, WMH_RECORDING, ok ? 1 : 0, (LPARAM) new std::wstring(w(err)));
    }).detach();
    return;
  }
  std::thread([] {
    std::string err;
    bool ok;
    {
      std::lock_guard<std::mutex> g(H.obsMu);
      ok = ensure_obs(err) && H.obs.start_record(err);
    }
    PostMessageW(H.wnd, WMH_RECORDING, ok ? 1 : 0, (LPARAM) new std::wstring(w(err)));
  }).detach();
}

void stop_recording() {
  if (!H.use_obs()) {   // cut what is left, then finish (the worker says when)
    KillTimer(H.wnd, kCutTimer);
    queue_ready(true);
    {
      std::lock_guard<std::mutex> g(H.qMu);
      H.stopping = true;
    }
    H.qCv.notify_all();
    H.busy = true;
    add_log(L"Stopping: cutting the last clips...");
    refresh();
    return;
  }
  std::thread([] {
    std::string err, path;
    bool ok;
    {
      std::lock_guard<std::mutex> g(H.obsMu);
      ok = ensure_obs(err) && H.obs.stop_record(path, err);
    }
    PostMessageW(H.wnd, WMH_STOPPED, ok ? 1 : 0, (LPARAM) new std::wstring(w(ok ? path : err)));
  }).detach();
}

void mark(bool plant) {
  if (!H.recording) return;
  int round = plant ? (H.markOrder.empty() ? 0 : H.markOrder.back().first) : next_round();
  if (!round) { MessageBeep(MB_ICONHAND); return; }
  if (!H.use_obs()) {   // the built-in recorder works in wall-clock time: the mark is simply "now"
    PostMessageW(H.wnd, WMH_MARK, 0, (LPARAM) new Mark{round, plant, wall_clock(), ""});
    return;
  }
  std::thread([round, plant] {
    auto* m = new Mark{round, plant, -1, ""};
    bool active = false;
    {
      std::lock_guard<std::mutex> g(H.obsMu);
      if (!ensure_obs(m->error) || !H.obs.record_time(m->at, active, m->error)) m->at = -1;
      else if (!active) { m->at = -1; m->error = "OBS is not recording"; }
    }
    PostMessageW(H.wnd, WMH_MARK, 0, (LPARAM)m);
  }).detach();
}

void cut() {
  H.cutting = true;
  refresh();
  const clips::Session s = H.session;
  const auto list = H.highlights;
  const std::string ff = ffmpeg();
  const auto base = H.cfg.clips_dir.empty() ? clips::default_clips_dir() : H.cfg.clips_dir;
  const std::string dir = u((base / w(s.match_id)).wstring());
  add_log(L"Cutting " + std::to_wstring(list.size()) + L" clips into " + w(dir));
  std::thread([s, list, ff, dir] {
    const auto res = clips::cut_all(s, list, ff, dir, [](int done, int total, const std::string& line) { post_log(std::to_string(done) + "/" + std::to_string(total) + "  " + line); });
    int ok = 0;
    for (const auto& r : res) ok += r.ok;
    // Then straight to the server, so they show up in the phone app. Anything that fails is sent next time.
    if (ok && !H.cfg.server.empty() && !H.cfg.token.empty()) {
      post_log("Sending the clips to your server...");
      const auto up = clips::upload_clips(H.cfg.server, H.cfg.token, dir, list, [](int, int, const std::string& line) { post_log(line); });
      post_log(std::to_string(up.sent) + " clips sent to the server" + (up.already ? ", " + std::to_string(up.already) + " were there already" : "") +
               (up.failed ? ", " + std::to_string(up.failed) + " failed (press Cut and upload again to retry)" : "") + (up.stopped ? ". Stopped: " + up.message : "."));
    }
    PostMessageW(H.wnd, WMH_CUTDONE, (WPARAM)ok, (LPARAM) new std::wstring(w(dir)));
  }).detach();
}

void choose_ffmpeg() {
  wchar_t file[MAX_PATH] = L"ffmpeg.exe";
  OPENFILENAMEW of{};
  of.lStructSize = sizeof of;
  of.hwndOwner = H.wnd;
  of.lpstrFilter = L"ffmpeg.exe\0ffmpeg.exe\0Programs\0*.exe\0";
  of.lpstrFile = file;
  of.nMaxFile = MAX_PATH;
  of.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
  if (!GetOpenFileNameW(&of)) return;
  H.cfg.ffmpeg = u(file);
  save_settings();
  refresh();
}

// ---------------------------------------------------------------- layout

void build() {
  H.font = make_font(9, FW_NORMAL);
  H.bold = make_font(9, FW_SEMIBOLD);
  H.big = make_font(13, FW_SEMIBOLD);
  const int m = S(20), W = S(560), gap = S(10), field = S(24), btn = S(28);
  int y = S(14);
  y = paragraph(L"Highlights", y, H.big, m, W) + S(4);
  y = paragraph(L"Turns your best moments in a replay into video clips. You play the replay in Siege, this program records the screen and cuts "
                L"the clips. It never touches the game. (For clips while you play, use \"Record live clips\" in the main window.)", y, H.font, m, W) + gap;

  y = paragraph(L"1. Recording", y, H.bold, m, W) + S(2);
  const std::wstring obsText = L"Use OBS instead of the built-in recorder (in OBS: Tools > WebSocket Server Settings > Enable; the port and password are under Show Connect Info)";
  const int oh = text_height(obsText, H.font, W - S(22)) + S(4);
  H.useObsBox = ctl(L"BUTTON", obsText.c_str(), WS_TABSTOP | BS_AUTOCHECKBOX | BS_MULTILINE, m, y, W, oh, IDH_USEOBS);
  SendMessageW(H.useObsBox, BM_SETCHECK, H.use_obs() ? BST_CHECKED : BST_UNCHECKED, 0);
  y += oh + S(4);
  ctl(L"STATIC", L"Port", SS_LEFT, m, y + S(4), S(34), field, 0);
  H.port = ctl(L"EDIT", std::to_wstring(H.cfg.obs_port).c_str(), WS_TABSTOP | ES_NUMBER, m + S(36), y, S(60), field, IDH_PORT, WS_EX_CLIENTEDGE);
  ctl(L"STATIC", L"Password", SS_LEFT, m + S(110), y + S(4), S(64), field, 0);
  H.pass = ctl(L"EDIT", w(H.cfg.obs_password).c_str(), WS_TABSTOP | ES_AUTOHSCROLL | ES_PASSWORD, m + S(176), y, S(220), field, IDH_PASS, WS_EX_CLIENTEDGE);
  H.connectBtn = ctl(L"BUTTON", L"Connect", WS_TABSTOP, m + W - S(120), y - 1, S(120), btn - S(1), IDH_CONNECT);
  y += field + S(4);
  y = paragraph(L"Not connected.", y, H.font, m, W, 1, &H.obsStat, IDH_OBSSTAT) + gap;

  y = paragraph(L"2. Match", y, H.bold, m, W) + S(2);
  H.match = ctl(L"COMBOBOX", L"", WS_TABSTOP | CBS_DROPDOWNLIST | WS_VSCROLL, m, y, W - S(150), S(240), IDH_MATCH);
  H.findBtn = ctl(L"BUTTON", L"Find highlights", WS_TABSTOP, m + W - S(140), y - 1, S(140), btn - S(1), IDH_FIND);
  y += btn + S(4);
  const int listH = S(110);
  H.list = ctl(L"LISTBOX", L"", WS_TABSTOP | WS_VSCROLL | WS_HSCROLL | LBS_NOINTEGRALHEIGHT | LBS_NOSEL, m, y, W, listH, IDH_LIST, WS_EX_CLIENTEDGE);
  y += listH + gap;

  y = paragraph(L"3. Record", y, H.bold, m, W) + S(2);
  y = paragraph(L"Play each round at normal speed from the moment you mark it until its moments are over. Speeding up or skipping inside a round moves the clips.",
                y, H.font, m, W) + S(6);
  y = paragraph(L"First connect to OBS (step 1).", y, H.bold, m, W, 3, &H.next, IDH_NEXT) + S(6);
  const int bw = S(150);
  H.startBtn = ctl(L"BUTTON", L"Start recording", WS_TABSTOP, m, y, bw, btn, IDH_START);
  H.stopBtn = ctl(L"BUTTON", L"Stop recording", WS_TABSTOP, m + bw + S(8), y, bw, btn, IDH_STOP);
  H.undoBtn = ctl(L"BUTTON", L"Undo last mark", WS_TABSTOP, m + W - S(130), y, S(130), btn, IDH_UNDO);
  y += btn + gap;

  y = paragraph(L"4. Clips", y, H.bold, m, W) + S(2);
  y = paragraph(L"ffmpeg not found.", y, H.font, m, W, 2, &H.ffStat, IDH_FFSTAT) + S(4);
  H.cutBtn = ctl(L"BUTTON", L"Cut and upload", WS_TABSTOP | BS_DEFPUSHBUTTON, m, y, bw, btn, IDH_CUT);
  ctl(L"BUTTON", L"Choose ffmpeg...", WS_TABSTOP, m + bw + S(8), y, bw, btn, IDH_FFBROWSE);
  H.openBtn = ctl(L"BUTTON", L"Open clips folder", WS_TABSTOP, m + W - S(150), y, S(150), btn, IDH_OPEN);
  y += btn + gap;

  const int logH = S(100);
  H.log = ctl(L"LISTBOX", L"", WS_TABSTOP | WS_VSCROLL | WS_HSCROLL | LBS_NOINTEGRALHEIGHT | LBS_NOSEL, m, y, W, logH, IDH_LOG, WS_EX_CLIENTEDGE);
  SendMessageW(H.log, LB_SETHORIZONTALEXTENT, (WPARAM)S(1400), 0);
  y += logH + S(16);

  RECT r{0, 0, W + 2 * m, y};
  AdjustWindowRect(&r, (DWORD)GetWindowLongPtrW(H.wnd, GWL_STYLE), FALSE);
  SetWindowPos(H.wnd, nullptr, 0, 0, r.right - r.left, r.bottom - r.top, SWP_NOMOVE | SWP_NOZORDER);
}

// ---------------------------------------------------------------- messages

LRESULT CALLBACK proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_COMMAND:
      switch (LOWORD(wp)) {
        case IDH_CONNECT: connect_obs(); break;
        case IDH_FIND: find_highlights(); break;
        case IDH_START: start_recording(); break;
        case IDH_STOP: stop_recording(); break;
        case IDH_UNDO:
          if (!H.markOrder.empty()) {
            auto [r, plant] = H.markOrder.back();
            H.markOrder.pop_back();
            (plant ? H.session.rounds[r].plant : H.session.rounds[r].start) = -1;
            clips::save_session(H.session);
            add_log(L"Removed the last mark (round " + std::to_wstring(r) + L").");
            refresh();
          }
          break;
        case IDH_FFBROWSE: choose_ffmpeg(); break;
        case IDH_USEOBS: {
          const bool on = SendMessageW(H.useObsBox, BM_GETCHECK, 0, 0) == BST_CHECKED;
          core::Config c;
          core::load_config(c);
          c.use_obs = on;
          core::save_config(c);
          H.cfg.use_obs = on;
          if (on) connect_obs();
          refresh();
          break;
        }
        case IDH_CUT: cut(); break;
        case IDH_OPEN: {
          const auto base = H.cfg.clips_dir.empty() ? clips::default_clips_dir() : H.cfg.clips_dir;
          std::error_code ec;
          core::fs::create_directories(base, ec);
          ShellExecuteW(H.wnd, L"open", base.wstring().c_str(), nullptr, nullptr, SW_SHOWNORMAL);
          break;
        }
        case IDH_MATCH:
          if (HIWORD(wp) == CBN_SELCHANGE) {
            H.highlights.clear();
            H.rounds.clear();
            H.session = {};
            refresh();
          }
          break;
      }
      return 0;
    case WM_HOTKEY:
      mark(wp == HOT_PLANT);
      return 0;
    case WMH_LOG: {
      std::unique_ptr<std::wstring> s((std::wstring*)lp);
      add_log(*s);
      return 0;
    }
    case WMH_OBS: {
      std::unique_ptr<std::wstring> s((std::wstring*)lp);
      H.obsOk = wp == 1;
      SetWindowTextW(H.obsStat, s->c_str());
      add_log(*s);
      refresh();
      return 0;
    }
    case WMH_FOUND: {
      std::unique_ptr<Found> f((Found*)lp);
      H.busy = false;
      if (!f->error.empty()) add_log(w("Could not read the replays: " + f->error));
      else if (f->rounds == 0) add_log(L"No rounds in that match could be read.");
      else {
        H.highlights = f->list;
        H.rounds = clips::rounds_to_mark(f->list);
        H.session = {};
        H.markOrder.clear();
        if (!clips::load_session(f->match_id, H.session)) H.session.match_id = f->match_id;   // marks from an earlier try are kept
        std::string who;
        for (const auto& n : f->me) who += (who.empty() ? "" : ", ") + n;
        add_log(w(std::to_string(f->rounds) + " rounds read" + (f->unreadable ? " (" + std::to_string(f->unreadable) + " unreadable)" : "") + ", " +
                  std::to_string(f->list.size()) + " highlights for " + who + "."));
        if (f->list.empty()) add_log(L"No kills of yours in this match, so nothing to record.");
      }
      refresh();
      return 0;
    }
    case WMH_RECORDING: {
      std::unique_ptr<std::wstring> s((std::wstring*)lp);
      H.busy = false;
      if (wp == 1) {
        H.recording = true;
        H.session.rounds.clear();   // a new recording: marks from an earlier one would point at the wrong video
        H.session.recording.clear();
        H.markOrder.clear();
        clips::save_session(H.session);
        H.session.footage.clear();
        clips::save_session(H.session);
        register_hotkeys();
        if (!H.use_obs()) {
          {
            std::lock_guard<std::mutex> g(H.qMu);
            H.queue.clear();
            H.queued.clear();
            H.stopping = false;
          }
          H.clipsSent = H.clipsFailed = 0;
          if (H.worker.joinable()) H.worker.join();
          H.worker = std::thread(cut_worker);
          SetTimer(H.wnd, kCutTimer, 2000, nullptr);
        }
        add_log(H.use_obs() ? L"OBS is recording. Switch to Siege and open this match's replay." : L"Recording the screen. Switch to Siege and open this match's replay.");
      } else {
        add_log((H.use_obs() ? L"OBS did not start recording: " : L"The recorder could not start: ") + *s);
      }
      refresh();
      return 0;
    }
    case WMH_MARK: {
      std::unique_ptr<Mark> m((Mark*)lp);
      if (m->at < 0) {
        MessageBeep(MB_ICONHAND);
        add_log(w("Could not mark round " + std::to_string(m->round) + ": " + m->error));
      } else {
        auto& rm = H.session.rounds[m->round];
        (m->plant ? rm.plant : rm.start) = m->at;
        H.markOrder.push_back({m->round, m->plant});
        clips::save_session(H.session);
        MessageBeep(MB_ICONASTERISK);   // heard in the game: the mark landed
        add_log(L"Round " + std::to_wstring(m->round) + (m->plant ? L": plant" : L": timer start") + (H.use_obs() ? L" at " + clock_text(m->at) + L" in the recording." : L" noted."));
      }
      refresh();
      return 0;
    }
    case WMH_STOPPED: {
      std::unique_ptr<std::wstring> s((std::wstring*)lp);
      if (wp == 1) {
        H.recording = false;
        unregister_hotkeys();
        H.session.recording = u(*s);
        clips::save_session(H.session);
        add_log(L"Recording saved: " + *s);
        if (next_round()) add_log(L"Some rounds were not marked; their moments will be skipped when cutting.");
      } else {
        add_log(L"OBS did not stop: " + *s);
      }
      refresh();
      return 0;
    }
    case WMH_FOOTAGE: {   // the built-in recorder's session is over: every clip was cut and sent as it went
      if (H.worker.joinable()) H.worker.join();
      H.recording = false;
      H.busy = false;
      unregister_hotkeys();
      add_log(L"Done: " + std::to_wstring(H.clipsSent) + L" clip" + (H.clipsSent == 1 ? L"" : L"s") + L" uploaded" +
              (H.clipsFailed ? L", " + std::to_wstring(H.clipsFailed) + L" could not be made" : L"") + L". The recording is deleted.");
      if (next_round()) add_log(L"Some rounds were not marked, so their moments were not cut.");
      refresh();
      return 0;
    }
    case WM_TIMER:
      if (wp == kCutTimer && H.recording && !H.use_obs()) queue_ready(false);
      return 0;
    case WMH_CUTDONE: {
      std::unique_ptr<std::wstring> s((std::wstring*)lp);
      H.cutting = false;
      add_log(std::to_wstring((int)wp) + L" clips saved in " + *s);
      refresh();
      return 0;
    }
    case WM_CLOSE:
      if (H.recording && MessageBoxW(h, L"Still recording. Close anyway? This recording will not be cut.", L"Highlights", MB_YESNO | MB_ICONQUESTION) != IDYES) return 0;
      DestroyWindow(h);
      return 0;
    case WM_DESTROY:
      unregister_hotkeys();
      KillTimer(h, kCutTimer);
      if (H.worker.joinable()) {   // closed mid-session: drop what is not cut yet, finish the clip being cut
        {
          std::lock_guard<std::mutex> g(H.qMu);
          H.queue.clear();
          H.stopping = true;
        }
        H.qCv.notify_all();
        H.worker.join();
      }
      {
        std::lock_guard<std::mutex> g(H.obsMu);
        H.obs.close();
      }
      H.wnd = nullptr;
      H.recording = false;
      H.obsOk = false;
      return 0;
  }
  return DefWindowProcW(h, msg, wp, lp);
}

}  // namespace

void open_highlights_window(HINSTANCE inst, HWND owner, int dpi, rec::Recorder* recorder, const rec::Options& recorder_options) {
  H.rec = recorder;
  H.recOpts = recorder_options;
  if (H.wnd) {
    ShowWindow(H.wnd, SW_SHOWNORMAL);
    SetForegroundWindow(H.wnd);
    return;
  }
  static bool registered = false;
  if (!registered) {
    WNDCLASSW wc{};
    wc.lpfnWndProc = proc;
    wc.hInstance = inst;
    wc.lpszClassName = kClass;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = GetSysColorBrush(COLOR_BTNFACE);
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
    RegisterClassW(&wc);
    registered = true;
  }
  H.inst = inst;
  H.owner = owner;
  H.dpi = dpi;
  H.cfg = {};
  core::load_config(H.cfg);
  H.highlights.clear();
  H.rounds.clear();
  H.session = {};
  H.markOrder.clear();
  const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
  H.wnd = CreateWindowExW(0, kClass, L"Highlights - R6 Replay Uploader", style, CW_USEDEFAULT, CW_USEDEFAULT, S(600), S(700), owner, nullptr, inst, nullptr);
  build();
  load_matches();
  refresh();
  ShowWindow(H.wnd, SW_SHOWNORMAL);
  if (H.use_obs() && (!H.cfg.obs_password.empty() || H.cfg.obs_port != 4455)) connect_obs();   // set up before: connect straight away
}

HWND highlights_window() { return H.wnd; }
