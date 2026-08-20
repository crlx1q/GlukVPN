# App assets

Put `logo.png` in this folder:

    flutter-client/assets/logo.png

That is the only file the app needs here. It is used by `GlukLogo`
(`lib/widgets/logo.dart`) on the splash screen, the onboarding header and the
login card. A square PNG works best - the 500x500 file is exactly right, and
Android scales it down for every density.

The folder is declared as a whole in `pubspec.yaml`, so the build does not fail
while the file is missing; the app just shows a plain violet tile instead.

Other places the same artwork is used:

- `control-server/public/logo.png` - admin panel header and favicon
- `android/app/src/main/res/mipmap-*/ic_launcher.png` - the launcher icon,
  generated from the same square PNG
