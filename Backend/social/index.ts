import { createJiggleHandler } from './handler.mjs';

// This endpoint verifies the caller with Supabase Auth itself. Keep platform JWT
// verification disabled in its deployment config so no unverified identity is
// substituted for that check.
const handler = createJiggleHandler({
  publishableKey: Deno.env.get('CUPCAKE_SUPABASE_PUBLISHABLE_KEY'),
  serviceRoleKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
  apnsKeyID: Deno.env.get('BOUND_APNS_KEY_ID'),
  apnsTeamID: Deno.env.get('BOUND_APNS_TEAM_ID'),
  apnsPrivateKey: Deno.env.get('BOUND_APNS_PRIVATE_KEY'),
  apnsSandboxKeyID: Deno.env.get('BOUND_APNS_SANDBOX_KEY_ID'),
  apnsSandboxTeamID: Deno.env.get('BOUND_APNS_SANDBOX_TEAM_ID'),
  apnsSandboxPrivateKey: Deno.env.get('BOUND_APNS_SANDBOX_PRIVATE_KEY'),
  apnsProductionKeyID: Deno.env.get('BOUND_APNS_PRODUCTION_KEY_ID'),
  apnsProductionTeamID: Deno.env.get('BOUND_APNS_PRODUCTION_TEAM_ID'),
  apnsProductionPrivateKey: Deno.env.get('BOUND_APNS_PRODUCTION_PRIVATE_KEY'),
});

Deno.serve(handler);
