import 'package:flutter_test/flutter_test.dart';
import 'package:cod/models/calendar_model.dart';
import 'package:cod/state/calendar.dart';

void main() {
  group('CalendarState.eventsForDay', () {
    test('returns only events on the given day, sorted by start', () {
      final state = CalendarState(
        events: [
          CalendarEvent(
            id: 'later',
            title: 'Later',
            start: DateTime(2024, 6, 1, 14),
            end: DateTime(2024, 6, 1, 15),
          ),
          CalendarEvent(
            id: 'earlier',
            title: 'Earlier',
            start: DateTime(2024, 6, 1, 9),
            end: DateTime(2024, 6, 1, 10),
          ),
          CalendarEvent(
            id: 'other-day',
            title: 'Other day',
            start: DateTime(2024, 6, 2, 9),
            end: DateTime(2024, 6, 2, 10),
          ),
        ],
      );

      final day = state.eventsForDay(DateTime(2024, 6, 1));
      expect(day.length, 2);
      expect(day.first.id, 'earlier');
      expect(day.last.id, 'later');
    });

    test('returns empty list when no events match', () {
      final state = CalendarState(
        events: [
          CalendarEvent(
            id: 'x',
            title: 'x',
            start: DateTime(2024, 1, 1),
            end: DateTime(2024, 1, 1, 1),
          ),
        ],
      );
      expect(state.eventsForDay(DateTime(2024, 2, 1)), isEmpty);
    });
  });

  group('CalendarState.copyWith', () {
    test('updates fields and preserves others', () {
      final state = CalendarState(connected: true);
      final next = state.copyWith(loadingEvents: true);
      expect(next.connected, isTrue);
      expect(next.loadingEvents, isTrue);
      expect(next.events, isEmpty);
    });

    test('clearError resets the error', () {
      final state = CalendarState(error: 'boom');
      expect(state.copyWith(clearError: true).error, isNull);
      expect(state.copyWith(error: 'new').error, 'new');
    });
  });
}
