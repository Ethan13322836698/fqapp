import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DramaFeaturePreferences {
  DramaFeaturePreferences._();

  static final instance = DramaFeaturePreferences._();
  static const _key = 'drama_feature_enabled';

  static bool get visible => instance.enabled.value;

  static bool allowsKind(String? kind) =>
      visible || (kind != 'video' && kind != 'manju');

  static bool allowsLabel(String label) =>
      visible || !const {'短剧', '漫剧', '视频', '有声漫画'}.contains(label.trim());

  final ValueNotifier<bool> enabled = ValueNotifier(true);
  Future<void>? _loading;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      enabled.value = preferences.getBool(_key) ?? true;
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  Future<void> setEnabled(bool value) async {
    await load();
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(_key, value)) {
      throw StateError('Could not save short drama preference');
    }
    enabled.value = value;
  }
}
