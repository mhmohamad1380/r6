// The built-in recorder: records the screen and the PC's sound into one-minute MP4 pieces on disk, keeping the last
// minutes (like a replay buffer), so clips can be cut from any moment that just happened. No OBS needed.
//
// It uses what Windows provides for screen sharing (DXGI Desktop Duplication), the graphics card to scale and convert
// the picture, the sound card's loopback (what you hear), and the graphics card's H.264 encoder. It never touches the
// game. Every time is wall-clock time (seconds since 1970), so a moment from a replay file can be found in the pieces.
#pragma once
#include <memory>
#include <string>
#include <vector>

namespace rec {

struct Segment {
  std::string path;
  double start = 0, end = 0;   // wall clock
};

struct Options {
  std::wstring dir;            // where the pieces go
  int fps = 30;
  int height = 720;            // the picture is scaled to this height (never up)
  int bitrate = 8000000;       // high enough that cutting a clip from it (a second encode) still looks good
  int keep_seconds = 720;      // the rolling buffer: older pieces are deleted
  int segment_seconds = 60;
  // A hard limit on disk: finished pieces never take more than this. With the piece being written (about 60 MB) and
  // clips waiting to upload (at most 60 MB, see live.cpp) the program stays under 700 MB in all.
  long long max_bytes = 580LL * 1000 * 1000;
};

constexpr long long kPendingClipBytes = 60LL * 1000 * 1000;   // clips cut but not uploaded yet (server unreachable)

class Recorder {
 public:
  virtual ~Recorder() = default;
  virtual bool start(const Options& o, std::string& error) = 0;
  virtual void stop() = 0;                       // stops and deletes every recorded piece
  virtual bool running() const = 0;
  virtual bool flush(std::string& error) = 0;    // finishes the current piece now, so its last seconds can be cut
  virtual std::vector<Segment> segments() = 0;   // finished pieces, oldest first
  virtual std::string status() = 0;              // one line: what it records, or why it cannot
};

std::unique_ptr<Recorder> make_recorder();       // the Windows recorder; on other systems one whose start() fails

// Which finished pieces to delete: the oldest, until what is left is younger than keep_seconds and fits in max_bytes.
// sizes[i] is the size of footage[i] (oldest first).
std::vector<size_t> to_delete(const std::vector<Segment>& footage, const std::vector<long long>& sizes, double now, int keep_seconds, long long max_bytes);

// The pieces of footage that cover [from, to] (wall clock), as (file, offset in file, length) parts in order.
// Returns false when the window is not fully covered; covered_from/covered_to say what is.
struct Part {
  std::string path;
  double offset = 0, length = 0;
};
bool parts_for(const std::vector<Segment>& footage, double from, double to, std::vector<Part>& parts, double* covered_from = nullptr, double* covered_to = nullptr);

}  // namespace rec
