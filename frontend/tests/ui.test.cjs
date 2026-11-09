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
function harness(storedToken) {
  const storage = new Map(storedToken ? [[sessionKey, storedToken]] : []);
  const requests = [];
  const replies = new Map();
  const pickerResults = [];
  const native = {
    Platform: { OS: 'ios' }, StyleSheet: { create: value => value },
    ...Object.fromEntries(['ActivityIndicator', 'Button', 'Image', 'Pressable',
      'SafeAreaView', 'ScrollView', 'Text', 'TextInput', 'View'].map(name => [name, name])),
    FlatList: ({ data, renderItem, ListEmptyComponent }) => React.createElement('FlatList', null,
      data.length ? data.map((item, index) => React.createElement(React.Fragment, { key: item.id }, renderItem({ item, index }))) : ListEmptyComponent),
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
      react: React, 'react/jsx-runtime': require('react/jsx-runtime'),
      'react-native': native, 'expo-status-bar': { StatusBar: 'StatusBar' },
      'expo-secure-store': secureStore,
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
      // React Native accepts local file objects; Node's FormData only accepts Blobs.
      FormData: class {
        parts = [];
        append(name, value) { this.parts.push({ name, value }); }
      },
      fetch: async (url, options = {}) => {
        const route = new URL(url).pathname;
        requests.push({ url: String(url), ...options, headers: new Headers(options.headers) });
        const queue = replies.get(route);
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
    assert.equal(request.body.parts.map(part => part.name).join(','), 'photos[],photos[]');
    assert.equal(request.body.parts.map(part => part.value.uri).join(','), 'file:///second.jpg,file:///first.png');
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

test('signed-in users can create an item, upload its photo, and open refreshed public details', async t => {
  const h = harness(token);
  h.reply('me', 200, user);
  const ui = await mount(t, h.App);
  h.reply('/api/v1/me/listings', 200, []);
  await press(ui, 'My listings');
  assert.ok(hasText(ui, 'You have no listings yet.'));
  await press(ui, 'Create listing');
  await fill(ui, 'Title', listing.title);
  await fill(ui, 'Description', listing.description);
  await fill(ui, 'Price in dollars', '25.00');
  await fill(ui, 'Category', listing.category);
  h.reply('/api/v1/listings', 201, listing);
  await press(ui, 'Publish and add photos');
  const publish = h.requests.find(request => request.method === 'POST' && request.url.endsWith('/listings'));
  assert.equal(publish.headers.get('Authorization'), `Bearer ${token}`);
  assert.equal(JSON.parse(publish.body).priceCents, 2500);
  assert.equal(JSON.parse(publish.body).ownerID, undefined);
  h.pick({ canceled: false, assets: [{ uri: 'file:///cover.png', mimeType: 'image/png', fileSize: 100 }] });
  await press(ui, 'Add photos');
  const updated = { ...listing, photoURLs: ['/uploads/listings/desk-1/version/0.png'] };
  h.reply(`/api/v1/listings/${listing.id}/photos`, 200, updated);
  h.reply(`/api/v1/listings/${listing.id}`, 200, updated);
  await press(ui, 'Upload photos');
  assert.ok(hasText(ui, listing.description));
  assert.ok(ui.container.queryAll(node => node.type === 'Image').some(node =>
    node.props.source.uri === `http://marketplace.test:8080${updated.photoURLs[0]}`));
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
  assert.equal(ui.container.queryAll(node => node.type === 'Button' && node.props.title === 'Add or replace photos for Sold lamp').length, 0);
  await press(ui, 'Back to marketplace');
  h.reply('/api/v1/me/listings', 401, { reason: 'Authentication required.' });
  await press(ui, 'My listings');
  await press(ui, 'Log in again');
  assert.ok(control(ui, 'Log in'));
});
