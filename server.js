// Tiny static server for hosts that run "npm start" (no dependencies).
const http = require('http');
const fs = require('fs');
const path = require('path');
const root = fs.existsSync(path.join(__dirname, 'dist')) ? path.join(__dirname, 'dist') : __dirname;
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon' };
const allowed = new Set(['/index.html', '/config.js']);
http.createServer((req, res) => {
  let p = decodeURIComponent((req.url || '/').split('?')[0]);
  if (p === '/' || !allowed.has(p)) p = '/index.html';
  fs.readFile(path.join(root, p), (err, data) => {
    if (err) { res.writeHead(500); return res.end('Server error'); }
    res.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream', 'X-Content-Type-Options': 'nosniff' });
    res.end(data);
  });
}).listen(process.env.PORT || 3000, () => console.log('Speak Onion running on port ' + (process.env.PORT || 3000)));
