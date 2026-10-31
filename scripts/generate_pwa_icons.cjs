// Run with Node.js and sharp installed, then generate_startup_images.cjs.
const path = require('node:path');
const sharp = require('sharp');
const root = path.resolve(__dirname, '../priv/static/images/brand');
async function main() {
  for (const size of [32, 180, 192, 512]) {
    await sharp(path.join(root, 'captain_homework-app-icon.svg'), {density: 192})
      .resize(size, size).png().toFile(path.join(root, `captain_homework-icon-${size}.png`));
  }
  await sharp(path.join(root, 'captain_homework-app-icon-maskable.svg'), {density: 192})
    .resize(512, 512).png().toFile(path.join(root, 'captain_homework-icon-maskable-512.png'));
}
main().catch(error => { console.error(error); process.exitCode = 1; });
