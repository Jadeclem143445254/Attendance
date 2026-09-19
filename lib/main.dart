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
      title: 'SVTI Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF090D16),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF2563EB),
          surface: Color(0xFF131B2E),
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
  // Hardcoded server endpoint
  static const String _backendBaseUrl = 'https://clemenguavis.pythonanywhere.com';

  final TextEditingController _employeeIdController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _siteNameController = TextEditingController();

  bool _isOvertime = false;
  String? _photoBase64;
  Uint8List? _imageBytes;
  bool _isLoading = false;
  String? _statusMessage;
  bool _isSuccess = true;

  CameraController? _cameraController;

  /// Fetch location silently in background
  Future<Position?> _fetchCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _setStatus('Location services are disabled on your device.', isSuccess: false);
        return null;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _setStatus('Location permissions are denied.', isSuccess: false);
          return null;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _setStatus('Location permissions are permanently denied.', isSuccess: false);
        return null;
      }

      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
    } catch (e) {
      _setStatus('Unable to fetch location: $e', isSuccess: false);
      return null;
    }
  }

  /// Selfie Capture Dialog
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
            backgroundColor: const Color(0xFF131B2E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xFF26334D)),
            ),
            title: const Text(
              'Take Selfie Verification',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
              textAlign: TextAlign.center,
            ),
            content: SizedBox(
              width: 320,
              height: 320,
              child: _cameraController != null && _cameraController!.value.isInitialized
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CameraPreview(_cameraController!),
                    )
                  : const Center(
                      child: CircularProgressIndicator(color: Color(0xFF2563EB)),
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
                      _setStatus('Selfie captured successfully!', isSuccess: true);
                    }
                  } catch (e) {
                    _setStatus('Error capturing photo: $e', isSuccess: false);
                  }
                },
                icon: const Icon(Icons.camera_alt),
                label: const Text('CAPTURE'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  foregroundColor: Colors.white,
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
        _setStatus('Selfie captured successfully!', isSuccess: true);
      }
    } catch (e) {
      _setStatus('Unable to access camera: $e', isSuccess: false);
    }
  }

  void _closeCamera() {
    _cameraController?.dispose();
    _cameraController = null;
  }

  /// Submit Attendance for TIME IN or TIME OUT
  Future<void> _submitAttendance(String actionType) async {
    if (_employeeIdController.text.trim().isEmpty) {
      _setStatus('Please enter Full Name / ID', isSuccess: false);
      return;
    }

    if (_imageBytes == null || _photoBase64 == null) {
      _setStatus('Please take selfie verification photo first', isSuccess: false);
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'Fetching location & submitting...';
    });

    try {
      Position? position = await _fetchCurrentLocation();
      if (position == null) {
        setState(() => _isLoading = false);
        return;
      }

      final Uri uri = Uri.parse('$_backendBaseUrl/api/attendance');

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'employee_id': _employeeIdController.text.trim(),
          'phone_number': _phoneController.text.trim().isEmpty ? 'N/A' : _phoneController.text.trim(),
          'site_name': _siteNameController.text.trim().isEmpty ? 'Unspecified Site' : _siteNameController.text.trim(),
          'action_type': actionType,
          'is_overtime': _isOvertime,
          'latitude': position.latitude,
          'longitude': position.longitude,
          'photo_base64': _photoBase64 ?? '',
        }),
      );

      if (response.statusCode == 200) {
        _setStatus('$actionType recorded successfully!', isSuccess: true);
        _resetForm();
      } else {
        _setStatus('Submission failed (Code: ${response.statusCode})', isSuccess: false);
      }
    } catch (e) {
      _setStatus('Network error: $e', isSuccess: false);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _setStatus(String message, {required bool isSuccess}) {
    setState(() {
      _statusMessage = message;
      _isSuccess = isSuccess;
    });
  }

  void _resetForm() {
    setState(() {
      _employeeIdController.clear();
      _phoneController.clear();
      _siteNameController.clear();
      _photoBase64 = null;
      _imageBytes = null;
      _isOvertime = false;
    });
  }

  @override
  void dispose() {
    _closeCamera();
    _employeeIdController.dispose();
    _phoneController.dispose();
    _siteNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Top Header Bar
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF131B2E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    child: Row(
                      children: [
                        // White Square Logo Box
                        Container(
                          width: 48,
                          height: 48,
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Image.asset(
                            'assets/svti_logo.png',
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) => const Icon(
                              Icons.business_rounded,
                              color: Color(0xFF2563EB),
                              size: 28,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        // App Title
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'SVTI Mobile',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Automated Attendance System',
                                style: TextStyle(
                                  color: Color(0xFF94A3B8),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Power Logout Icon
                        IconButton(
                          icon: const Icon(Icons.power_settings_new, color: Color(0xFFDC2626), size: 24),
                          onPressed: () {},
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Main Form Card
                  Container(
                    padding: const EdgeInsets.all(16.0),
                    decoration: BoxDecoration(
                      color: const Color(0xFF131B2E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    child: Column(
                      children: [
                        // Input: Full Name / ID
                        _buildInputField(
                          controller: _employeeIdController,
                          hintText: 'Full Name / ID',
                          icon: Icons.person_outline,
                        ),
                        const SizedBox(height: 12),

                        // Input: Phone Number
                        _buildInputField(
                          controller: _phoneController,
                          hintText: 'Phone Number',
                          icon: Icons.smartphone,
                          keyboardType: TextInputType.phone,
                        ),
                        const SizedBox(height: 12),

                        // Input: Site Location
                        _buildInputField(
                          controller: _siteNameController,
                          labelText: 'Site Location',
                          hintText: 'Site Location',
                          icon: Icons.location_on_outlined,
                        ),
                        const SizedBox(height: 14),

                        // Overtime Card Switch
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF182238),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Mark as Overtime',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    SizedBox(height: 2),
                                    Text(
                                      'Toggle on if logging overtime hours',
                                      style: TextStyle(
                                        color: Color(0xFF94A3B8),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Checkbox(
                                value: _isOvertime,
                                activeColor: const Color(0xFF2563EB),
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

                  // Selfie Button
                  InkWell(
                    onTap: _isLoading ? null : _captureSelfie,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF131B2E),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF2563EB), width: 1.5),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.camera_alt_outlined, color: Color(0xFF38BDF8), size: 18),
                          const SizedBox(width: 8),
                          Text(
                            _imageBytes == null ? 'Take Selfie Verification' : 'Selfie Verified ✓',
                            style: const TextStyle(
                              color: Color(0xFF38BDF8),
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Preview image if taken
                  if (_imageBytes != null) ...[
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        _imageBytes!,
                        height: 160,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),

                  // Action Buttons (TIME IN / TIME OUT)
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : () => _submitAttendance('Time In'),
                          icon: const Icon(Icons.arrow_forward, size: 18),
                          label: const Text(
                            'TIME IN',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2563EB),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : () => _submitAttendance('Time Out'),
                          icon: const Icon(Icons.exit_to_app, size: 18),
                          label: const Text(
                            'TIME OUT',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFDC2626),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Response / Status Message
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _statusMessage!,
                      style: TextStyle(
                        color: _isSuccess ? const Color(0xFF34D399) : const Color(0xFFF87171),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    String? labelText,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF182238),
        borderRadius: BorderRadius.circular(12),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: InputDecoration(
          labelText: labelText,
          labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
          hintText: hintText,
          hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
          prefixIcon: Icon(icon, color: const Color(0xFF38BDF8), size: 20),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    );
  }
}
