import test from 'node:test';
import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {secret} from './fixture.mjs';
import {debugFixture,owner,peer,sid,roomID,operationID,plain,hash,blob,settings} from './debug-fixture.mjs';

function committed(h){
  h.pair();const op=h.prepare().operation,a=h.upload(op,owner),b=h.upload(op,peer);
  h.mutate(owner,'commit',{operationID:op.operationID,generation:1});return {op,a,b};
}
function snapshot(h,op,who,checkpoint,predecessor,events=[]){
  const p=h.payload(op,who),cursor={origins:{}};
  for(const e of events)cursor.origins[e.id.origin]={contiguous:e.id.sequence,sparse:[]};
  const journal={version:1,run:op.runID,owner:who,partner:op.identities[who].partner,events,received:cursor,applied:cursor,nextSequence:2};
  p.body.checkpoint=checkpoint;p.body.predecessor=predecessor;
  p.body.files['shared-events.json']=blob(Buffer.from(JSON.stringify(journal)));
  // Exercise multiple real engine chunks, not only descriptor admission.
  p.body.files['checkpoint.state']=blob(Buffer.alloc(10000,193));
  p.bytes=Buffer.from(JSON.stringify(p.body));p.base64=p.bytes.toString('base64');
  p.descriptor.receipt={...p.descriptor.receipt,checkpoint,payloadSHA256:hash(p.bytes)};
  p.descriptor.bytes=p.bytes.length;p.descriptor.count=Math.ceil(p.base64.length/12000);
  p.descriptor.files=Object.fromEntries(Object.entries(p.body.files).map(([name,f])=>[name,{sha256:f.sha256,bytes:Buffer.from(f.data,'base64').length}]));
  p.descriptor.received=plain(cursor);p.descriptor.applied=plain(cursor);p.descriptor.durable=plain(cursor);return p;
}
function gameplay(h,who,generation,request){return h.mutate(who,'gameplay',{generation,request}).gameplay;}
function save(h,who,generation,p,expectedHead){
  // Preserve the receipt case emitted by Swift; this is a new immutable save.
  const receipt=plain(p.descriptor.receipt);for(const key of ['run','owner','checkpoint'])receipt[key]=receipt[key].toUpperCase();
  const fields={checkpoint:p.body.checkpoint,receipt,count:p.descriptor.count,bytes:p.bytes.length,expectedHead};
  gameplay(h,who,generation,{action:'save',...fields});
  gameplay(h,who,generation,{action:'save',...fields});
  for(let index=0;index<fields.count;index++)gameplay(h,who,generation,{action:'saveChunk',...fields,index,data:p.base64.slice(index*12000,(index+1)*12000)});
  return gameplay(h,who,generation,{action:'saveSeal',...fields});
}
function download(h,who,generation,p){
  return Array.from({length:p.descriptor.count},(_,index)=>gameplay(h,who,generation,{action:'saveDownload',checkpoint:p.body.checkpoint,index}).data).join('');
}
test('DEBUG scope preserves all short keys and bounds long keys at the largest generation',()=>{
  const h=debugFixture(),nk=h.f.nk,map=h.f.debug.scopedKey;
  for(const generation of [1,Number.MAX_SAFE_INTEGER]){
    const prefix=sid+'/'+generation+'/',short=operationID(12),limit='a'.repeat(128-prefix.length),long=operationID(12)+'/save/'+owner+'/'+operationID(13);
    assert.equal(map(nk,sid,generation,short),prefix+short);
    assert.equal(map(nk,sid,generation,limit),prefix+limit);
    assert.equal(map(nk,sid,generation,long),prefix+'~'+hash(long));
    assert.ok(map(nk,sid,generation,long).length<=128);
    assert.notEqual(map(nk,sid,generation,long),map(nk,sid,generation,long+'/0'));
  }
});
test('DEBUG real engine saves under the PostgreSQL key limit and reloads exact custom source lineage',()=>{
  const h=debugFixture(),ordinaryBefore=h.snapshot().filter(r=>['bound_independent_v2','bound_events_v2'].includes(r.collection));
  const {op,a,b}=committed(h);
  const event={run:op.runID,id:{origin:owner,sequence:1},kind:'soul',payload:Buffer.from(JSON.stringify({version:1,run:op.runID,kind:'death',slot:'area:1'})).toString('base64')};
  gameplay(h,owner,1,{action:'events',events:[event],after:{}});
  const p=snapshot(h,op,owner,operationID(901),a.body.checkpoint,[event]);
  assert.ok(p.descriptor.count>1);
  assert.equal(save(h,owner,1,p,a.body.checkpoint).saves[owner].receipt.checkpoint,p.body.checkpoint.toUpperCase());
  assert.equal(download(h,owner,1,p),p.base64);
  assert.throws(()=>gameplay(h,owner,1,{action:'save',checkpoint:p.body.checkpoint,receipt:{...p.descriptor.receipt,payloadSHA256:'a'.repeat(64)},count:p.descriptor.count,bytes:p.bytes.length}));
  let capture=h.prepare(2,'custom',{kind:'current',sourceGeneration:1},1).operation;
  const cursor=p.descriptor.applied;
  for(const who of [owner,peer])h.mutate(who,'captureReady',{operationID:capture.operationID,generation:2,sourceCheckpoint:who===owner?p.body.checkpoint:b.body.checkpoint,received:cursor,applied:cursor,durable:cursor});
  capture=h.rpc(owner,'status').operation;
  const captured={};for(const who of [owner,peer])captured[who]=snapshot(h,capture,who,operationID(who===owner?902:903),who===owner?p.body.checkpoint:b.body.checkpoint,[event]);
  for(const who of [owner,peer])h.upload(capture,who,captured[who]);
  for(const who of [owner,peer])h.mutate(who,'captureComplete',{operationID:capture.operationID,generation:2,payloadSHA256:captured[who].descriptor.receipt.payloadSHA256,cutDigest:capture.cut.digest});
  assert.equal(h.mutate(owner,'commit',{operationID:capture.operationID,generation:2}).session.currentGeneration,1);
  const restarted=debugFixture(h.snapshot());restarted.rpc(owner,'resume');restarted.rpc(peer,'resume');
  const reload=restarted.prepare(3,'reload',{kind:'custom',customID:capture.operationID,sourceGeneration:2},1).operation;
  for(const who of [owner,peer])restarted.upload(reload,who,captured[who]);
  restarted.mutate(owner,'commit',{operationID:reload.operationID,generation:3});
  assert.equal(download(restarted,owner,3,captured[owner]),captured[owner].base64);
  assert.deepEqual(gameplay(restarted,peer,3,{action:'events',events:[],after:{}}).events,[event]);
  const after=snapshot(restarted,reload,owner,operationID(904),captured[owner].body.checkpoint,[event]);
  save(restarted,owner,3,after,captured[owner].body.checkpoint);assert.equal(download(restarted,owner,3,after),after.base64);
  const rows=restarted.snapshot();assert.ok(rows.every(r=>r.key.length<=128));
  assert.deepEqual(rows.filter(r=>['bound_independent_v2','bound_events_v2'].includes(r.collection)),ordinaryBefore);
});
test('DEBUG historical cut resolves a long event key through the same bounded source mapping',()=>{
  const h=debugFixture(),{op}=committed(h),generation=Number.MAX_SAFE_INTEGER,run=op.runID;
  const root=h.snapshot().find(r=>r.collection==='bound_debug_v1'&&r.key===sid);
  const manifest=h.snapshot().find(r=>r.collection==='bound_debug_v1'&&r.key===sid+'/generation/1');
  const event={run,id:{origin:owner,sequence:Number.MAX_SAFE_INTEGER},kind:'soul',payload:'synthetic'};
  const key=run+'/'+owner+'/'+event.id.sequence;
  assert.ok((sid+'/'+generation+'/'+key).length>128);
  const sourceKey=h.f.debug.scopedKey(h.f.nk,sid,generation,key);
  h.f.nk.storageWrite([{collection:'bound_debug_events_v2',key:sourceKey,userId:root.userId,value:event,version:'*'}]);
  manifest.value.cut={sourceGeneration:generation,cursor:{origins:{[owner]:{contiguous:0,sparse:[event.id.sequence]}}}};
  h.f.nk.storageWrite([manifest]);
  const scoped=h.f.debug.scopedRuntime(h.f.nk,null,root,1);
  assert.deepEqual(plain(scoped.storageRead([{collection:'bound_events_v2',key,userId:root.userId}])[0].value),event);
});
function returningFixture(){
  const h=debugFixture();
  function ordinary(who,action,fields={}){
    const claims={version:1,protocol:'bound-saves-v1',ownerID:who,issuedAt:1000,expiresAt:1090,...(action==='create'?{partnerID:peer,roomID}:{})},encoded=Buffer.from(JSON.stringify(claims)).toString('base64url');
    return JSON.parse(h.f.independent.rpc({...h.f.ctx,userId:who},h.f.logger,h.f.nk,JSON.stringify({action,saveTicket:encoded+'.'+createHmac('sha256',secret).update(encoded).digest('hex'),...fields})));
  }
  const run=ordinary(owner,'create',{request_id:operationID(9000),partnerID:peer,gameID:'scope-race-fixture',romSHA256:'a'.repeat(64),settings:settings()});
  h.pair();const op=h.prepare().operation,ps={};
  for(const who of [owner,peer]){const identity=ordinary(who,'get',{save_id:run.save_id}).identity;
    ps[who]=h.upload(op,who,h.payload(op,who,{bookmark:{identity,checkpoint:null,receipt:null,deviceID:who,ownershipEpoch:1,settled:true}}));}
  h.mutate(owner,'commit',{operationID:op.operationID,generation:1});
  const returning=h.prepare(2,'return',{kind:'previous'},1).operation;
  return {h,op,ps,returning,ready:who=>h.mutate(who,'returnReady',{operationID:returning.operationID,generation:2,sourceCheckpoint:ps[who].body.checkpoint,deviceID:ps[who].descriptor.deviceID,ownershipEpoch:1,safe:true})};
}
test('scoped child retries revalidate authority after real buddy returnReady races the write',()=>{
  const {h,op,ps,ready}=returningFixture(),p=snapshot(h,op,owner,operationID(9501),ps[owner].body.checkpoint),write=h.f.nk.storageWrite;
  let changed=false;
  h.f.nk.storageWrite=writes=>{if(!changed&&writes.some(w=>w.collection==='bound_debug_gameplay_v2'&&w.value.data)){changed=true;ready(peer);}return write(writes);};
  assert.equal(save(h,owner,1,p,ps[owner].body.checkpoint).saves[owner].receipt.checkpoint,p.body.checkpoint.toUpperCase());
  assert.equal(changed,true);assert.equal(download(h,owner,1,p),p.base64);
});
test('scoped retries cannot refresh past own readiness, revocation, logout, generation or manifest change',()=>{
  for(const change of ['own-ready','revoked','logout','generation','manifest']){
    const {h,op,ps,ready}=returningFixture(),p=snapshot(h,op,owner,operationID(9502),ps[owner].body.checkpoint),write=h.f.nk.storageWrite;
    let changed=false,attempts=0;
    h.f.nk.storageWrite=writes=>{if(writes.some(w=>w.collection==='bound_debug_gameplay_v2'&&w.value.data)){
      attempts++;if(!changed){changed=true;
        if(change==='own-ready')ready(owner);
        else if(change==='revoked')h.mutate(peer,'leave');
        else if(change==='logout'){const r=h.snapshot().find(r=>r.collection==='bound_auth_sessions_v1'&&r.userId===owner);r.value.revoked=true;write([r]);}
        else{const r=h.snapshot().find(r=>r.collection==='bound_debug_v1'&&r.key===sid);if(change==='generation')r.value.currentGeneration++;else r.value.currentManifestDigest='f'.repeat(64);write([r]);}
      }}return write(writes);};
    assert.throws(()=>save(h,owner,1,p,ps[owner].body.checkpoint),undefined,change);
    assert.ok(changed&&attempts<=5,change);
    assert.equal(h.snapshot().filter(r=>r.collection==='bound_debug_gameplay_v2'&&r.value.data).length,0,change);
  }
});
