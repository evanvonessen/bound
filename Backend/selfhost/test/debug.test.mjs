import test from 'node:test';import assert from 'node:assert/strict';import {createHmac,createHash} from 'node:crypto';import {mkdtemp,readFile,readdir,stat} from 'node:fs/promises';import {join} from 'node:path';import {tmpdir} from 'node:os';
import {createDebug,canonical} from '../debug.mjs';import {configuration} from '../config.mjs';import {localFixtureDelivery} from '../local-fixture.mjs';
const owner='11111111-1111-4111-8111-111111111111',peer='22222222-2222-4222-8222-222222222222',session='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',secret='synthetic-local-debug-secret-123456789';
const base={HOST:'127.0.0.1',PUBLIC_URL:'https://127.0.0.1:58552',NAKAMA_HTTP_URL:'http://127.0.0.1:58550',DATABASE_URL:'postgresql://synthetic@127.0.0.1:58532/task',NAKAMA_SERVER_KEY:'synthetic',NAKAMA_HTTP_KEY:'synthetic',BOUND_GATEWAY_SECRET:secret,BOUND_NAKAMA_BRIDGE_SECRET:secret,BOUND_AUTH_ENCRYPTION_KEY:Buffer.alloc(32).toString('base64'),BOUND_DEBUG_MODE:'local',BOUND_DEBUG_GATEWAY_SECRET:secret,BOUND_DEBUG_ALLOWED_OWNERS:owner+','+peer};
const request=(body,headers={})=>new Request(base.PUBLIC_URL+'/functions/v1/bound-debug',{method:'POST',headers:{'content-type':'application/json',authorization:'Bearer synthetic',...headers},body:JSON.stringify(body)});
function fixture(override={}){const calls=[],identity={ownerID:owner,nakamaUserID:owner,sessionID:session,nakamaToken:'synthetic-token',record:{version:'v1',value:{accessHash:'1'.repeat(64)}}};let count=0;
const gateway=createDebug({config:{...base,...override},authenticate:async()=>{count++;return identity;},rpc:async()=>({roomID:session,ownerID:owner,members:[owner,peer]}),nakama:{debug:async proof=>{calls.push(proof);return {session:{sessionID:session,membershipEpoch:1,owners:[owner,peer]},realtime:{matchID:'match',roomID:session,protocol:'bound-debug-room-v1',ticket:'synthetic-ticket',expiresAt:123}};}}});return {gateway,calls,identity,count:()=>count};}
test('local DEBUG configuration rejects remote services and never enables by default',()=>{
  assert.equal(configuration(base).BOUND_DEBUG_MODE,'local');for(const fields of [{HOST:'0.0.0.0'},{PUBLIC_URL:'https://accounts.example.com'},{NAKAMA_HTTP_URL:'https://game.example.com'},{DATABASE_URL:'postgresql://synthetic@database.example.com/task'},{BOUND_DEBUG_MODE:'true'}])assert.throws(()=>configuration({...base,...fields}));
  assert.throws(()=>configuration({...base,BOUND_DEBUG_MODE:undefined,BOUND_LOCAL_EMAIL_CAPTURE:'true'}));
});
test('DEBUG gateway revalidates auth and signs exact server-owned identity and friend-room result',async()=>{
  const f=fixture(),input={action:'create',sessionID:session,roomID:session};assert.equal((await f.gateway.handle(request(input))).status,200);assert.equal(f.count(),2);
  const proof=f.calls[0];assert.equal(proof.authorization.ownerID,owner);assert.equal(proof.authorization.requestSHA256,createHash('sha256').update(canonical({request:input,room:proof.room})).digest('hex'));assert.equal(proof.signature,createHmac('sha256',secret).update(canonical(proof.authorization)).digest('hex'));
});
test('disabled, outsider, cross-origin, malformed and oversized DEBUG HTTP cannot dispatch',async()=>{
  for(const [override,headers,status]of[[{BOUND_DEBUG_MODE:undefined},{},404],[{BOUND_DEBUG_ALLOWED_OWNERS:peer},{},403],[{},{origin:'https://external.invalid'},403]]){const f=fixture(override);assert.equal((await f.gateway.handle(request({action:'status'},headers))).status,status);assert.equal(f.calls.length,0);}
  const f=fixture();assert.equal((await f.gateway.handle(request({action:'status',padding:'x'.repeat(70000)}))).status,400);assert.equal(f.calls.length,0);
});
test('realtime response uses existing verified native bearer and server match without ordinary broker fallback',async()=>{
  const f=fixture(),r=await f.gateway.handle(request({action:'realtime',generation:1,sessionID:session})),body=await r.json();assert.equal(r.status,200);assert.equal(body.realtime.accessToken,'synthetic-token');assert.equal(body.realtime.joinTicket,'synthetic-ticket');assert.equal(body.realtime.ticket,undefined);assert.equal(body.realtime.endpoint,'wss://127.0.0.1:58552/ws?format=json&status=false');assert.equal(body.realtime.ownerID,owner);assert.equal(body.realtime.peerOwnerID,peer);
});
test('fixture email delivery only captures synthetic recipients with private files and no confirmation bypass',async()=>{
  const temp=process.env.TMPDIR??tmpdir();const root=await mkdtemp(join(temp,'debug-email-')),send=await localFixtureDelivery({...base,BOUND_LOCAL_EMAIL_CAPTURE:'true',BOUND_LOCAL_FIXTURE_ROOT:root});
  const mail={to:['player@bound-debug.invalid'],subject:'Verify',text:'unchanged one-use challenge'};await send('https://api.resend.com/emails',{method:'POST',body:JSON.stringify(mail)});const names=await readdir(join(root,'email'));assert.equal(names.length,1);const p=join(root,'email',names[0]);assert.deepEqual(JSON.parse(await readFile(p)),mail);assert.equal((await stat(p)).mode&0o777,0o600);
  await assert.rejects(send('https://api.resend.com/emails',{method:'POST',body:JSON.stringify({...mail,to:['real@example.com']})}));await assert.rejects(send('https://external.invalid',{method:'POST',body:JSON.stringify(mail)}));
});
