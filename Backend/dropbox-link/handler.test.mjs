import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { createDropboxHandler, createGrantCipher } from './handler.mjs';
const owner = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const session = '33333333-3333-4333-8333-333333333333';
const appKey = 'fixtureappkey1234';
const encryptionKey = Buffer.alloc(32, 7).toString('base64');
const jwt = `header.${Buffer.from(JSON.stringify({sub:owner,session_id:session})).toString('base64url')}.signature`;
const response = (value, status = 200) => new Response(JSON.stringify(value), {status});
const cipher = () => createGrantCipher(encryptionKey, appKey, webcrypto);
const request = (body, headers = {}) => new Request('https://fixture.invalid', {method:'POST',
  headers:{'Content-Type':'application/json',Authorization:`Bearer ${jwt}`,...headers},body:JSON.stringify(body)});
function fixture(options = {}) {
  const calls = []; let stored = options.ciphertext ?? null; let revision = session; let counter = 0;
  const fetchImpl = async (url, init) => {
    calls.push({url,init});
    if (url.endsWith('/auth/v1/user')) return response({id:owner,role:'authenticated',is_anonymous:false,email_confirmed_at:'2026-01-01',...options.user}, options.authStatus ?? 200);
    if (url.includes('/rpc/')) {
      const {action,payload} = JSON.parse(init.body);
      assert.equal(payload.owner,owner); assert.equal(payload.session,session);
      if (options.rpcError) return response({error:options.rpcError});
      if (action === 'snapshot') return response({revision,ciphertext:stored});
      if (options.conflict || payload.revision !== revision) return response({error:'connection_changed'});
      if (action === 'store') { stored = payload.ciphertext; revision = other; return response({ok:true,revision}); }
      if (action === 'validate') return response({ok:true});
      if (action === 'unlink' || action === 'invalidate') { const old = stored; stored = null; revision = other; return response({ok:true,ciphertext:old}); }
      assert.fail('unexpected RPC');
    }
    if (url.endsWith('/oauth2/token')) {
      counter++;
      if (options.networkFailure) throw Error('SECRET-UPSTREAM-DIAGNOSTIC');
      if (options.invalidGrant) return response({error:'invalid_grant'},400);
      if (options.serverFailure) return response({error:'invalid_grant'},500);
      const form = new URLSearchParams(init.body);
      assert.equal(form.get('client_id'),appKey);
      if (form.get('grant_type') === 'authorization_code') {
        assert.equal(form.get('redirect_uri'),`db-${appKey}://2/token`);
        return response({access_token:'short-lived',refresh_token:'long-lived-secret',expires_in:14400});
      }
      assert.equal(form.get('refresh_token'),'long-lived-secret');
      return response({access_token:'short-lived',expires_in:14400});
    }
    if (url.endsWith('/auth/token/revoke')) return response({});
    assert.fail(url);
  };
  const handler = createDropboxHandler({serviceKey:'server-only',publishableKey:'public',appKey,encryptionKey,fetchImpl,cryptoImpl:webcrypto});
  return {handler,calls,stored:()=>stored,tokenCalls:()=>counter};
}

test('AES-GCM hides plaintext and rejects different owner, app, key and tampering', async () => {
  const sealed = await cipher().seal(owner,'long-lived-secret');
  assert.equal(sealed.includes('long-lived-secret'),false);
  assert.equal(await cipher().open(owner,sealed),'long-lived-secret');
  await assert.rejects(cipher().open(other,sealed));
  await assert.rejects(createGrantCipher(encryptionKey,'differentapp',webcrypto).open(owner,sealed));
  await assert.rejects(createGrantCipher(Buffer.alloc(32,8).toString('base64'),appKey,webcrypto).open(owner,sealed));
  const value = JSON.parse(sealed); value.data = value.data.slice(0,-4) + 'AAAA';
  await assert.rejects(cipher().open(owner,JSON.stringify(value)));
});
test('link stores encrypted grant and only returns expiring access token', async () => {
  const f = fixture(); const result = await f.handler(request({action:'link',code:'fixture-code',verifier:'v'.repeat(43)}));
  assert.equal(result.status,200); assert.deepEqual(await result.json(),{accessToken:'short-lived',expiresIn:14400,connectionID:other});
  assert.equal(await cipher().open(owner,f.stored()),'long-lived-secret');
  assert.equal(f.stored().includes('long-lived-secret'),false);
});
test('another device obtains access without Dropbox authorization code', async () => {
  const f = fixture({ciphertext:await cipher().seal(owner,'long-lived-secret')});
  const result = await f.handler(request({action:'token'}));
  assert.equal(result.status,200); assert.equal(f.tokenCalls(),1);
  const actions = f.calls.filter(x=>x.url.includes('/rpc/')).map(x=>JSON.parse(x.init.body).action);
  assert.deepEqual(actions,['snapshot','validate']);
});
test('unlinked accounts never contact Dropbox', async () => {
  const f = fixture(); const result = await f.handler(request({action:'token'}));
  assert.equal(result.status,404); assert.equal(f.tokenCalls(),0);
});
for (const body of [{action:'token',owner:other},{action:'link',code:'x',verifier:'short'},{action:'unlink',refreshToken:'secret'},{action:'unknown'}]) {
  test(`rejects unexpected input ${Object.keys(body).join(',')} ${body.action}`,async()=>{
    const f = fixture(); assert.equal((await f.handler(request(body))).status,400); assert.equal(f.calls.length,0);
  });
}
for (const options of [{user:{id:other}},{user:{is_anonymous:true}},{user:{email_confirmed_at:null}},{authStatus:401}]) {
  test(`identity validation rejects ${JSON.stringify(options)}`,async()=>{
    const f=fixture(options); assert.ok((await f.handler(request({action:'token'}))).status>=400);
    assert.equal(f.calls.length,1);
  });
}
for (const rpcError of ['unauthorized','rate_limited']) {
  test(`database rejects revoked/deleting/rate limited owner: ${rpcError}`,async()=>{
    const f=fixture({rpcError}); assert.equal((await f.handler(request({action:'token'}))).status,rpcError==='unauthorized'?401:429);
    assert.equal(f.tokenCalls(),0);
  });
}
test('unlink clears the grant even when Dropbox cannot revoke it',async()=>{
  const f=fixture({ciphertext:await cipher().seal(owner,'long-lived-secret'),networkFailure:true});
  assert.equal((await f.handler(request({action:'unlink'}))).status,200); assert.equal(f.stored(),null);
});
test('concurrent unlink/account deletion prevents token delivery after refresh',async()=>{
  const f=fixture({ciphertext:await cipher().seal(owner,'long-lived-secret'),conflict:true});
  const result=await f.handler(request({action:'token'})); assert.equal(result.status,409);
  assert.equal((await result.text()).includes('short-lived'),false);
});
test('rejected refresh credential is removed but service/network failures preserve it',async()=>{
  for(const flag of ['invalidGrant','serverFailure','networkFailure']) {
    const sealed=await cipher().seal(owner,'long-lived-secret'); const f=fixture({ciphertext:sealed,[flag]:true});
    const result=await f.handler(request({action:'token'}));
    assert.equal(result.status,flag==='invalidGrant'?409:503);
    assert.equal(f.stored(),flag==='invalidGrant'?null:sealed);
    assert.equal((await result.text()).includes('SECRET'),false);
  }
});
test('ciphertext from another owner cannot be used',async()=>{
  const f=fixture({ciphertext:await cipher().seal(other,'long-lived-secret')});
  assert.equal((await f.handler(request({action:'token'}))).status,503); assert.equal(f.tokenCalls(),0);
});
test('browser origins, missing auth and oversized input fail closed',async()=>{
  const f=fixture();
  assert.equal((await f.handler(request({action:'token'},{Origin:'https://evil.invalid'}))).status,403);
  assert.equal((await f.handler(request({action:'token'},{Authorization:''}))).status,401);
  assert.equal((await f.handler(request({action:'token',extra:'x'.repeat(5000)}))).status,400);
  assert.equal(f.calls.length,0);
});
test('missing configuration fails closed',async()=>{
  const handler=createDropboxHandler({}); assert.equal((await handler(request({action:'token'}))).status,503);
});


test('MFA enrolled user cannot obtain or link Dropbox using AAL1',async()=>{
  const f=fixture({user:{factors:[{status:'verified',factor_type:'totp'}]}});
  assert.equal((await f.handler(request({action:'token'}))).status,403);
  assert.equal(f.tokenCalls(),0);
});

test('MFA enrolled AAL2 caller can obtain its linked token',async()=>{
  const f=fixture({user:{factors:[{status:'verified',factor_type:'totp'}]},ciphertext:await cipher().seal(owner,'long-lived-secret')});
  const token=`header.${Buffer.from(JSON.stringify({sub:owner,session_id:session,aal:'aal2'})).toString('base64url')}.signature`;
  assert.equal((await f.handler(request({action:'token'},{Authorization:`Bearer ${token}`}))).status,200);
});
