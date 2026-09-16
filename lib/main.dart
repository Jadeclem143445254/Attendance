import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

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
      theme: ThemeData(primarySwatch: Colors.blue),
      home: AttendanceScreen(camera: camera),
    );
  }
}

class AttendanceScreen extends StatefulWidget {
  final CameraDescription camera;
  const AttendanceScreen({super.key, required this.camera});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  late CameraController _controller;
  final _nameController = TextEditingController();
  final _siteController = TextEditingController();
  String _status = "Ready to record attendance";
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initSystem();
  }

  Future<void> _initSystem() async {
    await [Permission.camera, Permission.location].request();
    _controller = CameraController(widget.camera, ResolutionPreset.medium);
    await _controller.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _submitAttendance(String actionType) async {
    final name = _nameController.text.trim();
    final site = _siteController.text.trim();

    if (name.isEmpty || site.isEmpty) {
      setState(() => _status = "Error: Enter both Name and Site Name");
      return;
    }

    setState(() {
      _isLoading = true;
      _status = "Capturing location & photo...";
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
          "employee_id": name,
          "site_name": site,
          "action_type": actionType,
          "latitude": pos.latitude,
          "longitude": pos.longitude,
          "is_mock_location": pos.isMocked,
          "photo_base64": base64Image,
        }),
      );

      final data = jsonDecode(response.body);
      if (response.statusCode == 200) {
        setState(() => _status = "SUCCESS: ${data['message']}");
      } else {
        setState(() => _status = "FAILED: ${data['error']}");
      }
    } catch (e) {
      setState(() => _status = "Error: ${e.toString()}");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _nameController.dispose();
    _siteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("SVTI Mobile Attendance"),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _controller.value.isInitialized
                    ? CameraPreview(_controller)
                    : const Center(child: CircularProgressIndicator()),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: "Full Name",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _siteController,
              decoration: const InputDecoration(
                labelText: "Site Name",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.location_city),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _status,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.login, color: Colors.white),
                    label: const Text("Time In", style: TextStyle(color: Colors.white, fontSize: 16)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _isLoading ? null : () => _submitAttendance("Time In"),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.logout, color: Colors.white),
                    label: const Text("Time Out", style: TextStyle(color: Colors.white, fontSize: 16)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _isLoading ? null : () => _submitAttendance("Time Out"),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
