import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
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
      title: 'SVTI Attendance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.red,
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
      ),
      home: const AttendanceHomeScreen(),
    );
  }
}

class AttendanceHomeScreen extends StatefulWidget {
  const AttendanceHomeScreen({super.key});

  @override
  State<AttendanceHomeScreen> createState() => _AttendanceHomeScreenState();
}

class _AttendanceHomeScreenState extends State<AttendanceHomeScreen> {
  // Update this to your running backend server IP or URL
  final String serverUrl = "https://your-flask-server.com/api/attendance";

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _siteController = TextEditingController();

  bool _isOvertime = false;
  bool _isLoading = false;
  File? _capturedImage;
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
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.camera, imageQuality: 40);
    if (pickedFile != null) {
      setState(() {
        _capturedImage = File(pickedFile.path);
      });
    }
  }

  Future<Position?> _getCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return null;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return null;
    }
    if (permission == LocationPermission.deniedForever) return null;

    return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
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

    await _saveUserData();

    // Capture location
    Position? position = await _getCurrentLocation();
    double lat = position?.latitude ?? 0.0;
    double lng = position?.longitude ?? 0.0;

    // Convert photo to Base64
    String photoBase64 = "";
    if (_capturedImage != null) {
      List<int> imageBytes = await _capturedImage!.readAsBytes();
      photoBase64 = base64Encode(imageBytes);
    }

    // Local ISO timestamp sent to Python endpoint
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

    try {
      final response = await http.post(
        Uri.parse(serverUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        setState(() {
          _statusMessage = "$actionType recorded successfully!";
          _capturedImage = null;
        });
      } else {
        setState(() {
          _statusMessage = "Server Error (${response.statusCode}). Try again.";
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = "Network Connection Error: $e";
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SVTI Time Tracker'),
        backgroundColor: const Color(0xFF0F172A),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Full Name', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone Number', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _siteController,
              decoration: const InputDecoration(labelText: 'Site Location', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Checkbox(
                  value: _isOvertime,
                  onChanged: (val) => setState(() => _isOvertime = val ?? false),
                ),
                const Text("Mark as Overtime"),
              ],
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _takePhoto,
              icon: const Icon(Icons.camera_alt),
              label: Text(_capturedImage == null ? "Take Verification Photo" : "Retake Photo"),
            ),
            if (_capturedImage != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Image.file(_capturedImage!, height: 120),
              ),
            const SizedBox(height: 20),
            if (_isLoading)
              const Center(child: CircularProgressIndicator())
            else
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.all(15)),
                      onPressed: () => _submitAttendance("Time In"),
                      child: const Text("TIME IN", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.all(15)),
                      onPressed: () => _submitAttendance("Time Out"),
                      child: const Text("TIME OUT", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
