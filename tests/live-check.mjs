// Live smoke + security checks against the deployed site and Supabase (public key only).
// Run: node tests/live-check.mjs   (Node 18+). Used by .github/workflows/live-check.yml
import fs from 'node:fs';
const SITE = process.env.SITE_URL || 'https://green-chamois-573370.hostingersite.com';
const cfg = fs.readFileSync(new URL('../config.js', import.meta.url), 'utf8');
const URL_ = cfg.match(/SUPABASE_URL:\s*'([^']+)'/)[1], KEY = cfg.match(/SUPABASE_ANON_KEY:\s*'([^']+)'/)[1];
const H = { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' };
let fails = 0;
const check = (name, ok, detail = '') => { console.log((ok ? 'PASS ' : 'FAIL ') + name + (!ok && detail ? '  -> ' + detail : '')); if (!ok) fails++; };
const get = (p, o) => fetch(SITE + p, { redirect: 'manual', ...o });
const api = (p, o = {}) => fetch(URL_ + p, { ...o, headers: { ...H, ...(o.headers || {}) } });

// --- website
let r = await get('/'); const html = await r.text();
check('Home page loads (200)', r.status === 200, r.status);
check('Home page is Speak Onion', html.includes('<title>Speak Onion'));
check('Security headers present', r.headers.get('x-content-type-options') === 'nosniff' && r.headers.get('x-frame-options') === 'DENY');
r = await get('/some-shared-topic-link'); check('Topic links serve the app', r.status === 200 && (await r.text()).includes('<title>Speak Onion'));
for (const f of ['/favicon.svg', '/apple-touch-icon.png', '/config.js', '/site.webmanifest']) { r = await get(f); check('Serves ' + f, r.status === 200, r.status); }
for (const f of ['/schema.sql', '/migration-004-chat.sql', '/README.md', '/server.js', '/package.json', '/.git/config', '/tests/e2e.py', '/email-templates/magic-link.html']) {
  r = await get(f); check('Blocks ' + f, r.status === 403 || r.status === 404, r.status);
}
r = await fetch(SITE.replace('https://', 'http://') + '/', { redirect: 'manual' });
check('HTTP redirects to HTTPS', [301, 302, 308].includes(r.status), r.status);

// --- database (as an anonymous visitor)
r = await api('/rest/v1/topics?select=id,title&limit=50'); const topics = await r.json();
check('Topics readable', r.ok && Array.isArray(topics) && topics.length > 0, JSON.stringify(topics).slice(0, 120));
r = await api('/rest/v1/public_votes?select=*&limit=5'); const pv = await r.json();
check('Public comments readable', r.ok, JSON.stringify(pv).slice(0, 120));
const cols = Array.isArray(pv) && pv[0] ? Object.keys(pv[0]) : [];
check('Public comments expose no user id/email', !cols.some((c) => /user|email/i.test(c)), cols.join(','));
check('Public comments use nicknames (migration 006)', !pv[0] || !/\*\*\*@/.test(pv[0].masked || ''), pv[0] && pv[0].masked);
check('Likes column present (migration 009)', !pv[0] || 'fair' in pv[0], cols.join(','));
r = await api('/rest/v1/votes?select=user_id&limit=5'); const raw = await r.json();
check('Raw votes hidden from visitors', Array.isArray(raw) ? raw.length === 0 : !r.ok, JSON.stringify(raw).slice(0, 120));
r = await api('/rest/v1/profiles?select=*&limit=5'); const prof = await r.json();
check('Profiles hidden from visitors', Array.isArray(prof) ? prof.length === 0 : !r.ok);
r = await api('/rest/v1/rpc/admin_list_users', { method: 'POST', body: '{}' });
check('Visitors cannot list users/emails', !r.ok, r.status);
r = await api('/rest/v1/topics', { method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ title: 'live check should fail', label_a: 'a', label_b: 'b' }) });
check('Visitors cannot create topics', !r.ok, r.status);
r = await api('/rest/v1/votes', { method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ topic_id: topics[0] && topics[0].id, side: 'a', comment: 'live check should fail' }) });
check('Visitors cannot vote', !r.ok, r.status);
r = await api('/rest/v1/rpc/find_match', { method: 'POST', body: JSON.stringify({ p_topic: topics[0] && topics[0].id }) });
check('Visitors cannot join chat matching (migration 004)', !r.ok, r.status);
r = await api('/rest/v1/rpc/server_clock', { method: 'POST', body: '{}' }); const clk = await r.json();
check('Server clock available (migration 005)', r.ok && Array.isArray(clk) && 'purge_hour' in clk[0], JSON.stringify(clk).slice(0, 120));
r = await api('/rest/v1/banned_words?select=word&limit=1');
check('Word list exists and is private (migration 003)', r.ok ? (await r.json()).length === 0 : r.status !== 404, r.status);

console.log(fails ? `\n${fails} check(s) FAILED` : '\nAll live checks passed');
process.exit(fails ? 1 : 0);
