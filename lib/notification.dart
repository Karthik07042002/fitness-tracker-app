import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// Reminder settings (phone-la save aagum)
class ReminderSettings {
  bool waterOn;
  int waterIntervalHours;
  int waterStartHour;
  int waterEndHour;
  bool walkOn;
  int walkHour;
  int walkMinute;

  ReminderSettings({
    this.waterOn = false,
    this.waterIntervalHours = 2,
    this.waterStartHour = 8,
    this.waterEndHour = 21,
    this.walkOn = false,
    this.walkHour = 17,
    this.walkMinute = 30,
  });
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const int _waterBaseId = 100;
  static const int _walkId = 200;

  Future<void> init() async {
    if (_ready) return;
    try {
      tzdata.initializeTimeZones();
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(const InitializationSettings(android: androidInit));
      _ready = true;
    } catch (e) {
      debugPrint("Notification init error: $e");
    }
  }

  Future<bool> requestPermission() async {
    await init();
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission();
      return granted ?? true;
    } catch (e) {
      debugPrint("Notification permission error: $e");
      return false;
    }
  }

  // ---------- Save / load ----------
  Future<ReminderSettings> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      return ReminderSettings(
        waterOn: p.getBool('rem_waterOn') ?? false,
        waterIntervalHours: p.getInt('rem_waterInt') ?? 2,
        waterStartHour: p.getInt('rem_waterStart') ?? 8,
        waterEndHour: p.getInt('rem_waterEnd') ?? 21,
        walkOn: p.getBool('rem_walkOn') ?? false,
        walkHour: p.getInt('rem_walkH') ?? 17,
        walkMinute: p.getInt('rem_walkM') ?? 30,
      );
    } catch (e) {
      debugPrint("Reminder load error: $e");
      return ReminderSettings();
    }
  }

  Future<void> _save(ReminderSettings s) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('rem_waterOn', s.waterOn);
      await p.setInt('rem_waterInt', s.waterIntervalHours);
      await p.setInt('rem_waterStart', s.waterStartHour);
      await p.setInt('rem_waterEnd', s.waterEndHour);
      await p.setBool('rem_walkOn', s.walkOn);
      await p.setInt('rem_walkH', s.walkHour);
      await p.setInt('rem_walkM', s.walkMinute);
    } catch (e) {
      debugPrint("Reminder save error: $e");
    }
  }

  // ---------- Scheduling ----------
  // Phone-oda local time-a UTC instant-a maathi, daily repeat pannum
  tz.TZDateTime _nextInstance(int hour, int minute) {
    final now = DateTime.now();
    var local = DateTime(now.year, now.month, now.day, hour, minute);
    if (!local.isAfter(now)) {
      local = local.add(const Duration(days: 1));
    }
    final u = local.toUtc();
    return tz.TZDateTime.utc(u.year, u.month, u.day, u.hour, u.minute);
  }

  NotificationDetails _details(String channelId, String channelName, String desc) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: desc,
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
  }

  Future<void> _scheduleDaily(
    int id,
    int hour,
    int minute,
    String title,
    String body,
    NotificationDetails details,
  ) async {
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      _nextInstance(hour, minute),
      details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  // Settings-a save panni, reminders-a schedule pannum
  Future<void> apply(ReminderSettings s) async {
    await _save(s);
    await init();
    if (!_ready) return;

    try {
      for (int i = 0; i < 24; i++) {
        await _plugin.cancel(_waterBaseId + i);
      }
      await _plugin.cancel(_walkId);

      if (s.waterOn) {
        final water = _details('water_channel', 'Water reminders', 'Thanni kudikka reminders');
        int id = _waterBaseId;
        for (int h = s.waterStartHour; h <= s.waterEndHour; h += s.waterIntervalHours) {
          if (id >= _waterBaseId + 24) break;
          await _scheduleDaily(
            id++,
            h,
            0,
            "Thanni kudikka neram",
            "Oru glass thanni kudinga. Udambu hydrate-a irukkattum!",
            water,
          );
        }
      }

      if (s.walkOn) {
        final walk = _details('walk_channel', 'Walk reminders', 'Nadakka reminders');
        await _scheduleDaily(
          _walkId,
          s.walkHour,
          s.walkMinute,
          "Nadakka neram",
          "Indru target-ku nadanga. FitPulse open pannunga!",
          walk,
        );
      }
    } catch (e) {
      debugPrint("Schedule error: $e");
    }
  }

  // App start aagumbodhu saved reminders-a thirumba schedule pannum
  Future<void> applySavedSettings() async {
    final s = await load();
    if (s.waterOn || s.walkOn) {
      await apply(s);
    }
  }

  Future<void> showTest() async {
    await init();
    if (!_ready) return;
    try {
      await _plugin.show(
        999,
        "FitPulse",
        "Reminder work aagudhu!",
        _details('test_channel', 'Test', 'Test notifications'),
      );
    } catch (e) {
      debugPrint("Test notification error: $e");
    }
  }
}