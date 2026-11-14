import 'dart:convert';

import 'package:http/http.dart' as http;

/// Rate-limit counters the API reports in its response headers (free plan: 40/min, 200/hour, 400/day).
class RateLimits {
  const RateLimits({this.dayLimit, this.dayRemaining, this.hourLimit, this.hourRemaining, this.minuteLimit, this.minuteRemaining});
  final int? dayLimit, dayRemaining, hourLimit, hourRemaining, minuteLimit, minuteRemaining;

  static RateLimits? fromHeaders(Map<String, String> h) {
    int? i(String k) => int.tryParse(h[k] ?? '');
    final r = RateLimits(
      dayLimit: i('x-ratelimit-day-limit'),
      dayRemaining: i('x-ratelimit-day-remaining'),
      hourLimit: i('x-ratelimit-hour-limit'),
      hourRemaining: i('x-ratelimit-hour-remaining'),
      minuteLimit: i('x-ratelimit-minute-limit'),
      minuteRemaining: i('x-ratelimit-minute-remaining'),
    );
    return r.dayRemaining == null && r.hourRemaining == null ? null : r;
  }
}

class ArenyzeException implements Exception {
  const ArenyzeException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

/// Thin client for the Arenyze (R6Data) API. Free plan: 2,000 calls/month.
class ArenyzeClient {
  ArenyzeClient(this.apiKey, {http.Client? client, this.onCall, this.onRateLimits}) : _http = client ?? http.Client();

  static const baseUrl = 'https://public-api.arenyze.com/r6/api';
  final String apiKey;
  final http.Client _http;
  final void Function(RateLimits)? onRateLimits;
  final void Function()? onCall; // counts every request actually sent, for the local quota meter

  Future<Map<String, dynamic>> profile(String name, String platform) =>
      _get('v2/profile', {'nameOnPlatform': name, 'platformType': platform});

  Future<Map<String, dynamic>> operators(String name, String platform, {String modes = 'all', String season = 'all'}) =>
      _get('v2/operators', {'nameOnPlatform': name, 'platformType': platform, 'modes': modes, 'seasonYear': season});

  Future<Map<String, dynamic>> usage() => _get('me/usage', {});

  static const replayUploadUrl = 'https://r6.arenyze.com/api/replays/api/upload';

  /// Uploads `.rec` files of ONE match. Each file spends one replay credit (free plan: 15).
  /// Returns the parsed response: `{matchID, rounds, match, quota}`.
  Future<Map<String, dynamic>> uploadReplays(List<String> paths) async {
    final req = http.MultipartRequest('POST', Uri.parse(replayUploadUrl))..headers['api-key'] = apiKey;
    for (final p in paths) {
      req.files.add(await http.MultipartFile.fromPath('replayFiles', p));
    }
    final http.Response r;
    try {
      r = await http.Response.fromStream(await _http.send(req).timeout(const Duration(minutes: 4)));
    } on Exception catch (e) {
      throw ArenyzeException('Upload failed: ${e.runtimeType}. Check your connection and try again.');
    }
    if (r.statusCode == 200) {
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      if (body is Map<String, dynamic>) return body;
      throw const ArenyzeException('Unexpected response format.');
    }
    String? detail;
    try {
      final b = jsonDecode(utf8.decode(r.bodyBytes));
      if (b is Map) detail = (b['error'] ?? b['message'])?.toString();
    } on Object {
      detail = null;
    }
    switch (r.statusCode) {
      case 401:
      case 403:
        throw ArenyzeException('API key rejected. Check it in Profile > Settings.', status: r.statusCode);
      case 402:
      case 429:
        throw ArenyzeException(detail ?? 'Replay credits used up for this plan.', status: r.statusCode);
      case 413:
        throw const ArenyzeException('Those files are too large to upload at once. Try fewer rounds.', status: 413);
      case 400:
      case 422:
        throw ArenyzeException(detail ?? 'The server could not read those replays. Upload rounds of a single match.', status: r.statusCode);
      default:
        throw ArenyzeException('Server returned ${r.statusCode}.', status: r.statusCode);
    }
  }

  String _limitMessage(RateLimits? rl) {
    if (rl?.minuteRemaining == 0) return 'Too many requests this minute. Wait a minute and try again.';
    if (rl?.hourRemaining == 0) return 'Hourly request limit reached. Try again within the hour.';
    if (rl?.dayRemaining == 0) return 'Daily request limit reached (resets at midnight UTC). Cached data is shown instead.';
    return 'Monthly API quota reached. Cached data is shown instead.';
  }

  Future<Map<String, dynamic>> _get(String path, Map<String, String> query) async {
    final uri = Uri.parse('$baseUrl/$path').replace(queryParameters: query.isEmpty ? null : query);
    final http.Response r;
    onCall?.call();
    try {
      r = await _http.get(uri, headers: {'api-key': apiKey}).timeout(const Duration(seconds: 45));
    } on Exception catch (e) {
      throw ArenyzeException('Network error: ${e.runtimeType}. Check your connection.');
    }
    final rl = RateLimits.fromHeaders(r.headers);
    if (rl != null) onRateLimits?.call(rl);
    switch (r.statusCode) {
      case 200:
        final body = jsonDecode(utf8.decode(r.bodyBytes));
        if (body is Map<String, dynamic>) return body;
        throw const ArenyzeException('Unexpected response format.');
      case 401:
      case 403:
        throw ArenyzeException('API key rejected. Check it in Profile > Settings.', status: r.statusCode);
      case 404:
        throw ArenyzeException('Player not found on this platform.', status: 404);
      case 429:
        throw ArenyzeException(_limitMessage(rl), status: 429);
      default:
        throw ArenyzeException('Server returned ${r.statusCode}.', status: r.statusCode);
    }
  }
}
