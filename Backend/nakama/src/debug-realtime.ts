namespace BoundDebug {
    const realtimeProtocol = "bound-debug-room-v1", presenceCollection = "bound_debug_presence_v1";
    // This checks the durable session on every match callback, including loops
    // with no incoming frames. A cached ticket is never a revocation authority.
    export function liveRoot(nk:nkruntime.Nakama,sessionID:string,generation:number,epoch:number):any {
        const record=read(nk,sessionID),root=record&&record.value;
        if(!root||root.status!=="active"||root.membershipEpoch!==epoch||root.currentGeneration!==generation)fail("realtime_stale",7);
        const manifest=read(nk,manifestKey(sessionID,generation));
        const game=manifest&&read(nk,prefix(sessionID,generation)+manifest.value.runID,gameplay);
        if(!game||game.value.gameOver||game.value.deleted)fail("realtime_terminal",7);
        root.owners.forEach(function(owner:string){
            const v=root.verifications[owner];
            if(!v||v.generation!==generation||v.manifestDigest!==root.currentManifestDigest||v.liveUntil<=now()||!v.authSessionID)fail("realtime_not_ready",7);
            const a=read(nk,v.authSessionID,"bound_auth_sessions_v1",owner),account=nk.accountGetId(owner);
            if(!a||a.value.revoked||a.value.purpose!=="normal"||a.value.expiresAt<=now()||a.value.accessHash!==v.authAccessHash||
                account.disableTime||!account.user.metadata.bound_email_confirmed_at||account.user.metadata.bound_deleted_at)fail("realtime_unauthorized",7);
        });return root;
    }
    function roomID(nk:nkruntime.Nakama,sessionID:string,generation:number):string {
        const h=nk.sha256Hash(realtimeProtocol+"/"+sessionID+"/"+generation);return h.slice(0,8)+"-"+h.slice(8,12)+"-4"+h.slice(13,16)+"-8"+h.slice(17,20)+"-"+h.slice(20,32);
    }
    function signed(ctx:nkruntime.Context,nk:nkruntime.Nakama,claims:any):string {
        const value=nk.base64UrlEncode(canonical(claims),false);return value+"."+nk.base16Encode(nk.hmacSha256Hash(value,ctx.env.BOUND_DEBUG_GATEWAY_SECRET));
    }
    function claims(ctx:nkruntime.Context,nk:nkruntime.Nakama,ticket:any):any {
        if(ctx.env.BOUND_DEBUG_MODE!=="local"||typeof ticket!=="string"||ticket.length>4096)fail("realtime_ticket",7);
        const p=ticket.split(".");if(p.length!==2||p[1]!==nk.base16Encode(nk.hmacSha256Hash(p[0],ctx.env.BOUND_DEBUG_GATEWAY_SECRET)))fail("realtime_ticket",7);
        let c:any;try{c=JSON.parse(nk.binaryToString(nk.base64UrlDecode(p[0],false)));}catch(_){fail("realtime_ticket",7);}
        if(c.protocol!==realtimeProtocol||!uuid.test(c.ownerID)||!uuid.test(c.sessionID)||!uuid.test(c.authSessionID)||!integer(c.generation)||!integer(c.membershipEpoch)||
            !integer(c.issuedAt)||!integer(c.expiresAt)||c.issuedAt>now()+5||c.expiresAt<=now()||c.expiresAt>c.issuedAt+30)fail("realtime_ticket",7);
        const root=liveRoot(nk,c.sessionID,c.generation,c.membershipEpoch),v=root.verifications[c.ownerID];
        if(!v||root.owners.indexOf(c.ownerID)<0||c.roomID!==roomID(nk,c.sessionID,c.generation)||v.authSessionID!==c.authSessionID||v.authAccessHash!==c.accessHash)fail("realtime_ticket",7);
        return c;
    }
    function ordinaryTicket(ctx:nkruntime.Context,nk:nkruntime.Nakama,c:any,members:string[]):string {
        const value=nk.base64UrlEncode(JSON.stringify({version:1,protocol:BoundRooms.protocol,ownerID:c.ownerID,roomID:c.roomID,members:members,issuedAt:now(),expiresAt:c.expiresAt}),false);
        return value+"."+nk.base16Encode(nk.hmacSha256Hash(value,ctx.env.BOUND_NAKAMA_BRIDGE_SECRET));
    }
    function roomRuntime(nk:nkruntime.Nakama):nkruntime.Nakama {
        const scoped:any=Object.create(nk),map=function(r:any){if(r.collection!=="bound_room_presence_v1")fail("realtime_scope",7);const v=copy(r);v.collection=presenceCollection;return v;};
        scoped.storageRead=function(rows:any[]){return nk.storageRead(rows.map(map));};
        scoped.storageWrite=function(rows:any[]){return nk.storageWrite(rows.map(map));};return scoped;
    }
    export function realtime(ctx:nkruntime.Context,nk:nkruntime.Nakama,auth:any,rootRecord:nkruntime.StorageObject,generation:number):any {
        const root=liveRoot(nk,rootRecord.key,generation,rootRecord.value.membershipEpoch),id=roomID(nk,root.sessionID,generation),key=root.sessionID+"/realtime/"+generation;
        let directory=read(nk,key),match=directory&&nk.matchGet(directory.value.matchID);
        if(!match){
            const cleanup=nk.uuidv4(),matchID=nk.matchCreate(realtimeProtocol,{roomID:id,members:root.owners,cleanupToken:cleanup,sessionID:root.sessionID,generation:generation,membershipEpoch:root.membershipEpoch});
            try{nk.storageWrite([unchanged(auth.auth),unchanged(rootRecord),write(key,{matchID:matchID},directory?directory.version:"*")]);}
            catch(error){try{nk.matchSignal(matchID,JSON.stringify({type:"discard",cleanupToken:cleanup}));}catch(_){}throw error;}
            match=nk.matchGet(matchID);if(!match)fail("realtime_unavailable");
        }
        const expiry=Math.min(now()+30,root.verifications[root.owners[0]].liveUntil,root.verifications[root.owners[1]].liveUntil);
        const c={protocol:realtimeProtocol,ownerID:auth.owner,sessionID:root.sessionID,generation:generation,membershipEpoch:root.membershipEpoch,roomID:id,
            authSessionID:auth.session,accessHash:auth.auth.value.accessHash,issuedAt:now(),expiresAt:expiry};
        const pending=root.activeOperationID&&read(nk,opKey(root.sessionID,root.activeOperationID));
        const activitiesAllowed=!(pending&&["waiting_cut","prepared","preparing"].indexOf(pending.value.state)>=0&&!(pending.value.kind==="custom"&&(pending.value.capturedOwners||[]).length===2));
        return {matchID:match.matchId,roomID:id,protocol:realtimeProtocol,ticket:signed(ctx,nk,c),expiresAt:expiry,activitiesAllowed:activitiesAllowed};
    }
    export const realtimeMatch:nkruntime.MatchHandler<any>={
        matchInit:function(ctx,logger,nk,params){
            liveRoot(nk,params.sessionID,params.generation,params.membershipEpoch);
            if(params.roomID!==roomID(nk,params.sessionID,params.generation))fail("realtime_scope",7);
            const result=BoundRooms.match.matchInit(ctx,logger,roomRuntime(nk),params),s:any=result.state;
            s.debug={sessionID:params.sessionID,generation:params.generation,membershipEpoch:params.membershipEpoch,claims:{}};result.label=JSON.stringify({protocol:realtimeProtocol});return result;
        },
        matchJoinAttempt:function(ctx,logger,nk,dispatcher,tick,state,presence,metadata){
            try{const c=claims(ctx,nk,metadata.bound_ticket),d=state.debug;
                if(presence.userId!==c.ownerID||c.sessionID!==d.sessionID||c.generation!==d.generation||c.membershipEpoch!==d.membershipEpoch)fail("realtime_scope",7);
                const result=BoundRooms.match.matchJoinAttempt(ctx,logger,roomRuntime(nk),dispatcher,tick,state,presence,{bound_ticket:ordinaryTicket(ctx,nk,c,state.members)});
                if(result&&result.accept)state.debug.claims[presence.sessionId]=metadata.bound_ticket;return result;
            }catch(_){return {state:state,accept:false,rejectMessage:"DEBUG admission is stale or unavailable"};}
        },
        matchJoin:function(ctx,logger,nk,dispatcher,tick,state,presences){
            const valid=presences.filter(function(p){try{claims(ctx,nk,state.debug.claims[p.sessionId]);return true;}catch(_){dispatcher.matchKick([p]);delete state.sessions[p.sessionId];return false;}});
            return BoundRooms.match.matchJoin(ctx,logger,roomRuntime(nk),dispatcher,tick,state,valid);
        },
        matchLeave:function(ctx,logger,nk,dispatcher,tick,state,presences){presences.forEach(function(p){delete state.debug.claims[p.sessionId];});return BoundRooms.match.matchLeave(ctx,logger,roomRuntime(nk),dispatcher,tick,state,presences);},
        matchLoop:function(ctx,logger,nk,dispatcher,tick,state,messages){
            try{liveRoot(nk,state.debug.sessionID,state.debug.generation,state.debug.membershipEpoch);}catch(_){dispatcher.matchKick(Object.keys(state.sessions).map(function(k){return state.sessions[k].presence;}));return null;}
            Object.keys(state.sessions).forEach(function(k){try{claims(ctx,nk,state.debug.claims[k]);}catch(_){dispatcher.matchKick([state.sessions[k].presence]);delete state.sessions[k];delete state.debug.claims[k];}});
            const forwarded:nkruntime.MatchMessage[]=[];
            messages.forEach(function(m){if(!state.sessions[m.sender.sessionId])return;
                if(m.opCode!==5){forwarded.push(m);return;}
                try{const frame=JSON.parse(nk.binaryToString(m.data)),c=claims(ctx,nk,frame.ticket),old=claims(ctx,nk,state.debug.claims[m.sender.sessionId]);
                    if(frame.v!==1||Object.keys(frame).sort().join(",")!=="ticket,v"||c.ownerID!==old.ownerID||c.sessionID!==old.sessionID||c.generation!==old.generation)fail("realtime_renewal",7);
                    state.debug.claims[m.sender.sessionId]=frame.ticket;
                    // BoundRooms retains its existing renewal rate limit and fencing.
                    const replacement:any=Object.create(m);replacement.data=nk.stringToBinary(JSON.stringify({v:1,ticket:ordinaryTicket(ctx,nk,c,state.members)}));forwarded.push(replacement);
                }catch(_){dispatcher.matchKick([m.sender]);delete state.sessions[m.sender.sessionId];delete state.debug.claims[m.sender.sessionId];}
            });return BoundRooms.match.matchLoop(ctx,logger,roomRuntime(nk),dispatcher,tick,state,forwarded);
        },
        matchTerminate:function(ctx,logger,nk,dispatcher,tick,state,grace){return BoundRooms.match.matchTerminate(ctx,logger,roomRuntime(nk),dispatcher,tick,state,grace);},
        matchSignal:function(ctx,logger,nk,dispatcher,tick,state,data){return BoundRooms.match.matchSignal(ctx,logger,roomRuntime(nk),dispatcher,tick,state,data);}
    };
}
var boundDebugMatchInit=BoundDebug.realtimeMatch.matchInit;
var boundDebugMatchJoinAttempt=BoundDebug.realtimeMatch.matchJoinAttempt;
var boundDebugMatchJoin=BoundDebug.realtimeMatch.matchJoin;
var boundDebugMatchLeave=BoundDebug.realtimeMatch.matchLeave;
var boundDebugMatchLoop=BoundDebug.realtimeMatch.matchLoop;
var boundDebugMatchTerminate=BoundDebug.realtimeMatch.matchTerminate;
var boundDebugMatchSignal=BoundDebug.realtimeMatch.matchSignal;
