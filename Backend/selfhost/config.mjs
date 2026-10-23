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
  return config;
}
