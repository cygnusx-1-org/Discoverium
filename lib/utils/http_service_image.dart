import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:obtainium/services/http_service.dart';

/// A [NetworkImage] fetched through [HttpService], so images are loaded with
/// the same TLS trust (Cronet and the Android trust store) and certificate
/// pinning as source requests.
@immutable
class HttpServiceImage extends ImageProvider<HttpServiceImage> {
  const HttpServiceImage(this.url);

  final String url;

  @override
  Future<HttpServiceImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<HttpServiceImage>(this);

  @override
  ImageStreamCompleter loadImage(
    HttpServiceImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(key, decode),
    scale: 1.0,
    debugLabel: url,
  );

  Future<ui.Codec> _load(
    HttpServiceImage key,
    ImageDecoderCallback decode,
  ) async {
    try {
      final res = await HttpService().request('GET', null, {'url': url});
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        throw NetworkImageLoadException(
          statusCode: res.statusCode,
          uri: Uri.parse(url),
        );
      }
      return await decode(
        await ui.ImmutableBuffer.fromUint8List(res.bodyBytes),
      );
    } catch (_) {
      // As NetworkImage does: a failed load must not stay cached, or the
      // image could never be retried.
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is HttpServiceImage && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => '${objectRuntimeType(this, 'HttpServiceImage')}("$url")';
}
