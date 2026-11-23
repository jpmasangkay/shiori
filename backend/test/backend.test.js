import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import jwt from 'jsonwebtoken';

const TEST_SECRET = 'test-super-secret-jwt-key-at-least-32-chars!!';

// Set env before importing app/config
process.env.JWT_SECRET = TEST_SECRET;
process.env.CORS_ORIGIN = 'https://shiori.app,http://localhost:8080';

const { assertConfig, getJwtSecret } = await import('../src/config.js');
const { createApp } = await import('../src/index.js');
const { sanitizeType } = await import('../src/routes/library.js');

function startTestServer() {
  const app = createApp();
  return new Promise((resolve) => {
    const server = http.createServer(app);
    server.listen(0, '127.0.0.1', () => {
      const addr = server.address();
      resolve({ server, baseUrl: `http://127.0.0.1:${addr.port}` });
    });
  });
}

test('assertConfig fails fast on missing or weak JWT_SECRET and succeeds with strong secret', () => {
  const original = process.env.JWT_SECRET;
  try {
    process.env.JWT_SECRET = '';
    assert.throws(() => assertConfig(), /JWT_SECRET/);
    assert.throws(() => getJwtSecret(), /JWT_SECRET/);

    process.env.JWT_SECRET = 'dev-fallback-secret';
    assert.throws(() => getJwtSecret(), /JWT_SECRET/);

    process.env.JWT_SECRET = 'change-me-to-something';
    assert.throws(() => assertConfig(), /JWT_SECRET/);

    process.env.JWT_SECRET = TEST_SECRET;
    assert.doesNotThrow(() => assertConfig());
    assert.equal(getJwtSecret(), TEST_SECRET);
  } finally {
    process.env.JWT_SECRET = original;
  }
});

test('sanitizeType rejects NoSQL injection objects and invalid strings', () => {
  assert.equal(sanitizeType('manhwa'), 'manhwa');
  assert.equal(sanitizeType('MANHUA'), 'manhua');
  assert.equal(sanitizeType({ $ne: 'manga' }), 'manga');
  assert.equal(sanitizeType(['manga']), 'manga');
  assert.equal(sanitizeType('invalid'), 'manga');
});

test('Health, CORS enforcement, auth rejection, NoSQL query guard, and slash-ID routes', async () => {
  const { server, baseUrl } = await startTestServer();
  try {
    // 1. Health endpoint
    const healthRes = await fetch(`${baseUrl}/api/health`);
    assert.equal(healthRes.status, 200);
    const healthBody = await healthRes.json();
    assert.equal(healthBody.status, 'ok');
    assert.ok('mongo' in healthBody);

    // 2. CORS allows configured origin and blocks unlisted origin
    const okCors = await fetch(`${baseUrl}/api/health`, {
      headers: { Origin: 'https://shiori.app' },
    });
    assert.equal(okCors.headers.get('access-control-allow-origin'), 'https://shiori.app');

    const blockedCors = await fetch(`${baseUrl}/api/health`, {
      headers: { Origin: 'https://evil.example.com' },
    });
    assert.equal(blockedCors.headers.get('access-control-allow-origin'), null);

    // 3. Protected routes reject missing token and reject tokens signed with legacy dev-fallback-secret
    const unauth = await fetch(`${baseUrl}/api/library`);
    assert.equal(unauth.status, 401);

    const forgedFallbackToken = jwt.sign({ id: 'u1', email: 'a@b.com' }, 'dev-fallback-secret');
    const forgedRes = await fetch(`${baseUrl}/api/library`, {
      headers: { Authorization: `Bearer ${forgedFallbackToken}` },
    });
    assert.equal(forgedRes.status, 401);

    // 4. Library GET rejects NoSQL object query parameter (?type[$ne]=manga)
    const validToken = jwt.sign({ id: '507f1f77bcf86cd799439011', email: 'test@shiori.app' }, TEST_SECRET);
    const nosqlRes = await fetch(`${baseUrl}/api/library?type[$ne]=manga`, {
      headers: { Authorization: `Bearer ${validToken}` },
    });
    assert.equal(nosqlRes.status, 400);

    // 5. Wildcard progress route matches slash-containing ext: mangaId (does NOT 404!)
    const slashRes = await fetch(
      `${baseUrl}/api/progress/manga/ext:eu.kanade.tachiyomi.extension.en.asura:/series/solo-leveling`,
      {
        headers: { Authorization: `Bearer ${validToken}` },
      },
    );
    // Route matched (not 404); without MongoDB it returns 500 rather than 404 Endpoint not found
    assert.notEqual(slashRes.status, 404);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
