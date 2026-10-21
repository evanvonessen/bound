// Read claims only after Auth has verified this exact bearer. Accounts that
// opt in to MFA cannot use an AAL1 password session for privileged operations.
function permitsSecondFactor(user, authorization) {
  if (!Array.isArray(user?.factors) || !user.factors.some(f => f?.status === 'verified')) return true;
  try {
    const part = authorization.slice(7).split('.')[1];
    const claims = JSON.parse(atob(part.replaceAll('-', '+').replaceAll('_', '/')));
    return claims.sub === user.id && claims.aal === 'aal2';
  } catch { return false; }
}
const origin = 'https://qevnxhngdtlyihhmvnjv.supabase.co';
const tokenPattern = /^[a-f0-9]{64}$/;
const uuidPattern = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
export function normalizedEmail(value) {
  if (typeof value !== 'string') return null;
  const result = value.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, '').toLowerCase();
  return result.length <= 254 && /^[\x21-\x7e]+$/.test(result) && /^[^@]+@[^@]+$/.test(result) ? result : null;
}
const reply = (status, body) => new Response(JSON.stringify(body), {status, headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
async function json(stream, maximum = 65536) {
  if (!stream) throw Error('missing body');
  const reader = stream.getReader(); const chunks = []; let size = 0;
  let timer;
  const deadline = new Promise((_, reject) => {timer = setTimeout(() => {void reader.cancel().catch(()=>{});reject(Error('deadline'));},5000);});
  try {
    for (;;) { const {done,value} = await Promise.race([reader.read(), deadline]); if(done) break; size += value.length; if(size > maximum) throw Error('body limit'); chunks.push(value); }
    const bytes = new Uint8Array(size); let offset = 0; for(const chunk of chunks) {bytes.set(chunk, offset);offset += chunk.length;}
    return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  } finally {clearTimeout(timer);void reader.cancel().catch(()=>{});}
}
// The sole administrative credential remains in this server adapter. No request
// field can select an owner. Resume tokens authorize only an already frozen job.
export function createDeletionHandler({serviceKey, publishableKey, fetchImpl = fetch, hash = async value => {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes), x=>x.toString(16).padStart(2,'0')).join('');
}}) {
  if (!serviceKey || !publishableKey) throw Error('configuration');
  async function call(path, method, body, authorization = `Bearer ${serviceKey}`, key = serviceKey) {
    const response = await fetchImpl(origin + path, {method, headers:{Authorization:authorization,apikey:key,'Content-Type':'application/json'}, body:body === undefined ? undefined : JSON.stringify(body), redirect:'error', signal:AbortSignal.timeout(10000)});
    return response;
  }
  async function rpc(action, payload) {
    const response = await call('/rest/v1/rpc/cup117_delete_account','POST',{action,payload});
    if (!response.ok) throw Error('database');
    const value = await json(response.body);
    if (!value || value.ok !== true) throw Error('database');
    return value;
  }
  return async request => {
    if (request.method !== 'POST') return reply(405,{error:'method_not_allowed'});
    if (request.headers.has('origin')) return reply(403,{error:'forbidden'});
    if (request.headers.get('content-type')?.split(';')[0] !== 'application/json') return reply(400,{error:'invalid_request'});
    let body;
    try { body = await json(request.body, 512); } catch {return reply(400,{error:'invalid_request'});}
    if (!body || Array.isArray(body) || typeof body.operationToken !== 'string' || !tokenPattern.test(body.operationToken)) return reply(400,{error:'invalid_request'});
    const resume = Object.keys(body).length === 1;
    const cancel = Object.keys(body).sort().join(',') === 'cancel,operationToken' && body.cancel === true;
    const emailBegin = Object.keys(body).sort().join(',') === 'confirmationEmail,operationToken' && normalizedEmail(body.confirmationEmail) !== null;
    const legacyBegin = Object.keys(body).sort().join(',') === 'confirmation,operationToken,username' && body.confirmation === 'DELETE' && /^[A-Za-z0-9_]{3,16}$/.test(body.username ?? '');
    if (!resume && !cancel && !emailBegin && !legacyBegin) return reply(400,{error:'invalid_request'});
    try {
      const operation = await hash(body.operationToken);
      let job;
      if (cancel) {
        job = await rpc('cancel',{operation});
        if (!['cancelled','pending','complete'].includes(job.status)) throw Error('invalid cancel result');
        return reply(job.status === 'pending' ? 202 : 200,{status:job.status});
      } else if (resume) {
        job = await rpc('resume',{operation});
        if (job.status === 'not_started') return reply(404,{status:'not_started'});
      } else {
        const authorization = request.headers.get('authorization') ?? '';
        if (!/^Bearer [A-Za-z0-9._-]{16,8192}$/.test(authorization)) return reply(401,{error:'unauthorized'});
        const auth = await call('/auth/v1/user','GET',undefined,authorization,publishableKey);
        if (!auth.ok) return reply(auth.status >= 500 ? 503 : 401,{error:'identity_unavailable'});
        const user = await json(auth.body);
        if (!uuidPattern.test(user.id ?? '') || user.is_anonymous !== false || user.role !== 'authenticated' || !Number.isFinite(Date.parse(user.email_confirmed_at ?? ''))) return reply(403,{error:'confirmation_mismatch'});
        if (!permitsSecondFactor(user, authorization)) return reply(403,{error:'second_factor_required'});
        if (emailBegin) {
          const email = normalizedEmail(user.email);
          if (!email || normalizedEmail(body.confirmationEmail) !== email) return reply(403,{error:'confirmation_mismatch'});
          job = await rpc('begin',{operation,owner:user.id.toLowerCase(),email});
        } else {
          // Backward compatibility only. Bound's new UI has no username field.
          if (user.user_metadata?.cupcake_username_v1 !== body.username) return reply(403,{error:'confirmation_mismatch'});
          job = await rpc('begin',{operation,owner:user.id.toLowerCase(),username:body.username});
        }
      }
      if (job.status === 'cancelled') return reply(resume ? 200 : 409,{status:'cancelled'});
      if (job.status === 'complete') return reply(200,{status:'complete'});
      if (job.status !== 'pending' || !uuidPattern.test(job.owner ?? '')) throw Error('invalid job');
      // Database returns actual object names, including nested legacy paths.
      // No pagination offset: deleted first-page entries must not skip the next.
      for (let round = 0; round < 4; round++) {
        const batch = await rpc('objects',{operation});
        if (!Array.isArray(batch.objects) || batch.objects.length > 100) throw Error('invalid objects');
        if (!batch.objects.length) break;
        for (const bucket of ['cup040-saves','cup071-covers','bound-roms']) {
          const entries = batch.objects.filter(x => x.bucket === bucket);
          if (entries.some(x => typeof x.name !== 'string' || !x.name.startsWith(job.owner + '/'))) throw Error('foreign object');
          if (entries.length) {
            const removed = await call('/storage/v1/object/' + bucket,'DELETE',{prefixes:entries.map(x=>x.name)});
            if (!removed.ok) throw Error('storage');
          }
        }
        if (batch.objects.some(x=>!['cup040-saves','cup071-covers','bound-roms'].includes(x.bucket))) throw Error('invalid bucket');
      }
      const purged = await rpc('purge',{operation});
      if (purged.status !== 'ready') return reply(202,{status:'pending'});
      const deleted = await call('/auth/v1/admin/users/' + job.owner,'DELETE',{should_soft_delete:false});
      // A lost successful response is resolved by an administrative lookup;
      // arbitrary 404s/errors never manufacture a successful receipt.
      if (!deleted.ok) {
        const checked = await call('/auth/v1/admin/users/' + job.owner,'GET');
        if (checked.status !== 404) throw Error('auth deletion');
      }
      await rpc('complete',{operation});
      return reply(200,{status:'complete'});
    } catch { return reply(503,{error:'deletion_pending'}); }
  };
}
