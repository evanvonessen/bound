/// <reference path="../types/nakama-runtime.d.ts" />

// This is a directory and authorization layer over independent.ts, not another
// snapshot store. Every permanent save_id is the existing version-two run key.
namespace BoundSaveLibrary {
    const collection = "bound_independent_v2", requests = "bound_save_requests_v1";
    const system = "00000000-0000-0000-0000-000000000000";
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    function fail(message: string): never { throw { message: message, code: 9 }; }
    function read(nk: nkruntime.Nakama, key: string, bucket: string = collection): nkruntime.StorageObject | null {
        const records = nk.storageRead([{ collection: bucket, key: key, userId: system }]); return records[0] || null;
    }
    function write(key: string, value: any, version: string, bucket: string = collection): nkruntime.StorageWriteRequest {
        return { collection: bucket, key: key, userId: system, value: value, version: version, permissionRead: 0, permissionWrite: 0 };
    }
    export function timestamp(): string { return new Date().toISOString(); }
    export function profile(value: any): boolean {
        return !!value && typeof value === "object" && !Array.isArray(value) && Object.keys(value).sort().join(",") === "gender,name" &&
            typeof value.name === "string" && /^[A-Za-z0-9]{1,7}$/.test(value.name) && (value.gender === 0 || value.gender === 1);
    }
    export function eventValid(nk: nkruntime.Nakama, event: any, runID: string): boolean {
        if (["world", "soul"].indexOf(event.kind) < 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(event.payload) || event.payload.length % 4 !== 0) return false;
        let value: any;
        try { value = JSON.parse(nk.binaryToString(nk.base64Decode(event.payload))); } catch (_) { return false; }
        if (!value || typeof value !== "object" || Array.isArray(value)) return false;
        if (event.kind === "soul") {
            if (value.version !== 1 || String(value.run).toLowerCase() !== runID || ["acquired", "death", "ended"].indexOf(value.kind) < 0) return false;
            if (value.kind === "ended") return value.slot == null;
            if (typeof value.slot !== "string" || !/^(area|egg):(0|[1-9][0-9]{0,3})$/.test(value.slot)) return false;
            const parts = value.slot.split(":"), slot = Number(parts[1]);
            return parts[0] === "area" ? slot <= 255 : slot >= 1 && slot <= 2048;
        }
        if (typeof value.group !== "number" || value.group !== Math.floor(value.group) || value.group < 0 || value.group >= 43 ||
            typeof value.number !== "number" || value.number !== Math.floor(value.number) || value.number < 0 || value.number > 255 ||
            typeof value.checkpoints !== "string" || value.checkpoints.length > 1068 || typeof value.boulders !== "string" || value.boulders.length > 128) return false;
        try {
            if (nk.base64Decode(value.checkpoints).byteLength !== 800) return false;
            const b = new Uint8Array(nk.base64Decode(value.boulders)), seen: number[] = [];
            if (b.length > 96 || b.length % 6 !== 0) return false;
            for (let i = 0; i < b.length; i += 6) {
                if (!b[i] || b[i] === 255 || b[i + 1] >= 16 || seen.indexOf(b[i]) >= 0) return false;
                seen.push(b[i]);
            }
            return true;
        } catch (_) { return false; }
    }
    export function metadata(state: any, owner: string): any {
        const identity = JSON.parse(JSON.stringify(state.identity));
        if (identity.owner !== owner) {
            const seed = identity.localSeed; identity.localSeed = identity.partnerSeed; identity.partnerSeed = seed;
            identity.owner = owner; identity.partner = state.identity.owner;
        }
        return { save_id: state.save_id, game_id: state.game_id, roomID: state.roomID, participants: state.members,
            identity: identity, revision: state.revision, created_at: state.created_at, updated_at: state.updated_at,
            profiles: state.profiles || {}, saves: state.saves, gameOver: gameOverView(state) };
    }
    function gameOverView(state: any): any {
        return state.gameOver ? { id: state.gameOver.id, returnRequested: state.gameOver.returnRequested,
            returned: state.gameOver.returned, deleted: state.deleted === true } : null;
    }
    function cleanup(nk: nkruntime.Nakama, runID: string): void {
        nk.sqlExec("DELETE FROM storage WHERE user_id = $1::uuid AND collection IN ('bound_independent_v2','bound_events_v2') AND key LIKE $2", [system, runID + "/%"]);
    }
    function gameOver(nk: nkruntime.Nakama, request: any, owner: string): string {
        if (!uuid.test(String(request.runID)) || request.eventID !== undefined && !uuid.test(String(request.eventID)) ||
            request.action !== "gameOverStatus" && !uuid.test(String(request.eventID))) fail("Invalid game over identity");
        for (let attempt = 0; attempt < 5; attempt++) {
            const record = read(nk, request.runID);
            const state = record && JSON.parse(JSON.stringify(record.value));
            if (!state || state.save_id !== request.runID || !Array.isArray(state.members) || state.members.length !== 2 ||
                state.members[0] === state.members[1] || state.members.indexOf(owner) < 0) fail("Save access denied");
            if (state.gameOver && request.action !== "gameOver" && request.eventID !== undefined && request.eventID !== state.gameOver.id) fail("Game over changed");
            if (state.deleted) {
                if (!state.gameOver) fail("Save was deleted");
                cleanup(nk, request.runID);
                return JSON.stringify(gameOverView(state));
            }
            let changed = false;
            if (request.action === "gameOver") {
                if (!state.gameOver) {
                    if (!state.committed || state.cancelled || !state.identity || !settingsPermitDeletion(nk, state.identity.settings)) fail("Game over deletion is disabled");
                    state.gameOver = { id: request.eventID, returnRequested: false, returned: [] }; changed = true;
                }
            } else {
                if (!state.gameOver) fail("Game over is unavailable");
                if (request.action === "gameOverReturn" && !state.gameOver.returnRequested) { state.gameOver.returnRequested = true; changed = true; }
                if (request.action === "gameOverMenu") {
                    if (!state.gameOver.returnRequested) fail("Return to menu has not been requested");
                    if (state.gameOver.returned.indexOf(owner) < 0) {
                        state.gameOver.returned.push(owner); state.gameOver.returned.sort(); changed = true;
                    }
                }
            }
            if (!changed) return JSON.stringify(gameOverView(state));
            state.revision++;
            const complete = state.members.every(function (member: string) { return state.gameOver.returned.indexOf(member) >= 0; });
            // Both independently authenticated menu acknowledgements must win
            // the parent CAS before either player's saved data can be deleted.
            const next = complete ? { version: 2, save_id: state.save_id, members: state.members,
                deleted: true, revision: state.revision, gameOver: state.gameOver } : state;
            try { nk.storageWrite([write(request.runID, next, record!.version)]); }
            catch (_) { if (attempt === 4) fail("Game over changed; retry"); continue; }
            if (complete) cleanup(nk, request.runID);
            return JSON.stringify(gameOverView(next));
        }
        fail("Game over changed; retry");
    }
    function settingsPermitDeletion(nk: nkruntime.Nakama, settings: string): boolean {
        if (!BoundIndependent.settingsValid(nk, settings)) return false;
        const b = new Uint8Array(nk.base64Decode(settings));
        return b[0] < 5 || b[21] === 0;
    }
    export function admission(ctx: nkruntime.Context, nk: nkruntime.Nakama, request: any): BoundRooms.Ticket {
        const authorization = BoundRooms.authorizeSave(ctx, nk, request.saveTicket);
        const record = read(nk, request.runID), state = record && record.value;
        if (!state || !state.save_id || state.deleted || state.members.indexOf(authorization.ownerID) < 0) fail("Save is unavailable");
        // The durable participant list, not transient friendship/room presence,
        // authorizes all later access. A library ticket never admits a live match.
        return { version: 1, protocol: "bound-room-v1", ownerID: authorization.ownerID,
            roomID: state.roomID, members: state.members, issuedAt: authorization.issuedAt, expiresAt: authorization.expiresAt };
    }
    export function library(ctx: nkruntime.Context, nk: nkruntime.Nakama, request: any): string | null {
        if (["list", "create", "delete", "gameOver", "gameOverReturn", "gameOverMenu", "gameOverStatus"].indexOf(request.action) < 0) return null;
        const ticket = BoundRooms.authorizeSave(ctx, nk, request.saveTicket), owner = ticket.ownerID;
        if (request.action.indexOf("gameOver") === 0) return gameOver(nk, request, owner);
        if (request.action === "list") {
            if (typeof request.gameID !== "string" || !request.gameID.length || request.gameID.length > 256 ||
                (request.cursor != null && !uuid.test(String(request.cursor)))) fail("Invalid save listing");
            // Filtering roots in PostgreSQL avoids scanning megabytes of chunks
            // and does not require a second, potentially inconsistent save index.
            const rows = nk.sqlQuery("SELECT key FROM storage WHERE collection = $1 AND user_id = $2::uuid AND value->>'save_id' IS NOT NULL AND value->>'deleted' IS DISTINCT FROM 'true' AND value->>'game_id' = $3 AND value->'members' ? $4 AND key > $5 ORDER BY key LIMIT 101",
                [collection, system, request.gameID, owner, request.cursor || ""]);
            const keys = rows.slice(0, 100).map(function (row: any) { return row.key as string; });
            // SQL JSONB values are driver-specific binary values in the live
            // runtime. storageRead supplies decoded JSON and may reorder rows.
            const states: { [key: string]: any } = {};
            if (keys.length) nk.storageRead(keys.map(function (key: string) {
                return { collection: collection, key: key, userId: system };
            })).forEach(function (record: nkruntime.StorageObject) { states[record.key] = record.value; });
            const page: any[] = [];
            keys.forEach(function (key: string) {
                const state = states[key];
                // A shared run can be removed after the query selected its key.
                if (!state || state.deleted) return;
                if (state.save_id !== key || state.game_id !== request.gameID || !Array.isArray(state.members) ||
                    state.members.indexOf(owner) < 0 || !state.identity) fail("Save metadata is unavailable");
                page.push(metadata(state, owner));
            });
            return JSON.stringify({ version: 2, runs: page, cursor: rows.length > 100 ? keys[keys.length - 1] : null });
        }
        if (request.action === "create") {
            if (!uuid.test(String(request.request_id)) || request.partnerID !== ticket.partnerID || !ticket.roomID ||
                typeof request.gameID !== "string" || !request.gameID.length || request.gameID.length > 256 ||
                !/^[0-9a-f]{64}$/.test(String(request.romSHA256)) || typeof request.settings !== "string" ||
                !BoundIndependent.settingsValid(nk, request.settings) || request.profile !== undefined && !profile(request.profile) ||
                request.partnerProfile !== undefined && !profile(request.partnerProfile)) fail("Invalid new save configuration");
            const key = owner + "/" + request.request_id;
            const choices = [request.partnerID, request.gameID, request.romSHA256, request.settings,
                request.profile ? [request.profile.name, request.profile.gender] : null];
            // Preserve existing request fingerprints for clients that chose
            // only their own trainer; new clients commit both profiles.
            if (request.partnerProfile !== undefined) choices.push([request.partnerProfile.name, request.partnerProfile.gender]);
            const configuration = nk.sha256Hash(JSON.stringify(choices));
            for (let attempt = 0; attempt < 5; attempt++) {
                const previous = read(nk, key, requests);
                if (previous) {
                    if (previous.value.configuration !== configuration) fail("Creation request changed");
                    const stored = read(nk, previous.value.save_id);
                    if (!stored || stored.value.deleted) fail("Save was deleted");
                    return JSON.stringify(BoundIndependent.view(stored.value as any, [], owner));
                }
                const saveID = nk.uuidv4(), first = parseInt(nk.uuidv4().substr(0, 8), 16) || 1;
                let second = parseInt(nk.uuidv4().substr(0, 8), 16) || 1;
                if (second === first) second = first === 4294967295 ? 1 : first + 1;
                const now = timestamp();
                const state: any = { version: 2, save_id: saveID, game_id: request.gameID, roomID: ticket.roomID,
                    members: [owner, request.partnerID].sort(), identity: { run: saveID, gameID: request.gameID, owner: owner,
                        partner: request.partnerID, roomID: ticket.roomID, settingsOwner: owner, settings: request.settings,
                        localSeed: first, partnerSeed: second, romSHA256: request.romSHA256, protocolVersion: 1, saveVersion: 1 },
                    committed: true, cancelled: false, epoch: 1, revision: 1, chooserSeen: BoundRooms.seconds(),
                    cursors: {}, saves: {}, deliveries: {}, profiles: {}, created_at: now, updated_at: now };
                if (request.profile) state.profiles[owner] = request.profile;
                if (request.partnerProfile) state.profiles[request.partnerID] = request.partnerProfile;
                try {
                    // Nakama storage batches are atomic: creation retries cannot
                    // allocate orphan/duplicate runs after a lost response.
                    nk.storageWrite([write(saveID, state, "*"), write(key, { save_id: saveID, configuration: configuration }, "*", requests)]);
                    return JSON.stringify(BoundIndependent.view(state, [], owner));
                } catch (_) { if (attempt === 4) fail("Save creation changed; retry"); }
            }
        }
        if (!uuid.test(String(request.runID)) || request.confirmSharedDeletion !== true) fail("Shared deletion confirmation required");
        for (let attempt = 0; attempt < 5; attempt++) {
            const record = read(nk, request.runID), state = record && record.value;
            if (!state || !state.save_id || state.members.indexOf(owner) < 0) fail("Save access denied");
            if (!state.deleted) {
                if (state.gameOver) fail("Both players must return to the menu before deletion");
                if (request.expectedRevision !== state.revision) fail("Save changed; refresh before deleting");
                // Retain only an access/replay tombstone; no gameplay snapshots,
                // identity, profile, or event data survives confirmed deletion.
                const tombstone = { version: 2, save_id: state.save_id, members: state.members, deleted: true, revision: state.revision + 1 };
                try { nk.storageWrite([write(request.runID, tombstone, record!.version)]); }
                catch (_) { if (attempt === 4) fail("Save changed; refresh before deleting"); continue; }
            }
            // Child writes atomically CAS the parent (guardedWrite), so nothing
            // can recreate data after the tombstone wins. A deletion retry also
            // completes cleanup if a previous connection ended after the CAS.
            cleanup(nk, request.runID);
            return JSON.stringify({ save_id: request.runID, deleted: true });
        }
        fail("Save changed; retry");
    }
    export function guardedWrite(nk: nkruntime.Nakama, runID: string, key: string, value: any, version: string, bucket: string): void {
        for (let attempt = 0; attempt < 5; attempt++) {
            const record = read(nk, runID);
            if (!record || record.value.deleted || record.value.gameOver) fail("Run is over");
            try {
                nk.storageWrite([write(runID, record.value, record.version), write(key, value, version, bucket)]);
                return;
            } catch (_) {
                const existing = read(nk, key, bucket);
                if (existing) throw { message: "Immutable save data conflict", code: 9 };
                if (attempt === 4) fail("Save changed; retry");
            }
        }
    }
}
