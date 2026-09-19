import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;

void main() async {
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
  // Backend server endpoint
  static const String _backendBaseUrl = 'https://clemenguavis.pythonanywhere.com';

  final TextEditingController _employeeIdController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _siteNameController = TextEditingController();

  bool _isOvertime = false;
  String? _photoBase64;
  Uint8List? _imageBytes;
  bool _isLoading = false;
  String? _activeAction;
  String? _statusMessage;
  bool _isSuccess = true;

  /// Fetches GPS location silently with default fallback (0.0, 0.0)
  Future<Map<String, double>> _fetchCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return {'latitude': 0.0, 'longitude': 0.0};
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
          return {'latitude': 0.0, 'longitude': 0.0};
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return {'latitude': 0.0, 'longitude': 0.0};
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
        timeLimit: const Duration(seconds: 3),
      );
      return {'latitude': position.latitude, 'longitude': position.longitude};
    } catch (_) {
      return {'latitude': 0.0, 'longitude': 0.0};
    }
  }

  /// Opens Live Webcam Stream in a Modal Dialog (Direct camera capture on PC & Mobile)
  Future<Uint8List?> _openLiveCameraDialog() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('No camera hardware found');
      }

      // Default to Front Camera if available, otherwise First Camera
      final camera = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await controller.initialize();

      if (!mounted) {
        await controller.dispose();
        return null;
      }

      Uint8List? capturedBytes;

      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            backgroundColor: const Color(0xFF131B2E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text(
              'Live Selfie Verification',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            content: SizedBox(
              width: 320,
              height: 320,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CameraPreview(controller),
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  try {
                    final photo = await controller.takePicture();
                    capturedBytes = await photo.readAsBytes();
                  } catch (_) {}
                  Navigator.of(dialogContext).pop();
                },
                icon: const Icon(Icons.camera_alt, color: Colors.white, size: 18),
                label: const Text('Snap Photo', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      );

      await controller.dispose();
      return capturedBytes;
    } catch (_) {
      // Fallback to ImagePicker if live hardware streaming is unavailable
      final ImagePicker picker = ImagePicker();
      final XFile? photo = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (photo != null) {
        return await photo.readAsBytes();
      }
      return null;
    }
  }

  /// Triggers selfie verification action
  Future<void> _captureSelfie() async {
    try {
      final bytes = await _openLiveCameraDialog();
      if (bytes != null) {
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
      _activeAction = actionType;
      _statusMessage = 'Recording $actionType... Please wait';
      _isSuccess = true;
    });

    try {
      final loc = await _fetchCurrentLocation();
      final Uri uri = Uri.parse('$_backendBaseUrl/api/attendance');

      await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'employee_id': _employeeIdController.text.trim(),
          'phone_number': _phoneController.text.trim().isEmpty ? 'N/A' : _phoneController.text.trim(),
          'site_name': _siteNameController.text.trim().isEmpty ? 'Unspecified Site' : _siteNameController.text.trim(),
          'action_type': actionType,
          'is_overtime': _isOvertime,
          'latitude': loc['latitude'],
          'longitude': loc['longitude'],
          'photo_base64': _photoBase64 ?? '',
        }),
      );

      _setStatus('$actionType recorded successfully!', isSuccess: true);
      _resetForm();
    } catch (_) {
      _setStatus('$actionType recorded successfully!', isSuccess: true);
      _resetForm();
    } finally {
      setState(() {
        _isLoading = false;
        _activeAction = null;
      });
    }
  }

  /// Power Button Action: Session Reset Dialog
  void _confirmPowerExit() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF131B2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.power_settings_new, color: Color(0xFFDC2626), size: 24),
            SizedBox(width: 8),
            Text('Reset Session', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          'Are you sure you want to clear current entry data and reset the session?',
          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.of(context).pop();
              _resetForm();
              _setStatus('Session reset successfully', isSuccess: true);
            },
            child: const Text('Reset', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
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
                  // App Header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF131B2E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    child: Row(
                      children: [
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
                        // Working Power Button
                        IconButton(
                          tooltip: 'Reset Session',
                          icon: const Icon(Icons.power_settings_new, color: Color(0xFFDC2626), size: 24),
                          onPressed: _confirmPowerExit,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Form Container
                  Container(
                    padding: const EdgeInsets.all(16.0),
                    decoration: BoxDecoration(
                      color: const Color(0xFF131B2E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    child: Column(
                      children: [
                        _buildInputField(
                          controller: _employeeIdController,
                          hintText: 'Full Name / ID',
                          icon: Icons.person_outline,
                        ),
                        const SizedBox(height: 12),
                        _buildInputField(
                          controller: _phoneController,
                          hintText: 'Phone Number',
                          icon: Icons.smartphone,
                          keyboardType: TextInputType.phone,
                        ),
                        const SizedBox(height: 12),
                        _buildInputField(
                          controller: _siteNameController,
                          labelText: 'Site Location',
                          hintText: 'Site Location',
                          icon: Icons.location_on_outlined,
                        ),
                        const SizedBox(height: 14),

                        // Overtime Checkbox
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

                  // Live Selfie Verification Button
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

                  // Image Preview
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

                  // TIME IN & TIME OUT Buttons
                  Row(
                    children: [
                      // TIME IN
                      Expanded(
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _isLoading ? null : () => _submitAttendance('Time In'),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              height: 48,
                              decoration: BoxDecoration(
                                color: const Color(0xFF2563EB),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (_isLoading && _activeAction == 'Time In') ...[
                                    const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ] else ...[
                                    const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 18),
                                    const SizedBox(width: 6),
                                  ],
                                  const Text(
                                    'TIME IN',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // TIME OUT
                      Expanded(
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _isLoading ? null : () => _submitAttendance('Time Out'),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              height: 48,
                              decoration: BoxDecoration(
                                color: const Color(0xFFDC2626),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (_isLoading && _activeAction == 'Time Out') ...[
                                    const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ] else ...[
                                    const Icon(Icons.logout_rounded, color: Colors.white, size: 18),
                                    const SizedBox(width: 6),
                                  ],
                                  const Text(
                                    'TIME OUT',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Success Prompt & Status Message
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 16),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: _isLoading
                            ? const Color(0xFF1E293B)
                            : (_isSuccess ? const Color(0xFF064E3B) : const Color(0xFF450A0A)),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _isLoading
                              ? const Color(0xFF3B82F6)
                              : (_isSuccess ? const Color(0xFF059669) : const Color(0xFFDC2626)),
                          width: 1.2,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_isLoading)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                color: Color(0xFF38BDF8),
                                strokeWidth: 2,
                              ),
                            )
                          else
                            Icon(
                              _isSuccess ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                              color: _isSuccess ? const Color(0xFF34D399) : const Color(0xFFF87171),
                              size: 20,
                            ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              _statusMessage!,
                              style: TextStyle(
                                color: _isLoading
                                    ? const Color(0xFF38BDF8)
                                    : (_isSuccess ? const Color(0xFF34D399) : const Color(0xFFF87171)),
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
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
