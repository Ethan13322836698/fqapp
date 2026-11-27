import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/media_item.dart';
import 'api_client.dart';
import 'app_log.dart';
import 'episode_source_cache.dart';
import 'playback_issue.dart';

/// The `codec` the Rust core reports for a rendition no platform decoder can
/// play (`BYTEVC2_CODEC` in `rust/src/endpoints/video.rs`). Only a request that
/// declared `transcode=1` can receive it.
const String bytevc2Codec = 'bytevc2';

/// Turns a `bytevc2` rendition into a local H.264 file (issue #466).
///
/// The Rust codec gate refuses every episode that only offers `bytevc2`. A
/// client that ships the patched ffmpeg (`third_party/bytevc2/`, packaged as
/// `libbvc2transcode.so`) declares `transcode=1`, gets that address back
/// instead, and plays it once this service wrote a plain H.264 copy.
///
/// The download stays CENC-encrypted on disk; the transcoder decrypts with the
/// episode's own key, the same posture the download feature keeps.
class Bytevc2TranscodeService {
  Bytevc2TranscodeService._();

  static final Bytevc2TranscodeService instance = Bytevc2TranscodeService._();

  static const MethodChannel _channel = MethodChannel('fqapp/bytevc2transcode');

  static const Duration _transcodeTimeout = Duration(minutes: 10);
  static const Duration _connectTimeout = Duration(seconds: 20);
  static const Duration _readTimeout = Duration(minutes: 3);

  bool? _available;
  final Map<String, Future<String>> _inFlight = {};

  /// Whether this install carries a usable transcoder. The answer cannot change
  /// while the process lives, so it is resolved once. A platform error (the
  /// channel is absent in tests, or on desktop) means "not available".
  ///
  /// The resolved *value* is cached, never the future: a future resolved inside
  /// one zone does not deliver to a caller in another (each widget test runs in
  /// its own fake-async zone), so caching it would hang every later caller.
  Future<bool> available() async =>
      _available ??= await _invokeBool('available');

  Future<bool> _invokeBool(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on PlatformException catch (error) {
      AppLog.w('bytevc2', '$method failed: ${error.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// The source to hand to the player for [episode].
  ///
  /// A `bytevc2` stream is downloaded, transcoded and played from the cache;
  /// every other stream passes through untouched. Throws when the episode
  /// cannot be made playable here: the core's own rejection message when no
  /// transcoder is installed (the pre-#466 verdict, deliberately not
  /// retryable), and a retryable error when the transcode itself failed.
  static Future<EpisodeSource> playable(
    Chapter episode,
    EpisodeSource source,
  ) async {
    if (source.codec != bytevc2Codec) return source;
    final service = Bytevc2TranscodeService.instance;
    if (!await service.available()) {
      throw const ApiException(PlaybackIssue.unsupportedCodecError);
    }
    final path = await service.transcode(episode.itemId, source);
    final url = Platform.isWindows ? Uri.file(path).toString() : 'file://$path';
    return EpisodeSource(
      url,
      '',
      const [],
      source.vertical,
      source.sourceTraceId,
    );
  }

  /// Transcodes [source] into `bytevc2/<itemId>.h264.mp4` and returns its path.
  /// A finished output is reused, so one episode transcodes at most once.
  Future<String> transcode(String itemId, EpisodeSource source) =>
      _inFlight.putIfAbsent(itemId, () async {
        try {
          return await _transcodeEpisode(itemId, source);
        } finally {
          _inFlight.remove(itemId);
        }
      });

  Future<String> _transcodeEpisode(String itemId, EpisodeSource source) async {
    final directory = Directory(
      '${(await getTemporaryDirectory()).path}/bytevc2',
    );
    await directory.create(recursive: true);
    final output = File('${directory.path}/$itemId.h264.mp4');
    if (await _isMp4(output)) return output.path;
    if (output.existsSync()) await output.delete();
    // The encrypted source survives a failed attempt, so a retry only pays for
    // the transcode instead of downloading the episode again.
    final input = File('${directory.path}/$itemId.bytevc2.mp4');
    if (!await _isMp4(input)) {
      if (input.existsSync()) await input.delete();
      await _download(source.url, input);
    }
    final partial = File('${output.path}.part');
    if (partial.existsSync()) await partial.delete();
    try {
      await _transcode(input.path, partial.path, source.keyHex);
      if (!await _isMp4(partial)) {
        throw const ApiException('bytevc2 转码结果不是 MP4');
      }
      await partial.rename(output.path);
    } catch (_) {
      // A file can have an MP4 header and still be truncated or undecodable.
      // Let the next attempt download a fresh source instead of reusing it.
      if (input.existsSync()) {
        try {
          await input.delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      if (partial.existsSync()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
    }
    try {
      await input.delete();
    } catch (_) {
      // 删不掉只是多占一份缓存,不影响播放。
    }
    return output.path;
  }

  Future<void> _transcode(String input, String output, String keyHex) async {
    try {
      // The plugin kills timed-out processes before replying. A Dart timeout
      // cannot cancel a queued native job, so keep file ownership until it ends.
      final result = await _channel.invokeMethod<String>('transcode', {
        'input': input,
        'output': output,
        'keyHex': keyHex,
        'timeoutMs': _transcodeTimeout.inMilliseconds,
      });
      if (result == null || result.isEmpty) {
        throw const ApiException('bytevc2 转码失败');
      }
    } on PlatformException catch (error) {
      AppLog.w('bytevc2', 'transcode failed: ${error.message}');
      throw ApiException('bytevc2 转码失败:${error.message ?? ''}'.trim());
    } on MissingPluginException {
      throw const ApiException(PlaybackIssue.unsupportedCodecError);
    }
  }

  /// Raw download of the rendition, mirroring the download feature's client
  /// setup: no transparent decompression, these URLs are CDN objects signed in
  /// the query string.
  Future<void> _download(String url, File target) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      throw const ApiException('获取播放地址失败');
    }
    final client = HttpClient()
      ..connectionTimeout = _connectTimeout
      ..autoUncompress = false;
    var completed = false;
    try {
      final request = await client.getUrl(uri).timeout(_connectTimeout);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(_readTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException('bytevc2 片源下载失败(${response.statusCode})');
      }
      final handle = await target.open(mode: FileMode.write);
      try {
        await for (final bytes in response.timeout(_readTimeout)) {
          await handle.writeFrom(bytes);
        }
      } finally {
        await handle.close();
      }
      if (!await _isMp4(target)) {
        throw const ApiException('bytevc2 片源不是 MP4');
      }
      completed = true;
    } on SocketException catch (error) {
      throw ApiException('bytevc2 片源下载失败:${error.message}');
    } on HttpException catch (error) {
      throw ApiException('bytevc2 片源下载失败:${error.message}');
    } finally {
      client.close(force: true);
      if (!completed && target.existsSync()) {
        try {
          await target.delete();
        } catch (_) {}
      }
    }
  }

  /// Field check before handing the file to ffmpeg: an error page saved as
  /// `.mp4` would otherwise only surface as an opaque transcode failure.
  Future<bool> _isMp4(File file) async {
    if (!await _usable(file)) return false;
    final handle = await file.open();
    try {
      final header = await handle.read(12);
      return header.length >= 8 &&
          String.fromCharCodes(header.sublist(4, 8)) == 'ftyp';
    } finally {
      await handle.close();
    }
  }

  Future<bool> _usable(File file) async =>
      file.existsSync() && await file.length() > 0;
}
