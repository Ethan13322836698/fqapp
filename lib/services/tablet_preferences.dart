import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TabletPreferences {
  TabletPreferences._();
  static final instance = TabletPreferences._();
  static const _key = 'appearance_tablet_mode';

  final enabled = ValueNotifier(false);

  Future<void> load(SharedPreferences preferences) async {
    enabled.value = preferences.getBool(_key) ?? false;
  }

  Future<void> setEnabled(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(_key, value)) {
      throw StateError('Could not save tablet mode');
    }
    enabled.value = value;
  }
}
