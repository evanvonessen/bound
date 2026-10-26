import test from 'node:test';
import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {secret} from './fixture.mjs';
import { debugFixture,owner,peer,third,sid,roomID,operationID,plain,hash } from './debug-fixture.mjs';

function committed(h){h.pair();const op=h.prepare().operation,a=h.upload(op,owner),b=h.upload(op,peer);const reply=h.mutate(owner,'commit',{operationID:op.operationID,generation:op.generation});return {op:reply.operation,manifest:reply.manifest,a,b};}
function captureComplete(h,op){for(const who of [owner,peer])h.mutate(who,'captureComplete',{operationID:op.operationID,generation:op.generation,payloadSHA256:h.rpc(who,'status',{operationID:op.operationID}).own.descriptor.receipt.payloadSHA256,cutDigest:op.cut.digest});}
function verify(h,op,manifest,who,p,extra={}){const d=p.descriptor;return h.mutate(who,'verify',{operationID:op.operationID,generation:op.generation,manifestDigest:manifest.digest,deviceID:d.deviceID,ownershipEpoch:d.ownershipEpoch,payloadSHA256:d.receipt.payloadSHA256,checkpoint:d.receipt.checkpoint,trainerID:d.trainer.id,soulDigest:d.soulDigest,applied:d.applied,nativeVerified:true,...extra});}
test('DEBUG is disabled by default, private gateway-only, and independently owner allowlisted',()=>{
  const h=debugFixture();delete h.f.ctx.env.BOUND_DEBUG_MODE;assert.throws(()=>h.rpc(owner,'create',{roomID}));
  h.f.ctx.env.BOUND_DEBUG_MODE='local';h.f.ctx.userId=owner;assert.throws(()=>h.rpc(owner,'create',{roomID}));delete h.f.ctx.userId;
  assert.throws(()=>h.rpc(third,'create',{roomID}));assert.throws(()=>h.rpc(owner,'create',{roomID},{signature:'0'.repeat(64)}));
  assert.equal(h.snapshot().filter(r=>r.collection==='bound_debug_v1').length,0);
});
test('buddy explicitly joins once; only designated controller prepares and unknown fields fail closed',()=>{
  const h=debugFixture();h.rpc(owner,'create',{roomID});assert.throws(()=>h.prepare());
  const invited=h.rpc(peer,'status');assert.equal(invited.own,null);assert.equal(invited.capability,null);
  h.rpc(peer,'join',{membershipEpoch:1});h.rpc(peer,'resume');
  const request={operationID:operationID(1),expectedGeneration:0,kind:'load',source:{kind:'builtin',pointID:'01',fixtureVersion:'multiplayer-isolation-v1'},compatibility:plain(h.f.debug.profile),settings:Buffer.alloc(32).toString('base64')};
  assert.throws(()=>h.mutate(peer,'prepare',request));assert.throws(()=>h.rpc(owner,'status',{ownerID:peer}));
  assert.equal(h.rpc(peer,'resume').session.joined.length,2);
});
test('prepare is durable idempotency and simultaneous different operation IDs cannot replace active work',()=>{
  const h=debugFixture();h.pair();const first=h.prepare();assert.deepEqual(h.prepare().operation,first.operation);
  assert.throws(()=>h.prepare(2));assert.throws(()=>h.prepare(1,'load',{kind:'builtin',pointID:'02',fixtureVersion:'multiplayer-isolation-v1'}));
  const restarted=debugFixture(h.snapshot());const resumed=restarted.rpc(owner,'resume');assert.equal(resumed.operation.operationID,first.operation.operationID);assert.equal(resumed.operation.generation,first.operation.generation);assert.equal(resumed.manifest,null);
});
test('partial uploads and mismatched immutable chunks never publish a paired manifest',()=>{
  const h=debugFixture();h.pair();const op=h.prepare().operation,p=h.payload(op,owner),f={operationID:op.operationID,generation:op.generation};
  h.mutate(owner,'ownerPrepare',{...f,descriptor:p.descriptor});assert.throws(()=>h.mutate(owner,'seal',f));assert.throws(()=>h.mutate(owner,'commit',f));
  h.mutate(owner,'chunk',{...f,index:0,data:p.base64});h.mutate(owner,'chunk',{...f,index:0,data:p.base64});
  assert.throws(()=>h.mutate(owner,'chunk',{...f,index:0,data:'A'+p.base64.slice(1)}));
  h.mutate(owner,'seal',f);assert.throws(()=>h.mutate(owner,'commit',f));assert.equal(h.rpc(owner,'status').session.currentGeneration,0);
});
test('binary state hashes, owner identities and files validate before commit; one native verification cannot be Ready',()=>{
  const h=debugFixture(),{op,manifest,a,b}=committed(h);
  assert.equal(manifest.owners[owner].receipt.payloadSHA256,hash(a.bytes));assert.equal(manifest.owners[peer].receipt.payloadSHA256,hash(b.bytes));
  assert.notEqual(manifest.owners[owner].trainer.id,manifest.owners[peer].trainer.id);
  assert.equal(verify(h,op,manifest,owner,a).operation.state,'committed');assert.equal(h.mutate(owner,'admission',{generation:1}).admission.allowed,false);
  assert.throws(()=>verify(h,op,manifest,peer,b,{payloadSHA256:a.descriptor.receipt.payloadSHA256}));
  assert.equal(verify(h,op,manifest,peer,b).operation.state,'ready');assert.equal(h.mutate(owner,'admission',{generation:1}).admission.allowed,true);
  const own=h.rpc(owner,'download',{operationID:op.operationID,generation:1,index:0});assert.equal(own.chunk.data,a.base64);assert.notEqual(own.chunk.data,b.base64);
  assert.deepEqual(h.mutate(owner,'commit',{operationID:op.operationID,generation:1}).manifest,manifest);
});
test('generation scoped real independent engine reads exact owner payloads and never touches ordinary namespaces',()=>{
  const h=debugFixture(),{op,a,b}=committed(h),before=h.snapshot().filter(r=>['bound_independent_v2','bound_events_v2'].includes(r.collection));
  for(const [who,p]of[[owner,a],[peer,b]]){
    const value=h.mutate(who,'gameplay',{generation:1,request:{action:'get'}}).gameplay;assert.equal(value.identity.owner,who);assert.equal(value.saves[who].receipt.checkpoint,p.body.checkpoint);
    const chunk=h.mutate(who,'gameplay',{generation:1,request:{action:'saveDownload',checkpoint:p.body.checkpoint,index:0}}).gameplay;assert.equal(chunk.data,p.base64);
  }
  assert.throws(()=>h.mutate(owner,'gameplay',{generation:1,request:{action:'get',runID:op.runID}}));
  assert.deepEqual(h.snapshot().filter(r=>['bound_independent_v2','bound_events_v2'].includes(r.collection)),before);
});
test('revocation cancels new authority and admission while retaining only own committed recovery',()=>{
  const h=debugFixture(),{op,a}=committed(h);const old=h.caps[owner];
  const revoked=h.mutate(peer,'leave');assert.equal(revoked.session.membershipEpoch,2);assert.equal(revoked.capability,null);
  assert.throws(()=>h.mutate(owner,'gameplay',{generation:1,request:{action:'get'},capability:old}));
  assert.throws(()=>h.mutate(owner,'prepare',{operationID:operationID(2)}));
  assert.equal(h.rpc(owner,'download',{operationID:op.operationID,generation:1,index:0}).chunk.data,a.base64);
  assert.throws(()=>h.rpc(third,'download',{operationID:op.operationID,generation:1,index:0}));
});
test('logout and revoke CAS races cannot resurrect child uploads',()=>{
  for(const target of ['auth','session']){
    const h=debugFixture();h.pair();const op=h.prepare().operation,p=h.payload(op,owner),f={operationID:op.operationID,generation:1};h.mutate(owner,'ownerPrepare',{...f,descriptor:p.descriptor});
    const original=h.f.nk.storageWrite;let intercepted=false;
    h.f.nk.storageWrite=writes=>{if(!intercepted&&writes.some(w=>w.collection==='bound_debug_payloads_v1')){intercepted=true;
      const record=h.snapshot().find(r=>target==='auth'?r.collection==='bound_auth_sessions_v1'&&r.userId===owner:r.collection==='bound_debug_v1'&&r.key===sid);
      original([{...record,value:target==='auth'?{...record.value,revoked:true}:{...record.value,status:'revoked',membershipEpoch:2}}]);}
      return original(writes);};
    assert.throws(()=>h.mutate(owner,'chunk',{...f,index:0,data:p.base64}));assert.equal(h.snapshot().filter(r=>r.collection==='bound_debug_payloads_v1').length,0);
  }
});
test('custom rendezvous freezes exact source heads and event cut before owner captures',()=>{
  const h=debugFixture(),{a,b}=committed(h);const next=h.prepare(2,'custom',{kind:'current',sourceGeneration:1},1).operation;
  assert.equal(next.state,'waiting_cut');assert.throws(()=>h.mutate(owner,'ownerPrepare',{operationID:next.operationID,generation:2,descriptor:h.payload(next,owner).descriptor}));
  const ready=who=>h.mutate(who,'captureReady',{operationID:next.operationID,generation:2,sourceCheckpoint:(who===owner?a:b).body.checkpoint,received:{origins:{}},applied:{origins:{}},durable:{origins:{}}});
  ready(owner);assert.throws(()=>h.mutate(owner,'gameplay',{generation:1,request:{action:'events',events:[{}],after:{}}}));
  const cut=ready(peer).operation;assert.equal(cut.state,'preparing');assert.equal(cut.cut.sourceGeneration,1);assert.equal(cut.runID,next.runID);
  h.upload(cut,owner);h.upload(cut,peer);captureComplete(h,cut);const published=h.mutate(owner,'commit',{operationID:cut.operationID,generation:2});assert.equal(published.session.currentGeneration,1);
  assert.equal(h.mutate(owner,'gameplay',{generation:1,request:{action:'get'}}).gameplay.identity.run,next.runID);assert.equal(h.rpc(owner,'captures').captures[0].manifest.generation,2);
});
test('scoped terminal actions retain DEBUG evidence without deleting ordinary storage',()=>{
  const h=debugFixture(),{op}=committed(h),eventID=operationID(999);
  const action=(who,action)=>h.mutate(who,'gameplay',{generation:1,request:{action,eventID}}).gameplay;
  assert.equal(action(owner,'gameOver').deleted,false);action(owner,'gameOverReturn');action(owner,'gameOverMenu');assert.equal(action(peer,'gameOverMenu').deleted,true);
  assert.equal(h.mutate(owner,'admission',{generation:1}).admission.allowed,false);
  assert.ok(h.snapshot().some(r=>r.collection==='bound_debug_payloads_v1'));
  assert.equal(h.rpc(owner,'download',{operationID:op.operationID,generation:1,index:0}).chunk.index,0);
});
test('DEBUG realtime requires both live native verifications and rejects ordinary tickets',()=>{
  const h=debugFixture(),{op,manifest,a,b}=committed(h);
  assert.throws(()=>h.mutate(owner,'realtime',{generation:1}));verify(h,op,manifest,owner,a);assert.throws(()=>h.mutate(owner,'realtime',{generation:1}));verify(h,op,manifest,peer,b);
  const rt=h.mutate(owner,'realtime',{generation:1}).realtime;assert.notEqual(rt.roomID,roomID);assert.equal(rt.protocol,'bound-debug-room-v1');
  const api=h.f.debug.realtimeMatch,args=h.f.active.get(rt.matchID).params;
  let state=api.matchInit(h.f.ctx,h.f.logger,h.f.nk,args).state;
  const p={userId:owner,sessionId:'debug-socket',node:'fixture',username:'fixture'};
  assert.equal(api.matchJoinAttempt(h.f.ctx,h.f.logger,h.f.nk,h.f.dispatcher,0,state,p,{bound_ticket:h.f.ticket()}).accept,false);
  assert.equal(api.matchJoinAttempt(h.f.ctx,h.f.logger,h.f.nk,h.f.dispatcher,0,state,p,{bound_ticket:rt.ticket}).accept,true);
  state=api.matchJoin(h.f.ctx,h.f.logger,h.f.nk,h.f.dispatcher,0,state,[p]).state;
  assert.ok(api.matchLoop(h.f.ctx,h.f.logger,h.f.nk,h.f.dispatcher,0,state,[]));
  h.mutate(peer,'leave');assert.equal(api.matchLoop(h.f.ctx,h.f.logger,h.f.nk,h.f.dispatcher,1,state,[]),null);assert.ok(h.f.kicks.some(x=>x.sessionId===p.sessionId));
  assert.equal(h.snapshot().filter(r=>r.collection==='bound_room_presence_v1').length,0);
});
test('stale DEBUG realtime lease and advanced generation cannot rejoin',()=>{
  const h=debugFixture(),{op,manifest,a,b}=committed(h);verify(h,op,manifest,owner,a);verify(h,op,manifest,peer,b);
  const rt=h.mutate(owner,'realtime',{generation:1}).realtime,api=h.f.debug.realtimeMatch,state=api.matchInit(h.f.ctx,h.f.logger,h.f.nk,h.f.active.get(rt.matchID).params).state;
  h.f.now(1031);const p={userId:owner,sessionId:'expired',node:'fixture',username:'fixture'};
  assert.equal(api.matchJoinAttempt(h.f.ctx,h.f.logger,h.f.nk,h.f.dispatcher,0,state,p,{bound_ticket:rt.ticket}).accept,false);
  h.f.now(1000);const next=h.prepare(2,'reload',{kind:'builtin',pointID:'02',fixtureVersion:'multiplayer-isolation-v1'},1).operation;assert.equal(h.mutate(owner,'admission',{generation:1}).admission.allowed,false);assert.equal(h.mutate(owner,'realtime',{generation:1}).realtime.activitiesAllowed,false);assert.ok(api.matchLoop(h.f.ctx,h.f.logger,h.f.nk,h.f.dispatcher,0,state,[]));h.upload(next,owner);h.upload(next,peer);h.mutate(owner,'commit',{operationID:next.operationID,generation:2});
  assert.equal(api.matchJoinAttempt(h.f.ctx,h.f.logger,h.f.nk,h.f.dispatcher,0,state,p,{bound_ticket:rt.ticket}).accept,false);
  assert.equal(api.matchLoop(h.f.ctx,h.f.logger,h.f.nk,h.f.dispatcher,0,state,[]),null);
});
function journalPayload(h,op,who,events){
  const p=h.payload(op,who),journal={version:1,run:op.runID.toUpperCase(),owner:who.toUpperCase(),partner:op.identities[who].partner.toUpperCase(),events:events.map(e=>({...e,run:e.run.toUpperCase(),id:{...e.id,origin:e.id.origin.toUpperCase()}})),received:{origins:{}},acknowledged:{origins:{}},applied:{origins:{}},nextSequence:2};
  for(const e of events)journal.received.origins[e.id.origin.toUpperCase()]={contiguous:1,sparse:[]};journal.applied=structuredClone(journal.received);
  const bytes=Buffer.from(JSON.stringify(journal)),file={data:bytes.toString('base64'),sha256:hash(bytes)};p.body.files['shared-events.json']=file;p.descriptor.files['shared-events.json']={sha256:file.sha256,bytes:bytes.length};
  p.bytes=Buffer.from(JSON.stringify(p.body));p.base64=p.bytes.toString('base64');p.descriptor.bytes=p.bytes.length;p.descriptor.count=Math.ceil(p.base64.length/12000);p.descriptor.receipt.payloadSHA256=hash(p.bytes);
  p.descriptor.received={origins:Object.fromEntries(events.map(e=>[e.id.origin,{contiguous:1,sparse:[]}]))};p.descriptor.applied=structuredClone(p.descriptor.received);p.descriptor.durable=structuredClone(p.descriptor.received);return p;
}
test('nonempty paired acquisitions preserve native journal UUID bytes and require each origin exact agreement',()=>{
  for(const corrupt of [false,true]){
    const h=debugFixture();h.pair();const op=h.prepare().operation;
    const events=[owner,peer].map(origin=>({run:op.runID,id:{origin,sequence:1},kind:'soul',payload:Buffer.from(JSON.stringify({version:1,run:op.runID.toUpperCase(),kind:'acquired',slot:'area:1'})).toString('base64'),idempotencyKey:'fixture:'+origin}));
    const a=journalPayload(h,op,owner,events),other=structuredClone(events);if(corrupt)other[0].payload=Buffer.from(JSON.stringify({version:1,run:op.runID,kind:'death',slot:'area:1'})).toString('base64');
    const b=journalPayload(h,op,peer,other);h.upload(op,owner,a);h.upload(op,peer,b);
    if(corrupt)assert.throws(()=>h.mutate(owner,'commit',{operationID:op.operationID,generation:1}));
    else{h.mutate(owner,'commit',{operationID:op.operationID,generation:1});const downloaded=h.rpc(owner,'download',{operationID:op.operationID,generation:1,index:0});assert.equal(downloaded.chunk.data,a.base64);const response=h.mutate(peer,'gameplay',{generation:1,request:{action:'events',events:[],after:{origins:{}}}}).gameplay;assert.equal(response.events.length,2);}
  }
});
test('new generation preserves exact custom payload and rejects a builtin as custom source',()=>{
  const h=debugFixture();committed(h);assert.throws(()=>h.prepare(2,'reload',{kind:'custom',customID:operationID(1),sourceGeneration:1},1));
  const op=h.prepare(3,'custom',{kind:'current',sourceGeneration:1},1).operation;
  for(const who of [owner,peer])h.mutate(who,'captureReady',{operationID:op.operationID,generation:2,sourceCheckpoint:operationID((who===owner?100:200)+1),received:{origins:{}},applied:{origins:{}},durable:{origins:{}}});
  const capture=h.rpc(owner,'status').operation,a=h.upload(capture,owner),b=h.upload(capture,peer);captureComplete(h,capture);h.mutate(owner,'commit',{operationID:capture.operationID,generation:2});
  const reload=h.prepare(4,'reload',{kind:'custom',customID:capture.operationID,sourceGeneration:2},1).operation;
  assert.equal(reload.runID,capture.runID);assert.deepEqual(reload.cut,capture.cut);assert.equal(h.rpc(owner,'download',{operationID:capture.operationID,generation:2,index:0}).chunk.data,a.base64);
  h.upload(reload,owner,a);h.upload(reload,peer,b);assert.equal(h.mutate(owner,'commit',{operationID:reload.operationID,generation:3}).session.currentGeneration,3);
});
function ordinaryFixture(h){
  function rpc(who,action,fields={}){const c={version:1,protocol:'bound-saves-v1',ownerID:who,issuedAt:1000,expiresAt:1090,...(action==='create'?{partnerID:peer,roomID}:{})},encoded=Buffer.from(JSON.stringify(c)).toString('base64url'),saveTicket=encoded+'.'+createHmac('sha256',secret).update(encoded).digest('hex');return JSON.parse(h.f.independent.rpc({...h.f.ctx,userId:who},h.f.logger,h.f.nk,JSON.stringify({action,saveTicket,...fields})));}
  const settings=Buffer.alloc(32);settings[0]=5;settings[12]=187;settings.fill(255,13,20);
  const run=rpc(owner,'create',{request_id:operationID(8000),partnerID:peer,gameID:'synthetic-ordinary',romSHA256:'a'.repeat(64),settings:settings.toString('base64')});
  const bookmarks={};for(const who of [owner,peer]){const current=rpc(who,'get',{save_id:run.save_id});bookmarks[who]={identity:current.identity,checkpoint:null,receipt:null,deviceID:who,ownershipEpoch:1,settled:true};}
  return {rpc,run,bookmarks};
}
test('coordinated return requires both safe owner heads and retains ordinary bytes across revocation and retry',()=>{
  const h=debugFixture(),ordinary=ordinaryFixture(h),before=h.snapshot().filter(r=>r.collection==='bound_independent_v2');h.pair();const op=h.prepare().operation;
  for(const who of [owner,peer])h.upload(op,who,h.payload(op,who,{bookmark:ordinary.bookmarks[who]}));h.mutate(owner,'commit',{operationID:op.operationID,generation:1});
  const returning=h.prepare(2,'return',{kind:'previous'},1).operation;assert.equal(returning.runID,op.runID);assert.equal(returning.identities[owner].run,ordinary.run.save_id);
  const fields={operationID:returning.operationID,generation:2};assert.throws(()=>h.mutate(owner,'commit',fields));
  for(const who of [owner,peer]){const p=h.payload(op,who);h.mutate(who,'returnReady',{...fields,deviceID:p.descriptor.deviceID,ownershipEpoch:1,sourceCheckpoint:p.body.checkpoint,safe:true});if(who===owner)assert.throws(()=>h.mutate(owner,'commit',fields));}
  const closed=h.mutate(owner,'commit',fields);assert.equal(closed.session.status,'revoked');assert.equal(closed.manifest,null);assert.deepEqual(h.mutate(owner,'commit',fields).operation,closed.operation);
  assert.equal(h.rpc(owner,'return').returnTarget.unchanged,true);assert.throws(()=>h.rpc(owner,'returnVerify',{checkpoint:operationID(900),deviceID:owner,nativeVerified:true}));
  h.rpc(owner,'returnVerify',{checkpoint:null,deviceID:owner,nativeVerified:true});const both=h.rpc(peer,'returnVerify',{checkpoint:null,deviceID:peer,nativeVerified:true});assert.equal(both.operation.state,'ready');
  assert.deepEqual(h.snapshot().filter(r=>r.collection==='bound_independent_v2').map(r=>r.value),before.map(r=>r.value));
});
test('custom capture releases before upload, archives generation2 while1 progresses, then reload3 restores frozen cut',()=>{
  const h=debugFixture(),initial=committed(h);verify(h,initial.op,initial.manifest,owner,initial.a);verify(h,initial.op,initial.manifest,peer,initial.b);
  let op=h.prepare(2,'custom',{kind:'current',sourceGeneration:1},1).operation;
  for(const who of [owner,peer])h.mutate(who,'captureReady',{operationID:op.operationID,generation:2,sourceCheckpoint:(who===owner?initial.a:initial.b).body.checkpoint,received:{origins:{}},applied:{origins:{}},durable:{origins:{}}});op=h.rpc(owner,'status').operation;
  const a=h.payload(op,owner),b=h.payload(op,peer),fields={operationID:op.operationID,generation:2};
  h.mutate(owner,'ownerPrepare',{...fields,descriptor:a.descriptor});assert.throws(()=>h.mutate(owner,'captureComplete',{...fields,payloadSHA256:a.descriptor.receipt.payloadSHA256,cutDigest:op.cut.digest}),e=>e.message==='debug_capture_not_ready');
  h.mutate(peer,'ownerPrepare',{...fields,descriptor:b.descriptor});h.mutate(owner,'captureComplete',{...fields,payloadSHA256:a.descriptor.receipt.payloadSHA256,cutDigest:op.cut.digest});assert.equal(h.mutate(owner,'admission',{generation:1}).admission.allowed,false);
  h.mutate(peer,'captureComplete',{...fields,payloadSHA256:b.descriptor.receipt.payloadSHA256,cutDigest:op.cut.digest});assert.equal(h.mutate(owner,'admission',{generation:1}).admission.allowed,true);
  assert.equal(h.snapshot().filter(r=>r.collection==='bound_debug_payloads_v1'&&r.key.includes(op.operationID)).length,0,'native capture release does not wait for upload');
  const death={run:op.runID,id:{origin:owner,sequence:1},kind:'soul',payload:Buffer.from(JSON.stringify({version:1,run:op.runID,kind:'death',slot:'area:1'})).toString('base64')};
  h.mutate(owner,'gameplay',{generation:1,request:{action:'events',events:[death],after:{}}});h.upload(op,owner,a);h.upload(op,peer,b);
  const archive=h.mutate(owner,'commit',fields);assert.equal(archive.session.currentGeneration,1);assert.equal(archive.manifest.generation,2);assert.equal(archive.session.currentManifestDigest,initial.manifest.digest);
  assert.equal(h.mutate(peer,'gameplay',{generation:1,request:{action:'events',events:[],after:{}}}).gameplay.events.length,1);
  const restarted=debugFixture(h.snapshot());restarted.rpc(owner,'resume');restarted.rpc(peer,'resume');assert.equal(restarted.rpc(owner,'captures').captures[0].operation.operationID,op.operationID);
  const reload=restarted.prepare(3,'reload',{kind:'custom',customID:op.operationID,sourceGeneration:2},1).operation;restarted.upload(reload,owner,a);restarted.upload(reload,peer,b);assert.equal(restarted.mutate(owner,'commit',{operationID:reload.operationID,generation:3}).session.currentGeneration,3);
  assert.equal(restarted.mutate(peer,'gameplay',{generation:3,request:{action:'events',events:[],after:{}}}).gameplay.events.length,0,'post-cut permanent event stays in prior DEBUG generation and cannot leak into explicit reload');
  assert.equal(restarted.rpc(owner,'download',{operationID:reload.operationID,generation:3,index:0}).chunk.data,a.base64);
});
test('return verification cannot mark success when the ordinary head changes during its guarded transaction',()=>{
  const h=debugFixture(),ordinary=ordinaryFixture(h);h.pair();const op=h.prepare().operation;for(const who of [owner,peer])h.upload(op,who,h.payload(op,who,{bookmark:ordinary.bookmarks[who]}));h.mutate(owner,'commit',{operationID:op.operationID,generation:1});
  const original=h.f.nk.storageWrite;let changed=false;
  h.f.nk.storageWrite=writes=>{if(!changed&&writes.some(w=>w.collection==='bound_independent_v2')){changed=true;const current=h.snapshot().find(r=>r.collection==='bound_independent_v2'&&r.key===ordinary.run.save_id);current.value.saves[owner]={receipt:{checkpoint:operationID(900),owner,run:ordinary.run.save_id,payloadSHA256:'a'.repeat(64),sharedEventDigest:'b'.repeat(64)},bytes:1,count:1};original([current]);}return original(writes);};
  assert.throws(()=>h.rpc(owner,'returnVerify',{checkpoint:null,deviceID:owner,nativeVerified:true}));assert.equal(h.rpc(owner,'status').own.returnVerified,false);assert.equal(h.rpc(owner,'return').returnTarget.currentHead.checkpoint,operationID(900));
});
