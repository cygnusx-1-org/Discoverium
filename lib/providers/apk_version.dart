// Reads the version an APK declares for itself — the versionCode and
// versionName in its compiled AndroidManifest.xml — and the ABIs its native
// libraries are built for. Over HTTP only the zip's central directory and the
// manifest are fetched, not the whole APK.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

/// The version an APK declares in its own manifest.
class ApkVersion {
  final int versionCode;

  /// The manifest's versionName, or its versionCode when it declares none.
  final String versionName;

  /// The package the APK installs as.
  final String? packageName;

  const ApkVersion(this.versionCode, this.versionName, {this.packageName});
}

/// Random access to the bytes of an APK.
abstract class ApkByteSource {
  /// Size of the whole APK in bytes.
  int get length;

  /// The bytes from [start] up to, but not including, [end].
  Future<Uint8List> read(int start, int end);
}

/// Thrown by an [ApkByteSource] whose server stops serving byte ranges partway
/// through, so the caller can fall back to downloading the APK.
class ApkRangeReadUnavailable implements Exception {
  const ApkRangeReadUnavailable();
}

const int _eocdSignature = 0x06054b50;
const int _centralEntrySignature = 0x02014b50;
const int _localHeaderSignature = 0x04034b50;
const int _eocdLength = 22;
const int _centralEntryLength = 46;
const int _localHeaderLength = 30;

/// The end-of-central-directory record plus the longest comment a zip may carry
/// after it: the record always lies within this many bytes of the end.
const int _eocdSearchLength = _eocdLength + 0xFFFF;

/// The central directory is read this much at a time, stopping at the
/// manifest's entry, so a large APK's directory is seldom read whole.
const int _centralDirectoryChunk = 64 * 1024;

/// Room past the central directory's figures for a local header whose extra
/// field is longer than the directory's copy (zipalign pads it).
const int _localHeaderSlack = 4096;

/// A compiled manifest is tens of kilobytes; an entry claiming more than this
/// is not inflated.
const int _maxManifestLength = 8 * 1024 * 1024;

const String _manifestEntryName = 'AndroidManifest.xml';

/// Reads the version [source] declares in its manifest.
///
/// Null when it cannot be read this way: the bytes are not a zip, the zip is a
/// zip64 archive, there is no manifest at its root (an XAPK, say), or a version
/// is a resource reference that only the resource table could resolve.
Future<ApkVersion?> readApkVersion(ApkByteSource source) async {
  final directory = await _CentralDirectory.open(source);
  if (directory == null) return null;
  final entry = await directory.find(_manifestEntryName);
  if (entry == null) return null;
  final manifest = await _readEntry(source, entry);
  return manifest == null ? null : parseManifestVersion(manifest);
}

/// The ABIs Android installs native libraries for, as `lib/<abi>/` folders.
const Set<String> _nativeLibraryAbis = {
  'arm64-v8a',
  'armeabi-v7a',
  'armeabi',
  'x86_64',
  'x86',
  'riscv64',
  'mips64',
  'mips',
};

/// Finding the ABIs means reading the whole central directory; one claiming
/// more than this is not read.
const int _maxAbiDirectoryLength = 8 * 1024 * 1024;

/// Reads the ABIs [source]'s native libraries are built for, from the
/// `lib/<abi>/` folders its central directory lists. Empty when it has no
/// native code, and so runs on any ABI.
///
/// Null when it cannot be read this way: the bytes are not a zip, the zip is a
/// zip64 archive, its directory is too long to be worth reading, or there is
/// no manifest at its root (an XAPK, say, whose APKs a range read cannot see
/// into, and which would otherwise pass for one without native code).
Future<Set<String>?> readApkAbis(ApkByteSource source) async {
  final directory = await _CentralDirectory.open(source);
  if (directory == null ||
      directory._end - directory._start > _maxAbiDirectoryLength) {
    return null;
  }
  final abis = <String>{};
  var hasManifest = false;
  final read = await directory.forEachName((name) {
    if (name == _manifestEntryName) hasManifest = true;
    if (!name.startsWith('lib/')) return;
    final slash = name.indexOf('/', 4);
    if (slash < 0 || slash == name.length - 1) return;
    final abi = name.substring(4, slash);
    if (_nativeLibraryAbis.contains(abi)) abis.add(abi);
  });
  return read && hasManifest ? abis : null;
}

/// The offset in [tail] of the end-of-central-directory record: the last
/// signature whose comment runs exactly to the end of the file.
int _findEndOfCentralDirectory(Uint8List tail) {
  final data = ByteData.sublistView(tail);
  for (var i = tail.length - _eocdLength; i >= 0; i--) {
    if (data.getUint32(i, Endian.little) == _eocdSignature &&
        i + _eocdLength + data.getUint16(i + 20, Endian.little) ==
            tail.length) {
      return i;
    }
  }
  return -1;
}

class _ZipEntry {
  final int method;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;

  const _ZipEntry(
    this.method,
    this.compressedSize,
    this.uncompressedSize,
    this.localHeaderOffset,
  );
}

/// A zip's central directory, fetched only as far as a lookup needs.
class _CentralDirectory {
  _CentralDirectory(this._source, this._start, this._end, this._entryCount);

  final ApkByteSource _source;
  final int _start;
  final int _end;
  final int _entryCount;
  Uint8List _bytes = Uint8List(0);

  /// [source]'s central directory, located from its end-of-central-directory
  /// record, or null when it is not a zip this can read.
  static Future<_CentralDirectory?> open(ApkByteSource source) async {
    final size = source.length;
    if (size < _eocdLength) return null;
    final tailStart = max(0, size - _eocdSearchLength);
    final tail = await source.read(tailStart, size);
    final eocd = _findEndOfCentralDirectory(tail);
    if (eocd < 0) return null;
    final record = ByteData.sublistView(tail, eocd);
    final entryCount = record.getUint16(10, Endian.little);
    final directorySize = record.getUint32(12, Endian.little);
    final directoryStart = record.getUint32(16, Endian.little);
    if (entryCount == 0xFFFF ||
        directoryStart == 0xFFFFFFFF ||
        directoryStart + directorySize > tailStart + eocd) {
      return null;
    }
    final directory = _CentralDirectory(
      source,
      directoryStart,
      directoryStart + directorySize,
      entryCount,
    );
    if (directoryStart >= tailStart) {
      directory.hold(
        Uint8List.sublistView(
          tail,
          directoryStart - tailStart,
          directoryStart - tailStart + directorySize,
        ),
      );
    }
    return directory;
  }

  /// Supplies directory bytes that were already read, from its start.
  void hold(Uint8List bytes) => _bytes = bytes;

  /// Makes sure the directory is held up to the absolute offset [end].
  Future<bool> _holdUpTo(int end) async {
    if (end > _end) return false;
    final held = _start + _bytes.length;
    if (end <= held) return true;
    final next = min(_end, max(end, held + _centralDirectoryChunk));
    final more = await _source.read(held, next);
    if (more.length != next - held) return false;
    _bytes =
        (BytesBuilder(copy: false)
              ..add(_bytes)
              ..add(more))
            .takeBytes();
    return true;
  }

  Future<_ZipEntry?> find(String name) async {
    final wanted = utf8.encode(name);
    var position = _start;
    for (var i = 0; i < _entryCount; i++) {
      if (!await _holdUpTo(position + _centralEntryLength)) return null;
      final at = position - _start;
      var data = ByteData.sublistView(_bytes);
      if (data.getUint32(at, Endian.little) != _centralEntrySignature) {
        return null;
      }
      final nameLength = data.getUint16(at + 28, Endian.little);
      final entryLength =
          _centralEntryLength +
          nameLength +
          data.getUint16(at + 30, Endian.little) +
          data.getUint16(at + 32, Endian.little);
      if (nameLength == wanted.length) {
        if (!await _holdUpTo(position + _centralEntryLength + nameLength)) {
          return null;
        }
        data = ByteData.sublistView(_bytes);
        if (_bytesMatch(_bytes, at + _centralEntryLength, wanted)) {
          return _ZipEntry(
            data.getUint16(at + 10, Endian.little),
            data.getUint32(at + 20, Endian.little),
            data.getUint32(at + 24, Endian.little),
            data.getUint32(at + 42, Endian.little),
          );
        }
      }
      position += entryLength;
    }
    return null;
  }

  /// Calls [visit] with the name of every entry, reading the whole directory.
  /// False when it is malformed or could not be read to its end.
  Future<bool> forEachName(void Function(String name) visit) async {
    if (!await _holdUpTo(_end)) return false;
    final data = ByteData.sublistView(_bytes);
    var at = 0;
    for (var i = 0; i < _entryCount; i++) {
      if (at + _centralEntryLength > _bytes.length ||
          data.getUint32(at, Endian.little) != _centralEntrySignature) {
        return false;
      }
      final nameLength = data.getUint16(at + 28, Endian.little);
      final nameEnd = at + _centralEntryLength + nameLength;
      if (nameEnd > _bytes.length) return false;
      visit(
        utf8.decode(
          Uint8List.sublistView(_bytes, at + _centralEntryLength, nameEnd),
          allowMalformed: true,
        ),
      );
      at =
          nameEnd +
          data.getUint16(at + 30, Endian.little) +
          data.getUint16(at + 32, Endian.little);
    }
    return true;
  }
}

bool _bytesMatch(Uint8List bytes, int offset, List<int> wanted) {
  for (var i = 0; i < wanted.length; i++) {
    if (bytes[offset + i] != wanted[i]) return false;
  }
  return true;
}

/// The uncompressed contents of [entry], or null when it cannot be read.
Future<Uint8List?> _readEntry(ApkByteSource source, _ZipEntry entry) async {
  if (entry.compressedSize > _maxManifestLength ||
      entry.uncompressedSize > _maxManifestLength) {
    return null;
  }
  final start = entry.localHeaderOffset;
  final guessEnd = min(
    source.length,
    start +
        _localHeaderLength +
        _manifestEntryName.length +
        _localHeaderSlack +
        entry.compressedSize,
  );
  if (start + _localHeaderLength > guessEnd) return null;
  var bytes = await source.read(start, guessEnd);
  final header = ByteData.sublistView(bytes);
  if (header.getUint32(0, Endian.little) != _localHeaderSignature) {
    return null;
  }
  final dataStart =
      _localHeaderLength +
      header.getUint16(26, Endian.little) +
      header.getUint16(28, Endian.little);
  final dataEnd = dataStart + entry.compressedSize;
  if (start + dataEnd > source.length) return null;
  if (dataEnd > bytes.length) {
    bytes =
        (BytesBuilder(copy: false)
              ..add(bytes)
              ..add(await source.read(start + bytes.length, start + dataEnd)))
            .takeBytes();
  }
  final stored = Uint8List.sublistView(bytes, dataStart, dataEnd);
  switch (entry.method) {
    case 0:
      return stored;
    case 8:
      return _inflate(stored);
    default:
      return null;
  }
}

/// [compressed] inflated, or null when it is malformed or inflates past
/// [_maxManifestLength]. The central directory's uncompressed size is only a
/// claim, so the limit is held against the output itself: a crafted entry
/// could otherwise inflate to any size in memory.
Uint8List? _inflate(Uint8List compressed) {
  final output = _BoundedBytes(_maxManifestLength);
  try {
    ZLibDecoder(raw: true).startChunkedConversion(output)
      ..addSlice(compressed, 0, compressed.length, false)
      ..close();
  } on FormatException {
    return null;
  } on _TooLong {
    return null;
  }
  return output.takeBytes();
}

class _TooLong implements Exception {
  const _TooLong();
}

/// Collects bytes up to a limit, throwing [_TooLong] as soon as it is passed.
class _BoundedBytes implements Sink<List<int>> {
  _BoundedBytes(this._limit);

  final int _limit;
  final BytesBuilder _bytes = BytesBuilder();

  @override
  void add(List<int> data) {
    if (_bytes.length + data.length > _limit) throw const _TooLong();
    _bytes.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _bytes.takeBytes();
}

const int _chunkXml = 0x0003;
const int _chunkStringPool = 0x0001;
const int _chunkResourceMap = 0x0180;
const int _chunkStartElement = 0x0102;
const int _stringPoolUtf8Flag = 0x100;
const int _valueReference = 0x01;
const int _valueString = 0x03;
const int _valueIntDecimal = 0x10;
const int _valueIntHex = 0x11;
const int _attributeLength = 20;
const int _androidVersionCode = 0x0101021b;
const int _androidVersionName = 0x0101021c;

/// Reads versionCode, versionName and package from the root `<manifest>`
/// element of a compiled (binary XML) AndroidManifest.xml.
///
/// Null when [xml] is not binary XML, is malformed, or gives a version as a
/// resource reference.
ApkVersion? parseManifestVersion(Uint8List xml) {
  if (xml.length < 8) return null;
  final data = ByteData.sublistView(xml);
  if (data.getUint16(0, Endian.little) != _chunkXml) return null;
  _StringPool? strings;
  List<int> resourceIds = const [];
  var offset = data.getUint16(2, Endian.little);
  while (offset + 8 <= xml.length) {
    final type = data.getUint16(offset, Endian.little);
    final headerLength = data.getUint16(offset + 2, Endian.little);
    final chunkEnd = offset + data.getUint32(offset + 4, Endian.little);
    if (headerLength < 8 ||
        offset + headerLength > chunkEnd ||
        chunkEnd > xml.length) {
      return null;
    }
    switch (type) {
      case _chunkStringPool:
        strings = _StringPool.read(data, offset, headerLength, chunkEnd);
        if (strings == null) return null;
      case _chunkResourceMap:
        resourceIds = [
          for (var p = offset + headerLength; p + 4 <= chunkEnd; p += 4)
            data.getUint32(p, Endian.little),
        ];
      case _chunkStartElement:
        // The first element is the root, the only one that carries a version.
        return strings == null
            ? null
            : _manifestVersion(
                data,
                offset + headerLength,
                chunkEnd,
                strings,
                resourceIds,
              );
    }
    offset = chunkEnd;
  }
  return null;
}

ApkVersion? _manifestVersion(
  ByteData data,
  int start,
  int end,
  _StringPool strings,
  List<int> resourceIds,
) {
  if (start + 20 > end) return null;
  if (strings.at(data.getInt32(start + 4, Endian.little)) != 'manifest') {
    return null;
  }
  final attributesStart = start + data.getUint16(start + 8, Endian.little);
  final attributeLength = data.getUint16(start + 10, Endian.little);
  final attributeCount = data.getUint16(start + 12, Endian.little);
  if (attributeLength < _attributeLength) return null;
  // Android's own default when a manifest gives no versionCode.
  var versionCode = 0;
  String? versionName;
  String? packageName;
  for (var i = 0; i < attributeCount; i++) {
    final at = attributesStart + i * attributeLength;
    if (at + _attributeLength > end) return null;
    final nameIndex = data.getInt32(at + 4, Endian.little);
    final rawValue = data.getInt32(at + 8, Endian.little);
    final valueType = data.getUint8(at + 15);
    final value = data.getInt32(at + 16, Endian.little);
    // Android attributes are identified by resource ID, which survives the
    // name stripping some build tools apply to the string pool.
    final resourceId = nameIndex >= 0 && nameIndex < resourceIds.length
        ? resourceIds[nameIndex]
        : null;
    if (resourceId == _androidVersionCode) {
      switch (valueType) {
        case _valueIntDecimal || _valueIntHex:
          versionCode = value;
        case _valueString:
          final parsed = int.tryParse(strings.at(value) ?? '');
          if (parsed == null) return null;
          versionCode = parsed;
        default:
          return null;
      }
    } else if (resourceId == _androidVersionName) {
      if (valueType == _valueReference) return null;
      versionName = strings.at(valueType == _valueString ? value : rawValue);
      if (versionName == null) return null;
    } else if (resourceId == null && strings.at(nameIndex) == 'package') {
      packageName = strings.at(valueType == _valueString ? value : rawValue);
    }
  }
  return ApkVersion(
    versionCode,
    versionNameOrCode(versionName, versionCode),
    packageName: packageName,
  );
}

/// A binary XML string pool, decoding each string only when it is asked for.
class _StringPool {
  _StringPool._(
    this._data,
    this._offsets,
    this._stringsStart,
    this._utf8,
    this._end,
  );

  final ByteData _data;
  final List<int> _offsets;
  final int _stringsStart;
  final bool _utf8;
  final int _end;

  static _StringPool? read(
    ByteData data,
    int start,
    int headerLength,
    int end,
  ) {
    if (headerLength < 28) return null;
    final count = data.getUint32(start + 8, Endian.little);
    final flags = data.getUint32(start + 16, Endian.little);
    final stringsStart = start + data.getUint32(start + 20, Endian.little);
    final offsetsStart = start + headerLength;
    if (offsetsStart + 4 * count > end || stringsStart > end) return null;
    return _StringPool._(
      data,
      [
        for (var i = 0; i < count; i++)
          data.getUint32(offsetsStart + 4 * i, Endian.little),
      ],
      stringsStart,
      (flags & _stringPoolUtf8Flag) != 0,
      end,
    );
  }

  String? at(int index) {
    if (index < 0 || index >= _offsets.length) return null;
    var p = _stringsStart + _offsets[index];
    if (_utf8) {
      // The length in UTF-16 units comes first and is not needed; the length
      // in bytes follows. Each takes a second byte when its high bit is set.
      if (p >= _end) return null;
      p += (_data.getUint8(p) & 0x80) != 0 ? 2 : 1;
      if (p >= _end) return null;
      var length = _data.getUint8(p++);
      if ((length & 0x80) != 0) {
        if (p >= _end) return null;
        length = ((length & 0x7F) << 8) | _data.getUint8(p++);
      }
      if (p + length > _end) return null;
      return utf8.decode(
        Uint8List.sublistView(_data, p, p + length),
        allowMalformed: true,
      );
    }
    if (p + 2 > _end) return null;
    var length = _data.getUint16(p, Endian.little);
    p += 2;
    if ((length & 0x8000) != 0) {
      if (p + 2 > _end) return null;
      length = ((length & 0x7FFF) << 16) | _data.getUint16(p, Endian.little);
      p += 2;
    }
    if (p + 2 * length > _end) return null;
    return String.fromCharCodes([
      for (var i = 0; i < length; i++)
        _data.getUint16(p + 2 * i, Endian.little),
    ]);
  }
}

/// Opens [apk], one of the APKs of the app at [appUrl], for reads over byte
/// ranges. It is resolved exactly as downloadApp resolves it, so the bytes read
/// are the bytes an install would download.
///
/// Null when the server does not serve byte ranges, or when [apk] is a bundle
/// or archive, which keeps its APKs inside another container that a range read
/// cannot see into.
Future<HttpApkByteSource?> openAppApkOverRanges(
  AppSource source,
  String appUrl,
  MapEntry<String, String> apk,
  Map<String, dynamic> additionalSettings,
  SettingsProvider settingsProvider,
) async {
  if (!apk.key.toLowerCase().endsWith('.apk') &&
      AppSource.isApkOrContainerFile(
        apk.key,
        includeArchives: true,
        includeTarballs: true,
      )) {
    return null;
  }
  final settings = await source.buildMergedSettings(
    additionalSettings,
    settingsProvider,
  );
  final url = await source.assetUrlPrefetchModifier(
    await source.generalReqPrefetchModifier(apk.value, settings),
    appUrl,
    settings,
  );
  settings
    ..['allowInsecure'] = TypedSettings(
      additionalSettings,
    ).getBool('allowInsecure')
    ..['allowInsecureRedirects'] = source.allowInsecureRedirects
    ..['enableCertificatePinning'] = settingsProvider.enableCertificatePinning;
  return HttpApkByteSource.open(
    url,
    await source.getRequestHeaders(
      additionalSettings,
      url,
      forAPKDownload: true,
    ),
    settings,
  );
}

/// Reads an APK over HTTP in byte ranges, so only the parts that hold its
/// manifest are downloaded.
class HttpApkByteSource implements ApkByteSource {
  HttpApkByteSource._(this._url, this._headers, this._settings, this.length);

  String _url;
  Map<String, String> _headers;
  final Map<String, dynamic> _settings;

  @override
  final int length;

  /// Opens [url] for ranged reads, or returns null when the server does not
  /// serve byte ranges.
  ///
  /// [settings] are the merged source settings a download of the same URL uses
  /// (TLS, insecure redirects, certificate pinning).
  static Future<HttpApkByteSource?> open(
    String url,
    Map<String, String>? headers,
    Map<String, dynamic> settings,
  ) async {
    // A suffix range ("bytes=-N") would reach the end in one request, but
    // GitHub's asset CDN answers it with 501, so the size comes from a
    // one-byte range instead.
    final first = await _rangedGet(url, headers ?? const {}, settings, 0, 1);
    if (first == null) return null;
    return HttpApkByteSource._(url, headers ?? const {}, settings, first.total)
      .._follow(first.finalUrl);
  }

  /// Sends later reads straight to where the first one was redirected, saving
  /// a redirect per read. A redirect to another origin already withheld the
  /// credentials, so they are dropped for that origin here too.
  void _follow(Uri finalUrl) {
    if (!HttpService.isSameOrigin(Uri.parse(_url), finalUrl)) {
      _headers = Map.of(_headers)
        ..removeWhere(
          (key, _) =>
              !HttpService.safeRedirectHeaders.contains(key.toLowerCase()),
        );
    }
    _url = finalUrl.toString();
  }

  @override
  Future<Uint8List> read(int start, int end) async {
    final result = await _rangedGet(_url, _headers, _settings, start, end);
    if (result == null || result.total != length) {
      throw const ApkRangeReadUnavailable();
    }
    return result.body;
  }

  static final RegExp _contentRange = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$');

  /// The bytes [start] to [end] of [url], or null unless the server returned
  /// exactly that range.
  static Future<({Uri finalUrl, int total, Uint8List body})?> _rangedGet(
    String url,
    Map<String, String> headers,
    Map<String, dynamic> settings,
    int start,
    int end,
  ) async {
    final response = await sourceRequestStreamResponse('GET', {
      ...headers,
      'range': 'bytes=$start-${end - 1}',
      // A compressed body would not be the bytes asked for.
      'accept-encoding': 'identity',
    }, Map<String, dynamic>.from(settings)..['url'] = url);
    final client = response.value.key;
    final res = response.value.value;
    try {
      // Anything but 206 means no usable range. A 200 is the whole APK, which
      // is left unread: closing the client below abandons it.
      if (res.statusCode != HttpStatus.partialContent) return null;
      final match = _contentRange.firstMatch(
        res.headers['content-range']?.first.trim() ?? '',
      );
      if (match == null ||
          int.parse(match.group(1)!) != start ||
          int.parse(match.group(2)!) != end - 1) {
        return null;
      }
      final body = BytesBuilder(copy: false);
      await for (final chunk in res) {
        body.add(chunk);
        if (body.length > end - start) return null;
      }
      if (body.length != end - start) return null;
      return (
        finalUrl: response.key,
        total: int.parse(match.group(3)!),
        body: body.takeBytes(),
      );
    } finally {
      client.close(force: true);
    }
  }
}
