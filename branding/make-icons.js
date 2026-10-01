// Renders Skyline's logo (branding/skyline-logo.svg, board 45 "Blue shield S")
// into every app icon. Needs two dev-only packages, installed anywhere outside
// the repo:  npm install @resvg/resvg-js@2 png-to-ico@2
// then:      node make-icons.js <repo root>   (NODE_PATH pointing at them)
// The drawing is repeated below; keep it identical to skyline-logo.svg.
const fs = require('fs');
const path = require('path');
const { Resvg } = require('@resvg/resvg-js');
const pngToIco = require('png-to-ico');

const repo = process.argv[2];
const mobile = path.join(repo, 'apps/mobile');

const SHIELD = '<path d="M60 20L31 32V55C31 75 43 90 60 98C77 90 89 75 89 55V32Z" fill="#3A63D8"/>' +
  '<path d="M70 45C67 38 51 38 51 47C51 55 69 54 69 64C69 73 53 75 49 68" fill="none" stroke="#FFFFFF" stroke-width="8" stroke-linecap="round"/>' +
  '<circle cx="78" cy="34" r="4" fill="#E8A33D"/>';
// Rounded tile (Windows, Android legacy, favicons) and full-bleed square (iOS
// masks it itself; Apple rejects transparency).
const rounded = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120"><rect width="120" height="120" rx="28" fill="#0C111C"/>${SHIELD}</svg>`;
const square = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120"><rect width="120" height="120" fill="#0C111C"/>${SHIELD}</svg>`;
// Android adaptive foreground: the shield inside the 66/108 safe zone.
const foreground = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120"><g transform="translate(60 59) scale(0.82) translate(-60 -59)">${SHIELD}</g></svg>`;
// Android 13 themed icon: one colour, the system tints it.
const monochrome = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120"><g transform="translate(60 59) scale(0.82) translate(-60 -59)"><path d="M60 20L31 32V55C31 75 43 90 60 98C77 90 89 75 89 55V32Z" fill="#FFFFFF"/><path d="M70 45C67 38 51 38 51 47C51 55 69 54 69 64C69 73 53 75 49 68" fill="none" stroke="#000000" stroke-width="8" stroke-linecap="round"/></g></svg>`;

function png(svg, size) {
  return new Resvg(svg, { fitTo: { mode: 'width', value: size } }).render().asPng();
}
function write(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, data);
  console.log('wrote', path.relative(repo, file));
}

// Android
const res = path.join(mobile, 'android/app/src/main/res');
const densities = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
for (const [d, k] of Object.entries(densities)) {
  write(path.join(res, `mipmap-${d}/ic_launcher.png`), png(rounded, Math.round(48 * k)));
  write(path.join(res, `mipmap-${d}/ic_launcher_foreground.png`), png(foreground, Math.round(108 * k)));
  write(path.join(res, `mipmap-${d}/ic_launcher_monochrome.png`), png(monochrome, Math.round(108 * k)));
}
write(path.join(res, 'mipmap-anydpi-v26/ic_launcher.xml'),
  '<?xml version="1.0" encoding="utf-8"?>\n' +
  '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n' +
  '    <background android:drawable="@color/ic_launcher_background"/>\n' +
  '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n' +
  '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n' +
  '</adaptive-icon>\n');
write(path.join(res, 'values/ic_launcher_background.xml'),
  '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">#0C111C</color>\n</resources>\n');

// iOS: every size the asset catalogue lists
const set = path.join(mobile, 'ios/Runner/Assets.xcassets/AppIcon.appiconset');
const contents = JSON.parse(fs.readFileSync(path.join(set, 'Contents.json'), 'utf8'));
for (const img of contents.images) {
  if (!img.filename) continue;
  const px = Math.round(parseFloat(img.size) * parseInt(img.scale, 10));
  write(path.join(set, img.filename), png(square, px));
}

// Windows
const sizes = [16, 24, 32, 48, 64, 128, 256];
pngToIco(sizes.map((s) => png(rounded, s))).then((ico) => {
  write(path.join(mobile, 'windows/runner/resources/app_icon.ico'), ico);
});
// The icon by the clock (board 49): small sizes only, loaded at runtime.
pngToIco([16, 20, 24, 32, 48].map((s) => png(rounded, s))).then((ico) => {
  write(path.join(mobile, 'assets/icons/tray.ico'), ico);
});

// Web: dashboard and download page favicons, and a PNG for anywhere else
write(path.join(repo, 'apps/dashboard/public/favicon.svg'), rounded + '\n');
write(path.join(repo, 'branding/skyline-logo-1024.png'), png(rounded, 1024));
write(path.join(repo, 'branding/skyline-logo-square-1024.png'), png(square, 1024));
