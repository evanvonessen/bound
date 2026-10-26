/// <reference path="../types/nakama-runtime.d.ts" />

// Private, explicitly enabled local DEBUG authority. Fixed storage domains are
// independent of ordinary saves. Native payloads remain their existing bytes.
namespace BoundDebug {
    export const meta = "bound_debug_v1", payloads = "bound_debug_payloads_v1";
    export const gameplay = "bound_debug_gameplay_v2", events = "bound_debug_events_v2";
    export const system = "00000000-0000-0000-0000-000000000000";
    export const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, digest = /^[0-9a-f]{64}$/;
    export const profile = { romSHA256: "7e170ed0d868cc3353552523c0a417ae600c6c24b0f7c28ff2781925bf6b9ca8", gameID: "a08fc3e61882d725c15e848a44fb00ac2802db42",
        coreIdentifier: "com.rileytestut.GBADeltaCore", coreStateVersion: 10, saveStateLayout: 6,
        ruleset: "6fb29ba1401149ed8dc6fa12b85cd94f", protocolVersion: 1, saveVersion: 1 };
    export function fail(message: string, code: number = 9): never { throw { message: "debug_" + message, code: code }; }
    export function now(): number { return Math.floor(Date.now() / 1000); }
    export function object(v: any): boolean { return v !== null && typeof v === "object" && !Array.isArray(v); }
    export function integer(v: any): boolean { return typeof v === "number" && isFinite(v) && v >= 0 && v <= 9007199254740991 && Math.floor(v) === v; }
    export function lowerUUID(v:any):string { return typeof v==="string"&&uuid.test(v.toLowerCase())?v.toLowerCase():""; }
    export function canonical(v: any): string {
        if (Array.isArray(v)) return "[" + v.map(canonical).join(",") + "]";
        if (object(v)) return "{" + Object.keys(v).sort().map(function (k) { return JSON.stringify(k) + ":" + canonical(v[k]); }).join(",") + "}";
        return JSON.stringify(v);
    }
    export function copy(v: any): any { return JSON.parse(JSON.stringify(v)); }
    export function equal(a: any, b: any): boolean { return canonical(a) === canonical(b); }
    export function sameReceipt(a:any,b:any):boolean {
        if(a===null||b===null)return a===null&&b===null;
        if(!object(a)||!object(b))return false;
        // Ordinary Swift receipts retain uppercase UUIDs in their immutable
        // payload metadata. DEBUG wire metadata uses lowercase UUIDs. Compare
        // those identifiers semantically without rewriting either record or
        // relaxing any hash, extra field, or other receipt content.
        const left=copy(a),right=copy(b);
        for(const key of ["run","owner","checkpoint"]){
            const x=lowerUUID(left[key]),y=lowerUUID(right[key]);if(!x||!y)return false;
            left[key]=x;right[key]=y;
        }
        return equal(left,right);
    }
    export function normalizedIdentity(value:any):any {
        if(!object(value))fail("identity");const result=copy(value);
        for(const key of ["run","owner","partner","settingsOwner","roomID"]){if(typeof result[key]!=="string"||!uuid.test(result[key].toLowerCase()))fail("identity");result[key]=result[key].toLowerCase();}
        return result;
    }
    export function normalizedCursor(value:any):any {
        if(!object(value)||!object(value.origins))fail("cursor");const origins:any={};
        Object.keys(value.origins).forEach(function(key){const lower=key.toLowerCase();if(origins[lower])fail("cursor");const p=copy(value.origins[key]);if(!object(p)||!Array.isArray(p.sparse))fail("cursor");p.sparse.sort(function(a:number,b:number){return a-b;});origins[lower]=p;});return {origins:origins};
    }
    export function normalizedEvent(value:any):any {
        if(!object(value)||!object(value.id)||typeof value.run!=="string"||typeof value.id.origin!=="string")fail("journal_event");
        const event=copy(value);event.run=event.run.toLowerCase();event.id.origin=event.id.origin.toLowerCase();return event;
    }
    export function insertCursor(cursors:any,origin:string,sequence:number):void {
        const c=cursors[origin]||(cursors[origin]={contiguous:0,sparse:[]});if(sequence<=c.contiguous||c.sparse.indexOf(sequence)>=0)return;
        c.sparse.push(sequence);c.sparse.sort(function(a:number,b:number){return a-b;});
        while(c.sparse.length&&c.sparse[0]===c.contiguous+1){c.contiguous++;c.sparse.shift();}
    }
    export function read(nk: nkruntime.Nakama, key: string, collection: string = meta, owner: string = system): nkruntime.StorageObject | null {
        return nk.storageRead([{ collection: collection, key: key, userId: owner }])[0] || null;
    }
    export function write(key: string, value: any, version: string = "*", collection: string = meta, owner: string = system): nkruntime.StorageWriteRequest {
        return { collection: collection, key: key, userId: owner, value: value, version: version, permissionRead: 0, permissionWrite: 0 };
    }
    export function unchanged(record: nkruntime.StorageObject): nkruntime.StorageWriteRequest {
        return write(record.key, record.value, record.version, record.collection, record.userId);
    }
    function signature(nk: nkruntime.Nakama, text: string, secret: string): string { return nk.base16Encode(nk.hmacSha256Hash(text, secret)); }
    function constant(a: any, b: string): boolean {
        if (typeof a !== "string" || a.length !== b.length) return false;
        let different = 0; for (let i = 0; i < b.length; i++) different |= a.charCodeAt(i) ^ b.charCodeAt(i);
        return different === 0;
    }
    export function authenticate(ctx: nkruntime.Context, nk: nkruntime.Nakama, envelope: any): any {
        if (ctx.userId || ctx.env.BOUND_DEBUG_MODE !== "local" || !BoundAccounts.enabled(ctx)) fail("disabled", 7);
        const secret = ctx.env.BOUND_DEBUG_GATEWAY_SECRET;
        if (!secret || secret.length < 32 || !object(envelope) || !object(envelope.request) || !object(envelope.authorization)) fail("unauthorized", 16);
        const a = envelope.authorization;
        if (!uuid.test(a.ownerID) || !uuid.test(a.sessionID) || !digest.test(a.accessHash) || !digest.test(a.requestSHA256) ||
            typeof a.sessionVersion !== "string" || !integer(a.expiresAt) || a.expiresAt <= now() || a.expiresAt > now() + 30 ||
            a.requestSHA256 !== nk.sha256Hash(canonical({ request: envelope.request, room: envelope.room || null })) ||
            !constant(envelope.signature, signature(nk, canonical(a), secret))) fail("unauthorized", 16);
        if ((ctx.env.BOUND_DEBUG_ALLOWED_OWNERS || "").split(",").indexOf(a.ownerID) < 0) fail("forbidden", 7);
        const account = nk.accountGetId(a.ownerID), auth = read(nk, a.sessionID, "bound_auth_sessions_v1", a.ownerID);
        if (!account.user || account.user.userId !== a.ownerID || account.disableTime || !account.user.metadata.bound_email_confirmed_at || account.user.metadata.bound_deleted_at ||
            !auth || auth.version !== a.sessionVersion || auth.value.accessHash !== a.accessHash || auth.value.revoked ||
            auth.value.expiresAt <= now() || auth.value.purpose !== "normal") fail("unauthorized", 16);
        return { owner: a.ownerID, session: a.sessionID, auth: auth, secret: secret };
    }
    export function capability(nk: nkruntime.Nakama, auth: any, root: any): string | null {
        if (root.status === "revoked" || root.joined.indexOf(auth.owner) < 0) return null;
        const claims = { version: 1, sessionID: root.sessionID, authSessionID: auth.session, ownerID: auth.owner,
            membershipEpoch: root.membershipEpoch, role: root.controllerID === auth.owner ? "controller" : "member", expiresAt: now() + 300 };
        const encoded = nk.base64UrlEncode(canonical(claims), false);
        return encoded + "." + signature(nk, encoded, auth.secret);
    }
    export function admit(nk: nkruntime.Nakama, auth: any, root: any, request: any, controller: boolean = false): void {
        if (root.status !== "active" || root.membershipEpoch !== request.membershipEpoch || root.joined.indexOf(auth.owner) < 0 ||
            typeof request.capability !== "string" || request.capability.length > 2048) fail("forbidden", 7);
        const parts = request.capability.split(".");
        if (parts.length !== 2 || !constant(parts[1], signature(nk, parts[0], auth.secret))) fail("capability", 7);
        let value: any; try { value = JSON.parse(nk.binaryToString(nk.base64UrlDecode(parts[0], false))); } catch (_) { fail("capability", 7); }
        if (value.version !== 1 || value.sessionID !== root.sessionID || value.authSessionID !== auth.session || value.ownerID !== auth.owner ||
            value.membershipEpoch !== root.membershipEpoch || !integer(value.expiresAt) || value.expiresAt <= now() ||
            value.role !== (root.controllerID === auth.owner ? "controller" : "member") || controller && value.role !== "controller") fail("capability", 7);
    }
    export function cursor(v: any, owners: string[]): boolean {
        if (!object(v) || !object(v.origins) || Object.keys(v).join(",") !== "origins") return false;
        return Object.keys(v.origins).every(function (owner) {
            const p = v.origins[owner];
            if (owners.indexOf(owner) < 0 || !object(p) || !integer(p.contiguous) || !Array.isArray(p.sparse) || p.sparse.length > 100000) return false;
            let last = p.contiguous + 1;
            return p.sparse.every(function (n: any) { if (!integer(n) || n <= last) return false; last = n; return true; });
        });
    }
    export function covers(a: any, b: any): boolean {
        return Object.keys(b.origins).every(function (owner) {
            const x = a.origins[owner] || { contiguous: 0, sparse: [] }, y = b.origins[owner];
            return x.contiguous >= y.contiguous && y.sparse.every(function (n: number) { return n <= x.contiguous || x.sparse.indexOf(n) >= 0; });
        });
    }
    export function checkpointIdentity(root: any, op: any, owner: string): any { return op.identities[owner]; }
    export function opKey(session: string, operation: string): string { return session + "/op/" + operation; }
    export function prefix(session: string, generation: number): string { return session + "/" + generation + "/"; }
    export function ownerKey(session: string, operation: string, owner: string): string { return opKey(session, operation) + "/owner/" + owner; }
    export function immutable(nk: nkruntime.Nakama, key: string, value: any, bucket: string): nkruntime.StorageWriteRequest[] {
        const prior = read(nk, key, bucket);
        if (prior && !equal(prior.value, value)) fail("immutable_conflict");
        return prior ? [] : [write(key, value, "*", bucket)];
    }
    function ordinaryCheckpoint(nk:nkruntime.Nakama,b:any,d:any):void {
        const r=d&&d.receipt;
        if(!object(r)||lowerUUID(r.owner)!==b.identity.owner||lowerUUID(r.run)!==b.identity.run||!lowerUUID(r.checkpoint)||
            !digest.test(r.payloadSHA256)||!digest.test(r.sharedEventDigest)||!integer(d.bytes)||d.bytes<1||d.bytes>16777216||
            d.count!==Math.ceil(Math.ceil(d.bytes/3)*4/12000))fail("ordinary_checkpoint");
        const key=b.identity.run+"/save/"+b.identity.owner+"/"+r.checkpoint.toLowerCase(),parts:string[]=[];
        for(let i=0;i<d.count;i++){const part=read(nk,key+"/"+i,"bound_independent_v2");
            if(!part||typeof part.value.data!=="string"||part.value.data.length!==Math.min(12000,Math.ceil(d.bytes/3)*4-i*12000))fail("ordinary_checkpoint");parts.push(part.value.data);}
        const bytes=nk.base64Decode(parts.join("")),text=nk.binaryToString(bytes);
        if(bytes.byteLength!==d.bytes||nk.sha256Hash(text)!==r.payloadSHA256)fail("ordinary_checkpoint");
        let p:any;try{p=JSON.parse(text);}catch(_){fail("ordinary_checkpoint");}
        if(!object(p)||p.version!==2||!object(p.manifest)||!equal(normalizedIdentity(p.manifest.identity),normalizedIdentity(b.identity))||
            lowerUUID(p.manifest.deviceOwner)!==b.deviceID||p.manifest.releasedForTransfer===true||p.manifest.ended===true||
            lowerUUID(p.checkpoint)!==r.checkpoint.toLowerCase()||p.sharedEventDigest!==r.sharedEventDigest)fail("ordinary_owner",7);
    }
    export function bookmark(nk: nkruntime.Nakama, value: any, owner: string, retained?:any): any {
        if(retained&&!equal(value,retained))fail("bookmark_changed");
        if (value === null) return null;
        if (!object(value) || !object(value.identity) || lowerUUID(value.identity.owner) !== owner || !lowerUUID(value.identity.run) ||
            !uuid.test(value.deviceID) || !integer(value.ownershipEpoch) || value.ownershipEpoch < 1 || value.settled !== true) fail("bookmark");
        const state = read(nk, value.identity.run.toLowerCase(), "bound_independent_v2");
        if (!state || state.value.deleted || !state.value.members || state.value.members.indexOf(owner) < 0) fail("ordinary_owner", 7);
        const identity = BoundSaveLibrary.metadata(state.value, owner).identity, receipt = state.value.saves[owner] && state.value.saves[owner].receipt;
        if (!equal(normalizedIdentity(identity), normalizedIdentity(value.identity)) || state.value.epoch!==value.ownershipEpoch) fail("ordinary_head_changed");
        if(retained){
            // A session's return bookmark is immutable. Later DEBUG captures
            // may follow ordinary saves made after initial admission; those
            // newer heads do not replace the original return identity.
            if(value.checkpoint===null){if(value.receipt!==null)fail("ordinary_checkpoint");}
            else{
                if(!uuid.test(value.checkpoint))fail("ordinary_checkpoint");
                const historical=read(nk,value.identity.run.toLowerCase()+"/save/"+owner+"/"+value.checkpoint,"bound_independent_v2");
                if(!historical||!sameReceipt(historical.value.receipt,value.receipt))fail("ordinary_checkpoint");
                ordinaryCheckpoint(nk,value,historical.value);
            }
            if(receipt)ordinaryCheckpoint(nk,value,state.value.saves[owner]);
            else if(value.checkpoint!==null)fail("ordinary_head_changed");
        }else if((receipt ? receipt.checkpoint.toLowerCase() : null) !== value.checkpoint || !sameReceipt(receipt || null, value.receipt)) fail("ordinary_head_changed");
        return copy(value);
    }
    export function verifyDescriptor(nk: nkruntime.Nakama, root: any, op: any, owner: string, d: any): void {
        // The server admitted and stored this exact profile at prepare. A later
        // current-profile update must not reinterpret its immutable operation.
        if (!object(d) || !uuid.test(d.deviceID) || !integer(d.ownershipEpoch) || d.ownershipEpoch !== op.ownershipEpoch || !equal(d.compatibility, op.compatibility) ||
            !object(d.trainer) || !integer(d.trainer.id) || d.trainer.id > 4294967295 || !BoundSaveLibrary.profile({name:d.trainer.name,gender:d.trainer.gender}) ||
            d.safe !== true || !object(d.receipt) || lowerUUID(d.receipt.owner) !== owner || lowerUUID(d.receipt.run) !== op.runID ||
            !lowerUUID(d.receipt.checkpoint) || !digest.test(d.receipt.payloadSHA256) || !digest.test(d.receipt.sharedEventDigest) ||
            d.historyDigest !== d.receipt.sharedEventDigest || !digest.test(d.soulDigest) || !integer(d.bytes) || d.bytes < 1 || d.bytes > 16777216 ||
            d.count !== Math.ceil(Math.ceil(d.bytes / 3) * 4 / 12000) || !object(d.files) || Object.keys(d.files).length > 256 ||
            !cursor(d.received, root.owners) || !cursor(d.applied, root.owners) || !cursor(d.durable, root.owners) ||
            !covers(d.received,d.applied) || !covers(d.received,d.durable) ||
            op.source.kind==="builtin"&&d.trainer.id!==op.identities[owner].localSeed) fail("descriptor");
        for (const required of ["game.sav","checkpoint.state","memory-files.json","shared-events.json"]) if (!d.files[required]) fail("files");
        Object.keys(d.files).forEach(function (key) { const f=d.files[key]; if (!object(f) || !digest.test(f.sha256) || !integer(f.bytes)) fail("files"); });
        if (op.cut && (d.cutDigest !== op.cut.digest || !equal(d.applied,op.cut.cursor) || !covers(d.received,op.cut.cursor) || !covers(d.durable,op.cut.cursor))) fail("history_cut");
        if (!op.cut && d.cutDigest != null) fail("history_cut");
        bookmark(nk, d.bookmark, owner,root.bookmarks&&root.bookmarks[owner]);
    }
    export function bytesFor(nk: nkruntime.Nakama, key: string, descriptor: any): {text:string,payload:any} {
        const chunks: string[] = [];
        for(let i=0;i<descriptor.count;i++) { const chunk=read(nk,key+"/"+i,payloads); if(!chunk) fail("partial_upload"); chunks.push(chunk.value.data); }
        const bytes=nk.base64Decode(chunks.join("")),text=nk.binaryToString(bytes);
        if(bytes.byteLength!==descriptor.bytes || nk.sha256Hash(text)!==descriptor.receipt.payloadSHA256) fail("payload_hash");
        let value:any;try {value=JSON.parse(text);}catch(_){fail("payload");}
        return {text:text,payload:value};
    }
    export function binaryHash(nk:nkruntime.Nakama,base64:string):string {
        // Nakama's sha256Hash accepts UTF-8 strings. pgcrypto hashes native
        // state/battery bytes without a lossy binary-to-Unicode conversion.
        const rows=nk.sqlQuery("SELECT encode(extensions.digest(decode($1,'base64'),'sha256'),'hex') AS hash",[base64]);
        if(rows.length!==1||!digest.test(rows[0].hash))fail("hash_unavailable");
        return rows[0].hash;
    }
    export function validatePayload(nk:nkruntime.Nakama,root:any,op:any,owner:string,d:any,value:any):any[] {
        if(!object(value)||value.version!==2||!object(value.manifest)||!equal(normalizedIdentity(value.manifest.identity),op.identities[owner])||
            lowerUUID(value.manifest.deviceOwner)!==d.deviceID||lowerUUID(value.checkpoint)!==lowerUUID(d.receipt.checkpoint)||value.sharedEventDigest!==d.historyDigest||
            !object(value.files)||Object.keys(value.files).sort().join(",")!==Object.keys(d.files).sort().join(",")) fail("payload_identity");
        Object.keys(value.files).forEach(function(key){const f=value.files[key],expected=d.files[key];
            if(!object(f)||typeof f.data!=="string"||f.sha256!==expected.sha256)fail("file_hash");
            const b=nk.base64Decode(f.data);if(b.byteLength!==expected.bytes||nk.base64Encode(b)!==f.data||binaryHash(nk,f.data)!==f.sha256)fail("file_hash");});
        const memory=JSON.parse(nk.binaryToString(nk.base64Decode(value.files["memory-files.json"].data)));
        const soul=memory["Soul Link/"+nk.sha256Hash(op.compatibility.gameID)+".json"];
        if(typeof soul!=="string"||binaryHash(nk,soul)!==d.soulDigest)fail("soul_metadata");
        const journal=JSON.parse(nk.binaryToString(nk.base64Decode(value.files["shared-events.json"].data)));
        if(!object(journal)||journal.version!==1||lowerUUID(journal.run)!==op.runID||lowerUUID(journal.owner)!==owner||lowerUUID(journal.partner)!==op.identities[owner].partner||!Array.isArray(journal.events)||journal.events.length>100000)fail("journal");
        if(!equal(normalizedCursor(journal.received),d.received)||!equal(normalizedCursor(journal.applied),d.applied))fail("journal_cursor");
        const seeded:any[]=[],received:any={},seen:any={};let largest=0;
        const source=op.cut?scopedRuntime(nk,null,read(nk,root.sessionID)!,op.cut.sourceGeneration):null;
        for(const raw of journal.events){const event=normalizedEvent(raw),id=event.id.origin+"/"+event.id.sequence;
            if(event.run!==op.runID||root.owners.indexOf(event.id.origin)<0||!integer(event.id.sequence)||event.id.sequence<1||seen[id]||!BoundSaveLibrary.eventValid(nk,event,op.runID))fail("journal_event");
            seen[id]=true;insertCursor(received,event.id.origin,event.id.sequence);
            if(source){const prior=read(source,op.runID+"/"+id,"bound_events_v2");if(!prior||!equal(normalizedEvent(prior.value),event))fail("source_event");}
            if(event.id.origin===owner){seeded.push(event);largest=Math.max(largest,event.id.sequence);}}
        if(!equal({origins:received},d.received)||!integer(journal.nextSequence)||journal.nextSequence<=largest)fail("journal_cursor");
        if(!op.cut&&seeded.length>2304)fail("history_too_large");
        return seeded;
    }
}
