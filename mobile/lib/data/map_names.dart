// Replay files name a map by a numeric id or a code such as BorderY10. This turns either into the name players know.

/// Numeric map ids from the r6-dissect source (dissect/map_string.go).
const _ids = {
  '355496559878': 'Bank',
  '413779563590': 'Bank',
  '2697268122': 'Bartlett University',
  '305979357167': 'Border',
  '407987100456': 'Border',
  '259816839773': 'Chalet',
  '407558616688': 'Chalet',
  '837214085': 'Clubhouse',
  '407193663917': 'Clubhouse',
  '42090092951': 'Coastline',
  '2609221242': 'Consulate',
  '379218689149': 'Consulate',
  '418126004176': 'Consulate',
  '365284490964': 'Emerald Plains',
  '329867321446': 'Favela',
  '126196841359': 'Fortress',
  '127951053400': 'Hereford Base',
  '237873412352': 'House',
  '1378191338': 'Kafe Dostoyevsky',
  '413845419788': 'Kafe Dostoyevsky',
  '1460220617': 'Kanal',
  '388073319671': 'Lair',
  '417890697769': 'Lair',
  '378595635123': 'Nighthaven Labs',
  '418119057546': 'Nighthaven Labs',
  '231702797556': 'Oregon',
  '362605108559': 'Outback',
  '2609218856': 'Presidential Plane',
  '276279025182': 'Skyscraper',
  '405306299908': 'Stadium',
  '270063334510': 'Stadium Bravo',
  '199824623654': 'Theme Park',
  '53627213396': 'Tower',
  '88107330328': 'Villa',
  '1767965020': 'Yacht',
  '398899676157': 'Fortress', // identified from its bombsite and spawn names in real replays
  '409325881472': 'Villa', // identified from its bombsite and spawn names in real replays
  '430788891316': 'Theme Park', // identified from its bombsite and spawn names in real replays
  '434715462383': 'Oregon', // identified from its bombsite and spawn names in real replays
  '436375283234': 'Coastline', // identified from its bombsite and spawn names in real replays
  '441408792952': 'Kanal', // identified from its bombsite and spawn names in real replays
  '441825219764': 'Outback', // identified from its bombsite and spawn names in real replays
};

String _key(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Names as the app shows them elsewhere, so a replay and a stats row for the same map line up.
const _display = [
  'Bank', 'Border', 'Calypso Casino', 'Chalet', 'Close Quarter', 'Clubhouse', 'Coastline', 'Consulate', 'District', 'Emerald Plains', 'Favela', 'Fortress',
  'Hereford Base', 'House', 'Kafe Dostoyevsky', 'Kanal', 'Lair', 'Nighthaven Labs', 'Oregon', 'Outback', 'Presidential Plane', 'Skyscraper',
  'Stadium Alpha', 'Stadium Bravo', 'Theme Park', 'Tower', 'Villa', 'Yacht',
];
final _byKey = {for (final n in _display) _key(n): n};

/// "Map(407987100456)" -> Border, "BorderY10" -> Border, "ClubHouseY10" -> Clubhouse.
/// An id that is newer than this table is shown as "Unknown map" with the end of its id, never as a guess.
String mapDisplayName(String raw) {
  final s = raw.trim();
  final id = RegExp(r'^Map\((\d+)\)$').firstMatch(s)?.group(1) ?? (RegExp(r'^\d{6,}$').hasMatch(s) ? s : null);
  if (id != null) return _ids[id] ?? 'Unknown map ${id.length > 4 ? id.substring(id.length - 4) : id}';
  final base = s.replaceAll(RegExp(r'(Y\d+|2020)$'), '');
  final hit = _byKey[_key(base)];
  if (hit != null) return hit;
  // A code name we do not list: split the camel case so it at least reads as words.
  return base.replaceAllMapped(RegExp(r'(?<=[a-z0-9])(?=[A-Z])'), (_) => ' ');
}
