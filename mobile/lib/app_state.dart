import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics/goals.dart';
import 'analytics/insights.dart';
import 'analytics/identity.dart';
import 'analytics/rp.dart';
import 'data/arenyze_client.dart';
import 'data/counters.dart';
import 'data/match_notes.dart';
import 'data/models.dart';
import 'data/ranks.dart';
import 'analytics/replay_patterns.dart';
import 'data/highlight.dart';
import 'data/replay.dart';
import 'data/scope.dart';
import 'data/snapshots.dart';

class ReplayQuota {
  const ReplayQuota({required this.limit, required this.used, required this.remaining, required this.at});
  final int limit, used, remaining;
  final DateTime at;
}

class ReplayImport {
  const ReplayImport({this.added = 0, this.duplicates = 0, this.errors = 0, this.message});
  final int added, duplicates, errors;
  final String? message; // set when nothing could be imported
  bool get ok => message == null && added + duplicates > 0;
}

class ReplaySync {
  const ReplaySync({this.added = 0, this.duplicates = 0, this.failedOnServer = 0, this.unreadable = 0, this.freedBytes = 0, this.pendingAcks = 0, this.message, this.skipped = false});
  final int added, duplicates, failedOnServer, unreadable, freedBytes, pendingAcks;
  final String? message; // set when the sync could not run or stopped early
  final bool skipped; // an automatic sync that was throttled
  int get received => added + duplicates;

  String get summary {
    if (message != null) return message!;
    if (received == 0 && failedOnServer == 0 && unreadable == 0) return 'Nothing new on the server.';
    final parts = <String>[
      if (received > 0) 'Got $received round${received == 1 ? '' : 's'}${duplicates > 0 ? ' ($duplicates already saved)' : ''}',
      if (freedBytes > 0) 'freed ${(freedBytes / 1048576).toStringAsFixed(1)} MB on the server',
      if (failedOnServer > 0) '$failedOnServer file${failedOnServer == 1 ? '' : 's'} the server could not read',
      if (unreadable > 0) '$unreadable unreadable',
      if (pendingAcks > 0) '$pendingAcks to delete next time',
    ];
    return '${parts.join(', ')}.';
  }
}

class ServerCheck {
  const ServerCheck({required this.ok, required this.message});
  final bool ok;
  final String message;
}

class OtherPlayer {
  const OtherPlayer(this.profile, this.operators, this.fetchedAt);
  final PlayerProfile profile;
  final List<OperatorStat> operators;
  final DateTime fetchedAt;
}

/// Holds settings, cached API data, snapshots and goals. The key is stored on-device only.
///
/// Request budget (free plan = 2,000 calls/month): a refresh costs 2 calls (profile + operators);
/// each other mode or period costs 1 call the first time it is opened (Unranked is derived and free).
/// Operator roles/icons are bundled, so they cost nothing.
class AppState extends ChangeNotifier {
  AppState(this._prefs, {this.httpClient, this.game = const [], this.counters = CounterBook.empty, this.ranks = RankLadder.empty, this.maps = const []}) {
    apiKey = _prefs.getString('apiKey') ?? '';
    username = _prefs.getString('username') ?? '';
    _onboarded = _prefs.getBool('onboarded') ?? false;
    platform = _prefs.getString('platform') ?? 'uplay';
    replayServerUrl = _prefs.getString('rs.url') ?? '';
    replayServerToken = _prefs.getString('rs.token') ?? '';
    replayCursor = _prefs.getInt('rs.cursor') ?? 0;
    lastReplaySync = DateTime.tryParse(_prefs.getString('rs.last') ?? '');
    hlCursor = _prefs.getInt('hl.cursor') ?? 0;
    try {
      highlights = [for (final x in jsonDecode(_prefs.getString('highlights') ?? '[]') as List) Highlight.fromJson(Map<String, dynamic>.from(x as Map))];
    } on Object {
      highlights = [];
      hlCursor = 0;
    }
    final pop = _prefs.getString('rs.population');
    if (pop != null) {
      try {
        population = Population.fromJson(jsonDecode(pop) as Map<String, dynamic>);
      } on Object {
        population = null;
      }
    }
    // Version 2 of the saved rounds keeps spawns, overtime and the season. Rounds saved before that are fetched again
    // once, so the new patterns have them (the server still holds every round it ever parsed).
    if ((_prefs.getInt('rs.schema') ?? 1) < replaySchema && replayServerUrl.isNotEmpty) {
      replayCursor = 0;
      _refetching = true;
    }
    pendingAcks = [for (final x in (_prefs.getStringList('rs.acks') ?? const <String>[])) int.parse(x)];
    _loadCache();
  }

  static const autoRefreshAfter = Duration(minutes: 30);
  static const minRefreshGap = Duration(seconds: 60);
  static const monthlyQuota = 2000;
  static const maxSnapshots = 150;

  final SharedPreferences _prefs;
  final http.Client? httpClient;
  final List<GameOperator> game;
  final CounterBook counters;
  final RankLadder ranks;
  final List<GameMap> maps;

  late String apiKey, username, platform;
  PlayerProfile? profile;
  List<OperatorStat> operators = const [];
  List<Snapshot> snapshots = [];
  List<Goal> goals = [];
  String replayServerUrl = '', replayServerToken = '';
  int replayCursor = 0;
  DateTime? lastReplaySync;
  bool replaySyncing = false;
  List<int> pendingAcks = []; // rounds saved here whose .rec the server has not been told to delete yet
  List<ReplayRound> replays = []; // imported rounds, newest match first by timestamp
  Population? population; // how the other players in the server's replays play (/v1/population)
  List<Highlight> highlights = []; // clips on the server, newest upload first (cached, so the list shows offline)
  int hlCursor = 0;
  int? clipsUsedBytes, clipsQuotaBytes;
  static const replaySchema = 2;
  bool _refetching = false; // one full download after an update, replacing the saved copies
  ReplayQuota? replayQuota;
  bool replayBusy = false;
  List<RpPoint> ledger = []; // every RP reading seen across refreshes, newest first
  Map<String, MatchNote> notes = {}; // keyed by the match's start-snapshot time, which never changes
  DateTime? fetchedAt;
  bool loading = false;
  String? error, notice;
  ModeFilter mode = ModeFilter.all;
  Period period = Period.lifetime;
  final Map<String, List<OperatorStat>> _sets = {}; // 'mode|period' -> operator stats
  final Map<String, DateTime> _setAt = {};

  bool get configured => apiKey.isNotEmpty && username.isNotEmpty;

  /// The app is usable from replays alone. A name is all it needs to find you in them, and the replays can say it themselves.
  bool get hasAccount => username.isNotEmpty || detected != null;

  String? _detectSig;
  DetectedPlayer? _detected;

  /// Who the replays say you are (see [detectPlayer]). Recomputed only when the replays change.
  DetectedPlayer? get detected {
    final sig = replays.isEmpty ? '' : '${replays.length}|${replays.first.key}|${replays.last.key}';
    if (_detectSig != sig) {
      _detected = detectPlayer(replays);
      _detectSig = sig;
    }
    return _detected;
  }

  /// The name the analysis is about: the one you set if it is in your replays, else who the replays say you are.
  String get playerName {
    final set = profile?.name ?? username;
    if (set.isNotEmpty && (replays.isEmpty || appearsIn(replays, set))) return set;
    return detected?.name ?? set;
  }

  /// True when [playerName] came from the replays rather than from a name you entered.
  bool get nameFromReplays => detected != null && playerName == detected!.name && playerName != (profile?.name ?? username);

  /// Keeps the name the replays gave, so it survives and shows in Profile. Only when none is set.
  Future<void> adoptDetectedName() async {
    final d = detected;
    if (username.isNotEmpty || d == null) return;
    username = d.name;
    await _prefs.setString('username', username);
    notifyListeners();
  }

  /// The optional Arenyze key adds lifetime rank and stats; nothing else depends on it.
  bool get hasStatsKey => apiKey.isNotEmpty;

  bool _onboarded = false;

  /// Someone who already has a name or replays when the app starts has been through setup; they never see the guide.
  /// Fixed at the first read, so typing a name during the guide does not end it halfway.
  late final bool _returningUser = username.isNotEmpty || replays.isNotEmpty;
  bool get needsOnboarding => !_onboarded && !_returningUser;

  Future<void> finishOnboarding() async {
    _onboarded = true;
    await _prefs.setBool('onboarded', true);
    notifyListeners();
  }
  bool get stale => fetchedAt == null || DateTime.now().difference(fetchedAt!) > autoRefreshAfter;
  /// Season id such as "Y11S3", taken from the profile. Null until the profile has loaded.
  String? get seasonId => profile?.rankedSeason?.shortName;

  List<OperatorStat> get activeOps => opsFor(mode, period);

  /// True when everything needed for the current filter is in memory.
  bool hasSet(String key) => _sets.containsKey(key);

  bool get activeReady => keysNeeded(mode, period).every(_sets.containsKey);

  List<OperatorStat> opsFor(ModeFilter m, Period p) {
    final keys = keysNeeded(m, p);
    if (!keys.every(_sets.containsKey)) return const [];
    if (m == ModeFilter.unranked) return subtractOps(_sets[keys[0]]!, _sets[keys[1]]!);
    return _sets[keys[0]]!;
  }

  String get filterLabel => '${mode.label}${period == Period.season ? ' · ${seasonId ?? 'season'}' : ''}';

  /// RP history grows with every refresh: the API only returns the latest 16 readings.
  List<RpPoint> get rpHistory => ledger.length >= (profile?.rpHistory.length ?? 0) ? ledger : (profile?.rpHistory ?? const []);
  RpAnalysis get rp => RpAnalysis.from(rpHistory);
  List<MatchRecord> get matchLog => buildMatchLog(snapshots);
  Map<String, GameOperator> get gameByName => {for (final g in game) g.key: g};

  String get _month {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}';
  }

  /// Requests this device has sent this calendar month (local count; the server's own meter is authoritative).
  int get callsThisMonth => _prefs.getString('calls.month') == _month ? (_prefs.getInt('calls.count') ?? 0) : 0;

  void _countCall() {
    final c = callsThisMonth + 1;
    _prefs.setString('calls.month', _month);
    _prefs.setInt('calls.count', c);
  }

  void _loadCache() {
    try {
      final p = _prefs.getString('cache.profile');
      final o = _prefs.getString('cache.operators');
      final t = _prefs.getString('cache.at');
      if (p != null && o != null) {
        profile = PlayerProfile.fromJson(jsonDecode(p) as Map<String, dynamic>);
        operators = OperatorStat.listFromResponse(jsonDecode(o) as Map<String, dynamic>);
        fetchedAt = t == null ? null : DateTime.tryParse(t);
      }
      if (operators.isNotEmpty) {
        _sets[scopeKey('all', Period.lifetime)] = operators;
        if (fetchedAt != null) _setAt[scopeKey('all', Period.lifetime)] = fetchedAt!;
      }
      for (final k in _prefs.getKeys().where((k) => k.startsWith('cache.set.') && !k.startsWith('cache.setat.'))) {
        final key = k.substring('cache.set.'.length);
        _sets[key] = OperatorStat.listFromResponse(jsonDecode(_prefs.getString(k)!) as Map<String, dynamic>);
        final at = DateTime.tryParse(_prefs.getString('cache.setat.$key') ?? '');
        if (at != null) _setAt[key] = at;
      }
      mode = ModeFilter.values.firstWhere((m) => m.name == _prefs.getString('filter.mode'), orElse: () => ModeFilter.all);
      period = Period.values.firstWhere((p) => p.name == _prefs.getString('filter.period'), orElse: () => Period.lifetime);
      final s = _prefs.getString('snapshots');
      if (s != null) {
        snapshots = [for (final x in jsonDecode(s) as List) Snapshot.fromJson(Map<String, dynamic>.from(x as Map))];
      }
      final rp = _prefs.getString('replays');
      if (rp != null) replays = [for (final x in jsonDecode(rp) as List) ReplayRound.fromJson(Map<String, dynamic>.from(x as Map))];
      if (username.isEmpty && replays.isNotEmpty) unawaited(adoptDetectedName()); // the replays say who you are: keep it
      final rq = _prefs.getString('replay.quota');
      if (rq != null) {
        final q = jsonDecode(rq) as Map<String, dynamic>;
        replayQuota = ReplayQuota(limit: (q['l'] as num).toInt(), used: (q['u'] as num).toInt(), remaining: (q['r'] as num).toInt(), at: DateTime.parse(q['at'] as String));
      }
      final l = _prefs.getString('ledger');
      if (l != null) {
        ledger = [
          for (final x in jsonDecode(l) as List)
            RpPoint(DateTime.parse((x as List)[0] as String), (x[1] as num).toInt(), x.length > 2 ? x[2] as String? : null),
        ];
      }
      final n = _prefs.getString('notes');
      if (n != null) {
        notes = {for (final e in (jsonDecode(n) as Map<String, dynamic>).entries) e.key: MatchNote.fromJson(Map<String, dynamic>.from(e.value as Map))};
      }
      final g = _prefs.getString('goals');
      if (g != null) {
        goals = [for (final x in jsonDecode(g) as List) Goal.fromJson(Map<String, dynamic>.from(x as Map))];
      }
    } on Object {
      profile = null; // corrupt cache: ignore and refetch
    }
  }

  Future<void> saveSettings({required String key, required String name, required String plat}) async {
    final changedPlayer = name.trim() != username || plat != platform;
    apiKey = key.trim();
    username = name.trim();
    platform = plat;
    await _prefs.setString('apiKey', apiKey);
    await _prefs.setString('username', username);
    await _prefs.setString('platform', platform);
    if (changedPlayer) {
      profile = null;
      operators = const [];
      snapshots = [];
      goals = [];
      fetchedAt = null;
      _sets.clear();
      _setAt.clear();
      for (final k in _prefs.getKeys().where((k) => k.startsWith('cache.set')).toList()) {
        await _prefs.remove(k);
      }
      notes = {};
      ledger = [];
      // Replays stay: each file holds all ten players, so they are not tied to one account.
      for (final k in ['cache.profile', 'cache.operators', 'snapshots', 'goals', 'notes', 'ledger']) {
        await _prefs.remove(k);
      }
    }
    notifyListeners();
    await refresh(force: true, bypassGap: true);
  }

  /// Change the mode and/or period. Missing data costs 1 request per set; Unranked needs Ranked
  /// plus All, and is otherwise free.
  Future<void> setFilter({ModeFilter? mode, Period? period}) async {
    if (period == Period.season && seasonId == null) return;
    if (mode != null) this.mode = mode;
    if (period != null) this.period = period;
    await _prefs.setString('filter.mode', this.mode.name);
    await _prefs.setString('filter.period', this.period.name);
    notifyListeners();
    await ensureActive();
  }

  /// Fetch whatever the current filter needs and does not have yet (or has older than 30 minutes).
  Future<void> ensureActive({bool forceStale = false}) async {
    if (!configured || loading || profile == null) return;
    final missing = [
      for (final k in keysNeeded(mode, period))
        if (!_sets.containsKey(k) || (forceStale && _isStale(k))) k,
    ];
    if (missing.isEmpty) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final c = _client();
      for (final k in missing) {
        await _fetchSet(c, k);
      }
    } on ArenyzeException catch (e) {
      error = e.message;
    } on Object catch (e) {
      error = 'Could not read the response (${e.runtimeType}).';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  bool _isStale(String key) {
    final at = _setAt[key];
    return at == null || DateTime.now().difference(at) > autoRefreshAfter;
  }

  Future<void> _fetchSet(ArenyzeClient c, String key) async {
    final parts = key.split('|');
    final season = parts[1] == Period.season.name ? seasonId : null;
    final raw = await c.operators(username, platform, modes: parts[0], season: season ?? 'all');
    _sets[key] = OperatorStat.listFromResponse(raw);
    _setAt[key] = DateTime.now();
    if (key == scopeKey('all', Period.lifetime)) operators = _sets[key]!;
    await _prefs.setString('cache.set.$key', jsonEncode(raw));
    await _prefs.setString('cache.setat.$key', _setAt[key]!.toIso8601String());
  }

  RateLimits? rate; // the server's own counters from the latest response
  DateTime? rateAt;

  void _onRate(RateLimits r) {
    rate = r;
    rateAt = DateTime.now();
  }

  ArenyzeClient _client() => ArenyzeClient(apiKey, client: httpClient, onCall: _countCall, onRateLimits: _onRate);

  /// How old the server's copy of this player is. Null if the response gave no timestamp.
  Duration? get serverAge => profile?.serverFetchedAt == null ? null : DateTime.now().difference(profile!.serverFetchedAt!);

  /// True when the server's copy is old enough that recent games are probably missing.
  bool get serverStale => (serverAge ?? Duration.zero) > const Duration(minutes: 45);

  /// Profile + operators (2 calls). Automatic calls only run when the cache is stale.
  Future<void> refresh({bool force = false, bool bypassGap = false}) async {
    if (!configured || loading) return;
    if (!force && !stale) return;
    if (force && !bypassGap && fetchedAt != null && DateTime.now().difference(fetchedAt!) < minRefreshGap) {
      notice = 'Already up to date. You can refresh again in a minute.';
      notifyListeners();
      return;
    }
    loading = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      final c = _client();
      final res = await Future.wait([c.profile(username, platform), c.operators(username, platform)]);
      profile = PlayerProfile.fromJson(res[0]);
      operators = OperatorStat.listFromResponse(res[1]);
      _sets[scopeKey('all', Period.lifetime)] = operators;
      fetchedAt = DateTime.now();
      _setAt[scopeKey('all', Period.lifetime)] = fetchedAt!;
      _record(Snapshot.from(profile!, operators, at: fetchedAt));
      _mergeLedger(profile!.rpHistory);
      await _prefs.setString('ledger', _ledgerJson());
      await _prefs.setString('cache.profile', jsonEncode(res[0]));
      await _prefs.setString('cache.operators', jsonEncode(res[1]));
      await _prefs.setString('cache.at', fetchedAt!.toIso8601String());
      await _prefs.setString('snapshots', jsonEncode([for (final s in snapshots) s.toJson()]));
      // Other modes and the season view are separate requests; refresh only the ones in use.
      for (final k in keysNeeded(mode, period)) {
        if (k != scopeKey('all', Period.lifetime) && (!_sets.containsKey(k) || force)) await _fetchSet(c, k);
      }
    } on ArenyzeException catch (e) {
      error = e.message;
    } on Object catch (e) {
      error = 'Could not read the response (${e.runtimeType}).';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Keep a snapshot only when counters moved. If nothing changed, slide the last one's time
  /// forward: we now know nothing was played until now, which tightens the next diff window.
  void _record(Snapshot s) {
    if (snapshots.isNotEmpty && snapshots.last.sameCounters(s)) {
      final l = snapshots.last;
      snapshots[snapshots.length - 1] = Snapshot(at: s.at, modes: l.modes, ops: l.ops, rank: s.rank, rankColor: s.rankColor);
    } else {
      snapshots.add(s);
      if (snapshots.length > maxSnapshots) snapshots = snapshots.sublist(snapshots.length - maxSnapshots);
    }
  }

  /// The server's own meter (1 call). Only used when the user asks for it.
  Future<Map<String, dynamic>> serverUsage() => _client().usage();

  Future<void> clearHistory() async {
    snapshots = snapshots.isEmpty ? [] : [snapshots.last];
    goals = [];
    notes = {};
    await _prefs.setString('snapshots', jsonEncode([for (final s in snapshots) s.toJson()]));
    await _prefs.remove('goals');
    await _prefs.remove('notes');
    notifyListeners();
  }

  // ----- Compare with another player (2 calls, only when the user asks) -----
  OtherPlayer? other;
  bool otherLoading = false;
  String? otherError;

  Future<void> compareWith(String name, String plat) async {
    final n = name.trim();
    if (n.isEmpty || !configured || otherLoading) return;
    otherLoading = true;
    otherError = null;
    notifyListeners();
    try {
      final c = _client();
      final res = await Future.wait([c.profile(n, plat), c.operators(n, plat)]);
      other = OtherPlayer(PlayerProfile.fromJson(res[0]), OperatorStat.listFromResponse(res[1]), DateTime.now());
    } on ArenyzeException catch (e) {
      otherError = e.message;
    } on Object catch (e) {
      otherError = 'Could not read the response (${e.runtimeType}).';
    } finally {
      otherLoading = false;
      notifyListeners();
    }
  }

  void clearOther() {
    other = null;
    otherError = null;
    notifyListeners();
  }

  static const maxLedger = 800;
  static const maxReplayRounds = 240;
  static const maxReplayUploadFiles = 20;

  Future<void> _saveReplays() => _prefs.setString('replays', jsonEncode([for (final r in replays) r.toJson()]));

  ReplayImport _addReplays(List<ReplayRound> rounds, {int errors = 0, bool replace = false}) {
    var added = 0, dup = 0;
    final have = {for (final r in replays) r.key};
    for (final r in rounds) {
      if (have.add(r.key)) {
        replays.add(r);
        added++;
      } else {
        // The same round again: keep the one with real kill times.
        final i = replays.indexWhere((x) => x.key == r.key);
        if (i >= 0 && ((!replays[i].timed && r.timed) || (replace && (r.timed || !replays[i].timed)))) replays[i] = r;
        dup++;
      }
    }
    replays.sort((a, b) => (b.at ?? DateTime(2000)).compareTo(a.at ?? DateTime(2000)));
    if (replays.length > maxReplayRounds) replays = replays.sublist(0, maxReplayRounds);
    if (username.isEmpty) unawaited(adoptDetectedName()); // the replays say who you are
    return ReplayImport(added: added, duplicates: dup, errors: errors, message: added + dup == 0 ? 'No replay rounds could be read from that.' : null);
  }

  /// Imports r6-dissect JSON (or an Arenyze response saved as JSON). No API call.
  Future<ReplayImport> importReplayJson(String text) async {
    final res = parseReplayJson(text);
    final out = _addReplays(res.rounds, errors: res.errors);
    if (out.added + out.duplicates > 0) await _saveReplays();
    notifyListeners();
    return out;
  }

  /// Uploads `.rec` files to Arenyze for parsing. Costs one replay credit per file, not API calls.
  Future<ReplayImport> uploadReplays(List<String> paths) async {
    if (!configured) return const ReplayImport(message: 'Add your API key in Profile first.');
    if (paths.isEmpty) return const ReplayImport(message: 'No files chosen.');
    if (paths.length > maxReplayUploadFiles) return const ReplayImport(message: 'Choose at most $maxReplayUploadFiles files at a time.');
    final left = replayQuota?.remaining;
    if (left != null && paths.length > left) return ReplayImport(message: 'You have $left replay credit${left == 1 ? '' : 's'} left, and chose ${paths.length} files.');
    replayBusy = true;
    notifyListeners();
    try {
      final body = await _client().uploadReplays(paths);
      final q = body['quota'];
      if (q is Map) {
        replayQuota = ReplayQuota(limit: (q['limit'] as num).toInt(), used: (q['used'] as num).toInt(), remaining: (q['remaining'] as num).toInt(), at: DateTime.now());
        await _prefs.setString('replay.quota', jsonEncode({'l': replayQuota!.limit, 'u': replayQuota!.used, 'r': replayQuota!.remaining, 'at': replayQuota!.at.toIso8601String()}));
      }
      final res = parseReplayJson(jsonEncode(body));
      final out = _addReplays(res.rounds, errors: res.errors);
      if (out.added + out.duplicates > 0) await _saveReplays();
      return out;
    } on ArenyzeException catch (e) {
      return ReplayImport(message: e.message);
    } on Object catch (e) {
      return ReplayImport(message: 'Upload failed (${e.runtimeType}).');
    } finally {
      replayBusy = false;
      notifyListeners();
    }
  }

  // ----- Replay server: the PC uploads .rec files, this phone collects the parsed rounds -----

  static String normalizeServerUrl(String u) {
    var s = u.trim();
    if (s.isEmpty) return '';
    if (!s.contains('://')) s = 'https://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  bool get replayServerConfigured => replayServerUrl.isNotEmpty && replayServerToken.isNotEmpty;

  Future<void> saveReplayServer(String url, String token) async {
    final u = normalizeServerUrl(url);
    if (u != replayServerUrl) {
      replayCursor = 0; // a different server has its own numbering
      pendingAcks = [];
      await _prefs.setInt('rs.cursor', 0);
      await _prefs.remove('rs.acks');
      await _prefs.setInt('rs.schema', replaySchema); // a fresh download from the start already has every field
      highlights = []; // another server has other clips
      hlCursor = 0;
      await _prefs.remove('highlights');
      await _prefs.setInt('hl.cursor', 0);
      _refetching = false;
    }
    replayServerUrl = u;
    replayServerToken = token.trim();
    await _prefs.setString('rs.url', replayServerUrl);
    await _prefs.setString('rs.token', replayServerToken);
    notifyListeners();
  }

  Future<http.Response> _srv(String method, String path, {Object? body}) {
    final c = httpClient ?? http.Client();
    final uri = Uri.parse('$replayServerUrl$path');
    final h = {'Authorization': 'Bearer $replayServerToken', if (body != null) 'Content-Type': 'application/json'};
    final f = switch (method) {
      'POST' => c.post(uri, headers: h, body: body == null ? null : jsonEncode(body)),
      'PATCH' => c.patch(uri, headers: h, body: jsonEncode(body)),
      'DELETE' => c.delete(uri, headers: h),
      _ => c.get(uri, headers: h),
    };
    return f.timeout(const Duration(seconds: 45));
  }

  String? _serverError(http.Response r) => switch (r.statusCode) {
        200 => null,
        401 => 'The server rejected the token. Check it in Profile.',
        403 => 'That is the upload token. The phone needs the read token.',
        404 => 'That address is not a replay server.',
        _ => 'The server returned ${r.statusCode}.',
      };

  String _netError(Object e) => replayServerUrl.startsWith('http://')
      ? 'Could not reach the server. Plain http:// addresses are blocked on this phone: use an https:// address.'
      : 'Could not reach the server. Check the address and your connection.';

  /// Confirms the address and token work, and says what is waiting.
  Future<ServerCheck> testReplayServer() async {
    if (!replayServerConfigured) return const ServerCheck(ok: false, message: 'Enter the server address and the read token first.');
    try {
      final h = await _srv('GET', '/health');
      if (h.statusCode != 200 || !h.body.contains('"ok"')) return const ServerCheck(ok: false, message: 'That address is not a replay server.');
      final r = await _srv('GET', '/v1/stats');
      final err = _serverError(r);
      if (err != null) return ServerCheck(ok: false, message: err);
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return ServerCheck(ok: true, message: 'Connected. ${j['parsed']} round${j['parsed'] == 1 ? '' : 's'} on the server, ${j['recs']} replay file${j['recs'] == 1 ? '' : 's'} waiting.');
    } on Object catch (e) {
      return ServerCheck(ok: false, message: _netError(e));
    }
  }

  Future<int> _ack(List<int> ids) async {
    var freed = 0;
    for (var i = 0; i < ids.length; i += 200) {
      final batch = ids.sublist(i, i + 200 > ids.length ? ids.length : i + 200);
      final r = await _srv('POST', '/v1/ack', body: {'ids': batch});
      if (r.statusCode != 200) throw StateError('ack ${r.statusCode}');
      freed += ((jsonDecode(r.body) as Map)['freedBytes'] as num?)?.toInt() ?? 0;
    }
    return freed;
  }

  Future<void> _savePending() => pendingAcks.isEmpty ? _prefs.remove('rs.acks') : _prefs.setStringList('rs.acks', [for (final i in pendingAcks) '$i']);

  /// Downloads new parsed rounds, saves them, and only then tells the server to delete their heavy
  /// .rec files. If the delete call fails the ids are kept and retried on the next sync.
  Future<ReplaySync> syncReplayServer({bool auto = false}) async {
    if (!replayServerConfigured) return const ReplaySync(message: 'Set up the replay server in Profile first.');
    if (replaySyncing) return const ReplaySync(skipped: true);
    if (auto && lastReplaySync != null && DateTime.now().difference(lastReplaySync!) < const Duration(minutes: 3)) return const ReplaySync(skipped: true);
    replaySyncing = true;
    notifyListeners();
    var added = 0, dup = 0, failed = 0, unreadable = 0, freed = 0;
    final toAck = <int>[];
    String? stop;
    try {
      if (pendingAcks.isNotEmpty) {
        try {
          freed += await _ack(pendingAcks);
          pendingAcks = [];
          await _savePending();
        } on Object {
          // The server will be asked again below, together with the new rounds.
        }
      }
      var cursor = replayCursor;
      for (var page = 0; page < 60; page++) {
        final r = await _srv('GET', '/v1/rounds?after=$cursor&limit=25');
        final err = _serverError(r);
        if (err != null) {
          stop = err;
          break;
        }
        final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        for (final raw in (j['rounds'] as List)) {
          final item = raw as Map<String, dynamic>;
          if (item['status'] == 'failed') {
            failed++;
            continue;
          }
          final data = item['data'];
          final parsed = data == null ? null : parseReplayJson(jsonEncode(data));
          if (parsed == null || parsed.rounds.isEmpty) {
            unreadable++;
            continue;
          }
          final out = _addReplays(parsed.rounds, replace: _refetching);
          added += out.added;
          dup += out.duplicates;
          toAck.add((item['id'] as num).toInt());
        }
        await _saveReplays(); // saved before anything is deleted
        cursor = (j['nextCursor'] as num).toInt();
        replayCursor = cursor;
        await _prefs.setInt('rs.cursor', cursor);
        if (j['hasMore'] != true) break;
      }
      if (toAck.isNotEmpty) {
        try {
          freed += await _ack(toAck);
        } on Object {
          pendingAcks = {...pendingAcks, ...toAck}.toList();
          await _savePending();
        }
      }
      if (stop == null && _refetching) {
        _refetching = false;
        await _prefs.setInt('rs.schema', replaySchema);
      }
      if (stop == null) await _fetchPopulation();
      if (stop == null) await _syncHighlights();
      lastReplaySync = DateTime.now();
      await _prefs.setString('rs.last', lastReplaySync!.toIso8601String());
    } on Object catch (e) {
      stop = _netError(e);
    } finally {
      replaySyncing = false;
      notifyListeners();
    }
    return ReplaySync(added: added, duplicates: dup, failedOnServer: failed, unreadable: unreadable, freedBytes: freed, pendingAcks: pendingAcks.length, message: stop);
  }

  // ----- highlight clips -----

  /// Headers and full addresses for the clip videos and pictures, which the player and Image widgets fetch themselves.
  Map<String, String> get serverHeaders => {'Authorization': 'Bearer $replayServerToken'};
  String serverUrl(String path) => path.startsWith('http') ? path : '$replayServerUrl$path';

  Future<void> _saveHighlights() async {
    await _prefs.setString('highlights', jsonEncode([for (final h in highlights) h.toJson()]));
    await _prefs.setInt('hl.cursor', hlCursor);
  }

  /// New, changed and deleted clips since the last sync. An older server without clips answers 404: nothing to do.
  Future<void> _syncHighlights() async {
    try {
      for (var page = 0; page < 40; page++) {
        final r = await _srv('GET', '/v1/highlights?after=$hlCursor&limit=100');
        if (r.statusCode != 200) return;
        final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        final byId = {for (final h in highlights) h.id: h};
        for (final raw in j['highlights'] as List) {
          final m = Map<String, dynamic>.from(raw as Map);
          if (m['deleted'] == true) {
            byId.remove(m['id']);
          } else {
            byId[m['id'] as String] = Highlight.fromJson(m);
          }
        }
        highlights = byId.values.toList()..sort((a, b) => b.seq.compareTo(a.seq));
        hlCursor = (j['nextCursor'] as num).toInt();
        final st = j['storage'] as Map?;
        clipsUsedBytes = (st?['usedBytes'] as num?)?.toInt();
        clipsQuotaBytes = (st?['quotaBytes'] as num?)?.toInt();
        await _saveHighlights();
        if (j['hasMore'] != true) break;
      }
    } on Object {
      // keep what is cached; the next sync tries again
    }
  }

  String _clipError(http.Response r) => switch (r.statusCode) {
        404 => 'That clip is no longer on the server.',
        401 || 403 => 'The server did not accept the read token.',
        _ => 'The server answered ${r.statusCode}.',
      };

  Future<String?> _editHighlight(String id, Map<String, dynamic> change) async {
    try {
      final r = await _srv('PATCH', '/v1/highlights/$id', body: change);
      if (r.statusCode != 200) return _clipError(r);
      final h = Highlight.fromJson(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>);
      highlights = [for (final x in highlights) x.id == id ? h : x];
      await _saveHighlights();
      notifyListeners();
      return null;
    } on Object catch (e) {
      return _netError(e);
    }
  }

  /// Returns an error message, or null when it worked.
  Future<String?> renameHighlight(String id, String title) => _editHighlight(id, {'title': title.trim()});

  /// Private ends every share link made so far.
  Future<String?> setHighlightPrivate(String id) => _editHighlight(id, {'visibility': 'private'});

  /// A link that plays the clip without the app or a token, for 7 days.
  Future<({String? url, String? error})> shareHighlight(String id) async {
    try {
      final r = await _srv('POST', '/v1/highlights/$id/share');
      if (r.statusCode != 200) return (url: null, error: _clipError(r));
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      highlights = [for (final x in highlights) x.id == id ? x.copyWith(visibility: 'unlisted') : x];
      await _saveHighlights();
      notifyListeners();
      return (url: serverUrl(j['videoUrl'] as String), error: null);
    } on Object catch (e) {
      return (url: null, error: _netError(e));
    }
  }

  Future<String?> deleteHighlight(String id) async {
    try {
      final r = await _srv('DELETE', '/v1/highlights/$id');
      if (r.statusCode != 200 && r.statusCode != 404) return _clipError(r);
      final gone = highlights.where((x) => x.id == id).fold<int>(0, (s, x) => s + x.size);
      highlights = [for (final x in highlights) if (x.id != id) x];
      if (clipsUsedBytes != null) clipsUsedBytes = (clipsUsedBytes! - gone).clamp(0, 1 << 62);
      await _saveHighlights();
      notifyListeners();
      return null;
    } on Object catch (e) {
      return _netError(e);
    }
  }

  /// Percentile tables of the other players on the server. One small request per sync; an older server without it is fine.
  Future<void> _fetchPopulation() async {
    try {
      final r = await _srv('GET', '/v1/population');
      if (r.statusCode != 200) return;
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final p = Population.fromJson(j);
      if (p == null) return;
      population = p;
      await _prefs.setString('rs.population', jsonEncode(j));
    } on Object {
      // keep the last good table
    }
  }

  Future<void> deleteReplayMatch(String matchId) async {
    replays = [for (final r in replays) if (r.matchId != matchId) r];
    await _saveReplays();
    notifyListeners();
  }

  void _mergeLedger(List<RpPoint> fresh) {
    final byTime = {for (final p in ledger) p.at.toUtc().toIso8601String(): p};
    for (final p in fresh) {
      byTime[p.at.toUtc().toIso8601String()] = p;
    }
    ledger = byTime.values.toList()..sort((a, b) => b.at.compareTo(a.at));
    if (ledger.length > maxLedger) ledger = ledger.sublist(0, maxLedger);
  }

  String _ledgerJson() => jsonEncode([for (final p in ledger) [p.at.toUtc().toIso8601String(), p.rp, p.rank]]);

  /// Everything stored on the device that cannot be re-downloaded, as one JSON string.
  String exportBackup() => jsonEncode({
        'v': 1,
        'player': username,
        'at': DateTime.now().toUtc().toIso8601String(),
        'snapshots': [for (final s in snapshots) s.toJson()],
        'goals': [for (final g in goals) g.toJson()],
        'notes': {for (final e in notes.entries) e.key: e.value.toJson()},
        'ledger': jsonDecode(_ledgerJson()),
        'replays': [for (final r in replays) r.toJson()],
      });

  /// Restores a backup. Returns an error message, or null on success. Nothing changes on failure.
  Future<String?> importBackup(String text) async {
    try {
      final j = jsonDecode(text.trim());
      if (j is! Map || j['v'] != 1) return 'This is not an R6 Coach backup.';
      if (j['player'] != null && username.isNotEmpty && j['player'] != username) return 'This backup belongs to ${j['player']}, not $username.';
      final snaps = [for (final x in j['snapshots'] as List) Snapshot.fromJson(Map<String, dynamic>.from(x as Map))];
      final gs = [for (final x in j['goals'] as List) Goal.fromJson(Map<String, dynamic>.from(x as Map))];
      final ns = {for (final e in (j['notes'] as Map).entries) e.key as String: MatchNote.fromJson(Map<String, dynamic>.from(e.value as Map))};
      final lg = [
        for (final x in j['ledger'] as List) RpPoint(DateTime.parse((x as List)[0] as String), (x[1] as num).toInt(), x.length > 2 ? x[2] as String? : null),
      ];
      final rs = [for (final x in (j['replays'] as List? ?? const [])) ReplayRound.fromJson(Map<String, dynamic>.from(x as Map))];
      snapshots = snaps;
      goals = gs;
      notes = ns;
      _mergeLedger(lg);
      _addReplays(rs);
      await _saveReplays();
      await _prefs.setString('snapshots', jsonEncode([for (final s in snapshots) s.toJson()]));
      await _prefs.setString('goals', jsonEncode([for (final g in goals) g.toJson()]));
      await _prefs.setString('notes', jsonEncode({for (final e in notes.entries) e.key: e.value.toJson()}));
      await _prefs.setString('ledger', _ledgerJson());
      notifyListeners();
      return null;
    } on Object {
      return 'Could not read that backup. Copy it again and retry.';
    }
  }

  MatchNote? noteFor(MatchRecord r) => notes[r.since.toIso8601String()];

  Future<void> saveNote(MatchRecord r, MatchNote n) async {
    final k = r.since.toIso8601String();
    if (n.isEmpty) {
      notes.remove(k);
    } else {
      notes[k] = n;
    }
    await _prefs.setString('notes', jsonEncode({for (final e in notes.entries) e.key: e.value.toJson()}));
    notifyListeners();
  }

  Future<void> startGoal(GoalMetric m) async {
    if (snapshots.isEmpty || goals.any((g) => g.metric == m)) return;
    final base = lifetimeValue(m, snapshots.last);
    if (base == null) return;
    goals = [...goals, Goal(metric: m, baseline: base, target: suggestTarget(m, base), startedAt: snapshots.last.at)];
    await _saveGoals();
  }

  Future<void> removeGoal(GoalMetric m) async {
    goals = [for (final g in goals) if (g.metric != m) g];
    await _saveGoals();
  }

  Future<void> _saveGoals() async {
    await _prefs.setString('goals', jsonEncode([for (final g in goals) g.toJson()]));
    notifyListeners();
  }
}
