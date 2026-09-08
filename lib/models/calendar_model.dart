import 'package:flutter/material.dart';

// ── Event ─────────────────────────────────────────────────────────────────────

class CalendarEvent {
  final String id;
  final String title;
  final String? description;
  final String? location;
  final DateTime start;
  final DateTime end;
  final bool isAllDay;
  final List<String> attendees;
  final Color? color;

  const CalendarEvent({
    required this.id,
    required this.title,
    this.description,
    this.location,
    required this.start,
    required this.end,
    this.isAllDay = false,
    this.attendees = const [],
    this.color,
  });

  factory CalendarEvent.fromJson(Map<String, dynamic> json) {
    final startObj = json['start'] as Map<String, dynamic>? ?? {};
    final endObj = json['end'] as Map<String, dynamic>? ?? {};
    final allDay = startObj.containsKey('date') && !startObj.containsKey('dateTime');

    DateTime _parse(Map<String, dynamic> obj) {
      if (obj['dateTime'] != null) {
        return DateTime.parse(obj['dateTime'] as String).toLocal();
      }
      if (obj['date'] != null) return DateTime.parse(obj['date'] as String);
      return DateTime.now();
    }

    return CalendarEvent(
      id: json['id'] as String? ?? '',
      title: json['summary'] as String? ?? '(no title)',
      description: json['description'] as String?,
      location: json['location'] as String?,
      start: _parse(startObj),
      end: _parse(endObj),
      isAllDay: allDay,
      attendees: (json['attendees'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .map((a) => a['email'] as String? ?? '')
              .where((e) => e.isNotEmpty)
              .toList() ??
          [],
      color: _colorFromId(json['colorId'] as String?),
    );
  }

  Map<String, dynamic> toJson() => {
        'summary': title,
        if (description != null) 'description': description,
        if (location != null) 'location': location,
        'start': isAllDay
            ? {'date': _dateStr(start)}
            : {'dateTime': start.toUtc().toIso8601String()},
        'end': isAllDay
            ? {'date': _dateStr(end)}
            : {'dateTime': end.toUtc().toIso8601String()},
      };

  static String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static Color? _colorFromId(String? id) => switch (id) {
        '1' => const Color(0xFF7986CB), // lavender
        '2' => const Color(0xFF33B679), // sage
        '3' => const Color(0xFF8E24AA), // grape
        '4' => const Color(0xFFE67C73), // flamingo
        '5' => const Color(0xFFF6BF26), // banana
        '6' => const Color(0xFFFF8A65), // tangerine
        '7' => const Color(0xFF039BE5), // peacock
        '8' => const Color(0xFF616161), // graphite
        '9' => const Color(0xFF3F51B5), // blueberry
        '10' => const Color(0xFF0B8043), // basil
        '11' => const Color(0xFFD50000), // tomato
        _ => null,
      };

  String get timeLabel {
    if (isAllDay) return 'All day';
    final fmt = (DateTime dt) =>
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '${fmt(start)} – ${fmt(end)}';
  }
}

// ── Suggestion ────────────────────────────────────────────────────────────────

enum SuggestionAction { info, addEvent, reply }

class CalendarSuggestion {
  final String id;
  final String title;
  final String detail;
  final SuggestionAction action;
  final CalendarEvent? event; // populated for addEvent action

  const CalendarSuggestion({
    required this.id,
    required this.title,
    required this.detail,
    this.action = SuggestionAction.info,
    this.event,
  });

  factory CalendarSuggestion.fromJson(Map<String, dynamic> json) {
    CalendarEvent? event;
    if (json['event'] is Map<String, dynamic>) {
      final e = json['event'] as Map<String, dynamic>;
      event = CalendarEvent(
        id: '',
        title: e['title'] as String? ?? '(event)',
        start: _parseLoose(e['start'] as String?),
        end: _parseLoose(e['end'] as String?),
      );
    }
    return CalendarSuggestion(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: json['title'] as String? ?? '',
      detail: json['detail'] as String? ?? '',
      action: switch (json['type'] as String?) {
        'add' => SuggestionAction.addEvent,
        'reply' => SuggestionAction.reply,
        _ => SuggestionAction.info,
      },
      event: event,
    );
  }

  static DateTime _parseLoose(String? s) {
    if (s == null) return DateTime.now();
    try { return DateTime.parse(s).toLocal(); } catch (_) { return DateTime.now(); }
  }
}
