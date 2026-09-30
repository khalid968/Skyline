// Phase 14d end to end (board 46): Alice sets a profile photo; Bob, linked to
// her, gets its key by Signal message, downloads the ciphertext through the
// graph-checked route, decrypts it and sees exactly her picture. Then she
// removes it and Bob is back to initials. Real devices, real vaults, a RUNNING
// throwaway backend. Same --dart-defines as calls_test.dart.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:skyline/core/realtime/realtime_client.dart';
import 'package:skyline/features/profile/data/profile_photos.dart';
import 'package:skyline/src/rust/frb_generated.dart';

import 'messaging_test.dart' show device, eventually;

const aliceId = String.fromEnvironment('ALICE_ID');
const aliceCode = String.fromEnvironment('ALICE_CODE');
const bobCode = String.fromEnvironment('BOB_CODE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('a profile photo reaches a contact, end to end encrypted', (_) async {
    expect(bobCode, isNotEmpty, reason: 'run with the fixture --dart-defines');
    final alice = await device(aliceCode, 'Alice test PC');
    final bob = await device(bobCode, 'Bob test PC');
    final aPhotos = ProfilePhotos(messenger: alice, media: alice.media, store: alice.store);
    final bPhotos = ProfilePhotos(messenger: bob, media: bob.media, store: bob.store);
    addTearDown(() {
      aPhotos.dispose();
      bPhotos.dispose();
      alice.dispose();
      bob.dispose();
    });
    for (final d in [alice, bob]) {
      await eventually(() async => d.connection == ConnectionStatus.online ? true : null);
      await d.refreshContacts();
    }

    // A small real JPEG, as the crop screen makes.
    final jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 64, height: 64)..clear(img.ColorRgb8(58, 99, 216))));
    await aPhotos.setMine(jpeg);
    expect(aPhotos.photoOf(aliceId), jpeg);

    // Bob learns the upload is hers (contacts) and gets the key (message).
    final got = await eventually(() async {
      await bob.refreshContacts();
      await bob.sync();
      return bPhotos.photoOf(aliceId);
    });
    expect(got, jpeg);

    // Removed: Bob is back to initials.
    await aPhotos.removeMine();
    await eventually(() async {
      await bob.refreshContacts();
      await bob.sync();
      return bPhotos.photoOf(aliceId) == null ? true : null;
    });
  });
}
