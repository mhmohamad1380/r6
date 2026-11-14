String pct(double? v, {int digits = 0}) => v == null ? '—' : '${(v * 100).toStringAsFixed(digits)}%';
String ratio(double? v) => v == null ? '—' : v.toStringAsFixed(2);
String signed(num v) => v > 0 ? '+$v' : '$v';

String ago(DateTime? t) {
  if (t == null) return 'never';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 30) return '${d.inDays} d ago';
  return '${(d.inDays / 30).floor()} mo ago';
}

String hours(int ms) => ms <= 0 ? '—' : '${(ms / 3600000).toStringAsFixed(ms >= 36000000 ? 0 : 1)} h';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String shortDate(DateTime t) => '${_months[t.month - 1]} ${t.day}';
String clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String dayLabel(DateTime t) {
  final now = DateTime.now();
  final d = DateTime(t.year, t.month, t.day), n = DateTime(now.year, now.month, now.day);
  final diff = n.difference(d).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return shortDate(t);
}
