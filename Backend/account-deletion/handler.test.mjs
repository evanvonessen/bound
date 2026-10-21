import test from 'node:test';
import assert from 'node:assert/strict';
import {createDeletionHandler, normalizedEmail} from './handler.mjs';
const owner='11111111-1111-4111-8111-111111111111';
const operation='a'.repeat(64);
const user={id:owner,email:'fixture@example.invalid',role:'authenticated',is_anonymous:false,email_confirmed_at:'2026-01-01T00:00:00Z'};
const response=(body,status=200)=>new Response(JSON.stringify(body),{status});
function fixture({identity=user,authStatus=200,objects=[],pending=false,deleted=200}={}) {
  const calls=[];
  const handler=createDeletionHandler({serviceKey:'synthetic-server-only',publishableKey:'synthetic-public',hash:async token=>{assert.equal(token,operation);return 'b'.repeat(64);},fetchImpl:async(url,options)=>{
    const body=options.body ? JSON.parse(options.body) : undefined;
    calls.push({url,options,body});
    if(url.endsWith('/auth/v1/user')) {assert.equal(options.headers.Authorization,'Bearer synthetic.valid.session');return response(identity,authStatus);}
    assert.equal(options.headers.Authorization,'Bearer synthetic-server-only');
    if(url.endsWith('/rest/v1/rpc/cup117_delete_account')) {
      assert.equal(body.payload.operation,'b'.repeat(64));
      switch(body.action) {
      case 'begin': assert.equal(body.payload.owner,owner);return response({ok:true,status:'pending',owner});
      case 'resume': return response({ok:true,status:'pending',owner});
      case 'objects': return response({ok:true,objects});
      case 'purge': return response({ok:true,status:pending?'pending':'ready'});
      case 'complete': return response({ok:true,status:'complete'});
      default: throw Error('unexpected RPC');
      }
    }
    if(url.includes('/storage/v1/object/')) return response({});
    if(url.endsWith('/auth/v1/admin/users/'+owner)) return response({},deleted);
    throw Error('unexpected endpoint');
  }});
  const request=(body={operationToken:operation,confirmationEmail:' FIXTURE@EXAMPLE.INVALID\n'},headers={})=>handler(new Request('https://fixture.invalid/delete-account',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer synthetic.valid.session',...headers},body:JSON.stringify(body)}));
  return {calls,request};
}
test('email confirms the server-verified self; administrative owner is never supplied by client',async()=>{
  const f=fixture();const result=await f.request();assert.equal(result.status,200);assert.deepEqual(await result.json(),{status:'complete'});
  const begin=f.calls.find(x=>x.body?.action==='begin');assert.equal(begin.body.payload.email,user.email);assert.equal(begin.body.payload.owner,owner);assert.equal(begin.body.payload.username,undefined);
  assert.ok(f.calls.some(x=>x.url.endsWith('/auth/v1/admin/users/'+owner)&&x.options.method==='DELETE'));
});
test('wrong email, anonymous, unconfirmed, and stale/revoked identities cannot begin',async()=>{
  for(const settings of [{identity:{...user,email:'other@example.invalid'}},{identity:{...user,is_anonymous:true}},{identity:{...user,email_confirmed_at:null}},{identity:{...user,role:'anon'}},{authStatus:401},{identity:{...user,id:'bad'}}]) {
    const f=fixture(settings);assert.ok((await f.request()).status>=400);assert.equal(f.calls.length,1);assert.ok(f.calls[0].url.endsWith('/auth/v1/user'));
  }
});
test('request-selected owner, passwords, or malformed capability are rejected without network',async()=>{
  for(const body of [{operationToken:operation,confirmationEmail:user.email,owner},{operationToken:operation,confirmationEmail:user.email,password:'private'}, {operationToken:[operation],confirmationEmail:user.email},{operationToken:'short'}, {operationToken:operation,confirmationEmail:'a@@b'}]) {
    const f=fixture();assert.equal((await f.request(body)).status,400);assert.equal(f.calls.length,0);
  }
  const f=fixture();assert.equal((await f.request(undefined,{origin:'https://foreign.invalid'})).status,403);assert.equal(f.calls.length,0);
});
test('pending storage purge never reports account deletion as complete',async()=>{
  const f=fixture({pending:true});const r=await f.request();assert.equal(r.status,202);assert.deepEqual(await r.json(),{status:'pending'});assert.ok(!f.calls.some(x=>x.url.includes('/auth/v1/admin/')));
});
test('foreign storage object cannot be removed',async()=>{
  const f=fixture({objects:[{bucket:'bound-roms',name:'foreign/file.gba'}]});assert.equal((await f.request()).status,503);assert.ok(!f.calls.some(x=>x.url.includes('/storage/v1/object/')||x.url.includes('/auth/v1/admin/')));
});
test('preauthorized resume uses only hashed capability and does not rely on revoked JWT',async()=>{
  const f=fixture();assert.equal((await f.request({operationToken:operation})).status,200);assert.ok(!f.calls.some(x=>x.url.endsWith('/auth/v1/user')));assert.equal(f.calls[0].body.action,'resume');
});
test('administrative delete failures cannot manufacture success',async()=>{
  const f=fixture({deleted:500});assert.equal((await f.request()).status,503);assert.ok(!f.calls.some(x=>x.body?.action==='complete'));
});
test('legacy confirmation remains compatible without introducing signup username',async()=>{
  const f=fixture({identity:{...user,user_metadata:{cupcake_username_v1:'fixture'}}});assert.equal((await f.request({operationToken:operation,confirmation:'DELETE',username:'fixture'})).status,200);
});
test('normalization matches app rules without accepting controls or ambiguous email',()=>{
  assert.equal(normalizedEmail(' USER@EXAMPLE.INVALID\r\n'),'user@example.invalid');
  for(const email of ['a@@b','@b','a@','a b@c','a@b\0','ä@b',null,{}])assert.equal(normalizedEmail(email),null);
});


test('MFA enrolled user must complete the second factor before beginning deletion',async()=>{
  const f=fixture({identity:{...user,factors:[{status:'verified',factor_type:'totp'}]}});
  assert.equal((await f.request()).status,403);
  assert.equal(f.calls.length,1);
});

test('MFA enrolled AAL2 caller can begin the existing deletion contract',async()=>{
  const calls=[];
  const token=`header.${Buffer.from(JSON.stringify({sub:owner,aal:'aal2'})).toString('base64url')}.signature`;
  const handler=createDeletionHandler({serviceKey:'synthetic-server-only',publishableKey:'synthetic-public',hash:async()=> 'b'.repeat(64),fetchImpl:async(url,options)=>{
    calls.push(url);
    if(url.endsWith('/auth/v1/user')) return response({...user,factors:[{status:'verified',factor_type:'totp'}]});
    assert.ok(url.endsWith('/cup117_delete_account'));
    assert.equal(JSON.parse(options.body).action,'begin');
    return response({ok:true,status:'complete'});
  }});
  const result=await handler(new Request('https://fixture.invalid/delete-account',{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${token}`},body:JSON.stringify({operationToken:operation,confirmationEmail:user.email})}));
  assert.equal(result.status,200); assert.equal(calls.length,2);
});
