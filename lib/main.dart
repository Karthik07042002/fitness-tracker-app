import 'dart:async';
import 'package:flutter/material.dart';
import 'package:pedometer/pedometer.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

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
  // Step Counter Variables
  StreamSubscription<StepCount>? _stepSubscription;
  int _steps = 0;
  int _dailyTarget = 8000;
  String _pedometerStatus = "Waiting for steps... walk a few steps";

  // Calorie & Distance Variables
  double _caloriesBurned = 0.0;
  double _distanceKm = 0.0;

  // Outdoor Tracking (Running/Cycling)
  bool _isTrackingGps = false;
  double _gpsDistanceMeters = 0.0;
  StreamSubscription<Position>? _positionSubscription;
  Position? _previousPosition;
  String _activeMode = "Walking";

  @override
  void initState() {
    super.initState();
    _init();
  }

  // Permission mudiyara varaikkum pedometer start aagaadhu
  Future<void> _init() async {
    await _requestPermissions();
    await _loadDailyTarget();
    _initPedometer();
  }

  Future<void> _requestPermissions() async {
    final activity = await Permission.activityRecognition.request();
    await Permission.locationWhenInUse.request();
    if (!activity.isGranted && mounted) {
      setState(() {
        _pedometerStatus = "Physical activity permission not granted";
      });
    }
  }

  Future<void> _loadDailyTarget() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _dailyTarget = prefs.getInt('dailyTarget') ?? 8000;
    });
  }

  Future<void> _saveDailyTarget(int target) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('dailyTarget', target);
    setState(() {
      _dailyTarget = target;
    });
  }

  void _initPedometer() {
    _stepSubscription?.cancel();
    _stepSubscription = Pedometer.stepCountStream.listen(
      _onStepCount,
      onError: _onStepCountError,
      cancelOnError: false,
    );
  }

  String _todayKey() {
    final now = DateTime.now();
    return "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
  }

  // event.steps = phone reboot aanadhula irundhu mothama steps.
  // Adhunaala indru-oda baseline-a minus pannanum.
  Future<void> _onStepCount(StepCount event) async {
    final prefs = await SharedPreferences.getInstance();
    final today = _todayKey();

    final savedDate = prefs.getString('baselineDate');
    int? baseline = prefs.getInt('baselineSteps');

    // Puthu naal, first run, or phone reboot aanaa baseline reset
    if (savedDate != today || baseline == null || event.steps < baseline) {
      baseline = (savedDate == today && baseline != null) ? 0 : event.steps;
      await prefs.setString('baselineDate', today);
      await prefs.setInt('baselineSteps', baseline);
    }

    if (!mounted) return;
    setState(() {
      _steps = event.steps - baseline!;
      _pedometerStatus = "";
      _calculateMetrics();
    });
  }

  void _onStepCountError(error) {
    debugPrint("Pedometer Error: $error");
    if (!mounted) return;
    setState(() {
      _pedometerStatus = "Step sensor error: $error";
    });
  }

  void _calculateMetrics() {
    _distanceKm = (_steps * 0.75) / 1000;
    _caloriesBurned = _steps * 0.04;
  }

  void _toggleGpsTracking(String mode) {
    if (_isTrackingGps) {
      _positionSubscription?.cancel();
      setState(() {
        _isTrackingGps = false;
        _previousPosition = null;
      });
    } else {
      setState(() {
        _isTrackingGps = true;
        _activeMode = mode;
        _gpsDistanceMeters = 0.0;
      });

      const locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      );

      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen((Position position) {
        if (_previousPosition != null) {
          double distanceInMeters = Geolocator.distanceBetween(
            _previousPosition!.latitude,
            _previousPosition!.longitude,
            position.latitude,
            position.longitude,
          );
          setState(() {
            _gpsDistanceMeters += distanceInMeters;
          });
        }
        _previousPosition = position;
      });
    }
  }

  double _calculateGpsCalories() {
    double distanceInKm = _gpsDistanceMeters / 1000;
    double met = (_activeMode == "Cycling") ? 7.5 : 9.8;
    return distanceInKm * met * 1.036;
  }

  @override
  void dispose() {
    _stepSubscription?.cancel();
    _positionSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double percent = (_steps / _dailyTarget).clamp(0.0, 1.0);

    return Scaffold(
      appBar: AppBar(
        title: const Text("FitPulse Tracker"),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
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
            if (_pedometerStatus.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _pedometerStatus,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
                ),
              ),
            const SizedBox(height: 30),
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
            const SizedBox(height: 30),
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
            Align(
              alignment: Alignment.centerLeft,
              child: Text("Outdoor Tracker ($_activeMode)", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 15),
            Card(
              color: Colors.white10,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Column(
                          children: [
                            const Text("GPS Distance", style: TextStyle(color: Colors.grey)),
                            Text("${(_gpsDistanceMeters / 1000).toStringAsFixed(2)} km", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Column(
                          children: [
                            const Text("Activity Cal", style: TextStyle(color: Colors.grey)),
                            Text("${_calculateGpsCalories().toStringAsFixed(1)} kcal", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 15),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed: _isTrackingGps ? null : () => _toggleGpsTracking("Running"),
                          icon: const Icon(Icons.directions_run),
                          label: const Text("Run"),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton.icon(
                          onPressed: _isTrackingGps ? null : () => _toggleGpsTracking("Cycling"),
                          icon: const Icon(Icons.directions_bike),
                          label: const Text("Cycle"),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                        ),
                        const SizedBox(width: 10),
                        if (_isTrackingGps)
                          ElevatedButton.icon(
                            onPressed: () => _toggleGpsTracking(_activeMode),
                            icon: const Icon(Icons.stop),
                            label: const Text("Stop"),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                          ),
                      ],
                    )
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
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