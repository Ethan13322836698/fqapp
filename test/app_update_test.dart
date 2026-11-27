import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/app_update.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const arm64 = 'app-arm64-v8a-release.apk';
  const armv7 = 'app-armeabi-v7a-release.apk';
  final apk = utf8.encode('signed APK fixture');
  final digest = sha256.convert(apk).toString();
  final github = Uri.https(
    'github.com',
    '/ch6vip/novel-sound/releases/download/v1.0.208/$arm64',
  );
  final mirror = Uri.https('mirror.example', '/$arm64');

  test('numeric version ordering and ABI selection', () {
    expect(
      AppUpdateClient.compareVersions('v1.0.100', '1.0.99'),
      greaterThan(0),
    );
    expect(AppUpdateClient.apkName(['x86_64', 'armeabi-v7a']), armv7);
    expect(AppUpdateClient.apkName(['x86_64']), isNull);
  });

  test('stale mirror falls back to the signed release assets', () async {
    final requests = <Uri>[];
    final client = AppUpdateClient(
      client: MockClient((request) async {
        requests.add(request.url);
        if (request.url.host == 'novel.tttq.de') {
          return http.Response('{"tag_name":"v1.0.207"}', 200);
        }
        if (request.url.host == 'api.github.com') {
          return http.Response(
            jsonEncode({
              'tag_name': 'v1.0.208',
              'body': '新版说明',
              'assets': [
                {'name': arm64},
                {'name': 'SHA256SUMS'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('$digest  $arm64\n', 200);
      }),
    );
    addTearDown(client.close);
    final release = await client.check(
      installedVersion: '1.0.207',
      abis: ['arm64-v8a'],
    );
    expect(release?.sources, [github]);
    expect(release?.notes, '新版说明');
    expect(release?.sha256, digest);
    expect(requests.map((uri) => uri.host), [
      'novel.tttq.de',
      'api.github.com',
      'github.com',
    ]);
  });

  test('mirror APK and checksum work without contacting GitHub', () async {
    final client = AppUpdateClient(
      client: MockClient((request) async {
        if (request.url.host == 'novel.tttq.de') {
          return http.Response(
            jsonEncode({
              'tag_name': 'v1.0.208',
              'mirror_assets': {
                arm64: '$mirror',
                'SHA256SUMS': 'https://mirror.example/SHA256SUMS',
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        expect(request.url.host, 'mirror.example');
        return http.Response('$digest *$arm64\n', 200);
      }),
    );
    addTearDown(client.close);
    final release = await client.check(
      installedVersion: '1.0.207',
      abis: ['arm64-v8a'],
    );
    expect(release?.sources, [mirror, github]);
  });

  test('a prerelease does not become an update candidate', () async {
    final client = AppUpdateClient(
      client: MockClient((_) async {
        return http.Response('{"tag_name":"v1.0.208","prerelease":true}', 200);
      }),
    );
    addTearDown(client.close);
    await expectLater(
      client.check(installedVersion: '1.0.207', abis: ['arm64-v8a']),
      throwsFormatException,
    );
  });

  AppUpdateRelease release(List<Uri> sources) => AppUpdateRelease(
    version: '1.0.208',
    notes: '',
    filename: arm64,
    sources: sources,
    sha256: digest,
  );

  test(
    'a broken mirror falls back and only a verified file is retained',
    () async {
      final client = AppUpdateClient(
        client: MockClient((request) async {
          return request.url == mirror
              ? http.Response('wrong bytes', 200)
              : http.Response.bytes(apk, 200);
        }),
      );
      addTearDown(client.close);
      final directory = await Directory.systemTemp.createTemp(
        'fqapp-update-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await client.download(
        release([mirror, github]),
        directory,
        cancel: Completer<void>(),
        onProgress: (_, _) {},
      );
      expect(await file.readAsBytes(), apk);
      expect(await directory.list().length, 1);
    },
  );

  test('cancellation discards the partial APK', () async {
    final client = AppUpdateClient(
      client: MockClient((_) async => http.Response.bytes(apk, 200)),
    );
    addTearDown(client.close);
    final directory = await Directory.systemTemp.createTemp(
      'fqapp-update-test',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cancelled = Completer<void>();
    await expectLater(
      client.download(
        release([github]),
        directory,
        cancel: cancelled,
        onProgress: (_, _) => cancelled.complete(),
      ),
      throwsA(isA<UpdateCancelled>()),
    );
    expect(await directory.list().isEmpty, isTrue);
  });
}
