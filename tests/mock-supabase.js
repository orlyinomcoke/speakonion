// In-memory stand-in for supabase-js, used only by the automated tests.
(function () {
  const now = Date.now(), H = 3600e3;
  const T = (id, title, community, a, b, ago) => ({ id, title, community, label_a: a, label_b: b, created_at: new Date(now - ago * H).toISOString(), hidden: false });
  const db = window.__db = {
    topics: [T('t1', "What do you think of Gloc-9's recent endorsement?", 't/showbiz', 'Good', 'Bad', 8), T('t2', 'Pineapple on pizza?', 't/food', 'Yes', 'No', 30),
      T('t3', 'Jollibee or McDo fried chicken?', 't/food', 'Jollibee', 'McDo', 2), T('t4', 'iPhone or Android?', 't/tech', 'iPhone', 'Android', 50), T('t5', 'Should work from home be the default?', 't/work', 'Yes', 'No', 1)],
    profiles: [{ id: 'me', nickname: 'QuietHalohalo722', is_admin: !!window.__mockAdmin, email: 'tester@example.com' },
      { id: 'u2', nickname: 'BituinBeats404', is_admin: false, email: 'bituin@example.com' }, { id: 'u3', nickname: 'CalmTarsier17', is_admin: false, email: 'calm@example.com' }],
    votes: [
      { id: 1, user_id: 'u2', topic_id: 't1', side: 'a', comment: 'Artists still have bills to pay.', hidden: false, created_at: new Date(now - 2 * H).toISOString() },
      { id: 2, user_id: 'u3', topic_id: 't1', side: 'b', comment: 'Bad example for young fans honestly.', hidden: false, created_at: new Date(now - 1 * H).toISOString() },
      { id: 3, user_id: 'u3', topic_id: 't2', side: 'b', comment: 'Pineapple belongs in desserts only.', hidden: false, created_at: new Date(now - 3 * H).toISOString() }],
    fair_points: [{ vote_id: 2, user_id: 'u2' }], reports: [], seq: 100, rpcCalls: []
  };
  const BANNED = ['gago', 'puta', 'fuck', 'shit', 'bitch', 'pota'];
  const nick = (uid) => (db.profiles.find((p) => p.id === uid) || {}).nickname || 'Anonymous';
  const me = () => (window.__mockUser ? 'me' : null);
  const view = (table) => {
    if (table === 'public_votes') return db.votes.filter((v) => !db.topics.find((t) => t.id === v.topic_id).hidden)
      .map((v) => ({ id: v.id, topic_id: v.topic_id, side: v.side, comment: v.hidden ? null : v.comment, hidden: v.hidden, created_at: v.created_at, masked: nick(v.user_id), fair: db.fair_points.filter((f) => f.vote_id === v.id).length }));
    if (table === 'topics') return db.topics.filter((t) => !t.hidden || (me() && db.profiles[0].is_admin));
    if (table === 'votes') return db.votes.filter((v) => v.user_id === me());
    if (table === 'profiles') return db.profiles.filter((p) => p.id === me()).map(({ email, ...p }) => p);
    if (table === 'fair_points') return db.fair_points.filter((f) => f.user_id === me());
    if (table === 'reports') return db.reports.filter((r) => r.reporter === me());
    return [];
  };
  const err = (message) => ({ data: null, error: { message } });
  function q(table) {
    const st = { filters: [], op: 'select', payload: null, single: false };
    const run = () => {
      if (st.op === 'select') { let rows = view(table); st.filters.forEach(([k, v]) => { rows = rows.filter((r) => r[k] === v); }); return { data: st.single ? (rows[0] || null) : rows, error: null }; }
      if (!me()) return err('new row violates row-level security policy');
      if (st.op === 'insert') {
        const row = st.payload;
        if (table === 'votes') {
          if (db.votes.some((v) => v.user_id === 'me' && v.topic_id === row.topic_id)) return err('duplicate key value violates unique constraint');
          if (!row.comment || row.comment.trim().length < 10) return err('comment check failed');
          if (BANNED.some((w) => row.comment.toLowerCase().includes(w))) return err('Please remove offensive words.');
          db.votes.push({ id: ++db.seq, user_id: 'me', hidden: false, created_at: new Date().toISOString(), ...row }); return { data: null, error: null };
        }
        if (table === 'fair_points') { const v = db.votes.find((x) => x.id === row.vote_id); if (v.user_id === 'me') return err('row-level security'); db.fair_points.push({ user_id: 'me', ...row }); return { data: null, error: null }; }
        if (table === 'reports') { db.reports.push({ reporter: 'me', ...row }); return { data: null, error: null }; }
        if (table === 'topics') { if (!db.profiles[0].is_admin) return err('row-level security'); db.topics.push({ id: 't' + (++db.seq), hidden: false, created_at: new Date().toISOString(), ...row }); return { data: null, error: null }; }
      }
      if (st.op === 'update' || st.op === 'delete') {
        const list = table === 'votes' ? db.votes : table === 'topics' ? db.topics : table === 'fair_points' ? db.fair_points : [];
        const hit = (r) => st.filters.every(([k, v]) => r[k] === v);
        if (table !== 'fair_points' && !db.profiles[0].is_admin) return err('row-level security');
        if (st.op === 'update') list.filter(hit).forEach((r) => Object.assign(r, st.payload));
        else for (let i = list.length - 1; i >= 0; i--) if (hit(list[i])) list.splice(i, 1);
        return { data: null, error: null };
      }
      return { data: null, error: null };
    };
    const p = {
      select() { return p; }, order() { return p; }, limit() { return p; },
      eq(k, v) { st.filters.push([k, v]); return p; },
      insert(row) { st.op = 'insert'; st.payload = row; return p; }, update(row) { st.op = 'update'; st.payload = row; return p; }, delete() { st.op = 'delete'; return p; },
      maybeSingle() { st.single = true; return Promise.resolve(run()); },
      then(res, rej) { return Promise.resolve(run()).then(res, rej); }
    };
    return p;
  }
  let matchTries = 0;
  async function rpc(name, args) {
    db.rpcCalls.push(name);
    if (name === 'server_clock') { const h = window.__mockManilaHour; if (h == null) return { data: [{ now_utc: new Date().toISOString() }], error: null };
      const d = new Date(); d.setUTCHours((h - 8 + 24) % 24, 30, 0, 0); return { data: [{ now_utc: d.toISOString() }], error: null }; }
    if (name === 'find_match') { if (++matchTries < 2) return { data: [], error: null };
      const mine = db.votes.find((v) => v.user_id === 'me' && v.topic_id === args.p_topic);
      return { data: [{ match_id: 'm1', partner_masked: 'CalmTarsier17', partner_side: mine.side === 'a' ? 'b' : 'a' }], error: null }; }
    if (name === 'admin_list_users') { if (!db.profiles[0].is_admin) return err('Admins only');
      return { data: db.profiles.map((p) => ({ id: p.id, email: p.email, nickname: p.nickname, created_at: new Date(now - 48 * H).toISOString(), last_sign_in_at: new Date().toISOString(), email_confirmed: true, is_admin: p.is_admin, votes: db.votes.filter((v) => v.user_id === p.id).length })), error: null }; }
    if (name === 'admin_reports') return { data: [], error: null };
    return { data: null, error: null };
  }
  const authCbs = [];
  const session = () => (window.__mockUser ? { user: { id: 'me', email: 'tester@example.com' } } : null);
  function channel(name) {
    const handlers = [];
    const ch = {
      sent: [],
      on(type, filter, cb) { handlers.push({ type, ev: filter.event, cb }); return ch; },
      subscribe(cb) {
        setTimeout(() => { cb && cb('SUBSCRIBED');
          if (name.startsWith('match:') && !window.__partnerNoShow) setTimeout(() => handlers.filter((x) => x.type === 'presence' && x.ev === 'join').forEach((x) => x.cb({ key: 'u3' })), 150);
        }, 50); return ch; },
      track() { return Promise.resolve('ok'); }, untrack() { return Promise.resolve('ok'); }, presenceState() { return { me: [{}] }; },
      send(m) { ch.sent.push(m); window.__sent = (window.__sent || []).concat(m);
        if (name.startsWith('match:') && m.event === 'msg') setTimeout(() => handlers.filter((x) => x.type === 'broadcast' && x.ev === 'msg')
          .forEach((x) => x.cb({ payload: { text: window.__partnerReply || 'Fair point, but I still disagree.' } })), 200);
        return Promise.resolve('ok'); }
    };
    window.__channels = (window.__channels || []).concat(name);
    return ch;
  }
  window.supabase = { createClient() { return {
    from: q, rpc, channel, removeChannel() {}, realtime: { setAuth: async () => {} },
    auth: { onAuthStateChange(cb) { authCbs.push(cb); }, getSession: async () => ({ data: { session: session() } }),
      signInWithOtp: async ({ email }) => { window.__otp = email; return { error: null }; },
      signOut: async () => { window.__mockUser = false; authCbs.forEach((cb) => cb('SIGNED_OUT', null)); } }
  }; } };
})();
