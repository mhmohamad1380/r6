import 'dart:convert';

import 'map_names.dart';

/// One thing that happened in a round. [remaining] is the seconds left on the round timer
/// (it counts down, so a larger value is earlier). It is null when the source's times are unusable.
class ReplayEvent {
  const ReplayEvent({required this.type, this.actor, this.target, this.headshot = false, this.remaining, this.operator, this.message});
  final String type; // Kill, LocateObjective, DefuserPlantComplete, DefuserDisableComplete, OperatorSwap, PlayerLeave, Other
  final String? actor, target, operator, message;
  final bool headshot;
  final int? remaining;

  bool get isKill => type == 'Kill';
  bool get isPlant => type.contains('Plant') && type.contains('Complete');
  bool get isDefuse => type.contains('Disable') && type.contains('Complete'); // DefuserDisableComplete. DefuserPlantComplete contains 'Defus' too
  bool get isDeath => type == 'Death'; // died with no killer: a fall, the map, their own gadget. [actor] is who died

  List<Object?> toJson() => [type, actor, target, headshot ? 1 : 0, remaining, operator, message];
  factory ReplayEvent.fromJson(List<dynamic> j) =>
      ReplayEvent(type: j[0] as String, actor: j[1] as String?, target: j[2] as String?, headshot: j[3] == 1, remaining: (j[4] as num?)?.toInt(), operator: j[5] as String?, message: j[6] as String?);
}

class ReplayPlayer {
  const ReplayPlayer({required this.name, required this.team, this.operator, this.profileId, this.kills, this.deaths, this.assists, this.score, this.spawn});
  final String name;
  final int team;
  final String? operator, profileId;
  final String? spawn; // where they started: an attacker's spawn point, or a defender's site
  final int? kills, deaths, assists, score; // only some sources provide these

  List<Object?> toJson() => [name, team, operator, profileId, kills, deaths, assists, score, spawn];
  factory ReplayPlayer.fromJson(List<dynamic> j) => ReplayPlayer(
        name: j[0] as String,
        team: (j[1] as num).toInt(),
        operator: j[2] as String?,
        profileId: j[3] as String?,
        kills: (j[4] as num?)?.toInt(),
        deaths: (j[5] as num?)?.toInt(),
        assists: (j[6] as num?)?.toInt(),
        score: (j[7] as num?)?.toInt(),
        spawn: j.length > 8 ? j[8] as String? : null, // older saves have 8 fields
      );
}

class ReplayTeam {
  const ReplayTeam({required this.role, required this.score, required this.won, this.winCondition});
  final String role; // Attack | Defense
  final int score;
  final bool won;
  final String? winCondition;

  bool get attack => role.toLowerCase().startsWith('att');

  List<Object?> toJson() => [role, score, won ? 1 : 0, winCondition];
  factory ReplayTeam.fromJson(List<dynamic> j) => ReplayTeam(role: j[0] as String, score: (j[1] as num).toInt(), won: j[2] == 1, winCondition: j[3] as String?);
}

/// A single round, normalized from either r6-dissect JSON or an Arenyze replay response.
class ReplayRound {
  const ReplayRound({
    required this.matchId,
    required this.number,
    required this.map,
    required this.matchType,
    required this.teams,
    required this.players,
    required this.events,
    required this.source,
    this.at,
    this.mode,
    this.site,
    this.roundsPerMatch,
    this.planted = false,
    this.defused = false,
    this.recorder,
    this.overtimeAt,
    this.season,
  });

  final String matchId, map, matchType, source; // source: dissect | arenyze
  final int number;
  final DateTime? at;
  final String? mode, site;
  final String? recorder; // profile id of the player whose game recorded this file: the person the replay belongs to
  final int? overtimeAt; // the first overtime round, when the file says (0 = none)
  final String? season; // game version, such as Y11S3
  final int? roundsPerMatch;
  final List<ReplayTeam> teams;
  final List<ReplayPlayer> players;
  final List<ReplayEvent> events;
  final bool planted, defused;

  String get key => '$matchId#$number';

  /// True when kill times are real, which strict trade and timing stats need.
  bool get timed => events.where((e) => e.isKill).isNotEmpty && events.where((e) => e.isKill).every((e) => e.remaining != null);

  Map<String, dynamic> toJson() => {
        'id': matchId,
        'n': number,
        'at': at?.toUtc().toIso8601String(),
        'map': map,
        'mt': matchType,
        'md': mode,
        'st': site,
        'rpm': roundsPerMatch,
        'tm': [for (final t in teams) t.toJson()],
        'pl': [for (final p in players) p.toJson()],
        'ev': [for (final e in events) e.toJson()],
        'pn': planted ? 1 : 0,
        'df': defused ? 1 : 0,
        'src': source,
        'rc': recorder,
        'ot': overtimeAt,
        'gv': season,
      };

  factory ReplayRound.fromJson(Map<String, dynamic> j) => ReplayRound(
        matchId: j['id'] as String,
        number: (j['n'] as num).toInt(),
        at: j['at'] == null ? null : DateTime.tryParse(j['at'] as String),
        map: mapDisplayName(j['map'] as String),
        matchType: j['mt'] as String,
        mode: j['md'] as String?,
        site: j['st'] as String?,
        roundsPerMatch: (j['rpm'] as num?)?.toInt(),
        teams: [for (final t in j['tm'] as List) ReplayTeam.fromJson(t as List)],
        players: [for (final p in j['pl'] as List) ReplayPlayer.fromJson(p as List)],
        events: [for (final e in j['ev'] as List) ReplayEvent.fromJson(e as List)],
        planted: j['pn'] == 1,
        defused: j['df'] == 1,
        source: j['src'] as String,
        recorder: j['rc'] as String?,
        overtimeAt: (j['ot'] as num?)?.toInt(),
        season: j['gv'] as String?,
      );

  /// The number of rounds a team must win: first to 4 in a 6-round ranked match, first to 3 in quick match.
  int get winTarget => (roundsPerMatch ?? 6) ~/ 2 + 1;

  /// True for overtime rounds. Uses the file's own marker when it has one, else the regular round count.
  bool get overtime => (overtimeAt != null && overtimeAt! > 0) ? number >= overtimeAt! : (roundsPerMatch != null && number >= roundsPerMatch!);
}

// ---------- parsing ----------

String? _s(Object? v) => v == null ? null : (v is Map ? _s(v['name']) : v.toString());
int? _i(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

const _known = {'Kill', 'Death', 'LocateObjective', 'OperatorSwap', 'PlayerLeave', 'Other'};

bool _isEventWeKeep(String type) => _known.contains(type) || type.contains('Plant') || type.contains('Disable') || type.contains('Defus');

List<ReplayTeam> _teams(Object? raw) => [
      for (final t in (raw as List? ?? const []))
        ReplayTeam(
          role: _s((t as Map)['role']) ?? '',
          score: _i(t['score']) ?? 0,
          won: t['won'] == true,
          winCondition: (t['winCondition'] as String?)?.isEmpty == true ? null : t['winCondition'] as String?,
        ),
    ];

/// r6-dissect JSON (`r6-dissect round.rec -o round.json`): `{header, matchFeedback}`. Times are real.
ReplayRound? parseDissectRound(Map<String, dynamic> j) {
  final h = (j['header'] ?? j) as Map<String, dynamic>; // the oldest format is flat
  final feedback = (j['matchFeedback'] as List?) ?? const [];
  final id = _s(h['matchID']);
  final rawMap = _s(h['map']);
  if (id == null || rawMap == null) return null;
  final map = mapDisplayName(rawMap);
  final events = <ReplayEvent>[];
  var planted = false, defused = false;
  for (final raw in feedback) {
    final e = raw as Map;
    final type = _s(e['type']) ?? 'Other';
    if (!_isEventWeKeep(type)) continue;
    final ev = ReplayEvent(
      type: type,
      actor: (e['username'] as String?)?.isEmpty == true ? null : e['username'] as String?,
      target: (e['target'] as String?)?.isEmpty == true ? null : e['target'] as String?,
      headshot: e['headshot'] == true,
      remaining: _i(e['timeInSeconds']),
      operator: _s(e['operator']),
      message: e['message'] as String?,
    );
    if (ev.isPlant) planted = true;
    if (ev.isDefuse) defused = true;
    events.add(ev);
  }
  return ReplayRound(
    matchId: id,
    number: _i(h['roundNumber']) ?? 1,
    at: DateTime.tryParse(_s(h['timestamp']) ?? ''),
    map: map,
    matchType: _s(h['matchType']) ?? 'Unknown',
    mode: _s(h['gamemode'] ?? h['gameMode']),
    site: h['site'] as String?,
    roundsPerMatch: _i(h['roundsPerMatch']),
    teams: _teams(h['teams']),
    players: [
      for (final p in (h['players'] as List? ?? const []))
        ReplayPlayer(name: (p as Map)['username'] as String? ?? '', team: _i(p['teamIndex']) ?? 0, operator: _s(p['operator']), profileId: p['profileID'] as String?, spawn: _blank(p['spawn'])),
    ],
    events: events,
    source: 'dissect',
    planted: planted,
    defused: defused,
    recorder: _s(h['recordingProfileID']),
    overtimeAt: _i(h['overtimeRoundNumber']),
    season: _blank(h['gameVersion']),
  );
}

String? _blank(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

/// One entry of an Arenyze replay response. Its kill order, killers, victims and headshots match
/// dissect, but every event time is the end of the round, so times are dropped (remaining = null).
ReplayRound? parseArenyzeRound(Map<String, dynamic> r, {Map<String, dynamic>? match}) {
  final h = r['header'] as Map<String, dynamic>?;
  if (h == null) return null;
  final id = _s(h['matchID']);
  final rawMap = _s(h['map']);
  if (id == null || rawMap == null) return null;
  final map = mapDisplayName(rawMap);
  final events = <ReplayEvent>[];
  for (final raw in (r['matchFeedback'] as List? ?? const [])) {
    final e = raw as Map;
    final type = _s(e['type']) ?? 'Other';
    if (!_isEventWeKeep(type)) continue; // drops LocationUpdate
    events.add(ReplayEvent(
      type: type,
      actor: (e['username'] as String?)?.isEmpty == true ? null : e['username'] as String?,
      target: (e['target'] as String?)?.isEmpty == true ? null : e['target'] as String?,
      headshot: e['headshot'] == true,
      operator: _s(e['operator']),
      message: e['message'] as String?,
    ));
  }
  final outcome = ((r['analysis'] as Map?)?['outcome'] as Map?) ?? const {};
  return ReplayRound(
    matchId: id,
    number: _i(h['roundNumber']) ?? 1,
    at: DateTime.tryParse(_s(h['timestamp']) ?? ''),
    map: map,
    matchType: _s(h['matchType']) ?? 'Unknown',
    mode: _s(h['gameMode'] ?? h['gamemode']),
    site: h['site'] as String?,
    roundsPerMatch: _i(h['roundsPerMatch']),
    teams: _teams(h['teams']),
    players: [
      for (final p in (h['players'] as List? ?? const []))
        ReplayPlayer(
          name: (p as Map)['username'] as String,
          team: _i(p['teamIndex']) ?? 0,
          operator: _s(p['operator']),
          kills: _i((p['stats'] as Map?)?['kills']),
          deaths: _i((p['stats'] as Map?)?['deaths']),
          assists: _i((p['stats'] as Map?)?['assists']),
          score: _i((p['stats'] as Map?)?['score']),
        ),
    ],
    events: events,
    source: 'arenyze',
    planted: outcome['planted'] == true,
    defused: outcome['defused'] == true,
    recorder: _s(h['recordingProfileID']),
  );
}

/// Reads dissect JSON or an Arenyze response: a single round, a list of rounds, or `{rounds: [...]}`.
/// Returns what could be parsed; [errors] counts entries that were skipped.
({List<ReplayRound> rounds, int errors}) parseReplayJson(String text) {
  final rounds = <ReplayRound>[];
  var errors = 0;
  void one(Object? x) {
    try {
      if (x is! Map<String, dynamic>) {
        errors++;
        return;
      }
      final arenyze = x['analysis'] != null || x['parserEngine'] != null;
      final r = arenyze ? parseArenyzeRound(x) : parseDissectRound(x);
      r == null ? errors++ : rounds.add(r);
    } on Object {
      errors++;
    }
  }

  try {
    final j = jsonDecode(text.trim());
    if (j is List) {
      j.forEach(one);
    } else if (j is Map<String, dynamic> && j['rounds'] is List) {
      (j['rounds'] as List).forEach(one);
    } else {
      one(j);
    }
  } on Object {
    errors++;
  }
  return (rounds: rounds, errors: errors);
}
