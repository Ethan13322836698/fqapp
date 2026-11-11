import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/library_backup_page.dart';
import 'package:fqapp/pages/webdav_sync_page.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('archive content starts below the title on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final previous = AppThemeStyleStore.instance.value;
    AppThemeStyleStore.instance.value = AppThemeStyle.archive;
    addTearDown(() => AppThemeStyleStore.instance.value = previous);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 32),
            textScaler: TextScaler.linear(1.3),
          ),
          child: child!,
        ),
        home: const WebDavSyncPage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('云端优先覆盖书架与阅读进度')).dy,
      greaterThan(tester.getBottomRight(find.byType(ArchiveRouteTitle)).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('backup page opens WebDAV settings and validates the address', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LibraryBackupPage()));
    final entry = find.text('WebDAV 同步');
    await tester.drag(
      find.byKey(const ValueKey('backup-scroll')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(WebDavSyncPage), findsOneWidget);
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'http://example.com/',
    );
    final save = find.text('保存设置');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入 HTTPS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saves credentials in secure storage without starting disabled sync',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WebDavSyncPage()));
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'https://dav.example.com/private/',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'reader');
      await tester.enterText(find.byType(TextFormField).at(2), 'dummy-secret');
      final password = tester.widget<TextField>(
        find.descendant(
          of: find.byType(TextFormField).at(2),
          matching: find.byType(TextField),
        ),
      );
      expect(password.obscureText, isTrue);
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      final save = find.text('保存设置');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('设置已安全保存'), findsOneWidget);
      final secure = await const FlutterSecureStorage().readAll();
      final settings = jsonDecode(secure['fqapp.webdav.config.v1']!) as Map;
      expect(settings['password'], 'dummy-secret');
      expect(settings['enabled'], isFalse);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
