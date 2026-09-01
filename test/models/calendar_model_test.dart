import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cod/models/calendar_model.dart';

void main() {
  group('CalendarEvent.fromJson', () {
    test('parses a timed event', () {
      final json = {
        'id': 'evt1',
        'summary': 'Standup',
        'description': 'Daily sync',
        'location': 'Zoom',
        'start': {'dateTime': '2024-06-01T09:00:00Z'},
        'end': {'dateTime': '2024-06-01T09:30:00Z'},
        'colorId': '1',
      };
      final e = CalendarEvent.fromJson(json);
      expect(e.id, 'evt1');
      expect(e.title, 'Standup');
      expect(e.description, 'Daily sync');
      expect(e.location, 'Zoom');
      expect(e.isAllDay, isFalse);
      expect(e.color, const Color(0xFF7986CB));
    });

    test('parses an all-day event', () {
      final json = {
        'id': 'evt2',
        'summary': 'Holiday',
        'start': {'date': '2024-12-25'},
        'end': {'date': '2024-12-26'},
      };
      final e = CalendarEvent.fromJson(json);
      expect(e.isAllDay, isTrue);
      expect(e.start.year, 2024);
      expect(e.start.month, 12);
      expect(e.start.day, 25);
    });

    test('defaults title when summary missing', () {
      final e = CalendarEvent.fromJson({
        'id': 'x',
        'start': {'dateTime': '2024-06-01T09:00:00Z'},
        'end': {'dateTime': '2024-06-01T09:30:00Z'},
      });
      expect(e.title, '(no title)');
    });

    test('parses attendees emails', () {
      final json = {
        'id': 'evt3',
        'summary': 'Meeting',
        'start': {'dateTime': '2024-06-01T09:00:00Z'},
        'end': {'dateTime': '2024-06-01T09:30:00Z'},
        'attendees': [
          {'email': 'a@x.com'},
          {'email': 'b@x.com'},
          {'email': ''},
        ],
      };
      final e = CalendarEvent.fromJson(json);
      expect(e.attendees, ['a@x.com', 'b@x.com']);
    });
  });

  group('CalendarEvent.toJson', () {
    test('timed event serializes dateTime', () {
      final e = CalendarEvent(
        id: '1',
        title: 'Sync',
        start: DateTime.utc(2024, 6, 1, 9),
        end: DateTime.utc(2024, 6, 1, 9, 30),
      );
      final json = e.toJson();
      expect(json['summary'], 'Sync');
      expect((json['start'] as Map)['dateTime'], isNotNull);
      expect((json['start'] as Map).containsKey('date'), isFalse);
    });

    test('all-day event serializes date only', () {
      final e = CalendarEvent(
        id: '1',
        title: 'Holiday',
        start: DateTime(2024, 12, 25),
        end: DateTime(2024, 12, 26),
        isAllDay: true,
      );
      final json = e.toJson();
      expect((json['start'] as Map)['date'], '2024-12-25');
      expect((json['start'] as Map).containsKey('dateTime'), isFalse);
    });
  });

  group('CalendarEvent.timeLabel', () {
    test('all-day events show "All day"', () {
      final e = CalendarEvent(
        id: '1',
        title: 'x',
        start: DateTime(2024, 1, 1),
        end: DateTime(2024, 1, 2),
        isAllDay: true,
      );
      expect(e.timeLabel, 'All day');
    });

    test('timed events show start–end', () {
      final e = CalendarEvent(
        id: '1',
        title: 'x',
        start: DateTime(2024, 1, 1, 9, 5),
        end: DateTime(2024, 1, 1, 10, 15),
      );
      expect(e.timeLabel, '09:05 – 10:15');
    });
  });

  group('CalendarSuggestion.fromJson', () {
    test('parses info suggestion', () {
      final s = CalendarSuggestion.fromJson({
        'title': 'Prepare slides',
        'detail': 'For the review',
        'type': 'info',
      });
      expect(s.action, SuggestionAction.info);
      expect(s.title, 'Prepare slides');
      expect(s.event, isNull);
    });

    test('parses add-event suggestion with event', () {
      final s = CalendarSuggestion.fromJson({
        'title': 'Add lunch',
        'detail': 'With the team',
        'type': 'add',
        'event': {
          'title': 'Lunch',
          'start': '2024-06-01T12:00:00Z',
          'end': '2024-06-01T13:00:00Z',
        },
      });
      expect(s.action, SuggestionAction.addEvent);
      expect(s.event, isNotNull);
      expect(s.event!.title, 'Lunch');
    });

    test('parses reply suggestion', () {
      final s = CalendarSuggestion.fromJson({
        'title': 'Reply to email',
        'detail': 'Confirm attendance',
        'type': 'reply',
      });
      expect(s.action, SuggestionAction.reply);
    });
  });
}
