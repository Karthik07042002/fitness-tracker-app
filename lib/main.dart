import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:pedometer/pedometer.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

// ---------------------------------------------------------------
// Achievements list
// ---------------------------------------------------------------
class Achievement {
  final String id;
  final String title;
  final String desc;
  final IconData icon;
  const Achievement(this.id, this.title, this.desc, this.icon);
}

const List<Achievement> kAchievements = [
  Achievement("steps_1k", "First 1,000", "Oru naal la 1,000 steps nadanga", Icons.directions_walk),
  Achievement("steps_5k", "5K Walker", "Oru naal la 5,000 steps", Icons.directions_walk),
  Achievement("steps_10k", "10K Champion", "Oru naal la 10,000 steps", Icons.emoji_events),
  Achievement("target_hit", "Target Crusher", "Daily target achieve pannunga", Icons.flag),
  Achievement("streak_3", "3-Day Streak", "3 naal continuous-a target hit", Icons.local_fire_department),
  Achievement("streak_7", "7-Day Streak", "7 naal continuous-a target hit", Icons.whatshot),
  Achievement("week_30k", "Weekly 30K", "Oru vaaram la 30,000 steps", Icons.calendar_month),
  Achievement("first_run", "First Run", "Running-la 1 km mudinga", Icons.directions_run),
  Achievement("first_ride", "First Ride", "Cycling-la 10 nimisham", Icons.directions_bike),
  Achievement("long_30", "30-Min Workout", "Edhavadhu workout 30 nimisham", Icons.timer),
];

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FitPulse Tracker',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: Colors.lightGreenAccent,
      ),
      home: const TrackerScreen(),
    );
  }
}

class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  // ---------- Profile ----------
  String _username = "";
  double _heightCm = 170;
  double _weightKg = 65;

  // Stride length (meter) height-la irundhu
  double get _strideWalkM => _heightCm * 0.415 / 100;
  double get _strideRunM => _heightCm * 0.65 / 100;

  // ---------- Daily step counter ----------
  StreamSubscription<StepCount>? _stepSubscription;
  int _steps = 0;
  int _dailyTarget = 8000;
  int? _memBaseline;
  int? _lastRawSteps;
  String _pedometerStatus = "Waiting for steps... walk a few steps";
  bool _needsSettings = false;

  double get _caloriesBurned => _steps * _weightKg * 0.0006;
  double get _distanceKm => (_steps * _strideWalkM) / 1000;

  // ---------- History / streak / achievements ----------
  Map<String, int> _history = {};
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  int _streak = 0;
  String _lastTargetDate = "";
  Set<String> _unlocked = <String>{};

  // ---------- Indoor / Outdoor mode ----------
  String _modeSetting = "Auto"; // Auto, Outdoor, Indoor
  String _detectedMode = "Indoor";
  Timer? _envTimer;
  int _goodCount = 0;
  int _badCount = 0;
  bool _firstCheck = true;

  String get _trackMode => _modeSetting == "Auto" ? _detectedMode : _modeSetting;

  // ---------- Workout session ----------
  String _activity = "Walking";
  bool _sessionActive = false;
  String _sessionMode = "Indoor";
  int _sessionSeconds = 0;
  int _sessionSteps = 0;
  int? _sessionStartRaw;
  double _gpsDistanceMeters = 0.0;
  double _liveSpeedKmh = 0.0;
  List<Position> _route = <Position>[];
  StreamSubscription<Position>? _positionSubscription;
  Position? _previousPosition;
  Timer? _sessionTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadStoredData();
    await _requestPermissions();
    _initPedometer();
    _startEnvironmentMonitor();
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- Date helpers ----------
  String _dateKey(DateTime d) {
    return "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";
  }

  String _todayKey() => _dateKey(DateTime.now());

  // ---------- Storage ----------
  Future<SharedPreferences?> _getPrefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint("Prefs error: $e");
      return null;
    }
  }

  Future<void> _loadStoredData() async {
    final prefs = await _getPrefs();
    if (prefs == null || !mounted) return;

    Map<String, int> hist = {};
    final raw = prefs.getString('stepsHistory');
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        hist = m.map((k, v) => MapEntry(k, (v as num).toInt()));
      } catch (e) {
        debugPrint("History parse error: $e");
      }
    }

    setState(() {
      _dailyTarget = prefs.getInt('dailyTarget') ?? 8000;
      _username = prefs.getString('username') ?? "";
      _heightCm = prefs.getDouble('heightCm') ?? 170;
      _weightKg = prefs.getDouble('weightKg') ?? 65;
      _streak = prefs.getInt('streak') ?? 0;
      _lastTargetDate = prefs.getString('lastTargetDate') ?? "";
      _unlocked = (prefs.getStringList('badges') ?? <String>[]).toSet();
      _history = hist;

      // Streak odanjuduchaa (neththu or indru target hit illa) 0 aakkum
      final yesterday = _dateKey(DateTime.now().subtract(const Duration(days: 1)));
      if (_lastTargetDate != _todayKey() && _lastTargetDate != yesterday) {
        _streak = 0;
      }
    });
  }

  Future<void> _saveProfile() async {
    final prefs = await _getPrefs();
    if (prefs == null) return;
    await prefs.setString('username', _username);
    await prefs.setDouble('heightCm', _heightCm);
    await prefs.setDouble('weightKg', _weightKg);
  }

  Future<void> _saveDailyTarget(int target) async {
    setState(() {
      _dailyTarget = target;
    });
    final prefs = await _getPrefs();
    await prefs?.setInt('dailyTarget', target);
  }

  Future<void> _saveAchievements() async {
    final prefs = await _getPrefs();
    await prefs?.setStringList('badges', _unlocked.toList());
  }

  Future<void> _saveStreak() async {
    final prefs = await _getPrefs();
    await prefs?.setInt('streak', _streak);
    await prefs?.setString('lastTargetDate', _lastTargetDate);
  }

  // Indru steps-a history la save pannum (10 sec ku oru dhadavai)
  Future<void> _recordDailySteps() async {
    _history[_todayKey()] = _steps;
    final now = DateTime.now();
    if (now.difference(_lastSave).inSeconds < 10) return;
    _lastSave = now;

    final cutoff = _dateKey(now.subtract(const Duration(days: 30)));
    _history.removeWhere((k, v) => k.compareTo(cutoff) < 0);

    final prefs = await _getPrefs();
    await prefs?.setString('stepsHistory', jsonEncode(_history));
  }

  // ---------- Permissions ----------
  Future<void> _requestPermissions() async {
    try {
      final activity = await Permission.activityRecognition.request();
      await Permission.locationWhenInUse.request();
      if (!mounted) return;
      if (activity.isPermanentlyDenied) {
        setState(() {
          _needsSettings = true;
          _pedometerStatus =
              "Physical activity permission blocked. 'Open settings' tap pannunga";
        });
      } else if (!activity.isGranted) {
        setState(() {
          _pedometerStatus = "Physical activity permission not granted";
        });
      }
    } catch (e) {
      debugPrint("Permission error: $e");
      if (!mounted) return;
      setState(() {
        _pedometerStatus = "Permission error: $e";
      });
    }
  }

  // ---------- Step counter ----------
  void _initPedometer() {
    try {
      _stepSubscription?.cancel();
      _stepSubscription = Pedometer.stepCountStream.listen(
        _onStepCount,
        onError: _onStepCountError,
        cancelOnError: false,
      );
    } catch (e) {
      _onStepCountError(e);
    }
  }

  // event.steps = phone reboot aanadhula irundhu mothama steps
  Future<void> _onStepCount(StepCount event) async {
    int baseline;
    try {
      final prefs = await SharedPreferences.getInstance();
      final today = _todayKey();
      final savedDate = prefs.getString('baselineDate');
      final savedBaseline = prefs.getInt('baselineSteps');

      if (savedDate != today || savedBaseline == null) {
        baseline = event.steps;
      } else if (event.steps < savedBaseline) {
        baseline = 0; // phone reboot aachu
      } else {
        baseline = savedBaseline;
      }

      if (baseline != savedBaseline || savedDate != today) {
        await prefs.setString('baselineDate', today);
        await prefs.setInt('baselineSteps', baseline);
      }
    } catch (e) {
      _memBaseline ??= event.steps;
      baseline = _memBaseline!;
    }

    if (!mounted) return;
    setState(() {
      _lastRawSteps = event.steps;
      _steps = event.steps - baseline;
      _pedometerStatus = "";

      if (_sessionActive && _sessionStartRaw != null) {
        final diff = event.steps - _sessionStartRaw!;
        _sessionSteps = diff < 0 ? 0 : diff;
      }
    });

    _recordDailySteps();
    _checkDailyAchievements();
  }

  void _onStepCountError(error) {
    debugPrint("Pedometer Error: $error");
    if (!mounted) return;
    setState(() {
      _pedometerStatus = "Step sensor error: $error";
    });
  }

  // ---------- Achievements ----------
  int _weekTotal() {
    int total = 0;
    for (int i = 0; i < 7; i++) {
      final key = _dateKey(DateTime.now().subtract(Duration(days: i)));
      total += (i == 0) ? _steps : (_history[key] ?? 0);
    }
    return total;
  }

  void _updateStreak() {
    final today = _todayKey();
    if (_lastTargetDate == today) return;
    final yesterday = _dateKey(DateTime.now().subtract(const Duration(days: 1)));
    _streak = (_lastTargetDate == yesterday) ? _streak + 1 : 1;
    _lastTargetDate = today;
    _saveStreak();
    if (mounted) setState(() {});
  }

  void _unlock(String id) {
    if (_unlocked.contains(id)) return;
    _unlocked.add(id);
    _saveAchievements();
    final a = kAchievements.firstWhere((x) => x.id == id);
    _showMsg("Achievement unlocked: ${a.title}");
  }

  void _checkDailyAchievements() {
    if (_steps >= 1000) _unlock("steps_1k");
    if (_steps >= 5000) _unlock("steps_5k");
    if (_steps >= 10000) _unlock("steps_10k");
    if (_steps >= _dailyTarget && _steps > 0) {
      _unlock("target_hit");
      _updateStreak();
    }
    if (_streak >= 3) _unlock("streak_3");
    if (_streak >= 7) _unlock("streak_7");
    if (_weekTotal() >= 30000) _unlock("week_30k");
  }

  // ---------- Auto indoor / outdoor detection ----------
  void _startEnvironmentMonitor() {
    _checkEnvironment();
    _envTimer?.cancel();
    _envTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _checkEnvironment();
    });
  }

  Future<void> _checkEnvironment() async {
    if (_modeSetting != "Auto" || _sessionActive) return;

    bool goodFix = false;
    try {
      final serviceOn = await Geolocator.isLocationServiceEnabled();
      final perm = await Geolocator.checkPermission();
      final allowed = perm == LocationPermission.whileInUse ||
          perm == LocationPermission.always;
      if (serviceOn && allowed) {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        );
        goodFix = pos.accuracy <= 25;
      }
    } catch (e) {
      goodFix = false;
    }

    if (goodFix) {
      _goodCount++;
      _badCount = 0;
    } else {
      _badCount++;
      _goodCount = 0;
    }

    final needed = _firstCheck ? 1 : 2;
    _firstCheck = false;

    if (!mounted) return;
    if (_goodCount >= needed && _detectedMode != "Outdoor") {
      setState(() {
        _detectedMode = "Outdoor";
      });
    } else if (_badCount >= needed && _detectedMode != "Indoor") {
      setState(() {
        _detectedMode = "Indoor";
      });
    }
  }

  // ---------- Workout session ----------
  double get _met {
    if (_activity == "Running") return 9.8;
    if (_activity == "Cycling") return 7.5;
    return 3.5;
  }

  double get _sessionCalories => _met * _weightKg * (_sessionSeconds / 3600.0);

  double _sessionDistanceKm(String mode) {
    if (mode == "Outdoor") return _gpsDistanceMeters / 1000;
    if (_activity == "Cycling") return 0.0;
    final stride = _activity == "Running" ? _strideRunM : _strideWalkM;
    return (_sessionSteps * stride) / 1000;
  }

  String _sessionDistanceText(String mode) {
    if (mode != "Outdoor" && _activity == "Cycling") return "--";
    return "${_sessionDistanceKm(mode).toStringAsFixed(2)} km";
  }

  String _speedText(String mode) {
    if (mode == "Outdoor") {
      return "${_liveSpeedKmh.toStringAsFixed(1)} km/h";
    }
    if (_activity == "Cycling") return "--";
    final km = _sessionDistanceKm(mode);
    if (_sessionSeconds < 5 || km <= 0) return "0.0 km/h";
    final v = km / (_sessionSeconds / 3600.0);
    return "${v.toStringAsFixed(1)} km/h";
  }

  String _formatTime(int totalSeconds) {
    final m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return "$m:$s";
  }

  IconData _activityIcon(String a) {
    if (a == "Running") return Icons.directions_run;
    if (a == "Cycling") return Icons.directions_bike;
    return Icons.directions_walk;
  }

  Future<bool> _startGps() async {
    try {
      final serviceOn = await Geolocator.isLocationServiceEnabled();
      if (!serviceOn) {
        _showMsg("Phone-la Location (GPS) ON pannunga");
        return false;
      }

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        _showMsg(
            "Location permission kudunga: Settings > Apps > FitPulse > Permissions");
        return false;
      }

      _gpsDistanceMeters = 0.0;
      _previousPosition = null;
      _liveSpeedKmh = 0.0;

      const locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      );

      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen(
        (Position position) {
          // Mosamaana GPS reading-a ignore pannum
          if (position.accuracy > 30) return;
          setState(() {
            if (_previousPosition != null) {
              _gpsDistanceMeters += Geolocator.distanceBetween(
                _previousPosition!.latitude,
                _previousPosition!.longitude,
                position.latitude,
                position.longitude,
              );
            }
            _route.add(position);
            _liveSpeedKmh = position.speed >= 0 ? position.speed * 3.6 : 0.0;
          });
          _previousPosition = position;
        },
        onError: (e) {
          debugPrint("GPS error: $e");
          _showMsg("GPS error: $e");
        },
      );
      return true;
    } catch (e) {
      debugPrint("GPS start error: $e");
      _showMsg("GPS start aagala: $e");
      return false;
    }
  }

  Future<void> _startSession() async {
    final mode = _trackMode;
    _route = <Position>[];

    if (mode == "Outdoor") {
      final ok = await _startGps();
      if (!ok) return;
    } else if (_activity != "Cycling" && _lastRawSteps == null) {
      _showMsg("Step sensor innum ready aagala. Konjam nadandhu paarunga");
      return;
    }

    if (!mounted) return;
    setState(() {
      _sessionActive = true;
      _sessionMode = mode;
      _sessionSeconds = 0;
      _sessionSteps = 0;
      _sessionStartRaw = _lastRawSteps;
    });

    _sessionTimer?.cancel();
    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _sessionSeconds++;
      });
    });
  }

  Future<void> _stopSession() async {
    final mode = _sessionMode;
    final km = _sessionDistanceKm(mode);
    final mins = _sessionSeconds / 60.0;
    final act = _activity;

    _sessionTimer?.cancel();
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _previousPosition = null;
    if (!mounted) return;
    setState(() {
      _sessionActive = false;
      _liveSpeedKmh = 0.0;
    });

    if (act == "Running" && km >= 1.0) _unlock("first_run");
    if (act == "Cycling" && mins >= 10) _unlock("first_ride");
    if (mins >= 30) _unlock("long_30");
  }

  @override
  void dispose() {
    _stepSubscription?.cancel();
    _positionSubscription?.cancel();
    _sessionTimer?.cancel();
    _envTimer?.cancel();
    super.dispose();
  }

  // ---------- Dialogs ----------
  Future<void> _showProfileDialog() async {
    final nameC = TextEditingController(text: _username);
    final hC = TextEditingController(text: _heightCm.toStringAsFixed(0));
    final wC = TextEditingController(text: _weightKg.toStringAsFixed(0));

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text("My Profile"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameC,
                  decoration: const InputDecoration(labelText: "Username"),
                ),
                TextField(
                  controller: hC,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: "Height (cm)"),
                ),
                TextField(
                  controller: wC,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: "Weight (kg)"),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                final h = double.tryParse(hC.text.trim());
                final w = double.tryParse(wC.text.trim());
                if (h == null || h < 100 || h > 250) {
                  _showMsg("Height 100-250 cm kulla kudunga");
                  return;
                }
                if (w == null || w < 20 || w > 300) {
                  _showMsg("Weight 20-300 kg kulla kudunga");
                  return;
                }
                setState(() {
                  _username = nameC.text.trim();
                  _heightCm = h;
                  _weightKg = w;
                });
                _saveProfile();
                Navigator.pop(ctx);
              },
              child: const Text("Save"),
            ),
          ],
        );
      },
    );
  }

  void _showAchievements() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Achievements (${_unlocked.length}/${kAchievements.length})",
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: kAchievements.map((a) {
                      final done = _unlocked.contains(a.id);
                      return ListTile(
                        leading: Icon(a.icon,
                            size: 32, color: done ? Colors.amber : Colors.grey),
                        title: Text(a.title,
                            style: TextStyle(color: done ? Colors.white : Colors.grey)),
                        subtitle: Text(a.desc),
                        trailing: Icon(
                          done ? Icons.check_circle : Icons.lock_outline,
                          color: done ? Colors.lightGreenAccent : Colors.grey,
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    double percent = (_steps / _dailyTarget).clamp(0.0, 1.0);

    return Scaffold(
      appBar: AppBar(
        title: Text(_username.isEmpty ? "FitPulse Tracker" : "Hi, $_username"),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.emoji_events, color: Colors.amber),
            tooltip: "Achievements",
            onPressed: _showAchievements,
          ),
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: "Profile",
            onPressed: _showProfileDialog,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            CircularPercentIndicator(
              radius: 110.0,
              lineWidth: 15.0,
              animation: true,
              percent: percent,
              center: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.directions_walk, size: 40, color: Colors.lightGreenAccent),
                  Text("$_steps", style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                  Text("Target: $_dailyTarget steps", style: const TextStyle(color: Colors.grey)),
                ],
              ),
              circularStrokeCap: CircularStrokeCap.round,
              progressColor: Colors.lightGreenAccent,
              backgroundColor: Colors.white12,
            ),
            if (_streak > 0)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.local_fire_department, color: Colors.orangeAccent, size: 20),
                    const SizedBox(width: 4),
                    Text("$_streak day streak",
                        style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            if (_pedometerStatus.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _pedometerStatus,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
                ),
              ),
            if (_needsSettings)
              TextButton(
                onPressed: () => openAppSettings(),
                child: const Text("Open settings"),
              ),
            const SizedBox(height: 25),
            Row(
              children: [
                _buildStatCard(
                  title: "Calories",
                  value: "${_caloriesBurned.toStringAsFixed(1)} kcal",
                  icon: Icons.local_fire_department,
                  color: Colors.orangeAccent,
                ),
                const SizedBox(width: 15),
                _buildStatCard(
                  title: "Distance",
                  value: "${_distanceKm.toStringAsFixed(2)} km",
                  icon: Icons.straighten,
                  color: Colors.lightBlueAccent,
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildWeekCard(),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Set Target Steps:", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                DropdownButton<int>(
                  value: _dailyTarget,
                  dropdownColor: Colors.grey[900],
                  items: [5000, 8000, 10000, 12000, 15000].map((int val) {
                    return DropdownMenuItem<int>(
                      value: val,
                      child: Text("$val Steps"),
                    );
                  }).toList(),
                  onChanged: (newTarget) {
                    if (newTarget != null) _saveDailyTarget(newTarget);
                  },
                )
              ],
            ),
            const Divider(height: 40, color: Colors.white24),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text("Workout Tracker", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              children: ["Walking", "Running", "Cycling"].map((String a) {
                return ChoiceChip(
                  avatar: Icon(_activityIcon(a), size: 18),
                  label: Text(a),
                  selected: _activity == a,
                  onSelected: _sessionActive
                      ? null
                      : (bool v) {
                          setState(() {
                            _activity = a;
                          });
                        },
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              children: ["Auto", "Outdoor", "Indoor"].map((String m) {
                return ChoiceChip(
                  label: Text(m),
                  selected: _modeSetting == m,
                  onSelected: _sessionActive
                      ? null
                      : (bool v) {
                          setState(() {
                            _modeSetting = m;
                          });
                          if (m == "Auto") {
                            _firstCheck = true;
                            _checkEnvironment();
                          }
                        },
                );
              }).toList(),
            ),
            if (_modeSetting == "Auto")
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _detectedMode == "Outdoor"
                      ? "Auto: Outdoor detect aachu (GPS fix kidaichiduchu)"
                      : "Auto: Indoor detect aachu (GPS fix illa)",
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
            const SizedBox(height: 15),
            _buildWorkoutCard(),
            if (_route.length >= 2) ...[
              const SizedBox(height: 15),
              _buildRouteCard(),
            ],
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _buildWeekCard() {
    final days = List<DateTime>.generate(
        7, (i) => DateTime.now().subtract(Duration(days: 6 - i)));
    final values = days.map((d) {
      final k = _dateKey(d);
      return k == _todayKey() ? _steps : (_history[k] ?? 0);
    }).toList();

    int maxSteps = _dailyTarget;
    for (final v in values) {
      if (v > maxSteps) maxSteps = v;
    }
    final total = values.fold<int>(0, (a, b) => a + b);
    const labels = ["M", "T", "W", "T", "F", "S", "S"];

    return Card(
      color: Colors.white10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("This Week", style: TextStyle(fontWeight: FontWeight.bold)),
                Text("$total steps", style: const TextStyle(color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(7, (i) {
                final h = 80.0 * (values[i] / maxSteps);
                final hit = values[i] >= _dailyTarget;
                return Column(
                  children: [
                    Text("${values[i]}",
                        style: const TextStyle(fontSize: 9, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Container(
                      width: 22,
                      height: h < 3 ? 3 : h,
                      decoration: BoxDecoration(
                        color: hit ? Colors.lightGreenAccent : Colors.white24,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(labels[days[i].weekday - 1],
                        style: const TextStyle(fontSize: 12)),
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkoutCard() {
    final String shownMode = _sessionActive ? _sessionMode : _trackMode;
    final bool gps = shownMode == "Outdoor";
    final bool showSteps = _activity != "Cycling";

    String info;
    if (gps) {
      info = "Outdoor: GPS distance and speed use aagum";
    } else if (_activity == "Cycling") {
      info = "Indoor cycling: time vachu calories (distance theriyaadhu)";
    } else {
      info = "Indoor: step sensor use aagum";
    }

    return Card(
      color: Colors.white10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text("$_activity - $shownMode",
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(info,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.spaceAround,
              spacing: 22,
              runSpacing: 12,
              children: [
                if (showSteps) _miniStat("Steps", "$_sessionSteps"),
                _miniStat("Distance", _sessionDistanceText(shownMode)),
                _miniStat("Speed", _speedText(shownMode)),
                _miniStat("Calories", _sessionCalories.toStringAsFixed(1)),
              ],
            ),
            const SizedBox(height: 12),
            Text("Time  ${_formatTime(_sessionSeconds)}",
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 15),
            ElevatedButton.icon(
              onPressed: () {
                if (_sessionActive) {
                  _stopSession();
                } else {
                  _startSession();
                }
              },
              icon: Icon(_sessionActive ? Icons.stop : Icons.play_arrow),
              label: Text(_sessionActive ? "Stop" : "Start $_activity"),
              style: ElevatedButton.styleFrom(
                backgroundColor: _sessionActive ? Colors.redAccent : Colors.green,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteCard() {
    return Card(
      color: Colors.white10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.route, size: 18),
                const SizedBox(width: 8),
                const Text("Route", style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text("${(_gpsDistanceMeters / 1000).toStringAsFixed(2)} km",
                    style: const TextStyle(color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              height: 200,
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF1B1B1B),
                borderRadius: BorderRadius.circular(12),
              ),
              child: CustomPaint(
                size: Size.infinite,
                painter: RoutePainter(_route),
              ),
            ),
            const SizedBox(height: 6),
            const Text("Green = start, Red = ippo irukkura idam",
                style: TextStyle(color: Colors.grey, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _miniStat(String title, String value) {
    return Column(
      children: [
        Text(title, style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildStatCard({required String title, required String value, required IconData icon, required Color color}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 30),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(color: Colors.grey, fontSize: 14)),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------
// Route painter: GPS points-a screen la line-a varaiyum (map tiles illa)
// ---------------------------------------------------------------
class RoutePainter extends CustomPainter {
  final List<Position> points;
  RoutePainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    double minLat = points.first.latitude;
    double maxLat = minLat;
    double minLon = points.first.longitude;
    double maxLon = minLon;
    for (final p in points) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLon = math.min(minLon, p.longitude);
      maxLon = math.max(maxLon, p.longitude);
    }

    final cosLat = math.cos(((minLat + maxLat) / 2) * math.pi / 180);
    final w = (maxLon - minLon) * cosLat;
    final h = maxLat - minLat;
    if (w <= 0 && h <= 0) return;

    const pad = 20.0;
    final availW = size.width - 2 * pad;
    final availH = size.height - 2 * pad;
    if (availW <= 0 || availH <= 0) return;

    final scaleW = w > 0 ? availW / w : double.infinity;
    final scaleH = h > 0 ? availH / h : double.infinity;
    final scale = math.min(scaleW, scaleH);
    final offX = pad + (availW - w * scale) / 2;
    final offY = pad + (availH - h * scale) / 2;

    Offset project(Position p) {
      return Offset(
        offX + (p.longitude - minLon) * cosLat * scale,
        offY + (maxLat - p.latitude) * scale,
      );
    }

    final path = Path();
    final first = project(points.first);
    path.moveTo(first.dx, first.dy);
    for (int i = 1; i < points.length; i++) {
      final o = project(points[i]);
      path.lineTo(o.dx, o.dy);
    }

    final linePaint = Paint()
      ..color = Colors.lightGreenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);

    canvas.drawCircle(first, 7, Paint()..color = Colors.green);
    canvas.drawCircle(project(points.last), 7, Paint()..color = Colors.redAccent);
  }

  @override
  bool shouldRepaint(covariant RoutePainter oldDelegate) => true;
}