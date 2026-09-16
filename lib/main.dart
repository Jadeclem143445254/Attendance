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
  bool _isRegistered = false;
  bool _isLoggedIn = false;
  String _userName = "";
  String _userPhone = "";
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkAuthState();
  }

  Future<void> _checkAuthState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isRegistered = prefs.getBool('isRegistered') ?? false;
      _isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
      _userName = prefs.getString('userName') ?? "";
      _userPhone = prefs.getString('userPhone') ?? "";
      _isLoading = false;
    });
  }

  void _onRegistered(String name, String phone) {
    setState(() {
      _isRegistered = true;
      _isLoggedIn = true;
      _userName = name;
      _userPhone = phone;
    });
  }

  void _onLoginSuccess() {
    setState(() {
      _isLoggedIn = true;
    });
  }

  void _onLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isLoggedIn', false);
    setState(() {
      _isLoggedIn = false;
    });
  }

  void _resetRegistration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    setState(() {
      _isRegistered = false;
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

    if (!_isRegistered) {
      return RegisterScreen(onRegistered: _onRegistered);
    }

    if (!_isLoggedIn) {
      return PasswordLoginScreen(
        userName: _userName,
        userPhone: _userPhone,
        onLoginSuccess: _onLoginSuccess,
        onResetAccount: _resetRegistration,
      );
    }

    return AttendanceScreen(
      camera: widget.camera,
      userName: _userName,
      userPhone: _userPhone,
      onLogout: _onLogout,
    );
  }
}

// ONE-TIME REGISTRATION SCREEN
class RegisterScreen extends StatefulWidget {
  final Function(String name, String phone) onRegistered;
  const RegisterScreen({super.key, required this.onRegistered});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String _status = "";

  Future<void> _handleRegister() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final password = _passwordController.text.trim();

    if (name.isEmpty || phone.isEmpty || password.length < 4) {
      setState(() => _status = "Please complete all fields (Min 4 digit password)");
      return;
    }

    setState(() {
      _isLoading = true;
      _status = "Registering account...";
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isRegistered', true);
      await prefs.setBool('isLoggedIn', true);
      await prefs.setString('userName', name);
      await prefs.setString('userPhone', phone);
      await prefs.setString('userPassword', password);

      widget.onRegistered(name, phone);
    } catch (e) {
      setState(() => _status = "Registration Error: ${e.toString()}");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 20),
              // SVTI LOGO DISPLAY
              Image.asset(
                'assets/svti_logo.png',
                height: 70,
                errorBuilder: (context, error, stackTrace) => const Text(
                  "SVTI",
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.black),
                ),
              ),
              const SizedBox(height: 8),
              const Text("Systems Variable Technicom Inc.", style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 24),
              const Text("One-Time Registration", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
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
                  labelText: "Phone Number",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone, color: Color(0xFF0D47A1)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: "Set Password",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock, color: Colors.red),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0D47A1),
                  minimumSize: const Size.fromHeight(50),
                ),
                onPressed: _isLoading ? null : _handleRegister,
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text("Register Account", style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
              const SizedBox(height: 12),
              Text(_status, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

// PASSWORD ONLY LOGIN SCREEN
class PasswordLoginScreen extends StatefulWidget {
  final String userName;
  final String userPhone;
  final VoidCallback onLoginSuccess;
  final VoidCallback onResetAccount;

  const PasswordLoginScreen({
    super.key,
    required this.userName,
    required this.userPhone,
    required this.onLoginSuccess,
    required this.onResetAccount,
  });

  @override
  State<PasswordLoginScreen> createState() => _PasswordLoginScreenState();
}

class _PasswordLoginScreenState extends State<PasswordLoginScreen> {
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String _status = "";

  Future<void> _verifyPassword() async {
    final password = _passwordController.text.trim();
    final prefs = await SharedPreferences.getInstance();
    final savedPassword = prefs.getString('userPassword') ?? "";

    if (password == savedPassword) {
      await prefs.setBool('isLoggedIn', true);
      widget.onLoginSuccess();
    } else {
      setState(() => _status = "Incorrect Password. Try again.");
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
              Image.asset(
                'assets/svti_logo.png',
                height: 70,
                errorBuilder: (context, error, stackTrace) => const Text(
                  "SVTI",
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.black),
                ),
              ),
              const SizedBox(height: 16),
              Text("Welcome back, ${widget.userName}", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Text(widget.userPhone, style: const TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 24),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: "Enter Password to Login",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock, color: Colors.blueAccent),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0D47A1),
                  minimumSize: const Size.fromHeight(50),
                ),
                onPressed: _isLoading ? null : _verifyPassword,
                child: const Text("Login", style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
              const SizedBox(height: 12),
              Text(_status, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              const Spacer(),
              TextButton(
                onPressed: widget.onResetAccount,
                child: const Text("Register as a different user?", style: TextStyle(color: Colors.grey)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// MAIN ATTENDANCE SCREEN WITH 24-HR LOCAL TIME & SVTI LOGO
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
    _startClock24Hr();
    _resetInactivityTimer();
  }

  // 24-HOUR LOCAL STANDARD TIME FORMAT
  void _startClock24Hr() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _currentTimeString = DateFormat('HH:mm:ss | EEE, MMM d').format(DateTime.now());
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
      XFile? photo = await _safeTakePicture();

      if (photo == null) {
        setState(() => _status = "Camera busy. Please try again.");
        return;
      }

      List<int> imageBytes = await File(photo.path).readAsBytes();
      String base64Image = base64Encode(imageBytes);

      setState(() => _status = "Getting location...");
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

      setState(() => _status = "Transmitting...");

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
          "local_timestamp": _currentTimeString,
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
          backgroundColor: Colors.white,
          elevation: 1,
          title: Row(
            children: [
              Image.asset(
                'assets/svti_logo.png',
                height: 32,
                errorBuilder: (context, error, stackTrace) => const Text(
                  "SVTI",
                  style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              const Text("Attendance", style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 16)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.logout, color: Colors.redAccent),
                onPressed: widget.onLogout,
              ),
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
              const SizedBox(height: 8),
              // 24-HOUR LOCAL TIME DISPLAY
              Text(
                _currentTimeString,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
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
