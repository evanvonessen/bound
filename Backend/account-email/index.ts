import { createEmailChangeHandler } from './handler.mjs';
// verify_jwt=false: validate exact bearer with Auth getUser and validate the
// original live auth.sessions row through the server-only RPC before updating.
Deno.serve(createEmailChangeHandler({
  serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
  publishableKey: Deno.env.get('CUPCAKE_SUPABASE_PUBLISHABLE_KEY'),
}));
