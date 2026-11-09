const assert = require('node:assert/strict');
const path = require('node:path');
const { test } = require('node:test');
const { createAppLoader } = require('./load-app.cjs');

// Expectations come from the backend auth routes and the session lifecycle
// contract. Only the native keychain and HTTP transport are replaced here.
const sessionKey = 'ku_marketplace_session';
const token = 'A'.repeat(72);
const user = {
  id: '84b9c5ab-37f2-490e-ad8f-70c9d21186fb',
  displayName: 'Test Student', email: 'student@ku.edu', verified: true,
};

function harness({ storedToken, storageError } = {}) {
  const storage = new Map(storedToken ? [[sessionKey, storedToken]] : []);
  const requests = [];
  const replies = [];
  const secureStore = {
    async getItemAsync(key) {
      if (storageError === 'read') throw new Error('Keychain unavailable');
      return storage.get(key) ?? null;
    },
    async setItemAsync(key, value) {
      if (storageError === 'write') throw new Error('Keychain unavailable');
      storage.set(key, value);
    },
    async deleteItemAsync(key) {
      if (storageError === 'delete') throw new Error('Keychain unavailable');
      storage.delete(key);
    },
  };
  const load = createAppLoader({
    modules: { 'expo-secure-store': secureStore, 'react-native': { Platform: { OS: 'ios' } } },
    globals: {
      fetch: async (url, options = {}) => {
        requests.push({ url: String(url), ...options, headers: new Headers(options.headers) });
        assert.ok(replies.length, `Unexpected request: ${url}`);
        const reply = replies.shift();
        if (reply instanceof Error) throw reply;
        return new Response(reply.status === 204 ? null : JSON.stringify(reply.body), {
          status: reply.status, headers: { 'Content-Type': 'application/json' },
        });
      },
    },
  });
  return {
    auth: load(path.resolve(__dirname, '../src/auth.ts')), storage, requests,
    reply: (status, body) => replies.push({ status, body }),
    offline: () => replies.push(new Error('Network unavailable')),
  };
}

function expectRequest(request, method, route, bearer) {
  assert.equal(request.url, `http://marketplace.test:8080/api/v1/auth/${route}`);
  assert.equal(request.method ?? 'GET', method);
  assert.equal(request.headers.get('Authorization'), bearer ? `Bearer ${bearer}` : null);
}

test('registration sends the backend fields and returns verification instructions without storing a session', async () => {
  const h = harness();
  const message = 'Check your KU email for a verification link before logging in.';
  h.reply(200, { message });
  assert.equal(await h.auth.register(user.displayName, user.email, 'long-password', 'long-password'), message);
  expectRequest(h.requests[0], 'POST', 'register');
  assert.equal(h.requests[0].headers.get('Content-Type'), 'application/json');
  assert.deepEqual(JSON.parse(h.requests[0].body), {
    displayName: user.displayName, email: user.email,
    password: 'long-password', passwordConfirmation: 'long-password',
  });
  assert.equal(h.storage.size, 0);
});

test('registration exposes a backend rejection instead of claiming success', async () => {
  const h = harness();
  h.reply(409, { reason: 'An account with this email already exists.' });
  await assert.rejects(h.auth.register(user.displayName, user.email, 'long-password', 'long-password'), /already exists/);
  assert.equal(h.storage.size, 0);
});

test('login sends credentials, stores only the token, and returns the account UUID', async () => {
  const h = harness();
  h.reply(200, { token, user });
  const session = await h.auth.login(user.email, 'long-password');
  expectRequest(h.requests[0], 'POST', 'login');
  assert.deepEqual(JSON.parse(h.requests[0].body), { email: user.email, password: 'long-password' });
  assert.equal(session.token, token);
  assert.equal(session.user.id, user.id);
  assert.deepEqual([...h.storage.values()], [token]);
});

for (const [status, reason] of [[401, 'Incorrect email or password.'], [403, 'Verify your KU email before logging in.']]) {
  test(`login rejection ${status} does not create a stored session`, async () => {
    const h = harness();
    h.reply(status, { reason });
    await assert.rejects(h.auth.login(user.email, 'long-password'), error => error.message === reason);
    assert.equal(h.storage.size, 0);
  });
}

test('login does not report a persistent session when keychain storage fails', async () => {
  const h = harness({ storageError: 'write' });
  h.reply(200, { token, user });
  // Implementations may revoke the newly issued token after storage failure.
  h.reply(204);
  await assert.rejects(h.auth.login(user.email, 'long-password'));
  assert.equal(h.storage.size, 0);
});

for (const [label, body] of [
  ['missing token', { user }],
  ['unverified account', { token, user: { ...user, verified: false } }],
]) {
  test(`login rejects an invalid successful response with ${label}`, async () => {
    const h = harness();
    h.reply(200, body);
    await assert.rejects(h.auth.login(user.email, 'long-password'));
    assert.equal(h.storage.size, 0);
  });
}

test('restoration without a stored token does not contact the server', async () => {
  const h = harness();
  assert.equal(await h.auth.restoreSession(), null);
  assert.equal(h.requests.length, 0);
});

test('restoration checks the stored bearer token with the backend', async () => {
  const h = harness({ storedToken: token });
  h.reply(200, user);
  const session = await h.auth.restoreSession();
  expectRequest(h.requests[0], 'GET', 'me', token);
  assert.equal(session.token, token);
  assert.equal(session.user.id, user.id);
  assert.equal(h.storage.get(sessionKey), token);
});

for (const status of [401, 403]) {
  test(`restoration removes a rejected token on ${status}`, async () => {
    const h = harness({ storedToken: token });
    h.reply(status, { reason: 'Authentication required.' });
    assert.equal(await h.auth.restoreSession(), null);
    expectRequest(h.requests[0], 'GET', 'me', token);
    assert.equal(h.storage.size, 0);
  });
}

for (const failure of ['offline', 500]) {
  test(`restoration retains the token and reports a retryable failure when ${failure}`, async () => {
    const h = harness({ storedToken: token });
    if (failure === 'offline') h.offline(); else h.reply(failure, { reason: 'Temporarily unavailable.' });
    await assert.rejects(h.auth.restoreSession());
    assert.equal(h.storage.get(sessionKey), token);
    h.reply(200, user);
    assert.equal((await h.auth.restoreSession()).user.id, user.id);
  });
}

test('restoration reports a keychain read failure without making an anonymous request', async () => {
  const h = harness({ storedToken: token, storageError: 'read' });
  await assert.rejects(h.auth.restoreSession());
  assert.equal(h.requests.length, 0);
});

test('logout sends the bearer token and clears storage after server revocation', async () => {
  const h = harness({ storedToken: token });
  h.reply(204);
  await h.auth.logout(token);
  expectRequest(h.requests[0], 'POST', 'logout', token);
  assert.equal(h.storage.size, 0);
});

for (const status of [401, 403]) {
  test(`logout clears a token the server already rejects with ${status}`, async () => {
    const h = harness({ storedToken: token });
    h.reply(status, { reason: 'Authentication required.' });
    await h.auth.logout(token);
    expectRequest(h.requests[0], 'POST', 'logout', token);
    assert.equal(h.storage.size, 0);
  });
}

for (const failure of ['offline', 500]) {
  test(`logout retains the token for a revocation retry when ${failure}`, async () => {
    const h = harness({ storedToken: token });
    if (failure === 'offline') h.offline(); else h.reply(failure, { reason: 'Temporarily unavailable.' });
    await assert.rejects(h.auth.logout(token));
    assert.equal(h.storage.get(sessionKey), token);
    h.reply(204);
    await h.auth.logout(token);
    assert.equal(h.storage.size, 0);
    for (const request of h.requests) expectRequest(request, 'POST', 'logout', token);
  });
}

test('logout reports failure to remove the token from the keychain', async () => {
  const h = harness({ storedToken: token, storageError: 'delete' });
  h.reply(204);
  await assert.rejects(h.auth.logout(token));
  assert.equal(h.storage.get(sessionKey), token);
});
