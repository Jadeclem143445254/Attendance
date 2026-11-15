import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gal/gal.dart';

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
  static const String _backendBaseUrl = 'https://clemenguavis.pythonanywhere.com';

  final GlobalKey _receiptPopupKey = GlobalKey();

  final TextEditingController _employeeIdController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _siteNameController = TextEditingController();

  List<String> _savedEmpIds = [];
  List<String> _savedPhones = [];
  List<String> _savedSites = [];

  bool _isOvertime = false;
  String? _photoBase64;
  Uint8List? _imageBytes;
  bool _isLoading = false;
  String? _activeAction;
  String? _statusMessage;
  bool _isSuccess = true;
  Timer? _statusDismissTimer;

  Timer? _clockTimer;
  int _serverOffsetMs = 0;
  String _liveClockText = '--:--:-- --';

  final List<dynamic> _recentLogs = [];

  @override
  void initState() {
    super.initState();
    _loadSavedInputs();
    _updateClockDisplay();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateClockDisplay();
    });
    _syncServerClock();
  }

  Future<void> _loadSavedInputs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _savedEmpIds = prefs.getStringList('history_emp_ids') ?? [];
        _savedPhones = prefs.getStringList('history_phones') ?? [];
        _savedSites = prefs.getStringList('history_sites') ?? [];

        _employeeIdController.text = prefs.getString('last_emp_id') ?? '';
        _phoneController.text = prefs.getString('last_phone') ?? '';
        _siteNameController.text = prefs.getString('last_site') ?? '';
      });
    } catch (_) {}
  }

  Future<void> _saveInputsToHistory(String empId, String phone, String site) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_emp_id', empId);
      await prefs.setString('last_phone', phone);
      await prefs.setString('last_site', site);

      if (empId.isNotEmpty) {
        _savedEmpIds.remove(empId);
        _savedEmpIds.insert(0, empId);
        if (_savedEmpIds.length > 15) _savedEmpIds = _savedEmpIds.sublist(0, 15);
        await prefs.setStringList('history_emp_ids', _savedEmpIds);
      }

      if (phone.isNotEmpty) {
        _savedPhones.remove(phone);
        _savedPhones.insert(0, phone);
        if (_savedPhones.length > 15) _savedPhones = _savedPhones.sublist(0, 15);
        await prefs.setStringList('history_phones', _savedPhones);
      }

      if (site.isNotEmpty) {
        _savedSites.remove(site);
        _savedSites.insert(0, site);
        if (_savedSites.length > 15) _savedSites = _savedSites.sublist(0, 15);
        await prefs.setStringList('history_sites', _savedSites);
      }

      if (mounted) setState(() {});
    } catch (_) {}
  }

  String _sanitizeErrorMessage(String rawMessage) {
    String cleaned = rawMessage
        .replaceAll(RegExp(r'\s*[\(\[]?\s*allowed\s*radius[^.\)\]]*[\)\]]?\.?', caseSensitive: false), '')
        .trim();
    if (cleaned.endsWith(',')) {
      cleaned = '${cleaned.substring(0, cleaned.length - 1)}.';
    }
    return cleaned;
  }

  /// Captures the pop-out receipt card and saves it to the mobile gallery
  Future<bool> _savePopupReceiptToGallery(String actionType) async {
    if (kIsWeb) return false;
    try {
      await Future.delayed(const Duration(milliseconds: 150));
      final boundary = _receiptPopupKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return false;

      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return false;

      final Uint8List pngBytes = byteData.buffer.asUint8List();

      bool hasAccess = await Gal.hasAccess(toAlbum: true);
      if (!hasAccess) {
        hasAccess = await Gal.requestAccess(toAlbum: true);
      }

      if (hasAccess) {
        final String safeAction = actionType.replaceAll(' ', '_');
        final String fileName = 'SVTI_${safeAction}_${DateTime.now().millisecondsSinceEpoch}';
        await Gal.putImageBytes(
          pngBytes,
          album: 'SVTI Attendance',
          name: fileName,
        );
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Shows a pop-out receipt modal after a valid Time In / Time Out with geofence details & save screenshot button
  void _showValidLogReceiptPopup(Map logData) {
    final bool isTimeIn = logData['action_type'] == 'Time In';
    final Uint8List? photoBytes = logData['photo_bytes'];
    final double lat = (logData['latitude'] is num) ? (logData['latitude'] as num).toDouble() : 0.0;
    final double lng = (logData['longitude'] is num) ? (logData['longitude'] as num).toDouble() : 0.0;
    final String gpsText = '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';
    final String formattedTime = _formatTimestamp(logData['timestamp'] as DateTime);

    bool isSaving = false;
    bool isSaved = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF0F172A),
              contentPadding: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: const BorderSide(color: Color(0xFF10B981), width: 1.5),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Capturable Receipt Card
                    RepaintBoundary(
                      key: _receiptPopupKey,
                      child: Container(
                        width: 310,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF131B2E),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF1E293B)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981).withOpacity(0.15),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.verified_rounded,
                                    color: Color(0xFF34D399),
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'SVTI Attendance Receipt',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                      Text(
                                        'Verified Geofence Log',
                                        style: TextStyle(
                                          color: Color(0xFF34D399),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: isTimeIn
                                        ? const Color(0xFF2563EB).withOpacity(0.25)
                                        : const Color(0xFFDC2626).withOpacity(0.25),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    (logData['action_type'] ?? '').toString().toUpperCase(),
                                    style: TextStyle(
                                      color: isTimeIn ? const Color(0xFF60A5FA) : const Color(0xFFF87171),
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (photoBytes != null)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.memory(
                                  photoBytes,
                                  height: 150,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            const SizedBox(height: 12),
                            const Divider(color: Color(0xFF1E293B), height: 1),
                            const SizedBox(height: 10),
                            _receiptDetailRow('Employee', '${logData['employee_id']}'),
                            const SizedBox(height: 6),
                            _receiptDetailRow('Site Location', '${logData['site_name']}'),
                            const SizedBox(height: 6),
                            _receiptDetailRow('Geofence GPS', gpsText, valueColor: const Color(0xFF34D399)),
                            const SizedBox(height: 6),
                            _receiptDetailRow(
                              'Shift Type',
                              logData['is_overtime'] == true ? 'OVERTIME' : 'REGULAR',
                            ),
                            const SizedBox(height: 6),
                            _receiptDetailRow('Timestamp', formattedTime),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    // Action Buttons
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFF334155)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: isSaving ? null : () => Navigator.of(dialogContext).pop(),
                            child: const Text(
                              'Close',
                              style: TextStyle(color: Color(0xFF94A3B8), fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isSaved ? const Color(0xFF059669) : const Color(0xFF2563EB),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: (isSaving || isSaved)
                                ? null
                                : () async {
                                    setDialogState(() => isSaving = true);
                                    final ok = await _savePopupReceiptToGallery(
                                      (logData['action_type'] ?? 'Log').toString(),
                                    );
                                    if (!dialogContext.mounted) return;
                                    setDialogState(() {
                                      isSaving = false;
                                      isSaved = ok;
                                    });
                                    if (ok) {
                                      ScaffoldMessenger.of(this.context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Saved to mobile gallery (SVTI Attendance).'),
                                          backgroundColor: Color(0xFF065F46),
                                          duration: Duration(seconds: 3),
                                        ),
                                      );
                                    } else {
                                      ScaffoldMessenger.of(this.context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Unable to save screenshot. Please allow Photos/Storage permission.'),
                                          backgroundColor: Color(0xFF991B1B),
                                          duration: Duration(seconds: 3),
                                        ),
                                      );
                                    }
                                  },
                            icon: isSaving
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                  )
                                : Icon(
                                    isSaved ? Icons.check_circle_rounded : Icons.download_rounded,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                            label: Text(
                              isSaved ? 'Saved to Gallery' : 'Save Screenshot',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _receiptDetailRow(String label, String value, {Color valueColor = Colors.white}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11.5),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
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
        if (data['epoch_ms'] != null) {
          setState(() {
            _serverOffsetMs = (data['epoch_ms'] as int) + rttHalf - t1;
          });
          _updateClockDisplay();
        }
      }
    } catch (_) {}
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

  Future _fetchCurrentLocation() async {
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
              'Live Selfie Verification',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            content: SizedBox(
              width: 320,
              height: 320,
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
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
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
      if (controller != null) {
        await controller.dispose();
      }
      return null;
    }
  }

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
            'Selfie captured successfully!',
            isSuccess: true,
            autoDismissAfter: const Duration(milliseconds: 3500),
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
          'Selfie captured successfully!',
          isSuccess: true,
          autoDismissAfter: const Duration(milliseconds: 3500),
        );
      }
    } catch (e) {
      _setStatus('Unable to access camera: $e', isSuccess: false);
    }
  }

  Future<void> _submitAttendance(String actionType) async {
    final String empId = _employeeIdController.text.trim();
    final String phone = _phoneController.text.trim();
    final String site = _siteNameController.text.trim();

    if (empId.isEmpty || phone.isEmpty || site.isEmpty) {
      _setStatus('All fields (Name/ID, Phone, Site Location) are required.', isSuccess: false);
      return;
    }

    if (_imageBytes == null || _photoBase64 == null) {
      _setStatus('Selfie verification photo is mandatory for $actionType.', isSuccess: false);
      return;
    }

    await _saveInputsToHistory(empId, phone, site);

    setState(() {
      _isLoading = true;
      _activeAction = actionType;
      _statusDismissTimer?.cancel();
      _statusMessage = 'Recording $actionType... Please wait';
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
              'employee_id': empId,
              'phone_number': phone,
              'site_name': site,
              'action_type': actionType,
              'is_overtime': _isOvertime,
              'latitude': loc['latitude'],
              'longitude': loc['longitude'],
              'photo_base64': _photoBase64 ?? '',
            }),
          )
          .timeout(const Duration(seconds: 15));

      Map respData = {};
      try {
        respData = jsonDecode(response.body) as Map;
      } catch (_) {}

      if (response.statusCode == 200 && (respData['success'] == true || respData['status'] == 'success')) {
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
          _isLoading = false;
          _activeAction = null;
        });

        _setStatus(respData['message'] ?? '$actionType recorded successfully!', isSuccess: true);
        _resetPhotoAndOvertimeOnly();

        // Pop out receipt modal with valid geofence coordinates & Save Screenshot button
        if (mounted) {
          _showValidLogReceiptPopup(newLog);
        }
      } else {
        final String rawErr = (respData['error'] ??
                respData['message'] ??
                'Check-in rejected by server (${response.statusCode}).')
            .toString();
        _setStatus(_sanitizeErrorMessage(rawErr), isSuccess: false);
      }
    } catch (e) {
      _setStatus('Network error: Unable to reach SVTI server. Please check internet connection.', isSuccess: false);
    } finally {
      if (mounted && _isLoading) {
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
            Icon(Icons.power_settings_new, color: Color(0xFFDC2626), size: 24),
            SizedBox(width: 8),
            Text('Reset Session', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          'Are you sure you want to clear current entry fields and reset the session? (Your saved dropdown history will remain available.)',
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
                'Session reset successfully',
                isSuccess: true,
                autoDismissAfter: const Duration(seconds: 3),
              );
            },
            child: const Text('Reset', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _setStatus(String message, {required bool isSuccess, Duration? autoDismissAfter}) {
    _statusDismissTimer?.cancel();
    setState(() {
      _statusMessage = message;
      _isSuccess = isSuccess;
    });

    if (autoDismissAfter != null) {
      _statusDismissTimer = Timer(autoDismissAfter, () {
        if (mounted && _statusMessage == message) {
          setState(() {
            _statusMessage = null;
          });
        }
      });
    }
  }

  void _resetPhotoAndOvertimeOnly() {
    setState(() {
      _photoBase64 = null;
      _imageBytes = null;
      _isOvertime = false;
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
    _statusDismissTimer?.cancel();
    _employeeIdController.dispose();
    _phoneController.dispose();
    _siteNameController.dispose();
    super.dispose();
  }

  String _formatTimestamp(DateTime dt) {
    final String month = dt.month.toString().padLeft(2, '0');
    final String day = dt.day.toString().padLeft(2, '0');
    final String year = dt.year.toString();
    final int hourNum = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final String hour = hourNum.toString().padLeft(2, '0');
    final String minute = dt.minute.toString().padLeft(2, '0');
    final String period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$month/$day/$year $hour:$minute $period';
  }

  Widget _buildAutocompleteField({
    required TextEditingController controller,
    required List<String> suggestions,
    String? labelText,
    required String hintText,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return RawAutocomplete<String>(
      textEditingController: controller,
      focusNode: FocusNode(),
      optionsBuilder: (TextEditingValue textEditingValue) {
        if (suggestions.isEmpty) return const Iterable<String>.empty();
        final query = textEditingValue.text.trim().toLowerCase();
        if (query.isEmpty) {
          return suggestions;
        }
        return suggestions.where((option) => option.toLowerCase().contains(query));
      },
      onSelected: (String selection) {
        controller.text = selection;
        controller.selection = TextSelection.fromPosition(
          TextPosition(offset: selection.length),
        );
      },
      fieldViewBuilder: (
        BuildContext context,
        TextEditingController fieldController,
        FocusNode fieldFocusNode,
        VoidCallback onFieldSubmitted,
      ) {
        return TextField(
          controller: fieldController,
          focusNode: fieldFocusNode,
          keyboardType: keyboardType,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            labelText: labelText,
            hintText: hintText,
            labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
            hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
            prefixIcon: Icon(icon, color: const Color(0xFF38BDF8), size: 20),
            suffixIcon: suggestions.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.arrow_drop_down_rounded, color: Color(0xFF94A3B8), size: 24),
                    tooltip: 'Show saved entries',
                    onPressed: () {
                      fieldFocusNode.requestFocus();
                      final current = fieldController.text;
                      fieldController.value = TextEditingValue(
                        text: current,
                        selection: TextSelection.collapsed(offset: current.length),
                      );
                    },
                  )
                : null,
            filled: true,
            fillColor: const Color(0xFF182238),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF1E293B)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF1E293B)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5),
            ),
          ),
        );
      },
      optionsViewBuilder: (
        BuildContext context,
        AutocompleteOnSelected<String> onSelected,
        Iterable<String> options,
      ) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 340,
              margin: const EdgeInsets.only(top: 4),
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF38BDF8), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.45),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                itemCount: options.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF334155)),
                itemBuilder: (BuildContext context, int index) {
                  final String option = options.elementAt(index);
                  return InkWell(
                    onTap: () => onSelected(option),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.history_rounded, color: Color(0xFF38BDF8), size: 16),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              option,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
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
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF131B2E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 46,
                              height: 46,
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
                                  size: 26,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'SVTI Mobile',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 17,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const Text(
                                    'Employee Field Attendance',
                                    style: TextStyle(
                                      color: Color(0xFF94A3B8),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
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
                            IconButton(
                              tooltip: 'Reset Session',
                              icon: const Icon(Icons.power_settings_new, color: Color(0xFFDC2626), size: 24),
                              onPressed: _confirmPowerExit,
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Container(
                          height: 26,
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFF1E293B)),
                          ),
                          child: const _ScrollingMarqueeText(
                            text: 'Spirituality, Efficiency, Responsiveness, Viability, and Excellence',
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  Container(
                    padding: const EdgeInsets.all(16.0),
                    decoration: BoxDecoration(
                      color: const Color(0xFF131B2E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    child: Column(
                      children: [
                        _buildAutocompleteField(
                          controller: _employeeIdController,
                          suggestions: _savedEmpIds,
                          hintText: 'Full Name / ID *',
                          icon: Icons.person_outline,
                        ),
                        const SizedBox(height: 12),
                        _buildAutocompleteField(
                          controller: _phoneController,
                          suggestions: _savedPhones,
                          hintText: 'Phone Number *',
                          icon: Icons.smartphone,
                          keyboardType: TextInputType.phone,
                        ),
                        const SizedBox(height: 12),
                        _buildAutocompleteField(
                          controller: _siteNameController,
                          suggestions: _savedSites,
                          labelText: 'Site Location *',
                          hintText: 'Site Location *',
                          icon: Icons.location_on_outlined,
                        ),
                        const SizedBox(height: 14),

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

                  InkWell(
                    onTap: _isLoading ? null : _captureSelfie,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
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
                          Icon(
                            Icons.camera_alt_outlined,
                            color: _imageBytes == null ? const Color(0xFFF43F5E) : const Color(0xFF38BDF8),
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _imageBytes == null ? 'Take Selfie Verification *' : 'Selfie Verified ✓',
                            style: TextStyle(
                              color: _imageBytes == null ? const Color(0xFFF43F5E) : const Color(0xFF38BDF8),
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

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

                  Row(
                    children: [
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

                  if (_recentLogs.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Row(
                      children: [
                        Icon(Icons.history_rounded, color: Color(0xFF38BDF8), size: 18),
                        SizedBox(width: 8),
                        Text(
                          'Recent On-Screen Activity Logs',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _recentLogs.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final log = _recentLogs[index];
                        final bool isTimeIn = log['action_type'] == 'Time In';
                        final Uint8List? photoBytes = log['photo_bytes'];

                        return InkWell(
                          onTap: () => _showValidLogReceiptPopup(log),
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFF131B2E),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isTimeIn ? const Color(0xFF2563EB) : const Color(0xFFDC2626),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (photoBytes != null)
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.memory(
                                      photoBytes,
                                      width: 54,
                                      height: 54,
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                else
                                  Container(
                                    width: 54,
                                    height: 54,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF182238),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Icon(Icons.person, color: Color(0xFF94A3B8)),
                                  ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              log['employee_id'] ?? '',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: isTimeIn
                                                  ? const Color(0xFF2563EB).withOpacity(0.2)
                                                  : const Color(0xFFDC2626).withOpacity(0.2),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              (log['action_type'] ?? '').toString().toUpperCase(),
                                              style: TextStyle(
                                                color: isTimeIn
                                                    ? const Color(0xFF60A5FA)
                                                    : const Color(0xFFF87171),
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '📍 ${log['site_name']} • ${log['is_overtime'] == true ? 'OVERTIME' : 'REGULAR'}',
                                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _formatTimestamp(log['timestamp'] as DateTime),
                                        style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
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
}

class _ScrollingMarqueeText extends StatefulWidget {
  final String text;
  const _ScrollingMarqueeText({required this.text});

  @override
  State<_ScrollingMarqueeText> createState() => _ScrollingMarqueeTextState();
}

class _ScrollingMarqueeTextState extends State<_ScrollingMarqueeText> {
  final ScrollController _scrollController = ScrollController();
  Timer? _scrollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startScrolling();
    });
  }

  void _startScrolling() {
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 35), (_) {
      if (!_scrollController.hasClients) return;
      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.offset;
      if (currentScroll >= maxScroll) {
        _scrollController.jumpTo(0);
      } else {
        _scrollController.jumpTo(currentScroll + 1.2);
      }
    });
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: ListView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          const SizedBox(width: 220),
          Center(
            child: Text(
              '★  ${widget.text}  ★',
              style: const TextStyle(
                color: Color(0xFF38BDF8),
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const SizedBox(width: 240),
        ],
      ),
    );
  }
}
