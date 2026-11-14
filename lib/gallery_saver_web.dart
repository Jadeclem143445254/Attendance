import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';

Future<void> saveReceiptToGallery(Uint8List pngBytes, String fileName) async {
  final xFile = XFile.fromData(
    pngBytes,
    mimeType: 'image/png',
    name: '$fileName.png',
  );
  await xFile.saveTo('$fileName.png');
}
