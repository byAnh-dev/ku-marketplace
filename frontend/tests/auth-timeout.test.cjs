const assert = require('node:assert/strict');
const http = require('node:http');
const path = require('node:path');
const { test } = require('node:test');
const { createAppLoader } = require('./load-app.cjs');

test('the account deadline covers stalled headers and JSON bodies without deleting a saved session', async () => {
  const received = new Set();
  const server = http.createServer((request, response) => {
    received.add(request.url);
    if (request.url.endsWith('/me')) {
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.write('{"id":');
    }
    // Login receives no headers. Profile receives headers but an incomplete body.
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const apiBase = `http://127.0.0.1:${server.address().port}`;
  const storedToken = 'fictional-test-session'.repeat(4);
  let storageWrites = 0;
  let storageDeletes = 0;
  const load = createAppLoader({
    modules: {
      'react-native': { Platform: { OS: 'ios' } },
      'expo-secure-store': {
        getItemAsync: async () => storedToken,
        setItemAsync: async () => { storageWrites += 1; },
        deleteItemAsync: async () => { storageDeletes += 1; },
      },
    },
    globals: { process: { env: { EXPO_PUBLIC_API_URL: apiBase } } },
  });
  const auth = load(path.resolve(__dirname, '../src/auth.ts'));

  // Run the real 15-second deadline and real fetch against a local HTTP server.
  // Only device storage and the API base URL are substituted.
  let watchdog;
  try {
    const checks = Promise.all([
      assert.rejects(auth.login('fictional@ku.edu', 'fictional-password'), /Could not reach the account service/),
      assert.rejects(auth.restoreSession(), /Could not reach the account service/),
    ]);
    await Promise.race([
      checks,
      new Promise((_, reject) => {
        watchdog = setTimeout(() => reject(new Error('Account calls exceeded their request deadline.')), 20000);
      }),
    ]);
    assert.deepEqual([...received].sort(), ['/api/v1/auth/login', '/api/v1/auth/me']);
    assert.equal(storageWrites, 0);
    assert.equal(storageDeletes, 0);
  } finally {
    clearTimeout(watchdog);
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});
