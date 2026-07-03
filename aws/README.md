# Songitude publish backend (serverless)

No server to run — just S3 + two Lambdas. Everything here is **additive** and lives in a **new,
isolated bucket** (`songitude-walks`); it never touches the `songitude.com` site bucket.

## Flow

```
Editor (browser)                         AWS
  ── sign in with Google ─────────────▶  (client-side)
  ── POST {name,center,zoom} + token ─▶  presign Lambda (Function URL)
       verifies token vs allowlist,          │ writes walks/<id>/meta.json
       returns presigned PUT url  ◀───────────┘ returns { uploadUrl, walkId }
  ── PUT bundle.zip ──────────────────▶  S3  walks/<id>/bundle.zip   (direct, any size)
                                             │ ObjectCreated(suffix=bundle.zip)
                                             ▼
                                        manifest Lambda → rebuilds walks/manifest.json
iOS app  ── GET walks/manifest.json ─▶  S3 (public read)  → list + download walks
```

Big files never pass through Lambda (presigned S3 upload), so hundred-MB+ walks are fine.

## Deploy

```bash
export GOOGLE_CLIENT_ID="....apps.googleusercontent.com"
export ALLOWED_EMAILS="you@gmail.com,collaborator@gmail.com"
bash deploy.sh
```

It prints two URLs:
- **Publish API** → paste into `editor/config.js` `publishApiUrl`.
- **Manifest URL** → used by the iOS app.

Update the allowlist any time with:
```bash
aws lambda update-function-configuration --function-name songitude-presign \
  --environment "Variables={WALKS_BUCKET=songitude-walks,GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID,ALLOWED_EMAILS=a@x.com,b@y.com,ALLOW_ORIGIN=https://songitude.com}"
```

## Create the Google OAuth Web client (one-time, in *your* Google account)

1. https://console.cloud.google.com/ → create/select a project (e.g. "Songitude").
2. **APIs & Services → OAuth consent screen** → External → fill app name + your email → Save.
   (Add your allowlisted emails as **Test users** while it's in "Testing".)
3. **APIs & Services → Credentials → Create credentials → OAuth client ID → Web application**.
4. **Authorized JavaScript origins**: add `https://songitude.com`, `https://www.songitude.com`,
   and `http://localhost:8000` (for local editor testing).
5. Create → copy the **Client ID** (`…apps.googleusercontent.com`).
6. Put it in `editor/config.js` `googleClientId` and pass it to `deploy.sh` as `GOOGLE_CLIENT_ID`.
