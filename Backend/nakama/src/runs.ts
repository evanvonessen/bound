/// <reference path="../types/nakama-runtime.d.ts" />

// Durable logical runs outlive sockets and match processes. All objects are
// server-owned; a room ticket and the protected account identity are required.
namespace BoundRuns {
    const system = "00000000-0000-0000-0000-000000000000";
    const collection = "bound_runs_v1", chunks = "bound_run_chunks_v1";
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    const digest = /^[0-9a-f]{64}$/;
    const maximumBytes = 16 * 1024 * 1024, chunkLength = 12000;
    interface Participant { identity: any; history: string; bits: string; world?: any; }
    interface Upload { receipt: any; count: number; bytes: number; }
    interface Checkpoint { id: string; predecessor: string | null; history: string; uploads: { [owner: string]: Upload }; reservations?: { [owner: string]: boolean }; }
    interface Run {
        version: number; roomID: string; members: string[]; setup: string;
        participants: { [owner: string]: Participant }; head: Checkpoint | null;
        pending: Checkpoint | null; baseline: { [owner: string]: { id: string | null; history: string | null } };
        ended: boolean; revision: number;
    }
    function fail(message: string): never { throw { message: message, code: 9 }; }
    function object(value: any): boolean { return value !== null && typeof value === "object" && !Array.isArray(value); }
    function integer(value: any): boolean { return typeof value === "number" && isFinite(value) && value === Math.floor(value); }
    function id(value: any): boolean { return typeof value === "string" && uuid.test(value); }
    function hash(value: any): boolean { return typeof value === "string" && digest.test(value); }
    function copy<T>(value: T): T { return JSON.parse(JSON.stringify(value)); }
    // Nakama materializes JSONB through Go maps; key order can change on every
    // read. Object equality must never depend on JSON.stringify insertion order.
    function canonical(value: any): string {
        if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
        if (object(value)) return "{" + Object.keys(value).sort().map(function (key) {
            return JSON.stringify(key) + ":" + canonical(value[key]);
        }).join(",") + "}";
        return JSON.stringify(value);
    }
    function ref(key: string, which: string = collection): nkruntime.StorageReadRequest { return { collection: which, key: key, userId: system }; }
    function read(nk: nkruntime.Nakama, key: string, which: string = collection): nkruntime.StorageObject | null {
        const values = nk.storageRead([ref(key, which)]); return values.length ? values[0] : null;
    }
    function write(nk: nkruntime.Nakama, key: string, value: any, version: string, which: string = collection): void {
        nk.storageWrite([{ collection: which, key: key, userId: system, value: value, version: version, permissionRead: 0, permissionWrite: 0 }]);
    }
    function setup(identity: any, owner: string, ticket: BoundRooms.Ticket, run: string): string {
        if (!object(identity) || identity.run.toLowerCase() !== run || identity.owner.toLowerCase() !== owner ||
            !id(identity.partner.toLowerCase()) || ticket.members.indexOf(identity.partner.toLowerCase()) < 0 ||
            identity.partner.toLowerCase() === owner || identity.roomID.toLowerCase() !== ticket.roomID ||
            typeof identity.gameID !== "string" || !identity.gameID.length || identity.gameID.length > 256 ||
            !hash(identity.romSHA256) || identity.protocolVersion !== 1 || identity.saveVersion !== 1 ||
            typeof identity.settings !== "string" || identity.settings.length > 128 ||
            !integer(identity.localSeed) || !integer(identity.partnerSeed) || identity.localSeed <= 0 || identity.partnerSeed <= 0 ||
            identity.localSeed > 4294967295 || identity.partnerSeed > 4294967295 || identity.localSeed === identity.partnerSeed ||
            [owner, identity.partner.toLowerCase()].indexOf(identity.settingsOwner.toLowerCase()) < 0) fail("Invalid run identity");
        const first = owner < identity.partner.toLowerCase();
        return JSON.stringify([identity.romSHA256, identity.protocolVersion, identity.saveVersion,
            identity.settingsOwner.toLowerCase(), identity.settings, first ? identity.localSeed : identity.partnerSeed,
            first ? identity.partnerSeed : identity.localSeed]);
    }
    function view(state: Run): any {
        return { version: 1, revision: state.revision, ended: state.ended, head: state.head,
            pending: state.pending, participants: state.participants, baseline: state.baseline };
    }
    function receipt(value: any, owner: string, run: string, pending: Checkpoint): boolean {
        return object(value) && value.run.toLowerCase() === run && value.owner.toLowerCase() === owner &&
            value.checkpoint.toLowerCase() === pending.id && value.sharedEventDigest === pending.history && hash(value.payloadSHA256);
    }
    function chunkKey(run: string, checkpoint: string, owner: string, index: number): string {
        return run + "/" + checkpoint + "/" + owner + "/" + index;
    }
    export const rpc: nkruntime.RpcFunction = function (ctx, _logger, nk, payload) {
        if (!payload || payload.length > 18000) fail("Invalid run request");
        const request = JSON.parse(payload);
        const ticket = BoundRooms.authorize(ctx, nk, request.ticket), owner = ticket.ownerID;
        if (!id(request.runID) || typeof request.action !== "string") fail("Invalid run request");
        const runID = request.runID;
        for (let attempt = 0; attempt < 4; attempt++) {
            const record = read(nk, runID);
            let state: Run;
            if (record) {
                state = copy(record.value) as Run;
                if (state.roomID !== ticket.roomID || state.members.indexOf(owner) < 0 ||
                    state.members.some(function (member) { return ticket.members.indexOf(member) < 0; })) fail("Run access denied");
            } else {
                if (request.action !== "session") fail("Run is not registered");
                const canonical = setup(request.identity, owner, ticket, runID);
                state = { version: 1, roomID: ticket.roomID, members: [owner, request.identity.partner.toLowerCase()].sort(),
                    setup: canonical, participants: {}, head: null, pending: null, baseline: {}, ended: false, revision: 0 };
            }
            if (state.ended && request.action !== "session" && request.action !== "download" && request.action !== "end") fail("Run has ended");
            if (state.ended && (request.action === "session" || request.action === "end")) return JSON.stringify(view(state));
            let changed = false;
            if (request.action === "session") {
                if (setup(request.identity, owner, ticket, runID) !== state.setup || !hash(request.history) ||
                    typeof request.bits !== "string" || request.bits.length > 8192) fail("Run identity or history conflict");
                const participant: Participant = { identity: request.identity, history: request.history, bits: request.bits };
                if (request.world !== undefined) {
                    const world = request.world;
                    if (!object(world) || !integer(world.group) || world.group < 0 || world.group >= 43 ||
                        !integer(world.number) || world.number < 0 || world.number > 255 ||
                        typeof world.checkpoints !== "string" || world.checkpoints.length > 1068 || nk.base64Decode(world.checkpoints).byteLength !== 800 ||
                        typeof world.boulders !== "string" || world.boulders.length > 128 || nk.base64Decode(world.boulders).byteLength % 6 !== 0) fail("Invalid world snapshot");
                    participant.world = world;
                } else if (state.participants[owner] && state.participants[owner].world) {
                    participant.world = state.participants[owner].world;
                }
                const previousParticipant = state.participants[owner];
                if (previousParticipant) {
                    const before = new Uint8Array(nk.base64Decode(previousParticipant.bits));
                    const after = new Uint8Array(nk.base64Decode(request.bits));
                    if (before.length !== after.length) fail("History shape changed");
                    for (let i = 0; i < before.length; i++) {
                        if ((before[i] & after[i]) !== before[i]) fail("Recorded progress cannot be removed");
                    }
                    if (previousParticipant.bits === request.bits && previousParticipant.history !== request.history) fail("History digest changed without progress");
                }
                if (canonical(state.participants[owner]) !== canonical(participant)) {
                    state.participants[owner] = participant; changed = true;
                }
                if (!state.baseline[owner]) {
                    if (request.checkpoint != null && !id(request.checkpoint) || request.checkpointHistory != null && !hash(request.checkpointHistory) ||
                        (request.checkpoint == null) !== (request.checkpointHistory == null)) fail("Invalid baseline");
                    state.baseline[owner] = { id: request.checkpoint || null, history: request.checkpointHistory || null }; changed = true;
                }
                const pending = state.pending;
                if (pending && !Object.keys(pending.uploads).length && !Object.keys(pending.reservations || {}).length && state.members.every(function (member) {
                    return !!state.participants[member] && state.participants[member].history === request.history &&
                        !read(nk, chunkKey(runID, pending.id, member, -1), chunks);
                }) && pending.history !== request.history) { pending.history = request.history; changed = true; }
            } else if (request.action === "begin") {
                if (!state.members.every(function (member) { return !!state.participants[member] && state.participants[member].history === request.history; }) ||
                    !hash(request.history)) fail("Waiting for matching player history");
                const baselines = state.members.map(function (member) { return state.baseline[member]; });
                const predecessor = state.head ? state.head.id : baselines[0].id;
                if (request.predecessor !== predecessor || (!state.head && baselines.some(function (base) {
                    return base.id !== baselines[0].id || base.history !== baselines[0].history;
                }))) fail("Checkpoint ancestry conflict");
                if (!state.pending) {
                    state.pending = { id: nk.uuidv4(), predecessor: predecessor, history: request.history, uploads: {}, reservations: {} }; changed = true;
                }
            } else if (request.action === "prepare") {
                if (!state.pending || state.pending.id !== request.checkpoint || state.pending.history !== request.history) fail("Checkpoint is not pending");
                const reservations = state.pending.reservations || {};
                if (!reservations[owner]) { reservations[owner] = true; state.pending.reservations = reservations; changed = true; }
            } else if (request.action === "cancel") {
                if (state.pending && state.pending.id === request.checkpoint) {
                    if (Object.keys(state.pending.uploads).length || Object.keys(state.pending.reservations || {}).length || state.members.some(function (member) {
                        return read(nk, chunkKey(runID, state.pending!.id, member, -1), chunks) !== null;
                    })) fail("A stored checkpoint must be recovered");
                    state.pending = null; changed = true;
                }
            } else if (request.action === "upload" || request.action === "chunk" || request.action === "seal") {
                const pending = state.pending;
                if (!pending || request.checkpoint !== pending.id) {
                    if (state.head && state.head.id === request.checkpoint) return JSON.stringify(view(state));
                    fail("Checkpoint is not pending");
                }
                if (!pending.reservations || !pending.reservations[owner]) fail("Checkpoint capture is not reserved");
                if (!receipt(request.receipt, owner, runID, pending)) fail("Invalid checkpoint receipt");
                const descriptor: Upload = { receipt: request.receipt, count: request.count, bytes: request.bytes };
                if (!integer(request.bytes) || request.bytes < 1 || request.bytes > maximumBytes || !integer(request.count) ||
                    request.count !== Math.ceil(Math.ceil(request.bytes / 3) * 4 / chunkLength)) fail("Invalid upload size");
                const key = chunkKey(runID, pending.id, owner, -1), previous = read(nk, key, chunks);
                if (previous && canonical(previous.value) !== canonical(descriptor)) fail("Immutable upload conflict");
                if (request.action === "upload") {
                    if (!previous) write(nk, key, descriptor, "*", chunks);
                } else {
                    if (!previous) fail("Upload not initialized");
                    if (request.action === "chunk") {
                        if (!integer(request.index) || request.index < 0 || request.index >= descriptor.count ||
                            typeof request.data !== "string" || request.data.length !== Math.min(chunkLength, Math.ceil(descriptor.bytes / 3) * 4 - request.index * chunkLength) ||
                            !/^[A-Za-z0-9+/]*={0,2}$/.test(request.data)) fail("Invalid upload chunk");
                        const partKey = chunkKey(runID, pending.id, owner, request.index), part = read(nk, partKey, chunks);
                        if (part && part.value.data !== request.data) fail("Immutable chunk conflict");
                        if (!part) write(nk, partKey, { data: request.data }, "*", chunks);
                    } else {
                        const data: string[] = [];
                        for (let i = 0; i < descriptor.count; i++) {
                            const part = read(nk, chunkKey(runID, pending.id, owner, i), chunks);
                            if (!part) fail("Upload is incomplete");
                            data.push(part.value.data);
                        }
                        const binary = nk.base64Decode(data.join("")), json = nk.binaryToString(binary);
                        if (binary.byteLength !== descriptor.bytes || nk.sha256Hash(json) !== request.receipt.payloadSHA256) fail("Checkpoint checksum mismatch");
                        const saved = JSON.parse(json), identity = saved.manifest && saved.manifest.identity;
                        if (!identity || setup(identity, owner, ticket, runID) !== state.setup ||
                            saved.checkpoint.toLowerCase() !== pending.id || (saved.predecessor ? saved.predecessor.toLowerCase() : null) !== pending.predecessor ||
                            saved.sharedEventDigest !== pending.history || !saved.files || !saved.files["game.sav"] || !saved.files["checkpoint.state"]) fail("Invalid checkpoint package");
                        pending.uploads[owner] = descriptor; changed = true;
                        if (state.members.every(function (member) { return !!pending.uploads[member]; })) {
                            state.head = pending; state.pending = null;
                        }
                    }
                }
            } else if (request.action === "download") {
                if (!state.head || request.checkpoint !== state.head.id || !state.head.uploads[owner] ||
                    !integer(request.index) || request.index < 0 || request.index >= state.head.uploads[owner].count) fail("Checkpoint is unavailable");
                const part = read(nk, chunkKey(runID, state.head.id, owner, request.index), chunks);
                if (!part) fail("Checkpoint is unavailable");
                return JSON.stringify({ data: part.value.data });
            } else if (request.action === "end") { state.ended = true; changed = true; }
            else fail("Unknown run action");
            if (!changed) return JSON.stringify(view(state));
            state.revision++;
            try { write(nk, runID, state, record ? record.version : "*"); return JSON.stringify(view(state)); }
            catch (_) { if (attempt === 3) fail("Run changed; retry"); }
        }
        fail("Run changed; retry");
    };
}
function boundRunRPC(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, payload: string): string {
    return BoundRuns.rpc(ctx, logger, nk, payload) as string;
}
