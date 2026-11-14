import 'dart:typed_data';
import 'package:gal/gal.dart';

Future<void> saveReceiptToGallery(Uint8List pngBytes, String fileName) async {
  final bool hasAccess = await Gal.hasAccess();
  if (!hasAccess) {
    await Gal.requestAccess();
  }
  await Gal.putImageBytes(pngBytes, name: fileName);
}
