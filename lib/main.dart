import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

import 'gallery_saver_web.dart'
    if (dart.library.io) 'gallery_saver_mobile.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AttendanceApp());
}

class GpsCoords {
  final double latitude;
  final double longitude;

  const GpsCoords(this.latitude, this.longitude);
}

class AttendanceRecord {
  final String employeeId;
  final String phoneNumber;
  final String siteName;
  final String actionType;
  final bool isOvertime;
  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final String googleLocation;
  final Uint8List? photoBytes;

  const AttendanceRecord({
    required this.employeeId,
    required this.phoneNumber,
    required this.siteName,
    required this.actionType,
    required this.isOvertime,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.googleLocation,
    this.photoBytes,
  });
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

  final GlobalKey _receiptBoundaryKey = GlobalKey();

  final TextEditingController _employeeIdController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _siteNameController = TextEditingController();

  bool _isOvertime = false;
  String? _photoBase64;
  Uint8List? _imageBytes;
  bool _isLoading = false;
  bool _isSavingReceipt = false;
  String? _activeAction;
  String? _statusMessage;
  bool _isSuccess = true;

  // Live Digital Clock synced with SVTI Server (Philippine Standard Time UTC+8)
  Timer? _clockTimer;
  int _serverOffsetMs = 0;
  String _liveClockText = '--:--:-- --';
  String _liveDateText = 'Loading Philippine Time...';

  // Post-submission receipt + geolocation map data (hidden on standby)
  AttendanceRecord? _latestReceipt;
  final List<AttendanceRecord> _recentLogs = [];

  static const List<String> _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  static const List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

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
        final dynamic data = jsonDecode(res.body);
        final int t1 = DateTime.now().millisecondsSinceEpoch;
        final int rttHalf = ((t1 - t0) / 2).round();
        if (data is Map && data['epoch_ms'] != null && mounted) {
          setState(() {
            _serverOffsetMs = (data['epoch_ms'] as int) + rttHalf - t1;
          });
          _updateClockDisplay();
        }
      }
    } catch (_) {
      // Uses device clock offset seamlessly if offline
    }
  }

  DateTime _currentManilaTime() {
    final DateTime utcNow = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch + _serverOffsetMs,
      isUtc: true,
    );
    return utcNow.add(const Duration(hours: 8));
  }

  void _updateClockDisplay() {
    final DateTime manilaNow = _currentManilaTime();
    final int hourNum = manilaNow.hour == 0
        ? 12
        : (manilaNow.hour > 12 ? manilaNow.hour - 12 : manilaNow.hour);
    final String hh = hourNum.toString().padLeft(2, '0');
    final String mm = manilaNow.minute.toString().padLeft(2, '0');
    final String ss = manilaNow.second.toString().padLeft(2, '0');
    final String period = manilaNow.hour >= 12 ? 'PM' : 'AM';

    final String weekday = _weekdays[manilaNow.weekday - 1];
    final String month = _months[manilaNow.month - 1];
    final String day = manilaNow.day.toString().padLeft(2, '0');
    final String year = manilaNow.year.toString();

    if (mounted) {
      setState(() {
        _liveClockText = '$hh:$mm:$ss $period';
        _liveDateText = '$weekday, $month $day, $year • PHT (UTC+8)';
      });
    }
  }

  /// Fetches high-accuracy GPS coordinates for geofence & post-submission map
  Future<GpsCoords> _fetchCurrentLocation() async {
    try {
      final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return const GpsCoords(0.0, 0.0);
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          return const GpsCoords(0.0, 0.0);
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return const GpsCoords(0.0, 0.0);
      }

      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 6),
        ),
      );
      return GpsCoords(position.latitude, position.longitude);
    } catch (_) {
      try {
        final Position? lastPos = await Geolocator.getLastKnownPosition();
        if (lastPos != null) {
          return GpsCoords(lastPos.latitude, lastPos.longitude);
        }
      } catch (_) {}
      return const GpsCoords(0.0, 0.0);
    }
  }

  /// Resolves a readable street / Google-style place name from GPS coordinates
  Future<String> _resolveGoogleLocationName(double lat, double lng) async {
    if (lat == 0.0 && lng == 0.0) {
      return 'GPS Unavailable (Enable Location Services)';
    }
    try {
      final Uri uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$lat&lon=$lng',
      );
      final response = await http.get(
        uri,
        headers: {'User-Agent': 'SVTIMobileAttendance/1.0'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final dynamic data = jsonDecode(response.body);
        if (data is Map) {
          final dynamic address = data['address'];
          if (address is Map) {
            final List<String> parts = [];
            final String? place = (data['name'] ??
                    address['building'] ??
                    address['amenity'] ??
                    address['shop'])
                ?.toString();
            final String? road = address['road']?.toString();
            final String? suburb = (address['suburb'] ??
                    address['neighbourhood'] ??
                    address['village'] ??
                    address['quarter'])
                ?.toString();
            final String? city = (address['city'] ??
                    address['town'] ??
                    address['municipality'] ??
                    address['county'])
                ?.toString();
            final String? state =
                (address['state'] ?? address['region'])?.toString();

            if (place != null && place.isNotEmpty) parts.add(place);
            if (road != null && road.isNotEmpty && !parts.contains(road)) {
              parts.add(road);
            }
            if (suburb != null &&
                suburb.isNotEmpty &&
                !parts.contains(suburb)) {
              parts.add(suburb);
            }
            if (city != null && city.isNotEmpty && !parts.contains(city)) {
              parts.add(city);
            }
            if (state != null && state.isNotEmpty && !parts.contains(state)) {
              parts.add(state);
            }

            if (parts.isNotEmpty) {
              return parts.join(', ');
            }
          }
          if (data['display_name'] != null) {
            return data['display_name'].toString();
          }
        }
      }
    } catch (_) {}
    return 'Lat ${lat.toStringAsFixed(6)}, Lng ${lng.toStringAsFixed(6)}';
  }

  /// Desktop fallback camera preview (for browser testing)
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
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text(
              'Live Selfie Verification',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
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
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Color(0xFF94A3B8)),
                ),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
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
                icon: const Icon(
                  Icons.camera_alt,
                  color: Colors.white,
                  size: 18,
                ),
                label: const Text(
                  'Snap Photo',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
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

  /// Captures mandatory front-camera selfie
  Future<void> _captureSelfie() async {
    try {
      final bool isMobileDevice =
          defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS;

      if (kIsWeb && !isMobileDevice) {
        final bytes = await _tryDesktopLiveCamera();
        if (bytes != null) {
          setState(() {
            _imageBytes = bytes;
            _photoBase64 = base64Encode(bytes);
          });
          _setStatus('Selfie captured successfully!', isSuccess: true);
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
        _setStatus('Selfie captured successfully!', isSuccess: true);
      }
    } catch (e) {
      _setStatus('Unable to access camera: $e', isSuccess: false);
    }
  }

  /// Captures the post-submission receipt card as PNG and saves to gallery/browser
  Future<void> _captureAndSaveScreenshot(
    String empId,
    String actionType,
  ) async {
    if (!mounted || _isSavingReceipt) return;
    setState(() => _isSavingReceipt = true);

    try {
      await Future.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;

      final RenderObject? renderObject =
          _receiptBoundaryKey.currentContext?.findRenderObject();
      if (renderObject is! RenderRepaintBoundary) {
        _setStatus('Receipt view not ready yet. Try again.', isSuccess: false);
        return;
      }

      final ui.Image image = await renderObject.toImage(pixelRatio: 3.0);
      final ByteData? byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        _setStatus('Failed to encode receipt image.', isSuccess: false);
        return;
      }

      final Uint8List pngBytes = byteData.buffer.asUint8List();
      final String cleanId =
          empId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final String cleanAction =
          actionType.replaceAll(' ', '_').toUpperCase();
      final int ts = DateTime.now().millisecondsSinceEpoch;
      final String fileName = 'SVTI_${cleanAction}_${cleanId}_$ts';

      await saveReceiptToGallery(pngBytes, fileName);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF065F46),
            content: Text(
              'Attendance receipt saved ($fileName.png)',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF991B1B),
            content: Text(
              'Could not save screenshot: $e',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSavingReceipt = false);
      }
    }
  }

  /// Prompts user to save PNG receipt right after successful submission
  Future<void> _promptSaveScreenshot(String empId, String actionType) async {
    if (!mounted) return;
    await Future.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF131B2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.receipt_long_rounded, color: Color(0xFF38BDF8), size: 22),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Save Attendance Receipt?',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          'Save a PNG receipt of your $actionType with your GPS map and timestamp to your gallery?',
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(
              'Later',
              style: TextStyle(color: Color(0xFF94A3B8)),
            ),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _captureAndSaveScreenshot(empId, actionType);
            },
            icon: const Icon(
              Icons.download_rounded,
              color: Colors.white,
              size: 18,
            ),
            label: const Text(
              'Save PNG',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Submits strict case-sensitive attendance payload to backend
  Future<void> _submitAttendance(String actionType) async {
    final String empId = _employeeIdController.text.trim();
    final String phone = _phoneController.text.trim();
    final String site = _siteNameController.text.trim();

    final List<String> missingFields = [];
    if (empId.isEmpty) missingFields.add('Full Name / ID');
    if (phone.isEmpty) missingFields.add('Phone Number');
    if (site.isEmpty) missingFields.add('Site Location');

    if (missingFields.isNotEmpty) {
      _setStatus(
        'Missing required field(s): ${missingFields.join(', ')}. Inputs are case-sensitive.',
        isSuccess: false,
      );
      return;
    }

    if (_imageBytes == null || _photoBase64 == null) {
      _setStatus(
        'Selfie verification photo is mandatory for $actionType.',
        isSuccess: false,
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _activeAction = actionType;
      _statusMessage = 'Verifying GPS & recording $actionType...';
      _isSuccess = true;
    });

    try {
      final GpsCoords loc = await _fetchCurrentLocation();
      final double lat = loc.latitude;
      final double lng = loc.longitude;

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
              'latitude': lat,
              'longitude': lng,
              'photo_base64': _photoBase64 ?? '',
            }),
          )
          .timeout(const Duration(seconds: 15));

      dynamic respData;
      try {
        respData = jsonDecode(response.body);
      } catch (_) {}

      final bool okFlag = respData is Map &&
          (respData['success'] == true || respData['status'] == 'success');

      if (response.statusCode == 200 && okFlag) {
        final String resolvedAddress =
            (respData['location_name'] ?? respData['address'])?.toString() ??
                await _resolveGoogleLocationName(lat, lng);

        final DateTime submittedAt = _currentManilaTime();
        final String verifiedEmpId =
            (respData['employee_id'] ?? empId).toString();
        final String verifiedSite =
            (respData['site_name'] ?? site).toString();

        final AttendanceRecord newLog = AttendanceRecord(
          employeeId: verifiedEmpId,
          phoneNumber: phone,
          siteName: verifiedSite,
          actionType: actionType,
          isOvertime: _isOvertime,
          timestamp: submittedAt,
          latitude: lat,
          longitude: lng,
          googleLocation: resolvedAddress,
          photoBytes: _imageBytes,
        );

        setState(() {
          _latestReceipt = newLog;
          _recentLogs.insert(0, newLog);
        });

        _setStatus(
          respData['message']?.toString() ??
              '$actionType recorded successfully!',
          isSuccess: true,
        );
        _resetForm();
        _promptSaveScreenshot(verifiedEmpId, actionType);
      } else {
        final String errMsg = (respData is Map
                ? (respData['error'] ??
                    respData['message'] ??
                    respData['detail'])
                : null)
            ?.toString() ??
            'Submission rejected by server (HTTP ${response.statusCode}). Check exact case-sensitive spelling and site geofence.';
        _setStatus(errMsg, isSuccess: false);
      }
    } catch (e) {
      _setStatus(
        'Server connection error: Unable to reach SVTI server. Please check your internet connection.',
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
            Icon(Icons.power_settings_new, color: Color(0xFFDC2626), size: 24),
            SizedBox(width: 8),
            Text(
              'Reset Session',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: const Text(
          'Clear current form inputs, hide the active map receipt, and return to standby mode?',
          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Color(0xFF94A3B8)),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () {
              Navigator.of(context).pop();
              _resetForm();
              setState(() {
                _latestReceipt = null;
              });
              _setStatus('Session reset to standby.', isSuccess: true);
            },
            child: const Text(
              'Reset',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
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
    _clockTimer?.cancel();
    _employeeIdController.dispose();
    _phoneController.dispose();
    _siteNameController.dispose();
    super.dispose();
  }

  String _formatTimestamp(DateTime dt) {
    final String month = dt.month.toString().padLeft(2, '0');
    final String day = dt.day.toString().padLeft(2, '0');
    final String year = dt.year.toString();
    final int hourNum =
        dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final String hour = hourNum.toString().padLeft(2, '0');
    final String minute = dt.minute.toString().padLeft(2, '0');
    final String second = dt.second.toString().padLeft(2, '0');
    final String period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$month/$day/$year $hour:$minute:$second $period PHT';
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String labelText,
    required String hintText,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      textCapitalization: TextCapitalization.none,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: labelText,
        hintText: hintText,
        labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
        hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
        prefixIcon: Icon(icon, color: const Color(0xFF38BDF8), size: 20),
        filled: true,
        fillColor: const Color(0xFF182238),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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
  }

  Widget _buildPostSubmissionReceiptCard(AttendanceRecord receipt) {
    final bool isTimeIn = receipt.actionType == 'Time In';
    final double lat = receipt.latitude;
    final double lng = receipt.longitude;
    final bool hasValidGps = lat != 0.0 || lng != 0.0;
    final Uint8List? photoBytes = receipt.photoBytes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RepaintBoundary(
          key: _receiptBoundaryKey,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF131B2E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isTimeIn
                    ? const Color(0xFF2563EB)
                    : const Color(0xFFDC2626),
                width: 1.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Receipt Top Banner
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isTimeIn
                            ? const Color(0x332563EB)
                            : const Color(0x33DC2626),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${receipt.actionType.toUpperCase()} VERIFIED',
                        style: TextStyle(
                          color: isTimeIn
                              ? const Color(0xFF60A5FA)
                              : const Color(0xFFF87171),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      receipt.isOvertime ? 'OVERTIME' : 'REGULAR',
                      style: const TextStyle(
                        color: Color(0xFF38BDF8),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Employee Details + Selfie Thumbnail
                Row(
                  children: [
                    if (photoBytes != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(
                          photoBytes,
                          width: 58,
                          height: 58,
                          fit: BoxFit.cover,
                        ),
                      ),
                    if (photoBytes != null) const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            receipt.employeeId,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Site: ${receipt.siteName}',
                            style: const TextStyle(
                              color: Color(0xFFCBD5E1),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _formatTimestamp(receipt.timestamp),
                            style: const TextStyle(
                              color: Color(0xFF38BDF8),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),
                const Divider(color: Color(0xFF1E293B), height: 1),
                const SizedBox(height: 10),

                // Google Location Name & Coordinates
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.place_rounded,
                      color: Color(0xFF34D399),
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Google Location / Street Address',
                            style: TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            receipt.googleLocation,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (hasValidGps) ...[
                            const SizedBox(height: 2),
                            Text(
                              'GPS: ${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
                              style: const TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 10,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),

                // Post-Submission Geolocation Street Map (Hidden on Standby)
                if (hasValidGps) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      height: 170,
                      width: double.infinity,
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: LatLng(lat, lng),
                          initialZoom: 16.5,
                          interactionOptions: const InteractionOptions(
                            flags: InteractiveFlag.pinchZoom |
                                InteractiveFlag.drag,
                          ),
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.svti.attendance',
                          ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: LatLng(lat, lng),
                                width: 44,
                                height: 44,
                                child: const Icon(
                                  Icons.location_pin,
                                  color: Color(0xFFEF4444),
                                  size: 40,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF38BDF8),
            side: const BorderSide(color: Color(0xFF2563EB)),
            padding: const EdgeInsets.symmetric(vertical: 11),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: _isSavingReceipt
              ? null
              : () => _captureAndSaveScreenshot(
                    receipt.employeeId,
                    receipt.actionType,
                  ),
          icon: const Icon(Icons.photo_library_outlined, size: 18),
          label: Text(
            _isSavingReceipt
                ? 'Saving PNG Receipt...'
                : 'Save PNG Receipt to Gallery',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 14.0),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Top Header + Prominent Live Philippine Time Clock
                  Container(
                    padding: const EdgeInsets.all(16),
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
                              width: 44,
                              height: 44,
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Image.asset(
                                'assets/svti_logo.png',
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, stackTrace) =>
                                    const Icon(
                                  Icons.business_rounded,
                                  color: Color(0xFF2563EB),
                                  size: 26,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
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
                                    'Employee Field Attendance',
                                    style: TextStyle(
                                      color: Color(0xFF94A3B8),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Reset Session',
                              icon: const Icon(
                                Icons.power_settings_new,
                                color: Color(0xFFDC2626),
                                size: 24,
                              ),
                              onPressed: _confirmPowerExit,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF090D16),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF1E293B)),
                          ),
                          child: Column(
                            children: [
                              Text(
                                _liveClockText,
                                style: const TextStyle(
                                  color: Color(0xFF38BDF8),
                                  fontSize: 26,
                                  fontWeight: FontWeight.w800,
                                  fontFamily: 'monospace',
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _liveDateText,
                                style: const TextStyle(
                                  color: Color(0xFF94A3B8),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),

                  // Strict Case-Sensitive Input Form
                  Container(
                    padding: const EdgeInsets.all(16.0),
                    decoration: BoxDecoration(
                      color: const Color(0xFF131B2E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: Text(
                            'All fields are strictly case-sensitive',
                            style: TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        _buildInputField(
                          controller: _employeeIdController,
                          labelText: 'Full Name / ID *',
                          hintText: 'Exact registered Full Name or ID',
                          icon: Icons.person_outline,
                        ),
                        const SizedBox(height: 12),
                        _buildInputField(
                          controller: _phoneController,
                          labelText: 'Phone Number *',
                          hintText: 'Registered Phone Number',
                          icon: Icons.smartphone,
                          keyboardType: TextInputType.phone,
                        ),
                        const SizedBox(height: 12),
                        _buildInputField(
                          controller: _siteNameController,
                          labelText: 'Site Location *',
                          hintText: 'Exact assigned Site Name',
                          icon: Icons.location_on_outlined,
                        ),
                        const SizedBox(height: 12),

                        // Overtime Checkbox
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
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
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                side: const BorderSide(
                                  color: Color(0xFF475569),
                                ),
                                onChanged: (val) =>
                                    setState(() => _isOvertime = val ?? false),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),

                  // Mandatory Selfie Verification Button
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
                          color: _imageBytes == null
                              ? const Color(0xFFE11D48)
                              : const Color(0xFF2563EB),
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.camera_alt_outlined,
                            color: _imageBytes == null
                                ? const Color(0xFFF43F5E)
                                : const Color(0xFF38BDF8),
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _imageBytes == null
                                ? 'Take Selfie Verification *'
                                : 'Selfie Verified ✓ (Tap to Retake)',
                            style: TextStyle(
                              color: _imageBytes == null
                                  ? const Color(0xFFF43F5E)
                                  : const Color(0xFF38BDF8),
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Selfie Preview
                  if (_imageBytes != null) ...[
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        _imageBytes!,
                        height: 150,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ],

                  const SizedBox(height: 14),

                  // TIME IN & TIME OUT Action Buttons
                  Row(
                    children: [
                      Expanded(
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _isLoading
                                ? null
                                : () => _submitAttendance('Time In'),
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
                                  if (_isLoading &&
                                      _activeAction == 'Time In') ...[
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
                                    const Icon(
                                      Icons.arrow_forward_rounded,
                                      color: Colors.white,
                                      size: 18,
                                    ),
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
                            onTap: _isLoading
                                ? null
                                : () => _submitAttendance('Time Out'),
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
                                  if (_isLoading &&
                                      _activeAction == 'Time Out') ...[
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
                                    const Icon(
                                      Icons.logout_rounded,
                                      color: Colors.white,
                                      size: 18,
                                    ),
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

                  // Server Status & Error Diagnostics Banner
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 14),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: _isLoading
                            ? const Color(0xFF1E293B)
                            : (_isSuccess
                                ? const Color(0xFF064E3B)
                                : const Color(0xFF450A0A)),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _isLoading
                              ? const Color(0xFF3B82F6)
                              : (_isSuccess
                                  ? const Color(0xFF059669)
                                  : const Color(0xFFDC2626)),
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
                              _isSuccess
                                  ? Icons.check_circle_rounded
                                  : Icons.error_outline_rounded,
                              color: _isSuccess
                                  ? const Color(0xFF34D399)
                                  : const Color(0xFFF87171),
                              size: 20,
                            ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              _statusMessage!,
                              style: TextStyle(
                                color: _isLoading
                                    ? const Color(0xFF38BDF8)
                                    : (_isSuccess
                                        ? const Color(0xFF34D399)
                                        : const Color(0xFFF87171)),
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // Post-Submission Receipt + Street Map (Hidden on Standby)
                  if (_latestReceipt != null) ...[
                    const SizedBox(height: 18),
                    _buildPostSubmissionReceiptCard(_latestReceipt!),
                  ],

                  // Recent Session Activity Logs
                  if (_recentLogs.length > 1) ...[
                    const SizedBox(height: 20),
                    const Row(
                      children: [
                        Icon(
                          Icons.history_rounded,
                          color: Color(0xFF38BDF8),
                          size: 18,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Earlier Session Submissions',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _recentLogs.length - 1,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final log = _recentLogs[index + 1];
                        final bool isTimeIn = log.actionType == 'Time In';
                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF131B2E),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isTimeIn
                                  ? const Color(0xFF2563EB)
                                  : const Color(0xFFDC2626),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${log.employeeId} • ${log.actionType.toUpperCase()}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${log.siteName} • ${_formatTimestamp(log.timestamp)}',
                                      style: const TextStyle(
                                        color: Color(0xFF94A3B8),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
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
