import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apk_version.dart';

/// An APK held in memory that counts the bytes read from it.
class _MemoryApk implements ApkByteSource {
  _MemoryApk(this._bytes);

  final Uint8List _bytes;
  int bytesRead = 0;

  @override
  int get length => _bytes.length;

  @override
  Future<Uint8List> read(int start, int end) async {
    bytesRead += end - start;
    return Uint8List.sublistView(_bytes, start, end);
  }
}

/// A compiled AndroidManifest.xml as aapt2 produced it: `literal` declares
/// package org.example.fixture, versionCode 1250 and versionName
/// 12.10.1-dec46b0; `reference` gives its versionName as `@string/version_name`.
/// aapt2 writes UTF-16 string pools, so `literal_utf8` is `literal` with its
/// pool re-encoded as UTF-8, which aapt2 reads back the same.
Uint8List _manifest(String name) =>
    File('test/fixtures/manifest_$name.axml').readAsBytesSync();

/// A zip laid out like an APK, holding [files] in order.
_MemoryApk _apk(List<ArchiveFile> files) {
  final archive = Archive();
  files.forEach(archive.addFile);
  return _MemoryApk(ZipEncoder().encodeBytes(archive));
}

ArchiveFile _deflated(String name, List<int> data) =>
    ArchiveFile.bytes(name, data)..compression = CompressionType.deflate;

ArchiveFile _stored(String name, List<int> data) =>
    ArchiveFile.noCompress(name, data.length, data);

void main() {
  group('parseManifestVersion', () {
    test('reads versionCode, versionName and package', () {
      final version = parseManifestVersion(_manifest('literal'))!;
      expect(version.versionCode, 1250);
      expect(version.versionName, '12.10.1-dec46b0');
      expect(version.packageName, 'org.example.fixture');
    });

    test('reads a manifest whose string pool is UTF-8', () {
      final version = parseManifestVersion(_manifest('literal_utf8'))!;
      expect(version.versionCode, 1250);
      expect(version.versionName, '12.10.1-dec46b0');
      expect(version.packageName, 'org.example.fixture');
    });

    test('gives up on a versionName that is a resource reference', () {
      expect(parseManifestVersion(_manifest('reference')), isNull);
    });

    test('gives up on bytes that are not a whole compiled manifest', () {
      final manifest = _manifest('literal');
      expect(
        parseManifestVersion(Uint8List.sublistView(manifest, 0, 200)),
        isNull,
      );
      expect(
        parseManifestVersion(utf8.encode('<manifest package="a.b"/>')),
        isNull,
      );
    });
  });

  group('readApkVersion', () {
    test('reads a deflated manifest', () async {
      final apk = _apk([
        _deflated('AndroidManifest.xml', _manifest('literal')),
        _deflated('classes.dex', List.filled(4096, 7)),
      ]);
      final version = await readApkVersion(apk);
      expect(version?.versionCode, 1250);
      expect(version?.versionName, '12.10.1-dec46b0');
      expect(version?.packageName, 'org.example.fixture');
    });

    test('reads a stored manifest', () async {
      final apk = _apk([
        _stored('classes.dex', List.filled(4096, 7)),
        _stored('AndroidManifest.xml', _manifest('literal')),
      ]);
      expect((await readApkVersion(apk))?.versionCode, 1250);
    });

    test('reads only the end and the manifest of a large APK', () async {
      final random = Random(59);
      final dex = List.generate(4 * 1024 * 1024, (_) => random.nextInt(256));
      final apk = _apk([
        _stored('classes.dex', dex),
        _deflated('AndroidManifest.xml', _manifest('literal')),
        _stored('resources.arsc', dex.sublist(0, 1024 * 1024)),
      ]);
      expect((await readApkVersion(apk))?.versionCode, 1250);
      expect(apk.length, greaterThan(5 * 1024 * 1024));
      expect(apk.bytesRead, lessThan(100 * 1024));
    });

    test('walks a central directory longer than one read', () async {
      final apk = _apk([
        for (var i = 0; i < 4000; i++)
          _stored('res/drawable/icon_$i.png', [i % 256]),
        _deflated('AndroidManifest.xml', _manifest('literal')),
      ]);
      expect((await readApkVersion(apk))?.versionName, '12.10.1-dec46b0');
    });

    test('stops reading the directory once the manifest is found', () async {
      final apk = _apk([
        _deflated('AndroidManifest.xml', _manifest('literal')),
        for (var i = 0; i < 4000; i++)
          _stored('res/drawable/icon_$i.png', [i % 256]),
      ]);
      expect((await readApkVersion(apk))?.versionCode, 1250);
      // The directory alone is over 250 KiB; one 64 KiB read of it suffices.
      expect(apk.bytesRead, lessThan(150 * 1024));
    });

    test('finds no manifest in a bundle that only holds APKs', () async {
      final apk = _apk([
        _deflated('manifest.json', utf8.encode('{}')),
        _stored('org.example.fixture.apk', List.filled(128, 1)),
      ]);
      expect(await readApkVersion(apk), isNull);
    });

    test('gives up on a manifest whose versionName is a reference', () async {
      final apk = _apk([
        _deflated('AndroidManifest.xml', _manifest('reference')),
      ]);
      expect(await readApkVersion(apk), isNull);
    });

    test('gives up on bytes that are not a zip', () async {
      expect(await readApkVersion(_MemoryApk(Uint8List(100000))), isNull);
      expect(await readApkVersion(_MemoryApk(Uint8List(10))), isNull);
    });
  });

  group('readApkAbis', () {
    ArchiveFile manifest() => _deflated('AndroidManifest.xml', [0]);
    ArchiveFile library(String abi) => _stored('lib/$abi/libapp.so', [1]);

    test('reads the ABIs of its native libraries', () async {
      final apk = _apk([
        manifest(),
        _stored('classes.dex', [2]),
        library('arm64-v8a'),
        _stored('lib/arm64-v8a/libflutter.so', [3]),
        library('armeabi-v7a'),
      ]);
      expect(await readApkAbis(apk), {'arm64-v8a', 'armeabi-v7a'});
    });

    test('finds no ABI in an APK with no native code', () async {
      final apk = _apk([
        manifest(),
        _stored('classes.dex', [2]),
      ]);
      expect(await readApkAbis(apk), isEmpty);
    });

    test('ignores lib/ entries that are not native libraries', () async {
      final apk = _apk([
        manifest(),
        _stored('lib/README', [2]),
        _stored('lib/x86_64', [3]),
        _stored('lib/plugins/libfoo.so', [4]),
      ]);
      expect(await readApkAbis(apk), isEmpty);
    });

    test('walks a central directory longer than one read', () async {
      final apk = _apk([
        manifest(),
        for (var i = 0; i < 4000; i++)
          _stored('res/drawable/icon_$i.png', [i % 256]),
        library('x86_64'),
      ]);
      expect(await readApkAbis(apk), {'x86_64'});
    });

    test('gives up on a bundle, whose APKs it cannot see into', () async {
      final apk = _apk([
        _deflated('manifest.json', utf8.encode('{}')),
        _stored('org.example.fixture.apk', List.filled(128, 1)),
        _stored('config.arm64_v8a.apk', List.filled(128, 1)),
      ]);
      expect(await readApkAbis(apk), isNull);
    });

    test('gives up on bytes that are not a zip', () async {
      expect(await readApkAbis(_MemoryApk(Uint8List(100000))), isNull);
    });
  });
}
