// Phase 13 (board 42): versions, the update check, and addresses under /api.
import 'package:flutter_test/flutter_test.dart';
import 'package:skyline/core/api/api_client.dart';
import 'package:skyline/core/config.dart';
import 'package:skyline/core/version.dart';
import 'package:skyline/features/updates/data/release_service.dart';

void main() {
  final base = Uri.parse('https://chat.example.org/api');

  group('versionBelow', () {
    test('compares numerically, not as text', () {
      expect(versionBelow('1.9.3', '1.10.0'), isTrue);
      expect(versionBelow('1.10.0', '1.9.3'), isFalse);
      expect(versionBelow('2.0.0', '2.0.0'), isFalse);
      expect(versionBelow('1.0', '1.0.1'), isTrue);
      expect(versionBelow('junk', '0.0.1'), isTrue);
    });
  });

  group('addresses keep the /api base path', () {
    test('joinPath', () {
      expect(AppConfig.joinPath('/api', '/me/inbox'), '/api/me/inbox');
      expect(AppConfig.joinPath('/api/', 'me'), '/api/me');
      expect(AppConfig.joinPath('', '/me'), '/me');
    });
    test('ApiClient.under keeps the query', () {
      expect(ApiClient.under(base, '/app/releases').toString(), 'https://chat.example.org/api/app/releases');
      expect(ApiClient.under(base, '/me/inbox?after=5').toString(), 'https://chat.example.org/api/me/inbox?after=5');
      expect(ApiClient.under(Uri.parse('http://10.0.2.2:3000'), '/me').toString(), 'http://10.0.2.2:3000/me');
    });
  });

  group('ReleaseService.parse', () {
    Map<String, Object?> latest(String version) => {
          'version': version,
          'notes': ['Faster start', 42, 'Fixes'],
          'android': {'url': '/downloads/skyline-$version.apk', 'size': 52428800},
          'ios': {'url': 'https://testflight.apple.com/join/abc'},
        };

    test('a newer release: the server path goes on the site root, not under /api', () {
      final r = ReleaseService.parse(latest('9.0.0'), base, 'android')!;
      expect(r.version, '9.0.0');
      expect(r.url.toString(), 'https://chat.example.org/downloads/skyline-9.0.0.apk');
      expect(r.size, 52428800);
      expect(r.notes, ['Faster start', 'Fixes']);
    });
    test('a full address is used as it is', () {
      expect(ReleaseService.parse(latest('9.0.0'), base, 'ios')!.url.host, 'testflight.apple.com');
    });
    test('nothing when not newer, no build for this platform, or malformed', () {
      expect(ReleaseService.parse(latest(appVersion), base, 'android'), isNull);
      expect(ReleaseService.parse(latest('0.0.1'), base, 'android'), isNull);
      expect(ReleaseService.parse(latest('9.0.0'), base, 'windows'), isNull);
      expect(ReleaseService.parse(null, base, 'android'), isNull);
      expect(ReleaseService.parse({'version': 9}, base, 'android'), isNull);
      expect(
          ReleaseService.parse({
            'version': '9.0.0',
            'android': {'url': 5}
          }, base, 'android'),
          isNull);
    });
  });
}
