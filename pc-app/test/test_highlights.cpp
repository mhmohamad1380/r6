// Tests of the highlight detector on hand-made rounds, where the right answer is known.
#include <cstdio>
#include <string>
#include <vector>

#include "../src/highlights.hpp"
#include "../src/json.hpp"

static int failures = 0, checks = 0;
#define CHECK(c) do { checks++; if (!(c)) { failures++; std::printf("  FAIL line %d: %s\n", __LINE__, #c); } } while (0)
#define SECTION(n) std::printf("%s\n", n)

// Me ("Me") and four teammates on team 0, five enemies on team 1. events: {type, actor, target, clock, headshot}.
struct Ev { const char* type; const char* actor; const char* target; int clock; bool hs; };

static mini::Json round(const std::vector<Ev>& events, bool weWon, int number = 3, const char* role = "Attack") {
  std::string players;
  const char* mates[] = {"Me", "A1", "A2", "A3", "A4"};
  const char* foes[] = {"E0", "E1", "E2", "E3", "E4"};
  for (int i = 0; i < 5; i++) players += std::string(i ? "," : "") + "{\"username\":\"" + mates[i] + "\",\"teamIndex\":0,\"profileID\":\"" + (i ? std::string("p") + mates[i] : "me-profile") + "\",\"operator\":{\"name\":\"" + (i ? "Sledge" : "Ash") + "\"}}";
  for (int i = 0; i < 5; i++) players += std::string(",{\"username\":\"") + foes[i] + "\",\"teamIndex\":1,\"profileID\":\"p" + foes[i] + "\",\"operator\":{\"name\":\"Op" + std::to_string(i) + "\"}}";
  std::string ev;
  for (size_t i = 0; i < events.size(); i++) {
    const Ev& e = events[i];
    ev += std::string(i ? "," : "") + "{\"type\":{\"name\":\"" + e.type + "\"},\"username\":\"" + e.actor + "\"" + (e.target ? std::string(",\"target\":\"") + e.target + "\"" : "") +
          ",\"timeInSeconds\":" + std::to_string(e.clock) + ",\"headshot\":" + (e.hs ? "true" : "false") + "}";
  }
  const std::string other = std::string(role) == "Attack" ? "Defense" : "Attack";
  const std::string text = std::string("{\"matchID\":\"match-1234\",\"roundNumber\":") + std::to_string(number) + ",\"timestamp\":\"2026-10-30T20:00:00Z\",\"map\":{\"name\":\"BankY10\"},\"matchType\":{\"name\":\"Ranked\"},\"recordingProfileID\":\"me-profile\"," +
                           "\"teams\":[{\"role\":\"" + role + "\",\"score\":1,\"won\":" + (weWon ? "true" : "false") + "},{\"role\":\"" + other + "\",\"score\":0,\"won\":" + (weWon ? "false" : "true") + "}]," +
                           "\"players\":[" + players + "],\"matchFeedback\":[" + ev + "]}";
  mini::Json j;
  mini::parse(text, j);
  return j;
}

static bool has(const hl::Highlight& h, const std::string& tag) {
  for (const auto& t : h.tags) if (t == tag) return true;
  return false;
}

int main() {
  const std::vector<std::string> me = {"Me"};

  SECTION("who the player is: the profile that recorded most rounds");
  {
    auto a = round({}, true), b = round({}, true);
    CHECK(hl::recorder_names({a, b}) == std::vector<std::string>{"Me"});
  }

  SECTION("kills close together are one moment, far apart are two");
  {
    auto r = round({{"Kill", "Me", "E0", 150, true}, {"Kill", "Me", "E1", 140, false}, {"Kill", "Me", "E2", 100, false}}, false);
    auto h = hl::detect_round(r, me);
    CHECK(h.size() == 2);
    CHECK(h[0].kills.size() == 2 && h[0].type == "multikill" && has(h[0], "entry"));
    // 2 kills (1+1) + 1 headshot + 3 for the second kill + 1 entry = 7
    CHECK(h[0].score == 7);
    CHECK(h[0].from == 25 && h[0].to == 43);   // first kill at 30 s minus 5, last at 40 s plus 3
    CHECK(h[1].kills.size() == 1 && h[1].type == "kill" && h[1].score == 1);
    CHECK(h[0].round == 4 && h[0].map == "Bank" && h[0].op == "Ash" && h[0].side == "Attack");
  }

  SECTION("an ace is one moment however long it takes");
  {
    auto r = round({{"Kill", "Me", "E0", 170, true}, {"Kill", "Me", "E1", 140, true}, {"Kill", "Me", "E2", 110, false}, {"Kill", "Me", "E3", 80, false}, {"Kill", "Me", "E4", 30, true}}, true);
    auto h = hl::detect_round(r, me);
    CHECK(h.size() == 1);
    CHECK(h[0].type == "ace" && h[0].kills.size() == 5 && has(h[0], "round_winner") && has(h[0], "entry"));
    // 5 + 3 headshots + 12 (4 extra kills) + 10 ace + 2 round winner + 1 entry = 33
    CHECK(h[0].score == 33);
  }

  SECTION("a won clutch: last one standing against two");
  {
    auto r = round({{"Kill", "E0", "A1", 160, false}, {"Kill", "E1", "A2", 150, false}, {"Kill", "Me", "E0", 145, false}, {"Kill", "E2", "A3", 120, false},
                    {"Death", "E3", nullptr, 110, false},   // an enemy falls to their death
                    {"Kill", "A4", "E4", 100, false},       // a teammate trades one: E1 and E2 are left
                    {"Kill", "E1", "A4", 90, false},        // I am alone against E1 and E2: 1v2 starts at 90 s
                    {"Kill", "Me", "E1", 60, true}, {"Kill", "Me", "E2", 35, false}}, true);
    auto h = hl::detect_round(r, me);
    const hl::Highlight* c = nullptr;
    for (const auto& x : h) if (x.type == "clutch") c = &x;
    CHECK(c != nullptr);
    if (c) {
      CHECK(c->clutch_vs == 2 && c->kills.size() == 2 && has(*c, "round_winner"));
      CHECK(c->from == 85);   // the clip starts when the clutch did (90 s), minus the 5 s pad; the kills are 25 s apart
      // 2 kills + 1 headshot + 3 extra kill + 10 for 1v2 + 2 round winner = 18
      CHECK(c->score == 18);
    }
    CHECK(hl::detect({r}, me)[0].type == "clutch");   // detect() ranks best first
  }

  SECTION("a lost clutch is not called a clutch");
  {
    auto r = round({{"Kill", "E0", "A1", 160, false}, {"Kill", "E0", "A2", 150, false}, {"Kill", "E0", "A3", 140, false}, {"Kill", "E0", "A4", 130, false},
                    {"Kill", "Me", "E1", 120, false}, {"Kill", "E0", "Me", 100, false}}, false);
    auto h = hl::detect_round(r, me);
    CHECK(h.size() == 1 && h[0].clutch_vs == 0 && !has(h[0], "clutch"));
  }

  SECTION("team kills are not highlights, and do not count as the entry");
  {
    auto r = round({{"Kill", "Me", "A1", 170, true}, {"Kill", "E0", "A2", 160, false}, {"Kill", "Me", "E0", 120, false}}, true);
    auto h = hl::detect_round(r, me);
    CHECK(h.size() == 1 && h[0].kills.size() == 1 && h[0].kills[0].victim == "E0" && !has(h[0], "entry"));
  }

  SECTION("after a plant the game times kills on the defuser clock: placed after the plant, marked approximate");
  {
    auto r = round({{"Kill", "E0", "A1", 120, false}, {"DefuserPlantComplete", "A2", nullptr, 44, false}, {"Kill", "Me", "E1", 30, true}}, true);
    auto h = hl::detect_round(r, me);
    CHECK(h.size() == 1 && h[0].approx && h[0].kills[0].post_plant);
    CHECK(h[0].kills[0].t == 60 + 15);   // last known moment before the plant (60 s) + 15 s into the 45 s countdown
  }

  SECTION("not in the round: nothing");
  {
    auto r = round({{"Kill", "Me", "E0", 150, true}}, true);
    CHECK(hl::detect_round(r, {"Somebody"}).empty());
  }

  SECTION("ids are stable, a minimum score filters, and the JSON is valid");
  {
    auto r = round({{"Kill", "Me", "E0", 150, true}, {"Kill", "Me", "E1", 100, false}}, true);
    auto a = hl::detect_round(r, me), b = hl::detect_round(r, me);
    CHECK(a.size() == 2 && a[0].id == b[0].id && a[0].id != a[1].id && a[0].id.size() == 36);
    hl::Options o;
    o.min_score = 3;
    CHECK(hl::detect_round(r, me, o).size() == 1);   // the entry headshot (1+1+1) stays, the plain kill goes
    mini::Json j;
    CHECK(mini::parse(hl::to_json(hl::detect({r}, me), me), j) && j.at("highlights").a.size() == 2 && j.at("highlights").at(0).at("clip").at("from").n == 25);
    CHECK(hl::describe(a[0]).find("Round 4 on Bank: 1 kill, entry, headshot as Ash") == 0);
  }

  std::printf("\n%d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
