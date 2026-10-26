namespace BoundDebug {
    const fields:{[action:string]:string[]}={create:["sessionID","roomID"],list:[],join:["sessionID","membershipEpoch"],resume:["sessionID"],status:["sessionID","operationID?"],
        prepare:["sessionID","membershipEpoch","capability","operationID","expectedGeneration","kind","source","compatibility","settings"],
        captures:["sessionID"],captureComplete:["sessionID","membershipEpoch","capability","operationID","generation","payloadSHA256","cutDigest"],
        returnReady:["sessionID","membershipEpoch","capability","operationID","generation","deviceID","ownershipEpoch","sourceCheckpoint","safe"],
        captureReady:["sessionID","membershipEpoch","capability","operationID","generation","sourceCheckpoint","received","applied","durable"],
        ownerPrepare:["sessionID","membershipEpoch","capability","operationID","generation","descriptor"],chunk:["sessionID","membershipEpoch","capability","operationID","generation","index","data"],
        seal:["sessionID","membershipEpoch","capability","operationID","generation"],commit:["sessionID","membershipEpoch","capability","operationID","generation"],
        download:["sessionID","operationID","generation","index"],verify:["sessionID","membershipEpoch","capability","operationID","generation","manifestDigest","deviceID","ownershipEpoch","payloadSHA256","checkpoint","trainerID","soulDigest","applied","nativeVerified"],
        realtime:["sessionID","membershipEpoch","capability","generation"],admission:["sessionID","membershipEpoch","capability","generation"],abort:["sessionID","membershipEpoch","capability","operationID","generation"],revoke:["sessionID","membershipEpoch","capability"],leave:["sessionID","membershipEpoch","capability"],
        return:["sessionID"],returnVerify:["sessionID","checkpoint","deviceID","nativeVerified"],gameplay:["sessionID","membershipEpoch","capability","generation","request"],report:["sessionID","operationID?"]};
    function requestValid(r:any):void {
        if(!object(r)||!fields[r.action])fail("request",3);
        const permitted=["action"].concat(fields[r.action].map(function(k){return k.replace(/\?$/,"");}));
        if(Object.keys(r).some(function(k){return permitted.indexOf(k)<0;})||fields[r.action].some(function(k){return k.indexOf("?")<0&&r[k]===undefined;}))fail("request",3);
        for(const k of ["sessionID","operationID"])if(r[k]!==undefined&&!uuid.test(r[k]))fail("request",3);
    }
    function sessionView(root:any):any {
        return {sessionID:root.sessionID,roomID:root.roomID,owners:root.owners,controllerID:root.controllerID,membershipEpoch:root.membershipEpoch,
            joined:root.joined,status:root.status,currentGeneration:root.currentGeneration,activeOperationID:root.activeOperationID,currentManifestDigest:root.currentManifestDigest};
    }
    function operationView(op:any):any {
        if(!op)return null;const answer:any={};
        for(const key of ["operationID","sessionID","membershipEpoch","requestDigest","generation","kind","source","state","runID","identities","compatibility","settings","cut","preparedOwners","verifiedOwners","deadline","failure"])answer[key]=op[key];
        answer.capturedOwners=op.capturedOwners||[];
        return answer;
    }
    function response(nk:nkruntime.Nakama,auth:any,root:any,op:any=null,extra:any={}):any {
        if(root.joined.indexOf(auth.owner)<0)return {version:1,session:sessionView(root),capability:null,operation:null,manifest:null,own:null};
        if(!op&&root.currentGeneration){const current=read(nk,manifestKey(root.sessionID,root.currentGeneration));if(current){const committed=read(nk,opKey(root.sessionID,current.value.operationID));if(committed)op=committed.value;}}
        const m=op?(["committed","ready"].indexOf(op.state)>=0?read(nk,manifestKey(root.sessionID,op.generation)):null):root.currentGeneration?read(nk,manifestKey(root.sessionID,root.currentGeneration)):null;
        const pending=op?read(nk,ownerKey(root.sessionID,op.operationID,auth.owner)):null;
        const v=root.verifications[auth.owner],answer:any={version:1,session:sessionView(root),capability:capability(nk,auth,root),operation:operationView(op),manifest:m?m.value:null,
            own:root.joined.indexOf(auth.owner)<0?null:{ownerID:auth.owner,descriptor:pending?pending.value.descriptor:m&&m.value.owners[auth.owner]||null,bookmark:root.bookmarks[auth.owner]||null,
                verifiedGeneration:v?v.generation:null,liveUntil:v?v.liveUntil:0,returnVerified:root.returned[auth.owner]===true}};
        Object.keys(extra).forEach(function(k){answer[k]=extra[k];});return answer;
    }
    function roomValid(ctx:nkruntime.Context,auth:any,room:any,roomID:string):string[] {
        if(!uuid.test(roomID)||!object(room)||room.roomID!==roomID||room.ownerID!==auth.owner||!Array.isArray(room.members)||room.members.length!==2||
            room.members[0]===room.members[1]||room.members.indexOf(auth.owner)<0||room.members.some(function(id:any){return !uuid.test(id)||(ctx.env.BOUND_DEBUG_ALLOWED_OWNERS||"").split(",").indexOf(id)<0;}))fail("friend_room",7);
        return room.members.slice().sort();
    }
    function commitWrites(nk:nkruntime.Nakama,auth:any,rootRecord:nkruntime.StorageObject|null,root:any,more:nkruntime.StorageWriteRequest[]):void {
        nk.storageWrite([unchanged(auth.auth),write(root.sessionID,root,rootRecord?rootRecord.version:"*")].concat(more));
    }
    function ordinaryReturn(nk:nkruntime.Nakama,root:any,owner:string):any {
        const b=root.bookmarks[owner];if(!b)fail("no_previous_run");
        const record=read(nk,b.identity.run.toLowerCase(),"bound_independent_v2"),state=record&&record.value;
        if(!state||state.deleted||!state.members||state.members.indexOf(owner)<0||!equal(normalizedIdentity(BoundSaveLibrary.metadata(state,owner).identity),normalizedIdentity(b.identity)))fail("ordinary_owner",7);
        const head=state.saves[owner]&&state.saves[owner].receipt||null;
        return {bookmark:b,currentHead:head,unchanged:sameReceipt(head,b.receipt),record:record};
    }
    export const rpc:nkruntime.RpcFunction=function(ctx,logger,nk,payload){
        if(!payload||payload.length>70000)fail("request",3);
        let envelope:any;try{envelope=JSON.parse(payload);}catch(_){fail("request",3);}
        const auth=authenticate(ctx,nk,envelope),r=envelope.request;requestValid(r);
        if(r.action==="list"){
            const rows=nk.sqlQuery("SELECT key FROM storage WHERE collection=$1 AND user_id=$2::uuid AND value->>'recordType'='session' AND value->'owners' ? $3 ORDER BY key LIMIT 100",[meta,system,auth.owner]);
            const sessions=rows.map(function(row:any){const value=read(nk,row.key);return value?sessionView(value.value):null;}).filter(function(v:any){return v!==null;});
            return JSON.stringify({version:1,session:null,capability:null,operation:null,manifest:null,own:null,sessions:sessions});
        }
        let rootRecord=read(nk,r.sessionID),root:any=rootRecord?copy(rootRecord.value):null;
        if(r.action==="create"){
            const owners=roomValid(ctx,auth,envelope.room,r.roomID);
            if(root){if(root.controllerID!==auth.owner||root.roomID!==r.roomID||!equal(root.owners,owners))fail("session_conflict");}
            else {root={recordType:"session",version:1,sessionID:r.sessionID,roomID:r.roomID,owners:owners,controllerID:auth.owner,membershipEpoch:1,joined:[auth.owner],status:"invited",
                currentGeneration:0,nextGeneration:0,currentManifestDigest:null,activeOperationID:null,bookmarks:{},devices:{},verifications:{},returned:{},createdAt:now()};
                commitWrites(nk,auth,null,root,[]);}
            return JSON.stringify(response(nk,auth,root));
        }
        if(!root||root.recordType!=="session"||root.owners.indexOf(auth.owner)<0)fail("session_owner",7);
        if(r.action==="join"){
            if(root.status==="revoked"||r.membershipEpoch!==root.membershipEpoch||!equal(roomValid(ctx,auth,envelope.room,root.roomID),root.owners))fail("membership",7);
            if(root.joined.indexOf(auth.owner)<0){root.joined.push(auth.owner);root.joined.sort();root.status="active";commitWrites(nk,auth,rootRecord,root,[]);}
            return JSON.stringify(response(nk,auth,root));
        }
        if(r.action!=="status"&&r.action!=="resume"&&root.joined.indexOf(auth.owner)<0)fail("join_required",7);
        let opRecord=r.operationID?read(nk,opKey(root.sessionID,r.operationID)):root.activeOperationID?read(nk,opKey(root.sessionID,root.activeOperationID)):null;
        let op:any=opRecord?copy(opRecord.value):null;
        if(["status","resume","report"].indexOf(r.action)>=0){
            if(r.operationID&&!op)fail("operation");
            const extra:any=r.action==="report"?{report:{version:1,session:sessionView(root),operation:operationView(op),manifestDigest:root.currentManifestDigest,
                ownVerification:root.verifications[auth.owner]||null,generatedAt:now(),synthetic:true}}:{};
            return JSON.stringify(response(nk,auth,root,op,extra));
        }
        if(r.action==="captures"){
            const rows=nk.sqlQuery("SELECT key FROM storage WHERE collection=$1 AND user_id=$2::uuid AND key LIKE $3 AND value->>'kind'='custom' AND value->>'state'='committed' ORDER BY (value->>'generation')::bigint DESC LIMIT 100",[meta,system,root.sessionID+"/op/%"]);
            const captures=rows.map(function(row:any){const value=read(nk,row.key);if(!value)return null;const manifest=read(nk,manifestKey(root.sessionID,value.value.generation));return manifest?{operation:operationView(value.value),manifest:manifest.value}:null;}).filter(function(v:any){return v!==null;});
            return JSON.stringify(response(nk,auth,root,op,{captures:captures}));
        }
        if(r.action==="return"||r.action==="returnVerify"){
            const target=ordinaryReturn(nk,root,auth.owner),ordinaryRecord=target.record;delete target.record;
            if(r.action==="returnVerify"){
                if(r.nativeVerified!==true||!uuid.test(r.deviceID)||(target.currentHead?target.currentHead.checkpoint.toLowerCase():null)!==r.checkpoint)fail("return_verification");
                root.returned[auth.owner]=true;const writes:nkruntime.StorageWriteRequest[]=[unchanged(ordinaryRecord)];
                if(op&&op.kind==="return"){op.verifiedOwners=root.owners.filter(function(o:string){return root.returned[o]===true;});if(op.verifiedOwners.length===2)op.state="ready";writes.push(write(opRecord!.key,op,opRecord!.version));}
                commitWrites(nk,auth,rootRecord,root,writes);
            }
            return JSON.stringify(response(nk,auth,root,op,{returnTarget:target}));
        }
        if(r.action==="download"){
            if(!op||op.generation!==r.generation||["committed","ready"].indexOf(op.state)<0||op.kind==="return")fail("uncommitted");
            const owner=read(nk,ownerKey(root.sessionID,op.operationID,auth.owner));if(!owner||!owner.value.sealed||!integer(r.index)||r.index>=owner.value.descriptor.count)fail("download");
            const chunk=read(nk,owner.key+"/"+r.index,payloads);if(!chunk)fail("partial_upload");
            return JSON.stringify(response(nk,auth,root,op,{chunk:{index:r.index,data:chunk.value.data,count:owner.value.descriptor.count,bytes:owner.value.descriptor.bytes,payloadSHA256:owner.value.descriptor.receipt.payloadSHA256}}));
        }
        // A lost commit reply remains readable after revocation, including the
        // return operation that itself closes DEBUG membership. This grants no
        // new capability and cannot write or resurrect a generation.
        if(r.action==="commit"&&op&&op.generation===r.generation&&["committed","ready"].indexOf(op.state)>=0&&root.controllerID===auth.owner)return JSON.stringify(response(nk,auth,root,op));
        admit(nk,auth,root,r,["prepare","commit","revoke"].indexOf(r.action)>=0);
        if(r.action==="realtime")return JSON.stringify(response(nk,auth,root,op,{realtime:realtime(ctx,nk,auth,rootRecord!,r.generation)}));
        if(r.action==="gameplay")return JSON.stringify(response(nk,auth,root,op,{gameplay:gameplayRequest(ctx,logger,nk,auth,rootRecord!,r)}));
        if(r.action==="leave"||r.action==="revoke"){
            root.status="revoked";root.membershipEpoch++;root.verifications={};const writes:nkruntime.StorageWriteRequest[]=[];
            if(op&&["preparing","waiting_cut","prepared"].indexOf(op.state)>=0){op.state="aborted";op.failure="revoked";writes.push(write(opRecord!.key,op,opRecord!.version));}
            commitWrites(nk,auth,rootRecord,root,writes);return JSON.stringify(response(nk,auth,root,op));
        }
        if(r.action==="prepare"){
            const choices={expectedGeneration:r.expectedGeneration,kind:r.kind,source:r.source,compatibility:r.compatibility,settings:r.settings},hash=nk.sha256Hash(canonical(choices));
            if(op){if(op.requestDigest!==hash)fail("operation_conflict");return JSON.stringify(response(nk,auth,root,op));}
            if(r.expectedGeneration!==root.currentGeneration||!integer(r.expectedGeneration)||["load","reload","custom","return"].indexOf(r.kind)<0||!equal(r.compatibility,profile)||!BoundIndependent.settingsValid(nk,r.settings)||!object(r.source))fail("prepare");
            const sourceFields:any={builtin:["fixtureVersion","kind","pointID"],current:["kind","sourceGeneration"],custom:["customID","kind","sourceGeneration"],previous:["kind"]};
            if(!sourceFields[r.source.kind]||Object.keys(r.source).sort().join(",")!==sourceFields[r.source.kind].join(",")||
                r.source.sourceGeneration!==undefined&&(!integer(r.source.sourceGeneration)||r.source.sourceGeneration<1)||
                r.source.customID!==undefined&&!uuid.test(r.source.customID))fail("source");
            if(root.activeOperationID){const active=read(nk,opKey(root.sessionID,root.activeOperationID));if(active&&["preparing","waiting_cut","prepared"].indexOf(active.value.state)>=0)fail("busy");}
            let identities:any={},runID=nk.uuidv4(),cut:any=null,ownershipEpoch=root.membershipEpoch;
            if(r.source.kind==="builtin"){
                if(typeof r.source.pointID!=="string"||!/^(0[1-9]|1[0-5])$/.test(r.source.pointID)||r.source.fixtureVersion!=="multiplayer-isolation-v1"||["load","reload"].indexOf(r.kind)<0)fail("fixture");
                root.owners.forEach(function(owner:string){const first=owner===root.controllerID;identities[owner]={run:runID,gameID:profile.gameID,owner:owner,partner:root.owners.filter(function(o:string){return o!==owner;})[0],roomID:root.roomID,
                    settingsOwner:root.controllerID,settings:r.settings,localSeed:first?305419896:2271560481,partnerSeed:first?2271560481:305419896,romSHA256:profile.romSHA256,protocolVersion:1,saveVersion:1};});
            }else if(r.source.kind==="current"||r.source.kind==="custom"){
                const source=read(nk,manifestKey(root.sessionID,r.source.sourceGeneration));if(!source||r.source.kind==="current"&&(r.kind!=="custom"||r.source.sourceGeneration!==root.currentGeneration)||r.source.kind==="custom"&&(r.kind!=="reload"||source.value.operationID!==r.source.customID))fail("source");
                const previous=read(nk,opKey(root.sessionID,source.value.operationID));if(!previous||!equal(source.value.compatibility,r.compatibility)||source.value.settings!==r.settings)fail("source");
                if(r.source.kind==="custom"&&previous.value.kind!=="custom")fail("source");
                const sourceState=read(nk,prefix(root.sessionID,r.source.sourceGeneration)+source.value.runID,gameplay);if(!sourceState)fail("source");ownershipEpoch=sourceState.value.epoch;
                runID=source.value.runID;identities=copy(previous.value.identities);if(r.source.kind==="custom")cut=source.value.cut;
            }else if(r.source.kind==="previous"&&r.kind==="return"){
                const current=read(nk,manifestKey(root.sessionID,root.currentGeneration));if(!current||current.value.settings!==r.settings)fail("source");
                root.owners.forEach(function(owner:string){identities[owner]=ordinaryReturn(nk,root,owner).bookmark.identity;});runID=current.value.runID;
            }else fail("source");
            const generation=++root.nextGeneration;root.activeOperationID=r.operationID;
            op={operationID:r.operationID,sessionID:root.sessionID,membershipEpoch:root.membershipEpoch,requestDigest:hash,generation:generation,kind:r.kind,source:r.source,state:r.kind==="custom"?"waiting_cut":"preparing",
                runID:runID,ownershipEpoch:ownershipEpoch,identities:identities,compatibility:r.compatibility,settings:r.settings,cut:cut,preparedOwners:[],verifiedOwners:[],deadline:now()+300,failure:null,rendezvous:{},capturedOwners:[]};
            commitWrites(nk,auth,rootRecord,root,[write(opKey(root.sessionID,r.operationID),op)]);return JSON.stringify(response(nk,auth,root,op));
        }
        // Remaining operation and verification transitions are defined below.
        return operationAction(ctx,logger,nk,auth,rootRecord!,root,opRecord,op,r);
    };
    function operationAction(ctx:nkruntime.Context,logger:nkruntime.Logger,nk:nkruntime.Nakama,auth:any,rootRecord:nkruntime.StorageObject,root:any,opRecord:nkruntime.StorageObject|null,op:any,r:any):string {
        if(r.action==="admission"){
            if(r.generation!==root.currentGeneration)fail("stale_generation");
            const manifest=read(nk,manifestKey(root.sessionID,r.generation));
            const game=manifest&&read(nk,prefix(root.sessionID,r.generation)+manifest.value.runID,gameplay);
            const times=root.owners.map(function(owner:string){const v=root.verifications[owner];return v&&v.generation===r.generation&&v.manifestDigest===root.currentManifestDigest?v.liveUntil:0;});
            const expiry=Math.min(times[0],times[1]);let allowed=expiry>now()&&game&&!game.value.gameOver&&!game.value.deleted&&(!op||op.kind!=="return"&&(["preparing","waiting_cut","prepared"].indexOf(op.state)<0||op.kind==="custom"&&(op.capturedOwners||[]).length===2));
            try{liveRoot(nk,root.sessionID,r.generation,root.membershipEpoch);}catch(_){allowed=false;}
            return JSON.stringify(response(nk,auth,root,op,{admission:{allowed:!!allowed,generation:r.generation,manifestDigest:root.currentManifestDigest,expiresAt:allowed?expiry:0}}));
        }
        if(!op||!opRecord||op.generation!==r.generation||op.membershipEpoch!==root.membershipEpoch)fail("stale_operation");
        const key=ownerKey(root.sessionID,op.operationID,auth.owner),ownerRecord=read(nk,key),owner=ownerRecord?copy(ownerRecord.value):null;
        if(r.action==="verify"){
            if(root.currentGeneration!==op.generation||["committed","ready"].indexOf(op.state)<0||op.kind==="return"||!owner||!owner.sealed)fail("uncommitted");
            const d=owner.descriptor;
            if(r.manifestDigest!==root.currentManifestDigest||r.deviceID!==d.deviceID||r.ownershipEpoch!==d.ownershipEpoch||r.payloadSHA256!==d.receipt.payloadSHA256||
                r.checkpoint!==d.receipt.checkpoint.toLowerCase()||r.trainerID!==d.trainer.id||r.soulDigest!==d.soulDigest||r.nativeVerified!==true||!cursor(r.applied,root.owners)||!covers(r.applied,d.applied))fail("verification");
            root.verifications[auth.owner]={generation:op.generation,manifestDigest:r.manifestDigest,deviceID:r.deviceID,ownershipEpoch:r.ownershipEpoch,verifiedAt:now(),liveUntil:now()+30,authSessionID:auth.session,authAccessHash:auth.auth.value.accessHash};
            op.verifiedOwners=root.owners.filter(function(o:string){const v=root.verifications[o];return v&&v.generation===op.generation&&v.manifestDigest===root.currentManifestDigest;});
            if(op.verifiedOwners.length===2)op.state="ready";
            commitWrites(nk,auth,rootRecord,root,[write(opRecord.key,op,opRecord.version)]);return JSON.stringify(response(nk,auth,root,op));
        }
        if(r.action==="captureComplete"&&op.kind==="custom"&&(op.capturedOwners||[]).indexOf(auth.owner)>=0&&owner&&owner.descriptor.receipt.payloadSHA256===r.payloadSHA256&&op.cut&&op.cut.digest===r.cutDigest)return JSON.stringify(response(nk,auth,root,op));
        if(r.action==="commit"&&["committed","ready"].indexOf(op.state)>=0)return JSON.stringify(response(nk,auth,root,op));
        if(root.activeOperationID!==op.operationID||["preparing","waiting_cut","prepared"].indexOf(op.state)<0)fail("operation_state");
        if(r.action==="abort"){
            op.state="aborted";op.failure="aborted";root.activeOperationID=null;
            commitWrites(nk,auth,rootRecord,root,[write(opRecord.key,op,opRecord.version)]);return JSON.stringify(response(nk,auth,root,op));
        }
        if(op.deadline<=now())fail("expired");
        const writes:nkruntime.StorageWriteRequest[]=[];
        if(r.action==="captureComplete"){
            if(op.kind!=="custom"||!op.cut||!ownerRecord||owner.descriptor.receipt.payloadSHA256!==r.payloadSHA256||op.cut.digest!==r.cutDigest)fail("capture_complete");
            root.owners.forEach(function(o:string){const candidate=read(nk,ownerKey(root.sessionID,op.operationID,o));if(!candidate)fail("capture_not_ready");if(o!==auth.owner)writes.push(unchanged(candidate));});
            op.capturedOwners=op.capturedOwners||[];if(op.capturedOwners.indexOf(auth.owner)<0)op.capturedOwners.push(auth.owner);op.capturedOwners.sort();writes.push(unchanged(ownerRecord));
        }else if(r.action==="returnReady"){
            if(op.kind!=="return"||r.safe!==true)fail("return_ready");
            const device=root.devices[auth.owner],current=read(nk,manifestKey(root.sessionID,root.currentGeneration));
            const source=current&&read(nk,prefix(root.sessionID,root.currentGeneration)+current.value.runID,gameplay);
            const head=source&&source.value.saves[auth.owner];
            if(!device||device.deviceID!==r.deviceID||device.ownershipEpoch!==r.ownershipEpoch||!source||source.value.epoch!==r.ownershipEpoch||
                (head?head.receipt.checkpoint.toLowerCase():null)!==r.sourceCheckpoint)fail("return_ready");
            const ready={sourceCheckpoint:r.sourceCheckpoint};if(op.rendezvous[auth.owner]&&!equal(op.rendezvous[auth.owner],ready))fail("immutable_conflict");
            op.rendezvous[auth.owner]=ready;if(op.preparedOwners.indexOf(auth.owner)<0)op.preparedOwners.push(auth.owner);op.preparedOwners.sort();if(op.preparedOwners.length===2)op.state="prepared";writes.push(unchanged(source));
        }else if(r.action==="captureReady"){
            if(op.kind!=="custom"||["waiting_cut","preparing"].indexOf(op.state)<0||!cursor(r.received,root.owners)||!cursor(r.applied,root.owners)||!cursor(r.durable,root.owners)||!covers(r.received,r.applied)||!covers(r.received,r.durable))fail("rendezvous");
            const source=read(nk,prefix(root.sessionID,op.source.sourceGeneration)+op.runID,gameplay);if(!source||source.value.gameOver||source.value.deleted)fail("source");
            const head=source.value.saves[auth.owner],checkpoint=head?head.receipt.checkpoint.toLowerCase():null;
            if(r.sourceCheckpoint!==checkpoint||!covers({origins:source.value.cursors},r.received))fail("source_head");
            const ready={sourceCheckpoint:r.sourceCheckpoint,received:r.received,applied:r.applied,durable:r.durable};
            if(op.rendezvous[auth.owner]&&!equal(op.rendezvous[auth.owner],ready))fail("immutable_conflict");
            op.rendezvous[auth.owner]=ready;
            if(root.owners.every(function(o:string){return !!op.rendezvous[o];})){
                const heads:any={};root.owners.forEach(function(o:string){heads[o]=source.value.saves[o]?source.value.saves[o].receipt.checkpoint.toLowerCase():null;
                    if(heads[o]!==op.rendezvous[o].sourceCheckpoint)fail("source_head");});
                const cut:any={sourceGeneration:op.source.sourceGeneration,sourceRunID:op.runID,cursor:{origins:source.value.cursors},heads:heads};
                cut.digest=nk.sha256Hash(canonical(cut));if(op.cut&&!equal(op.cut,cut))fail("history_cut");op.cut=cut;op.state="preparing";
            }
            writes.push(unchanged(source));
        }else if(r.action==="ownerPrepare"){
            if(op.state==="waiting_cut"||op.kind==="return")fail("operation_state");
            if(!object(r.descriptor))fail("descriptor");
            // Swift omits nil optionals. Normalize metadata only; the uploaded
            // checkpoint and sidecar bytes remain opaque and byte-identical.
            if(r.descriptor.bookmark===undefined)r.descriptor.bookmark=null;
            if(r.descriptor.cutDigest===undefined)r.descriptor.cutDigest=null;
            verifyDescriptor(nk,root,op,auth.owner,r.descriptor);
            const device=root.devices[auth.owner];if(device&&(device.deviceID!==r.descriptor.deviceID||device.ownershipEpoch!==r.descriptor.ownershipEpoch))fail("device_owner");
            root.devices[auth.owner]={deviceID:r.descriptor.deviceID,ownershipEpoch:r.descriptor.ownershipEpoch};
            if(!root.bookmarks[auth.owner]&&r.descriptor.bookmark)root.bookmarks[auth.owner]=copy(r.descriptor.bookmark);
            if(ownerRecord){if(!equal(owner.descriptor,r.descriptor))fail("immutable_conflict");}
            else writes.push(write(key,{descriptor:r.descriptor,sealed:false}));
        }else if(r.action==="chunk"){
            if(!ownerRecord||owner.sealed||!integer(r.index)||r.index>=owner.descriptor.count||typeof r.data!=="string"||r.data.length!==Math.min(12000,Math.ceil(owner.descriptor.bytes/3)*4-r.index*12000)||! /^[A-Za-z0-9+/]*={0,2}$/.test(r.data))fail("chunk");
            const additions=immutable(nk,key+"/"+r.index,{data:r.data},payloads);for(const addition of additions)writes.push(addition);
            writes.push(unchanged(ownerRecord));
        }else if(r.action==="seal"){
            if(!ownerRecord)fail("owner_prepare");
            if(!owner.sealed){const decoded=bytesFor(nk,key,owner.descriptor),seeded=validatePayload(nk,root,op,auth.owner,owner.descriptor,decoded.payload);
                if(!op.cut)for(const event of seeded){const additions=immutable(nk,opKey(root.sessionID,op.operationID)+"/event/"+auth.owner+"/"+event.id.sequence,event,payloads);for(const addition of additions)writes.push(addition);}
                const journal=JSON.parse(nk.binaryToString(nk.base64Decode(decoded.payload.files["shared-events.json"].data)));
                owner.observed=op.cut?[]:journal.events.map(function(e:any){const value=normalizedEvent(e);return {origin:value.id.origin,sequence:value.id.sequence,digest:nk.sha256Hash(canonical(value))};});
                owner.sealed=true;owner.sealedAt=now();owner.seeded=seeded.map(function(e:any){return e.id.sequence;});writes.push(write(key,owner,ownerRecord.version));
            }
            if(op.preparedOwners.indexOf(auth.owner)<0)op.preparedOwners.push(auth.owner);op.preparedOwners.sort();if(op.preparedOwners.length===2)op.state="prepared";
        }else if(r.action==="commit"){
            if(op.kind==="return"){
                if(op.preparedOwners.length!==2)fail("waiting_for_buddy");
                const current=read(nk,manifestKey(root.sessionID,root.currentGeneration)),source=current&&read(nk,prefix(root.sessionID,root.currentGeneration)+current.value.runID,gameplay);if(!source)fail("source");
                root.owners.forEach(function(o:string){const head=source.value.saves[o];if(!op.rendezvous[o]||(head?head.receipt.checkpoint.toLowerCase():null)!==op.rendezvous[o].sourceCheckpoint)fail("source_head");ordinaryReturn(nk,root,o);
                    const ordinary=read(nk,root.bookmarks[o].identity.run.toLowerCase(),"bound_independent_v2")!;if(!writes.some(function(w){return w.collection===ordinary.collection&&w.key===ordinary.key;}))writes.push(unchanged(ordinary));});
                writes.push(unchanged(source));op.state="committed";root.status="revoked";root.membershipEpoch++;root.verifications={};
            }else{
                if(op.preparedOwners.length!==2||op.kind==="custom"&&(op.capturedOwners||[]).length!==2)fail("waiting_for_buddy");
                const descriptors:any={},cursors:any=op.cut?copy(op.cut.cursor.origins):{},saves:any={},profiles:any={};
                root.owners.forEach(function(o:string){const saved=read(nk,ownerKey(root.sessionID,op.operationID,o));if(!saved||!saved.value.sealed)fail("waiting_for_buddy");
                    const d=copy(saved.value.descriptor);d.bookmark=null;descriptors[o]=d;saves[o]={receipt:d.receipt,count:d.count,bytes:d.bytes};profiles[o]={name:d.trainer.name,gender:d.trainer.gender};
                    if(!op.cut)for(const sequence of saved.value.seeded)insertCursor(cursors,o,sequence);
                    for(const observed of saved.value.observed||[]){const event=read(nk,opKey(root.sessionID,op.operationID)+"/event/"+observed.origin+"/"+observed.sequence,payloads);
                        if(!event||nk.sha256Hash(canonical(normalizedEvent(event.value)))!==observed.digest)fail("paired_history");}
                    writes.push(unchanged(saved));});
                if(descriptors[root.owners[0]].trainer.id===descriptors[root.owners[1]].trainer.id)fail("distinct_trainers");
                const m:any={sessionID:root.sessionID,membershipEpoch:root.membershipEpoch,operationID:op.operationID,generation:op.generation,runID:op.runID,source:op.source,
                    compatibility:op.compatibility,settings:op.settings,owners:descriptors,cut:op.cut,committedAt:now()};m.digest=nk.sha256Hash(canonical(m));
                const state={version:2,save_id:op.runID,game_id:op.compatibility.gameID,roomID:root.roomID,members:root.owners,identity:op.identities[root.owners[0]],committed:true,cancelled:false,epoch:op.ownershipEpoch,revision:1,chooserSeen:now(),
                    cursors:cursors,saves:saves,deliveries:{},profiles:profiles,created_at:new Date().toISOString(),updated_at:new Date().toISOString()};
                writes.push(write(manifestKey(root.sessionID,op.generation),m));writes.push(write(prefix(root.sessionID,op.generation)+op.runID,state,"*",gameplay));
                op.state="committed";
                if(op.kind==="custom")root.activeOperationID=null;
                else{root.currentGeneration=op.generation;root.currentManifestDigest=m.digest;root.verifications={};root.returned={};}
            }
        }else fail("action",3);
        writes.push(write(opRecord.key,op,opRecord.version));commitWrites(nk,auth,rootRecord,root,writes);
        return JSON.stringify(response(nk,auth,root,op));
    }
}

function boundDebugRPC(ctx:nkruntime.Context,logger:nkruntime.Logger,nk:nkruntime.Nakama,payload:string):string {
    return BoundDebug.rpc(ctx,logger,nk,payload) as string;
}
