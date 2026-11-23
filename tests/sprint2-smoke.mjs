// End-to-end integration check for the mobile contract: publish, photo, browse
// with filters and sort, open details, edit, mark sold, and the error shapes the
// app renders. Needs a verified account's session token; skips without one.
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
  const body = await response.json().catch(() => null);
  return { status: response.status, body };
};

// A 1x1 PNG, so the photo path is exercised with a real decoder input.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

const stamp = Date.now();
const title = `Integration check ${stamp}`;
const draft = {
  title,
  description: 'Created by the sprint 2 integration check.',
  priceCents: 4242,
  category: 'Electronics',
  condition: 'Good',
  pickupArea: 'Watson Library',
};

const created = await call('listings', { method: 'POST', headers: json, body: JSON.stringify(draft) });
assert.equal(created.status, 201, `publish must succeed, got ${created.status} ${JSON.stringify(created.body)}`);
const listing = created.body;
assert.equal(listing.title, title);
assert.ok(listing.postedAt, 'a published listing must carry its posting date');
assert.ok(!Number.isNaN(Date.parse(listing.postedAt)), 'postedAt must parse as a date');

const form = new FormData();
form.append('photos[]', new Blob([PNG], { type: 'image/png' }), 'pixel.png');
const withPhoto = await call(`listings/${listing.id}/photos`, { method: 'POST', headers: auth, body: form });
assert.equal(withPhoto.status, 200, `photo upload must succeed, got ${withPhoto.status}`);
const primary = withPhoto.body.photoURLs?.[0];
assert.ok(primary && !/^https?:/.test(primary) && !primary.includes('@'), 'primary photo must be a relative path without credentials');

// Browse exactly as the app does: keyword, filters, page size and order together.
const browse = await call(
  `listings?q=${encodeURIComponent('integration check')}&per=50&category=Electronics` +
    `&condition=Good&minPriceCents=4000&maxPriceCents=4400&sort=price_asc`,
);
assert.equal(browse.status, 200);
const feed = browse.body;
const mine = feed.find(item => item.id === listing.id);
assert.ok(mine, 'the new listing must appear under its own category, condition and price range');
assert.equal(mine.priceCents, 4242);
for (let i = 1; i < feed.length; i += 1) {
  assert.ok(feed[i - 1].priceCents <= feed[i].priceCents, 'price_asc must be ordered');
}

const details = await call(`listings/${listing.id}`);
assert.equal(details.status, 200);
assert.equal(details.body.postedAt, listing.postedAt, 'details must expose the same posting date');

const owned = await call(`me/listings/${listing.id}`, { headers: auth });
assert.equal(owned.status, 200);
assert.equal(owned.body.status, 'active');
assert.equal(owned.body.editedAt ?? null, null, 'a fresh listing has not been edited');

const edited = await call(`listings/${listing.id}`, {
  method: 'PATCH',
  headers: { ...json, 'If-Match': owned.body.revision },
  body: JSON.stringify({ ...draft, priceCents: 4300 }),
});
assert.equal(edited.status, 200, `edit must succeed, got ${edited.status} ${JSON.stringify(edited.body)}`);
assert.equal(edited.body.listing.postedAt, listing.postedAt, 'editing must not move the posting date');
assert.ok(edited.body.editedAt, 'editing must stamp the last edit');

const sold = await call(`listings/${listing.id}/sold`, {
  method: 'POST',
  headers: { ...auth, 'If-Match': edited.body.revision },
});
assert.equal(sold.status, 200);
assert.equal(sold.body.status, 'sold');

const feedAfterSale = await call('listings?per=50&category=Electronics&sort=price_asc');
assert.ok(!feedAfterSale.body.some(item => item.id === listing.id), 'sold listings must leave the public feed');
const publicDetails = await call(`listings/${listing.id}`);
assert.equal(publicDetails.status, 404, 'sold listings must not be served publicly');

const rejectedSort = await call('listings?sort=oldest');
assert.equal(rejectedSort.status, 422, 'an unknown sort must be rejected');
assert.ok(rejectedSort.body.fieldErrors?.sort, 'the sort error must name the field');

const rejectedRange = await call('listings?minPriceCents=5000&maxPriceCents=1000');
assert.equal(rejectedRange.status, 422, 'an inverted price range must be rejected');
assert.ok(rejectedRange.body.fieldErrors?.minPriceCents, 'the range error must name the field');

const removed = await call(`listings/${listing.id}`, {
  method: 'DELETE',
  headers: { ...auth, 'If-Match': sold.body.revision },
});
assert.equal(removed.status, 200, 'cleanup must remove the check listing');
assert.equal(removed.body.status, 'deleted');

console.log('Sprint 2 integration smoke passed: publish, photo, browse, details, edit, sold, errors, cleanup.');
