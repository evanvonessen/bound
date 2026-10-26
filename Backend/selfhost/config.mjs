export function configuration(env = process.env) {
  const config = { ...env };
  config.PUBLIC_URL ??= config.BOUND_PUBLIC_URL;
  config.BOUND_PUBLIC_URL = config.PUBLIC_URL;
  config.NAKAMA_HTTP_URL ??= config.NAKAMA_INTERNAL_URL ?? 'http://nakama:7350';
  config.NAKAMA_INTERNAL_URL = config.NAKAMA_HTTP_URL;
  const publicURL = new URL(config.PUBLIC_URL);
  if (publicURL.protocol !== 'https:' || publicURL.username || publicURL.password || publicURL.pathname !== '/' || publicURL.search || publicURL.hash) throw Error('PUBLIC_URL must be an HTTPS origin');
  for (const key of ['DATABASE_URL', 'NAKAMA_SERVER_KEY', 'NAKAMA_HTTP_KEY', 'BOUND_GATEWAY_SECRET', 'BOUND_NAKAMA_BRIDGE_SECRET', 'BOUND_AUTH_ENCRYPTION_KEY']) {
    if (!config[key]) throw Error('Missing configuration: ' + key);
  }
  if (config.BOUND_NAKAMA_BRIDGE_SECRET.length < 32) throw Error('Gameplay signing key is too short');
  const port = Number(config.PORT ?? 8080);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw Error('Invalid PORT');
  config.PORT = port;
  config.TRUST_PROXY = config.TRUST_PROXY === 'true';
  if (config.BOUND_DEBUG_MODE !== undefined) {
    if (config.BOUND_DEBUG_MODE !== 'local' || config.HOST !== '127.0.0.1' || !['127.0.0.1', 'localhost'].includes(publicURL.hostname) ||
        !['127.0.0.1', 'localhost'].includes(new URL(config.NAKAMA_INTERNAL_URL).hostname) ||
        !['127.0.0.1', 'localhost'].includes(new URL(config.DATABASE_URL).hostname) ||
        (config.BOUND_DEBUG_GATEWAY_SECRET?.length ?? 0) < 32) throw Error('DEBUG requires explicit isolated loopback configuration');
    config.BOUND_DEBUG_ALLOWED_OWNERS ??= '';
    if (config.BOUND_DEBUG_ALLOWED_OWNERS && config.BOUND_DEBUG_ALLOWED_OWNERS.split(',').some(id => !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id))) throw Error('Invalid DEBUG owner allowlist');
  }
  if (config.BOUND_LOCAL_EMAIL_CAPTURE === 'true' && config.BOUND_DEBUG_MODE !== 'local') throw Error('Local email capture requires isolated DEBUG configuration');
  if (config.BOUND_MIGRATION_MODE !== undefined && config.BOUND_MIGRATION_MODE !== 'verify') throw Error('Invalid migration mode');
  return config;
}
