// Negative-path checks safe to run against a blank or existing development DB.
import assert from 'node:assert/strict';
const host = process.env.API_URL ?? 'http://localhost:8080';
const post = (path, body) => fetch(`${host}/api/v1/auth/${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
let r = await post('register', { displayName: 'Test', email: 'notku@example.org', password: 'passwordlong123', passwordConfirmation: 'passwordlong123' });
assert.equal(r.status, 400, 'non-KU email must be rejected');
r = await post('register', { displayName: 'Test', email: 'demo@ku.edu', password: 'passwordlong123', passwordConfirmation: 'mismatch123' });
assert.equal(r.status, 400, 'mismatched passwords must be rejected');
r = await post('login', { email: 'notku@example.org', password: 'anything' });
assert.equal(r.status, 401, 'invalid credentials must be rejected');
r = await fetch(`${host}/api/v1/auth/me`);
assert.equal(r.status, 401, 'protected profile must reject anonymous requests');
r = await post('logout', {});
assert.equal(r.status, 401, 'logout must reject anonymous requests');
console.log('Auth negative-path smoke checks passed.');
