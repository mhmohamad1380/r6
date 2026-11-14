// A highlight clip on the replay server: the moment the PC found in a replay, recorded and uploaded as a video.

class HighlightKill {
  const HighlightKill({required this.t, required this.victim, this.victimOperator, this.headshot = false, this.postPlant = false});
  final double t; // seconds since the round timer started
  final String victim;
  final String? victimOperator;
  final bool headshot, postPlant;

  factory HighlightKill.fromJson(Map<String, dynamic> j) => HighlightKill(
        t: (j['t'] as num?)?.toDouble() ?? 0,
        victim: j['victim'] as String? ?? '',
        victimOperator: (j['victim_operator'] as String?)?.isEmpty == true ? null : j['victim_operator'] as String?,
        headshot: j['headshot'] == true,
        postPlant: j['post_plant'] == true,
      );
  Map<String, dynamic> toJson() => {'t': t, 'victim': victim, 'victim_operator': victimOperator, 'headshot': headshot, 'post_plant': postPlant};
}

class Highlight {
  const Highlight({
    required this.id,
    required this.matchId,
    required this.round,
    required this.type,
    required this.score,
    required this.kills,
    this.tags = const [],
    this.clutchVs = 0,
    this.won = false,
    this.side = '',
    this.operator = '',
    this.map = '',
    this.mode = '',
    this.playedAt,
    this.title,
    this.visibility = 'private',
    this.duration,
    this.size = 0,
    this.videoUrl = '',
    this.thumbnailUrl,
    this.approx = false,
    this.seq = 0,
  });

  final String id, matchId, type, side, operator, map, mode, visibility, videoUrl;
  final int round, score, clutchVs, size, seq;
  final List<String> tags;
  final List<HighlightKill> kills;
  final bool won, approx;
  final DateTime? playedAt;
  final String? title, thumbnailUrl;
  final double? duration;

  bool get shared => visibility == 'unlisted';

  /// What people call it: "Ace", "Clutch 1v3", "3K", "Entry", "Headshot", "Kill".
  String get label {
    final n = kills.length;
    if (type == 'ace') return 'Ace';
    if (type == 'clutch') return 'Clutch 1v$clutchVs${n >= 2 ? ' · ${n}K' : ''}';
    if (n >= 2) return '${n}K';
    return switch (type) { 'entry' => 'Entry kill', 'headshot' => 'Headshot', _ => 'Kill' };
  }

  String get displayTitle => (title != null && title!.trim().isNotEmpty) ? title! : '$label on $map';

  factory Highlight.fromJson(Map<String, dynamic> j) {
    final clip = (j['clip'] as Map?) ?? const {};
    return Highlight(
      id: j['id'] as String,
      matchId: j['match_id'] as String? ?? '',
      round: (j['round'] as num?)?.toInt() ?? 0,
      type: j['type'] as String? ?? 'kill',
      tags: [for (final t in (j['tags'] as List? ?? const [])) t as String],
      score: (j['score'] as num?)?.toInt() ?? 0,
      clutchVs: (j['clutch_vs'] as num?)?.toInt() ?? 0,
      won: j['won'] == true,
      side: j['side'] as String? ?? '',
      operator: j['operator'] as String? ?? '',
      map: j['map'] as String? ?? '',
      mode: j['mode'] as String? ?? '',
      playedAt: DateTime.tryParse(j['played_at'] as String? ?? ''),
      kills: [for (final k in (j['kills'] as List? ?? const [])) HighlightKill.fromJson(Map<String, dynamic>.from(k as Map))],
      title: j['title'] as String?,
      visibility: j['visibility'] as String? ?? 'private',
      duration: (j['duration'] as num?)?.toDouble(),
      size: (j['size'] as num?)?.toInt() ?? 0,
      videoUrl: j['videoUrl'] as String? ?? '/v1/highlights/${j['id']}/video',
      thumbnailUrl: j['thumbnailUrl'] as String?,
      approx: clip['approx'] == true,
      seq: (j['seq'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'match_id': matchId,
        'round': round,
        'type': type,
        'tags': tags,
        'score': score,
        'clutch_vs': clutchVs,
        'won': won,
        'side': side,
        'operator': operator,
        'map': map,
        'mode': mode,
        'played_at': playedAt?.toUtc().toIso8601String(),
        'kills': [for (final k in kills) k.toJson()],
        'title': title,
        'visibility': visibility,
        'duration': duration,
        'size': size,
        'videoUrl': videoUrl,
        'thumbnailUrl': thumbnailUrl,
        'clip': {'approx': approx},
        'seq': seq,
      };

  Highlight copyWith({String? title, bool clearTitle = false, String? visibility}) => Highlight.fromJson({
        ...toJson(),
        'title': clearTitle ? null : (title ?? this.title),
        'visibility': visibility ?? this.visibility,
      });
}
