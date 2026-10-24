/// <reference path="../types/nakama-runtime.d.ts" />

// Version two never interprets a transport acknowledgement as permission to play.
// Setup is one CAS-protected document. Events and each player's saves are durable
// independently of the other player's socket, progress, or save generation.
namespace BoundIndependent {
    const collection = "bound_independent_v2", eventCollection = "bound_events_v2";
    const system = "00000000-0000-0000-0000-000000000000";
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    const digest = /^[0-9a-f]{64}$/;
    interface Cursor { contiguous: number; sparse: number[]; }
    interface Run {
        version: number; roomID: string; members: string[]; identity: any;
        committed: boolean; cancelled: boolean; epoch: number; revision: number;
        chooserSeen: number; cursors: { [origin: string]: Cursor };
        saves: { [owner: string]: any }; deliveries: { [owner: string]: { [origin: string]: number } };
        legacyHistory?: { [owner: string]: { history: string; bits: string } };
    }
    function fail(message: string): never { throw { message: message, code: 9 }; }
    function id(value: any): boolean { return typeof value === "string" && uuid.test(value); }
    function integer(value: any): boolean { return typeof value === "number" && isFinite(value) && value >= 0 && value <= 9007199254740991 && Math.floor(value) === value; }
    function canonical(value: any): string {
        if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
        if (value !== null && typeof value === "object") return "{" + Object.keys(value).sort().map(function (key) { return JSON.stringify(key) + ":" + canonical(value[key]); }).join(",") + "}";
        return JSON.stringify(value);
    }
    function read(nk: nkruntime.Nakama, key: string, bucket: string = collection): nkruntime.StorageObject | null {
        const values = nk.storageRead([{ collection: bucket, key: key, userId: system }]); return values.length ? values[0] : null;
    }
    function write(nk: nkruntime.Nakama, key: string, value: any, version: string, bucket: string = collection): void {
        nk.storageWrite([{ collection: bucket, key: key, userId: system, value: value, version: version, permissionRead: 0, permissionWrite: 0 }]);
    }
    function identity(value: any, owner: string, ticket: BoundRooms.Ticket, run: string): any {
        if (!value || typeof value !== "object" || typeof value.owner !== "string" || typeof value.partner !== "string" ||
            value.owner.toLowerCase() !== owner || !id(value.partner.toLowerCase()) || value.partner.toLowerCase() === owner ||
            ticket.members.indexOf(value.partner.toLowerCase()) < 0 || String(value.run).toLowerCase() !== run ||
            String(value.roomID).toLowerCase() !== ticket.roomID || !digest.test(value.romSHA256) ||
            value.protocolVersion !== 1 || value.saveVersion !== 1 || typeof value.gameID !== "string" || !value.gameID.length || value.gameID.length > 256 ||
            typeof value.settings !== "string" || value.settings.length > 128 ||
            !integer(value.localSeed) || !integer(value.partnerSeed) || !value.localSeed || !value.partnerSeed ||
            value.localSeed > 4294967295 || value.partnerSeed > 4294967295 || value.localSeed === value.partnerSeed ||
            [owner, value.partner.toLowerCase()].indexOf(String(value.settingsOwner).toLowerCase()) < 0) fail("Invalid shared configuration");
        const result = JSON.parse(JSON.stringify(value));
        for (const key of ["run", "owner", "partner", "settingsOwner", "roomID"]) result[key] = result[key].toLowerCase();
        return result;
    }
    function shared(value: any): string {
        const first = value.owner < value.partner;
        return canonical([value.run, value.roomID, value.romSHA256, value.protocolVersion, value.saveVersion,
            first ? value.owner : value.partner, first ? value.partner : value.owner,
            first ? value.localSeed : value.partnerSeed, first ? value.partnerSeed : value.localSeed]);
    }
    function settingsValid(nk: nkruntime.Nakama, text: string): boolean {
        const b = new Uint8Array(nk.base64Decode(text));
        if (b.length !== 32 || b[0] !== 4) return false;
        for (let i = 1; i <= 11; i++) if (b[i] > 1) return false;
        if (b[2] + b[3] + b[4] > 1 || b[6] && b[7] || b[20] > 1) return false;
        let end = false;
        for (let i = 12; i < 20; i++) { if (b[i] === 255) end = true; else if (end || b[i] > 246) return false; }
        if (!end || b[12] === 255) return false;
        for (let i = 21; i < 32; i++) if (b[i]) return false;
        return true;
    }
    function cursor(value?: Cursor): Cursor { return value || { contiguous: 0, sparse: [] }; }
    function legacy(nk: nkruntime.Nakama, runID: string, proposed: any, owner: string, ticket: BoundRooms.Ticket): { [owner: string]: { history: string; bits: string } } | null {
        const record = read(nk, runID, "bound_runs_v1");
        if (!record) return null;
        const state = record.value;
        if (!state || state.version !== 1 || state.ended || state.roomID !== ticket.roomID ||
            !Array.isArray(state.members) || state.members.length !== 2 || state.members.indexOf(owner) < 0 ||
            state.members.some(function (member: string) { return ticket.members.indexOf(member) < 0; }) ||
            !state.participants || !state.participants[owner]) fail("Legacy run needs its original owner and configuration");
        const original = identity(state.participants[owner].identity, owner, ticket, runID);
        if (shared(original) !== shared(proposed) || original.settings !== proposed.settings ||
            original.settingsOwner !== proposed.settingsOwner) fail("Legacy run configuration conflict");
        const first = original.owner < original.partner;
        const expected = [original.romSHA256, original.protocolVersion, original.saveVersion, original.settingsOwner,
            original.settings, first ? original.localSeed : original.partnerSeed, first ? original.partnerSeed : original.localSeed];
        if (canonical(JSON.parse(state.setup)) !== canonical(expected)) fail("Legacy run configuration conflict");
        const history: { [owner: string]: { history: string; bits: string } } = {};
        for (const member of state.members) {
            const participant = state.participants[member];
            if (!participant) continue;
            const saved = identity(participant.identity, member, ticket, runID);
            if (shared(saved) !== shared(original) || saved.settings !== original.settings || saved.settingsOwner !== original.settingsOwner ||
                !digest.test(participant.history) || typeof participant.bits !== "string" || nk.base64Decode(participant.bits).byteLength !== 864) fail("Legacy shared history needs recovery");
            history[member] = { history: participant.history, bits: participant.bits };
        }
        return history;
    }
    function admit(c: Cursor, sequence: number): void {
        if (sequence <= c.contiguous || c.sparse.indexOf(sequence) >= 0) return;
        if (c.sparse.length >= 4096 || sequence > c.contiguous + 4096) fail("Event gap is too large");
        c.sparse.push(sequence); c.sparse.sort(function (a, b) { return a - b; });
        while (c.sparse.length && c.sparse[0] === c.contiguous + 1) { c.contiguous++; c.sparse.shift(); }
    }
    function view(state: Run, events: any[] = []): any {
        return { version: 2, identity: state.identity, committed: state.committed, cancelled: state.cancelled,
            epoch: state.epoch, revision: state.revision, cursors: state.cursors, deliveries: state.deliveries || {}, saves: state.saves,
            legacyHistory: state.legacyHistory || {}, events: events };
    }
    export const rpc: nkruntime.RpcFunction = function (ctx, _logger, nk, payload) {
        if (!payload || payload.length > 20000) fail("Invalid independent run request");
        const request = JSON.parse(payload), ticket = BoundRooms.authorize(ctx, nk, request.ticket), owner = ticket.ownerID;
        if (!id(request.runID) || typeof request.action !== "string") fail("Invalid run identity");
        const runID = request.runID, now = Math.floor(Date.now() / 1000);
        for (let attempt = 0; attempt < 5; attempt++) {
            const record = read(nk, runID);
            let state: Run;
            if (!record) {
                if (request.action !== "setup" && request.action !== "migrate" && request.action !== "cancelSetup") fail("Shared setup is unavailable");
                const proposed = identity(request.identity, owner, ticket, runID);
                const migrated = legacy(nk, runID, proposed, owner, ticket);
                if (request.action === "migrate" && !migrated) fail("Legacy run is unavailable");
                state = { version: 2, roomID: ticket.roomID, members: [owner, proposed.partner].sort(), identity: proposed,
                    committed: migrated !== null, cancelled: false, epoch: 1, revision: 0, chooserSeen: now, cursors: {}, saves: {}, deliveries: {},
                    legacyHistory: migrated || {} };
            } else {
                state = JSON.parse(JSON.stringify(record.value));
                if (state.version !== 2 || state.roomID !== ticket.roomID || state.members.indexOf(owner) < 0 ||
                    state.members.some(function (member) { return ticket.members.indexOf(member) < 0; })) fail("Run access denied");
            }
            let changed = !record;
            const events: any[] = [];
            if (request.action === "setup" || request.action === "migrate") {
                const proposed = identity(request.identity, owner, ticket, runID);
                if (shared(proposed) !== shared(state.identity)) fail("Shared setup conflict");
                if (request.action === "migrate" && (!state.committed || proposed.settings !== state.identity.settings ||
                    proposed.settingsOwner !== state.identity.settingsOwner)) fail("Legacy run configuration conflict");
                if (request.action === "migrate" && record) {
                    const latest = legacy(nk, runID, proposed, owner, ticket);
                    if (latest) {
                        const retained = state.legacyHistory || {};
                        for (const member of Object.keys(latest)) {
                            if (retained[member]) {
                                const before = new Uint8Array(nk.base64Decode(retained[member].bits));
                                const after = new Uint8Array(nk.base64Decode(latest[member].bits));
                                for (let i = 0; i < before.length; i++) if ((before[i] & after[i]) !== before[i]) fail("Legacy history cannot regress");
                            }
                            if (canonical(retained[member]) !== canonical(latest[member])) { retained[member] = latest[member]; changed = true; }
                        }
                        state.legacyHistory = retained;
                    }
                }
                if (owner === state.identity.settingsOwner && !state.committed && !state.cancelled) { state.chooserSeen = now; changed = true; }
            } else if (request.action === "draft" || request.action === "commit") {
                if (state.cancelled || request.epoch !== state.epoch || owner !== state.identity.settingsOwner) fail("Setup ownership changed");
                const proposed = identity(request.identity, owner, ticket, runID);
                if (shared(proposed) !== shared(state.identity) || proposed.settingsOwner !== owner) fail("Shared setup conflict");
                if (state.committed) {
                    if (proposed.settings !== state.identity.settings) fail("Configuration is already committed");
                } else {
                    if (request.action === "commit" && !settingsValid(nk, proposed.settings)) fail("Incomplete shared configuration");
                    state.identity = proposed; state.committed = request.action === "commit"; state.chooserSeen = now; changed = true;
                }
            } else if (request.action === "takeover") {
                if (state.committed || state.cancelled || request.authorized !== true || request.epoch !== state.epoch ||
                    owner === state.identity.settingsOwner || now - state.chooserSeen < 30) fail("Setup takeover is unavailable");
                state.identity.settingsOwner = owner; state.epoch++; state.chooserSeen = now; changed = true;
            } else if (request.action === "cancelSetup") {
                // A cancelled local intent may race a successful commit. Tell
                // the client which durable outcome won; never undo that commit.
                if (!state.committed && !state.cancelled) { state.cancelled = true; changed = true; }
            } else if (request.action === "events") {
                if (!state.committed || state.cancelled) fail("Shared setup is incomplete");
                if (!Array.isArray(request.events) || request.events.length > 16 || !request.after || typeof request.after !== "object" || Array.isArray(request.after)) fail("Invalid event batch");
                for (const event of request.events) {
                    if (!event || String(event.run).toLowerCase() !== runID || !event.id || String(event.id.origin).toLowerCase() !== owner ||
                        !integer(event.id.sequence) || event.id.sequence < 1 || typeof event.kind !== "string" || !event.kind.length || event.kind.length > 64 ||
                        typeof event.payload !== "string" || event.payload.length > 8192 || event.idempotencyKey != null && (typeof event.idempotencyKey !== "string" || event.idempotencyKey.length > 512)) fail("Invalid shared event");
                    const stored = { run: runID, id: { origin: owner, sequence: event.id.sequence }, kind: event.kind, payload: event.payload,
                        ...(event.idempotencyKey == null ? {} : { idempotencyKey: event.idempotencyKey }) };
                    const c = cursor(state.cursors[owner]); admit(c, event.id.sequence);
                    const key = runID + "/" + owner + "/" + event.id.sequence, previous = read(nk, key, eventCollection);
                    if (previous && canonical(previous.value) !== canonical(stored)) fail("Immutable event conflict");
                    if (!previous) { try { write(nk, key, stored, "*", eventCollection); } catch (_) { const saved = read(nk, key, eventCollection); if (!saved || canonical(saved.value) !== canonical(stored)) fail("Immutable event conflict"); } }
                    state.cursors[owner] = c; changed = true;
                }
                state.deliveries = state.deliveries || {};
                const delivered: { [origin: string]: number } = {};
                for (const origin of state.members) {
                    const after = request.after[origin] == null ? 0 : request.after[origin], c = cursor(state.cursors[origin]);
                    if (!integer(after)) fail("Invalid event cursor");
                    // The client can have live/offline events the server has not
                    // accepted yet. Its cursor never authorizes dropping them.
                    delivered[origin] = Math.min(after, c.contiguous);
                    const sequences: number[] = [];
                    for (let sequence = after + 1; sequence <= c.contiguous && sequences.length < 16; sequence++) sequences.push(sequence);
                    for (const sequence of c.sparse) if (sequence > after && sequences.length < 16) sequences.push(sequence);
                    for (const sequence of sequences) {
                        const event = read(nk, runID + "/" + origin + "/" + sequence, eventCollection); if (event) events.push(event.value);
                    }
                }
                state.deliveries[owner] = delivered; changed = true;
            } else if (request.action === "save" || request.action === "saveChunk" || request.action === "saveSeal" || request.action === "saveDownload") {
                if (!state.committed || state.cancelled || !id(request.checkpoint)) fail("Save is unavailable");
                const key = runID + "/save/" + owner + "/" + request.checkpoint;
                if (request.action === "saveDownload") {
                    const head = state.saves[owner];
                    if (!head || head.receipt.checkpoint.toLowerCase() !== request.checkpoint || !integer(request.index) || request.index >= head.count) fail("Save is unavailable");
                    const part = read(nk, key + "/" + request.index); if (!part) fail("Save is unavailable");
                    return JSON.stringify(part.value);
                }
                const r = request.receipt;
                if (!r || String(r.owner).toLowerCase() !== owner || String(r.run).toLowerCase() !== runID ||
                    String(r.checkpoint).toLowerCase() !== request.checkpoint || !digest.test(r.payloadSHA256) || !digest.test(r.sharedEventDigest) ||
                    !integer(request.bytes) || !request.bytes || request.bytes > 16 * 1024 * 1024 ||
                    !integer(request.count) || request.count !== Math.ceil(Math.ceil(request.bytes / 3) * 4 / 12000)) fail("Invalid player save");
                const descriptor = { receipt: r, count: request.count, bytes: request.bytes }, previous = read(nk, key);
                if (previous && canonical(previous.value) !== canonical(descriptor)) fail("Immutable player save conflict");
                if (request.action === "save") { if (!previous) write(nk, key, descriptor, "*"); }
                else {
                    if (!previous) fail("Save upload is unavailable");
                    if (request.action === "saveChunk") {
                        if (!integer(request.index) || request.index >= request.count || typeof request.data !== "string" ||
                            request.data.length !== Math.min(12000, Math.ceil(request.bytes / 3) * 4 - request.index * 12000) || !/^[A-Za-z0-9+/]*={0,2}$/.test(request.data)) fail("Invalid save chunk");
                        const part = read(nk, key + "/" + request.index);
                        if (part && part.value.data !== request.data) fail("Immutable save chunk conflict");
                        if (!part) write(nk, key + "/" + request.index, { data: request.data }, "*");
                    } else {
                        const parts: string[] = [];
                        for (let i = 0; i < request.count; i++) { const part = read(nk, key + "/" + i); if (!part) fail("Save upload is incomplete"); parts.push(part.value.data); }
                        const binary = nk.base64Decode(parts.join("")), json = nk.binaryToString(binary);
                        if (binary.byteLength !== request.bytes || nk.sha256Hash(json) !== r.payloadSHA256) fail("Save checksum mismatch");
                        const saved = JSON.parse(json), savedIdentity = identity(saved.manifest.identity, owner, ticket, runID);
                        if (saved.version !== 2 || shared(savedIdentity) !== shared(state.identity) || savedIdentity.settings !== state.identity.settings || savedIdentity.settingsOwner !== state.identity.settingsOwner ||
                            String(saved.checkpoint).toLowerCase() !== request.checkpoint || saved.sharedEventDigest !== r.sharedEventDigest ||
                            !saved.files || !saved.files["game.sav"] || !saved.files["checkpoint.state"]) fail("Invalid player save package");
                        // Optimistic per-player head, independent of partner progress.
                        const head = state.saves[owner], expected = request.expectedHead == null ? null : request.expectedHead;
                        if (expected !== null && !id(expected)) fail("Invalid player save head");
                        if ((!head && expected !== null) || (head && head.receipt.checkpoint.toLowerCase() !== request.checkpoint && head.receipt.checkpoint.toLowerCase() !== expected)) fail("Player save changed; retry");
                        state.saves[owner] = descriptor; changed = true;
                    }
                }
            } else if (request.action !== "get") fail("Unknown independent run action");
            if (!changed) return JSON.stringify(view(state, events));
            state.revision++;
            try { write(nk, runID, state, record ? record.version : "*"); return JSON.stringify(view(state, events)); }
            catch (_) { if (attempt === 4) fail("Run changed; retry"); }
        }
        fail("Run changed; retry");
    };
}
function boundIndependentRPC(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, payload: string): string {
    return BoundIndependent.rpc(ctx, logger, nk, payload) as string;
}
