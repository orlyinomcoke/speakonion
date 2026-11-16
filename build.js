// Copies the static site into dist/ (no dependencies needed).
const fs = require('fs');
const path = require('path');
const out = path.join(__dirname, 'dist');
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
for (const f of ['index.html', 'config.js']) fs.copyFileSync(path.join(__dirname, f), path.join(out, f));
console.log('Built static site into dist/');
