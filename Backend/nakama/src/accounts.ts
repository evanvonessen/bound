/// <reference path="../types/nakama-runtime.d.ts" />

// This module is enabled only on the private self-hosted Nakama deployment.
// Public API requests cannot call it with a player session or choose account IDs.
namespace BoundAccounts {
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    const collections = ["bound_auth_sessions_v1", "bound_auth_factors_v1", "bound_auth_proofs_v1", "bound_auth_challenges_v1"];
    function deny(message: string = "Account gateway required"): never { throw { message: message, code: 7 }; }
    export function enabled(ctx: nkruntime.Context): boolean { return ctx.env.BOUND_ACCOUNT_MODE === "nakama"; }
    function gateway(ctx: nkruntime.Context, secret: any): void {
        const expected = ctx.env.BOUND_GATEWAY_SECRET;
        if (!enabled(ctx) || typeof expected !== "string" || expected.length < 32 || typeof secret !== "string" || expected.length !== secret.length) deny();
        let difference = 0;
        for (let i = 0; i < expected.length; i++) difference |= expected.charCodeAt(i) ^ secret.charCodeAt(i);
        if (difference) deny();
    }
    function active(nk: nkruntime.Nakama, id: string): nkruntime.Account {
        if (!uuid.test(id)) deny();
        const account = nk.accountGetId(id);
        if (!account.user || account.user.userId !== id || account.disableTime || account.user.metadata.bound_deleted_at) deny();
        return account;
    }
    function publicAccount(account: nkruntime.Account): any {
        return { id: account.user.userId, email: account.email, username: account.user.username,
            email_confirmed_at: account.user.metadata.bound_email_confirmed_at || null,
            user_metadata: { bound_username_v1: account.user.metadata.bound_username_v1 || account.user.displayName || account.user.username } };
    }
    export const authenticate: nkruntime.BeforeHookFunction<nkruntime.AuthenticateCustomRequest> = function (ctx, _logger, nk, request) {
        const vars = request.account && request.account.vars;
        gateway(ctx, vars && vars.bound_gateway);
        const id = request.account && request.account.id;
        if (request.create !== false || !id || id.substr(0, 15) !== "bound-selfhost:" || !uuid.test(id.substr(15)) || !vars || !uuid.test(vars.session_id) || !uuid.test(vars.session_nonce) || ["aal1", "aal2"].indexOf(vars.aal) < 0) deny();
        const account = active(nk, id.substr(15));
        if (account.customId !== id || !account.user.metadata.bound_email_confirmed_at) deny();
        request.account!.vars = { session_id: vars.session_id, session_nonce: vars.session_nonce, aal: vars.aal, email: account.email };
        return request;
    };
    export const refresh: nkruntime.BeforeHookFunction<any> = function (ctx, _logger, _nk, request) {
        gateway(ctx, request.vars && request.vars.bound_gateway);
        if (!request.vars || !uuid.test(request.vars.session_id) || !uuid.test(request.vars.session_nonce) || ["aal1", "aal2"].indexOf(request.vars.aal) < 0) deny();
        // The private gateway verified the native refresh token against its CAS journal.
        request.vars = { session_id: request.vars.session_id, session_nonce: request.vars.session_nonce, aal: request.vars.aal, email: request.vars.email };
        return request;
    };
    export const rpc: nkruntime.RpcFunction = function (ctx, _logger, nk, payload) {
        if (ctx.userId) deny();
        let body: any;
        try { body = JSON.parse(payload); } catch (_) { deny(); }
        gateway(ctx, body.gatewaySecret);
        let result: any = {};
        if (body.action === "signup") {
            const created = nk.authenticateEmail(body.email, body.password, undefined, true);
            if (!created.created) return JSON.stringify({ existing: true });
            try {
                nk.linkCustom(created.userId, "bound-selfhost:" + created.userId);
                nk.accountUpdateId(created.userId, null, body.username, null, null, null, null, { bound_username_v1: body.username });
            } catch (error) {
                // Metadata updates claim the unique Bound username. Do not strand
                // an unconfirmed account when that database constraint fails.
                nk.accountDeleteId(created.userId, false);
                throw error;
            }
            result = publicAccount(active(nk, created.userId));
        } else if (body.action === "password") {
            const authenticated = nk.authenticateEmail(body.email, body.password, undefined, false);
            result = publicAccount(active(nk, authenticated.userId));
        } else if (body.action === "lookup") {
            const rows = nk.sqlQuery("SELECT id FROM users WHERE lower(email) = lower($1) AND disable_time = '1970-01-01 00:00:00 UTC' LIMIT 1", [body.email]);
            result = rows.length ? publicAccount(active(nk, rows[0].id)) : null;
        } else if (body.action === "account") {
            result = publicAccount(active(nk, body.id));
        } else if (body.action === "confirm") {
            const account = active(nk, body.id);
            const metadata = account.user.metadata;
            metadata.bound_email_confirmed_at = new Date().toISOString();
            nk.accountUpdateId(body.id, null, null, null, null, null, null, metadata);
            result = publicAccount(active(nk, body.id));
        } else if (body.action === "update_password") {
            const account = active(nk, body.id);
            nk.linkEmail(body.id, account.email, body.password);
            nk.sessionLogout(body.id);
        } else if (body.action === "update_email") {
            active(nk, body.id);
            // Email changes preserve the existing bcrypt credential exactly.
            // Re-hashing a legacy password longer than bcrypt's 72-byte creation
            // limit could destroy its credential; password proof is separate.
            nk.sqlExec("UPDATE users SET email = $2, update_time = now() WHERE id = $1", [body.id, body.email]);
            nk.sessionLogout(body.id);
            result = publicAccount(active(nk, body.id));
        } else if (body.action === "delete") {
            active(nk, body.id);
            nk.sessionLogout(body.id);
            nk.accountDeleteId(body.id, true);
        } else if (body.action === "logout") {
            nk.sessionLogout(body.id, body.token, body.refreshToken);
        } else if (body.action === "storage_read" || body.action === "storage_write" || body.action === "storage_delete" || body.action === "storage_list") {
            if (collections.indexOf(body.collection) < 0 || !uuid.test(body.id)) deny();
            const key = { userId: body.id, collection: body.collection, key: body.key };
            if (body.action === "storage_read") result = nk.storageRead([key])[0] || null;
            else if (body.action === "storage_list") {
                result = [];
                let cursor: string | undefined;
                do {
                    const page = nk.storageList(body.id, body.collection, 100, cursor);
                    result = result.concat(page.objects || []);
                    cursor = page.cursor;
                    if (result.length > 10000) deny("Storage limit exceeded");
                } while (cursor);
            }
            else if (body.action === "storage_delete") nk.storageDelete([{ userId: body.id, collection: body.collection, key: body.key, version: body.version }]);
            else result = nk.storageWrite([{ userId: body.id, collection: body.collection, key: body.key,
                value: body.value, version: body.version, permissionRead: 0, permissionWrite: 0 }])[0];
        } else deny();
        return JSON.stringify(result);
    };
}
var boundAccountRPC = BoundAccounts.rpc;
var boundAccountAuthenticate = BoundAccounts.authenticate;
var boundAccountRefresh = BoundAccounts.refresh;
