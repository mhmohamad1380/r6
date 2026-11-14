// Finds the player's best moments in parsed rounds: multi-kills, aces, clutches, entries, headshots and round-winning
// kills. Pure logic on the trimmed round JSON the uploader already makes; nothing here touches the game or the network.
//
// Time: every highlight is placed on the round's action phase, in seconds since the round timer started counting down
// from 3:00. Kills after a plant are timed by the game on the 45-second defuser countdown and the plant itself has no
// usable time, so those clips are marked approximate: the recording step lets the player nudge them.
#pragma once
#include <string>
#include <vector>

#include "json.hpp"

namespace hl {

struct Options {
  double window = 15;        // kills closer than this (seconds) belong to one moment
  double pad_before = 5;     // clip starts this long before the first kill
  double pad_after = 3;      // and ends this long after the last one
  double round_length = 180; // action phase length, the clock the game counts down
  int min_score = 1;         // leave out anything below this
};

struct Kill {
  double t = 0;              // seconds into the action phase
  int clock = 0;             // what the in-game timer showed (remaining seconds; after a plant, the defuser timer)
  bool post_plant = false;
  bool approx = false;       // after a plant: the exact second is not known
  bool headshot = false;
  std::string victim, victim_operator;
};

struct Highlight {
  std::string id;            // stable: the same moment always gets the same id
  std::string match_id, map, map_raw, mode, played_at, op, side;
  int round = 0;             // 1-based, as the game shows it
  std::string type;          // ace | clutch | multikill | entry | headshot | kill
  std::vector<std::string> tags;  // every quality it has, e.g. multikill, entry, round_winner
  int score = 0;
  int clutch_vs = 0;         // enemies alive when the player became the last one on their team (0 = no clutch)
  bool won = false;
  std::vector<Kill> kills;
  double begin = 0;          // when the moment starts, unpadded (the first kill, or when a clutch began)
  double from = 0, to = 0;   // the clip, seconds into the action phase
  bool approx = false;
};

// The names of whoever recorded most of these rounds (each replay says which profile recorded it).
std::vector<std::string> recorder_names(const std::vector<mini::Json>& rounds);

std::vector<Highlight> detect_round(const mini::Json& round, const std::vector<std::string>& me, const Options& opt = {});
std::vector<Highlight> detect(const std::vector<mini::Json>& rounds, const std::vector<std::string>& me, const Options& opt = {});  // best first

std::string item_json(const Highlight& h);   // one highlight as a JSON object (what the server receives)
std::string to_json(const std::vector<Highlight>& list, const std::vector<std::string>& me);
bool from_json(const std::string& text, std::vector<Highlight>& out);   // reads what to_json wrote (a list the player may have trimmed)
std::string describe(const Highlight& h);  // one line for people: "Round 4 on Bank: 3K clutch 1v2 as Ash, 14 points"

}  // namespace hl
