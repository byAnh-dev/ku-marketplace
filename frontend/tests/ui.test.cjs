const assert = require('node:assert/strict');
const path = require('node:path');
const { test } = require('node:test');
const React = require('react');
const { act } = React;
const { createRoot } = require('test-renderer');
const { createAppLoader } = require('./load-app.cjs');

global.IS_REACT_ACT_ENVIRONMENT = true;
const sessionKey = 'ku_marketplace_session';
const token = 'B'.repeat(72);
const user = {
  id: '84b9c5ab-37f2-490e-ad8f-70c9d21186fb',
  displayName: 'Test Student', email: 'student@ku.edu', verified: true,
};
const listing = {
  id: 'desk-1', title: 'Study desk', description: 'A desk for studying.',
  priceCents: 2500, condition: 'Good', category: 'Furniture',
  sellerDisplayName: 'Another Student', pickupArea: 'Campus', photoURLs: [],
};

// React, application components, effects, and the API modules execute unchanged.
// These hosts expose props and events but do not simulate native layout or touch.
function harness(storedToken, clock) {
  const storage = new Map(storedToken ? [[sessionKey, storedToken]] : []);
  const requests = [];
  const replies = new Map();
  const pickerResults = [];
  const appStateListeners = new Set();
  const native = {
    AppState: { currentState: 'active', addEventListener: (_, listener) => {
      appStateListeners.add(listener);
      return { remove: () => appStateListeners.delete(listener) };
    } },
    Platform: { OS: 'ios' }, StyleSheet: { create: value => value },
    ...Object.fromEntries(['ActivityIndicator', 'Button', 'Image', 'Pressable',
      'SafeAreaView', 'KeyboardAvoidingView', 'ScrollView', 'Text', 'TextInput', 'View'].map(name => [name, name])),
    FlatList: ({ data, renderItem, keyExtractor, ListEmptyComponent, onViewableItemsChanged }) => React.createElement('FlatList', { onViewableItemsChanged },
      data.length ? data.map((item, index) => React.createElement(React.Fragment, { key: keyExtractor(item, index) }, renderItem({ item, index }))) : ListEmptyComponent),
  };
  const secureStore = {
    getItemAsync: async key => storage.get(key) ?? null,
    setItemAsync: async (key, value) => { storage.set(key, value); },
    deleteItemAsync: async key => { storage.delete(key); },
  };
  const response = (status, body) => new Response(status === 204 ? null : JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json' },
  });
  const load = createAppLoader({
    modules: {
      react: React, 'react/jsx-runtime': require('react/jsx-runtime'), expo: { uuid: { v4: require('node:crypto').randomUUID } },
      'react-native': native, 'expo-status-bar': { StatusBar: 'StatusBar' },
      'expo-secure-store': secureStore,
      'expo-image': { Image: 'Image' },
      '@expo-google-fonts/plus-jakarta-sans': { useFonts: () => [true] },
      'expo-file-system': {
        File: class {
          constructor(uri) {
            this.uri = uri;
            this.name = new URL(uri).pathname.split('/').at(-1);
            this.type = this.name.endsWith('.png') ? 'image/png' : 'image/jpeg';
          }
          async bytes() { return new TextEncoder().encode(this.uri); }
        },
      },
      'expo-image-picker': {
        launchImageLibraryAsync: async () => {
          assert.ok(pickerResults.length, 'Queue a device picker result first');
          const next = pickerResults.shift();
          if (next instanceof Error) throw next;
          return await next;
        },
      },
    },
    globals: {
      setInterval, clearInterval,
      ...(clock ? { Date: class extends Date { static now() { return clock.now; } },
        setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout } : {}),
      Blob, TextEncoder,
      FormData: class {
        parts = [];
        append(name, value) { this.parts.push({ name, value }); }
        *entries() { for (const { name, value } of this.parts) yield [name, value]; }
      },
      fetch: async (url, options = {}) => {
        const route = new URL(url).pathname;
        const request = { url: String(url), ...options, headers: new Headers(options.headers) };
        if (options.body?.entries) {
          const { convertFormDataAsync } = load(path.join(path.dirname(require.resolve('expo/package.json')),
            'src/winter/fetch/convertFormData.ts'));
          const { body, boundary } = await convertFormDataAsync(options.body);
          request.multipart = await new Response(body, {
            headers: { 'Content-Type': 'multipart/form-data; boundary=' + boundary },
          }).formData();
        }
        requests.push(request);
        const queue = replies.get(route);
        if (!queue?.length && route === '/api/v1/me/unread') return response(200, { total: 0, threads: [] });
        if (!queue?.length && route === '/api/v1/listings' && (!options.method || options.method === 'GET')) return response(200, [listing]);
        if (!queue?.length && route === '/api/v1/listings/desk-1') return response(200, listing);
        assert.ok(queue?.length, `Unexpected request: ${route}`);
        const next = queue.shift();
        if (next instanceof Error) throw next;
        return await next;
      },
    },
  });
  function queue(route, value) {
    const key = route.startsWith('/') ? route : `/api/v1/auth/${route}`;
    if (!replies.has(key)) replies.set(key, []);
    replies.get(key).push(value);
  }
  return {
    App: load(path.resolve(__dirname, '../App.tsx')).default,
    AuthScreen: load(path.resolve(__dirname, '../src/AuthScreen.tsx')).AuthScreen,
    AddPhotos: load(path.resolve(__dirname, '../src/PhotoPicker.tsx')).AddPhotos,
    PhotoPicker: load(path.resolve(__dirname, '../src/PhotoPicker.tsx')).PhotoPicker,
    api: load(path.resolve(__dirname, '../src/api.ts')),
    storage, requests,
    changeAppState(state) {
      native.AppState.currentState = state;
      for (const listener of appStateListeners) listener(state);
    },
    pick: result => pickerResults.push(result),
    reply: (route, status, body) => queue(route, response(status, body)),
    offline: route => queue(route, new Error('Network unavailable')),
    defer(route) {
      let resolve;
      const pending = new Promise(done => { resolve = done; });
      queue(route, pending);
      return (status, body) => resolve(response(status, body));
    },
  };
}

function text(node) {
  if (typeof node === 'string' || typeof node === 'number') return String(node);
  return (node.children ?? []).map(text).join('');
}
function hasText(ui, expected) {
  return ui.container.queryAll(node => node.type === 'Text').some(node => text(node).includes(expected));
}
function control(ui, label) {
  const matches = ui.container.queryAll(node =>
    (node.type === 'Button' && node.props.title === label) ||
    (node.type === 'Pressable' && (text(node) === label || node.props.accessibilityLabel === label)));
  assert.equal(matches.length, 1, `Expected one control named ${label}`);
  return matches[0];
}
async function press(ui, label) {
  const target = control(ui, label);
  assert.notEqual(target.props.disabled, true, `${label} should be enabled`);
  await act(async () => { target.props.onPress(); });
}
async function fill(ui, label, value) {
  const input = ui.container.queryAll(node => node.type === 'TextInput').find(node => node.props.accessibilityLabel === label);
  assert.ok(input, `Missing input: ${label}`);
  assert.notEqual(input.props.editable, false, `${label} should be editable`);
  await act(async () => { input.props.onChangeText(value); });
}
function inputValue(ui, label) {
  return ui.container.queryAll(node => node.type === 'TextInput').find(node => node.props.accessibilityLabel === label)?.props.value;
}
async function mount(t, Component, props = {}) {
  const ui = createRoot({ textComponentTypes: ['Text'] });
  await act(async () => { ui.render(React.createElement(Component, props)); });
  t.after(async () => { await act(async () => { ui.unmount(); }); });
  return ui;
}

function manualClock() {
  let nextID = 0;
  const timers = new Map();
  const clock = {
    now: Date.now(),
    setTimeout(callback, delay) { const id = ++nextID; timers.set(id, { at: clock.now + delay, callback }); return id; },
    clearTimeout(id) { timers.delete(id); },
    advance(milliseconds) {
      clock.now += milliseconds;
      for (const [id, timer] of [...timers]) {
        if (timer.at <= clock.now) { timers.delete(id); timer.callback(); }
      }
    },
  };
  return clock;
}

test('public browsing stays available and login/logout preserve the marketplace search', async t => {
  const h = harness();
  const ui = await mount(t, h.App);
  assert.ok(hasText(ui, 'Study desk'));
  assert.equal(h.requests.filter(request => request.url.includes('/auth/')).length, 0);
  await fill(ui, 'Search listings', 'desk');
  await press(ui, 'Student login / register');
  await fill(ui, 'KU email', user.email);
  await fill(ui, 'Password', 'long-password');
  h.reply('login', 200, { token, user });
  await press(ui, 'Log in');
  assert.ok(hasText(ui, `Signed in as ${user.displayName}`));
  assert.equal(inputValue(ui, 'Search listings'), 'desk');
  assert.equal(h.storage.get(sessionKey), token);
  h.reply('logout', 204);
  await press(ui, 'Log out');
  assert.ok(control(ui, 'Student login / register'));
  assert.ok(hasText(ui, 'Study desk'));
  assert.equal(inputValue(ui, 'Search listings'), 'desk');
  assert.equal(h.storage.size, 0);
  const logout = h.requests.find(request => request.url.endsWith('/auth/logout'));
  assert.equal(logout.headers.get('Authorization'), `Bearer ${token}`);
});

test('a lost first-send response retains the draft and retries with its original UUID', async t => {
  const h = harness(token);
  h.reply('me', 200, user);
  const ui = await mount(t, h.App);
  const card = ui.container.queryAll(node => node.type === 'Pressable').find(node => text(node).includes(listing.title));
  await act(async () => card.props.onPress());
  h.reply('/api/v1/conversations', 200, []);
  await press(ui, 'Message seller');
  await fill(ui, 'Message', 'Can we meet at Wescoe?');
  const start = '/api/v1/listings/desk-1/conversations';
  h.offline(start);
  await press(ui, 'Send');
  assert.equal(inputValue(ui, 'Message'), 'Can we meet at Wescoe?');
  const first = JSON.parse(h.requests.find(r => r.url.endsWith(start)).body);
  assert.match(first.clientMessageId, /^[a-f0-9-]{36}$/);
  const message = { sequence: 51, ...first, senderId: user.id, recipientId: 'peer', senderDisplayName: user.displayName, createdAt: '2026-11-22T10:00:00Z' };
  h.reply(start, 200, { conversationId: 'thread-1', message });
  h.reply('/api/v1/conversations/thread-1/messages', 200, { items: [message], hasOlder: false, hasNewer: false, canMessage: true, blockedByMe: false, listingStatus: 'active' });
  await press(ui, 'Retry send');
  const sends = h.requests.filter(r => r.url.endsWith(start));
  assert.equal(sends.length, 2);
  assert.equal(sends[1].body, sends[0].body);
  assert.equal(ui.container.queryAll(node => node.type === 'Text' && text(node) === first.body).length, 1);
});

test('opening a blocked thread retains history and marks only visible incoming sequences', async t => {
  const h = harness(token);
  h.reply('me', 200, user);
  h.reply('/api/v1/me/unread', 200, { total: 2, threads: [{ conversationId: 'thread-1', unreadCount: 2 }] });
  const ui = await mount(t, h.App);
  const conversation = { id: 'thread-1', listingId: 'desk-1', listingTitle: 'Study desk', peerDisplayName: 'Peer', canMessage: false, blockedByMe: true, listingStatus: 'active' };
  h.reply('/api/v1/conversations', 200, [conversation]);
  await press(ui, 'Messages (2 unread)');
  const incoming = { senderId: 'peer', recipientId: user.id, senderDisplayName: 'Peer', createdAt: '2026-11-22T10:00:00Z' };
  const items = [{ ...incoming, sequence: 40, body: 'Older' }, { ...incoming, sequence: 41, body: 'Displayed' },
    { ...incoming, sequence: 42, senderId: user.id, recipientId: 'peer', body: 'Outgoing' }];
  const route = '/api/v1/conversations/thread-1/messages';
  h.reply(route, 200, { ...conversation, items, hasOlder: false, hasNewer: false });
  await press(ui, 'Study deskPeer2 unreadRead-only');
  assert.ok(hasText(ui, 'This conversation is read-only.'));
  assert.equal(ui.container.queryAll(n => n.type === 'TextInput').length, 0);
  const read = '/api/v1/conversations/thread-1/read';
  assert.equal(h.requests.filter(r => r.url.endsWith(read)).length, 0);
  h.reply(read, 204);
  h.reply(route, 200, { ...conversation, items: [], hasOlder: false, hasNewer: false });
  const list = ui.container.queryAll(n => n.type === 'FlatList')[0];
  await act(async () => list.props.onViewableItemsChanged({ viewableItems: items.slice(1).map(item => ({ item, isViewable: true })) }));
  assert.deepEqual(JSON.parse(h.requests.find(r => r.url.endsWith(read)).body), { sequences: [41] });
});

test('Message seller reopens the buyer history and never selects a seller-owned conversation', async t => {
  const h = harness(token);
  h.reply('me', 200, user);
  const ui = await mount(t, h.App);
  const openDetail = async () => {
    const card = ui.container.queryAll(node => node.type === 'Pressable').find(node => text(node).includes(listing.title));
    await act(async () => card.props.onPress());
  };
  await openDetail();
  const thread = { id: 'existing', listingId: listing.id, listingTitle: listing.title, peerDisplayName: 'Peer',
    listingStatus: 'active', canMessage: true, blockedByMe: false };
  h.reply('/api/v1/conversations', 200, [{ ...thread, isBuyer: false }]);
  await press(ui, 'Message seller');
  assert.ok(hasText(ui, 'This is your listing.'));
  assert.equal(h.requests.filter(r => r.url.endsWith('/existing/messages')).length, 0);
  h.reply('/api/v1/conversations', 200, [{ ...thread, isBuyer: true }]);
  h.reply('/api/v1/conversations/existing/messages', 200, { ...thread, items: [{ sequence: 12, senderId: 'peer', recipientId: user.id,
    senderDisplayName: 'Peer', body: 'The desk is still available.', createdAt: '2026-11-22T10:00:00Z' }], hasOlder: false, hasNewer: false });
  await press(ui, 'Message seller');
  assert.ok(hasText(ui, 'The desk is still available.'));
  assert.equal(h.requests.filter(r => r.method === 'POST').length, 0);
});

test('a pending read preserves rapidly scrolled messages, retries failures and skips background-only rows', async t => {
  const h = harness(token);
  h.reply('me', 200, user);
  const ui = await mount(t, h.App);
  const thread = { id: 'existing', listingId: listing.id, listingTitle: 'Study desk', peerDisplayName: 'Peer',
    listingStatus: 'active', canMessage: true, blockedByMe: false, isBuyer: true };
  const messages = Array.from({ length: 104 }, (_, i) => ({ sequence: i + 1, senderId: 'peer', recipientId: user.id,
    senderDisplayName: 'Peer', body: String(i + 1), createdAt: '2026-11-22T10:00:00Z' }));
  const route = '/api/v1/conversations/existing/messages';
  const page = { ...thread, hasOlder: false, hasNewer: false };
  const read = '/api/v1/conversations/existing/read';
  const batches = () => h.requests.filter(r => r.url.endsWith(read)).map(r => JSON.parse(r.body).sequences);
  h.reply('/api/v1/conversations', 200, [thread]);
  await press(ui, 'Messages');
  h.reply(route, 200, { ...page, items: messages });
  await press(ui, 'Study deskPeer');
  const view = items => ui.container.queryAll(n => n.type === 'FlatList')[0].props
    .onViewableItemsChanged({ viewableItems: items.map(item => ({ item, isViewable: true })) });
  const finishFirst = h.defer(read);
  await act(async () => view(messages.slice(0, 1)));
  await act(async () => { view(messages.slice(1, 102)); view([]); });
  assert.deepEqual(batches(), [[1]]);
  h.offline(read);
  h.reply(route, 200, { ...page, items: [] });
  await act(async () => finishFirst(204));
  const nextHundred = messages.slice(1, 101).map(row => row.sequence);
  assert.deepEqual(batches(), [[1], nextHundred]);
  await act(async () => h.changeAppState('background'));
  await act(async () => { view(messages.slice(102, 103)); view(messages.slice(103)); });
  assert.equal(batches().length, 2);
  h.reply(read, 204); h.reply(read, 204);
  for (let i = 0; i < 3; i++) h.reply(route, 200, { ...page, items: [] });
  await act(async () => h.changeAppState('active'));
  assert.deepEqual(batches(), [[1], nextHundred, nextHundred, [102, 104]]);
});

test('displayed receipts drain after leaving a thread and a stale receipt cannot sign out the next account', async t => {
  const h = harness(token);
  h.reply('me', 200, user);
  const ui = await mount(t, h.App);
  const thread = { id: 'thread-1', listingId: listing.id, listingTitle: 'Study desk', peerDisplayName: 'Peer',
    listingStatus: 'active', canMessage: true, blockedByMe: false, isBuyer: true };
  const items = [11, 12].map(sequence => ({ sequence, senderId: 'peer', recipientId: user.id, senderDisplayName: 'Peer',
    body: String(sequence), createdAt: '2026-11-22T10:00:00Z' }));
  h.reply('/api/v1/conversations', 200, [thread]);
  await press(ui, 'Messages');
  h.reply('/api/v1/conversations/thread-1/messages', 200, { ...thread, items, hasNewer: false, hasOlder: false });
  await press(ui, 'Study deskPeer');
  const read = '/api/v1/conversations/thread-1/read';
  const first = h.defer(read), second = h.defer(read);
  const view = ui.container.queryAll(n => n.type === 'FlatList')[0].props.onViewableItemsChanged;
  await act(async () => view({ viewableItems: [{ item: items[0], isViewable: true }] }));
  await act(async () => view({ viewableItems: [{ item: items[1], isViewable: true }] }));
  h.reply('/api/v1/conversations', 200, [thread]);
  await press(ui, 'Back to messages');
  h.reply('/api/v1/conversations', 200, [thread]);
  await act(async () => first(204));
  const reads = h.requests.filter(r => r.url.endsWith(read));
  assert.deepEqual(reads.map(r => JSON.parse(r.body).sequences), [[11], [12]]);
  assert.ok(reads.every(r => r.headers.get('Authorization') === 'Bearer ' + token));
  await press(ui, 'Back to marketplace');
  h.reply('logout', 204);
  await press(ui, 'Log out');
  await press(ui, 'Student login / register');
  await fill(ui, 'KU email', 'second@ku.edu');
  await fill(ui, 'Password', 'long-password');
  h.reply('login', 200, { token: 'C'.repeat(72), user: { ...user, id: 'different-id', email: 'second@ku.edu', displayName: 'Second' } });
  await press(ui, 'Log in');
  await act(async () => second(401, { reason: 'Session expired' }));
  assert.ok(hasText(ui, 'Signed in as Second'));
  assert.equal(h.requests.filter(r => r.url.endsWith(read)).length, 2);
});

test('registration validates KU email, matching passwords, and UTF-8 bytes before showing verification instructions', async t => {
  const h = harness();
  let loggedIn = false;
  const ui = await mount(t, h.AuthScreen, { onLogin: () => { loggedIn = true; }, onBack() {} });
  await press(ui, 'New here? Create an account');
  await fill(ui, 'Display name', user.displayName);
  await fill(ui, 'KU email', 'student@example.com');
  await fill(ui, 'Password', 'long-password');
  await fill(ui, 'Confirm password', 'long-password');
  await press(ui, 'Register');
  assert.ok(hasText(ui, 'Use your @ku.edu email address.'));
  await fill(ui, 'KU email', user.email);
  await fill(ui, 'Confirm password', 'different-password');
  await press(ui, 'Register');
  assert.ok(hasText(ui, 'Passwords do not match.'));
  const tooLong = 'é'.repeat(37);
  assert.equal(Buffer.byteLength(tooLong, 'utf8'), 74);
  await fill(ui, 'Password', tooLong);
  await fill(ui, 'Confirm password', tooLong);
  await press(ui, 'Register');
  assert.ok(hasText(ui, 'Use a password between 12 and 72 bytes.'));
  assert.equal(h.requests.length, 0);
  const accepted = 'é'.repeat(6);
  assert.equal(Buffer.byteLength(accepted, 'utf8'), 12);
  await fill(ui, 'Password', accepted);
  await fill(ui, 'Confirm password', accepted);
  h.reply('register', 200, { message: 'Check your KU email for a verification link before logging in.' });
  await press(ui, 'Register');
  assert.ok(hasText(ui, 'KU student login'));
  assert.ok(hasText(ui, 'Check your KU email for a verification link before logging in.'));
  assert.equal(inputValue(ui, 'Password'), '');
  assert.equal(inputValue(ui, 'Confirm password'), undefined);
  assert.equal(inputValue(ui, 'KU email'), user.email);
  assert.equal(loggedIn, false);
  assert.equal(h.storage.size, 0);
  assert.equal(control(ui, 'Resend verification email').props.disabled, true);
});

test('an unverified login stays on the form and displays the backend explanation', async t => {
  const h = harness();
  const ui = await mount(t, h.App);
  await press(ui, 'Student login / register');
  await fill(ui, 'KU email', user.email);
  await fill(ui, 'Password', 'long-password');
  h.reply('login', 403, { reason: 'Verify your KU email before logging in.' });
  await press(ui, 'Log in');
  assert.ok(hasText(ui, 'Verify your KU email before logging in.'));
  assert.ok(control(ui, 'Log in'));
  assert.equal(h.storage.size, 0);
});

test('a newly mounted app restores the persisted session through the profile route', async t => {
  const h = harness();
  const first = await mount(t, h.App);
  await press(first, 'Student login / register');
  await fill(first, 'KU email', user.email);
  await fill(first, 'Password', 'long-password');
  h.reply('login', 200, { token, user });
  await press(first, 'Log in');
  await act(async () => { first.unmount(); });
  h.reply('me', 200, user);
  const restored = await mount(t, h.App);
  assert.ok(hasText(restored, `Signed in as ${user.displayName}`));
  const profile = h.requests.find(request => request.url.endsWith('/auth/me'));
  assert.equal(profile.headers.get('Authorization'), `Bearer ${token}`);
});

test('offline restoration keeps the token, allows browsing, and offers a working retry', async t => {
  const h = harness(token);
  h.offline('me');
  const ui = await mount(t, h.App);
  assert.ok(hasText(ui, 'Could not restore your session.'));
  assert.ok(hasText(ui, 'Study desk'));
  assert.equal(h.storage.get(sessionKey), token);
  await fill(ui, 'Search listings', 'desk');
  h.reply('me', 200, user);
  await press(ui, 'Retry session');
  assert.ok(hasText(ui, `Signed in as ${user.displayName}`));
  assert.equal(inputValue(ui, 'Search listings'), 'desk');
  assert.equal(hasText(ui, 'Could not restore your session.'), false);
});

test('failed logout keeps the account visible until a successful revocation retry', async t => {
  const h = harness(token);
  h.reply('me', 200, user);
  const ui = await mount(t, h.App);
  h.offline('logout');
  await press(ui, 'Log out');
  assert.ok(hasText(ui, `Signed in as ${user.displayName}`));
  assert.ok(hasText(ui, 'Could not finish logging out.'));
  assert.equal(h.storage.get(sessionKey), token);
  h.reply('logout', 204);
  await press(ui, 'Log out');
  assert.ok(control(ui, 'Student login / register'));
  assert.equal(h.storage.size, 0);
});

test('an in-flight account request disables navigation, mode changes, and credential edits', async t => {
  const h = harness();
  let backCount = 0;
  const ui = await mount(t, h.AuthScreen, { onLogin() {}, onBack: () => { backCount++; } });
  await fill(ui, 'KU email', user.email);
  await fill(ui, 'Password', 'long-password');
  const complete = h.defer('login');
  await press(ui, 'Log in');
  assert.equal(control(ui, 'Back to marketplace').props.disabled, true);
  assert.equal(control(ui, 'New here? Create an account').props.disabled, true);
  assert.ok(ui.container.queryAll(node => node.type === 'TextInput').every(node => node.props.editable === false));
  assert.equal(ui.container.queryAll(node => node.type === 'ActivityIndicator').length, 1);
  assert.equal(backCount, 0);
  await act(async () => { complete(401, { reason: 'Incorrect email or password.' }); });
  assert.equal(control(ui, 'Back to marketplace').props.disabled, false);
  assert.ok(ui.container.queryAll(node => node.type === 'TextInput').every(node => node.props.editable === true));
  assert.ok(hasText(ui, 'Incorrect email or password.'));
});

test('photo selection preserves order, handles library errors, and sends the session in multipart uploads', async t => {
  const h = harness();
  let completed;
  const ui = await mount(t, h.AddPhotos, { listingId: listing.id, token, onDone: value => { completed = value; }, onBack() {}, onSessionExpired() {} });
  h.pick(new Error('Photo permission denied'));
  await press(ui, 'Add photos');
  assert.ok(hasText(ui, 'Could not open your photo library.'));
  h.pick({ canceled: true, assets: null });
  await press(ui, 'Add photos');
  assert.equal(control(ui, 'Upload photos').props.disabled, true);
  h.pick({ canceled: false, assets: [
    { uri: 'file:///first.png', mimeType: 'image/png', fileSize: 100 },
    { uri: 'file:///first.png', mimeType: 'image/png', fileSize: 100 },
    { uri: 'file:///second.jpg', mimeType: 'image/jpeg', fileSize: 100 },
    { uri: 'file:///oversized.jpg', mimeType: 'image/jpeg', fileSize: 8 * 1024 * 1024 + 1 },
  ] });
  await press(ui, 'Add photos');
  assert.ok(hasText(ui, '2/5'));
  assert.ok(hasText(ui, 'Photos larger than 8 MB were skipped.'));
  await press(ui, 'Photo 2, make primary');
  assert.equal(control(ui, 'Primary photo').children[0].props.source.uri, 'file:///second.jpg');
  h.reply(`/api/v1/listings/${listing.id}/photos`, 422, { fieldErrors: { photos: 'Photo is corrupt.' } });
  await press(ui, 'Upload photos');
  assert.ok(hasText(ui, 'Photo is corrupt.'));
  assert.ok(hasText(ui, '2/5'));
  assert.equal(completed, undefined);
  const updated = { ...listing, photoURLs: ['/uploads/cover.jpg', '/uploads/second.png'] };
  h.reply(`/api/v1/listings/${listing.id}/photos`, 200, updated);
  await press(ui, 'Upload photos');
  assert.equal(completed.photoURLs[0], updated.photoURLs[0]);
  const uploads = h.requests.filter(request => request.url.endsWith('/photos'));
  assert.equal(uploads.length, 2);
  for (const request of uploads) {
    assert.equal(request.method, 'POST');
    assert.equal(request.headers.get('Authorization'), `Bearer ${token}`);
    assert.equal(request.headers.has('Content-Type'), false, 'Native fetch must set the multipart boundary');
    const files = request.multipart.getAll('photos[]');
    assert.deepEqual(files.map(file => file.type), ['image/jpeg', 'image/png']);
    assert.deepEqual(await Promise.all(files.map(file => file.text())), ['file:///second.jpg', 'file:///first.png']);
  }
});

test('photo uploads disable changes while pending and recover from an expired session', async t => {
  const h = harness();
  let expired = 0;
  let completed = 0;
  const ui = await mount(t, h.AddPhotos, { listingId: listing.id, token, onDone: () => completed++, onBack() {}, onSessionExpired: () => expired++ });
  h.pick({ canceled: false, assets: [{ uri: 'file:///cover.png', mimeType: 'image/png', fileSize: 100 }] });
  await press(ui, 'Add photos');
  const finish = h.defer(`/api/v1/listings/${listing.id}/photos`);
  await press(ui, 'Upload photos');
  for (const label of ['Back to my listings', 'Add photos', 'Remove photo 1', 'Primary photo']) {
    assert.equal(control(ui, label).props.disabled, true);
  }
  await act(async () => { finish(401, { reason: 'Authentication required.' }); });
  assert.equal(expired, 1);
  assert.equal(completed, 0);
});

test('owned listing requests use bearer authentication and relative photo URLs use the shared API host', async () => {
  const h = harness();
  h.reply('/api/v1/me/listings', 200, [{ status: 'active', listing }]);
  const owned = await h.api.myListings(token, new AbortController().signal);
  assert.equal(owned[0].listing.id, listing.id);
  assert.equal(h.requests[0].headers.get('Authorization'), `Bearer ${token}`);
  assert.equal(h.api.photoURL('/uploads/image.jpg'), 'http://marketplace.test:8080/uploads/image.jpg');
  assert.equal(h.api.photoURL('https://images.example/image.jpg'), 'https://images.example/image.jpg');
});

async function startListing(t) {
  const h = harness(token);
  h.reply('me', 200, user);
  const ui = await mount(t, h.App);
  h.reply('/api/v1/me/listings', 200, []);
  await press(ui, 'My listings');
  assert.ok(hasText(ui, 'You have no listings yet.'));
  await press(ui, 'Create listing');
  return { h, ui };
}

async function fillListing(ui) {
  await fill(ui, 'Title', listing.title);
  await fill(ui, 'Description', listing.description);
  await fill(ui, 'Price in dollars', '25.00');
  await fill(ui, 'Category', listing.category);
}

const writes = h => h.requests.filter(request => request.method === 'POST');

test('invalid listing fields show local feedback without a publish request', async t => {
  const { h, ui } = await startListing(t);
  await fillListing(ui);
  for (const [label, invalid, valid] of [
    ['Title', '   ', listing.title],
    ['Description', '', listing.description],
    ['Category', '  ', listing.category],
    ['Price in dollars', '1.235', '25.00'],
    ['Price in dollars', '0', '25.00'],
  ]) {
    await fill(ui, label, invalid);
    await press(ui, 'Publish listing');
    assert.equal(writes(h).length, 0, `Invalid ${label} reached the server`);
    assert.ok(ui.container.queryAll(node => node.type === 'Text' && node.props.accessibilityRole === 'alert').length);
    await fill(ui, label, valid);
  }
});

test('a valid listing with zero photos publishes directly and opens public details', async t => {
  const { h, ui } = await startListing(t);
  await fillListing(ui);
  h.reply('/api/v1/listings', 201, listing);
  await press(ui, 'Publish listing');
  const [publish] = writes(h);
  assert.equal(writes(h).length, 1);
  assert.equal(new URL(publish.url).pathname, '/api/v1/listings');
  assert.equal(publish.headers.get('Authorization'), `Bearer ${token}`);
  assert.equal(publish.headers.get('Content-Type'), 'application/json');
  assert.equal(JSON.parse(publish.body).priceCents, 2500);
  assert.equal(JSON.parse(publish.body).ownerID, undefined);
  assert.ok(hasText(ui, listing.description));
  assert.ok(hasText(ui, 'No photo'));
});

test('a seller can preview, reorder and remove images and retry a rejected publish with the draft intact', async t => {
  const { h, ui } = await startListing(t);
  await fillListing(ui);
  let finishPicking;
  h.pick(new Promise(resolve => { finishPicking = resolve; }));
  await press(ui, 'Add photos');
  assert.equal(control(ui, 'Publish listing').props.disabled, true);
  await act(async () => { finishPicking({ canceled: false, assets: [
    { uri: 'file:///desk.png', fileSize: 100 }, { uri: 'file:///discard.png', fileSize: 100 },
    { uri: 'file:///cover.jpg', fileSize: 100 },
  ] }); });
  await press(ui, 'Remove photo 2');
  await press(ui, 'Photo 2, make primary');
  assert.equal(control(ui, 'Primary photo').children[0].props.source.uri, 'file:///cover.jpg');
  assert.equal(writes(h).length, 0, 'Editing a draft must leave the marketplace unchanged');
  h.reply('/api/v1/listings', 422, { fieldErrors: { photos: 'Photo is corrupt.' } });
  await press(ui, 'Publish listing');
  assert.ok(hasText(ui, 'Photo is corrupt.'));
  assert.equal(inputValue(ui, 'Title'), listing.title);
  assert.ok(hasText(ui, '2/5'));
  const updated = { ...listing, photoURLs: ['/uploads/cover.jpg', '/uploads/desk.png'] };
  h.reply('/api/v1/listings', 201, updated);
  h.reply(`/api/v1/listings/${listing.id}`, 200, updated);
  await press(ui, 'Publish listing');
  assert.equal(writes(h).length, 2, 'One publish request per attempt');
  for (const publish of writes(h)) {
    assert.equal(new URL(publish.url).pathname, '/api/v1/listings');
    assert.equal(publish.headers.get('Authorization'), `Bearer ${token}`);
    assert.equal(publish.headers.has('Content-Type'), false, 'Fetch supplies the multipart boundary');
    const draft = JSON.parse(publish.multipart.get('listing'));
    assert.equal(draft.title, listing.title);
    assert.equal(draft.priceCents, 2500);
    const photos = publish.multipart.getAll('photos[]');
    assert.deepEqual(await Promise.all(photos.map(file => file.text())), ['file:///cover.jpg', 'file:///desk.png']);
  }
  assert.ok(hasText(ui, listing.description));
  assert.ok(ui.container.queryAll(node => node.type === 'Image').some(node =>
    node.props.source.uri === `http://marketplace.test:8080${updated.photoURLs[0]}`));
});

test('leaving a listing draft with selected photos creates no listing or upload', async t => {
  const { h, ui } = await startListing(t);
  await fillListing(ui);
  h.pick({ canceled: false, assets: [{ uri: 'file:///draft.jpg', fileSize: 100 }] });
  await press(ui, 'Add photos');
  h.reply('/api/v1/me/listings', 200, []);
  await press(ui, 'Back to my listings');
  assert.equal(writes(h).length, 0);
  assert.ok(control(ui, 'Create listing'));
});

test('owner sees a photo placeholder and opens fresh sold details through the private route', async t => {
  const h = harness(token);
  h.reply('me', 200, user);
  const ui = await mount(t, h.App);
  const sold = { ...listing, id: 'sold-1', title: 'Sold lamp' };
  const rows = [{ status: 'sold', listing: sold }];
  h.reply('/api/v1/me/listings', 200, rows);
  await press(ui, 'My listings');
  assert.ok(hasText(ui, 'No photo'));
  const route = '/api/v1/me/listings/sold-1';
  h.reply(route, 200, { status: 'sold', listing: { ...sold, description: 'Fresh owner-only detail.' } });
  await press(ui, 'View Sold lamp');
  const reads = h.requests.filter(request => new URL(request.url).pathname.endsWith('/sold-1'));
  assert.equal(reads.length, 1);
  assert.equal(new URL(reads[0].url).pathname, route);
  assert.equal(reads[0].headers.get('Authorization'), `Bearer ${token}`);
  assert.ok(hasText(ui, 'Fresh owner-only detail.'));
  h.reply('/api/v1/me/listings', 200, rows);
  await press(ui, 'Back to my listings');
  assert.ok(control(ui, 'View Sold lamp'));
});

test('My listings restricts photo actions to active items and offers login after session expiry', async t => {
  const h = harness(token);
  h.reply('me', 200, user);
  const ui = await mount(t, h.App);
  h.reply('/api/v1/me/listings', 200, [
    { status: 'active', listing },
    { status: 'sold', listing: { ...listing, id: 'sold-1', title: 'Sold lamp' } },
  ]);
  await press(ui, 'My listings');
  assert.ok(control(ui, `Add or replace photos for ${listing.title}`));
  assert.equal(ui.container.queryAll(node => node.props.accessibilityLabel === 'Add or replace photos for Sold lamp').length, 0);
  await press(ui, 'Back to marketplace');
  h.reply('/api/v1/me/listings', 401, { reason: 'Authentication required.' });
  await press(ui, 'My listings');
  await press(ui, 'Log in again');
  assert.ok(control(ui, 'Log in'));
});


async function openEditor(t) {
  const h = harness(token);
  h.reply('me', 200, user);
  const ui = await mount(t, h.App);
  h.reply('/api/v1/me/listings', 200, [{ status: 'active', listing, revision: 'initial' }]);
  await press(ui, 'My listings');
  h.reply(`/api/v1/me/listings/${listing.id}`, 200, { status: 'active', listing, revision: 'initial' });
  await press(ui, `Edit ${listing.title}`);
  return { h, ui };
}

test('editing is populated, validates all fields, and cancel sends no save', async t => {
  const { h, ui } = await openEditor(t);
  assert.equal(inputValue(ui, 'Title'), listing.title);
  assert.equal(inputValue(ui, 'Description'), listing.description);
  assert.equal(inputValue(ui, 'Price in dollars'), '25.00');
  assert.equal(inputValue(ui, 'Category'), listing.category);
  assert.ok(control(ui, 'Good (selected)'));
  for (const field of ['Title', 'Description', 'Category']) await fill(ui, field, ' ');
  await fill(ui, 'Price in dollars', '0');
  await press(ui, 'Save changes');
  for (const message of ['Title is required.', 'Description is required.', 'Category is required.', 'Price must be between']) {
    assert.ok(hasText(ui, message));
  }
  assert.equal(h.requests.filter(r => r.method === 'PATCH').length, 0);
  h.reply('/api/v1/me/listings', 200, [{ status: 'active', listing, revision: 'initial' }]);
  await press(ui, 'Cancel');
  assert.ok(hasText(ui, listing.title));
  assert.equal(h.requests.filter(r => r.method === 'PATCH').length, 0);
});

test('editing retains server field errors, disables duplicate saves, and refreshes My listings on success', async t => {
  const { h, ui } = await openEditor(t);
  await fill(ui, 'Title', 'Updated desk');
  h.reply(`/api/v1/listings/${listing.id}`, 422, { fieldErrors: { title: 'Server title error.' } });
  await press(ui, 'Save changes');
  assert.ok(hasText(ui, 'Server title error.'));
  assert.equal(inputValue(ui, 'Title'), 'Updated desk');
  const finish = h.defer(`/api/v1/listings/${listing.id}`);
  await press(ui, 'Save changes');
  assert.equal(control(ui, 'Cancel').props.disabled, true);
  assert.equal(control(ui, 'Reload listing').props.disabled, true);
  assert.ok(ui.container.queryAll(n => n.type === 'TextInput').every(n => n.props.editable === false));
  const updated = { status: 'active', listing: { ...listing, title: 'Updated desk' }, revision: 'v2' };
  h.reply('/api/v1/me/listings', 200, [updated]);
  await act(async () => finish(200, updated));
  assert.ok(hasText(ui, 'Updated desk'));
  const save = h.requests.filter(r => r.method === 'PATCH').at(-1);
  assert.equal(save.headers.get('Authorization'), `Bearer ${token}`);
  assert.equal(save.headers.get('If-Match'), 'initial');
  assert.equal(JSON.parse(save.body).priceCents, 2500);
  assert.equal(JSON.parse(save.body).ownerID, undefined);
});

test('stale edits require reload and use the refreshed revision on retry', async t => {
  const { h, ui } = await openEditor(t);
  await fill(ui, 'Title', 'My unsaved title');
  h.reply(`/api/v1/listings/${listing.id}`, 409, { reason: 'This listing has changed. Reload before editing again.' });
  await press(ui, 'Save changes');
  assert.ok(hasText(ui, 'This listing has changed.'));
  assert.equal(inputValue(ui, 'Title'), 'My unsaved title');
  assert.equal(control(ui, 'Save changes').props.disabled, true);
  const current = { status: 'active', listing: { ...listing, title: 'Saved elsewhere' }, revision: 'v2' };
  h.reply(`/api/v1/me/listings/${listing.id}`, 200, current);
  await press(ui, 'Reload listing');
  assert.equal(inputValue(ui, 'Title'), 'Saved elsewhere');
  assert.equal(control(ui, 'Save changes').props.disabled, false);
  h.reply(`/api/v1/listings/${listing.id}`, 200, { ...current, revision: 'v3' });
  h.reply('/api/v1/me/listings', 200, [current]);
  await press(ui, 'Save changes');
  assert.equal(h.requests.filter(r => r.method === 'PATCH').at(-1).headers.get('If-Match'), 'v2');
});

test('inactive reloads prevent editing and session expiry returns to login', async t => {
  const { h, ui } = await openEditor(t);
  h.reply(`/api/v1/listings/${listing.id}`, 409, { reason: 'This listing is no longer active.' });
  await press(ui, 'Save changes');
  h.reply(`/api/v1/me/listings/${listing.id}`, 200, { status: 'sold', listing, revision: 'v2' });
  await press(ui, 'Reload listing');
  assert.ok(hasText(ui, 'sold and cannot be edited'));
  assert.equal(ui.container.queryAll(n => n.type === 'TextInput').length, 0);
  h.reply(`/api/v1/me/listings/${listing.id}`, 401, { reason: 'Authentication required.' });
  await press(ui, 'Reload listing');
  assert.ok(control(ui, 'Log in'));
});


async function openManagedListings(t) {
  const h = harness(token);
  h.reply('me', 200, user);
  const ui = await mount(t, h.App);
  h.reply('/api/v1/me/listings', 200, [{ status: 'active', listing, revision: 'initial' }]);
  await press(ui, 'My listings');
  return { h, ui };
}

test('mark sold confirms before sending, disables duplicate requests, and keeps seller history', async t => {
  const { h, ui } = await openManagedListings(t);
  await press(ui, `Mark sold ${listing.title}`);
  assert.equal(h.requests.filter(r => r.url.endsWith('/sold')).length, 0);
  await press(ui, 'Cancel listing action');
  await press(ui, `Mark sold ${listing.title}`);
  const finish = h.defer(`/api/v1/listings/${listing.id}/sold`);
  await press(ui, 'Confirm mark sold');
  assert.equal(control(ui, 'Confirm mark sold').props.disabled, true);
  assert.equal(control(ui, 'Back to marketplace').props.disabled, true);
  await act(async () => finish(200, { status: 'sold', listing, revision: 'sold-v2' }));
  assert.ok(hasText(ui, 'Listing marked as sold.'));
  assert.ok(hasText(ui, listing.title));
  assert.ok(hasText(ui, 'No longer visible to buyers'));
  assert.equal(ui.container.queryAll(n => n.props?.accessibilityLabel === `Edit ${listing.title}`).length, 0);
  const request = h.requests.find(r => r.url.endsWith('/sold'));
  assert.equal(request.method, 'POST');
  assert.equal(request.headers.get('If-Match'), 'initial');
  assert.equal(request.headers.get('Authorization'), `Bearer ${token}`);
});

test('delete can be canceled, preserves the card on network failure and removes it only after success', async t => {
  const { h, ui } = await openManagedListings(t);
  await press(ui, `Delete ${listing.title}`);
  await press(ui, 'Cancel listing action');
  assert.equal(h.requests.filter(r => r.method === 'DELETE').length, 0);
  await press(ui, `Delete ${listing.title}`);
  h.offline(`/api/v1/listings/${listing.id}`);
  await press(ui, 'Confirm delete');
  assert.ok(hasText(ui, 'Could not reach the marketplace'));
  assert.ok(hasText(ui, listing.title));
  h.reply(`/api/v1/listings/${listing.id}`, 200, { status: 'deleted', listing, revision: 'deleted-v2' });
  await press(ui, 'Confirm delete');
  assert.ok(hasText(ui, 'Listing deleted.'));
  assert.equal(hasText(ui, listing.title), false);
  assert.ok(hasText(ui, 'You have no listings yet.'));
  const request = h.requests.filter(r => r.method === 'DELETE').at(-1);
  assert.equal(request.headers.get('If-Match'), 'initial');
});

test('stale status actions require reload and expired sessions return to login', async t => {
  const { h, ui } = await openManagedListings(t);
  await press(ui, `Delete ${listing.title}`);
  h.reply(`/api/v1/listings/${listing.id}`, 409, { reason: 'This listing has changed. Reload your listings before trying again.' });
  await press(ui, 'Confirm delete');
  assert.equal(control(ui, 'Confirm delete').props.disabled, true);
  h.reply('/api/v1/me/listings', 200, [{ status: 'active', listing, revision: 'v2' }]);
  await press(ui, 'Reload my listings');
  await press(ui, `Mark sold ${listing.title}`);
  h.reply(`/api/v1/listings/${listing.id}/sold`, 401, { reason: 'Authentication required.' });
  await press(ui, 'Confirm mark sold');
  assert.ok(control(ui, 'Log in'));
});

test('resend verification validates email and counts down the server cooldown for each address', async t => {
  const clock = manualClock();
  const h = harness(undefined, clock);
  const ui = await mount(t, h.AuthScreen, { onLogin() {}, onBack() {} });
  await fill(ui, 'KU email', 'student@example.com');
  await press(ui, 'Resend verification email');
  assert.ok(hasText(ui, 'Use your @ku.edu email address.'));
  assert.equal(h.requests.length, 0);
  await fill(ui, 'KU email', ' Student@KU.edu ');
  h.reply('resend-verification', 200, { message: 'Check your KU email.', retryAfterSeconds: 60 });
  await press(ui, 'Resend verification email');
  assert.equal(control(ui, 'Resend verification email').props.disabled, true);
  assert.deepEqual(JSON.parse(h.requests[0].body), { email: user.email });
  assert.ok(hasText(ui, '60 seconds'));
  await act(async () => { clock.advance(59000); });
  assert.ok(hasText(ui, '1 seconds'));
  await act(async () => { clock.advance(1000); });
  assert.equal(control(ui, 'Resend verification email').props.disabled, false);
  h.reply('resend-verification', 429, { reason: 'Please wait before requesting another verification email.', retryAfterSeconds: 37 });
  await press(ui, 'Resend verification email');
  assert.ok(hasText(ui, 'Please wait before requesting another verification email.'));
  assert.ok(hasText(ui, '37 seconds'));
  await fill(ui, 'KU email', 'another@ku.edu');
  assert.equal(control(ui, 'Resend verification email').props.disabled, false);
  await fill(ui, 'KU email', 'STUDENT@KU.EDU');
  assert.equal(control(ui, 'Resend verification email').props.disabled, true);
  assert.equal(h.storage.size, 0);
});

test('an unverified student can resend; duplicate requests and navigation are blocked while delivery is pending', async t => {
  const h = harness();
  let loggedIn = false;
  const ui = await mount(t, h.AuthScreen, { onLogin() { loggedIn = true; }, onBack() {} });
  await fill(ui, 'KU email', user.email);
  await fill(ui, 'Password', 'long-password');
  h.reply('login', 403, { reason: 'Verify your KU email before logging in.' });
  await press(ui, 'Log in');
  const finish = h.defer('resend-verification');
  const resend = control(ui, 'Resend verification email');
  await act(async () => { resend.props.onPress(); resend.props.onPress(); });
  assert.equal(h.requests.filter(request => request.url.endsWith('/resend-verification')).length, 1);
  for (const label of ['Resend verification email', 'Back to marketplace', 'New here? Create an account']) {
    assert.equal(control(ui, label).props.disabled, true);
  }
  assert.ok(ui.container.queryAll(node => node.type === 'TextInput').every(node => node.props.editable === false));
  await act(async () => { finish(503, { reason: 'Verification email could not be delivered.' }); });
  assert.ok(hasText(ui, 'Verification email could not be delivered.'));
  assert.equal(control(ui, 'Resend verification email').props.disabled, false);
  assert.equal(loggedIn, false);
  assert.equal(h.storage.size, 0);
});

test('marketplace filters combine with the keyword, reject a bad range, and clear without losing it', async t => {
  const h = harness();
  const ui = await mount(t, h.App);
  assert.ok(hasText(ui, 'Study desk'));

  await fill(ui, 'Search listings', 'desk');
  await press(ui, 'Filters');
  await press(ui, 'Textbooks');
  await press(ui, 'Good');
  await fill(ui, 'Minimum price', '10');
  await fill(ui, 'Maximum price', '20');
  await press(ui, 'Apply filters');

  const filtered = h.requests.at(-1);
  assert.match(filtered.url, /[?&]q=desk/);
  assert.match(filtered.url, /category=Textbooks/);
  assert.match(filtered.url, /condition=Good/);
  assert.match(filtered.url, /minPriceCents=1000/);
  assert.match(filtered.url, /maxPriceCents=2000/);
  assert.ok(hasText(ui, '4 applied'));

  // An inverted range is refused locally, before any request leaves the app.
  const sent = h.requests.length;
  await press(ui, 'Filters');
  await fill(ui, 'Minimum price', '30');
  await press(ui, 'Apply filters');
  assert.equal(h.requests.length, sent);
  assert.ok(hasText(ui, 'Minimum price must not be greater than the maximum.'));

  // A price that is not a number is refused the same way.
  await fill(ui, 'Minimum price', 'ten');
  await press(ui, 'Apply filters');
  assert.equal(h.requests.length, sent);
  assert.ok(hasText(ui, 'Enter prices like 10 or 10.50.'));

  // Clearing filters keeps the keyword and drops every filter parameter.
  await fill(ui, 'Minimum price', '10');
  await press(ui, 'Apply filters');
  await press(ui, 'Clear filters');
  const cleared = h.requests.at(-1);
  assert.match(cleared.url, /[?&]q=desk/);
  assert.doesNotMatch(cleared.url, /category=|condition=|minPriceCents=|maxPriceCents=/);
  assert.equal(inputValue(ui, 'Search listings'), 'desk');
  assert.ok(!hasText(ui, '4 applied'));

  // Reopening the panel after clearing shows empty fields, and a new filter still applies.
  await press(ui, 'Filters');
  assert.equal(inputValue(ui, 'Minimum price'), '');
  await press(ui, 'Dorm & Living');
  await press(ui, 'Apply filters');
  assert.match(h.requests.at(-1).url, /category=Dorm%20%26%20Living/);
});

test('sorting changes the feed order and keeps the keyword and filters', async t => {
  const h = harness();
  const ui = await mount(t, h.App);
  await fill(ui, 'Search listings', 'desk');

  await press(ui, 'Lowest price');
  assert.match(h.requests.at(-1).url, /sort=price_asc/);
  assert.match(h.requests.at(-1).url, /[?&]q=desk/);

  await press(ui, 'Filters');
  await press(ui, 'Textbooks');
  await press(ui, 'Apply filters');
  assert.match(h.requests.at(-1).url, /sort=price_asc/);
  assert.match(h.requests.at(-1).url, /category=Textbooks/);

  await press(ui, 'Highest price');
  assert.match(h.requests.at(-1).url, /sort=price_desc/);

  // Newest is the default, so it must not be sent as an explicit parameter.
  await press(ui, 'Newest');
  const newest = h.requests.at(-1).url;
  assert.doesNotMatch(newest, /sort=/);
  assert.match(newest, /category=Textbooks/);
  assert.equal(inputValue(ui, 'Search listings'), 'desk');
});
