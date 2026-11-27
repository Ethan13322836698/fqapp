import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

const updateRepository = 'ch6vip/novel-sound';
const _maxApkBytes = 256 * 1024 * 1024;
final _officialFeed = Uri.https('novel.tttq.de', '/update/android.json');
final _githubLatest = Uri.https(
  'api.github.com',
  '/repos/$updateRepository/releases/latest',
);

class AppUpdateRelease {
  const AppUpdateRelease({
    required this.version,
    required this.notes,
    required this.filename,
    required this.sources,
    required this.sha256,
  });

  final String version, notes, filename, sha256;
  final List<Uri> sources;
  String get localFilename => 'fqapp-$version.apk';
}

class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

class AppUpdateClient {
  AppUpdateClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  static List<int>? _version(String value) {
    final match = RegExp(
      r'^v?(\d{1,6})\.(\d{1,6})\.(\d{1,6})$',
    ).firstMatch(value);
    if (match == null) return null;
    return [for (var i = 1; i <= 3; i++) int.parse(match[i]!)];
  }

  static int compareVersions(String a, String b) {
    final left = _version(a), right = _version(b);
    if (left == null || right == null) {
      throw const FormatException('无法识别版本号');
    }
    for (var i = 0; i < 3; i++) {
      final difference = left[i].compareTo(right[i]);
      if (difference != 0) return difference;
    }
    return 0;
  }

  static String? apkName(Iterable<String> abis) {
    for (final abi in abis) {
      if (abi == 'arm64-v8a' || abi == 'armeabi-v7a') {
        return 'app-$abi-release.apk';
      }
    }
    return null;
  }

  static Uri? _https(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            !uri.hasFragment
        ? uri
        : null;
  }

  static Uri _asset(String tag, String name) => Uri.https(
    'github.com',
    '/$updateRepository/releases/download/$tag/$name',
  );

  Future<AppUpdateRelease?> check({
    required String installedVersion,
    required Iterable<String> abis,
  }) async {
    final filename = apkName(abis);
    if (filename == null) throw const FormatException('当前设备没有对应的更新包');

    // The mirror serves the same files as the official release. A stale feed
    // must not hide a newer GitHub release from an already updated device.
    try {
      final release = await _candidate(
        _officialFeed,
        filename,
        installedVersion,
        mirror: true,
      );
      if (release != null) return release;
    } on Exception {
      // GitHub is the fallback for unavailable or invalid mirrors.
    }
    return _candidate(_githubLatest, filename, installedVersion);
  }

  Future<AppUpdateRelease?> _candidate(
    Uri feed,
    String filename,
    String installedVersion, {
    bool mirror = false,
  }) async {
    final raw = jsonDecode(await _text(feed, 1024 * 1024));
    if (raw is! Map ||
        raw['draft'] == true ||
        raw['prerelease'] == true ||
        raw['tag_name'] is! String) {
      throw const FormatException('正式版更新信息无效');
    }
    final tag = raw['tag_name'] as String;
    if (!tag.startsWith('v') || _version(tag) == null) {
      throw const FormatException('正式版更新版本号无效');
    }
    if (compareVersions(tag, installedVersion) <= 0) return null;

    Uri? mirrorApk, mirrorChecksums;
    if (mirror) {
      final assets = raw['mirror_assets'];
      if (assets is Map) {
        mirrorApk = _https(assets[filename]);
        mirrorChecksums = _https(assets['SHA256SUMS']);
      }
    } else {
      final assets = raw['assets'];
      if (assets is! List ||
          !assets.any((asset) => asset is Map && asset['name'] == filename) ||
          !assets.any(
            (asset) => asset is Map && asset['name'] == 'SHA256SUMS',
          )) {
        throw const FormatException('正式版暂未提供对应的 APK 和校验文件');
      }
    }

    String? sha;
    if (mirrorChecksums != null) {
      try {
        sha = _checksum(await _text(mirrorChecksums, 64 * 1024), filename);
      } on Exception {
        // Fall back to the manifest attached to this exact GitHub release.
      }
    }
    sha ??= _checksum(
      await _text(_asset(tag, 'SHA256SUMS'), 64 * 1024),
      filename,
    );
    if (sha == null) throw const FormatException('发布清单缺少 APK 的 SHA-256');
    final notes = raw['body'];
    return AppUpdateRelease(
      version: tag.substring(1),
      notes: notes is String ? notes : '',
      filename: filename,
      sources: {?mirrorApk, _asset(tag, filename)}.toList(),
      sha256: sha,
    );
  }

  static String? _checksum(String text, String filename) {
    String? digest;
    final entry = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$');
    for (final line in const LineSplitter().convert(text)) {
      final match = entry.firstMatch(line.trim());
      if (match == null || match[2] != filename) continue;
      final next = match[1]!.toLowerCase();
      if (digest != null && next != digest) {
        throw const FormatException('发布清单包含冲突的 APK 校验值');
      }
      digest = next;
    }
    return digest;
  }

  Future<http.StreamedResponse> _open(Uri url, {Future<void>? cancel}) async {
    for (var hop = 0; hop < 6; hop++) {
      if (_https(url.toString()) == null) {
        throw const FormatException('更新地址必须使用 HTTPS');
      }
      final request = http.AbortableRequest('GET', url, abortTrigger: cancel)
        ..followRedirects = false;
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 12));
      if (response.statusCode == 200) return response;
      await response.stream.listen(null).cancel();
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        throw HttpException('更新服务器返回 HTTP ${response.statusCode}');
      }
      final location = response.headers['location'];
      if (location == null) break;
      url = url.resolve(location);
    }
    throw const FormatException('更新地址重定向无效');
  }

  Future<String> _text(Uri url, int limit) async {
    final response = await _open(url);
    final collected = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 12),
    )) {
      if (collected.length + chunk.length > limit) {
        throw const FormatException('更新信息文件过大');
      }
      collected.addAll(chunk);
    }
    return utf8.decode(collected);
  }

  Future<File> download(
    AppUpdateRelease release,
    Directory destination, {
    required Completer<void> cancel,
    required void Function(int received, int? total) onProgress,
  }) async {
    await destination.create(recursive: true);
    final file = File('${destination.path}/${release.localFilename}');
    final partial = File('${file.path}.part');
    for (final source in release.sources) {
      if (cancel.isCompleted) throw const UpdateCancelled();
      try {
        final output = await partial.open(mode: FileMode.write);
        final digest = _DigestSink();
        final hash = sha256.startChunkedConversion(digest);
        var received = 0;
        try {
          final response = await _open(source, cancel: cancel.future);
          final total = response.contentLength;
          if (total != null && total > _maxApkBytes) {
            await response.stream.listen(null).cancel();
            throw const FormatException('更新包过大');
          }
          await for (final chunk in response.stream.timeout(
            const Duration(seconds: 20),
          )) {
            if (cancel.isCompleted) throw const UpdateCancelled();
            received += chunk.length;
            if (received > _maxApkBytes) throw const FormatException('更新包过大');
            await output.writeFrom(chunk);
            hash.add(chunk);
            onProgress(received, total);
          }
        } finally {
          hash.close();
          await output.close();
        }
        if (cancel.isCompleted) throw const UpdateCancelled();
        if (digest.value?.toString() != release.sha256) {
          throw const FormatException('APK 的 SHA-256 校验失败');
        }
        return await partial.rename(file.path);
      } on Exception {
        if (cancel.isCompleted) throw const UpdateCancelled();
        if (source == release.sources.last) rethrow;
        onProgress(0, null);
      } finally {
        if (await partial.exists()) await partial.delete();
      }
    }
    throw const FormatException('找不到可用的更新地址');
  }

  void close() => _client.close();
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
