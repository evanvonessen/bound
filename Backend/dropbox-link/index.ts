import { createDropboxHandler } from './handler.mjs';
// verify_jwt=false: the handler validates the JWT with Auth getUser AND checks
// the live auth.sessions row in every privileged database operation.
Deno.serve(createDropboxHandler({
  serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
  publishableKey: Deno.env.get('CUPCAKE_SUPABASE_PUBLISHABLE_KEY'),
  appKey: Deno.env.get('BOUND_DROPBOX_APP_KEY'),
  encryptionKey: Deno.env.get('BOUND_DROPBOX_ENCRYPTION_KEY'),
}));
