// End-to-end integration check for the mobile contract: publish, photo, browse
// with filters and sort, pagination, details, edit, mark sold, and the error
// shapes the app renders. Needs a verified account's session token; skips
// without one.
//
//   API_URL=http://localhost:8080 SMOKE_TOKEN=<token> node tests/sprint2-smoke.mjs
import assert from 'node:assert/strict';

const host = (process.env.API_URL ?? 'http://localhost:8080').replace(/\/+$/, '');
const token = process.env.SMOKE_TOKEN;

if (!token) {
  console.log('Sprint 2 integration smoke skipped: set SMOKE_TOKEN to a verified account session.');
  process.exit(0);
}

const json = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
const auth = { Authorization: `Bearer ${token}` };
const call = async (path, init = {}) => {
  const response = await fetch(`${host}/api/v1/${path}`, init);
  return { status: response.status, body: await response.json().catch(() => null), headers: response.headers };
};

// A 1x1 PNG, so the photo path is exercised with a real decoder input.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

const stamp = Date.now();
const keyword = `Integration check ${stamp}`;
const draft = price => ({
  title: `${keyword} ${price}`,
  description: 'Created by the sprint 2 integration check.',
  priceCents: price,
  category: 'Electronics',
  condition: 'Good',
  pickupArea: 'Watson Library',
});

const publish = async price => {
  const created = await call('listings', { method: 'POST', headers: json, body: JSON.stringify(draft(price)) });
  assert.equal(created.status, 201, `publish must succeed, got ${created.status} ${JSON.stringify(created.body)}`);
  assert.ok(created.body.postedAt, 'a published listing must carry its posting date');
  assert.ok(!Number.isNaN(Date.parse(created.body.postedAt)), 'postedAt must parse as a date');
  return created.body;
};

const created = [];
try {
  // Two prices, so ordering is provable even on a database with no seed rows.
  const cheaper = await publish(4242);
  created.push({ listing: cheaper });
  const dearer = await publish(4999);
  created.push({ listing: dearer });

  const form = new FormData();
  form.append('photos[]', new Blob([PNG], { type: 'image/png' }), 'pixel.png');
  const withPhoto = await call(`listings/${cheaper.id}/photos`, { method: 'POST', headers: auth, body: form });
  assert.equal(withPhoto.status, 200, `photo upload must succeed, got ${withPhoto.status}`);
  const primary = withPhoto.body.photoURLs?.[0];
  assert.ok(primary, 'the upload must return a primary photo');
  assert.ok(/^\/?uploads\/listings\//.test(primary), `the photo must be an uploads path, got ${primary}`);
  assert.ok(!/^https?:|^\/\//.test(primary), 'the photo path must not carry a host or scheme');
  created[0].listing = withPhoto.body;

  const parse = response => {
    assert.equal(response.status, 200, `browse must succeed, got ${response.status}`);
    return response.body;
  };

  // Browse exactly as the app does: keyword, filters, page size and order together.
  const asc = parse(await call(
    `listings?q=${encodeURIComponent(keyword)}&per=50&category=Electronics` +
      `&condition=Good&minPriceCents=4000&maxPriceCents=5100&sort=price_asc`,
  ));
  assert.equal(asc.length, 2, 'both listings must match the filter set');
  assert.deepEqual(asc.map(item => item.priceCents), [4242, 4999], 'price_asc must order by price');
  assert.equal(asc[0].photoURLs[0], primary, 'the browse card must carry the uploaded primary photo');

  const desc = parse(await call(
    `listings?q=${encodeURIComponent(keyword)}&per=50&category=Electronics&sort=price_desc`,
  ));
  assert.deepEqual(desc.map(item => item.priceCents), [4999, 4242], 'price_desc must reverse the order');

  const newest = parse(await call(`listings?q=${encodeURIComponent(keyword)}&per=50&sort=newest`));
  assert.equal(newest[0].id, dearer.id, 'newest must lead with the most recently published listing');

  const pageOne = await call(`listings?q=${encodeURIComponent(keyword)}&per=1&page=1`);
  const pageTwo = await call(`listings?q=${encodeURIComponent(keyword)}&per=1&page=2`);
  assert.equal(pageOne.headers.get('x-has-more'), 'true', 'a full first page must report more pages');
  assert.equal(pageOne.body.length, 1, 'page one must hold exactly one row at per=1');
  assert.equal(pageOne.body[0].id, newest[0].id, 'the first page must follow the same order');
  assert.equal(pageTwo.body.length, 1, 'the second page must not come back empty');
  assert.notEqual(pageTwo.body[0].id, pageOne.body[0].id, 'page two must not repeat page one');

  const details = await call(`listings/${cheaper.id}`);
  assert.equal(details.status, 200);
  assert.equal(details.body.postedAt, cheaper.postedAt, 'details must expose the same posting date');
  assert.equal(details.body.photoURLs[0], primary, 'details must carry the same primary photo');

  const owned = await call(`me/listings/${cheaper.id}`, { headers: auth });
  assert.equal(owned.status, 200);
  assert.equal(owned.body.status, 'active');
  assert.equal(typeof owned.body.revision, 'string', 'the owner view must carry an If-Match revision');
  assert.equal(owned.body.editedAt ?? null, null, 'a fresh listing has not been edited');

  const edited = await call(`listings/${cheaper.id}`, {
    method: 'PATCH',
    headers: { ...json, 'If-Match': owned.body.revision },
    body: JSON.stringify({ ...draft(4242), priceCents: 4300 }),
  });
  assert.equal(edited.status, 200, `edit must succeed, got ${edited.status} ${JSON.stringify(edited.body)}`);
  assert.equal(edited.body.listing.postedAt, cheaper.postedAt, 'editing must not move the posting date');
  assert.ok(edited.body.editedAt, 'editing must stamp the last edit');
  assert.equal(typeof edited.body.revision, 'string', 'the edit must return the next If-Match revision');
  assert.notEqual(edited.body.revision, owned.body.revision, 'an edit must rotate the revision');
  created[0].listing = edited.body.listing;

  // The app's optimistic-concurrency branch: a stale revision must be refused.
  const stale = await call(`listings/${cheaper.id}`, {
    method: 'PATCH',
    headers: { ...json, 'If-Match': owned.body.revision },
    body: JSON.stringify(draft(4242)),
  });
  assert.equal(stale.status, 409, `a stale revision must conflict, got ${stale.status}`);
  const afterStale = await call(`listings/${cheaper.id}`);
  assert.equal(afterStale.body.priceCents, 4300, 'a refused edit must not change the listing');

  const sold = await call(`listings/${cheaper.id}/sold`, {
    method: 'POST',
    headers: { ...auth, 'If-Match': edited.body.revision },
  });
  assert.equal(sold.status, 200);
  assert.equal(sold.body.status, 'sold');

  const feedAfterSale = await call(`listings?q=${encodeURIComponent(keyword)}&per=50`);
  assert.ok(!feedAfterSale.body.some(item => item.id === cheaper.id), 'sold listings must leave the public feed');
  assert.equal((await call(`listings/${cheaper.id}`)).status, 404, 'sold listings must not be served publicly');

  const anonymous = await call('me/listings', { headers: { Authorization: 'Bearer not-a-real-session' } });
  assert.equal(anonymous.status, 401, 'an invalid session must be rejected by owner routes');

  const rejectedSort = await call('listings?sort=oldest');
  assert.equal(rejectedSort.status, 422, 'an unknown sort must be rejected');
  assert.ok(rejectedSort.body.fieldErrors?.sort, 'the sort error must name the field');

  const rejectedRange = await call('listings?minPriceCents=5000&maxPriceCents=1000');
  assert.equal(rejectedRange.status, 422, 'an inverted price range must be rejected');
  assert.ok(rejectedRange.body.fieldErrors?.minPriceCents, 'the range error must name the field');

  const removed = await call(`listings/${cheaper.id}`, {
    method: 'DELETE',
    headers: { ...auth, 'If-Match': sold.body.revision },
  });
  assert.equal(removed.status, 200, 'cleanup must remove the check listing');
  assert.equal(removed.body.status, 'deleted');

  console.log('Sprint 2 integration smoke passed: publish, photo, filters, sort, pages, details, edit, conflict, sold, errors, cleanup.');
} finally {
  // Never leave check listings behind, even when an assertion fails.
  for (const entry of created) {
    const id = entry.listing?.id;
    if (!id) continue;
    const current = await call(`me/listings/${id}`, { headers: auth }).catch(() => null);
    if (current?.status === 200 && current.body.status !== 'deleted') {
      await call(`listings/${id}`, {
        method: 'DELETE',
        headers: { ...auth, 'If-Match': current.body.revision },
      }).catch(() => null);
    }
  }
}
