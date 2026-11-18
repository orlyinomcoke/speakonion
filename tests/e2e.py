"""Speak Onion end-to-end simulation. Runs the real index.html against tests/mock-supabase.js.
Usage: python3 tests/e2e.py   (needs: pip install playwright; a Chrome/Chromium)"""
import asyncio, os, subprocess, sys, time, json, re
from playwright.async_api import async_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOCK = os.path.join(ROOT, 'tests', 'mock-supabase.js')
PORT = 8799
BASE = f'http://localhost:{PORT}'
CHROME = os.environ.get('CHROME', '/usr/bin/google-chrome')
results = []

def check(name, ok, detail=''):
    results.append((name, bool(ok), detail))
    print(('PASS ' if ok else 'FAIL ') + name + (('  -> ' + detail) if detail and not ok else ''))

async def new_page(browser, user=False, admin=False, hour=None, w=1320, h=900, extra=''):
    ctx = await browser.new_context(viewport={'width': w, 'height': h})
    init = f"window.__mockUser={json.dumps(user)};window.__mockAdmin={json.dumps(admin)};window.__mockManilaHour={json.dumps(hour)};{extra}"
    await ctx.add_init_script(init)
    pg = await ctx.new_page()
    await pg.route('https://cdn.jsdelivr.net/**', lambda r: r.fulfill(path=MOCK, content_type='text/javascript'))
    await pg.route('https://fonts.googleapis.com/**', lambda r: r.abort())
    await pg.route('https://accounts.google.com/**', lambda r: r.abort())
    pg.errors = []
    pg.on('pageerror', lambda e: pg.errors.append(str(e)))
    return pg

async def load(pg, path='/'):
    await pg.goto(BASE + path); await pg.wait_for_timeout(700)

async def titles(pg):
    return await pg.eval_on_selector_all('.ctitle', 'els=>els.map(e=>e.textContent)')

async def run():
    subprocess.run(['node', 'build.js'], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    server = subprocess.Popen(['node', 'server.js'], cwd=ROOT, env={**os.environ, 'PORT': str(PORT)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch(executable_path=CHROME, args=['--no-sandbox'])

            # 1. Guest browsing
            pg = await new_page(b)
            await load(pg)
            t = await titles(pg)
            check('Home lists all 5 topics', len(t) == 5, str(t))
            check('Guest sees Sign in button', await pg.get_by_role('button', name='Sign in').count() == 1)
            check('Live counter shows voices and channels', 'voices' in (await pg.inner_text('.livepill')) and '4 channels' in (await pg.inner_text('.livepill')))
            orders = {}
            for s in ['Hot', 'New', 'Most votes', 'Closest split']:
                await pg.get_by_role('tab', name=s).click(); await pg.wait_for_timeout(150); orders[s] = await titles(pg)
            check('"New" puts newest topic first', orders['New'][0].startswith('Should work'), str(orders['New']))
            check('"Most votes" puts Gloc-9 (2 votes) first', orders['Most votes'][0].startswith('What do you think'), str(orders['Most votes']))
            check('"Closest split" puts the 50/50 topic first', orders['Closest split'][0].startswith('What do you think'), str(orders))
            await pg.get_by_role('tab', name='t/food').click(); await pg.wait_for_timeout(150)
            check('Channel filter t/food shows 2 topics', len(await titles(pg)) == 2)
            await pg.get_by_role('tab', name='All channels').click()
            await pg.fill('input[type=search]', 'iphone'); await pg.wait_for_timeout(150)
            check('Search "iphone" finds 1 topic', (await titles(pg)) == ['iPhone or Android?'])
            await pg.fill('input[type=search]', '')
            check('Home cards show votes only (no comment count)', 'comment' not in (await pg.inner_text('.feed')).lower())
            check('Unvoted cards show "Vote above to unlock chat"', await pg.locator('.locked').count() == 5)
            check('No JS errors (guest)', not pg.errors, '; '.join(pg.errors))

            # 2. Routing / sharing
            await load(pg, '/pineapple-on-pizza')
            check('Direct topic URL opens topic page', 'Pineapple on pizza?' in await pg.inner_text('h1'))
            check('Tab title is the topic', 'Pineapple' in await pg.title())
            check('Guest asked to sign in to vote', await pg.get_by_text('Sign in with your email to vote').count() == 1)
            await load(pg, '/this-topic-does-not-exist')
            check('Unknown URL shows "Topic not found"', await pg.get_by_text('Topic not found').count() == 1)
            await load(pg, '/')
            await pg.locator('.ctitle', has_text='iPhone').click(); await pg.wait_for_timeout(300)
            check('Clicking card changes URL to slug', pg.url.endswith('/iphone-or-android'), pg.url)
            await pg.go_back(); await pg.wait_for_timeout(300)
            check('Back button returns home', pg.url.rstrip('/') == BASE)

            # 3. Sign-in screen
            await pg.get_by_role('button', name='Sign in').click(); await pg.wait_for_timeout(200)
            await pg.fill('#em', 'not-an-email'); await pg.get_by_role('button', name='Send me a sign-in link').click()
            check('Sign-in rejects invalid email (no link sent)', not await pg.evaluate('window.__otp'))
            await pg.fill('#em', 'friend@example.com'); await pg.get_by_role('button', name='Send me a sign-in link').click(); await pg.wait_for_timeout(200)
            check('Sign-in sends magic link', 'Check your inbox' in await pg.inner_text('[role=status]'))

            # 4. Voting (signed in)
            pg = await new_page(b, user=True)
            await load(pg, '/iphone-or-android')
            check('Signed-in header shows nickname', 'QuietHalohalo722' in await pg.inner_text('header'))
            await pg.get_by_role('button', name='Post vote').click(); await pg.wait_for_timeout(150)
            check('Post without side -> "Pick a side first"', 'Pick a side first' in await pg.inner_text('[role=alert]'))
            await pg.get_by_role('radio', name=re.compile('Android')).click()
            await pg.fill('#why', 'too short'); await pg.get_by_role('button', name='Post vote').click(); await pg.wait_for_timeout(150)
            check('Short comment rejected', 'at least 10' in await pg.inner_text('[role=alert]'))
            await pg.fill('#why', 'Android is cheaper, gago'); await pg.get_by_role('button', name='Post vote').click(); await pg.wait_for_timeout(150)
            check('Profanity in comment rejected', 'offensive' in await pg.inner_text('[role=alert]'))
            await pg.fill('#why', 'Visit www.example.com for proof'); await pg.get_by_role('button', name='Post vote').click(); await pg.wait_for_timeout(150)
            check('Links in comment rejected', 'No links' in await pg.inner_text('[role=alert]'))
            await pg.fill('#why', 'I will kill you if you disagree'); await pg.get_by_role('button', name='Post vote').click(); await pg.wait_for_timeout(150)
            check('Threat in comment rejected', 'Threats' in await pg.inner_text('[role=alert]'))
            await pg.fill('#why', 'Android gives more value for the price, plain and simple.'); await pg.get_by_role('button', name='Post vote').click(); await pg.wait_for_timeout(500)
            body = await pg.inner_text('#view')
            check('Valid vote is posted', 'YOUR PICK' in body.upper() and 'Votes are final' in body)
            check('Own comment appears with "(you)"', 'QuietHalohalo722 (you)' in body)
            check('Vote box disappears after voting (one vote only)', await pg.locator('#why').count() == 0)
            check('"Talk to iPhone side" appears', await pg.get_by_text('Talk to iPhone side').count() == 1)
            await pg.click('#home'); await pg.wait_for_timeout(300)
            card = pg.locator('.card', has_text='iPhone or Android?')
            check('Home card shows "You picked Android"', await card.get_by_text('You picked Android').count() == 1)

            # 5. Likes
            await load(pg, '/what-do-you-think-of-gloc-9s-recent-endorsement')
            before = await pg.eval_on_selector_all('.take b', 'els=>els.map(e=>e.textContent)')
            likebtn = pg.locator('button.fair').first
            t0 = await likebtn.inner_text()
            await likebtn.click(); await pg.wait_for_timeout(300)
            after = await pg.eval_on_selector_all('.take b', 'els=>els.map(e=>e.textContent)')
            check('Like increments count', (await pg.locator('button.fair').first.inner_text()) != t0, t0)
            check('Liking does not reorder takes', before == after, f'{before} -> {after}')
            await pg.locator('button.fair').first.click(); await pg.wait_for_timeout(300)
            check('Unlike restores count', (await pg.locator('button.fair').first.inner_text()) == t0)

            # 6. Chat (normal hours)
            pg = await new_page(b, user=True, hour=15)
            await load(pg, '/what-do-you-think-of-gloc-9s-recent-endorsement')
            await pg.locator('.tchip', has_text='Bad').click()
            # vote first
            await load(pg, '/should-work-from-home-be-the-default')
            await pg.get_by_role('radio', name=re.compile('Yes')).click()
            await pg.fill('#why', 'Remote work saves hours of commuting every day.'); await pg.get_by_role('button', name='Post vote').click(); await pg.wait_for_timeout(500)
            await pg.locator('button.enter').click(); await pg.wait_for_timeout(300)
            check('Matching screen shows', 'Finding someone who picked No' in await pg.inner_text('#view'))
            await pg.wait_for_timeout(3200)
            chat = await pg.inner_text('#view')
            check('Matched into chat with partner nickname', 'CalmTarsier17' in chat, chat[:200])
            check('Partner connected message', 'Connected with CalmTarsier17' in chat)
            check('Purge banner hidden at 3 PM', await pg.locator('#purgeBar').is_hidden())
            await pg.fill('#msg', 'Commuting in Manila is brutal though'); await pg.keyboard.press('Enter'); await pg.wait_for_timeout(500)
            msgs = await pg.eval_on_selector_all('.bubble', 'els=>els.map(e=>e.className+"|"+e.textContent)')
            check('My message shows', any('me|Commuting' in m for m in msgs), str(msgs))
            check('Partner reply received', any('them|' in m for m in msgs), str(msgs))
            await pg.fill('#msg', 'pota ka'); await pg.keyboard.press('Enter'); await pg.wait_for_timeout(200)
            check('Profanity blocked in chat outside Purge Hour', 'offensive' in await pg.inner_text('.chat [role=alert]'))
            await pg.fill('#msg', 'call me 09171234567'); await pg.keyboard.press('Enter'); await pg.wait_for_timeout(200)
            check('Phone numbers blocked in chat', 'No links' in await pg.inner_text('.chat [role=alert]'))
            check('Chat uses private match room', any(c.startswith('match:') for c in await pg.evaluate('window.__channels')))
            await pg.get_by_role('button', name='End', exact=True).click(); await pg.wait_for_timeout(300)
            check('Ending chat shows rating screen', 'Was CalmTarsier17 respectful?' in await pg.inner_text('#view'))
            check('End chat notifies partner (bye)', any(m.get('event') == 'bye' for m in await pg.evaluate('window.__sent')))
            check('No JS errors (chat)', not pg.errors, '; '.join(pg.errors))

            # 7. Chat during Purge Hour (server time 12 AM Manila)
            pg = await new_page(b, user=True, hour=0)
            await load(pg, '/what-do-you-think-of-gloc-9s-recent-endorsement')
            await pg.get_by_role('radio', name=re.compile('Good')).click()
            await pg.fill('#why', 'His music speaks for itself, endorsements are fine.'); await pg.get_by_role('button', name='Post vote').click(); await pg.wait_for_timeout(500)
            check('Purge banner visible at 12 AM (server time)', await pg.locator('#purgeBar').is_visible())
            await pg.locator('button.enter').click(); await pg.wait_for_timeout(3500)
            check('Chat turns black in Purge Hour', await pg.evaluate("document.body.classList.contains('purge-chat')"))
            await pg.fill('#msg', 'pota ka talaga'); await pg.keyboard.press('Enter'); await pg.wait_for_timeout(300)
            check('Profanity allowed in Purge Hour chat', any('pota ka talaga' in m for m in await pg.eval_on_selector_all('.bubble.me', 'els=>els.map(e=>e.textContent)')))
            await pg.fill('#msg', 'papatayin kita'); await pg.keyboard.press('Enter'); await pg.wait_for_timeout(200)
            check('Threats still blocked in Purge Hour', 'Threats' in await pg.inner_text('.chat [role=alert]'))
            pg2 = await new_page(b, user=True, hour=0)
            await load(pg2, '/pineapple-on-pizza')
            await pg2.get_by_role('radio', name=re.compile('Yes')).click()
            await pg2.fill('#why', 'pota masarap kaya'); await pg2.get_by_role('button', name='Post vote').click(); await pg2.wait_for_timeout(200)
            check('Comments stay filtered during Purge Hour', 'offensive' in await pg2.inner_text('[role=alert]'))

            # 8. Partner never connects
            pg = await new_page(b, user=True, extra='window.__partnerNoShow=true;')
            await load(pg, '/jollibee-or-mcdo-fried-chicken')
            await pg.get_by_role('radio', name=re.compile('Jollibee')).click()
            await pg.fill('#why', 'Chickenjoy gravy wins every single time.'); await pg.get_by_role('button', name='Post vote').click(); await pg.wait_for_timeout(500)
            await pg.locator('button.enter').click(); await pg.wait_for_timeout(3500)
            await pg.fill('#msg', 'hello?'); await pg.keyboard.press('Enter'); await pg.wait_for_timeout(200)
            check('Cannot send before partner connects', 'Waiting for them' in await pg.inner_text('.chat [role=alert]'))

            # 9. Admin
            pg = await new_page(b, user=True, admin=True)
            await load(pg)
            check('Admin sees New topic button', await pg.get_by_role('button', name='New topic').count() == 1)
            check('Admin sees Purge Hour test switch', await pg.get_by_text('Simulate Purge Hour').count() == 1)
            await pg.get_by_role('button', name='Admin', exact=True).click(); await pg.wait_for_timeout(300)
            await pg.get_by_role('tab', name='Users').click(); await pg.wait_for_timeout(400)
            users = await pg.inner_text('#view')
            check('Admin Users lists emails + nicknames', 'bituin@example.com' in users and 'BituinBeats404' in users)
            await pg.get_by_role('tab', name='Topics').click(); await pg.wait_for_timeout(200)
            await pg.locator('div', has_text=re.compile('^iPhone or Android\\?')).first.wait_for()
            row = pg.locator('div[style*="border-top"]', has_text='iPhone or Android?')
            await row.get_by_role('button', name='Hide').click(); await pg.wait_for_timeout(400)
            await pg.click('#home'); await pg.wait_for_timeout(300)
            check('Hidden topic disappears from home', 'iPhone or Android?' not in await titles(pg))
            await pg.get_by_role('button', name='New topic').click(); await pg.wait_for_timeout(200)
            await pg.fill('#nt', 'Is Coke better than Pepsi?'); await pg.fill('#nc', 'food'); await pg.fill('#na', 'Coke'); await pg.fill('#nb', 'Pepsi')
            await pg.get_by_role('button', name='Publish').click(); await pg.wait_for_timeout(500)
            await pg.click('#home'); await pg.wait_for_timeout(300)
            check('Admin can publish a new topic', 'Is Coke better than Pepsi?' in await titles(pg))
            pg = await new_page(b, user=True)
            await load(pg)
            check('Non-admin has no Admin/New topic', await pg.get_by_role('button', name='Admin', exact=True).count() == 0 and await pg.get_by_role('button', name='New topic').count() == 0)

            # 10. Theme + mobile layout
            pg = await new_page(b)
            await load(pg)
            await pg.click('#theme'); await load(pg)
            check('Dark mode persists after reload', await pg.evaluate("document.body.classList.contains('theme-dark')"))
            for path in ['/', '/what-do-you-think-of-gloc-9s-recent-endorsement']:
                for w in [360, 390, 768]:
                    m = await new_page(b, user=True, w=w, h=800)
                    await load(m, path)
                    over = await m.evaluate('document.documentElement.scrollWidth - window.innerWidth')
                    check(f'No sideways overflow at {w}px on {path}', over <= 1, f'{over}px')
            m = await new_page(b, user=True, w=390, h=800)
            await load(m)
            small = await m.evaluate("[...document.querySelectorAll('button,a,input')].filter(e=>e.offsetParent&&e.getBoundingClientRect().height<28).map(e=>e.textContent.trim()||e.getAttribute('aria-label')).slice(0,8)")
            check('Tap targets at least 28px tall on phone', not small, str(small))
            unnamed = await m.evaluate("[...document.querySelectorAll('button')].filter(b=>!(b.textContent.trim()||b.getAttribute('aria-label'))).length")
            check('Every button has an accessible name', unnamed == 0, str(unnamed))

            # 11. Legal pages
            pg = await new_page(b)
            await load(pg, '/terms')
            body = await pg.inner_text('#view')
            check('Terms page loads', 'Terms of Use' in body and 'You must be 18 or older' in body and 'Purge Hour' in body)
            await load(pg, '/privacy')
            body = await pg.inner_text('#view')
            check('Privacy page loads (Data Privacy Act)', 'Privacy Policy' in body and 'RA 10173' in body and 'National Privacy Commission' in body)
            await load(pg)
            check('Footer links to Terms and Privacy', await pg.locator('.footlinks').get_by_role('button', name='Terms').count() == 1 and await pg.locator('.footlinks').get_by_role('button', name='Privacy').count() == 1)
            await pg.locator('.footlinks').get_by_role('button', name='Privacy').click(); await pg.wait_for_timeout(200)
            check('Footer link opens /privacy', pg.url.endswith('/privacy'))
            await pg.get_by_role('button', name='Sign in').click(); await pg.wait_for_timeout(200)
            check('Sign-in shows 18+ and agreement', 'For adults 18+' in await pg.inner_text('#view'))

            # 12. Consent gate (new user)
            pg = await new_page(b, user=True, extra='window.__mockNoConsent=true;')
            await load(pg, '/iphone-or-android')
            check('New user must accept terms first', 'Before you join' in await pg.inner_text('#view'))
            await pg.get_by_role('button', name='Continue').click(); await pg.wait_for_timeout(150)
            check('Consent requires both boxes', 'tick both' in await pg.inner_text('#view [role=alert]'))
            await pg.check('#c18'); await pg.check('#cterms'); await pg.get_by_role('button', name='Continue').click(); await pg.wait_for_timeout(600)
            check('After consent, returns to the topic they opened', 'iPhone or Android?' in await pg.inner_text('h1'))
            await pg.get_by_role('radio', name=re.compile('iPhone')).click()
            await pg.fill('#why', 'The ecosystem just works together nicely.'); await pg.get_by_role('button', name='Post vote').click(); await pg.wait_for_timeout(500)
            check('Can vote after consent', 'YOUR PICK' in (await pg.inner_text('#view')).upper())

            # 13. Banned user
            pg = await new_page(b, user=True, extra='window.__mockBanned=true;')
            await load(pg, '/iphone-or-android')
            check('Banned user sees suspension notice', 'suspended' in (await pg.inner_text('#view')).lower() and 'Harassment' in await pg.inner_text('#view'))
            await pg.get_by_role('radio', name=re.compile('iPhone')).click()
            await pg.fill('#why', 'Trying to vote while banned here.'); await pg.get_by_role('button', name='Post vote').click(); await pg.wait_for_timeout(400)
            check('Banned user cannot vote', 'YOUR PICK' not in (await pg.inner_text('#view')).upper())
            await load(pg, '/what-do-you-think-of-gloc-9s-recent-endorsement')
            check('Banned user cannot like', await pg.locator('button.fair.on').count() == 0)

            # 14. Block a commenter
            pg = await new_page(b, user=True)
            await load(pg, '/what-do-you-think-of-gloc-9s-recent-endorsement')
            take = pg.locator('.take', has_text='BituinBeats404')
            await take.get_by_role('button', name='Block').click(); await pg.wait_for_timeout(500)
            check('Blocked commenter disappears', await pg.locator('.take', has_text='BituinBeats404').count() == 0)
            check('Block confirmation shown', 'Blocked BituinBeats404' in await pg.inner_text('#view'))
            await pg.locator('button.whopill').click(); await pg.wait_for_timeout(400)
            check('Account page lists blocked person', 'BituinBeats404' in await pg.inner_text('#view'))
            await pg.get_by_role('button', name='Unblock').click(); await pg.wait_for_timeout(500)
            check('Unblock removes them from the list', "haven't blocked anyone" in await pg.inner_text('#view'))

            async def into_chat(pg, topic='/should-work-from-home-be-the-default', side='Yes'):
                await load(pg, topic)
                await pg.get_by_role('radio', name=re.compile(side)).click()
                await pg.fill('#why', 'This is my honest reason for picking this side.'); await pg.get_by_role('button', name='Post vote').click(); await pg.wait_for_timeout(500)
                await pg.locator('button.enter').click(); await pg.wait_for_timeout(3500)

            # 15. Server-side chat: messages go through send_chat, own echo not duplicated
            pg = await new_page(b, user=True, hour=15)
            await into_chat(pg)
            await pg.fill('#msg', 'Traffic is the real reason'); await pg.keyboard.press('Enter'); await pg.wait_for_timeout(500)
            mine = await pg.eval_on_selector_all('.bubble.me', 'els=>els.map(e=>e.textContent)')
            check('Messages are sent through the server (send_chat)', 'send_chat' in await pg.evaluate('window.__db.rpcCalls'))
            check('Client never broadcasts chat messages directly', not await pg.evaluate('window.__clientMsgBroadcast'))
            check('Own message shown once (server echo ignored)', mine.count('Traffic is the real reason') == 1, str(mine))
            await pg.evaluate("window.__deliver({text:'gago ka', side: window.__mySide==='a'?'b':'a'})"); await pg.wait_for_timeout(200)
            check('Incoming bad words still hidden as a safety net', any('blocked' in m for m in await pg.eval_on_selector_all('.bubble.sys', 'els=>els.map(e=>e.textContent)')))

            # 16. Report from chat
            await pg.get_by_role('button', name='Report', exact=True).click(); await pg.wait_for_timeout(200)
            await pg.get_by_role('button', name='Report and block').click(); await pg.wait_for_timeout(150)
            check('Report needs a reason', 'Pick a reason' in await pg.inner_text('.reportbox'))
            await pg.get_by_role('radio', name='Hate or slurs').click()
            await pg.fill('.reportbox textarea', 'Used slurs twice'); await pg.get_by_role('button', name='Report and block').click(); await pg.wait_for_timeout(500)
            check('Chat report saved with reason', await pg.evaluate("window.__db.chatReports.length===1 && window.__db.chatReports[0].p_reason==='hate'"))
            check('Reported person is blocked', await pg.evaluate("window.__db.blocks.some(b=>b.blocked==='u3')"))
            check('Report confirmation shown', 'saved your report' in await pg.inner_text('#view'))

            # 17. Block from chat
            pg = await new_page(b, user=True, hour=15)
            await into_chat(pg)
            await pg.get_by_role('button', name='Block', exact=True).click(); await pg.wait_for_timeout(500)
            check('Block from chat ends it and confirms', 'You blocked CalmTarsier17' in await pg.inner_text('#view'))
            check('Blocked partner saved', await pg.evaluate("window.__db.blocks.some(b=>b.blocked==='u3')"))

            # 18. Rating after chat
            pg = await new_page(b, user=True, hour=15)
            await into_chat(pg)
            await pg.get_by_role('button', name='End', exact=True).click(); await pg.wait_for_timeout(300)
            await pg.get_by_role('button', name='Yes').click(); await pg.wait_for_timeout(300)
            check('"Respectful" rating saved', await pg.evaluate("window.__db.ratings.length===1 && window.__db.ratings[0].p_respectful===true"))
            check('Thanks shown after rating', 'Thanks for the feedback' in await pg.inner_text('#view'))
            pg = await new_page(b, user=True, hour=15)
            await into_chat(pg)
            await pg.get_by_role('button', name='End', exact=True).click(); await pg.wait_for_timeout(300)
            await pg.get_by_role('button', name='No', exact=True).click(); await pg.wait_for_timeout(300)
            check('"Not respectful" offers a report', await pg.locator('.reportbox').count() == 1)

            # 19. Delete account
            pg = await new_page(b, user=True)
            await load(pg, '/account')
            body = await pg.inner_text('#view')
            check('Account page shows nickname and email', 'QuietHalohalo722' in body and 'tester@example.com' in body)
            await pg.get_by_role('button', name='Delete my account').click(); await pg.wait_for_timeout(200)
            check('Delete requires typing DELETE', 'Type DELETE' in await pg.inner_text('#view [role=alert]'))
            await pg.fill('#delconf', 'DELETE'); await pg.get_by_role('button', name='Delete my account').click(); await pg.wait_for_timeout(600)
            check('Account deleted and signed out', 'have been deleted' in await pg.inner_text('#view') and await pg.get_by_role('button', name='Sign in').count() == 1)

            # 20. Admin bans
            pg = await new_page(b, user=True, admin=True)
            await load(pg, '/admin')
            await pg.get_by_role('tab', name='Users').click(); await pg.wait_for_timeout(400)
            await pg.fill('#banreason', 'Spamming links')
            row = pg.locator('div[style*="border-top"]', has_text='BituinBeats404')
            await row.get_by_role('button', name='7 days').click(); await pg.wait_for_timeout(600)
            check('Admin can ban for 7 days with reason', await pg.evaluate("window.__db.profiles[1].banned_until && window.__db.profiles[1].ban_reason==='Spamming links'"))
            check('Banned tag shown', 'Banned until' in await pg.locator('div[style*="border-top"]', has_text='BituinBeats404').inner_text())
            await pg.locator('div[style*="border-top"]', has_text='BituinBeats404').get_by_role('button', name='Unban').click(); await pg.wait_for_timeout(600)
            check('Admin can unban', await pg.evaluate("!window.__db.profiles[1].banned_until"))
            check('Admin cannot ban themselves (no buttons on own row)', await pg.locator('div[style*="border-top"]', has_text='QuietHalohalo722').get_by_role('button', name='7 days').count() == 0)
            await pg.get_by_role('tab', name='Reports').click(); await pg.wait_for_timeout(400)
            check('Admin sees Chat reports section', 'Chat reports' in await pg.inner_text('#view'))
            for path in ['/terms', '/account']:
                m = await new_page(b, user=True, w=360, h=800)
                await load(m, path)
                over = await m.evaluate('document.documentElement.scrollWidth - window.innerWidth')
                check(f'No sideways overflow at 360px on {path}', over <= 1, f'{over}px')
            await b.close()
    finally:
        server.terminate()
    passed = sum(1 for r in results if r[1])
    print(f'\n{passed}/{len(results)} checks passed')
    return 0 if passed == len(results) else 1

if __name__ == '__main__':
    sys.exit(asyncio.run(run()))
