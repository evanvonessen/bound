namespace BoundDebug {
    export function manifestKey(session:string,generation:number):string { return session+"/generation/"+generation; }
    export function scopedRuntime(nk:nkruntime.Nakama,auth:any,sessionRecord:nkruntime.StorageObject,generation:number):nkruntime.Nakama {
        const root=sessionRecord.value,base=prefix(root.sessionID,generation),view:any=Object.create(nk);
        const activeOperation=root.activeOperationID?read(nk,opKey(root.sessionID,root.activeOperationID)):null;
        function bucket(collection:string):string {
            if(collection==="bound_independent_v2")return gameplay;
            if(collection==="bound_events_v2")return events;
            fail("scope",7);
        }
        function seeded(key:string,collection:string,g:number,depth:number):any {
            if(depth>64)fail("history_depth");
            const manifest=read(nk,manifestKey(root.sessionID,g));if(!manifest)return null;
            const m=manifest.value,parts=key.split("/");
            if(collection==="bound_independent_v2"&&parts.length>=4&&parts[0]===m.runID&&parts[1]==="save") {
                const d=m.owners[parts[2]];if(!d||parts[3]!==d.receipt.checkpoint.toLowerCase())return null;
                if(parts.length===4)return {receipt:d.receipt,count:d.count,bytes:d.bytes};
                if(parts.length===5&&/^(0|[1-9][0-9]*)$/.test(parts[4])) {
                    const part=read(nk,ownerKey(root.sessionID,m.operationID,parts[2])+"/"+parts[4],payloads);return part&&part.value;
                }
            }
            if(collection==="bound_events_v2"&&parts.length===3&&parts[0]===m.runID) {
                const event=read(nk,opKey(root.sessionID,m.operationID)+"/event/"+parts[1]+"/"+parts[2],payloads);if(event)return event.value;
                if(m.cut) {const c=m.cut.cursor.origins[parts[1]],sequence=Number(parts[2]);
                    if(c&&(sequence<=c.contiguous||c.sparse.indexOf(sequence)>=0)) {
                        const source=read(nk,prefix(root.sessionID,m.cut.sourceGeneration)+key,events);
                        return source?source.value:seeded(key,collection,m.cut.sourceGeneration,depth+1);
                    }
                }
            }
            return null;
        }
        view.storageRead=function(requests:nkruntime.StorageReadRequest[]):nkruntime.StorageObject[] {
            const answer:nkruntime.StorageObject[]=[];
            for(const r of requests){if(r.userId!==system)fail("scope",7);
                const mapped=read(nk,base+r.key,bucket(r.collection));
                if(mapped){const result=copy(mapped);result.key=r.key;result.collection=r.collection;answer.push(result);continue;}
                const value=seeded(r.key,r.collection,generation,0);
                if(value!==null)answer.push({key:r.key,collection:r.collection,userId:system,value:value,version:"debug-seed",permissionRead:0,permissionWrite:0} as nkruntime.StorageObject);
            }
            return answer;
        };
        view.storageWrite=function(requests:nkruntime.StorageWriteRequest[]):nkruntime.StorageWriteAck[] {
            const mapped=requests.map(function(r){if(r.userId!==system)fail("scope",7);return write(base+r.key,r.value,r.version||"*",bucket(r.collection));});
            // Revocation, generation and auth logout race every child write on
            // the same CAS guards. No public request chooses these namespaces.
            const guards=[unchanged(auth.auth),unchanged(sessionRecord)];if(activeOperation)guards.push(unchanged(activeOperation));
            return nk.storageWrite(guards.concat(mapped));
        };
        view.storageDelete=function(){fail("scope",7);};
        view.sqlQuery=function(){fail("scope",7);};
        view.sqlExec=function(sql:string,args:any[]){
            // DEBUG keeps immutable generation evidence after the engine's
            // authenticated terminal tombstone; it never runs ordinary GC SQL.
            if(sql!=="DELETE FROM storage WHERE user_id = $1::uuid AND collection IN ('bound_independent_v2','bound_events_v2') AND key LIKE $2"||args[0]!==system)fail("scope",7);
            return {rowsAffected:0};
        };
        return view as nkruntime.Nakama;
    }
    export function gameplayRequest(ctx:nkruntime.Context,logger:nkruntime.Logger,nk:nkruntime.Nakama,auth:any,sessionRecord:nkruntime.StorageObject,request:any):any {
        const root=sessionRecord.value,generation=request.generation;
        if(!integer(generation)||generation!==root.currentGeneration||!object(request.request))fail("stale_generation");
        const allowed=["get","events","save","saveChunk","saveSeal","saveDownload","gameOver","gameOverReturn","gameOverMenu","gameOverStatus"],body=copy(request.request);
        if(allowed.indexOf(body.action)<0||body.save_id!==undefined||body.runID!==undefined||body.saveTicket!==undefined||body.ticket!==undefined||body.ownerID!==undefined)fail("gameplay_request",7);
        const manifest=read(nk,manifestKey(root.sessionID,generation));if(!manifest)fail("manifest");
        if(root.activeOperationID){const active=read(nk,opKey(root.sessionID,root.activeOperationID));
            if(active&&["custom","return"].indexOf(active.value.kind)>=0&&active.value.rendezvous[auth.owner]&&(active.value.capturedOwners||[]).indexOf(auth.owner)<0&&["waiting_cut","preparing","prepared"].indexOf(active.value.state)>=0&&
                !(body.action==="get"||body.action==="saveDownload"||body.action==="gameOverStatus"||body.action==="events"&&Array.isArray(body.events)&&body.events.length===0))fail("capture_fenced");}
        body.save_id=manifest.value.runID;
        const ticket={version:1,protocol:"bound-saves-v1",ownerID:auth.owner,issuedAt:now(),expiresAt:now()+90};
        const encoded=nk.base64UrlEncode(JSON.stringify(ticket),false);
        body.saveTicket=encoded+"."+nk.base16Encode(nk.hmacSha256Hash(encoded,ctx.env.BOUND_NAKAMA_BRIDGE_SECRET));
        const context:any={};Object.keys(ctx).forEach(function(k){context[k]=(ctx as any)[k];});context.userId=auth.owner;
        return JSON.parse(BoundIndependent.rpc(context,logger,scopedRuntime(nk,auth,sessionRecord,generation),JSON.stringify(body)) as string);
    }
}
