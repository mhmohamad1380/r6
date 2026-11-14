import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
import 'core/theme.dart';
import 'data/counters.dart';
import 'data/match_notes.dart';
import 'data/models.dart';
import 'data/ranks.dart';
import 'features/common/common.dart';
import 'features/common/guide.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/matches/matches_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/replays/coach_screen.dart';
import 'features/stats/stats_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(statusBarColor: Colors.transparent, systemNavigationBarColor: AppColors.surface));
  final bundle = rootBundle;
  final game = GameOperator.listFromResponse(await _json(bundle, 'assets/game_operators.json'));
  final counters = CounterBook.parse(await bundle.loadString('assets/counters.json'));
  final ranks = RankLadder.parse(await bundle.loadString('assets/ranks.json'));
  final maps = parseMaps(await bundle.loadString('assets/maps.json'));
  final state = AppState(await SharedPreferences.getInstance(), game: game, counters: counters, ranks: ranks, maps: maps);
  runApp(R6CoachApp(state: state));
  state.refresh(); // only hits the network when the cache is stale
  state.syncReplayServer(auto: true); // collects new replays from your replay server, if one is set up
}

Future<Object?> _json(AssetBundle b, String path) async => jsonDecode(await b.loadString(path));

class R6CoachApp extends StatelessWidget {
  const R6CoachApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'R6 Coach',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: HomeShell(state: state),
      );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state});
  final AppState state;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      widget.state.refresh(); // no-op unless data is over 30 minutes old
      widget.state.syncReplayServer(auto: true); // no-op unless configured and not synced in the last 3 minutes
    }
  }

  void _go(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          // First run: three short steps instead of an empty app.
          if (widget.state.needsOnboarding) return OnboardingScreen(state: widget.state);
          return AppNav(goTab: _go, child: _shell());
        },
      );

  Widget _shell() {
    final pages = <Widget>[
      DashboardScreen(state: widget.state, onOpenSettings: () => _go(Tabs.profile), onOpenTab: _go),
      MatchCoachScreen(state: widget.state, embedded: true),
      MatchesScreen(state: widget.state, onOpenSettings: () => _go(Tabs.profile)),
      StatsScreen(state: widget.state, onOpenSettings: () => _go(Tabs.profile)),
      ProfileScreen(state: widget.state),
    ];
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
          child: KeyedSubtree(key: ValueKey(_index), child: pages[_index]),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          HapticFeedback.selectionClick();
          _go(i);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.school_outlined), selectedIcon: Icon(Icons.school), label: 'Coach'),
          NavigationDestination(icon: Icon(Icons.sports_esports_outlined), selectedIcon: Icon(Icons.sports_esports), label: 'Matches'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Stats'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}
