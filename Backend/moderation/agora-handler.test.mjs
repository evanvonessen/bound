import test from 'node:test';
import assert from 'node:assert/strict';
import {createTokenHandler} from './agora-handler.mjs';
const owner='11111111-1111-4111-8111-111111111111';
const room='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const json=(body,status=200)=>new Response(JSON.stringify(body),{status});
function fixture({deny=false,deleted=false,staticRoom=false}={}) {
 const calls=[];let signed=0;
 const handler=createTokenHandler({appID:'a'.repeat(32),certificate:'b'.repeat(32),publishableKey:'synthetic-public',rooms:staticRoom?{legacy:{channel:'legacy',members:[{ownerID:owner,uid:1},{ownerID:'22222222-2222-4222-8222-222222222222',uid:2}]}}:{},now:()=>1000,
 sign:args=>{signed++;assert.equal(args.ttl,60);return 'synthetic-rtc-token';},fetchImpl:async(url,options)=>{
  calls.push(url);assert.equal(options.headers.Authorization,'Bearer synthetic.valid.session');
  if(url.endsWith('/auth/v1/user'))return json({id:owner,is_anonymous:false,role:'authenticated',email_confirmed_at:'2026-01-01T00:00:00Z'},deleted?401:200);
  if(url.endsWith('/cup117_account_active'))return json(true);
  if(url.endsWith('/cup050_friends')) {
   assert.deepEqual(JSON.parse(options.body),{action:'room',payload:{roomID:room}});
   return json(deny?{ok:false}:{ok:true,room:{roomID:room,channel:'cup050_'+room.replaceAll('-',''),uid:1,remoteUID:2}});
  }
  throw Error('unexpected endpoint');
 }});
 return {calls,signed:()=>signed,request:()=>handler(new Request('https://fixture.invalid/agora-token',{method:'POST',headers:{Authorization:'Bearer synthetic.valid.session','Content-Type':'application/json'},body:JSON.stringify({roomID:staticRoom?'legacy':room})}))};
}
test('allowed dynamic room gets a 60-second lease after checked membership',async()=>{
 const f=fixture();const r=await f.request();assert.equal(r.status,200);const value=await r.json();assert.equal(value.expiresAt-value.issuedAt,60);assert.equal(f.signed(),1);assert.equal(f.calls.length,3);
});
test('blocked or suspended dynamic room cannot issue or renew a token, including old client request',async()=>{
 const f=fixture({deny:true});assert.equal((await f.request()).status,403);assert.equal(f.signed(),0);
});
test('deleted or revoked Auth identity is denied before membership and signing',async()=>{
 const f=fixture({deleted:true});assert.equal((await f.request()).status,401);assert.equal(f.signed(),0);assert.equal(f.calls.length,1);
});
test('legacy static configuration cannot bypass moderation gates',async()=>{
 const f=fixture({staticRoom:true});assert.equal((await f.request()).status,403);assert.equal(f.signed(),0);
});

const lobby='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const memberToken='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const lobbyMembers=Array.from({length:4},(_,i)=>({ownerID:i===0?owner:`${i+2}`.repeat(8)+'-'+`${i+2}`.repeat(4)+'-4'+`${i+2}`.repeat(3)+'-8'+`${i+2}`.repeat(3)+'-'+`${i+2}`.repeat(12),uid:i+1,sessionID:`${i+5}`.repeat(8)+'-'+`${i+5}`.repeat(4)+'-4'+`${i+5}`.repeat(3)+'-8'+`${i+5}`.repeat(3)+'-'+`${i+5}`.repeat(12),generation:'1'}));
function lobbyFixture({mutate=x=>x,deny=false,unavailable=false,expectedTTL=60}={}){
 let signed=0;const calls=[];
 const handler=createTokenHandler({appID:'a'.repeat(32),certificate:'b'.repeat(32),publishableKey:'synthetic-public',rooms:{},now:()=>1000,
 sign:args=>{signed++;assert.equal(args.ttl,expectedTTL);assert.equal(args.channel,'bound_lobby_'+lobby.replaceAll('-',''));assert.equal(args.uid,1);return 'synthetic-lobby-token';},
 fetchImpl:async(url,options)=>{
  calls.push(url);assert.equal(options.headers.Authorization,'Bearer synthetic.valid.session');
  if(url.endsWith('/auth/v1/user'))return json({id:owner,is_anonymous:false,role:'authenticated',email_confirmed_at:'2026-01-01T00:00:00Z'});
  if(url.endsWith('/cup117_account_active'))return json(true);
  if(url.endsWith('/bound_lobby_v1')){
   assert.deepEqual(JSON.parse(options.body),{action:'room',payload:{lobbyID:lobby,memberToken}});
   if(unavailable)throw Error('offline');
   const room=mutate({lobbyID:lobby,channel:'bound_lobby_'+lobby.replaceAll('-',''),uid:1,membershipRevision:'9',serverTime:1000,expiresAt:1090,members:structuredClone(lobbyMembers),partnerOwnerID:lobbyMembers[2].ownerID});
   return json(deny?{ok:false,error:'fenced'}:{ok:true,room});
  }throw Error('unexpected endpoint');
 }});
 return {calls,signed:()=>signed,request:(body={lobbyID:lobby,memberToken})=>handler(new Request('https://fixture.invalid/agora-token',{method:'POST',headers:{Authorization:'Bearer synthetic.valid.session','Content-Type':'application/json'},body:JSON.stringify(body)}))};
}
test('four-player token binds authenticated owner, stable UIDs, public membership sessions and paired partner',async()=>{
 const f=lobbyFixture();const r=await f.request();assert.equal(r.status,200);const value=await r.json();
 assert.equal(value.roomID,lobby);assert.equal(value.lobbyID,lobby);assert.equal(value.remoteUID,3);assert.equal(value.uid,1);assert.equal(value.members.length,4);
 assert.equal(value.membershipRevision,'9');assert.equal(value.expiresAt-value.issuedAt,60);assert.equal(f.signed(),1);assert.ok(!JSON.stringify(value).includes(memberToken));
});
test('lobby lease permits one remaining member and uses remote UID zero',async()=>{
 const f=lobbyFixture({mutate:r=>({...r,members:r.members.slice(0,1)})});const response=await f.request();assert.equal(response.status,200);assert.equal((await response.json()).remoteUID,0);
});
test('stale, departed, blocked or declined lobby members cannot renew tokens',async()=>{
 const f=lobbyFixture({deny:true});assert.equal((await f.request()).status,403);assert.equal(f.signed(),0);
});
test('lobby membership failure is fail-closed and distinct from denial',async()=>{
 const f=lobbyFixture({unavailable:true});assert.equal((await f.request()).status,503);assert.equal(f.signed(),0);
});
for(const [label,mutate] of [
 ['duplicate UID',r=>({...r,members:r.members.map((m,i)=>({...m,uid:i===1?1:m.uid}))})],
 ['duplicate owner',r=>({...r,members:r.members.map((m,i)=>({...m,ownerID:i===1?owner:m.ownerID}))})],
 ['duplicate session',r=>({...r,members:r.members.map((m,i)=>({...m,sessionID:i===1?r.members[0].sessionID:m.sessionID}))})],
 ['wrong local UID',r=>({...r,uid:2})],
 ['missing local owner',r=>({...r,members:r.members.slice(1)})],
 ['wrong lobby',r=>({...r,lobbyID:room})],
 ['wrong channel',r=>({...r,channel:'cup050_'+room.replaceAll('-','')})],
 ['fifth player',r=>({...r,members:[...r.members,{...r.members[0],uid:5}]})],
 ['missing session',r=>({...r,members:r.members.map(m=>({...m,sessionID:undefined}))})],
 ['invalid generation',r=>({...r,members:r.members.map(m=>({...m,generation:'0'}))})],
 ['invalid revision',r=>({...r,membershipRevision:'0'})],
])test(`lobby token rejects ${label} from authorization response`,async()=>{
 const f=lobbyFixture({mutate});assert.equal((await f.request()).status,403);assert.equal(f.signed(),0);
});
test('lobby client cannot supply UID, owner or mix paired-room and group credentials',async()=>{
 for(const extra of [{uid:4},{ownerID:owner},{roomID:room}]){const f=lobbyFixture();assert.equal((await f.request({lobbyID:lobby,memberToken,...extra})).status,400);assert.equal(f.calls.length,0);}
});

test('lobby token never outlives the remaining server membership',async()=>{
 const f=lobbyFixture({mutate:r=>({...r,expiresAt:1045}),expectedTTL:43});const response=await f.request();assert.equal(response.status,200);const body=await response.json();assert.equal(body.expiresAt-body.issuedAt,43);
 const stale=lobbyFixture({mutate:r=>({...r,expiresAt:1030})});assert.equal((await stale.request()).status,403);assert.equal(stale.signed(),0);
});
