import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/qr_code_image.dart';
import 'package:qr/qr.dart';

void main() {
  const url = 'https://github.com/cygnusx-1-org/Discoverium';

  testWidgets('takes the requested size', (tester) async {
    await tester.pumpWidget(
      const Center(child: QrCodeImage(data: url, size: 160)),
    );
    expect(tester.getSize(find.byType(QrCodeImage)), const Size(160, 160));
  });

  testWidgets('draws nothing for data too long to encode', (tester) async {
    await tester.pumpWidget(Center(child: QrCodeImage(data: 'x' * 4000)));
    expect(tester.getSize(find.byType(QrCodeImage)), Size.zero);
  });

  /// Checks, pixel by pixel, that the [QrCodeImage] under [key] shows [data]'s
  /// modules inside a four-module quiet zone, at [scale] pixels per module.
  Future<void> expectModules(
    WidgetTester tester,
    GlobalKey key,
    String data,
    int scale,
  ) async {
    final expected = QrImage(
      QrCode(
        payload: QrPayload.fromString(data),
        errorCorrectLevel: QrErrorCorrectLevel.medium,
      ),
    );
    final cells = expected.moduleCount + 8;
    final width = cells * scale;
    expect(tester.getSize(find.byKey(key)), Size.square(width.toDouble()));
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final pixels = (await tester.runAsync(() async {
      final image = await boundary.toImage();
      return image.toByteData();
    }))!;

    bool darkAt(int row, int col) {
      final x = col * scale + scale ~/ 2;
      final y = row * scale + scale ~/ 2;
      return pixels.getUint8((y * width + x) * 4) < 128;
    }

    for (var row = 0; row < cells; row++) {
      for (var col = 0; col < cells; col++) {
        final r = row - 4, c = col - 4;
        final inCode =
            r >= 0 &&
            c >= 0 &&
            r < expected.moduleCount &&
            c < expected.moduleCount;
        expect(
          darkAt(row, col),
          inCode && expected.isDark(r, c),
          reason: 'module at row $row, column $col',
        );
      }
    }
  }

  /// The side, in pixels, at which [data]'s code draws [scale] pixels per
  /// module.
  double sideFor(String data, int scale) =>
      (QrImage(
            QrCode(
              payload: QrPayload.fromString(data),
              errorCorrectLevel: QrErrorCorrectLevel.medium,
            ),
          ).moduleCount +
          8) *
      scale.toDouble();

  testWidgets('draws every module where the encoder puts it, inside a '
      'four-module quiet zone', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Center(
        child: RepaintBoundary(
          key: key,
          child: QrCodeImage(data: url, size: sideFor(url, 4)),
        ),
      ),
    );
    await expectModules(tester, key, url, 4);
  });

  testWidgets('redraws when the data changes', (tester) async {
    const other = 'https://codeberg.org/example/other-app';
    final key = GlobalKey();
    Widget build(String data) => Center(
      child: RepaintBoundary(
        key: key,
        child: QrCodeImage(data: data, size: sideFor(data, 4)),
      ),
    );
    await tester.pumpWidget(build(url));
    await tester.pumpWidget(build(other));
    await expectModules(tester, key, other, 4);
  });
}
