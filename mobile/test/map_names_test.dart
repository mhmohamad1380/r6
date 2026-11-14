import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r6_coach/data/map_names.dart';
import 'package:r6_coach/data/replay.dart';

void main() {
  test('numeric ids and code names become the names players know', () {
    expect(mapDisplayName('Map(407987100456)'), 'Border');
    expect(mapDisplayName('Map(413779563590)'), 'Bank');
    expect(mapDisplayName('Map(407193663917)'), 'Clubhouse');
    expect(mapDisplayName('Map(413845419788)'), 'Kafe Dostoyevsky');
    expect(mapDisplayName('Map(418119057546)'), 'Nighthaven Labs');
    expect(mapDisplayName('Map(418126004176)'), 'Consulate');
    expect(mapDisplayName('Map(417890697769)'), 'Lair');
    expect(mapDisplayName('407987100456'), 'Border');
    expect(mapDisplayName('BorderY10'), 'Border');
    expect(mapDisplayName('ClubHouseY10'), 'Clubhouse');
    expect(mapDisplayName('NighthavenLabs'), 'Nighthaven Labs');
    expect(mapDisplayName('Bank'), 'Bank');
    expect(mapDisplayName('Consulate'), 'Consulate');
  });

  test('a map newer than the table is labelled unknown, never guessed', () {
    expect(mapDisplayName('Map(999999991472)'), 'Unknown map 1472');
    expect(mapDisplayName('Map(12345678)'), 'Unknown map 5678');
    expect(mapDisplayName('SomeNewMapY11'), 'Some New Map');
  });

  test('the seven ids identified from real replays by their bombsites and spawns', () {
    expect(mapDisplayName('Map(398899676157)'), 'Fortress'); // Hammam, Commander's Office
    expect(mapDisplayName('Map(409325881472)'), 'Villa'); // Aviator Room, Trophy Room
    expect(mapDisplayName('Map(430788891316)'), 'Theme Park'); // Bumper Cars, Teacups
    expect(mapDisplayName('Map(434715462383)'), 'Oregon'); // Kids' Dorms, Junkyard
    expect(mapDisplayName('Map(436375283234)'), 'Coastline'); // Hookah Lounge, Pool Side
    expect(mapDisplayName('Map(441408792952)'), 'Kanal'); // Kayaks, Floating Dock
    expect(mapDisplayName('Map(441825219764)'), 'Outback'); // Fuel Pumps, Party Room
  });

  test('the seven ids identified from real replays by their bombsites and spawns', () {
    expect(mapDisplayName('Map(398899676157)'), 'Fortress'); // Hammam, Commander's Office
    expect(mapDisplayName('Map(409325881472)'), 'Villa'); // Aviator Room, Trophy Room
    expect(mapDisplayName('Map(430788891316)'), 'Theme Park'); // Bumper Cars, Teacups
    expect(mapDisplayName('Map(434715462383)'), 'Oregon'); // Kids' Dorms, Junkyard
    expect(mapDisplayName('Map(436375283234)'), 'Coastline'); // Hookah Lounge, Pool Side
    expect(mapDisplayName('Map(441408792952)'), 'Kanal'); // Kayaks, Floating Dock
    expect(mapDisplayName('Map(441825219764)'), 'Outback'); // Fuel Pumps, Party Room
  });

  test('old and new spellings of one map are one map', () {
    expect({'Border', mapDisplayName('BorderY10'), mapDisplayName('Map(407987100456)'), mapDisplayName('Map(305979357167)')}.length, 1);
  });

  test('a saved replay and a freshly parsed one both show the name', () {
    final saved = jsonDecode(File('test/fixtures/replays/quick_1.rec.json').readAsStringSync()) as Map<String, dynamic>;
    final withMap = saved['header'] is Map ? {...saved, 'header': {...(saved['header'] as Map<String, dynamic>), 'map': 'Map(407987100456)'}} : {...saved, 'map': 'Map(407987100456)'};
    final fresh = parseReplayJson(jsonEncode(withMap)).rounds;
    expect(fresh, isNotEmpty);
    expect(fresh.every((r) => r.map == 'Border'), isTrue);
    final back = ReplayRound.fromJson({...fresh.first.toJson(), 'map': 'Map(413845419788)'});
    expect(back.map, 'Kafe Dostoyevsky', reason: 'rounds saved on the phone before this fix are repaired when loaded');
  });
}
