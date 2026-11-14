// Live clips: while you play, OBS keeps the last minutes of gameplay in its replay buffer. When a round's replay file
// appears, this finds your best moments in it, has OBS save the buffer, cuts each moment out and uploads it.
//
// Where a moment is in the saved video: the round's replay says when the round started (wall clock, to the second);
// the moment is that many seconds into the round; the saved video ends when OBS saved it and is as long as it is. The
// gap between "the round started" in the replay and "the round timer started" (operator pick and preparation) is not
// in the file: it is learned once per game mode from one press of the calibration key, and guessed (with wider clips)
// until then. Nothing touches the game: OBS records the screen, and this program reads the replay files.
#pragma once
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "clips.hpp"
#include "highlights.hpp"
#include "recorder.hpp"

namespace live {

struct Settings {
  bool enabled = false;
  bool use_obs = false;                    // false: the built-in recorder (no OBS needed); true: OBS's replay buffer
  int obs_port = 4455;
  std::string obs_password;
  int min_score = 3;                       // moments below this are not clipped
  std::map<std::string, double> offsets;   // per game mode: seconds from the replay's round start to the round timer starting
  std::string server, token;               // where clips go (the uploader's own server and upload token)
  std::string clips_dir;
  bool keep_buffer_files = false;
};

// The guess before calibration: operator selection and the preparation phase.
double default_offset(const std::string& mode);

double parse_utc(const std::string& iso);   // "2026-10-30T13:45:56Z" -> seconds since 1970; -1 if it is not a time
double wall_now();

struct Job {
  std::vector<hl::Highlight> list;
  std::string match_id, video, mode;   // video: OBS's saved file (empty with the built-in recorder)
  int round = 0;
  double round_start = 0;   // wall clock, from the replay
  double saved_at = 0;      // wall clock, when OBS saved the buffer
  double offset = 0;
  bool calibrated = false;
};

class Clipper {
 public:
  using Log = std::function<void(const std::string&)>;
  explicit Clipper(Log log = nullptr) : log_(std::move(log)) {}

  void configure(const Settings& s);
  Settings settings();

  // Called when the game is (or is not) running: connects to OBS and keeps the replay buffer on while it runs.
  // Returns a line for the status display.
  std::string keep_buffer(bool game_running);

  // Called with each round the uploader has just read (the trimmed round JSON). Saves OBS's buffer at once when the round
  // has moments worth clipping, and queues the cutting. Rounds from long ago (catching up on old files) are left alone.
  // replay_written: when the game finished writing this round's replay (wall clock), for the timing line in the log.
  void on_round(const std::string& round_json, double replay_written = -1);

  // The calibration key: "the round timer just started". Remembered until the round's replay arrives.
  void calibrate_now();

  // Cuts and uploads what on_round queued. Returns the number of clips sent. Runs on a worker thread.
  int drain();

  // The built-in recorder (owned by the caller). Without one, or with use_obs, OBS is used.
  void use_recorder(rec::Recorder* r) { recorder_ = r; }
  rec::Options recorder_options;   // where its pieces go

  // Seams for tests: the clock, reading a video's length, and cutting (pieces joined in order; the still is taken from
  // thumb_file at thumb_offset).
  std::function<double()> now = wall_now;
  std::function<bool(const std::string& video, double& seconds, std::string& error)> duration;
  std::function<bool(const std::vector<rec::Part>& parts, const std::string& out, const std::string& thumb_out, const std::string& thumb_file, double thumb_offset, std::string& error)> cut;
  std::function<void(const Settings&)> on_settings_changed;   // calibration learned something: save it
  std::function<void(const std::string&)> timing_log;         // the per-round timing line (to the log file only)

 private:
  Log log_;
  std::mutex mu_;          // settings, jobs, the calibration press
  std::mutex obs_mu_;      // one OBS conversation at a time
  Settings s_;
  std::deque<Job> jobs_;
  double press_ = -1;      // when the calibration key was pressed
  clips::Obs obs_;
  rec::Recorder* recorder_ = nullptr;
  bool startedRecorder_ = false;   // only stop the recorder if live clips started it (the replay window may be using it)
  bool builtin() { return recorder_ && !settings().use_obs; }
  bool warned_buffer_ = false;
  std::vector<std::pair<std::string, std::vector<hl::Highlight>>> pending_;   // cut rounds not on the server yet (drain thread only)
  int upload_pending(const Settings& s, const std::string& what);
  bool connect(std::string& error);
  void say(const std::string& m) { if (log_) log_(m); }
};

}  // namespace live
