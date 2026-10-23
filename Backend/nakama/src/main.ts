/// <reference path="../types/nakama-runtime.d.ts" />

// Nakama's JS VM has no Node APIs. Compile to one ES5 script with InitModule
// at global scope; all networking is outside the emulator's frame worker.
namespace BoundRooms {
    export const protocol = "bound-room-v1";
    export const handlerName = "bound_room_v1";
    export const directory = "bound_room_directory_v1";
    const systemUser = "00000000-0000-0000-0000-000000000000";
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    const maxMembers = 8;
    const tickRate = 60;

    export interface Ticket {
        version: 1;
        protocol: string;
        ownerID: string;
        roomID: string;
        members: string[];
        issuedAt: number;
        expiresAt: number;
    }

    interface Bucket { tokens: number; time: number; }
    interface Session {
        ownerID: string;
        presence: nkruntime.Presence;
        expiresAt: number;
        admittedAt: number;
        joined: boolean;
        buckets: { [lane: string]: Bucket };
    }
    export interface State {
        roomID: string;
        members: string[];
        sessions: { [sessionID: string]: Session };
        cleanupToken: string;
        idleSince: number;
        discarded: boolean;
    }
    interface Frame { v: 1; body: string; targetOwnerID?: string; }

    export function seconds(): number { return Math.floor(Date.now() / 1000); }
    function reject(message: string, code: number = 7): never { throw { message: message, code: code }; }
    function object(value: any): boolean { return value !== null && typeof value === "object" && !Array.isArray(value); }
    function integer(value: any): boolean { return typeof value === "number" && isFinite(value) && Math.floor(value) === value; }
    function sameMembers(left: string[], right: string[]): boolean { return left.join(",") === right.join(","); }
    function validMembers(value: any): value is string[] {
        if (!Array.isArray(value) || value.length < 2 || value.length > maxMembers) return false;
        for (let i = 0; i < value.length; i++) {
            if (typeof value[i] !== "string" || !uuid.test(value[i]) || (i > 0 && value[i - 1] >= value[i])) return false;
        }
        return true;
    }
    function equalSignature(left: string, right: string): boolean {
        if (left.length !== right.length) return false;
        let difference = 0;
        for (let i = 0; i < left.length; i++) difference |= left.charCodeAt(i) ^ right.charCodeAt(i);
        return difference === 0;
    }

    export function verifyTicket(ctx: nkruntime.Context, nk: nkruntime.Nakama, value: any): Ticket {
        const secret = ctx.env.BOUND_NAKAMA_BRIDGE_SECRET;
        if (!secret || secret.length < 32) reject("Gameplay bridge is unavailable", 14);
        if (typeof value !== "string" || value.length > 4096) reject("Invalid admission ticket");
        const parts = value.split(".");
        if (parts.length !== 2 || !/^[A-Za-z0-9_-]+$/.test(parts[0]) || !/^[0-9a-f]{64}$/.test(parts[1])) reject("Invalid admission ticket");
        const signature = nk.base16Encode(nk.hmacSha256Hash(parts[0], secret));
        if (!equalSignature(signature, parts[1])) reject("Invalid admission ticket");
        let ticket: any;
        try {
            const decoded = nk.base64UrlDecode(parts[0], false);
            if (nk.base64UrlEncode(decoded, false) !== parts[0]) reject("Invalid admission ticket");
            ticket = JSON.parse(nk.binaryToString(decoded));
        } catch (_) { reject("Invalid admission ticket"); }
        const now = seconds();
        if (!object(ticket) || Object.keys(ticket).sort().join(",") !== "expiresAt,issuedAt,members,ownerID,protocol,roomID,version" ||
            ticket.version !== 1 || ticket.protocol !== protocol ||
            typeof ticket.ownerID !== "string" || !uuid.test(ticket.ownerID) ||
            typeof ticket.roomID !== "string" || !uuid.test(ticket.roomID) ||
            !validMembers(ticket.members) || ticket.members.indexOf(ticket.ownerID) < 0 ||
            !integer(ticket.issuedAt) || !integer(ticket.expiresAt) ||
            ticket.issuedAt > now + 5 || ticket.expiresAt <= now ||
            ticket.expiresAt <= ticket.issuedAt || ticket.expiresAt > ticket.issuedAt + 90) reject("Invalid or expired admission ticket");
        return ticket as Ticket;
    }

    function ownerForUser(ctx: nkruntime.Context, nk: nkruntime.Nakama, userID: string): string {
        const account = nk.accountGetId(userID);
        if (BoundAccounts.enabled(ctx)) {
            if (!uuid.test(userID) || account.user.userId !== userID || account.disableTime || !account.user.metadata.bound_email_confirmed_at || account.user.metadata.bound_deleted_at) reject("Bound account required");
            return userID;
        }
        const customID = account.customId;
        if (typeof customID !== "string" || customID.substr(0, 6) !== "bound:" || !uuid.test(customID.substr(6))) reject("Bound account required");
        return customID.substr(6);
    }

    export const authenticate: nkruntime.BeforeHookFunction<nkruntime.AuthenticateCustomRequest> = function (ctx, _logger, nk, request) {
        const ticket = verifyTicket(ctx, nk, request.account && request.account.vars && request.account.vars.bound_ticket);
        if (!request.account || request.account.id !== "bound:" + ticket.ownerID) reject("Account does not match admission ticket");
        // Never preserve caller-supplied session vars. Match authorization also
        // checks the protected account customId instead of trusting those vars.
        request.account.vars = { bound_owner_id: ticket.ownerID };
        return request;
    };

    function discardCandidate(nk: nkruntime.Nakama, matchID: string, cleanupToken: string): void {
        try { nk.matchSignal(matchID, JSON.stringify({ type: "discard", cleanupToken: cleanupToken })); }
        catch (_) { /* An unclaimed empty candidate also expires after 60s. */ }
    }

    export const roomRPC: nkruntime.RpcFunction = function (ctx, _logger, nk, payload) {
        if (!ctx.userId) reject("Authentication required", 16);
        let request: any;
        try { request = JSON.parse(payload); } catch (_) { reject("Invalid room request", 3); }
        if (!object(request) || Object.keys(request).join(",") !== "ticket") reject("Invalid room request", 3);
        const ticket = verifyTicket(ctx, nk, request.ticket);
        if (ownerForUser(ctx, nk, ctx.userId) !== ticket.ownerID) reject("Account does not match admission ticket");
        const read = { collection: directory, key: ticket.roomID, userId: systemUser };
        for (let attempt = 0; attempt < 3; attempt++) {
            const records = nk.storageRead([read]);
            const existing = records.length ? records[0] : null;
            if (existing && typeof existing.value.matchID === "string") {
                const match = nk.matchGet(existing.value.matchID);
                if (match) {
                    if (!match.authoritative || !Array.isArray(existing.value.members) || !sameMembers(existing.value.members, ticket.members)) reject("Room membership changed");
                    return JSON.stringify({ matchID: match.matchId, roomID: ticket.roomID, protocol: protocol, nakamaUserID: ctx.userId });
                }
            }
            const cleanupToken = nk.uuidv4();
            const matchID = nk.matchCreate(handlerName, { roomID: ticket.roomID, members: ticket.members, cleanupToken: cleanupToken });
            try {
                // '*' is create-only; a read version is compare-and-swap. Only
                // one concurrent allocator can publish this room's match ID.
                nk.storageWrite([{
                    collection: directory, key: ticket.roomID, userId: systemUser,
                    value: { matchID: matchID, members: ticket.members },
                    version: existing ? existing.version : "*", permissionRead: 0, permissionWrite: 0
                }]);
                return JSON.stringify({ matchID: matchID, roomID: ticket.roomID, protocol: protocol, nakamaUserID: ctx.userId });
            } catch (_) { discardCandidate(nk, matchID, cleanupToken); }
        }
        reject("Room allocation is busy; retry shortly", 14);
    };

    function roster(state: State, dispatcher: nkruntime.MatchDispatcher): void {
        const members = state.members.map(function (ownerID) {
            const online = Object.keys(state.sessions).some(function (key) {
                const session = state.sessions[key];
                return session.ownerID === ownerID && session.joined;
            });
            return { ownerID: ownerID, online: online };
        });
        const online = activePresences(state);
        if (online.length) dispatcher.broadcastMessage(4, JSON.stringify({ v: 1, members: members }), online, null, true);
    }

    function activePresences(state: State): nkruntime.Presence[] {
        return Object.keys(state.sessions).filter(function (key) { return state.sessions[key].joined; })
            .map(function (key) { return state.sessions[key].presence; });
    }

    function consume(session: Session, lane: string, rate: number, capacity: number, amount: number, now: number): boolean {
        const bucket = session.buckets[lane] || { tokens: capacity, time: now };
        bucket.tokens = Math.min(capacity, bucket.tokens + Math.max(0, now - bucket.time) * rate);
        bucket.time = now;
        session.buckets[lane] = bucket;
        if (bucket.tokens < amount) return false;
        bucket.tokens -= amount;
        return true;
    }

    function removeSession(state: State, dispatcher: nkruntime.MatchDispatcher, sessionID: string): void {
        const session = state.sessions[sessionID];
        if (!session) return;
        delete state.sessions[sessionID];
        dispatcher.matchKick([session.presence]);
    }

    function targets(state: State, source: Session, frame: Frame): nkruntime.Presence[] {
        return Object.keys(state.sessions).filter(function (key) {
            const target = state.sessions[key];
            return target.joined && target.ownerID !== source.ownerID && (!frame.targetOwnerID || target.ownerID === frame.targetOwnerID);
        }).map(function (key) { return state.sessions[key].presence; });
    }

    function forward(state: State, dispatcher: nkruntime.MatchDispatcher, opcode: number, session: Session, frame: Frame): void {
        const recipients = targets(state, session, frame);
        if (!recipients.length) return;
        const envelope = { v: 1, senderOwnerID: session.ownerID, targetOwnerID: frame.targetOwnerID, body: frame.body };
        dispatcher.broadcastMessage(opcode, JSON.stringify(envelope), recipients, session.presence, opcode !== 1);
    }

    export const match: nkruntime.MatchHandler<State> = {
        matchInit: function (_ctx, _logger, _nk, params) {
            if (typeof params.roomID !== "string" || !uuid.test(params.roomID) || !validMembers(params.members) || typeof params.cleanupToken !== "string") reject("Invalid room initialization", 3);
            return {
                state: { roomID: params.roomID, members: params.members.slice(), sessions: {}, cleanupToken: params.cleanupToken, idleSince: seconds(), discarded: false },
                tickRate: tickRate,
                label: JSON.stringify({ protocol: protocol })
            };
        },
        matchJoinAttempt: function (ctx, _logger, nk, _dispatcher, _tick, state, presence, metadata) {
            try {
                const ticket = verifyTicket(ctx, nk, metadata.bound_ticket);
                if (ticket.roomID !== state.roomID || !sameMembers(ticket.members, state.members) || ownerForUser(ctx, nk, presence.userId) !== ticket.ownerID) reject("Room access denied");
                const duplicate = Object.keys(state.sessions).some(function (key) {
                    return key !== presence.sessionId && state.sessions[key].ownerID === ticket.ownerID && state.sessions[key].expiresAt > seconds();
                });
                if (duplicate) return { state: state, accept: false, rejectMessage: "This player is already connected" };
                state.sessions[presence.sessionId] = {
                    ownerID: ticket.ownerID, presence: presence, expiresAt: ticket.expiresAt,
                    admittedAt: seconds(), joined: false, buckets: {}
                };
                return { state: state, accept: true };
            } catch (_) { return { state: state, accept: false, rejectMessage: "Room access denied or expired" }; }
        },
        matchJoin: function (_ctx, _logger, _nk, dispatcher, _tick, state, presences) {
            presences.forEach(function (presence) {
                const session = state.sessions[presence.sessionId];
                if (session && session.presence.userId === presence.userId && session.expiresAt > seconds()) {
                    session.presence = presence;
                    session.joined = true;
                } else dispatcher.matchKick([presence]);
            });
            state.idleSince = seconds();
            roster(state, dispatcher);
            return { state: state };
        },
        matchLeave: function (_ctx, _logger, _nk, dispatcher, _tick, state, presences) {
            presences.forEach(function (presence) { delete state.sessions[presence.sessionId]; });
            if (!Object.keys(state.sessions).length) state.idleSince = seconds();
            roster(state, dispatcher);
            return { state: state };
        },
        matchLoop: function (ctx, _logger, nk, dispatcher, _tick, state, messages) {
            if (state.discarded) return null;
            const now = seconds();
            let rosterChanged = false;
            Object.keys(state.sessions).forEach(function (key) {
                const session = state.sessions[key];
                if (session.expiresAt <= now || (!session.joined && session.admittedAt + 5 <= now)) {
                    removeSession(state, dispatcher, key);
                    rosterChanged = true;
                }
            });
            const poses: { [key: string]: { session: Session; frame: Frame } } = {};
            messages.forEach(function (message) {
                const session = state.sessions[message.sender.sessionId];
                if (!session || !session.joined || session.presence.userId !== message.sender.userId) return;
                const time = Date.now() / 1000;
                if (message.data.byteLength > 16384 || !consume(session, "bytes", 524288, 786432, message.data.byteLength, time)) {
                    removeSession(state, dispatcher, message.sender.sessionId); rosterChanged = true; return;
                }
                let frame: any;
                try { frame = JSON.parse(nk.binaryToString(message.data)); }
                catch (_) { removeSession(state, dispatcher, message.sender.sessionId); rosterChanged = true; return; }
                if (message.opCode === 5) {
                    try {
                        if (!object(frame) || Object.keys(frame).sort().join(",") !== "ticket,v" || frame.v !== 1 || !consume(session, "renew", 0.2, 3, 1, time)) reject("Invalid ticket renewal");
                        const ticket = verifyTicket(ctx, nk, frame.ticket);
                        if (ticket.ownerID !== session.ownerID || ticket.roomID !== state.roomID || !sameMembers(ticket.members, state.members)) reject("Invalid ticket renewal");
                        session.expiresAt = Math.max(session.expiresAt, ticket.expiresAt);
                    } catch (_) { removeSession(state, dispatcher, message.sender.sessionId); rosterChanged = true; }
                    return;
                }
                if (message.opCode < 1 || message.opCode > 3 || !object(frame) || frame.v !== 1 ||
                    Object.keys(frame).some(function (key) { return ["v", "body", "targetOwnerID"].indexOf(key) < 0; }) ||
                    typeof frame.body !== "string" || !frame.body.length || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(frame.body) ||
                    (frame.targetOwnerID !== undefined && (typeof frame.targetOwnerID !== "string" || frame.targetOwnerID === session.ownerID || state.members.indexOf(frame.targetOwnerID) < 0)) ||
                    (message.opCode === 3 && !frame.targetOwnerID)) {
                    removeSession(state, dispatcher, message.sender.sessionId); rosterChanged = true; return;
                }
                const maxBytes = message.opCode === 1 ? 768 : message.opCode === 2 ? 4096 : 8192;
                const decodedBytes = frame.body.length / 4 * 3 - (frame.body.slice(-2) === "==" ? 2 : frame.body.slice(-1) === "=" ? 1 : 0);
                if (decodedBytes < 1 || decodedBytes > maxBytes) { removeSession(state, dispatcher, message.sender.sessionId); rosterChanged = true; return; }
                const rate = message.opCode === 1 ? 30 : message.opCode === 2 ? 30 : 120;
                if (!consume(session, String(message.opCode), rate, rate * 2, 1, time)) {
                    if (message.opCode !== 1) { removeSession(state, dispatcher, message.sender.sessionId); rosterChanged = true; }
                    return;
                }
                if (message.opCode === 1) poses[message.sender.sessionId + ":" + (frame.targetOwnerID || "*")] = { session: session, frame: frame };
                else forward(state, dispatcher, message.opCode, session, frame);
            });
            Object.keys(poses).forEach(function (key) {
                const pose = poses[key];
                // Nakama rematerializes state through Go map wrappers between
                // callbacks; repeated lookups need not have JS object identity.
                const current = state.sessions[pose.session.presence.sessionId];
                if (current && current.joined && current.ownerID === pose.session.ownerID) forward(state, dispatcher, 1, current, pose.frame);
            });
            if (rosterChanged) {
                if (!Object.keys(state.sessions).length) state.idleSince = now;
                roster(state, dispatcher);
            }
            if (!Object.keys(state.sessions).length && now - state.idleSince >= 60) return null;
            return { state: state };
        },
        matchTerminate: function (_ctx, _logger, _nk, dispatcher, _tick, state) {
            const online = activePresences(state);
            if (online.length) dispatcher.matchKick(online);
            return { state: state };
        },
        matchSignal: function (_ctx, _logger, _nk, _dispatcher, _tick, state, data) {
            let signal: any;
            try { signal = JSON.parse(data); } catch (_) { return { state: state }; }
            if (signal.type === "discard" && signal.cleanupToken === state.cleanupToken && !Object.keys(state.sessions).length) state.discarded = true;
            return { state: state };
        }
    };
}

// Nakama resolves registered callbacks by global function identity when it
// creates another JS VM. Namespace properties alone are not discoverable.
function boundAuthenticate(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, request: nkruntime.AuthenticateCustomRequest): nkruntime.AuthenticateCustomRequest | void {
    return BoundAccounts.enabled(ctx) ? BoundAccounts.authenticate(ctx, logger, nk, request) : BoundRooms.authenticate(ctx, logger, nk, request);
}
function boundRefresh(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, request: any): any {
    if (!ctx || !BoundAccounts.enabled(ctx)) return boundDeny();
    return BoundAccounts.refresh(ctx, logger, nk, request);
}
var boundRoomRPC = BoundRooms.roomRPC;
var boundMatchInit = BoundRooms.match.matchInit;
var boundMatchJoinAttempt = BoundRooms.match.matchJoinAttempt;
var boundMatchJoin = BoundRooms.match.matchJoin;
var boundMatchLeave = BoundRooms.match.matchLeave;
var boundMatchLoop = BoundRooms.match.matchLoop;
var boundMatchTerminate = BoundRooms.match.matchTerminate;
var boundMatchSignal = BoundRooms.match.matchSignal;
function boundDeny(): never { throw { message: "Use the Bound account bridge", code: 7 }; }

function InitModule(ctx: nkruntime.Context, logger: nkruntime.Logger, _nk: nkruntime.Nakama, initializer: nkruntime.Initializer): void {
    if (!ctx.env.BOUND_NAKAMA_BRIDGE_SECRET || ctx.env.BOUND_NAKAMA_BRIDGE_SECRET.length < 32) throw Error("BOUND_NAKAMA_BRIDGE_SECRET must be configured with at least 32 characters");
    const selfhost = BoundAccounts.enabled(ctx);
    if (selfhost && (!ctx.env.BOUND_GATEWAY_SECRET || ctx.env.BOUND_GATEWAY_SECRET.length < 32)) throw Error("BOUND_GATEWAY_SECRET must be configured");
    initializer.registerBeforeAuthenticateCustom(boundAuthenticate);
    initializer.registerBeforeAuthenticateApple(boundDeny);
    initializer.registerBeforeAuthenticate(boundDeny);
    initializer.registerBeforeSessionRefresh(boundRefresh);
    initializer.registerBeforeAuthenticateDevice(boundDeny);
    initializer.registerBeforeAuthenticateEmail(boundDeny);
    initializer.registerBeforeAuthenticateFacebook(boundDeny);
    initializer.registerBeforeAuthenticateFacebookInstantGame(boundDeny);
    initializer.registerBeforeAuthenticateGameCenter(boundDeny);
    initializer.registerBeforeAuthenticateGoogle(boundDeny);
    initializer.registerBeforeAuthenticateSteam(boundDeny);
    initializer.registerBeforeLinkCustom(boundDeny);
    initializer.registerBeforeUnlinkCustom(boundDeny);
    initializer.registerBeforeLink(boundDeny);
    initializer.registerBeforeUnlink(boundDeny);
    initializer.registerBeforeLinkApple(boundDeny);
    initializer.registerBeforeLinkDevice(boundDeny);
    initializer.registerBeforeLinkEmail(boundDeny);
    initializer.registerBeforeUnlinkEmail(boundDeny);
    initializer.registerBeforeLinkFacebook(boundDeny);
    initializer.registerBeforeLinkFacebookInstantGame(boundDeny);
    initializer.registerBeforeLinkGameCenter(boundDeny);
    initializer.registerBeforeLinkGoogle(boundDeny);
    initializer.registerBeforeLinkSteam(boundDeny);
    initializer.registerRtBefore("MatchCreate", boundDeny);
    // Nakama extracts callback identifiers from top-level InitModule statements;
    // mode checks belong inside the callback, never in conditional registration.
    initializer.registerRpc("bound_account_v1", boundAccountRPC);
    initializer.registerBeforeUpdateAccount(boundDeny);
    initializer.registerBeforeDeleteAccount(boundDeny);
    // Bound storage is exclusively server-owned. A client must not create a
    // fresh reserved-key record with its own write permissions.
    initializer.registerBeforeWriteStorageObjects(boundDeny);
    initializer.registerBeforeDeleteStorageObjects(boundDeny);
    initializer.registerRpc("bound_room_v1", boundRoomRPC);
    initializer.registerMatch("bound_room_v1", {
        matchInit: boundMatchInit,
        matchJoinAttempt: boundMatchJoinAttempt,
        matchJoin: boundMatchJoin,
        matchLeave: boundMatchLeave,
        matchLoop: boundMatchLoop,
        matchTerminate: boundMatchTerminate,
        matchSignal: boundMatchSignal
    });
    logger.info("Bound gameplay room protocol v1 initialized");
}
