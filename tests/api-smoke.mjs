import assert from 'node:assert/strict';
const base = process.env.API_URL || 'http://127.0.0.1:8080';
async function get(path) {
  const res = await fetch(base + path);
  assert.equal(res.status, 200, path);
  return res.json();
}
const path = '/api/v1/listings';
assert.equal((await get('/health')).status, 'ok');
const feed = await get(path);
assert.deepEqual(feed.map(item => item.id).sort(), ['calculus', 'desk-lamp']);
assert.deepEqual((await get(path + '?q=DORM')).map(item => item.id), ['desk-lamp']);
assert.deepEqual((await get(path + '?q=CaLcUlUs')).map(item => item.id), ['calculus']);
assert.deepEqual((await get(path + '?q=%20dOrM%20')).map(item => item.id), ['desk-lamp']);
for (const suffix of ['?q=', '?q=%20%0A%20']) assert.deepEqual(await get(path + suffix), feed);
assert.deepEqual(await get(path + '?q=commuter'), []);
assert.deepEqual(await get(path + '?q=no-match'), []);
assert.equal((await get(path + '/desk-lamp')).priceCents, 1200);
for (const id of ['bike', 'missing']) assert.equal((await fetch(base + path + '/' + id)).status, 404);
for (const suffix of ['', '/desk-lamp']) {
  const response = await fetch(base + '/api/v1/me/listings' + suffix, {
    headers: { Authorization: 'Bearer sam', 'X-User-ID': 'sam' },
  });
  assert.equal(response.status, 401);
}
console.log('Marketplace API smoke checks passed.');
