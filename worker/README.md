# Holiday Resort Owner API (Cloudflare Workers free tier)

This Worker replaces the legacy Firebase callable functions. The Flutter app sends its Firebase Authentication ID token as a Bearer token. The Worker verifies the token against Google's Firebase public JWKs, validates the account and unit in Firestore, then uses Firestore REST transactions with a dedicated service account.

No service-account key is stored in Flutter or committed here.

## Firebase setup

1. In Google Cloud IAM for project `holiday-resort-7fa3f`, create a dedicated service account such as `holiday-resort-worker`.
2. Grant only `Cloud Datastore User` (`roles/datastore.user`). This permits document reads/writes without granting project administration.
3. Create a JSON key for that service account. Extract `client_email` and `private_key` for the Worker secrets, then store the downloaded JSON securely outside the repository.
4. Keep Firebase Authentication and Cloud Firestore enabled on the Spark plan.

## Cloudflare setup

```powershell
cd worker
npm ci
npx wrangler login
npx wrangler secret put FIREBASE_CLIENT_EMAIL
npx wrangler secret put FIREBASE_PRIVATE_KEY
npm test
npx wrangler deploy
```

Paste the service-account `client_email` into the first secret. Paste the complete PEM private key, including its BEGIN/END lines, into the second.

The only non-secret Worker variable is `FIREBASE_PROJECT_ID`, stored in `wrangler.toml`.

## Build the Owner App

After deployment, build with the HTTPS Worker URL printed by Wrangler:

```powershell
flutter build apk --release --dart-define=OWNER_API_BASE_URL=https://holiday-resort-owner-api.holiday-resort-mrx.workers.dev
```

The app intentionally fails QR operations with an Arabic configuration error when `OWNER_API_BASE_URL` is absent. It never falls back to local/mock QR data.

## Local development

Copy `.dev.vars.example` to `.dev.vars` and replace placeholders locally. `.dev.vars` is ignored by Git.

```powershell
npm run dev
flutter run --dart-define=OWNER_API_BASE_URL=http://localhost:8787
```

## Endpoints

- `POST /generate-guest-qr`
- `POST /cancel-guest-qr`
- `POST /generate-delivery-qr`
- `POST /validate-and-use-qr` (Security/Admin roles only)
- `POST /inspect-qr` (Security/Admin, non-consuming)
- `POST /create-entry-draft` (Security/Admin, 15-minute upload context)
- `POST /set-entry-visitor-id-state` (Security/Admin, explicit audited No-ID state)
- `POST /upload-entry-id-image` (Security/Admin, private Supabase upload)
- `POST /confirm-entry` (Security/Admin, atomic final consumption)

Every endpoint requires a valid Firebase ID token. The Worker never trusts submitted owner IDs and rechecks `users/{uid}` plus `units/{unitId}` inside the Firestore transaction.

The ID upload endpoint reads `SUPABASE_URL` and `SUPABASE_SECRET_KEY` only from
Worker environment secrets and writes to the private `gate-id-cards` bucket.
Clients receive only private object paths; no public or permanent download URLs
are created. Pending drafts contain a 15-minute expiry and cleanup timestamp.
