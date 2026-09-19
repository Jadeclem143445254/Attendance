import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:camera/camera.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SvtiAttendanceApp());
}

class SvtiAttendanceApp extends StatelessWidget {
  const SvtiAttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SVTI Mobile Attendance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE11D48),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E293B),
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
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
  // Update with your actual Flask backend endpoint
  final String serverUrl = 'http://10.0.2.2:5000/api/attendance';

  final _formKey = GlobalKey<FormState>();
  final TextEditingController _employeeController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _siteController = TextEditingController();

  String _actionType = 'Time In';
  bool _isOvertime = false;
  Uint8List? _capturedImageBytes;
  String? _base64Photo;
  bool _isLoading = false;
  String _locationStatus = 'Location not fetched';

  CameraController? _cameraController;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  @override
  void dispose() {
    _closeCamera();
    _employeeController.dispose();
    _phoneController.dispose();
    _siteController.dispose();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    await _requestPermissions();
    await _loadSavedPreferences();
  }

  // Request Runtime Permissions for Camera & Location
  Future<void> _requestPermissions() async {
    if (kIsWeb) return; // Browser manages permissions natively on web
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.locationWhenInUse,
    ].request();

    if (statuses[Permission.camera]!.isDenied ||
        statuses[Permission.locationWhenInUse]!.isDenied) {
      _showSnackBar('Camera and Location permissions are required for attendance logging.');
    }
  }

  // Persistent storage auto-fill
  Future<void> _loadSavedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _employeeController.text = prefs.getString('saved_employee_id') ?? '';
      _phoneController.text = prefs.getString('saved_phone_number') ?? '';
      _siteController.text = prefs.getString('saved_site_name') ?? '';
    });
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_employee_id', _employeeController.text.trim());
    await prefs.setString('saved_phone_number', _phoneController.text.trim());
    await prefs.setString('saved_site_name', _siteController.text.trim());
  }

  // Capture Photo Verification (Live Webcam Preview for PC Web + Mobile Compatibility)
  Future<void> _takePhoto() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        // Select front selfie camera if available, otherwise default to first camera
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

        // Display live camera preview modal
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
                'Selfie Verification',
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
                          _capturedImageBytes = bytes;
                          _base64Photo = base64Encode(bytes);
                        });
                        _closeCamera();
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
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
                  ),
                ),
              ],
            );
          },
        );
      } else {
        await _fallbackImagePicker();
      }
    } catch (e) {
      await _fallbackImagePicker();
    } finally {
      _closeCamera();
    }
  }

  // Fallback image picker if camera stream permission is restricted
  Future<void> _fallbackImagePicker() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? photo = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 45,
        maxWidth: 600,
      );

      if (photo != null) {
        final bytes = await photo.readAsBytes();
        setState(() {
          _capturedImageBytes = bytes;
          _base64Photo = base64Encode(bytes);
        });
      }
    } catch (e) {
      _showSnackBar('Failed to capture image: $e');
    }
  }

  void _closeCamera() {
    _cameraController?.dispose();
    _cameraController = null;
  }

  // Get GPS Coordinates (Fixes iOS Null Island 0,0 issue)
  Future<Position?> _getCurrentLocation() async {
    setState(() => _locationStatus = 'Fetching GPS coordinates...');

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showSnackBar('Location services are turned off on your device.');
      setState(() => _locationStatus = 'GPS Disabled');
      return null;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _showSnackBar('Location permissions are denied.');
        setState(() => _locationStatus = 'Permission Denied');
        return null;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      _showSnackBar('Location permissions are permanently denied in settings.');
      setState(() => _locationStatus = 'Permission Denied Permanently');
      return null;
    }

    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 10),
      );

      // Prevent Null Island (0.0, 0.0) submission on iOS Web
      if (position.latitude == 0.0 && position.longitude == 0.0) {
        _showSnackBar('Invalid GPS coordinates (0,0). Ensure URL uses https:// and try again.');
        setState(() => _locationStatus = 'Invalid GPS (0,0)');
        return null;
      }

      setState(() => _locationStatus =
          'Lat: ${position.latitude.toStringAsFixed(4)}, Lon: ${position.longitude.toStringAsFixed(4)}');
      return position;
    } catch (e) {
      _showSnackBar('Could not acquire location: $e');
      setState(() => _locationStatus = 'Location Error');
      return null;
    }
  }

  // Submit Data to Backend API
  Future<void> _submitAttendance() async {
    if (!_formKey.currentState!.validate()) return;

    if (_base64Photo == null) {
      _showSnackBar('Please capture a verification photo before submitting.');
      return;
    }

    setState(() => _isLoading = true);

    try {
      await _savePreferences();
      Position? position = await _getCurrentLocation();

      final Map<String, dynamic> payload = {
        'employee_id': _employeeController.text.trim(),
        'phone_number': _phoneController.text.trim(),
        'site_name': _siteController.text.trim(),
        'action_type': _actionType,
        'is_overtime': _isOvertime,
        'latitude': position?.latitude ?? 0.0,
        'longitude': position?.longitude ?? 0.0,
        'photo_base64': _base64Photo,
      };

      final response = await http
          .post(
            Uri.parse(serverUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      final responseData = jsonDecode(response.body);

      if (response.statusCode == 200 && responseData['status'] == 'success') {
        _showSuccessDialog(responseData['message'] ?? 'Attendance logged successfully.');
        _resetImageAndOptions();
      } else {
        _showSnackBar('Server Error: ${responseData['error'] ?? 'Submission failed'}');
      }
    } catch (e) {
      _showSnackBar('Network Error: Unable to connect to server. ($e)');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _resetImageAndOptions() {
    setState(() {
      _capturedImageBytes = null;
      _base64Photo = null;
      _isOvertime = false;
      _locationStatus = 'Location reset';
    });
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFE11D48),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showSuccessDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 28),
            SizedBox(width: 10),
            Text('Success', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Text(message, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK', style: TextStyle(color: Color(0xFFE11D48))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SVTI Time Logging'),
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFFE11D48)),
                  SizedBox(height: 16),
                  Text('Submitting Attendance...', style: TextStyle(color: Colors.white70)),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20.0),
              child: Form(
                key: _formKey,
                child: Column(
                  // Corrected crossAxisAlignment syntax error
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Brand Logo Header
                    Center(
                      child: Image.asset(
                        'assets/svti_logo.png',
                        height: 65,
                        errorBuilder: (context, error, stackTrace) => const Column(
                          children: [
                            Icon(Icons.business, size: 50, color: Color(0xFFE11D48)),
                            SizedBox(height: 4),
                            Text('SVTI LOGISTICS', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Camera Preview Container
                    GestureDetector(
                      onTap: _takePhoto,
                      child: Container(
                        height: 200,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _capturedImageBytes != null ? const Color(0xFFE11D48) : const Color(0xFF334155),
                            width: 1.5,
                          ),
                        ),
                        child: _capturedImageBytes != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(11),
                                child: Image.memory(_capturedImageBytes!, fit: BoxFit.cover),
                              )
                            : const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add_a_photo, size: 44, color: Color(0xFFE11D48)),
                                  SizedBox(height: 10),
                                  Text('Tap to Take Verification Photo', style: TextStyle(color: Colors.white70, fontSize: 14)),
                                  SizedBox(height: 4),
                                  Text('(Required)', style: TextStyle(color: Colors.white38, fontSize: 12)),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Employee ID / Name Field
                    TextFormField(
                      controller: _employeeController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Employee Name / ID',
                        prefixIcon: Icon(Icons.person_outline, color: Color(0xFFE11D48)),
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Color(0xFF1E293B),
                      ),
                      validator: (v) => v == null || v.trim().isEmpty ? 'Please enter Employee Name or ID' : null,
                    ),
                    const SizedBox(height: 15),

                    // Phone Field
                    TextFormField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Phone Number',
                        prefixIcon: Icon(Icons.phone_outlined, color: Color(0xFFE11D48)),
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Color(0xFF1E293B),
                      ),
                      validator: (v) => v == null || v.trim().isEmpty ? 'Please enter Phone Number' : null,
                    ),
                    const SizedBox(height: 15),

                    // Site Name Field
                    TextFormField(
                      controller: _siteController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Site / Location Name',
                        prefixIcon: Icon(Icons.location_on_outlined, color: Color(0xFFE11D48)),
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Color(0xFF1E293B),
                      ),
                      validator: (v) => v == null || v.trim().isEmpty ? 'Please enter Site Location' : null,
                    ),
                    const SizedBox(height: 15),

                    // Action Type Dropdown
                    DropdownButtonFormField<String>(
                      value: _actionType,
                      dropdownColor: const Color(0xFF1E293B),
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Log Action',
                        prefixIcon: Icon(Icons.access_time, color: Color(0xFFE11D48)),
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Color(0xFF1E293B),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'Time In', child: Text('Time In')),
                        DropdownMenuItem(value: 'Time Out', child: Text('Time Out')),
                      ],
                      onChanged: (val) => setState(() => _actionType = val!),
                    ),
                    const SizedBox(height: 10),

                    // Overtime Switch / Checkbox
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFF475569)),
                      ),
                      child: CheckboxListTile(
                        title: const Text('Mark as Overtime', style: TextStyle(color: Colors.white)),
                        value: _isOvertime,
                        activeColor: const Color(0xFFE11D48),
                        onChanged: (val) => setState(() => _isOvertime = val ?? false),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Location Status Indicator
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4.0),
                      child: Text(
                        'GPS Status: $_locationStatus',
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Submit Button
                    ElevatedButton.icon(
                      onPressed: _submitAttendance,
                      icon: const Icon(Icons.send),
                      label: const Text(
                        'SUBMIT LOG',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE11D48),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
