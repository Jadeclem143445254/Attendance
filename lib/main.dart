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
  final _empController = TextEditingController();
  String _status = "Initializing system...";
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
    if (mounted) setState(() => _status = "Ready to record attendance");
  }

  Future<void> _submitAttendance(String actionType) async {
    if (_empController.text.trim().isEmpty) {
      setState(() => _status = "Error: Enter Employee ID");
      return;
    }

    setState(() {
      _isLoading = true;
      _status = "Acquiring location & photo...";
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
          "employee_id": _empController.text.trim(),
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
        setState(() => _status = "REJECTED: ${data['error']}");
      }
    } catch (e) {
      setState(() => _status = "Connection error: ${e.toString()}");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _empController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("SVTI Mobile Attendance")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Expanded(
              child: _controller.value.isInitialized
                  ? CameraPreview(_controller)
                  : const Center(child: CircularProgressIndicator()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _empController,
              decoration: const InputDecoration(
                labelText: "Employee ID",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _status,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                    onPressed: _isLoading ? null : () => _submitAttendance("LOG_IN"),
                    child: const Text("LOG IN", style: TextStyle(color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: _isLoading ? null : () => _submitAttendance("LOG_OUT"),
                    child: const Text("LOG OUT", style: TextStyle(color: Colors.white)),
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
