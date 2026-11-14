// The part of the built-in recorder that is the same everywhere: finding which recorded pieces hold a moment.
#include <algorithm>
#include <string>

#include "recorder.hpp"

namespace rec {

bool parts_for(const std::vector<Segment>& footage, double from, double to, std::vector<Part>& parts, double* covered_from, double* covered_to) {
  parts.clear();
  double lo = -1, hi = -1;
  for (const auto& s : footage) {   // oldest first
    const double a = std::max(from, s.start), b = std::min(to, s.end);
    if (b - a <= 0.001) continue;
    parts.push_back({s.path, a - s.start, b - a});
    if (lo < 0) lo = a;
    hi = b;
  }
  if (covered_from) *covered_from = lo;
  if (covered_to) *covered_to = hi;
  if (parts.empty()) return false;
  // Fully covered: starts at `from`, ends at `to`, and no gap between pieces of more than a frame or two.
  double at = from;
  for (const auto& s : footage) {
    if (s.end <= from || s.start >= to) continue;
    if (s.start > at + 0.1) return false;
    at = std::max(at, s.end);
  }
  return at >= to - 0.1;
}

std::vector<size_t> to_delete(const std::vector<Segment>& footage, const std::vector<long long>& sizes, double now, int keep_seconds, long long max_bytes) {
  long long total = 0;
  for (auto b : sizes) total += b;
  std::vector<size_t> out;
  for (size_t i = 0; i < footage.size(); i++) {   // oldest first
    const bool tooOld = footage[i].end < now - keep_seconds;
    if (!tooOld && total <= max_bytes) break;
    out.push_back(i);
    total -= i < sizes.size() ? sizes[i] : 0;
  }
  return out;
}

#ifndef _WIN32
// Not Windows: no screen to record. Tests use their own stand-in recorder.
namespace {
class NoRecorder : public Recorder {
 public:
  bool start(const Options&, std::string& error) override { error = "the built-in recorder only works on Windows"; return false; }
  void stop() override {}
  bool running() const override { return false; }
  bool flush(std::string&) override { return true; }
  std::vector<Segment> segments() override { return {}; }
  std::string status() override { return "Recorder: only on Windows."; }
};
}  // namespace
std::unique_ptr<Recorder> make_recorder() { return std::make_unique<NoRecorder>(); }
#endif

}  // namespace rec
