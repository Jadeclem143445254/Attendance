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
        : SignUpScreen(onLoginSuccess: _onLoginSuccess);
  }
}

// SIGN UP / PHONE AUTH SCREEN WITH REAL SMS INTEGRATION
class SignUpScreen extends StatefulWidget {
  final Function(String name, String phone) onLoginSuccess;
  const SignUpScreen({super.key, required this.onLoginSuccess});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();

  bool _codeSent = false;
  bool _isLoading = false;
  String _status = "";

  Future<void> _sendCode() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();

    if (name.isEmpty || phone.length < 10) {
      setState(() => _status = "Please enter full name & valid phone number");
      return;
    }

    setState(() {
      _isLoading = true;
      _status = "Sending SMS code to $phone...";
    });

    try {
      final res = await http.post(
        Uri.parse("https://clemenguavis.pythonanywhere.com/api/send-otp"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"phone_number": phone}),
      );

      final data = jsonDecode(res.body);

      if (res.statusCode == 200 && data['status'] == 'success') {
        setState(() {
          _codeSent = true;
          _status = "SMS code dispatched! Enter code below.";
        });
      } else {
        setState(() => _status = data['message'] ?? "Failed to send SMS code");
      }
    } catch (e) {
      setState(() => _status = "Connection Error: ${e.toString()}");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _verifyCode() async {
    final phone = _phoneController.text.trim();
    final otp = _otpController.text.trim();

    if (otp.length < 6) {
      setState(() => _status = "Please enter the 6-digit code");
      return;
    }

    setState(() {
      _isLoading = true;
      _status = "Verifying code...";
    });

    try {
      final res = await http.post(
        Uri.parse("https://clemenguavis.pythonanywhere.com/api/verify-otp"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"phone_number": phone, "otp": otp}),
      );

      final data = jsonDecode(res.body);

      if (res.statusCode == 200 && data['status'] == 'success') {
        widget.onLoginSuccess(_nameController.text.trim(), phone);
      } else {
        setState(() => _status = data['message'] ?? "Invalid verification code");
      }
    } catch (e) {
      setState(() => _status = "Connection Error: ${e.toString()}");
    } finally {
      setState(() => _isLoading = false);
    }
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
                    Text("Attendance Authentication", style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              if (!_codeSent) ...[
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: "Full Name",
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person, color: Color(0xFF0D47A1)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: "Active Phone Number (e.g. 09171234567)",
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.phone, color: Color(0xFF0D47A1)),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0D47A1),
                    minimumSize: const Size.fromHeight(50),
                  ),
                  onPressed: _isLoading ? null : _sendCode,
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text("Send SMS Code", style: TextStyle(color: Colors.white, fontSize: 16)),
                ),
              ] else ...[
                TextField(
                  controller: _otpController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: "Enter 6-Digit SMS Verification Code",
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock, color: Colors.red),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    minimumSize: const Size.fromHeight(50),
                  ),
                  onPressed: _isLoading ? null : _verifyCode,
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text("Verify & Complete Sign Up", style: TextStyle(color: Colors.white, fontSize: 16)),
                ),
              ],
              const SizedBox(height: 12),
              Text(_status, style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
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
  late CameraController _controller;
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
    _controller = CameraController(widget.camera, ResolutionPreset.medium);
    await _controller.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _submitAttendance(String actionType, bool isOvertime) async {
    _resetInactivityTimer();
    final site = _siteController.text.trim();

    if (site.isEmpty) {
      setState(() => _status = "Error: Please enter Site Name");
      return;
    }

    setState(() {
      _isLoading = true;
      _status = "Capturing location & selfie...";
    });

    try {
      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      XFile photo = await _controller.takePicture();
      List<int> imageBytes = await File(photo.path).readAsBytes();
      String base64Image = base64Encode(imageBytes);

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
          setState(() => _status = "SUCCESS: Attendance recorded");
        }
      } else {
        try {
          final data = jsonDecode(response.body);
          setState(() => _status = "FAILED: ${data['error'] ?? 'Server Error'}");
        } catch (_) {
          setState(() => _status = "Server Error (${response.statusCode}): Check PythonAnywhere script");
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
    _controller.dispose();
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
                  child: _controller.value.isInitialized
                      ? CameraPreview(_controller)
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
