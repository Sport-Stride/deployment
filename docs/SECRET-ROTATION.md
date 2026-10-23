# Secret rotation runbook

No secret values appear in this file. Variables are referred to by NAME only.
All values live in `.env.production` on the server (shared `env_file` for the containers).
`.env.production.example` lists every NAME with an empty value.

Why this is mandatory: older commits of several repos contained real secret defaults (Mongo URI with
credentials, Mailgun key, Google/Facebook secrets, encryption/signing keys, an SMTP app password, a Mongo
admin password in scripts). Removing them from the working tree does not remove them from git history,
so every one of those values must be treated as compromised and rotated (see section 5).

## 1. Inventory

"me" = can be done on the server by the operator/automation. "owner" = needs the third-party dashboard.

| Variable | Used by (containers) | Protects | Who | Impact of rotating |
|---|---|---|---|---|
| COACHIFY_ENCRYPTION_KEY | frontend; account, chat, content, invitation, payments, workout, tracker, statistics | AES-GCM layer around every JWT (users.token, refresh tokens, Authorization header) | me | All sessions die; every stored ciphertext made with it becomes unreadable (section 2). Must change everywhere at once. |
| COACHIFY_SECRET_KEY | account, chat, content, invitation, payments, workout, tracker, statistics | HS256 signature of the JWTs | me | All issued JWTs become invalid (forced re-login). Must change in all Go services at once. |
| AUTH_SECRET | frontend | Auth.js session cookie encryption/signing | me | All browser sessions invalid (re-login). Frontend only. |
| GOOGLE_ENCRYPTION_KEY | account | AES-GCM of Google OAuth access/refresh tokens stored in Mongo | me | Stored Google provider tokens unreadable; users re-link/login with Google. |
| FACEBOOK_ENCRYPTION_KEY | account | Same, for Facebook. Passed to the provider; no Encrypt call found in oauth2/facebook.go (verify before relying on it). | me | Same as Google if it is used. |
| GOOGLE_APP_SECRET (GOOGLE_CLIENT_SECRET in the frontend env) | account (frontend for GOOGLE_CLIENT_SECRET) | Google OAuth client | owner | Google login fails until updated everywhere. |
| FACEBOOK_APP_SECRET (FACEBOOK_CLIENT_SECRET) | account (frontend) | Facebook OAuth client | owner | Facebook login fails until updated. |
| MONGODB_URI | identifier, account, chat | Mongo app credentials (URI contains user and password) | me | Service cannot connect until restarted with the new value. |
| MONGO_URL | invitation, workout, tracker, content | same | me | same |
| MONGO_URI | payments, statistics | same | me | same |
| FEDERATED_MONGO_URI | statistics (declared, not read by code today) | Atlas federated endpoint | owner | none today |
| MONGO_ROOT_USER / MONGO_ROOT_PASSWORD | mongodb-exporter (as `${MONGO_ROOT_PASSWORD}`), admin scripts | Mongo admin (root) account | me | Exporter and admin scripts fail until updated. |
| LOCAL_MONGO_ROOT_PASSWORD, MONGO_APP_USER, MONGO_APP_PASSWORD, LOCAL_MONGO_EXPRESS_PASSWORD, LOCAL_RABBITMQ_PASSWORD | mongodb, mongo-express, rabbitmq (profile `local-db` only; read from `.env` next to the compose file) | optional containerised DB | me | Only if that profile is used. |
| MAILGUN_API_KEY | notification, invitation | Sending mail | owner | Mail sending fails until updated. |
| SMTP_USERNAME / SMTP_PASSWORD | alertmanager (via monitoring/secrets/smtp_password) | Alert email relay (Gmail app password) | owner | Alert mail fails until updated. |
| GRAFANA_ADMIN_PASSWORD | grafana | Grafana admin | me | New login. |
| CLOUDAMQP_URL | workout, tracker, statistics | RabbitMQ broker (credentials inside the URL) | owner | Publishing/consuming stops until restart. |
| CLOUDAMQP_APIKEY | declared in several services, not read by code | CloudAMQP API | owner | none today |
| ABLY_API_KEY | chat, content | Ably server key | owner | Realtime/chat publishing fails until updated. |
| NEXT_PUBLIC_ABLY_KEY | frontend (baked at build time) | Ably client key | owner | Requires rebuilding the frontend image. |
| STRIPE_API_KEY, STRIPE_WEBHOOK_SECRET | payments | Stripe API and webhook signature | owner | Payments and webhooks fail until updated. The webhook secret changes in the Stripe webhook endpoint. |
| FLOUCI_API_KEY, FLOUCI_PUBLIC_KEY, FLOUCI_PRIVATE_KEY, FLOUCI_WEBHOOK_SECRET | payments | Flouci provider | owner | Flouci payments fail until updated. |
| KONNECT_API_KEY, KONNECT_WEBHOOK_SECRET | payments (config only) | Konnect provider | owner | none unless used |
| CLOUDINARY_API_SECRET, NEXT_PUBLIC_CLOUDINARY_API_KEY | frontend | Media uploads | owner | Uploads fail until updated; the public key is baked at build time. |
| GHCR_USERNAME / GHCR_TOKEN | deploy (image pull) | Registry access | owner | Pull fails until updated. |
| INTERNAL_API_KEY, TRACKER_API_KEY, ACCOUNT_API_KEY, API_KEYS | tracker, chat, workout (read from env, empty if unset) | service-to-service keys | me | Rotate in caller and callee together. |

## 2. Keys: format, generation, what depends on them

### COACHIFY_ENCRYPTION_KEY
- Code: `utils/crypto.go` (every Go service) and `src/utils/crypto-utils.ts`, `src/app/api/auth/[...nextauth]/route.ts` (frontend).
- Format: the string is used as raw UTF-8 bytes (`[]byte(key)` in Go, `TextEncoder`/`Buffer.from(key,'utf-8')` in the frontend). It is not hex or base64 decoded.
- AES key size must be exactly 16, 24 or 32 bytes. Use 32 for AES-256: exactly 32 ASCII characters. A 64 char hex string is NOT valid (64 bytes: `aes: invalid key size`).
- Generate a valid value: `openssl rand -hex 16` (32 hex characters = 32 bytes).
- Algorithm: AES-GCM, output = base64(nonce(12) || ciphertext||tag). Note: in `utils/crypto.go` the nonce is a zero-filled 12 byte buffer that is never randomised, so the nonce is reused for every encryption under one key. This weakens GCM; fix the code (fill the nonce with `crypto/rand`) in a separate change. Existing ciphertext remains decryptable by the frontend because the nonce is stored in the payload.
- What it encrypts: the signed JWT access/refresh tokens (account `utils/token.go`) and OAuth provider tokens are separate (see Google/Facebook below). Persisted: `users.users.token` and `users.users.refresh_token` hold tokens that were encrypted with it. No matricule fiscale document or other business data is encrypted with it (no Encrypt call in `handlers/matricule.go`).
- If it changes: every existing access/refresh token fails to decrypt, so all users are logged out and must log in again. Nothing else is lost once the stored tokens are cleared (section 4, step 5).
- Frontend and ALL Go services using it (account, chat, content, invitation, payments, workout, tracker, statistics) must run with the same new value. Restart them together.

### COACHIFY_SECRET_KEY
- Code: `utils/token.go` (HS256 `jwt.SigningMethodHS256`, `[]byte(key)`); verified in each service `AuthMiddleware`.
- Format: any string (raw bytes). Use at least 32 random characters.
- Generate: `openssl rand -hex 32` (64 hex characters; fine because it is not an AES key).
- Not used to encrypt stored data. If it changes, all issued JWTs are invalid (forced login). Same rule: change in all Go services at once. The frontend does not read it.

### AUTH_SECRET (Auth.js, frontend)
- Read automatically by Auth.js (`AUTH_SECRET`). Any high entropy string; the Auth.js default is base64 of 32 bytes.
- Generate: `openssl rand -base64 32`.
- Protects the session cookie only. Rotating logs out all browsers. Nothing is persisted in Mongo with it. Restart only the frontend (but you will do all together in the runbook).

### GOOGLE_ENCRYPTION_KEY and FACEBOOK_ENCRYPTION_KEY
- Code: `oauth2/google.go` calls `utils.Encrypt(token, []byte(p.encryptionKey))`; the key is the same AES rule: exactly 16/24/32 raw bytes, generate with `openssl rand -hex 16`.
- Persisted ciphertext: Mongo `users.users` documents, field `providers.<provider>.access_token` and `providers.<provider>.refresh_token` (type `OAuthProviderDetails`), and the `OAuthUser` access_token/refresh_token fields of OAuth login records. These become unreadable after rotation. Impact: token refresh for linked Google accounts fails; the user signs in with Google again and new tokens are stored. To clean up: `db.users.updateMany({}, {$unset: {"providers.google.access_token": "", "providers.google.refresh_token": ""}})` (run in the correct database; adapt for facebook).
- Facebook: no `Encrypt` call was found in `oauth2/facebook.go`; confirm whether Facebook tokens are stored before relying on this.

## 3. MongoDB credentials

How they are defined (as found in the repo):
- `.env.production` carries the full URIs `MONGODB_URI`, `MONGO_URL`, `MONGO_URI` (they point at the host mongod, `172.18.0.1:27017`, database `coachify`, `authSource=coachify`, application user, e.g. `coachifyApp`) and `MONGO_ROOT_USER` / `MONGO_ROOT_PASSWORD` (admin user `adminUser`, `authSource=admin`).
- `docker-compose.monitoring.yml` builds the mongodb-exporter URI as `mongodb://adminUser:${MONGO_ROOT_PASSWORD}@172.18.0.1:27017/?authSource=admin`. Run compose with `--env-file .env.production` so the variable resolves.
- The optional containerised DB (`COMPOSE_PROFILES=local-db`) uses `LOCAL_MONGO_ROOT_PASSWORD`, `MONGO_APP_USER`, `MONGO_APP_PASSWORD` from a `.env` next to the compose file; `mongo-express` uses `LOCAL_MONGO_ROOT_PASSWORD`.
- The URI is `mongodb://<MONGO_APP_USER>:<url-encoded MONGO_APP_PASSWORD>@<host>:27017/<db>?authSource=<db>`. Prefer passwords with only `[A-Za-z0-9]` (`openssl rand -hex 24`) so no URL encoding is needed. If you must use special characters, percent-encode them in the URI.
- Admin scripts (`scripts/mongodb/grant_app_user.sh`, `test_auth.sh`, `run_cutover.sh`) now read `MONGO_ADMIN_PASSWORD` / `NEW_MONGO_URI` from the environment, no literals.
- Services using Mongo: identifier, account, chat (MONGODB_URI); invitation, workout, tracker, content (MONGO_URL); payments, statistics (MONGO_URI). Note: because users may be spread over several databases, the app user needs the roles granted by `grant_app_user.sh` (readWriteAnyDatabase).

Safe procedure to change the app user password (zero double-failure window):
1. Back up `.env.production` (section 4, step 1) and take a `mongodump` if a recent one does not exist.
2. Generate: `NEWPW=$(openssl rand -hex 24)` (shell variable only, do not echo it).
3. Change the password in mongod, inside the container or host shell, authenticated as admin. From the host: `mongosh "mongodb://adminUser:$MONGO_ROOT_PASSWORD@127.0.0.1:27017/admin?authSource=admin" --eval 'db.getSiblingDB("coachify").updateUser("<MONGO_APP_USER>", {pwd: process.env.NEWPW})'`. The password is passed through the `NEWPW` environment variable (`NEWPW=... mongosh ...`), not on the command line. For the container: `docker exec -e NEWPW="$NEWPW" -i coachify-mongodb mongosh -u adminUser -p "$LOCAL_MONGO_ROOT_PASSWORD" --authenticationDatabase admin --eval '...same updateUser...'`. Use `createUser` instead only if the user does not exist. The user's home database is the one used in `authSource`; check with `db.getSiblingDB("admin").system.users.find({user:"<MONGO_APP_USER>"},{db:1})`.
4. Existing connections keep working until they reconnect; new connections need the new password. Therefore update the env and restart immediately.
5. Edit `.env.production`: set the password inside `MONGODB_URI`, `MONGO_URL`, `MONGO_URI` (and `MONGO_APP_PASSWORD` in `.env` if the local profile is used).
6. Restart identifier, account, chat, invitation, workout, tracker, content, payments, statistics (`docker compose --env-file .env.production -f docker-compose.prod.yml up -d --force-recreate <services>`). A plain `restart` does not re-read the env file.
7. Admin password (MONGO_ROOT_PASSWORD): same `updateUser` against `admin` for `adminUser`, then update `.env.production`, then recreate the exporter: `docker compose --env-file .env.production -f docker-compose.monitoring.yml up -d --force-recreate mongodb-exporter`. If the local profile is used, also recreate `mongo-express` and set `LOCAL_MONGO_ROOT_PASSWORD`. Note: `MONGO_INITDB_ROOT_PASSWORD` only applies at first initialisation of an empty data directory; it does not change an existing user, so always run `updateUser`.
Rollback: `updateUser` back to the old password (kept in the `.env.production` backup), restore the backup file, recreate the services. Keep the old password valid until the verification in section 4 passes.

## 4. Third-party secrets (owner)

The owner rotates in each dashboard, then gives the new value to the operator, who puts it into `.env.production` (never in git, never in chat logs).

| Provider | Dashboard action | Update in `.env.production` |
|---|---|---|
| Mailgun | Create a new API key, delete the old one | MAILGUN_API_KEY |
| Google OAuth | Google Cloud Console, Credentials, OAuth client: add new secret, disable old | GOOGLE_APP_SECRET (and GOOGLE_CLIENT_SECRET) |
| Facebook | App settings, Basic, Reset app secret | FACEBOOK_APP_SECRET (and FACEBOOK_CLIENT_SECRET) |
| Stripe | Developers, API keys: roll the secret key; Webhooks: roll the signing secret of the endpoint | STRIPE_API_KEY, STRIPE_WEBHOOK_SECRET |
| Flouci | Developer dashboard: regenerate app keys and webhook secret | FLOUCI_API_KEY, FLOUCI_PUBLIC_KEY, FLOUCI_PRIVATE_KEY, FLOUCI_WEBHOOK_SECRET |
| Konnect | Wallet settings: regenerate API key and webhook secret | KONNECT_API_KEY, KONNECT_WEBHOOK_SECRET |
| Ably | App, API keys: create a new key (server) and a restricted client key, revoke the old | ABLY_API_KEY, NEXT_PUBLIC_ABLY_KEY (rebuild frontend image) |
| CloudAMQP | Instance: change the user password (or create a new user) in the management UI | CLOUDAMQP_URL, CLOUDAMQP_APIKEY |
| Cloudinary | Settings, API keys: generate a new key pair, revoke the old | CLOUDINARY_API_SECRET, NEXT_PUBLIC_CLOUDINARY_API_KEY |
| SMTP (Gmail app password for alerts) | Google account, Security, App passwords: delete old, create new | SMTP_PASSWORD, and write the same value to `monitoring/secrets/smtp_password` (file, mode 600, gitignored) |
| GitHub (GHCR) | Settings, Developer settings: new token, delete old | GHCR_TOKEN |
| MongoDB Atlas (old cluster) | Database Access: delete or change the password of the user that was in the old default URI | none (no longer used by services); do this first, it is the leaked one |

## 5. Ordered runbook

Maintenance window of about 15 minutes. Run on the server in the deploy directory.

1. Back up: `cp -p .env.production .env.production.bak.$(date +%Y%m%d%H%M%S)` and `chmod 600` the copy. Keep it until step 10 passes.
2. Prepare new values (do not print them): `COACHIFY_ENCRYPTION_KEY=$(openssl rand -hex 16)`, `COACHIFY_SECRET_KEY=$(openssl rand -hex 32)`, `AUTH_SECRET=$(openssl rand -base64 32)`, `GOOGLE_ENCRYPTION_KEY=$(openssl rand -hex 16)`, `FACEBOOK_ENCRYPTION_KEY=$(openssl rand -hex 16)`, new Mongo passwords (`openssl rand -hex 24`). Collect the owner's third-party values (section 4).
3. Change the Mongo passwords inside mongod (section 3 steps 3 and 7).
4. Edit `.env.production` with all new values (single edit, keep file mode 600). Write `monitoring/secrets/smtp_password`.
5. Force logout, clear the stored tokens (they are ciphertext of the old key and no longer decryptable). With mongosh as admin, in the database that holds `users.users` (database name `users` by default, collection `users`):
   `mongosh "<admin URI>" --eval 'db.getSiblingDB("users").users.updateMany({}, {$set: {token: null, refresh_token: null}})'`
   Add `{$unset: {"providers.google.access_token": "", "providers.google.refresh_token": ""}}` style updates for provider tokens if GOOGLE_ENCRYPTION_KEY or FACEBOOK_ENCRYPTION_KEY changed. If the `token` field is expected to be absent rather than null, use `$unset: {token: "", refresh_token: ""}` instead; check one document first with `findOne({}, {token: 1, refresh_token: 1})`.
6. Rebuild the frontend image only if NEXT_PUBLIC_ABLY_KEY or NEXT_PUBLIC_CLOUDINARY_API_KEY changed (they are baked at build time).
7. Restart order (all together, recreate so the env file is re-read): `docker compose --env-file .env.production -f docker-compose.prod.yml up -d --force-recreate identifier-api notification-api account-api chat-api content-api invitation-api payments-api workout-api tracker-api statistics-api frontend` and then `docker compose --env-file .env.production -f docker-compose.monitoring.yml up -d --force-recreate mongodb-exporter alertmanager grafana`. Database dependents first, then account (auth), then the rest, then the frontend. Do not leave a window where some services have the old COACHIFY_* values.
8. Verify: `docker ps --format '{{.Names}} {{.Status}}'` (all healthy); `docker logs --tail 50 coachify-account-api` shows no "required environment variables are missing" message (the services now exit with the NAME of any missing variable); `scripts/health-check.sh`; log in through the UI with a test account (new session works, old browser sessions are asked to log in); trigger a password reset mail (Mailgun); check Prometheus target `mongodb-exporter` is up; place a Stripe test checkout and check the webhook delivers (Stripe dashboard).
9. Revoke the old third-party credentials in the dashboards (section 4), now that the new ones are verified.
10. Delete the `.env.production.bak.*` file when everything is verified, and never copy it elsewhere.

Rollback (before step 9): restore the backup `.env.production`, restore the old Mongo password with `updateUser`, recreate the same services (step 7). Users stay logged out (tokens were cleared in step 5); this is harmless. After step 9 rollback is impossible for third-party values, so revoke last.

## 6. Git history

The old values still exist in git history of the service repos and in any clones/forks, so rotation (above) is mandatory and is the real fix. Rewriting history (git filter-repo or BFG, then force push, then everyone re-clones) is optional, separate work that only reduces future exposure; it does not make a leaked value safe again. Do not do it before rotation is complete.
