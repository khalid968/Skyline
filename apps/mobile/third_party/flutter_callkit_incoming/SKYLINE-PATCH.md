# flutter_callkit_incoming 3.1.6, patched for Skyline

An unmodified copy of [flutter_callkit_incoming](https://github.com/hiennguyen92/flutter_callkit_incoming)
3.1.6 from pub.dev (MIT, see `LICENSE`): `android/`, `ios/`, `lib/` and `pubspec.yaml`. The example,
images and tests are left out. The one change is marked `SKYLINE PATCH` in the code.

## The change (owner decision 2026-10-31)

Declining a call from the phone's call notification, or from its full-screen call screen, now goes
through the plugin's own `TransparentActivity`, exactly like Accept already does. Two files change:
`CallkitNotificationManager.getDeclinePendingIntent` and `CallkitIncomingActivity.onDeclineClick`.

Why: the caller only stops ringing when this phone sends a Signal-encrypted "decline", and only the
running app can encrypt (it alone opens the key vault). Upstream, Decline is a broadcast. On Android 12
and later a broadcast from a notification can't open an app, so with Skyline closed nobody told the
caller, and they heard ringing for 45 seconds. `TransparentActivity` still sends the same decline
broadcast, so the plugin's own bookkeeping is unchanged. It also opens Skyline with the decline action.
Skyline sends the decline, then goes back to the background (`MainActivity`, "skyline/launch").

## Updating

To move to a newer version, copy the same folders from the new release, re-apply the two marked
changes, and update the version above.
