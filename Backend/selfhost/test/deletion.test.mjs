import test from 'node:test';
import assert from 'node:assert/strict';
import { createDeletion } from '../deletion.mjs';

const identity = { id: '11111111-1111-4111-8111-111111111111',
  session_id: '22222222-2222-4222-8222-222222222222', email: 'owner@example.invalid' };
const request = body => new Request('https://bound.example/functions/v1/delete-account', {
  method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
});

test('deletion does not start if the bearer was revoked while waiting for its fence', async () => {
  const statements = []; let checks = 0;
  const client = { query: async sql => { statements.push(sql); return { rows: [] }; }, release() {} };
  const deletion = createDeletion({ pool: { query: async () => ({ rows: [] }), connect: async () => client },
    auth: { authenticate: async () => { if (++checks === 2) throw Error('revoked'); return identity; }, deleteAccount: async () => assert.fail('must not delete') },
    files: { purgeOwner: async () => assert.fail('must not purge') } });
  const response = await deletion.handle(request({ operationToken: 'a'.repeat(64), confirmationEmail: identity.email }));
  assert.equal(response.status, 401);
  assert.equal(checks, 2);
  assert.ok(statements.includes('ROLLBACK'));
  assert.equal(statements.some(sql => sql.startsWith('INSERT')), false);
});

test('malformed deletion JSON is rejected before database access', async () => {
  const deletion = createDeletion({ pool: { query: async () => assert.fail('unexpected database call') }, auth: {}, files: {} });
  assert.equal((await deletion.handle(request(null))).status, 400);
});
