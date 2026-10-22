const origin = 'https://qevnxhngdtlyihhmvnjv.supabase.co';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const roomPattern = /^[A-Za-z0-9_-]{1,64}$/;
const response = (status, body) => new Response(JSON.stringify(body), {status, headers: {'Content-Type':'application/json', 'Cache-Control':'no-store'}});
async function boundedJSON(stream, limit, timeoutMs=5000) {
  if (!stream) throw Error();
  const reader = stream.getReader(); let size=0; const chunks=[];
  let timer; const timeout=new Promise((_,reject)=>{timer=setTimeout(()=>{void reader.cancel().catch(()=>{});reject(Error());},timeoutMs);});
  try { for (;;) { const {done,value}=await Promise.race([reader.read(),timeout]); if(done) break; size+=value.byteLength; if(size>limit) throw Error(); chunks.push(value); } }
  finally { clearTimeout(timer); void reader.cancel().catch(()=>{}); }
  const bytes=new Uint8Array(size); let offset=0; for(const c of chunks){bytes.set(c,offset);offset+=c.length;}
  return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
}
export function createTokenHandler({appID, certificate, publishableKey, rooms, sign, fetchImpl=fetch, now=()=>Math.floor(Date.now()/1000), requestTimeoutMs=5000}) {
  if(!/^[a-f0-9]{32}$/i.test(appID??'') || !/^[a-f0-9]{32}$/i.test(certificate??'') || !publishableKey || typeof sign!=='function') throw Error('Invalid issuer configuration');
  const channels=new Set();
  for(const [roomID,room] of Object.entries(rooms??{})) {
    if(!roomPattern.test(roomID)||!roomPattern.test(room.channel??'')||!Array.isArray(room.members)||room.members.length!==2) throw Error('Invalid room configuration');
    if(channels.has(room.channel)) throw Error('Invalid room configuration');
    channels.add(room.channel);
    if(room.members.some(m=>!uuid.test(m.ownerID??'')||!Number.isInteger(m.uid)||m.uid<1||m.uid>4294967295)||room.members[0].ownerID.toLowerCase()===room.members[1].ownerID.toLowerCase()||room.members[0].uid===room.members[1].uid) throw Error('Invalid room configuration');
  }
  return async request => {
    if(request.method!=='POST') return response(405,{error:'method_not_allowed'});
    if(request.headers.has('origin')) return response(403,{error:'forbidden'});
    if(request.headers.get('content-type')?.split(';')[0]!=='application/json') return response(400,{error:'invalid_request'});
    const authorization=request.headers.get('authorization')??'';
    if(!/^Bearer [A-Za-z0-9._-]{16,8192}$/.test(authorization)) return response(401,{error:'unauthorized'});
    let body;
    try { body=await boundedJSON(request.body,256,requestTimeoutMs); } catch { return response(400,{error:'invalid_request'}); }
    const isLobby=body && !Array.isArray(body) && Object.keys(body).length===2 &&
      uuid.test(body.lobbyID??'') && uuid.test(body.memberToken??'');
    const isPair=body && !Array.isArray(body) && Object.keys(body).length===1 && roomPattern.test(body.roomID??'');
    if(!isLobby&&!isPair) return response(400,{error:'invalid_request'});
    let user;
    try {
      const auth=await fetchImpl(`${origin}/auth/v1/user`,{headers:{Authorization:authorization,apikey:publishableKey},redirect:'error',signal:AbortSignal.timeout(5000)});
      if(!auth.ok) return response(401,{error:'unauthorized'});
      user=await boundedJSON(auth.body,65536);
    } catch { return response(503,{error:'identity_unavailable'}); }
    if(!uuid.test(user?.id??'')||user.is_anonymous!==false||user.role!=='authenticated'||!Number.isFinite(Date.parse(user.email_confirmed_at??''))) return response(403,{error:'forbidden'});
    // Deletion fences also apply to statically configured rooms. Fail closed
    // until the CUP-117 read-only gate has been deployed.
    try {
      const gate = await fetchImpl(`${origin}/rest/v1/rpc/cup117_account_active`, {
        method:'POST',headers:{Authorization:authorization,apikey:publishableKey,'Content-Type':'application/json'},
        body:'{}',redirect:'error',signal:AbortSignal.timeout(5000)});
      if (!gate.ok || await boundedJSON(gate.body,32) !== true) return response(403,{error:'forbidden'});
    } catch { return response(503,{error:'identity_unavailable'}); }
    let channel, uid, remoteUID, members, membershipRevision, ttl=60;
    if(isLobby) {
      try {
        const membershipRequestedAt=performance.now();
        const result=await fetchImpl(`${origin}/rest/v1/rpc/bound_lobby_v1`,{
          method:'POST',headers:{Authorization:authorization,apikey:publishableKey,'Content-Type':'application/json'},
          body:JSON.stringify({action:'room',payload:{lobbyID:body.lobbyID,memberToken:body.memberToken}}),redirect:'error',signal:AbortSignal.timeout(5000)});
        if(!result.ok) return response(403,{error:'forbidden'});
        const resolved=await boundedJSON(result.body,4096), room=resolved?.room;
        if(resolved?.ok!==true || room?.lobbyID!==body.lobbyID.toLowerCase() ||
          room.channel!==`bound_lobby_${body.lobbyID.toLowerCase().replaceAll('-','')}` ||
          ![1,2,3,4].includes(room.uid) || !Array.isArray(room.members) || room.members.length<1 || room.members.length>4 ||
          !/^[1-9][0-9]{0,18}$/.test(room.membershipRevision??'') ||
          !Number.isFinite(room.serverTime) || !Number.isFinite(room.expiresAt)) return response(403,{error:'forbidden'});
        // A token cannot outlive the presence authority that allowed it. Count
        // the complete RPC round trip conservatively, including streamed JSON.
        ttl=Math.min(60,Math.floor(room.expiresAt-room.serverTime-(performance.now()-membershipRequestedAt)/1000)-1);
        if(ttl<=30) return response(403,{error:'membership_expired'});
        const owners=new Set(),uids=new Set(),sessions=new Set();
        for(const member of room.members) {
          if(!uuid.test(member?.ownerID??'') || ![1,2,3,4].includes(member.uid) || !uuid.test(member.sessionID??'') ||
            !/^[1-9][0-9]{0,18}$/.test(member.generation??'') || owners.has(member.ownerID.toLowerCase()) || uids.has(member.uid) || sessions.has(member.sessionID.toLowerCase()))
            return response(403,{error:'forbidden'});
          owners.add(member.ownerID.toLowerCase());uids.add(member.uid);sessions.add(member.sessionID.toLowerCase());
        }
        const local=room.members.find(m=>m.ownerID.toLowerCase()===user.id.toLowerCase());
        if(!local || local.uid!==room.uid) return response(403,{error:'forbidden'});
        channel=room.channel;uid=room.uid;members=room.members;membershipRevision=room.membershipRevision;
        remoteUID=members.find(m=>m.ownerID===room.partnerOwnerID && m.uid!==uid)?.uid ?? members.find(m=>m.uid!==uid)?.uid ?? 0;
      } catch { return response(503,{error:'membership_unavailable'}); }
    } else if(Object.hasOwn(rooms??{},body.roomID)) {
      // Retire legacy static-room bypasses; every lease needs the checked friend RPC.
      return response(403,{error:'forbidden'});
    } else {
      // The caller's own JWT authorizes the RPC. No elevated service credential.
      if(!uuid.test(body.roomID)) return response(403,{error:'forbidden'});
      try {
        const result=await fetchImpl(`${origin}/rest/v1/rpc/cup050_friends`,{
          method:'POST',headers:{Authorization:authorization,apikey:publishableKey,'Content-Type':'application/json'},
          body:JSON.stringify({action:'room',payload:{roomID:body.roomID}}),redirect:'error',signal:AbortSignal.timeout(5000)});
        if(!result.ok) return response(403,{error:'forbidden'});
        const resolved=await boundedJSON(result.body,4096);
        const room=resolved?.room;
        if(resolved?.ok!==true || room?.roomID!==body.roomID.toLowerCase() ||
          room.channel!==`cup050_${body.roomID.toLowerCase().replaceAll('-','')}` ||
          ![1,2].includes(room.uid) || ![1,2].includes(room.remoteUID) || room.uid===room.remoteUID || channels.has(room.channel)) return response(403,{error:'forbidden'});
        channel=room.channel; uid=room.uid; remoteUID=room.remoteUID;
      } catch { return response(503,{error:'membership_unavailable'}); }
    }
    try {
      const issuedAt=now(); const token=sign({appID,certificate,channel,uid,ttl});
      if(typeof token!=='string'||token.length<16||token.length>8192) throw Error();
      return response(200,{roomID:isLobby?body.lobbyID:body.roomID,ownerID:user.id,appID,channel,uid,remoteUID,token,issuedAt,expiresAt:issuedAt+ttl,
        ...(isLobby?{lobbyID:body.lobbyID,members,membershipRevision}:{})});
    } catch { return response(503,{error:'issuance_unavailable'}); }
  };
}
