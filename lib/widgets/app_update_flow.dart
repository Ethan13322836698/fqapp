import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update.dart';

class AppUpdateFlow {
  AppUpdateFlow._();
  static const _channel = MethodChannel('fqapp/app_update');
  static const _ignoredKey = 'app_update_ignored_version';
  static final _releasePage = Uri.https(
    'github.com',
    '/$updateRepository/releases/latest',
  );
  static bool _checking = false;
  static bool _startupChecked = false;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static void startup(BuildContext context) {
    if (_startupChecked || !supported) return;
    _startupChecked = true;
    unawaited(check(context, automatic: true));
  }

  static void _notice(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  static Future<void> _openReleases(BuildContext context) async {
    try {
      final opened = await launchUrl(
        _releasePage,
        mode: LaunchMode.externalApplication,
      );
      if (!opened && context.mounted) _notice(context, '无法打开发布页');
    } on Exception {
      if (context.mounted) _notice(context, '无法打开发布页');
    }
  }

  static Future<void> check(
    BuildContext context, {
    bool automatic = false,
  }) async {
    if (!supported) {
      if (!automatic) await _openReleases(context);
      return;
    }
    if (_checking) {
      if (!automatic) _notice(context, '正在检查更新，请稍候');
      return;
    }
    _checking = true;
    final client = AppUpdateClient();
    try {
      final device = await _channel.invokeMapMethod<String, dynamic>('device');
      if (!context.mounted) return;
      final version = device?['version'];
      final rawAbis = device?['abis'];
      final abis = rawAbis is List
          ? rawAbis.whereType<String>()
          : const <String>[];
      if (device?['supported'] != true ||
          version is! String ||
          AppUpdateClient.apkName(abis) == null) {
        if (!automatic) await _openReleases(context);
        return;
      }
      if (!automatic) _notice(context, '正在检查更新…');
      final release = await client.check(installedVersion: version, abis: abis);
      if (!context.mounted) return;
      if (release == null) {
        if (!automatic) _notice(context, '已是最新正式版');
        return;
      }
      final preferences = await SharedPreferences.getInstance();
      if (!context.mounted ||
          (automatic &&
              (ModalRoute.of(context)?.isCurrent != true ||
                  preferences.getString(_ignoredKey) == release.version))) {
        return;
      }
      final selection = await showDialog<_UpdateChoice>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('发现新版本 v${release.version}'),
          content: SingleChildScrollView(
            child: Text(
              release.notes.trim().isEmpty ? '正式版现已发布。' : release.notes,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, _UpdateChoice.ignore),
              child: const Text('忽略此版本'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, _UpdateChoice.download),
              child: const Text('立即更新'),
            ),
          ],
        ),
      );
      if (selection == _UpdateChoice.ignore) {
        await preferences.setString(_ignoredKey, release.version);
      } else if (selection == _UpdateChoice.download && context.mounted) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              _DownloadUpdateDialog(client: client, release: release),
        );
      }
    } on Exception {
      if (!automatic && context.mounted) {
        _notice(context, '无法完成更新检查，请稍后重试');
      }
    } finally {
      client.close();
      _checking = false;
    }
  }
}

enum _UpdateChoice { ignore, download }

class _DownloadUpdateDialog extends StatefulWidget {
  const _DownloadUpdateDialog({required this.client, required this.release});
  final AppUpdateClient client;
  final AppUpdateRelease release;

  @override
  State<_DownloadUpdateDialog> createState() => _DownloadUpdateDialogState();
}

class _DownloadUpdateDialogState extends State<_DownloadUpdateDialog> {
  final _cancel = Completer<void>();
  int _received = 0;
  int? _total;
  bool _downloading = true;
  bool _installing = false;
  bool _permissionRequired = false;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_download());
  }

  Future<void> _download() async {
    try {
      final cache = await getTemporaryDirectory();
      final directory = Directory('${cache.path}/app_updates');
      if (await directory.exists()) {
        await for (final file in directory.list()) {
          if (file is File &&
              file.uri.pathSegments.last != widget.release.localFilename) {
            await file.delete();
          }
        }
      }
      final elapsed = Stopwatch()..start();
      var lastPaint = -100;
      await widget.client.download(
        widget.release,
        directory,
        cancel: _cancel,
        onProgress: (received, total) {
          final now = elapsed.elapsedMilliseconds;
          if (!mounted || (received != 0 && now - lastPaint < 100)) return;
          lastPaint = now;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _ready = true;
      });
      await _install();
    } on UpdateCancelled {
      if (mounted) Navigator.of(context).pop();
    } on Exception catch (error) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = error is FormatException ? error.message : '下载失败，请检查网络或可用空间';
        });
      }
    }
  }

  Future<void> _install() async {
    if (_installing) return;
    setState(() => _installing = true);
    try {
      final status = await AppUpdateFlow._channel.invokeMethod<String>(
        'install',
        widget.release.localFilename,
      );
      if (!mounted) return;
      if (status == 'opened') {
        Navigator.of(context).pop();
      } else {
        setState(() {
          _permissionRequired = status == 'permission';
          _ready = _permissionRequired;
          _error = _permissionRequired ? null : 'APK 的应用标识、版本或签名与当前安装不符';
        });
      }
    } on Exception {
      if (mounted) setState(() => _error = '无法打开系统安装器');
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _openPermissionSettings() async {
    try {
      await AppUpdateFlow._channel.invokeMethod<void>('permissionSettings');
    } on Exception {
      if (mounted) setState(() => _error = '无法打开系统权限设置');
    }
  }

  @override
  void dispose() {
    if (!_cancel.isCompleted) _cancel.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _total;
    final cancelled = _cancel.isCompleted;
    return PopScope(
      canPop: !_downloading,
      child: AlertDialog(
        title: Text('更新到 v${widget.release.version}'),
        content: _downloading
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: total == null || total <= 0
                        ? null
                        : (_received / total).clamp(0, 1),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    cancelled
                        ? '正在取消…'
                        : '已下载 ${(_received / 1048576).toStringAsFixed(1)} MB',
                  ),
                ],
              )
            : Text(
                _error ??
                    (_permissionRequired
                        ? 'APK 已校验。请在系统设置允许「安装未知应用」，返回后点「继续安装」。'
                        : 'APK 已校验，正在打开系统安装器。'),
              ),
        actions: [
          TextButton(
            onPressed: cancelled || _installing
                ? null
                : () {
                    if (_downloading) {
                      setState(_cancel.complete);
                    } else {
                      Navigator.of(context).pop();
                    }
                  },
            child: Text(_downloading ? '取消下载' : '关闭'),
          ),
          if (_permissionRequired)
            TextButton(
              onPressed: _openPermissionSettings,
              child: const Text('打开系统设置'),
            ),
          if (_ready && !_downloading)
            FilledButton(
              onPressed: _installing ? null : _install,
              child: const Text('继续安装'),
            ),
        ],
      ),
    );
  }
}
