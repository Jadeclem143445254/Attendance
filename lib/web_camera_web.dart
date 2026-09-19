import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'dart:typed_data';
import 'package:flutter/material.dart';

Future<Uint8List?> openWebCamDialog(BuildContext context) async {
  final String viewTypeId = 'webcam-view-${DateTime.now().millisecondsSinceEpoch}';
  final html.VideoElement videoElement = html.VideoElement()
    ..style.width = '100%'
    ..style.height = '100%'
    ..style.objectFit = 'cover'
    ..autoplay = true
    ..muted = true
    ..playsInline = true;

  html.MediaStream? stream;
  try {
    stream = await html.window.navigator.mediaDevices?.getUserMedia({'video': true});
    videoElement.srcObject = stream;
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Unable to access webcam: $e')),
    );
    return null;
  }

  ui_web.platformViewRegistry.registerViewFactory(
    viewTypeId,
    (int viewId) => videoElement,
  );

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
            child: HtmlElementView(viewType: viewTypeId),
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
            onPressed: () {
              final canvas = html.CanvasElement(
                width: videoElement.videoWidth > 0 ? videoElement.videoWidth : 640,
                height: videoElement.videoHeight > 0 ? videoElement.videoHeight : 480,
              );
              final ctx = canvas.context2D;
              ctx.drawImage(videoElement, 0, 0);
              final dataUrl = canvas.toDataUrl('image/jpeg', 0.85);
              final base64String = dataUrl.split(',').last;
              capturedBytes = base64Decode(base64String);
              Navigator.of(dialogContext).pop();
            },
            icon: const Icon(Icons.camera_alt, color: Colors.white, size: 18),
            label: const Text('Snap Photo', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      );
    },
  );

  // Stop camera hardware stream when dialog closes
  stream?.getTracks().forEach((track) => track.stop());

  return capturedBytes;
}
