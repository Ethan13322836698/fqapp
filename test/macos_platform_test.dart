import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/platform_capabilities.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('macOS uses desktop playback and preserves playback on focus loss', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(isMacOSDesktop, isTrue);
    expect(isWindowsDesktop, isFalse);
    expect(isDesktopPlatform, isTrue);
    expect(supportsVideoPlayback, isTrue);
    expect(playbackAppIsActive(AppLifecycleState.inactive), isTrue);
    expect(playbackAppIsActive(AppLifecycleState.hidden), isFalse);
    expect(desktopInactiveStillVisible(AppLifecycleState.inactive), isTrue);
  });

  test('mobile platforms retain their previous playback capabilities', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(isDesktopPlatform, isFalse);
    expect(supportsVideoPlayback, isFalse);
    expect(playbackAppIsActive(AppLifecycleState.inactive), isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(isDesktopPlatform, isFalse);
    expect(supportsVideoPlayback, isTrue);
  });

  test('Windows retains the shared desktop path', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(isWindowsDesktop, isTrue);
    expect(isMacOSDesktop, isFalse);
    expect(isDesktopPlatform, isTrue);
    expect(supportsVideoPlayback, isTrue);
  });
}
