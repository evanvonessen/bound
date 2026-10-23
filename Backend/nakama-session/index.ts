import { createNakamaSessionHandler } from './handler.mjs';

// The exact bearer is verified with Auth getUser. The room RPC separately checks
// the live Auth session, account deletion and the existing friend authorization.
Deno.serve(createNakamaSessionHandler({
  publishableKey: Deno.env.get('CUPCAKE_SUPABASE_PUBLISHABLE_KEY'),
  nakamaHTTPURL: Deno.env.get('NAKAMA_HTTP_URL'),
  nakamaServerKey: Deno.env.get('NAKAMA_SERVER_KEY'),
  bridgeSecret: Deno.env.get('BOUND_NAKAMA_BRIDGE_SECRET'),
}));
