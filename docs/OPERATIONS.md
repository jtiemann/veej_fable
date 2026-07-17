# Production operations

This guide applies to the source-mounted Docker Swarm deployment described in
[INSTALLATION.md](INSTALLATION.md). Commands use PowerShell and assume the
service is named `veej_fable`.

## Health checks

Check the Swarm replica, current task, logs, and public endpoint:

```powershell
docker service ls --filter name=veej_fable
docker service ps veej_fable --filter desired-state=running --no-trunc
docker service logs veej_fable --since 10m --tail 100
curl.exe -I https://veejr.example.com/
curl.exe https://veejr.example.com/api/v1/capabilities
```

Healthy output has one running replica (`1/1`), a recent task without an error,
Phoenix listening on port 4000, and HTTP status 200 from the public URL.

Check the supporting containers separately:

```powershell
docker ps --filter name=veej_caddy
docker logs --tail 100 veej_caddy
docker ps --filter name=veej_postfix
docker logs --tail 100 veej_postfix
```

Postfix checks are necessary only when `SMTP_HOST` points to that container or
relay. The current project host uses an external SMTP provider directly.

## Deploy an update

Do not deploy with an uncommitted working tree. Review upstream changes and
take a backup before an update that includes migrations.

```powershell
Set-Location C:\Services\veejr-server
git status --short
git pull --ff-only
git log -1 --oneline
```

Find the running container, run migrations, build digested assets, and force a
compile after the digest so Phoenix references the new manifest:

```powershell
$AppContainer = docker ps `
  --filter label=com.docker.swarm.service.name=veej_fable `
  --format "{{.ID}}"

docker exec $AppContainer mix ecto.migrate
docker exec $AppContainer mix assets.deploy
docker exec $AppContainer mix compile --force
docker service update --force veej_fable
```

The source-mounted `mix phx.server` service does **not** auto-migrate. A proper
`mix release` starts `Ecto.Migrator` automatically in this project, but that is
not the deployment described here.

With host-mode port publishing on a single node, Swarm may briefly report
`no suitable node (host-mode port already in use)` while replacing the old
task. It should then converge to `1/1`. Treat failure to converge as an error.

Run the health checks after every rollout and confirm the public HTML points to
new digested CSS/JavaScript files:

```powershell
$Response = Invoke-WebRequest https://veejr.example.com/ -UseBasicParsing
$Response.StatusCode
[regex]::Matches(
  $Response.Content,
  'assets/(?:js|css)/app-[a-f0-9]+\.(?:js|css)'
).Value | Sort-Object -Unique
```

## Restart services

Restart Phoenix through Swarm rather than `docker restart`:

```powershell
docker service update --force veej_fable
```

Restart standalone supporting containers with:

```powershell
docker restart veej_caddy
docker restart veej_postfix
```

Only restart Postfix when it is actually part of the configured mail path.

## Operate account moves

Account moves are intentionally resumable and are visible on `/admin`:

1. **Awaiting test / Testing**: the source account remains active while the
   provisioner imports into a disposable database.
2. **Test verified**: review the target hostname and counts, then approve
   cutover. This suspends the member, revokes web and Android sessions, and
   creates a fresh final export.
3. **Provisioning / Target verified**: confirm the new HTTPS site works and the
   moved user can request a login link before selecting **Finalize**.
4. **Finalized**: the target directory has been verified against the moved
   user's pinned public key, source-side friendships and address-book references
   point to the new server, and the source account and private package have
   been removed. Signed move notices update established friends on other
   federated servers.

Test or provision failures preserve the source account and package. Use
**Retry** after correcting DNS, Docker, storage, SMTP-template, or Caddy errors.
If a job remains in Testing or Provisioning because the host process stopped,
first confirm no provisioner is still processing it, then use **Retry**. Cancel
reactivates a member suspended by cutover. Never finalize solely because a
Docker service exists; verify its public HTTPS endpoint and imported owner.

If final import and service creation succeeded but Caddy or certificate
readiness failed, Retry resumes from the saved import receipt. Earlier partial
failures deliberately keep their instance directory for diagnosis. After
confirming no useful target service exists, rename that directory as a backup
before retrying; do not recursively delete it as a first response.

The import currently includes the user's profile image, encrypted envelope
history, and blobs they own. Received attachment blobs cannot be discovered from server-side
ciphertext and therefore cannot be copied automatically. This limitation is
shown in the export documentation and should be explained before cutover.

## Backups

A complete backup contains:

- The SQLite database at `DATABASE_PATH`.
- The encrypted blob directory at `VEEJR_BLOB_DIR`.
- The protected production environment file.
- The original Firebase service-account JSON, when enabled.
- Caddy's `/data` volume, which contains certificates and account state.

The database also contains federation signing material and browser-push VAPID
credentials. Losing it changes the instance identity and can break established
federation relationships.

For a simple consistent backup, briefly stop the one application replica,
copy the state directory, and start it again:

```powershell
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Backup = "D:\Backups\Veejr\$Stamp"

docker service scale veej_fable=0
New-Item -ItemType Directory -Force $Backup
Copy-Item -Recurse -Force C:\ProgramData\Veejr\data "$Backup\data"
Copy-Item -Force C:\ProgramData\Veejr\secrets\veejr.env "$Backup\veejr.env"
docker service scale veej_fable=1
```

Confirm the service returns to `1/1`, then encrypt the backup and copy it off
the host. Keep multiple generations and test restoration periodically. Do not
commit backups, databases, environment files, service-account files, or
attachment directories to Git.

## Restore

1. Stop the application replica with `docker service scale veej_fable=0`.
2. Preserve the current state directory separately; do not overwrite the only
   copy.
3. Restore the database and uploads to the exact paths configured in the
   environment file.
4. Restore the same `SECRET_KEY_BASE` and public hostname.
5. Ensure host/container permissions allow SQLite and uploads to be written.
6. Run `mix ecto.migrate` with the checked-out application version.
7. Scale the service back to one replica and run all health checks.

Restoring only SQLite or only the blob directory produces incomplete
attachments. Restoring under a different public hostname changes federated
addresses and requires a deliberate migration plan.

## Roll back application code

Database migrations are not automatically reversible. Before rolling back,
read the migrations introduced by the failed release and restore a compatible
backup when necessary.

For a code-only rollback:

```powershell
git log --oneline -10
git switch --detach <known-good-commit>

$AppContainer = docker ps `
  --filter label=com.docker.swarm.service.name=veej_fable `
  --format "{{.ID}}"

docker exec $AppContainer mix assets.deploy
docker exec $AppContainer mix compile --force
docker service update --force veej_fable
```

After recovery, return the checkout to the managed branch deliberately. Never
use `git reset --hard` on a host with unreviewed local work.

## Rotate secrets

### Session secret

Changing `SECRET_KEY_BASE` signs users out and invalidates existing browser
session cookies. Update the protected environment file, recreate/update the
service environment, and roll the service during a maintenance window.

### SMTP credential

Replace the provider credential, update `SMTP_PASSWORD`, roll Phoenix, and
perform a real login-email test. Revoke the old credential only after delivery
is confirmed.

### Firebase key

Docker secrets are immutable. Create a versioned replacement, update the
service to mount it at `/run/secrets/fcm_service_account_json`, verify
`"android_push": true` in the capabilities response, then revoke the old key
in Firebase and remove the old Docker secret.

## Common failures

### Public 403 response

- Confirm `PHX_HOST` exactly matches the public hostname, without a scheme or
  path.
- Confirm Caddy preserves the incoming `Host` header.
- Check that DNS is not still forwarding to an old tunnel or endpoint.
- Rebuild assets and force compile before restarting after a hostname/config
  change.

### TLS certificate is missing

- Confirm public DNS resolves to this host.
- Forward TCP 80 and 443 to Caddy and allow them through the host firewall.
- Check `docker logs veej_caddy` for ACME errors.
- Preserve the Caddy data volume between container replacements.

### Caddy returns 502

- Confirm the Swarm service is `1/1`.
- Request `http://localhost:4000` from the host.
- On Linux, ensure the Caddy container can resolve/reach
  `host.docker.internal`, or configure the host-gateway mapping.

### Email is not delivered

- Verify `SMTP_HOST`, port, TLS mode, username, and allowed sender address.
- For Gmail, use an App Password and two-step verification.
- Review `/admin` operational failures and Phoenix logs without printing the
  SMTP password.
- Check spam handling and the sender domain's SPF, DKIM, and DMARC records.
- If Postfix is used, inspect its queue/logs and verify it is not an open relay.

### Voice or video fails

- Use the public HTTPS hostname; camera and microphone access require a secure
  browser context.
- Recheck browser site permissions for camera and microphone.
- Confirm the instance upload limit and total storage quota have room.
- Test a browser-supported MP4 or WebM format.

### SQLite is locked or read-only

- Keep exactly one application replica.
- Confirm the host directory is writable by the container.
- Do not place the live database on a network filesystem with unreliable file
  locking.
- Stop the application before filesystem-level backup or restore.

### Service does not return after host restart

- Confirm Docker Desktop/Engine starts automatically.
- Check that the node is still an active Swarm manager.
- Use `docker service ps veej_fable --no-trunc` to inspect scheduling errors.
- Configure standalone Caddy/Postfix containers with `--restart unless-stopped`.

## Security checklist

- Expose only Caddy's public HTTP/HTTPS ports.
- Keep the manager node, environment file, SMTP credential, and Firebase key
  restricted to administrators.
- Apply OS, Docker, Elixir-image, and Caddy updates on a tested schedule.
- Pin container versions or digests instead of relying on `latest`.
- Maintain encrypted off-host backups and perform restoration drills.
- Review administrator audit events and operational failures.
- Remember that encrypted content does not hide account, friendship,
  sender/recipient, timestamp, item-kind, or blob-size metadata from the server.
