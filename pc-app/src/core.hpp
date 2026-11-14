// The uploader's logic: settings, finding the replay folder, deciding what to send, sending it.
#pragma once
#include <filesystem>
#include <functional>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace core {
namespace fs = std::filesystem;

constexpr const char* kVersion = "1.7.0";
// What the server is told about the reader that produced a round. The server refuses a version below its minimum, so bump this
// whenever the bundled reader (r6-dissect) changes, for example after a game patch adds operators or maps.
constexpr const char* kParserVersion = "1.3.0";
constexpr const char* kParserBuild = "e6c2ca8+unknown-operators-1";
constexpr uint64_t kRawFallbackMax = 20ull << 20;   // a replay the PC could not read is sent as the file itself only up to this size
constexpr int kStableSeconds = 6;   // a replay must be this old: the game may still be writing it
constexpr int kDefaultPoll = 20;

struct Config {
  std::string server;      // https://...
  std::string token;       // the UPLOAD token
  fs::path folder;         // the MatchReplay folder
  int poll = kDefaultPoll;
  bool raw_fallback = true;   // send the file itself when this PC cannot read it, so it can be looked at on the server
  // Highlights: OBS's remote control, ffmpeg, and where clips go. All optional.
  int obs_port = 4455;
  std::string obs_password;
  std::string ffmpeg;      // empty: look next to the program and on PATH
  fs::path clips_dir;      // empty: Videos\R6 Highlights
  // Live clips while playing (OBS replay buffer).
  bool live = false;
  bool use_obs = false;    // record with OBS instead of the built-in recorder
  int live_min_score = 3;
  std::map<std::string, double> live_offsets;   // per game mode, learned from one key press
  bool configured() const { return !server.empty() && !token.empty() && !folder.empty(); }
};

struct Counts {
  int parsed = 0, duplicate = 0, failed = 0, rejected = 0, error = 0, skipped = 0;
  int known = 0;   // already on the server, so not sent again
  uint64_t bytes = 0;   // sent in full this pass
  int local = 0;        // read on this PC and sent as small JSON
  int fell_back = 0;    // could not be read here, so the file itself went to the server
  bool update_needed = false;   // the server refused this reader as too old
  std::string update_message;
  int uploaded() const { return parsed + duplicate + failed; }
};

using Logger = std::function<void(const std::string&)>;

std::string normalize_url(std::string url);

// Settings and "already uploaded" memory live in %APPDATA%\R6ReplayUploader.
bool load_config(Config& c);
bool save_config(const Config& c);
// Memory of what is done. Two kinds of entry share the map:
//   <64 hex characters>  ->  what happened to that content (parsed, duplicate, failed, skipped, on server)
//   <path|size|mtime>    ->  "#<64 hex characters>", the fingerprint of that file, so it is read only once
// A replay is identified by its content, never by its name or where it sits.
using State = std::map<std::string, std::string>;
State load_state();
int done_count(const State& s);
void remember(State& s, const std::string& key, const std::string& status);

// Checks the address and token. On success message says so; on failure it explains why.
bool check_server(const std::string& server, const std::string& token, std::string& message);

// Folders that look like Siege's MatchReplay folder, most replays first.
std::vector<std::pair<fs::path, int>> discover();
std::vector<fs::path> candidate_folders();
int count_rec(const fs::path& folder);

std::string sha256_file(const fs::path& p);       // lowercase hex; empty if the file cannot be read
std::string sha256_bytes(const std::string& data);
std::string file_key(const fs::path& p);
std::string fingerprint(const fs::path& p, State& s);   // the content hash, from memory when the file is unchanged
bool is_stable(const fs::path& p);
bool looks_like_replay(const fs::path& p);
// Every stable .rec under the folder (any depth: one folder per match is the usual shape) that is not done yet, oldest first.
std::vector<fs::path> scan(const fs::path& folder, State& state);

// Live progress of the file being sent.
struct UploadStatus {
  std::string name;
  uint64_t sent = 0, total = 0;
  double bytes_per_second = 0;   // average since this file started
  int index = 0, of = 0;         // "2 of 5"
  std::string phase = "Uploading";   // or "Reading": the replay is being read on this PC
  int percent() const { return total == 0 ? 100 : (int)(sent * 100 / total); }
};
using Progress = std::function<void(const UploadStatus&)>;

std::string human_size(uint64_t bytes);       // "9.4 MB"
std::string human_speed(double bytes_per_second);   // "3.1 MB/s"
std::string log_file_path();                  // %APPDATA%\R6ReplayUploader\uploader.log (kept to about 1 MB)

// Reading a replay on this PC: runs the bundled r6-dissect and keeps only the fields the apps use.
struct LocalRead {
  bool ok = false;
  bool helper_unusable = false;   // the reader program is missing or this Windows cannot run it: send the file itself instead
  std::string payload;            // the whole request body for POST /v1/parsed
  std::string reason;             // why it failed, in one line
  std::string summary;            // one line on how the round went, for the log
  double seconds = 0;
};
LocalRead read_replay(const fs::path& rec, const std::string& sha, uint64_t size);
std::string trim_round(const std::string& dissect_json, std::string& error);   // the apps' fields of one parsed round, as compact JSON
std::string map_display_name(const std::string& raw);   // "Map(407987100456)" -> Border, "ClubHouseY10" -> Clubhouse
std::string round_summary(const std::string& round_json);   // "Round 3 on Border (Ranked): you attacked and won. 2 kills, 1 headshot, survived"
std::string failure_payload(const std::string& file, const std::string& sha, uint64_t size, const std::string& reason);
std::string failure_reason(const std::string& output);   // the one line that says what went wrong in the reader's output
bool is_done(const State& s, const std::string& sha);    // handled for this reader version (a failure by an older reader is retried)

// Finds replays that are not done, asks the server which it already has, uploads the rest.
// Stops early if the server cannot be reached; nothing is lost and the next pass retries.
// Every message goes to the logger (with a clock prefix) and to the log file.
// onRound, when given, receives each round read on this PC (its trimmed JSON) as soon as it is read: live clips use it.
using RoundHook = std::function<void(const std::string& round_json, double replay_written)>;   // written: wall clock, -1 if unknown
void write_log_file(const std::string& msg);   // a line in uploader.log
Counts sync_once(const Config& cfg, State& state, const Logger& log, const Progress& progress = nullptr, const RoundHook& onRound = nullptr);

// Tells when something in the replay folder changed and then went quiet (the game finished writing).
// Works even if the folder does not exist yet: it keeps looking for it.
class Watcher {
 public:
  explicit Watcher(fs::path folder, int quiet_seconds = kStableSeconds + 1);
  ~Watcher();
  Watcher(const Watcher&) = delete;
  Watcher& operator=(const Watcher&) = delete;
  bool wait_settled(int ms);   // blocks up to ms; true when changes happened and have settled
 private:
  fs::path folder_;
  int quiet_;
  void* handle_ = nullptr;
  bool pending_ = false;
  long long last_ms_ = 0;
};

}  // namespace core
