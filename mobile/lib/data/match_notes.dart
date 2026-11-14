import 'dart:convert';

/// Context the API cannot provide, entered by the player for a logged match.
class MatchNote {
  const MatchNote({this.map, this.party, this.feeling, this.text});
  final String? map;
  final String? party; // solo | duo | trio | squad
  final int? feeling; // 1 (tilted) .. 5 (locked in)
  final String? text;

  bool get isEmpty => map == null && party == null && feeling == null && (text == null || text!.isEmpty);

  MatchNote copyWith({Object? map = _keep, Object? party = _keep, Object? feeling = _keep, Object? text = _keep}) => MatchNote(
        map: identical(map, _keep) ? this.map : map as String?,
        party: identical(party, _keep) ? this.party : party as String?,
        feeling: identical(feeling, _keep) ? this.feeling : feeling as int?,
        text: identical(text, _keep) ? this.text : text as String?,
      );

  Map<String, dynamic> toJson() => {'m': map, 'p': party, 'f': feeling, 't': text};
  factory MatchNote.fromJson(Map<String, dynamic> j) => MatchNote(map: j['m'] as String?, party: j['p'] as String?, feeling: (j['f'] as num?)?.toInt(), text: j['t'] as String?);
}

const _keep = Object();

const partySizes = ['solo', 'duo', 'trio', 'squad'];

String partyLabel(String p) => switch (p) { 'solo' => 'Solo', 'duo' => 'Duo', 'trio' => 'Trio', 'squad' => 'Squad (4-5)', _ => p };

class GameMap {
  const GameMap(this.name, this.location, this.ranked);
  final String name, location;
  final bool ranked;
}

List<GameMap> parseMaps(String json) => [
      for (final m in (jsonDecode(json) as Map<String, dynamic>)['maps'] as List) GameMap(m['n'] as String, (m['loc'] as String?) ?? '', m['r'] == true),
    ];
