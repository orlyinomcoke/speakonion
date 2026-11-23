// In-memory stand-in for supabase-js, used only by the automated tests.
(function () {
  const now = Date.now(), H = 3600e3;
  const T = (id, title, community, a, b, ago) => ({ id, title, community, label_a: a, label_b: b, created_at: new Date(now - ago * H).toISOString(), hidden: false });
  const db = window.__db = {
    topics: [T('t1', "What do you think of Gloc-9's recent endorsement?", 't/showbiz', 'Good', 'Bad', 8), T('t2', 'Pineapple on pizza?', 't/food', 'Yes', 'No', 30),
      T('t3', 'Jollibee or McDo fried chicken?', 't/food', 'Jollibee', 'McDo', 2), T('t4', 'iPhone or Android?', 't/tech', 'iPhone', 'Android', 50), T('t5', 'Should work from home be the default?', 't/work', 'Yes', 'No', 1)],
    profiles: [{ id: 'me', nickname: 'QuietHalohalo722', is_admin: !!window.__mockAdmin, email: 'tester@example.com', terms_accepted_at: window.__mockNoConsent ? null : '2026-11-01T00:00:00Z', banned_until: window.__mockBanned ? 'infinity' : null, ban_reason: window.__mockBanned ? 'Harassment' : null },
      { id: 'u2', nickname: 'BituinBeats404', is_admin: false, email: 'bituin@example.com' }, { id: 'u3', nickname: 'CalmTarsier17', is_admin: false, email: 'calm@example.com' }],
    votes: [
      { id: 1, user_id: 'u2', topic_id: 't1', side: 'a', comment: 'Artists still have bills to pay.', hidden: false, created_at: new Date(now - 2 * H).toISOString() },
      { id: 2, user_id: 'u3', topic_id: 't1', side: 'b', comment: 'Bad example for young fans honestly.', hidden: false, created_at: new Date(now - 1 * H).toISOString() },
      { id: 3, user_id: 'u3', topic_id: 't2', side: 'b', comment: 'Pineapple belongs in desserts only.', hidden: false, created_at: new Date(now - 3 * H).toISOString() }],
    fair_points: [{ vote_id: 2, user_id: 'u2' }], reports: [], blocks: [], chatReports: [], ratings: [], seq: 100, rpcCalls: [], rpcArgs: {}
  };
  (window.__extraTopics || []).forEach((t) => db.topics.push({ label_a: 'Yes', label_b: 'No', ...t }));
  const BANNED = ['gago', 'puta', 'fuck', 'shit', 'bitch', 'pota'];
  const nick = (uid) => (db.profiles.find((p) => p.id === uid) || {}).nickname || 'Anonymous';
  const me = () => (window.__mockUser ? 'me' : null);
  const view = (table) => {
    if (table === 'public_votes') return db.votes.filter((v) => !db.topics.find((t) => t.id === v.topic_id).hidden)
      .map((v) => ({ id: v.id, topic_id: v.topic_id, side: v.side, comment: v.hidden ? null : v.comment, hidden: v.hidden, created_at: v.created_at, masked: nick(v.user_id), fair: db.fair_points.filter((f) => f.vote_id === v.id).length, blocked: db.blocks.some((b) => b.blocker === me() && b.blocked === v.user_id) }));
    if (table === 'topics') return db.topics.filter((t) => !t.hidden || (me() && db.profiles[0].is_admin));
    if (table === 'votes') return db.votes.filter((v) => v.user_id === me());
    if (table === 'profiles') return db.profiles.filter((p) => p.id === me()).map(({ email, ...p }) => p);
    if (table === 'fair_points') return db.fair_points.filter((f) => f.user_id === me());
    if (table === 'reports') return db.reports.filter((r) => r.reporter === me());
    if (table === 'blocks') return db.blocks.filter((b) => b.blocker === me());
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
        const prof = db.profiles[0];
        if (['votes', 'fair_points', 'reports'].includes(table) && (!prof.terms_accepted_at || prof.banned_until)) return err('new row violates row-level security policy');
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
        const list = table === 'votes' ? db.votes : table === 'topics' ? db.topics : table === 'fair_points' ? db.fair_points : table === 'blocks' ? db.blocks : [];
        const hit = (r) => st.filters.every(([k, v]) => r[k] === v);
        if (table !== 'fair_points' && table !== 'blocks' && !db.profiles[0].is_admin) return err('row-level security');
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
  const manilaHour = () => window.__mockManilaHour == null ? (new Date().getUTCHours() + 8) % 24 : window.__mockManilaHour;
  function textProblem(t, allowProfanity) {
    const c = t.toLowerCase().replace(/[^a-z]/g, '');
    if (['patayinkita', 'papatayinkita', 'killyou', 'iwillkill'].some((w) => c.includes(w))) return 'Threats are never allowed.';
    if (/(\+?63|0)9\d{2}[\s-]?\d{3}[\s-]?\d{4}|https?:\/\/|www\.|\w+@\w+\.\w+/i.test(t)) return 'No links, phone numbers or emails.';
    if (!allowProfanity && BANNED.some((w) => t.toLowerCase().split(/[^a-z]+/).includes(w))) return 'Please remove offensive words.';
    return null;
  }
  const matchState = { ended: false, partner: 'u3' };
  async function rpc(name, args) {
    db.rpcCalls.push(name); db.rpcArgs[name] = args;
    const prof = db.profiles[0];
    const canPlay = !!window.__mockUser && !!prof.terms_accepted_at && !prof.banned_until;
    if (name === 'accept_terms') { prof.terms_accepted_at = new Date().toISOString(); return { data: null, error: null }; }
    if (name === 'delete_my_account') { db.votes = db.votes.filter((v) => v.user_id !== 'me'); prof.deleted = true; return { data: null, error: null }; }
    if (name === 'my_blocks') return { data: db.blocks.filter((b) => b.blocker === 'me').map((b) => ({ blocked: b.blocked, nickname: nick(b.blocked) })), error: null };
    if (name === 'block_comment_author') { const v = db.votes.find((x) => x.id === args.p_vote); if (v && v.user_id !== 'me') db.blocks.push({ blocker: 'me', blocked: v.user_id }); return { data: null, error: null }; }
    if (name === 'block_match_partner') { db.blocks.push({ blocker: 'me', blocked: matchState.partner }); matchState.ended = true; return { data: null, error: null }; }
    if (name === 'report_match') { db.chatReports.push({ ...args }); db.blocks.push({ blocker: 'me', blocked: matchState.partner }); matchState.ended = true; return { data: null, error: null }; }
    if (name === 'rate_match') { db.ratings.push({ ...args }); return { data: null, error: null }; }
    if (name === 'admin_ban') { const u = db.profiles.find((x) => x.id === args.target); u.banned_until = args.days == null ? 'infinity' : new Date(Date.now() + args.days * 864e5).toISOString(); u.ban_reason = args.reason; return { data: null, error: null }; }
    if (name === 'admin_unban') { const u = db.profiles.find((x) => x.id === args.target); u.banned_until = null; return { data: null, error: null }; }
    if (name === 'admin_chat_reports') return { data: db.chatReports.map((r, i) => ({ id: i, created_at: new Date().toISOString(), reason: r.p_reason, note: r.p_note, reported: 'u3', reported_nickname: 'CalmTarsier17', reported_email: 'calm@example.com', reported_total: 1, banned_until: db.profiles[2].banned_until, reporter_nickname: 'QuietHalohalo722', topic_title: 'x' })), error: null };
    if (name === 'send_chat') {
      if (matchState.ended) return err('This chat has ended.');
      if (!canPlay) return err("Your account can't chat right now.");
      const prob = textProblem(args.p_text, [0, 12].includes(manilaHour()));
      if (prob) return err(prob);
      const mySide = window.__mySide;
      setTimeout(() => window.__deliver && window.__deliver({ text: args.p_text, side: mySide }), 30);   // server echoes to sender too
      setTimeout(() => window.__deliver && window.__deliver({ text: window.__partnerReply || 'Fair point, but I still disagree.', side: mySide === 'a' ? 'b' : 'a' }), 200);
      return { data: null, error: null };
    }
    if (name === 'server_clock') { const h = window.__mockManilaHour; if (h == null) return { data: [{ now_utc: new Date().toISOString() }], error: null };
      const d = new Date(); d.setUTCHours((h - 8 + 24) % 24, 30, 0, 0); return { data: [{ now_utc: d.toISOString() }], error: null }; }
    if (name === 'find_match') { if (!canPlay) return err("Your account can't chat right now."); if (++matchTries < 2) return { data: [], error: null };
      const mine = db.votes.find((v) => v.user_id === 'me' && v.topic_id === args.p_topic); window.__mySide = mine.side; matchState.ended = false;
      return { data: [{ match_id: 'm1', partner_masked: 'CalmTarsier17', partner_side: mine.side === 'a' ? 'b' : 'a' }], error: null }; }
    if (name === 'admin_list_users') { if (!db.profiles[0].is_admin) return err('Admins only');
      return { data: db.profiles.map((p) => ({ id: p.id, email: p.email, nickname: p.nickname, banned_until: p.banned_until, ban_reason: p.ban_reason, chat_reports: 0, not_respectful: 0, comment_reports: 0, created_at: new Date(now - 48 * H).toISOString(), last_sign_in_at: new Date().toISOString(), email_confirmed: true, is_admin: p.is_admin, votes: db.votes.filter((v) => v.user_id === p.id).length })), error: null }; }
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
        if (name.startsWith('match:')) window.__deliver = (payload) => handlers.filter((x) => x.type === 'broadcast' && x.ev === 'msg').forEach((x) => x.cb({ payload }));
        setTimeout(() => { cb && cb('SUBSCRIBED');
          if (name.startsWith('match:') && !window.__partnerNoShow) setTimeout(() => handlers.filter((x) => x.type === 'presence' && x.ev === 'join').forEach((x) => x.cb({ key: 'u3' })), 150);
        }, 50); return ch; },
      track() { return Promise.resolve('ok'); }, untrack() { return Promise.resolve('ok'); }, presenceState() { return { me: [{}] }; },
      send(m) { ch.sent.push(m); window.__sent = (window.__sent || []).concat(m);
        if (name.startsWith('match:') && m.event === 'msg') window.__clientMsgBroadcast = true;   // should never happen now
        return Promise.resolve('ok'); }
    };
    window.__channels = (window.__channels || []).concat(name);
    return ch;
  }
  window.supabase = { createClient() { return {
    from: q, rpc, channel, removeChannel() {}, realtime: { setAuth: async () => {} },
    auth: { onAuthStateChange(cb) { authCbs.push(cb); }, getSession: async () => ({ data: { session: session() } }),
      signInWithOtp: async ({ email, options }) => { window.__otp = email; window.__otpRedirect = options && options.emailRedirectTo; return { error: null }; },
      verifyOtp: async ({ token }) => { if (token !== '123456') return { error: { message: 'Token has expired or is invalid' } }; window.__mockUser = true; setTimeout(() => authCbs.forEach((cb) => cb('SIGNED_IN', session())), 10); return { data: {}, error: null }; },
      signOut: async () => { window.__mockUser = false; authCbs.forEach((cb) => cb('SIGNED_OUT', null)); } }
  }; } };
})();
