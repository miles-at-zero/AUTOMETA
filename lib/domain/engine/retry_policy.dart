import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';

/// Controlled retry behaviour (spec §22).
///
/// `maxAttempts` is always finite, backoff grows exponentially and is capped,
/// and a non-retriable failure (bad credentials, invalid template, user
/// rejection) stops immediately. Nothing here can loop forever.
@immutable
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = EngineLimits.defaultRetries + 1,
    this.baseBackoff = EngineLimits.retryBaseBackoff,
    this.maxBackoff = const Duration(hours: 1),
    this.jitter = true,
  });

  /// Total tries including the first attempt. `maxRetries = 2` => 3 attempts.
  final int maxAttempts;
  final Duration baseBackoff;
  final Duration maxBackoff;
  final bool jitter;

  factory RetryPolicy.fromMaxRetries(int maxRetries) => RetryPolicy(
        maxAttempts: (maxRetries + 1).clamp(1, EngineLimits.maxRetries + 1),
      );

  /// [attempt] is 1-based: the attempt that just failed.
  bool shouldRetry({
    required int attempt,
    required bool retriable,
    bool cancelled = false,
  }) {
    if (cancelled) return false;
    if (!retriable) return false;
    return attempt < maxAttempts;
  }

  /// Exponential backoff: base * 2^(attempt-1), capped, plus up to 20% jitter.
  Duration backoffFor(int attempt, {math.Random? random}) {
    final int exponent = (attempt - 1).clamp(0, 12);
    final int rawMillis = baseBackoff.inMilliseconds * math.pow(2, exponent).toInt();
    final int capped = math.min(rawMillis, maxBackoff.inMilliseconds);
    if (!jitter || capped == 0) return Duration(milliseconds: capped);
    final math.Random rng = random ?? math.Random();
    final int extra = rng.nextInt((capped * 0.2).ceil().clamp(1, 60000));
    return Duration(milliseconds: capped + extra);
  }

  /// Human readable plan, shown in the retry sheet: "30s, 1m, 2m".
  String describePlan({math.Random? random}) {
    if (maxAttempts <= 1) return 'No retries';
    final List<String> parts = <String>[];
    for (int attempt = 1; attempt < maxAttempts; attempt++) {
      final Duration backoff = backoffFor(attempt, random: random ?? math.Random(42));
      parts.add(_short(backoff));
    }
    return 'Retry after ${parts.join(', ')}';
  }

  static String _short(Duration value) {
    if (value.inSeconds < 60) return '${value.inSeconds}s';
    if (value.inMinutes < 60) return '${value.inMinutes}m';
    return '${value.inHours}h ${value.inMinutes % 60}m';
  }
}
