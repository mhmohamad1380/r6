import 'dart:convert';

/// One "A beats B" relationship from the community counters dataset.
class Counter {
  const Counter({required this.from, required this.to, required this.level, required this.text});
  final String from, to; // normalized operator ids
  final String level; // hard | soft | minor
  final String text;

  int get weight => switch (level) { 'hard' => 3, 'soft' => 2, _ => 1 };
}

/// Lowercases and strips diacritics so "Jäger" matches "jager" and "Nøkk" matches "nokk".
String opId(String name) {
  const map = {'ä': 'a', 'ö': 'o', 'ø': 'o', 'å': 'a', 'é': 'e', 'è': 'e', 'ü': 'u', 'ï': 'i', 'ã': 'a', 'á': 'a', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ñ': 'n', 'ç': 'c'};
  final lower = name.toLowerCase();
  return lower.split('').map((c) => map[c] ?? c).join().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// Data: github.com/BurkusCat/r6-operator-counters (MIT). Bundled, so it costs no API calls.
class CounterBook {
  const CounterBook(this.all);
  static const empty = CounterBook([]);
  final List<Counter> all;

  factory CounterBook.parse(String json) {
    final j = jsonDecode(json) as Map<String, dynamic>;
    final out = <Counter>[];
    for (final e in (j['counters'] as Map<String, dynamic>).entries) {
      for (final c in e.value as List) {
        out.add(Counter(from: opId(e.key), to: opId(c['t'] as String), level: c['k'] as String, text: c['x'] as String));
      }
    }
    return CounterBook(out);
  }

  /// Operators this one is good against.
  List<Counter> beats(String name) => (all.where((c) => c.from == opId(name)).toList())..sort((a, b) => b.weight.compareTo(a.weight));

  /// Operators that are good against this one.
  List<Counter> beatenBy(String name) => (all.where((c) => c.to == opId(name)).toList())..sort((a, b) => b.weight.compareTo(a.weight));
}
