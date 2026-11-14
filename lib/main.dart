import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:camera/camera.dart';
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

  // Detailed status & error diagnostics
  String? _statusTitle;
  String? _statusMessage;
  bool _isSuccess = true;

  // Live Digital Clock synced with SVTI Server (Philippine Time UTC+8)
  Timer? _clockTimer;
  int _serverOffsetMs = 0;
  String _liveClockText = '--:--:-- --';

  // Session logs (accessible via header icon so main screen stays 1-page)
  final List> _recentLogs = [];

  @override
  void initState() {
    super.initState();
    _updateClockDisplay();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateClockDisplay();
    });
    _syncServerClock();
  }

  Future<void> _syncServerClock() async {
    try {
      final int t0 = DateTime.now().millisecondsSinceEpoch;
      final res = await http
          .get(Uri.parse('$_backendBaseUrl/api/server-time'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final int t1 = DateTime.now().millisecondsSinceEpoch;
        final int rttHalf = ((t1 - t0) / 2).round();
        if (data['epoch_ms'] != null && mounted) {
          setState(() {
            _serverOffsetMs = (data['epoch_ms'] as int) + rttHalf - t1;
          });
          _updateClockDisplay();
        }
      }
    } catch (_) {
      // Falls back silently to device clock if offline
    }
  }

  void _updateClockDisplay() {
    final DateTime utcNow = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch + _serverOffsetMs,
      isUtc: true,
    );
    final DateTime manilaNow = utcNow.add(const Duration(hours: 8));
    final int hourNum = manilaNow.hour == 0
        ? 12
        : (manilaNow.hour > 12 ? manilaNow.hour - 12 : manilaNow.hour);
    final String hh = hourNum.toString().padLeft(2, '0');
    final String mm = manilaNow.minute.toString().padLeft(2, '0');
    final String ss = manilaNow.second.toString().padLeft(2, '0');
    final String period = manilaNow.hour >= 12 ? 'PM' : 'AM';

    if (mounted) {
      setState(() {
        _liveClockText = '$hh:$mm:$ss $period';
      });
    }
  }

  /// Fetches high-accuracy GPS coordinates for server geofence check
  Future> _fetchCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return {'latitude': 0.0, 'longitude': 0.0};
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          return {'latitude': 0.0, 'longitude': 0.0};
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return {'latitude': 0.0, 'longitude': 0.0};
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 5),
      );
      return {'latitude': position.latitude, 'longitude': position.longitude};
    } catch (_) {
      try {
        final lastPos = await Geolocator.getLastKnownPosition();
        if (lastPos != null) {
          return {'latitude': lastPos.latitude, 'longitude': lastPos.longitude};
        }
      } catch (_) {}
      return {'latitude': 0.0, 'longitude': 0.0};
    }
  }

  /// Desktop Live Camera stream (for PC web browsers)
  Future<Uint8List?> _tryDesktopLiveCamera() async {
    CameraController? controller;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return null;

      final camera = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      controller = CameraController(
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
              'Mandatory Selfie Verification',
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            content: SizedBox(
              width: 280,
              height: 280,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CameraPreview(controller!),
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  try {
                    final photo = await controller!.takePicture();
                    capturedBytes = await photo.readAsBytes();
                  } catch (_) {}
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                },
                icon: const Icon(Icons.camera_alt, color: Colors.white, size: 16),
                label: const Text('Snap Photo', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      );

      await controller.dispose();
      return capturedBytes;
    } catch (_) {
      if (controller != null) {
        await controller.dispose();
      }
      return null;
    }
  }

  /// Triggers mandatory selfie verification photo
  Future<void> _captureSelfie() async {
    try {
      final bool isMobileDevice = defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS;

      if (kIsWeb && !isMobileDevice) {
        final bytes = await _tryDesktopLiveCamera();
        if (bytes != null) {
          setState(() {
            _imageBytes = bytes;
            _photoBase64 = base64Encode(bytes);
          });
          _setStatus(
            title: 'Selfie Verified',
            message: 'Verification photo captured. Ready to submit.',
            isSuccess: true,
          );
          return;
        }
      }

      final ImagePicker picker = ImagePicker();
      final XFile? photo = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );

      if (photo != null) {
        final bytes = await photo.readAsBytes();
        setState(() {
          _imageBytes = bytes;
          _photoBase64 = base64Encode(bytes);
        });
        _setStatus(
          title: 'Selfie Verified',
          message: 'Verification photo captured. Ready to submit.',
          isSuccess: true,
        );
      }
    } catch (e) {
      _setStatus(
        title: 'Camera Access Error',
        message: 'Unable to open camera ($e). Please allow camera permissions in your device settings.',
        isSuccess: false,
      );
    }
  }

  /// Extracts a human-readable explanation from any server HTTP response
  String _parseServerError(int statusCode, String rawBody) {
    String serverReason = '';

    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map<String, dynamic>) {
        serverReason = (decoded['error'] ??
                decoded['message'] ??
                decoded['detail'] ??
                decoded['reason'] ??
                '')
            .toString()
            .trim();
      }
    } catch (_) {
      // Response is not JSON (e.g., HTML error page or plain text)
      final cleaned = rawBody.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (cleaned.isNotEmpty) {
        serverReason = cleaned.length > 140 ? '${cleaned.substring(0, 140)}...' : cleaned;
      }
    }

    switch (statusCode) {
      case 400:
        return serverReason.isNotEmpty
            ? 'Validation Error (HTTP 400): $serverReason (Note: Inputs are strictly case-sensitive).'
            : 'Invalid Request (HTTP 400): Server rejected the data. Check exact uppercase/lowercase spelling.';
      case 401:
      case 403:
        return serverReason.isNotEmpty
            ? 'Access / Geofence Denied (HTTP $statusCode): $serverReason'
            : 'Access Denied (HTTP $statusCode): You are not authorized or outside the allowed site boundary.';
      case 404:
        return 'Endpoint Not Found (HTTP 404): The server URL /api/attendance was not found. Check backend deployment.';
      case 500:
        return serverReason.isNotEmpty
            ? 'Internal Server Error (HTTP 500): $serverReason'
            : 'Internal Server Error (HTTP 500): The PythonAnywhere server crashed while processing your request.';
      case 502:
      case 503:
      case 504:
        return 'Server Unavailable (HTTP $statusCode): The SVTI backend server is currently offline, reloading, or overloaded. Try again in a few seconds.';
      default:
        return serverReason.isNotEmpty
            ? 'Server Error (HTTP $statusCode): $serverReason'
            : 'Unexpected Server Response (HTTP $statusCode). Please contact your administrator.';
    }
  }

  /// Submit Attendance for TIME IN or TIME OUT
  Future<void> _submitAttendance(String actionType) async {
    // Preserve exact uppercase/lowercase characters (strictly case-sensitive)
    final String empId = _employeeIdController.text.trim();
    final String phone = _phoneController.text.trim();
    final String site = _siteNameController.text.trim();

    // 1. STRICT VALIDATION: Check every individual field so user knows what is missing
    final List<String> missingFields = [];
    if (empId.isEmpty) missingFields.add('Full Name / ID');
    if (phone.isEmpty) missingFields.add('Phone Number');
    if (site.isEmpty) missingFields.add('Site Location');

    if (missingFields.isNotEmpty) {
      _setStatus(
        title: 'Missing Required Information',
        message: 'Please fill in: ${missingFields.join(', ')}. All fields are required and case-sensitive.',
        isSuccess: false,
      );
      return;
    }

    // 2. STRICT VALIDATION: Mandatory Selfie Verification
    if (_imageBytes == null || _photoBase64 == null) {
      _setStatus(
        title: 'Mandatory Selfie Required',
        message: 'You must take a selfie verification photo before pressing ${actionType.toUpperCase()}.',
        isSuccess: false,
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _activeAction = actionType;
      _statusTitle = 'Submitting $actionType...';
      _statusMessage = 'Verifying GPS location and sending record to SVTI server...';
      _isSuccess = true;
    });

    try {
      final loc = await _fetchCurrentLocation();
      final Uri uri = Uri.parse('$_backendBaseUrl/api/attendance');

      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'employee_id': empId, // Exact case preserved
              'phone_number': phone, // Exact case preserved
              'site_name': site, // Exact case preserved
              'action_type': actionType,
              'is_overtime': _isOvertime,
              'latitude': loc['latitude'],
              'longitude': loc['longitude'],
              'photo_base64': _photoBase64 ?? '',
            }),
          )
          .timeout(const Duration(seconds: 15));

      Map<String, dynamic> respData = {};
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          respData = decoded;
        }
      } catch (_) {}

      final bool serverAccepted = response.statusCode >= 200 &&
          response.statusCode < 300 &&
          respData['success'] != false &&
          respData['error'] == null;

      if (serverAccepted) {
        final newLog = {
          'employee_id': respData['employee_id'] ?? empId,
          'phone_number': phone,
          'site_name': respData['site_name'] ?? site,
          'action_type': actionType,
          'is_overtime': _isOvertime,
          'timestamp': DateTime.now(),
          'latitude': loc['latitude'] ?? 0.0,
          'longitude': loc['longitude'] ?? 0.0,
          'photo_bytes': _imageBytes,
        };

        setState(() {
          _recentLogs.insert(0, newLog);
        });

        _setStatus(
          title: '$actionType Recorded',
          message: respData['message']?.toString() ??
              '$actionType verified for "$empId" at "$site".',
          isSuccess: true,
        );
        _resetForm();
      } else {
        final String detailedReason = _parseServerError(response.statusCode, response.body);
        _setStatus(
          title: 'Server Rejected $actionType',
          message: detailedReason,
          isSuccess: false,
        );
      }
    } on TimeoutException {
      _setStatus(
        title: 'Connection Timed Out',
        message: 'The SVTI server did not respond within 15 seconds. Check your internet signal and try again.',
        isSuccess: false,
      );
    } on http.ClientException catch (e) {
      _setStatus(
        title: 'Network Connection Error',
        message: 'Unable to reach clemenguavis.pythonanywhere.com (${e.message}). Check your Wi-Fi or mobile data.',
        isSuccess: false,
      );
    } catch (e) {
      _setStatus(
        title: 'Unexpected Error',
        message: 'Failed to submit attendance: $e',
        isSuccess: false,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _activeAction = null;
        });
      }
    }
  }

  void _confirmPowerExit() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF131B2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.power_settings_new, color: Color(0xFFDC2626), size: 22),
            SizedBox(width: 8),
            Text('Reset Session', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          'Clear all entered fields and selfie photo?',
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
              _setStatus(
                title: 'Session Cleared',
                message: 'All input fields and selfie photo have been reset.',
                isSuccess: true,
              );
            },
            child: const Text('Reset', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showSessionLogsModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF131B2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                children: [
                  Icon(Icons.history_rounded, color: Color(0xFF38BDF8), size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Session Activity Logs',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _recentLogs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final log = _recentLogs[index];
                    final bool isTimeIn = log['action_type'] == 'Time In';
                    final Uint8List? photoBytes = log['photo_bytes'];
                    return Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF182238),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isTimeIn ? const Color(0xFF2563EB) : const Color(0xFFDC2626),
                        ),
                      ),
                      child: Row(
                        children: [
                          if (photoBytes != null)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.memory(photoBytes, width: 42, height: 42, fit: BoxFit.cover),
                            ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${log['employee_id']} • ${(log['action_type'] ?? '').toString().toUpperCase()}',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                                Text(
                                  '${log['site_name']} • ${_formatTimestamp(log['timestamp'] as DateTime)}',
                                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _setStatus({required String title, required String message, required bool isSuccess}) {
    setState(() {
      _statusTitle = title;
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
    _clockTimer?.cancel();
    _employeeIdController.dispose();
    _phoneController.dispose();
    _siteNameController.dispose();
    super.dispose();
  }

  String _formatTimestamp(DateTime dt) {
    final String month = dt.month.toString().padLeft(2, '0');
    final String day = dt.day.toString().padLeft(2, '0');
    final int hourNum = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final String hour = hourNum.toString().padLeft(2, '0');
    final String minute = dt.minute.toString().padLeft(2, '0');
    final String period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$month/$day $hour:$minute $period';
  }

  Widget _buildCompactInput({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    TextInputAction textInputAction = TextInputAction.next,
  }) {
    return SizedBox(
      height: 44,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        textCapitalization: TextCapitalization.none,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(color: Colors.white, fontSize: 13.5),
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 12.5),
          prefixIcon: Icon(icon, color: const Color(0xFF38BDF8), size: 18),
          prefixIconConstraints: const BoxConstraints(minWidth: 38),
          filled: true,
          fillColor: const Color(0xFF182238),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF1E293B)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF1E293B)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 20.0,
                ),
                child: Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 1. COMPACT HEADER
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF131B2E),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFF1E293B)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Image.asset(
                                  'assets/svti_logo.png',
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, stackTrace) => const Icon(
                                    Icons.business_rounded,
                                    color: Color(0xFF2563EB),
                                    size: 24,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'SVTI Mobile',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      _liveClockText,
                                      style: const TextStyle(
                                        color: Color(0xFF38BDF8),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (_recentLogs.isNotEmpty)
                                IconButton(
                                  tooltip: 'Session Logs (${_recentLogs.length})',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                                  icon: Badge(
                                    label: Text('${_recentLogs.length}'),
                                    backgroundColor: const Color(0xFF2563EB),
                                    child: const Icon(Icons.history_rounded, color: Color(0xFF38BDF8), size: 22),
                                  ),
                                  onPressed: _showSessionLogsModal,
                                ),
                              IconButton(
                                tooltip: 'Reset Session',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                                icon: const Icon(Icons.power_settings_new, color: Color(0xFFDC2626), size: 22),
                                onPressed: _confirmPowerExit,
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 10),

                        // 2. COMPACT ALL-REQUIRED & CASE-SENSITIVE FORM
                        Container(
                          padding: const EdgeInsets.all(12.0),
                          decoration: BoxDecoration(
                            color: const Color(0xFF131B2E),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFF1E293B)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'EMPLOYEE DETAILS',
                                    style: TextStyle(
                                      color: Color(0xFF94A3B8),
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.6,
                                    ),
                                  ),
                                  Text(
                                    'All Required • Case-Sensitive',
                                    style: TextStyle(
                                      color: Color(0xFFFBBF24),
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              _buildCompactInput(
                                controller: _employeeIdController,
                                hintText: 'Full Name / ID * (Case-Sensitive)',
                                icon: Icons.person_outline,
                              ),
                              const SizedBox(height: 8),
                              _buildCompactInput(
                                controller: _phoneController,
                                hintText: 'Phone Number *',
                                icon: Icons.smartphone,
                                keyboardType: TextInputType.phone,
                              ),
                              const SizedBox(height: 8),
                              _buildCompactInput(
                                controller: _siteNameController,
                                hintText: 'Site Location * (Case-Sensitive)',
                                icon: Icons.location_on_outlined,
                                textInputAction: TextInputAction.done,
                              ),
                              const SizedBox(height: 8),

                              // Compact Overtime Row
                              InkWell(
                                onTap: () => setState(() => _isOvertime = !_isOvertime),
                                borderRadius: BorderRadius.circular(10),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF182238),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    children: [
                                      const Expanded(
                                        child: Text(
                                          'Mark as Overtime',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 12.5,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        height: 24,
                                        width: 24,
                                        child: Checkbox(
                                          value: _isOvertime,
                                          activeColor: const Color(0xFF2563EB),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                          side: const BorderSide(color: Color(0xFF475569)),
                                          onChanged: (val) => setState(() => _isOvertime = val ?? false),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 10),

                        // 3. MANDATORY SELFIE VERIFICATION (Inline Thumbnail keeps screen 1-page)
                        InkWell(
                          onTap: _isLoading ? null : _captureSelfie,
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF131B2E),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _imageBytes == null ? const Color(0xFFE11D48) : const Color(0xFF2563EB),
                                width: 1.5,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (_imageBytes != null) ...[
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: Image.memory(
                                      _imageBytes!,
                                      width: 36,
                                      height: 36,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  const Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Selfie Verified ✓',
                                          style: TextStyle(
                                            color: Color(0xFF38BDF8),
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13.5,
                                          ),
                                        ),
                                        Text(
                                          'Tap to retake verification photo',
                                          style: TextStyle(
                                            color: Color(0xFF94A3B8),
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.refresh_rounded, color: Color(0xFF38BDF8), size: 20),
                                ] else ...[
                                  const Icon(
                                    Icons.camera_alt_outlined,
                                    color: Color(0xFFF43F5E),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  const Text(
                                    'Take Selfie Verification * (Mandatory)',
                                    style: TextStyle(
                                      color: Color(0xFFF43F5E),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 10),

                        // 4. TIME IN & TIME OUT ACTION BUTTONS
                        Row(
                          children: [
                            Expanded(
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: _isLoading ? null : () => _submitAttendance('Time In'),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    height: 46,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2563EB),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        if (_isLoading && _activeAction == 'Time In') ...[
                                          const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
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
                            const SizedBox(width: 10),
                            Expanded(
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: _isLoading ? null : () => _submitAttendance('Time Out'),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    height: 46,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFDC2626),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        if (_isLoading && _activeAction == 'Time Out') ...[
                                          const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
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

                        const SizedBox(height: 10),

                        // 5. DETAILED STATUS & SERVER ERROR DIAGNOSTIC BOX
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: _statusMessage == null
                                ? const Color(0xFF131B2E)
                                : (_isLoading
                                    ? const Color(0xFF1E293B)
                                    : (_isSuccess ? const Color(0xFF064E3B) : const Color(0xFF450A0A))),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _statusMessage == null
                                  ? const Color(0xFF1E293B)
                                  : (_isLoading
                                      ? const Color(0xFF3B82F6)
                                      : (_isSuccess ? const Color(0xFF059669) : const Color(0xFFDC2626))),
                              width: 1.2,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: _statusMessage == null
                                    ? const Icon(Icons.info_outline_rounded, color: Color(0xFF64748B), size: 18)
                                    : (_isLoading
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(color: Color(0xFF38BDF8), strokeWidth: 2),
                                          )
                                        : Icon(
                                            _isSuccess ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                                            color: _isSuccess ? const Color(0xFF34D399) : const Color(0xFFF87171),
                                            size: 18,
                                          )),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _statusTitle ?? 'Ready for Attendance',
                                      style: TextStyle(
                                        color: _statusMessage == null
                                            ? const Color(0xFF94A3B8)
                                            : (_isLoading
                                                ? const Color(0xFF38BDF8)
                                                : (_isSuccess ? const Color(0xFF34D399) : const Color(0xFFFCA5A5))),
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _statusMessage ??
                                          'Complete all case-sensitive fields and capture a selfie to log Time In or Time Out.',
                                      style: TextStyle(
                                        color: _statusMessage == null
                                            ? const Color(0xFF64748B)
                                            : (_isSuccess ? const Color(0xFFA7F3D0) : const Color(0xFFFECACA)),
                                        fontSize: 11.5,
                                        height: 1.3,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
