import 'package:meta/meta.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/utils/formatters.dart';
import '../../core/utils/json_utils.dart';

/// The five trigger kinds supported by AUTOMETA (spec §10).
enum TriggerType {
  schedule('schedule', 'Schedule'),
  dateTime('date_time', 'Date & time'),
  manual('manual', 'Manual'),
  appEvent('app_event', 'App event'),
  webhook('webhook', 'Webhook');

  const TriggerType(this.wire, this.label);

  final String wire;
  final String label;

  static TriggerType fromWire(Object? value, {TriggerType fallback = schedule}) {
    final String raw = '$value'.toLowerCase().trim();
    for (final TriggerType type in TriggerType.values) {
      if (type.wire == raw || type.name.toLowerCase() == raw) return type;
    }
    return fallback;
  }

  /// Only these triggers can be armed by the scheduler.
  bool get isSchedulable => this == schedule || this == dateTime;
}

/// Repetition pattern for a [ScheduleTrigger].
enum ScheduleRepeat {
  daily('daily', 'Every day'),
  weekdays('weekdays', 'Weekdays'),
  weekends('weekends', 'Weekends'),
  days('days', 'Specific days'),
  weekly('weekly', 'Every week'),
  monthly('monthly', 'Every month'),
  interval('interval', 'At an interval');

  const ScheduleRepeat(this.wire, this.label);

  final String wire;
  final String label;

  static ScheduleRepeat fromWire(Object? value, {ScheduleRepeat fallback = daily}) {
    final String raw = '$value'.toLowerCase().trim();
    for (final ScheduleRepeat repeat in ScheduleRepeat.values) {
      if (repeat.wire == raw || repeat.name.toLowerCase() == raw) return repeat;
    }
    return fallback;
  }
}

/// How a [DateTimeTrigger] recurs after its anchor moment.
enum DateTimeRepeat {
  once('once', 'One time'),
  daily('daily', 'Repeat daily'),
  weekly('weekly', 'Repeat weekly'),
  monthly('monthly', 'Repeat monthly'),
  yearly('yearly', 'Repeat yearly');

  const DateTimeRepeat(this.wire, this.label);

  final String wire;
  final String label;

  static DateTimeRepeat fromWire(Object? value, {DateTimeRepeat fallback = once}) {
    final String raw = '$value'.toLowerCase().trim();
    for (final DateTimeRepeat repeat in DateTimeRepeat.values) {
      if (repeat.wire == raw || repeat.name.toLowerCase() == raw) return repeat;
    }
    return fallback;
  }
}

/// Trigger half of a workflow definition.
///
/// Triggers are pure data plus one calculation: "when do I fire next?".
/// All wall-clock arithmetic happens in [tz.TZDateTime] so a workflow created
/// in `Africa/Lagos` keeps firing at 07:00 Lagos time when the device travels.
@immutable
sealed class WorkflowTrigger {
  const WorkflowTrigger();

  TriggerType get type;

  Map<String, dynamic> toJson();

  /// Next firing strictly after [after], in [location]'s wall clock, or `null`
  /// when the trigger can never fire again.
  tz.TZDateTime? nextOccurrence(tz.TZDateTime after, tz.Location location);

  /// Short human label, e.g. "Every day · 07:00".
  String describe();

  /// Whether the OS scheduler can arm this trigger.
  bool get isSchedulable => type.isSchedulable;

  static WorkflowTrigger fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    final TriggerType type = TriggerType.fromWire(map['type']);
    return switch (type) {
      TriggerType.schedule => ScheduleTrigger.fromJson(map),
      TriggerType.dateTime => DateTimeTrigger.fromJson(map),
      TriggerType.manual => ManualTrigger.fromJson(map),
      TriggerType.appEvent => AppEventTrigger.fromJson(map),
      TriggerType.webhook => WebhookTrigger.fromJson(map),
    };
  }
}

@immutable
class ScheduleTrigger extends WorkflowTrigger {
  const ScheduleTrigger({
    this.timeOfDay = '07:00',
    this.repeat = ScheduleRepeat.daily,
    this.weekdays = const <int>{1, 2, 3, 4, 5, 6, 7},
    this.dayOfMonth = 1,
    this.intervalMinutes = 60,
    this.anchor,
  });

  /// `HH:mm` in the workflow's time zone.
  final String timeOfDay;
  final ScheduleRepeat repeat;

  /// ISO-8601 weekday numbers (1 = Monday … 7 = Sunday).
  final Set<int> weekdays;
  final int dayOfMonth;
  final int intervalMinutes;

  /// Reference point for interval scheduling.
  final DateTime? anchor;

  @override
  TriggerType get type => TriggerType.schedule;

  ScheduleTrigger copyWith({
    String? timeOfDay,
    ScheduleRepeat? repeat,
    Set<int>? weekdays,
    int? dayOfMonth,
    int? intervalMinutes,
    DateTime? anchor,
  }) =>
      ScheduleTrigger(
        timeOfDay: timeOfDay ?? this.timeOfDay,
        repeat: repeat ?? this.repeat,
        weekdays: weekdays ?? this.weekdays,
        dayOfMonth: dayOfMonth ?? this.dayOfMonth,
        intervalMinutes: intervalMinutes ?? this.intervalMinutes,
        anchor: anchor ?? this.anchor,
      );

  int get hour => Formatters.minutesOfDay(timeOfDay) == null ? 7 : Formatters.minutesOfDay(timeOfDay)! ~/ 60;
  int get minute =>
      Formatters.minutesOfDay(timeOfDay) == null ? 0 : Formatters.minutesOfDay(timeOfDay)! % 60;

  Set<int> get effectiveWeekdays => switch (repeat) {
        ScheduleRepeat.daily => const <int>{1, 2, 3, 4, 5, 6, 7},
        ScheduleRepeat.weekdays => const <int>{1, 2, 3, 4, 5},
        ScheduleRepeat.weekends => const <int>{6, 7},
        ScheduleRepeat.weekly => <int>{weekdays.isEmpty ? 1 : weekdays.first},
        _ => weekdays.isEmpty ? const <int>{1, 2, 3, 4, 5, 6, 7} : weekdays,
      };

  @override
  tz.TZDateTime? nextOccurrence(tz.TZDateTime after, tz.Location location) {
    if (repeat == ScheduleRepeat.interval) {
      final int step = intervalMinutes <= 0 ? 60 : intervalMinutes;
      final tz.TZDateTime start = anchor == null
          ? after
          : tz.TZDateTime.from(anchor!.toUtc(), location);
      if (!start.isBefore(after)) return start;
      final int elapsed = after.difference(start).inMinutes;
      final int steps = elapsed ~/ step + 1;
      return start.add(Duration(minutes: step * steps));
    }

    if (repeat == ScheduleRepeat.monthly) {
      final int day = dayOfMonth.clamp(1, 31);
      for (int i = 0; i < 24; i++) {
        final tz.TZDateTime candidate = tz.TZDateTime(
          location,
          after.year,
          after.month + i,
          1,
          hour,
          minute,
        );
        final int daysInMonth = tz.TZDateTime(location, candidate.year, candidate.month + 1, 1)
            .difference(candidate)
            .inDays;
        if (day > daysInMonth) continue;
        final tz.TZDateTime atDay = tz.TZDateTime(
          location,
          candidate.year,
          candidate.month,
          day,
          hour,
          minute,
        );
        if (atDay.isAfter(after)) return atDay;
      }
      return null;
    }

    final Set<int> allowed = effectiveWeekdays;
    for (int i = 0; i < 9; i++) {
      final tz.TZDateTime candidate = tz.TZDateTime(
        location,
        after.year,
        after.month,
        after.day + i,
        hour,
        minute,
      );
      if (allowed.contains(candidate.weekday) && candidate.isAfter(after)) return candidate;
    }
    return null;
  }

  @override
  String describe() {
    final String time = Formatters.humanize24(timeOfDay);
    return switch (repeat) {
      ScheduleRepeat.daily => 'Every day · $time',
      ScheduleRepeat.weekdays => 'Weekdays · $time',
      ScheduleRepeat.weekends => 'Weekends · $time',
      ScheduleRepeat.days || ScheduleRepeat.weekly => '${Formatters.weekdayList(effectiveWeekdays)} · $time',
      ScheduleRepeat.monthly => 'Monthly on the ${Formatters.ordinal(dayOfMonth)} · $time',
      ScheduleRepeat.interval => 'Every ${Formatters.duration(Duration(minutes: intervalMinutes))}',
    };
  }

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type.wire,
        'time': timeOfDay,
        'repeat': repeat.wire,
        'weekdays': sortedInts(effectiveWeekdays),
        'day_of_month': dayOfMonth,
        'interval_minutes': intervalMinutes,
        if (anchor != null) 'anchor': anchor!.toUtc().toIso8601String(),
      };

  factory ScheduleTrigger.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    final Set<int> days = asIntSet(map['weekdays']);
    return ScheduleTrigger(
      timeOfDay: asString(map['time'], fallback: '07:00'),
      repeat: ScheduleRepeat.fromWire(map['repeat']),
      weekdays: days.isEmpty ? const <int>{1, 2, 3, 4, 5, 6, 7} : days,
      dayOfMonth: asInt(map['day_of_month'], fallback: 1).clamp(1, 31),
      intervalMinutes: asInt(map['interval_minutes'], fallback: 60).clamp(1, 7 * 24 * 60),
      anchor: asDateTime(map['anchor']),
    );
  }
}

@immutable
class DateTimeTrigger extends WorkflowTrigger {
  const DateTimeTrigger({required this.at, this.repeat = DateTimeRepeat.once, this.label});

  final DateTime at;
  final DateTimeRepeat repeat;
  final String? label;

  /// Convenience builder for "in 30 minutes" style countdowns (spec §10).
  factory DateTimeTrigger.countdown(Duration duration, {DateTime? from}) =>
      DateTimeTrigger(
        at: (from ?? DateTime.now()).add(duration),
        label: 'In ${Formatters.duration(duration)}',
      );

  @override
  TriggerType get type => TriggerType.dateTime;

  DateTimeTrigger copyWith({DateTime? at, DateTimeRepeat? repeat, String? label}) =>
      DateTimeTrigger(at: at ?? this.at, repeat: repeat ?? this.repeat, label: label ?? this.label);

  @override
  tz.TZDateTime? nextOccurrence(tz.TZDateTime after, tz.Location location) {
    switch (repeat) {
      case DateTimeRepeat.once:
        final tz.TZDateTime moment = tz.TZDateTime.from(at, location);
        return moment.isAfter(after) ? moment : null;
      case DateTimeRepeat.daily:
        for (int i = 0; i < 9; i++) {
          final tz.TZDateTime candidate = tz.TZDateTime(
            location,
            after.year,
            after.month,
            after.day + i,
            at.hour,
            at.minute,
          );
          if (candidate.isAfter(after)) return candidate;
        }
        return null;
      case DateTimeRepeat.weekly:
        for (int i = 0; i < 9; i++) {
          final tz.TZDateTime candidate = tz.TZDateTime(
            location,
            after.year,
            after.month,
            after.day + i,
            at.hour,
            at.minute,
          );
          if (candidate.weekday == at.weekday && candidate.isAfter(after)) return candidate;
        }
        return null;
      case DateTimeRepeat.monthly:
        for (int i = 0; i < 24; i++) {
          final tz.TZDateTime candidate = tz.TZDateTime(
            location,
            after.year,
            after.month + i,
            at.day,
            at.hour,
            at.minute,
          );
          if (candidate.day == at.day && candidate.isAfter(after)) return candidate;
        }
        return null;
      case DateTimeRepeat.yearly:
        for (int i = 0; i < 4; i++) {
          final tz.TZDateTime candidate = tz.TZDateTime(
            location,
            after.year + i,
            at.month,
            at.day,
            at.hour,
            at.minute,
          );
          if (candidate.month == at.month &&
              candidate.day == at.day &&
              candidate.isAfter(after)) {
            return candidate;
          }
        }
        return null;
    }
  }

  @override
  String describe() {
    final DateTime local = at.toLocal();
    final String moment = '${Formatters.fullDate(local)} · ${Formatters.time(local)}';
    return repeat == DateTimeRepeat.once ? moment : '$moment · ${repeat.label}';
  }

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type.wire,
        'at': at.toUtc().toIso8601String(),
        'repeat': repeat.wire,
        if (label != null) 'label': label,
      };

  factory DateTimeTrigger.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return DateTimeTrigger(
      at: asDateTime(map['at']) ?? DateTime.now(),
      repeat: DateTimeRepeat.fromWire(map['repeat']),
      label: asStringOrNull(map['label']),
    );
  }
}

/// Fired only by the user pressing "Run now" (or by a test run).
@immutable
class ManualTrigger extends WorkflowTrigger {
  const ManualTrigger({this.hint});

  final String? hint;

  @override
  TriggerType get type => TriggerType.manual;

  @override
  tz.TZDateTime? nextOccurrence(tz.TZDateTime after, tz.Location location) => null;

  @override
  String describe() => hint ?? 'Runs when you ask it to';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type.wire,
        if (hint != null) 'hint': hint,
      };

  factory ManualTrigger.fromJson(Object? json) =>
      ManualTrigger(hint: asStringOrNull(asMap(json)['hint']));
}

/// Fired by an in-app signal. Only events AUTOMETA can genuinely observe are
/// offered: app opened, app backgrounded, device charging state.
@immutable
class AppEventTrigger extends WorkflowTrigger {
  const AppEventTrigger({required this.event, this.debounceMinutes = 15});

  /// One of [supportedEvents].
  final String event;

  /// Minimum gap between two firings of the same event.
  final int debounceMinutes;

  static const Map<String, String> supportedEvents = <String, String>{
    'app_opened': 'When the app is opened',
    'app_backgrounded': 'When the app goes to the background',
    'device_charging': 'When the device starts charging',
  };

  @override
  TriggerType get type => TriggerType.appEvent;

  @override
  tz.TZDateTime? nextOccurrence(tz.TZDateTime after, tz.Location location) => null;

  @override
  String describe() => supportedEvents[event] ?? 'App event: $event';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type.wire,
        'event': event,
        'debounce_minutes': debounceMinutes,
      };

  factory AppEventTrigger.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return AppEventTrigger(
      event: asString(map['event'], fallback: 'app_opened'),
      debounceMinutes: asInt(map['debounce_minutes'], fallback: 15).clamp(1, 24 * 60),
    );
  }
}

/// Fired by an inbound HTTPS POST to the device webhook endpoint.
@immutable
class WebhookTrigger extends WorkflowTrigger {
  const WebhookTrigger({required this.token, this.method = 'POST'});

  /// Opaque secret identifying this workflow's endpoint. Never logged.
  final String token;
  final String method;

  @override
  TriggerType get type => TriggerType.webhook;

  @override
  tz.TZDateTime? nextOccurrence(tz.TZDateTime after, tz.Location location) => null;

  @override
  String describe() => 'Inbound webhook';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type.wire,
        'token': token,
        'method': method,
      };

  factory WebhookTrigger.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return WebhookTrigger(
      token: asString(map['token']),
      method: asString(map['method'], fallback: 'POST'),
    );
  }
}
