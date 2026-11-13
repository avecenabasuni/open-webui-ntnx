const fs = require('node:fs');
const path = require('node:path');
const { Resvg } = require('@resvg/resvg-js');

const source = fs.readFileSync(path.join(__dirname, 'source/logo.svg'), 'utf8');
const out = path.join(__dirname, 'assets');
fs.mkdirSync(out, { recursive: true });
const nested = source.replace('<svg ', '<svg x="80" y="123" width="352" height="266" ');
const icon = `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512"><rect width="512" height="512" rx="64" fill="#171717"/>${nested}</svg>`;

function png(svg, width) {
  return new Resvg(svg, { fitTo: { mode: 'width', value: width } }).render().asPng();
}
fs.writeFileSync(path.join(out, 'favicon.svg'), icon);
for (const [name, size] of Object.entries({
  'favicon.png': 96,
  'favicon-96x96.png': 96,
  'apple-touch-icon.png': 180,
  'logo.png': 500,
  'web-app-manifest-192x192.png': 192,
  'web-app-manifest-512x512.png': 512,
})) {
  fs.writeFileSync(path.join(out, name), png(icon, size));
}
fs.writeFileSync(path.join(out, 'splash.png'), png(source.replace('#fff', '#171717'), 380));
fs.writeFileSync(path.join(out, 'splash-dark.png'), png(source, 380));
fs.writeFileSync(path.join(out, 'site.webmanifest'), JSON.stringify({
  name: 'DEWA', short_name: 'DEWA', start_url: '/', display: 'standalone',
  theme_color: '#171717', background_color: '#171717',
  icons: [192, 512].map(size => ({
    src: `/static/web-app-manifest-${size}x${size}.png`,
    sizes: `${size}x${size}`, type: 'image/png', purpose: 'any maskable',
  })),
}, null, 2) + '\n');

// ICO directory entries can contain PNG payloads; no raster editor is required.
const sizes = [16, 32, 48];
const images = sizes.map(size => png(icon, size));
const directory = Buffer.alloc(6 + sizes.length * 16);
directory.writeUInt16LE(1, 2);
directory.writeUInt16LE(sizes.length, 4);
let offset = directory.length;
sizes.forEach((size, i) => {
  const entry = 6 + i * 16;
  directory[entry] = directory[entry + 1] = size;
  directory.writeUInt16LE(1, entry + 4);
  directory.writeUInt16LE(32, entry + 6);
  directory.writeUInt32LE(images[i].length, entry + 8);
  directory.writeUInt32LE(offset, entry + 12);
  offset += images[i].length;
});
fs.writeFileSync(path.join(out, 'favicon.ico'), Buffer.concat([directory, ...images]));
console.log(`Rendered ${fs.readdirSync(out).length} DEWA assets from the existing logo.`);
