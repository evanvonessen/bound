import { createHash, createHmac } from 'node:crypto';
import { fixture, owner, peer, third, roomID, plain, secret } from './fixture.mjs';
export { owner, peer, third, roomID, plain };
export const sid = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
export const operationID = n => `eeeeeeee-eeee-4eee-8eee-${String(n).padStart(12,'0')}`;
export const hash = bytes => createHash('sha256').update(bytes).digest('hex');
export const blob = bytes => ({ data: Buffer.from(bytes).toString('base64'), sha256: hash(bytes) });
export const canonical = value => Array.isArray(value) ? '['+value.map(canonical).join(',')+']' : value !== null && typeof value === 'object' ? '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}' : JSON.stringify(value);
export const settings = () => { const b=Buffer.alloc(32); b[0]=5;b[12]=187;b.fill(255,13,20);return b.toString('base64'); };
export function debugFixture(saved = []) {
  const f=fixture(),stored=new Map(),key=r=>r.collection+':'+r.userId+':'+r.key;
  let serial=0;
  f.ctx={env:{BOUND_ACCOUNT_MODE:'nakama',BOUND_DEBUG_MODE:'local',BOUND_DEBUG_GATEWAY_SECRET:secret,BOUND_NAKAMA_BRIDGE_SECRET:secret,BOUND_DEBUG_ALLOWED_OWNERS:[owner,peer].join(',')}};
  f.nk.uuidv4=()=>`cccccccc-cccc-4ccc-8ccc-${String(++serial).padStart(12,'0')}`;
  f.nk.base64Encode=b=>Buffer.from(b).toString('base64');
  f.nk.accountGetId=id=>({user:{userId:id,metadata:{bound_email_confirmed_at:'fixture'}},email:'fixture@bound-debug.invalid'});
  f.nk.storageRead=reads=>reads.flatMap(r=>stored.has(key(r))?[plain(stored.get(key(r)))]:[]);
  f.nk.storageWrite=writes=>{
    const keys=writes.map(key);if(new Set(keys).size!==keys.length)throw Error('duplicate transaction key');
    for(const w of writes){const old=stored.get(key(w));if(w.version==='*'&&old||w.version&&w.version!=='*'&&old?.version!==w.version)throw Error('CAS conflict');}
    // Nakama versions are value digests: an unchanged CAS guard retains its
    // version. This matters when the real engine stages a child then writes
    // its cursor in another guarded transaction in the same RPC.
    return writes.map(w=>{const r={...plain(w),version:createHash('md5').update(canonical(w.value)).digest('hex')};stored.set(key(r),r);return plain(r);});
  };
  f.nk.sqlQuery=(sql,args)=>{
    if(sql.startsWith('SELECT encode(extensions.digest'))return [{hash:hash(Buffer.from(args[0],'base64'))}];
    if(sql.includes("value->>'kind'='custom'"))return [...stored.values()].filter(r=>r.collection===args[0]&&r.userId===args[1]&&r.key.startsWith(args[2].slice(0,-1))&&r.value.kind==='custom'&&r.value.state==='committed').sort((a,b)=>b.value.generation-a.value.generation).slice(0,100).map(r=>({key:r.key}));
    if(sql.startsWith('SELECT key FROM storage'))return [...stored.values()].filter(r=>r.collection===args[0]&&r.userId===args[1]&&r.value.recordType==='session'&&r.value.owners.includes(args[2])).map(r=>({key:r.key}));
    throw Error('unexpected SQL');
  };
  if(saved.length)f.nk.storageWrite(saved.map(r=>({...plain(r),version:'*'})));
  const sessions={[owner]:'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',[peer]:'aaaaaaaa-aaaa-4aaa-8aaa-000000000002',[third]:'aaaaaaaa-aaaa-4aaa-8aaa-000000000003'};
  for(const who of [owner,peer,third])if(!f.nk.storageRead([{collection:'bound_auth_sessions_v1',userId:who,key:sessions[who]}]).length)f.nk.storageWrite([{collection:'bound_auth_sessions_v1',userId:who,key:sessions[who],version:'*',value:{accessHash:hash(who),expiresAt:5000,revoked:false,purpose:'normal',aal:'aal1'},permissionRead:0,permissionWrite:0}]);
  const caps={};
  function rpc(who,action,fields={},override={}){
    const request={action,...(action==='list'?{}:{sessionID:sid}),...fields};
    const record=f.nk.storageRead([{collection:'bound_auth_sessions_v1',userId:who,key:sessions[who]}])[0];
    const room=['create','join'].includes(action)?{roomID,ownerID:who,members:[owner,peer]}:null;
    const authorization={ownerID:who,sessionID:sessions[who],sessionVersion:record.version,accessHash:record.value.accessHash,expiresAt:1020,requestSHA256:hash(canonical({request,room}))};
    const envelope={request,room,authorization,signature:createHmac('sha256',secret).update(canonical(authorization)).digest('hex'),...override};
    const value=JSON.parse(f.debug.rpc(f.ctx,f.logger,f.nk,JSON.stringify(envelope)));
    if(value.capability)caps[who]=value.capability;return value;
  }
  const mutate=(who,action,fields={})=>rpc(who,action,{membershipEpoch:1,capability:caps[who],...fields});
  const pair=()=>{rpc(owner,'create',{roomID});return rpc(peer,'join',{membershipEpoch:1});};
  const prepare=(n=1,kind='load',source={kind:'builtin',pointID:'01',fixtureVersion:'multiplayer-isolation-v1'},expectedGeneration=0)=>mutate(owner,'prepare',{operationID:operationID(n),expectedGeneration,kind,source,compatibility:plain(f.debug.profile),settings:settings()});
  function payload(op,who,extra={}){
    const identity=op.identities[who],deviceID=who===owner?'bbbbbbbb-bbbb-4bbb-8bbb-000000000001':'bbbbbbbb-bbbb-4bbb-8bbb-000000000002';
    const ledger=Buffer.from(JSON.stringify({version:1,run:op.runID,owner:who,synthetic:true}));
    const memory=Buffer.from(JSON.stringify({['Soul Link/'+hash(identity.gameID)+'.json']:ledger.toString('base64')}));
    const journal=Buffer.from(JSON.stringify({version:1,run:op.runID,owner:who,partner:identity.partner,events:[],received:{origins:{}},applied:{origins:{}},nextSequence:1}));
    const files={'game.sav':blob(Buffer.from([0,255,128,192,1])),'checkpoint.state':blob(Buffer.from([255,254,0,1,128])),'memory-files.json':blob(memory),'shared-events.json':blob(journal)};
    const body={version:2,manifest:{identity,deviceOwner:deviceID,releasedForTransfer:false},checkpoint:who===owner?operationID(100+op.generation):operationID(200+op.generation),predecessor:null,sharedEventDigest:hash('synthetic-history'),files};
    const bytes=Buffer.from(JSON.stringify(body)),base64=bytes.toString('base64');
    const descriptor={deviceID,ownershipEpoch:1,compatibility:plain(f.debug.profile),trainer:{id:identity.localSeed,name:who===owner?'Red':'Blue',gender:0},receipt:{run:op.runID,checkpoint:body.checkpoint,owner:who,payloadSHA256:hash(bytes),sharedEventDigest:body.sharedEventDigest},bytes:bytes.length,count:Math.ceil(base64.length/12000),files:Object.fromEntries(Object.entries(files).map(([k,v])=>[k,{sha256:v.sha256,bytes:Buffer.from(v.data,'base64').length}])),historyDigest:body.sharedEventDigest,soulDigest:hash(ledger),received:{origins:{}},applied:{origins:{}},durable:{origins:{}},cutDigest:op.cut?.digest??null,bookmark:null,safe:true,...extra};
    return {body,bytes,base64,descriptor};
  }
  function upload(op,who,p=payload(op,who)){
    const fields={operationID:op.operationID,generation:op.generation};mutate(who,'ownerPrepare',{...fields,descriptor:p.descriptor});
    for(let i=0;i<p.descriptor.count;i++)mutate(who,'chunk',{...fields,index:i,data:p.base64.slice(i*12000,(i+1)*12000)});
    mutate(who,'seal',fields);return p;
  }
  return {f,stored,rpc,mutate,pair,prepare,payload,upload,caps,sessions,snapshot:()=>[...stored.values()].map(plain)};
}
