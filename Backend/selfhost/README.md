# Bound on Linode

This deployment runs Nakama, PostgreSQL, Caddy and Bound's authenticated API/file
service on one server. Nakama owns accounts and issues access/refresh tokens.
Agora remains the Friends video provider; Resend sends account email; existing
Dropbox sync keeps transferring ROMs and saves directly to Dropbox.

**Keep the existing backend running until Evan explicitly requests retirement.**
New Bound builds use `https://bound.evanvonessen.com`. Existing installed builds
continue using the original backend; changes made there after the migration
snapshot are not automatically copied. Nothing here deletes or pauses it. The Heroic runtime repository
is not used or changed. No off-server backups or paid add-ons are configured.

## Server and cost

Use Ubuntu 24.04 on the Linode 2 GB Shared CPU plan: one CPU, 50 GB disk and 2 TB
monthly transfer. Akamai's plan and regional availability APIs confirmed $12/month
and availability in Los Angeles on October 22, 2026. Recheck before creation.
Taxes and transfer overages can add to that amount; this is a small single-server
deployment, with no high-availability or performance guarantee.

Resend stays on Free (3,000 transactional emails/month, 100/day). Keep paid
transactional overages disabled. The existing domain and Agora usage keep their
own billing. Do not add another paid plan, larger server, backup service, reserved
IP, managed database or control panel without approval.

## Deploy

1. Create the server with the deployment SSH public key, disk encryption enabled,
   and backups disabled. The private SSH key stays outside source control.
2. Prepare and upload the repository's `Backend/` directory:

   ```sh
   python3 Backend/selfhost/deploy.py --host SERVER_IP --identity PRIVATE_KEY --bootstrap
   ```

   This installs Docker on the new server and prepares a release under
   `/opt/bound/releases/`. It does not start the backend or change DNS.
3. Point a new DNS hostname at this server. Preserve the existing website,
   Supabase endpoints, mail records and Resend verification records.
4. On the server, generate private configuration once:

   ```sh
   python3 /opt/bound/releases/RELEASE/Backend/selfhost/configure.py \
     --hostname NEW_BACKEND_HOSTNAME --tls-email evanvonessen.dev@gmail.com \
     --directory /opt/bound/config
   ```

   Add integration credentials to `/opt/bound/config/.env` through a protected
   channel: Resend sending key, existing Agora app ID/certificate, Dropbox app key
   and **the existing Dropbox encryption key** when importing linked accounts,
   and APNs credentials for friend notifications. Never put secrets in Git, logs,
   app settings or command arguments. Missing provider credentials disable that
   integration. Keep `RESEND_FROM=Bound <noreply@auth.evanvonessen.com>`.
5. Start the new stack:

   ```sh
   python3 Backend/selfhost/deploy.py --host SERVER_IP --identity PRIVATE_KEY --activate
   ```

   Build output stays in Docker, not Git. Caddy obtains TLS for the new hostname.
   Only ports 80/443 are published; the database, Nakama native authentication,
   privileged RPCs and console stay private. Only `/ws` reaches Nakama publicly.
   Container memory limits and rotating logs leave space for the host. The
   deployment script retains earlier source releases and persistent volumes.

## Accounts and data

Read [IMPORT.md](IMPORT.md) before importing existing users. The importer
connects to the original PostgreSQL database read-only, preserves account UUIDs
and bcrypt password hashes, and writes a fresh destination transactionally.
Its default mode reports counts and blockers. It never retires the source.

The gateway preserves Bound's existing HTTP contracts; `auth.*` in PostgreSQL is
a set of views over Nakama, not a second identity platform. Account confirmation,
password recovery and TOTP use private Nakama storage. Provider credentials and
MFA secrets remain server-side. Signing out, refreshing, changing passwords and
deleting accounts revoke the appropriate server sessions.

The file service handles temporary transfers. It uses
live Nakama identity and current room membership, limits file sizes/disk use, and
removes expired transfers. Dropbox remains the default cloud provider. Approved
users can select private server save backups instead; one account-authoritative
provider prevents updated clients from syncing to both. See [BACKUPS.md](BACKUPS.md)
for approval commands, limits, and the save-backup HTTP contract. Historical
Supabase files and save-history rows are retained in a separate private archive,
without expiry, and removed when their owner deletes their new-backend account.

After the new deployment, imported data and integrations are verified, select it
in a Bound build with:

```text
BOUND_BACKEND_KIND=selfhost
BOUND_BACKEND_URL=https://NEW_BACKEND_HOSTNAME
```

Existing builds continue using the original backend. A malformed explicit URL
fails closed; sessions and Keychain entries are isolated by origin. Do not run
automatic fallback or assume two independently writable backends stay in sync.
Coordinate the client switch and final import; retain the original service until
the explicit retirement instruction arrives.

## Validation and maintenance

```sh
cd Backend/selfhost
npm ci --ignore-scripts --no-audit --no-fund
npm test
```

Focused checks cover session/MFA boundaries, import preservation, service
authorization, HTTP limits and file access. An isolated Nakama 3.41/PostgreSQL 17.6
check exercised account lifecycle, friend authorization, gameplay admission and
peer transfers. Email/video/Dropbox provider calls were not live validation.

Apply host security updates regularly and rebuild pinned container versions after
reviewing upgrades. Use `docker compose ps` and `docker compose logs --tail=100`
from the active release for status; do not enable payload/header logging. Preserve
`/opt/bound/config` and Docker volumes across deployments. No backup automation is
installed, so loss of this server's data is not covered by this setup.
