import 'package:app/src/format/note_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatNoteTimestamp', () {
    test('renders YYYY-MM-DD HH:MM with zero padding and no UTC marker', () {
      expect(
        formatNoteTimestamp(DateTime(2026, 1, 2, 3, 4, 5)),
        '2026-01-02 03:04',
      );
    });

    test('renders a UTC instant as the local wall-clock time', () {
      final utc = DateTime.utc(2026, 9, 12, 10, 28);
      final l = utc.toLocal();
      final wallClock = DateTime(l.year, l.month, l.day, l.hour, l.minute);

      expect(formatNoteTimestamp(utc), formatNoteTimestamp(wallClock));
    });
  });

  group('formatNoteDate', () {
    test('renders YYYY-MM-DD with zero padding', () {
      expect(formatNoteDate(DateTime(2026, 1, 2, 23, 59)), '2026-01-02');
    });

    test('is the date part of formatNoteTimestamp', () {
      final dt = DateTime.utc(2026, 9, 12, 23, 30);
      expect(formatNoteTimestamp(dt), startsWith(formatNoteDate(dt)));
    });
  });

  group('formatClockTime', () {
    test('renders HH:MM with zero padding', () {
      expect(formatClockTime(DateTime(2026, 1, 2, 3, 4, 5)), '03:04');
    });

    test('is the time part of formatNoteTimestamp', () {
      final dt = DateTime.utc(2026, 9, 12, 23, 30);
      expect(formatNoteTimestamp(dt), endsWith(formatClockTime(dt)));
    });
  });

  group('formatRelativeNoteTime', () {
    final now = DateTime.utc(2026, 9, 12, 12, 0, 0);

    test('just now for less than a minute ago', () {
      expect(
        formatRelativeNoteTime(
          now.subtract(const Duration(seconds: 30)),
          now: now,
        ),
        'just now',
      );
    });

    test('singular minute', () {
      expect(
        formatRelativeNoteTime(
          now.subtract(const Duration(minutes: 1)),
          now: now,
        ),
        '1 minute ago',
      );
    });

    test('plural minutes', () {
      expect(
        formatRelativeNoteTime(
          now.subtract(const Duration(minutes: 5)),
          now: now,
        ),
        '5 minutes ago',
      );
    });

    test('singular hour', () {
      expect(
        formatRelativeNoteTime(
          now.subtract(const Duration(hours: 1)),
          now: now,
        ),
        '1 hour ago',
      );
    });

    test('plural hours', () {
      expect(
        formatRelativeNoteTime(
          now.subtract(const Duration(hours: 5)),
          now: now,
        ),
        '5 hours ago',
      );
    });

    test('singular day', () {
      expect(
        formatRelativeNoteTime(now.subtract(const Duration(days: 1)), now: now),
        '1 day ago',
      );
    });

    test('plural days', () {
      expect(
        formatRelativeNoteTime(now.subtract(const Duration(days: 3)), now: now),
        '3 days ago',
      );
    });

    test('falls back to the absolute timestamp beyond a week', () {
      final then = now.subtract(const Duration(days: 8));
      expect(formatRelativeNoteTime(then, now: now), formatNoteTimestamp(then));
    });

    test('falls back to the absolute timestamp for a future update time', () {
      // Clock skew between server and client can put updatedAt slightly (or
      // not so slightly) ahead of "now" — the negative diff must not read
      // as "just now".
      final future = now.add(const Duration(hours: 3));
      expect(
        formatRelativeNoteTime(future, now: now),
        formatNoteTimestamp(future),
      );
    });

    test('defaults `now` to the current instant', () {
      expect(
        formatRelativeNoteTime(
          DateTime.now().subtract(const Duration(seconds: 5)),
        ),
        'just now',
      );
    });
  });
}
