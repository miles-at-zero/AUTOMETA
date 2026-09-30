import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Display formatting helpers. All user-facing time strings go through here so
/// the dashboard, activity list and builder never disagree.
class Formatters {
  const Formatters._();

  static final DateFormat _time = DateFormat.jm();
  static final DateFormat _time24 = DateFormat.Hm();
  static final DateFormat _dayMonth = DateFormat.MMMd();
  static final DateFormat _fullDate = DateFormat.yMMMMd();
  static final DateFormat _stamp = DateFormat.yMMMd().add_jm();
  static final DateFormat _isoDay = DateFormat('yyyy-MM-dd');

  static String time(DateTime value) => _time.format(value);
  static String time24(DateTime value) => _time24.format(value);
  static String dayMonth(DateTime value) => _dayMonth.format(value);
  static String fullDate(DateTime value) => _fullDate.format(value);
  static String stamp(DateTime value) => _stamp.format(value);
  static String isoDay(DateTime value) => _isoDay.format(value);

  /// "07:00" -> "7:00 AM". Returns the input untouched when it is not `HH:mm`.
  static String humanize24(String hhmm) {
    final RegExp pattern = RegExp(r'^(\d{1,2}):(\d{2})$');
    final Match? match = pattern.firstMatch(hhmm.trim());
    if (match == null) return hhmm;
    final int hour = int.parse(match.group(1)!);
    final int minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) return hhmm;
    return _time.format(DateTime(2000, 1, 1, hour, minute));
  }

  /// "07:00" -> 420.
  static int? minutesOfDay(String hhmm) {
    final RegExp pattern = RegExp(r'^(\d{1,2}):(\d{2})$');
    final Match? match = pattern.firstMatch(hhmm.trim());
    if (match == null) return null;
    final int hour = int.parse(match.group(1)!);
    final int minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) return null;
    return hour * 60 + minute;
  }

  static String minutesTo24(int totalMinutes) {
    final int clamped = totalMinutes.clamp(0, 24 * 60 - 1);
    final int hour = clamped ~/ 60;
    final int minute = clamped % 60;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  static String greeting(DateTime now) {
    final int hour = now.hour;
    if (hour < 5) return 'Still up';
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    if (hour < 22) return 'Good evening';
    return 'Good night';
  }

  /// Relative label used on the dashboard: "in 2 h 10 m", "12 m ago".
  static String relative(DateTime value, {DateTime? now}) {
    final DateTime reference = now ?? DateTime.now();
    final Duration delta = value.difference(reference);
    final bool future = delta.isNegative == false;
    final Duration abs = delta.abs();

    String body;
    if (abs.inSeconds < 45) {
      body = 'moments';
    } else if (abs.inMinutes < 60) {
      body = '${abs.inMinutes} min';
    } else if (abs.inHours < 24) {
      final int minutes = abs.inMinutes % 60;
      body = minutes == 0 ? '${abs.inHours} h' : '${abs.inHours} h ${minutes} min';
    } else if (abs.inDays < 7) {
      body = '${abs.inDays} d';
    } else {
      body = dayMonth(value);
    }

    if (abs.inSeconds < 45) return future ? 'in moments' : 'moments ago';
    return future ? 'in $body' : '$body ago';
  }

  /// "Every day", "Mon, Wed, Fri", "Every month on the 1st".
  static String weekdayList(Iterable<int> weekdays) {
    const List<String> names = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final List<int> sorted = weekdays.toList()..sort();
    if (sorted.length == 7) return 'Every day';
    if (_same(sorted, <int>[1, 2, 3, 4, 5])) return 'Weekdays';
    if (_same(sorted, <int>[6, 7])) return 'Weekends';
    return sorted.map((int d) => names[(d - 1) % 7]).join(', ');
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String duration(Duration value) {
    if (value.inSeconds < 60) return '${value.inSeconds}s';
    if (value.inMinutes < 60) {
      final int seconds = value.inSeconds % 60;
      return seconds == 0 ? '${value.inMinutes}m' : '${value.inMinutes}m ${seconds}s';
    }
    final int hours = value.inHours;
    final int minutes = value.inMinutes % 60;
    return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
  }

  static String ordinal(int day) {
    if (day >= 11 && day <= 13) return '${day}th';
    switch (day % 10) {
      case 1:
        return '${day}st';
      case 2:
        return '${day}nd';
      case 3:
        return '${day}rd';
      default:
        return '${day}th';
    }
  }

  /// Truncates for single-line previews so cards never overflow on 320dp phones.
  static String preview(String value, {int max = 72}) {
    final String collapsed = value.replaceAll('\n', ' ').trim();
    if (collapsed.length <= max) return collapsed;
    return '${collapsed.substring(0, max - 1)}…';
  }
}

/// Clamps a widget to a comfortable reading width on tablets / landscape while
/// staying edge-to-edge on phones.
class ResponsiveWidth extends StatelessWidget {
  const ResponsiveWidth({required this.child, this.maxWidth = 640, super.key});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      );
}
