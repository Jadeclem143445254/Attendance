import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  final frontCamera = cameras.firstWhere(
    (c) => c.lensDirection == CameraLensDirection.front,
    orElse: () => cameras.first,
  );
  runApp(SVTIApp(camera: frontCamera));
}

class SVTIApp extends StatelessWidget {
  final CameraDescription camera;
  const SVTIApp({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SVTI Attendance',
      theme: ThemeData(
        primaryColor: const Color(0xFF0D47A1),
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      ),
      home: AuthWrapper(camera: camera),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  final CameraDescription camera;
  const AuthWrapper({super.key, required this.camera});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _isLoggedIn = false;
  String _userName = "";
  String _userPhone = "";
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _userName = prefs.getString('userName') ?? "";
      _userPhone = prefs.getString('userPhone') ?? "";
      _isLoggedIn = _userName.isNotEmpty && _userPhone.isNotEmpty;
      _isLoading = false;
    });
  }

  void _onLoginSuccess(String name, String phone) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('userName', name);
    await prefs.setString('userPhone', phone);
    setState(() {
      _userName = name;
      _userPhone = phone;
      _isLoggedIn = true;
    });
  }

  void _onLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    setState(() {
      _isLoggedIn = false;
      _userName = "";
      _userPhone = "";
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _isLoggedIn
        ? AttendanceScreen(
            camera: widget.camera,
            userName: _userName,
            userPhone: _userPhone,
            onLogout: _onLogout,
          )
        : LoginScreen(onLoginSuccess: _onLoginSuccess);
  }
}

// SIMPLIFIED DIRECT LOGIN SCREEN
class LoginScreen extends StatefulWidget {
  final Function(String name, String phone) onLoginSuccess;
  const LoginScreen({super.key, required this.onLoginSuccess});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  String _status = "";

  void _handleLogin() {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();

    if (name.isEmpty) {
      setState(() => _status = "Please enter your Full Name");
      return;
    }

    if (phone.isEmpty || phone.length < 7) {
      setState(() => _status = "Please enter a valid Phone Number");
      return;
    }

    // Directly log in and proceed
    widget.onLoginSuccess(name, phone);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.red.shade700, width: 2),
                ),
                child: const Column(
                  children: [
                    Icon(Icons.shield, size: 50, color: Colors.blueAccent),
                    SizedBox(height: 6),
                    Text("SVTI MOBILE", style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                    Text("Attendance Login", style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: "Full Name",
                  hintText: "e.g. Clemen Guavis",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person, color: Color(0xFF0D47A1)),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: "Phone Number",
                  hintText: "e.g. 09277026061",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone, color: Color(0xFF0D47A1)),
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0D47A1),
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _handleLogin,
                child: const Text("Log In", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              if (_status.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(_status, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// MAIN ATTENDANCE SCREEN
class AttendanceScreen extends StatefulWidget {
  final CameraDescription camera;
  final String userName;
  final String userPhone;
  final VoidCallback onLogout;

  const AttendanceScreen({
    super.key,
    required this.camera,
    required this.userName,
    required this.userPhone,
    required this.onLogout,
  });

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  CameraController? _controller;
  final _siteController = TextEditingController();
  String _status = "Ready";
  bool _isLoading = false;
  
  Timer? _clockTimer;
  Timer? _inactivityTimer;
  String _currentTimeString = "";

  @override
  void initState() {
    super.initState();
    _initCamera();
    _startClock();
    _resetInactivityTimer();
  }

  void _startClock() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          // Live display matching user's phone local time
          _currentTimeString = DateFormat('hh:mm:ss a | EEE, MMM d').format(DateTime.now());
        });
      }
    });
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(const Duration(minutes: 2), () {
      if (mounted) {
        widget.onLogout();
      }
    });
  }

  Future<void> _initCamera() async {
    await [Permission.camera, Permission.location].request();
    final newController = CameraController(widget.camera, ResolutionPreset.medium, enableAudio: false);
    
    try {
      await newController.initialize();
      if (mounted) {
        setState(() {
          _controller = newController;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = "Camera Error: ${e.toString()}");
      }
    }
  }

  // Safe camera capture helper with channel auto-recovery
  Future<XFile?> _safeTakePicture() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      await _initCamera();
    }

    if (_controller == null || !_controller!.value.isInitialized) {
      return null;
    }

    if (_controller!.value.isTakingPicture) {
      return null;
    }

    try {
      return await _controller!.takePicture();
    } catch (e) {
      // Auto-reinitialize on channel error and retry
      await _initCamera();
      if (_controller != null && _controller!.value.isInitialized) {
        try {
          return await _controller!.takePicture();
        } catch (_) {
          return null;
        }
      }
      return null;
    }
  }

  Future<void> _submitAttendance(String actionType, bool isOvertime) async {
    _resetInactivityTimer();
    final site = _siteController.text.trim();

    if (site.isEmpty) {
      setState(() => _status = "Error: Please enter Site Name");
      return;
    }

    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _status = "Capturing photo...";
    });

    try {
      // 1. Get standard local timestamp from phone time
      final nowLocal = DateTime.now();
      final localTimestamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(nowLocal);

      // 2. Take picture FIRST
      XFile? photo = await _safeTakePicture();

      if (photo == null) {
        setState(() => _status = "Camera Busy or Disconnected. Please tap again.");
        return;
      }

      List<int> imageBytes = await File(photo.path).readAsBytes();
      String base64Image = base64Encode(imageBytes);

      // 3. Fetch GPS Location
      setState(() => _status = "Getting GPS location...");
      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      ).catchError((_) async {
        return await Geolocator.getLastKnownPosition() ?? Position(
          latitude: 0.0,
          longitude: 0.0,
          timestamp: DateTime.now(),
          accuracy: 0.0,
          altitude: 0.0,
          heading: 0.0,
          speed: 0.0,
          speedAccuracy: 0.0,
          altitudeAccuracy: 0.0,
          headingAccuracy: 0.0,
        );
      });

      // 4. Send to Server with phone's local timestamp
      setState(() => _status = "Transmitting to server...");

      final response = await http.post(
        Uri.parse("https://clemenguavis.pythonanywhere.com/api/attendance"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "employee_id": widget.userName,
          "phone_number": widget.userPhone,
          "site_name": site,
          "action_type": actionType,
          "is_overtime": isOvertime,
          "timestamp": localTimestamp, // Exact local phone time
          "latitude": pos.latitude,
          "longitude": pos.longitude,
          "photo_base64": base64Image,
        }),
      );

      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body);
          setState(() => _status = "SUCCESS: ${data['message']}");
        } catch (_) {
          setState(() => _status = "SUCCESS: Recorded at $localTimestamp");
        }
      } else {
        try {
          final data = jsonDecode(response.body);
          setState(() => _status = "FAILED: ${data['error'] ?? 'Server Error'}");
        } catch (_) {
          setState(() => _status = "Server Error (${response.statusCode})");
        }
      }
    } catch (e) {
      setState(() => _status = "Connection Error: ${e.toString()}");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _siteController.dispose();
    _clockTimer?.cancel();
    _inactivityTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _resetInactivityTimer(),
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: Row(
            children: [
              const Icon(Icons.shield, color: Colors.blueAccent),
              const SizedBox(width: 8),
              const Text("SVTI Attendance", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(icon: const Icon(Icons.logout, color: Colors.redAccent), onPressed: widget.onLogout),
            ],
          ),
        ),
        body: Padding(
          padding: const EdgeInsets.all(14.0),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D47A1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.account_circle, color: Colors.white, size: 28),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.userName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                        Text(widget.userPhone, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                    const Spacer(),
                    const Icon(Icons.timer, color: Colors.redAccent, size: 16),
                    const SizedBox(width: 4),
                    const Text("Auto 2m", style: TextStyle(color: Colors.white70, fontSize: 10)),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(_currentTimeString, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87)),
              const SizedBox(height: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: (_controller != null && _controller!.value.isInitialized)
                      ? CameraPreview(_controller!)
                      : const Center(child: CircularProgressIndicator()),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _siteController,
                onChanged: (_) => _resetInactivityTimer(),
                decoration: const InputDecoration(
                  labelText: "Site Name",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.location_city, color: Color(0xFF0D47A1)),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _status,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: _status.startsWith("SUCCESS") ? Colors.green.shade800 : Colors.red.shade800,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.login, color: Colors.white, size: 18),
                      label: const Text("Time In", style: TextStyle(color: Colors.white, fontSize: 14)),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, padding: const EdgeInsets.symmetric(vertical: 12)),
                      onPressed: _isLoading ? null : () => _submitAttendance("Time In", false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.logout, color: Colors.white, size: 18),
                      label: const Text("Time Out", style: TextStyle(color: Colors.white, fontSize: 14)),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700, padding: const EdgeInsets.symmetric(vertical: 12)),
                      onPressed: _isLoading ? null : () => _submitAttendance("Time Out", false),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.add_alarm, color: Colors.white, size: 18),
                      label: const Text("Overtime In", style: TextStyle(color: Colors.white, fontSize: 14)),
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0D47A1), padding: const EdgeInsets.symmetric(vertical: 12)),
                      onPressed: _isLoading ? null : () => _submitAttendance("Overtime In", true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.alarm_off, color: Colors.white, size: 18),
                      label: const Text("Overtime Out", style: TextStyle(color: Colors.white, fontSize: 14)),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.black87, padding: const EdgeInsets.symmetric(vertical: 12)),
                      onPressed: _isLoading ? null : () => _submitAttendance("Overtime Out", true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
