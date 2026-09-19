import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const AttendanceApp());
}

class AttendanceApp extends StatelessWidget {
  const AttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SVTI Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF080D1A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF1D61E7),
          surface: Color(0xFF10192D),
        ),
      ),
      home: const AttendanceHomeScreen(),
    );
  }
}

// DASHBOARD SCREEN
class AttendanceHomeScreen extends StatefulWidget {
  const AttendanceHomeScreen({super.key});

  @override
  State<AttendanceHomeScreen> createState() => _AttendanceHomeScreenState();
}

class _AttendanceHomeScreenState extends State<AttendanceHomeScreen> {
  final String serverUrl = "https://clemenguavis.pythonanywhere.com/api/attendance";

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _siteController = TextEditingController();

  bool _isOvertime = false;
  bool _isLoading = false;
  XFile? _capturedImage;
  Uint8List? _capturedImageBytes;
  String _statusMessage = "";

  @override
  void initState() {
    super.initState();
    _loadSavedUserData();
  }

  Future<void> _loadSavedUserData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _nameController.text = prefs.getString('saved_name') ?? '';
      _phoneController.text = prefs.getString('saved_phone') ?? '';
      _siteController.text = prefs.getString('saved_site') ?? 'Main Site';
    });
  }

  Future<void> _saveUserData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_name', _nameController.text.trim());
    await prefs.setString('saved_phone', _phoneController.text.trim());
    await prefs.setString('saved_site', _siteController.text.trim());
  }

  Future<void> _takePhoto() async {
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 40,
      );
      if (pickedFile != null) {
        final bytes = await pickedFile.readAsBytes();
        setState(() {
          _capturedImage = pickedFile;
          _capturedImageBytes = bytes;
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = "Camera access error: $e";
      });
    }
  }

  Future<Position?> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return null;
      }
      if (permission == LocationPermission.deniedForever) return null;

      // Time limit prevents iOS Safari from freezing indefinitely
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 8),
      );
    } catch (e) {
      return null;
    }
  }

  Future<void> _submitAttendance(String actionType) async {
    if (_nameController.text.isEmpty || _phoneController.text.isEmpty) {
      setState(() => _statusMessage = "Please fill in Name and Phone Number.");
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = "Recording $actionType...";
    });

    try {
      await _saveUserData();

      Position? position = await _getCurrentLocation();
      double lat = position?.latitude ?? 0.0;
      double lng = position?.longitude ?? 0.0;

      String photoBase64 = "";
      if (_capturedImageBytes != null) {
        photoBase64 = base64Encode(_capturedImageBytes!);
      }

      String localTimestamp = DateTime.now().toIso8601String();

      Map<String, dynamic> payload = {
        "employee_id": _nameController.text.trim(),
        "phone_number": _phoneController.text.trim(),
        "site_name": _siteController.text.trim(),
        "action_type": actionType,
        "is_overtime": _isOvertime,
        "latitude": lat,
        "longitude": lng,
        "photo_base64": photoBase64,
        "timestamp": localTimestamp
      };

      final response = await http.post(
        Uri.parse(serverUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        setState(() {
          _statusMessage = "$actionType recorded successfully!";
          _capturedImage = null;
          _capturedImageBytes = null;
        });
      } else {
        setState(() {
          _statusMessage = "Server Error (${response.statusCode}). Try again.";
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = "Network Error: $e";
      });
    } finally {
      // Guarantees loading indicator stops on iOS Safari
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.power_settings_new, color: Colors.redAccent, size: 28),
            tooltip: 'Quit Application',
            onPressed: () => SystemNavigator.pop(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Header Banner Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0F3B8C), Color(0xFF0B1736)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF1E40AF).withOpacity(0.5)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Image.asset(
                      'assets/svti_logo.png',
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => const Icon(Icons.business, color: Color(0xFF080D1A), size: 30),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text('SVTI Mobile', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                        SizedBox(height: 2),
                        Text('Automated Attendance System', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                      ],
                    ),
                  )
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Form Section Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF10192D),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF1E293B)),
              ),
              child: Column(
                children: [
                  TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.person_outline, color: Color(0xFF38BDF8)),
                      hintText: 'Full Name',
                      hintStyle: const TextStyle(color: Color(0xFF64748B)),
                      filled: true,
                      fillColor: const Color(0xFF162238),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.phone_android_outlined, color: Color(0xFF38BDF8)),
                      hintText: 'Phone Number',
                      hintStyle: const TextStyle(color: Color(0xFF64748B)),
                      filled: true,
                      fillColor: const Color(0xFF162238),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _siteController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.location_on_outlined, color: Color(0xFF38BDF8)),
                      hintText: 'Site Location',
                      labelText: 'Site Location',
                      labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                      hintStyle: const TextStyle(color: Color(0xFF64748B)),
                      filled: true,
                      fillColor: const Color(0xFF162238),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Overtime Selection Box
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF162238),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text("Mark as Overtime", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                            SizedBox(height: 2),
                            Text("Toggle on if logging overtime hours", style: TextStyle(color: Color(0xFF64748B), fontSize: 11)),
                          ],
                        ),
                        Checkbox(
                          value: _isOvertime,
                          activeColor: const Color(0xFF38BDF8),
                          checkColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                          side: const BorderSide(color: Color(0xFF475569)),
                          onChanged: (val) => setState(() => _isOvertime = val ?? false),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Selfie Verification Button Container
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF10192D),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF1E293B)),
              ),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  side: const BorderSide(color: Color(0xFF00A8FF), width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _takePhoto,
                icon: const Icon(Icons.camera_alt_outlined, color: Color(0xFF00A8FF)),
                label: Text(
                  _capturedImageBytes == null ? "Take Selfie Verification" : "Retake Photo",
                  style: const TextStyle(color: Color(0xFF00A8FF), fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
            ),
            if (_capturedImageBytes != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(_capturedImageBytes!, height: 140, fit: BoxFit.cover),
                ),
              ),
            const SizedBox(height: 20),

            // Time In / Time Out Action Buttons
            if (_isLoading)
              const Center(child: CircularProgressIndicator())
            else
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1D61E7),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: () => _submitAttendance("Time In"),
                      icon: const Icon(Icons.arrow_forward_rounded, color: Colors.white),
                      label: const Text("TIME IN", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFDC2626),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: () => _submitAttendance("Time Out"),
                      icon: const Icon(Icons.logout_rounded, color: Colors.white),
                      label: const Text("TIME OUT", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 15),
            Text(_statusMessage, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey)),
          ],
        ),
      ),
    );
  }
}
