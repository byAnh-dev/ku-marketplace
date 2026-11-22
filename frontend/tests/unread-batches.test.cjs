const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { createAppLoader } = require('./load-app.cjs');

// Exercise batching independently of the transport. Server-side authorization and
// persistence are covered by UnreadReceiptTests using Vapor and SQLite.
function unreadClient(messagingRequest) {
  return createAppLoader({ modules: { './messaging': { messagingRequest } } })(
    path.resolve(__dirname, '../src/unread.ts'));
}

test('the summary uses the current token and forwards cancellation', async () => {
  const signal = new AbortController().signal;
  const summary = { total: 0, threads: [] };
  const api = unreadClient((...args) => {
    assert.deepEqual(args, ['me/unread', 'session', 'GET', undefined, signal]);
    return Promise.resolve(summary);
  });
  assert.equal(await api.fetchUnread('session', signal), summary);
});

test('displayed IDs retain gaps and are deduplicated before splitting into batches', async () => {
  const ids = Array.from({ length: 205 }, (_, i) => 2 * i + 1);
  const batches = [];
  const api = unreadClient(async (url, token, method, body) => {
    assert.equal(url, 'conversations/a%2Fb/read');
    assert.equal(token, 'session');
    assert.equal(method, 'POST');
    batches.push(Array.from(body.sequences));
  });
  await api.markDisplayed('session', 'a/b', []);
  assert.equal(batches.length, 0);
  await api.markDisplayed('session', 'a/b', [...ids, ids[0], ids[100]]);
  assert.deepEqual(batches.map(batch => batch.length), [100, 100, 5]);
  assert.deepEqual(batches.flat(), ids);
});

test('a failed batch stops later sends and leaves the caller free to retry the IDs', async () => {
  const ids = Array.from({ length: 201 }, (_, i) => i + 1);
  const sizes = [];
  const api = unreadClient(async (_url, _token, _method, body) => {
    sizes.push(body.sequences.length);
    if (sizes.length === 2) throw new Error('connection lost');
  });
  await assert.rejects(api.markDisplayed('session', 'thread', ids), /connection lost/);
  assert.deepEqual(sizes, [100, 100]);
  await api.markDisplayed('session', 'thread', ids);
  assert.deepEqual(sizes, [100, 100, 100, 100, 1]);
});
