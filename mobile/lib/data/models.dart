/// Parsed Arenyze responses. Missing values stay null; they are never coerced to 0.
num? _n(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);
num? _statValue(Object? stat) => _n(stat is Map ? stat['value'] : stat);

class SeasonSegment {
  const SeasonSegment({this.shortName, this.seasonName, this.sessionType, required this.stats});
  final String? shortName, seasonName, sessionType;
  final Map<String, num> stats;

  num? stat(String key) => stats[key];

  factory SeasonSegment.fromJson(Map<String, dynamic> j) {
    final meta = (j['metadata'] as Map?) ?? const {};
    final attrs = (j['attributes'] as Map?) ?? const {};
    final raw = (j['stats'] as Map?) ?? const {};
    return SeasonSegment(
      shortName: meta['shortName'] as String?,
      seasonName: meta['seasonName'] as String?,
      sessionType: attrs['sessionType'] as String?,
      stats: {
        for (final e in raw.entries)
          if (_statValue(e.value) != null) e.key as String: _statValue(e.value)!,
      },
    );
  }
}

class ModeBoard {
  const ModeBoard({
    required this.id,
    this.wins,
    this.losses,
    this.kills,
    this.deaths,
    this.rank,
    this.rankPoints,
    this.maxRankPoints,
  });
  final String id;
  final int? wins, losses, kills, deaths, rank, rankPoints, maxRankPoints;

  int? get matches => (wins == null || losses == null) ? null : wins! + losses!;
  double? get kd => (kills == null || deaths == null || deaths == 0) ? null : kills! / deaths!;
  double? get winRate => (matches == null || matches == 0) ? null : wins! / matches!;

  factory ModeBoard.fromJson(String id, Map<String, dynamic> fullProfile) {
    final p = (fullProfile['profile'] as Map?) ?? const {};
    return ModeBoard(
      id: id,
      wins: _n(p['wins'])?.toInt(),
      losses: _n(p['losses'])?.toInt(),
      kills: _n(p['kills'])?.toInt(),
      deaths: _n(p['deaths'])?.toInt(),
      rank: _n(p['rank'])?.toInt(),
      rankPoints: _n(p['rank_points'])?.toInt(),
      maxRankPoints: _n(p['max_rank_points'])?.toInt(),
    );
  }
}

class RpPoint {
  const RpPoint(this.at, this.rp, this.rank, {this.colorHex, this.imageUrl});
  final DateTime at;
  final int rp;
  final String? rank, colorHex, imageUrl;
}

class PlayerProfile {
  const PlayerProfile({
    required this.name,
    required this.platform,
    this.level,
    this.avatarUrl,
    this.banned = false,
    this.currentSeason,
    required this.boards,
    required this.segments,
    required this.rpHistory,
    this.serverFetchedAt,
  });

  final String name, platform;
  final int? level;
  final String? avatarUrl;
  final bool banned;
  final int? currentSeason;
  final Map<String, ModeBoard> boards;
  final List<SeasonSegment> segments;
  final List<RpPoint> rpHistory; // newest first, as returned

  /// When the server last pulled this player from Ubisoft. Responses are cached server-side, so this
  /// can be many hours older than the request.
  final DateTime? serverFetchedAt;

  ModeBoard? get ranked => boards['ranked'];
  String? get currentRankName => rpHistory.isEmpty ? null : rpHistory.first.rank;
  RpPoint? get latestRank => rpHistory.isEmpty ? null : rpHistory.first;

  /// The named ranked-season segment, e.g. "Y11S3".
  SeasonSegment? get rankedSeason {
    for (final s in segments) {
      if (s.sessionType == 'ranked' && s.shortName != null) return s;
    }
    return null;
  }

  factory PlayerProfile.fromJson(Map<String, dynamic> j) {
    final player = (j['player'] as Map?) ?? const {};
    final account = (j['account'] as Map?) ?? const {};
    final boards = <String, ModeBoard>{};
    final families = ((j['stats'] as Map?)?['platform_families_full_profiles'] as List?) ?? const [];
    if (families.isNotEmpty) {
      for (final b in (families.first['board_ids_full_profiles'] as List?) ?? const []) {
        final fp = (b['full_profiles'] as List?) ?? const [];
        if (fp.isNotEmpty) {
          boards[b['board_id'] as String] = ModeBoard.fromJson(b['board_id'] as String, Map<String, dynamic>.from(fp.first as Map));
        }
      }
    }
    final seasonData = ((j['seasons'] as Map?)?['data'] as Map?) ?? const {};
    final segments = [
      for (final s in (seasonData['segments'] as List?) ?? const []) SeasonSegment.fromJson(Map<String, dynamic>.from(s as Map)),
    ];
    final history = <RpPoint>[];
    final rows = ((((j['history'] as Map?)?['data'] as Map?)?['history'] as Map?)?['data'] as List?) ?? const [];
    for (final r in rows) {
      if (r is List && r.length == 2 && r[1] is Map) {
        final at = DateTime.tryParse(r[0] as String);
        final v = _n((r[1] as Map)['value']);
        if (at != null && v != null) {
          final meta = ((r[1] as Map)['metadata'] as Map?) ?? const {};
          history.add(RpPoint(at, v.toInt(), meta['rank'] as String?,
              colorHex: meta['color'] as String?, imageUrl: meta['imageUrl'] as String?));
        }
      }
    }
    return PlayerProfile(
      name: (player['nameOnPlatform'] as String?) ?? '',
      platform: (player['platformType'] as String?) ?? 'uplay',
      level: _n(account['level'])?.toInt(),
      avatarUrl: account['profilePicture'] as String?,
      banned: (((j['banned'] as Map?)?['isBanned']) == true),
      currentSeason: _n((seasonData['metadata'] as Map?)?['currentSeason'])?.toInt(),
      boards: boards,
      segments: segments,
      rpHistory: history,
      serverFetchedAt: _newestFetchedAt(j),
    );
  }
}

/// The newest `_cache.fetchedAt` among the response's blocks, if any.
DateTime? _newestFetchedAt(Map<String, dynamic> j) {
  DateTime? best;
  for (final k in const ['stats', 'account', 'banned', 'seasons', 'history']) {
    final f = ((j[k] as Map?)?['_cache'] as Map?)?['fetchedAt'];
    final t = f is String ? DateTime.tryParse(f) : null;
    if (t != null && (best == null || t.isAfter(best))) best = t;
  }
  return best;
}

class OperatorStat {
  const OperatorStat({
    required this.name,
    required this.side,
    this.roundsPlayed,
    this.roundsWon,
    this.roundsLost,
    this.kills,
    this.deaths,
    this.headshots,
    this.firstBloods,
    this.firstDeaths,
    this.clutches,
    this.clutchesLost,
    this.assists,
    this.matchesPlayed,
    this.matchesWon,
    this.matchesLost,
    this.kills2,
    this.kills3,
    this.kills4,
    this.kills5,
    this.teamKills,
    this.timePlayedMs,
  });

  final String name, side; // side: Attacker | Defender
  final int? roundsPlayed, roundsWon, roundsLost, kills, deaths, headshots;
  final int? firstBloods, firstDeaths, clutches, clutchesLost, assists;
  final int? matchesPlayed, matchesWon, matchesLost;
  final int? kills2, kills3, kills4, kills5, teamKills, timePlayedMs;

  bool get isAttacker => side.toLowerCase().startsWith('att');

  double? get kd => (kills == null || deaths == null || deaths == 0) ? null : kills! / deaths!;
  double? get roundWinRate => (roundsWon == null || (roundsPlayed ?? 0) == 0) ? null : roundsWon! / roundsPlayed!;
  double? get matchWinRate {
    final m = matchesPlayed;
    return (matchesWon == null || m == null || m == 0) ? null : matchesWon! / m;
  }

  double? get headshotRate => (headshots == null || (kills ?? 0) == 0) ? null : headshots! / kills!;
  double? get killsPerRound => (kills == null || (roundsPlayed ?? 0) == 0) ? null : kills! / roundsPlayed!;
  double? get deathsPerRound => (deaths == null || (roundsPlayed ?? 0) == 0) ? null : deaths! / roundsPlayed!;
  double? get assistsPerRound => (assists == null || (roundsPlayed ?? 0) == 0) ? null : assists! / roundsPlayed!;
  double? get openingWinRate {
    if (firstBloods == null || firstDeaths == null) return null;
    final n = firstBloods! + firstDeaths!;
    return n == 0 ? null : firstBloods! / n;
  }

  double? get clutchRate {
    if (clutches == null || clutchesLost == null) return null;
    final n = clutches! + clutchesLost!;
    return n == 0 ? null : clutches! / n;
  }

  factory OperatorStat.fromJson(Map<String, dynamic> j) {
    int? i(String k) => _n(j[k])?.toInt();
    return OperatorStat(
      name: (j['operator'] as String?) ?? 'Unknown',
      side: (j['side'] as String?) ?? '',
      roundsPlayed: i('roundsPlayed'),
      roundsWon: i('wins'),
      roundsLost: i('losses'),
      kills: i('kills'),
      deaths: i('deaths'),
      headshots: i('headshots'),
      firstBloods: i('firstBloods'),
      firstDeaths: i('firstDeaths'),
      clutches: i('clutches'),
      clutchesLost: i('clutchesLost'),
      assists: i('assists'),
      matchesPlayed: i('matchesPlayed'),
      matchesWon: i('matchesWon'),
      matchesLost: i('matchesLost'),
      kills2: i('kills2K'),
      kills3: i('kills3K'),
      kills4: i('kills4K'),
      kills5: i('kills5K'),
      teamKills: i('teamKills'),
      timePlayedMs: i('timePlayedMs'),
    );
  }

  static List<OperatorStat> listFromResponse(Map<String, dynamic> j) {
    final ops = (((j['operators'] as Map?)?['operators']) as List?) ?? const [];
    return [for (final o in ops) OperatorStat.fromJson(Map<String, dynamic>.from(o as Map))];
  }
}

/// Static operator info (roles, icon). Cached for days; fetched once.
class GameOperator {
  const GameOperator({required this.name, required this.side, required this.roles, this.season, this.iconUrl});
  final String name, side;
  final List<String> roles;
  final String? season, iconUrl;

  String get key => name.toLowerCase();

  factory GameOperator.fromJson(Map<String, dynamic> j) {
    final icon = j['icon_url'] as String?;
    return GameOperator(
      name: (j['name'] as String?) ?? '',
      side: ((j['side'] as String?) ?? '').toLowerCase().startsWith('att') ? 'Attacker' : 'Defender',
      roles: [for (final r in (j['roles'] as List?) ?? const []) normalizeRole(r.toString())],
      season: j['season_introduced'] as String?,
      // The listed host is unreachable from many networks; the same assets are served from arenyze.
      iconUrl: icon?.replaceFirst('r6data.eu', 'r6.arenyze.com'),
    );
  }

  static List<GameOperator> listFromResponse(Object? j) => [
        for (final o in (j is List ? j : const [])) GameOperator.fromJson(Map<String, dynamic>.from(o as Map)),
      ];
}

/// Roles come in mixed case and spellings ("Front line", "CROWD CONTROL").
String normalizeRole(String r) {
  final t = r.trim().toLowerCase().replaceAll('-', ' ');
  const aliases = {
    'intel': 'Intel Gatherer',
    'trapper': 'Trap',
    'anti gadget': 'Anti Gadget',
    'breach': 'Hard Breach',
    'attacker': 'Support',
    'defender': 'Support',
  };
  final m = aliases[t] ?? t;
  return m.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
}
