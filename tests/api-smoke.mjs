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
assert.deepEqual(await get(path + '?q=no-match'), []);
assert.equal((await get(path + '/desk-lamp')).priceCents, 1200);
for (const id of ['bike', 'missing']) assert.equal((await fetch(base + path + '/' + id)).status, 404);
console.log('Marketplace API smoke checks passed.');
