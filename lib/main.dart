import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AttendanceApp());
}

class AttendanceApp extends StatelessWidget {
  const AttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SVTI Attendance Portal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE11D48),
          primary: const Color(0xFFE11D48),
        ),
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        useMaterial3: true,
      ),
      home: const AttendanceScreen(),
    );
  }
}

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  final TextEditingController _employeeIdController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _siteNameController = TextEditingController();
  final TextEditingController _backendUrlController =
      TextEditingController(text: 'http://localhost:5000');

  String _actionType = 'Time In';
  bool _isOvertime = false;
  double? _latitude;
  double? _longitude;
  String? _photoBase64;
  Uint8List? _imageBytes;
  bool _isLoading = false;

  CameraController? _cameraController;

  Future<void> _getCurrentLocation() async {
    setState(() => _isLoading = true);
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showSnackBar('Location services are disabled.');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _showSnackBar('Location permissions are denied.');
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _showSnackBar('Location permissions are permanently denied.');
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
      });
      _showSnackBar('GPS Coordinates captured successfully!');
    } catch (e) {
      _showSnackBar('Error getting location: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// Handles Camera Capture (Direct live WebRTC stream on PC & Mobile)
  Future<void> _captureSelfie() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        await _fallbackImagePicker();
        return;
      }

      final frontCamera = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController!.initialize();

      if (!mounted) return;

      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: Color(0xFF334155)),
            ),
            title: const Text(
              'Webcam Selfie Capture',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            content: SizedBox(
              width: 380,
              height: 380,
              child: _cameraController != null && _cameraController!.value.isInitialized
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CameraPreview(_cameraController!),
                    )
                  : const Center(
                      child: CircularProgressIndicator(color: Color(0xFFE11D48)),
                    ),
            ),
            actionsAlignment: MainAxisAlignment.spaceBetween,
            actions: [
              TextButton(
                onPressed: () {
                  _closeCamera();
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton.icon(
                onPressed: () async {
                  try {
                    if (_cameraController != null && _cameraController!.value.isInitialized) {
                      final photo = await _cameraController!.takePicture();
                      final bytes = await photo.readAsBytes();
                      setState(() {
                        _imageBytes = bytes;
                        _photoBase64 = base64Encode(bytes);
                      });
                      _closeCamera();
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                      _showSnackBar('Selfie captured successfully!');
                    }
                  } catch (e) {
                    _showSnackBar('Error capturing photo: $e');
                  }
                },
                icon: const Icon(Icons.camera_alt),
                label: const Text('SNAP PHOTO'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE11D48),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
            ],
          );
        },
      );
    } catch (e) {
      await _fallbackImagePicker();
    } finally {
      _closeCamera();
    }
  }

  Future<void> _fallbackImagePicker() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? photo = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 80,
      );

      if (photo != null) {
        final bytes = await photo.readAsBytes();
        setState(() {
          _imageBytes = bytes;
          _photoBase64 = base64Encode(bytes);
        });
      }
    } catch (e) {
      _showSnackBar('Unable to access camera: $e');
    }
  }

  void _closeCamera() {
    _cameraController?.dispose();
    _cameraController = null;
  }

  Future<void> _submitAttendance() async {
    if (_employeeIdController.text.trim().isEmpty) {
      _showSnackBar('Please enter Employee Name/ID');
      return;
    }
    if (_latitude == null || _longitude == null) {
      _showSnackBar('Please capture your GPS location first');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final String baseUrl = _backendUrlController.text.trim().replaceAll(RegExp(r'/$'), '');
      final Uri uri = Uri.parse('$baseUrl/api/attendance');

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'employee_id': _employeeIdController.text.trim(),
          'phone_number': _phoneController.text.trim().isEmpty ? 'N/A' : _phoneController.text.trim(),
          'site_name': _siteNameController.text.trim().isEmpty ? 'Unspecified Site' : _siteNameController.text.trim(),
          'action_type': _actionType,
          'is_overtime': _isOvertime,
          'latitude': _latitude,
          'longitude': _longitude,
          'photo_base64': _photoBase64 ?? '',
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _showSnackBar(data['message'] ?? 'Attendance submitted successfully!');
        _resetForm();
      } else {
        _showSnackBar('Submission failed (Status Code: ${response.statusCode})');
      }
    } catch (e) {
      _showSnackBar('Network error submitting attendance: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _resetForm() {
    setState(() {
      _employeeIdController.clear();
      _phoneController.clear();
      _siteNameController.clear();
      _photoBase64 = null;
      _imageBytes = null;
      _latitude = null;
      _longitude = null;
      _isOvertime = false;
      _actionType = 'Time In';
    });
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    _closeCamera();
    _employeeIdController.dispose();
    _phoneController.dispose();
    _siteNameController.dispose();
    _backendUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'SVTI Attendance',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF1E293B),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 500),
            padding: const EdgeInsets.all(24.0),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Record Attendance',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _backendUrlController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Backend Server URL',
                    labelStyle: TextStyle(color: Colors.grey),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _employeeIdController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Employee Name / ID *',
                    labelStyle: TextStyle(color: Colors.grey),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Phone Number',
                    labelStyle: TextStyle(color: Colors.grey),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _siteNameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Site Location',
                    labelStyle: TextStyle(color: Colors.grey),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: RadioListTile<String>(
                        title: const Text('Time In', style: TextStyle(color: Colors.white)),
                        value: 'Time In',
                        groupValue: _actionType,
                        onChanged: (val) => setState(() => _actionType = val!),
                      ),
                    ),
                    Expanded(
                      child: RadioListTile<String>(
                        title: const Text('Time Out', style: TextStyle(color: Colors.white)),
                        value: 'Time Out',
                        groupValue: _actionType,
                        onChanged: (val) => setState(() => _actionType = val!),
                      ),
                    ),
                  ],
                ),
                CheckboxListTile(
                  title: const Text('Overtime Shift', style: TextStyle(color: Colors.white)),
                  value: _isOvertime,
                  onChanged: (val) => setState(() => _isOvertime = val ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _isLoading ? null : _getCurrentLocation,
                  icon: const Icon(Icons.location_on),
                  label: Text(_latitude == null
                      ? 'Capture GPS Location'
                      : 'GPS: ${_latitude!.toStringAsFixed(4)}, ${_longitude!.toStringAsFixed(4)}'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _isLoading ? null : _captureSelfie,
                  icon: const Icon(Icons.camera_alt),
                  label: Text(_imageBytes == null ? 'Take Selfie Photo' : 'Photo Captured ✓'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                if (_imageBytes != null) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      _imageBytes!,
                      height: 180,
                      fit: BoxFit.cover,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _isLoading ? null : _submitAttendance,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE11D48),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Text(
                          'SUBMIT ATTENDANCE',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
