# Build settings for the organization's server

`production.json` points a build at the live server (https://chat.secline.fyi). Without it, a build
talks to a development server on `localhost`.

```sh
# Run on a connected phone or simulator
flutter run --dart-define-from-file=config/production.json

# Before pressing Run in Xcode: write the settings into the iOS project once
flutter build ios --config-only --dart-define-from-file=config/production.json
```

Release builds made by `.github/workflows/release.yml` take the server from the repository variable
`SKYLINE_DOMAIN` instead. Keep the two in step, and raise `SKYLINE_VERSION` together with `version:` in
`pubspec.yaml`.

Nothing here is secret: the address is the public download page. Signing keys and passwords are never
in this repository.
