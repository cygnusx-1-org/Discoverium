import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart';

/// [data] as a QR code, encoded on the device and drawn dark on a light square
/// with the standard four-module quiet zone, so a phone camera can read it off
/// a dark theme. Draws nothing for data too long to encode.
class QrCodeImage extends StatefulWidget {
  const QrCodeImage({super.key, required this.data, this.size = 160});

  final String data;
  final double size;

  @override
  State<QrCodeImage> createState() => _QrCodeImageState();
}

class _QrCodeImageState extends State<QrCodeImage> {
  // Encoded once per value, not on every rebuild of the page around it.
  QrImage? _image;

  @override
  void initState() {
    super.initState();
    _image = _encode(widget.data);
  }

  @override
  void didUpdateWidget(QrCodeImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) _image = _encode(widget.data);
  }

  static QrImage? _encode(String data) {
    try {
      return QrImage(
        QrCode(
          payload: QrPayload.fromString(data),
          errorCorrectLevel: QrErrorCorrectLevel.medium,
        ),
      );
    } on InputTooLongException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox.shrink();
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(painter: _QrPainter(image)),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  static const int _quietZone = 4;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final module = size.width / (image.moduleCount + 2 * _quietZone);
    // One path for every dark module, so neighbouring modules fill as a single
    // shape with no anti-aliased seams between them.
    final path = Path();
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (image.isDark(row, col)) {
          path.addRect(
            Rect.fromLTWH(
              (col + _quietZone) * module,
              (row + _quietZone) * module,
              module,
              module,
            ),
          );
        }
      }
    }
    canvas.drawPath(path, Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.image != image;
}
