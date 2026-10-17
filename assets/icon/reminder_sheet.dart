import 'package:flutter/material.dart';
import 'notification_service.dart';

void showRemindersSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1E1E1E),
    builder: (ctx) => const RemindersSheet(),
  );
}

class RemindersSheet extends StatefulWidget {
  const RemindersSheet({super.key});

  @override
  State<RemindersSheet> createState() => _RemindersSheetState();
}

class _RemindersSheetState extends State<RemindersSheet> {
  ReminderSettings _s = ReminderSettings();
  bool _loaded = false;
  String _warning = "";

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await NotificationService.instance.load();
    if (!mounted) return;
    setState(() {
      _s = s;
      _loaded = true;
    });
  }

  // Maatram panni, permission kekkum, reminders-a schedule pannum
  Future<void> _update(VoidCallback change) async {
    setState(change);
    if (_s.waterOn || _s.walkOn) {
      final ok = await NotificationService.instance.requestPermission();
      if (!mounted) return;
      setState(() {
        _warning = ok
            ? ""
            : "Notification permission block aagirukku. Settings > Apps > FitPulse > Notifications ON pannunga";
      });
    }
    await NotificationService.instance.apply(_s);
  }

  String _hourLabel(int h) {
    final suffix = h >= 12 ? "PM" : "AM";
    final hh = (h % 12 == 0) ? 12 : h % 12;
    return "$hh $suffix";
  }

  String _timeLabel(int h, int m) {
    final suffix = h >= 12 ? "PM" : "AM";
    final hh = (h % 12 == 0) ? 12 : h % 12;
    return "$hh:${m.toString().padLeft(2, '0')} $suffix";
  }

  Widget _hourDropdown(int value, ValueChanged<int> onChanged) {
    return DropdownButton<int>(
      value: value,
      dropdownColor: Colors.grey[900],
      items: List<int>.generate(19, (i) => i + 5).map((int h) {
        return DropdownMenuItem<int>(value: h, child: Text(_hourLabel(h)));
      }).toList(),
      onChanged: (int? v) {
        if (v != null) onChanged(v);
      },
    );
  }

  Future<void> _pickWalkTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _s.walkHour, minute: _s.walkMinute),
    );
    if (picked == null) return;
    _update(() {
      _s.walkHour = picked.hour;
      _s.walkMinute = picked.minute;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: !_loaded
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Reminders",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),

                    // ---- Water ----
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Thanni kudikka reminder"),
                      subtitle: Text(
                          "${_hourLabel(_s.waterStartHour)} to ${_hourLabel(_s.waterEndHour)}, ovvoru ${_s.waterIntervalHours} manikku"),
                      value: _s.waterOn,
                      onChanged: (bool v) => _update(() => _s.waterOn = v),
                    ),
                    if (_s.waterOn)
                      Wrap(
                        spacing: 14,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          DropdownButton<int>(
                            value: _s.waterIntervalHours,
                            dropdownColor: Colors.grey[900],
                            items: [1, 2, 3].map((int h) {
                              return DropdownMenuItem<int>(
                                  value: h, child: Text("Every $h hr"));
                            }).toList(),
                            onChanged: (int? v) {
                              if (v != null) _update(() => _s.waterIntervalHours = v);
                            },
                          ),
                          const Text("From"),
                          _hourDropdown(_s.waterStartHour, (int v) {
                            _update(() {
                              _s.waterStartHour = v;
                              if (_s.waterEndHour < v) _s.waterEndHour = v;
                            });
                          }),
                          const Text("To"),
                          _hourDropdown(_s.waterEndHour, (int v) {
                            _update(() {
                              _s.waterEndHour = v;
                              if (_s.waterStartHour > v) _s.waterStartHour = v;
                            });
                          }),
                        ],
                      ),
                    const Divider(height: 28, color: Colors.white24),

                    // ---- Walk ----
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Nadakka reminder"),
                      subtitle: Text(
                          "Daily ${_timeLabel(_s.walkHour, _s.walkMinute)} ku"),
                      value: _s.walkOn,
                      onChanged: (bool v) => _update(() => _s.walkOn = v),
                    ),
                    if (_s.walkOn)
                      OutlinedButton.icon(
                        onPressed: _pickWalkTime,
                        icon: const Icon(Icons.access_time),
                        label: Text("Time: ${_timeLabel(_s.walkHour, _s.walkMinute)}"),
                      ),
                    const SizedBox(height: 14),

                    if (_warning.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(_warning,
                            style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                      ),

                    ElevatedButton.icon(
                      onPressed: () async {
                        final ok = await NotificationService.instance.requestPermission();
                        if (!mounted) return;
                        if (!ok) {
                          setState(() {
                            _warning =
                                "Notification permission block aagirukku. Settings > Apps > FitPulse > Notifications ON pannunga";
                          });
                          return;
                        }
                        await NotificationService.instance.showTest();
                      },
                      icon: const Icon(Icons.notifications_active),
                      label: const Text("Test notification"),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      "Note: Phone la FitPulse-ku Battery > Unrestricted vachaa reminders correct time-la varum.",
                      style: TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}