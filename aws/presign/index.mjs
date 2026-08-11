// Songitude — presign Lambda (Function URL).
// Verifies a Google ID token against an allowlist, then returns a presigned S3 PUT URL so the
// browser uploads the (possibly huge) bundle zip DIRECTLY to S3 — no file passes through Lambda.
//
// It also stores per-artist profiles (display name + markdown bio + page colour) at
// artists/<artistId>.json, where artistId is derived from the signed-in email so it is stable
// across sessions and never exposes the address itself.
//
// Env: WALKS_BUCKET, GOOGLE_CLIENT_ID, ALLOWED_EMAILS (comma-separated), ALLOW_ORIGIN
import { S3Client, PutObjectCommand, GetObjectCommand, ListObjectsV2Command, DeleteObjectsCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { randomUUID, createHash } from "crypto";

const BUCKET = process.env.WALKS_BUCKET;
const CLIENT_ID = process.env.GOOGLE_CLIENT_ID;
const ALLOWED = (process.env.ALLOWED_EMAILS || "").toLowerCase().split(",").map(s => s.trim()).filter(Boolean);
const s3 = new S3Client({});

const ALLOWED_ORIGINS = (process.env.ALLOW_ORIGIN || "https://songitude.com")
  .split(",").map(s => s.trim()).concat(["https://www.songitude.com", "http://localhost:8000", "http://localhost:5173"]);
let currentOrigin = ALLOWED_ORIGINS[0];
function cors() {
  return {
    "Access-Control-Allow-Origin": currentOrigin,
    "Access-Control-Allow-Methods": "POST,OPTIONS",
    "Access-Control-Allow-Headers": "authorization,content-type",
    "Access-Control-Max-Age": "3000",
  };
}
function resp(code, body) {
  return { statusCode: code, headers: { ...cors(), "Content-Type": code === 200 ? "application/json" : "text/plain" }, body };
}
function slug(s) {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "walk";
}

// Stable public id for an artist. A hash keeps the account's email out of every published object
// while still resolving to the same profile on every sign-in.
function artistIdFor(email) {
  return createHash("sha256").update(String(email).toLowerCase()).digest("hex").slice(0, 16);
}


async function readArtist(artistId) {
  try {
    const g = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: `artists/${artistId}.json` }));
    return JSON.parse(await g.Body.transformToString());
  } catch { return null; }
}

async function writeArtist(artistId, body) {
  const bg = String(body.bgColor || "");
  const profile = {
    id: artistId,
    name: String(body.name || "").slice(0, 120),
    bio: String(body.bio || "").slice(0, 20000),       // markdown source
    // null ⇒ the artist chose "use system colors"; every reader supplies its own background.
    bgColor: /^#[0-9a-fA-F]{6}$/.test(bg) ? bg.toLowerCase() : null,
    updatedAt: new Date().toISOString(),
  };
  await s3.send(new PutObjectCommand({
    Bucket: BUCKET, Key: `artists/${artistId}.json`,
    Body: JSON.stringify(profile), ContentType: "application/json", CacheControl: "no-cache",
  }));
  return profile;
}

export const handler = async (event) => {
  const origin = event?.headers?.origin || event?.headers?.Origin || "";
  if (ALLOWED_ORIGINS.includes(origin)) currentOrigin = origin;
  const method = event?.requestContext?.http?.method;
  if (method === "OPTIONS") return { statusCode: 204, headers: cors() };
  try {
    const auth = event.headers?.authorization || event.headers?.Authorization || "";
    const token = auth.replace(/^Bearer\s+/i, "").trim();
    if (!token) return resp(401, "missing token");

    // Verify the Google ID token (audience + verified email), then check the allowlist.
    const info = await fetch("https://oauth2.googleapis.com/tokeninfo?id_token=" + encodeURIComponent(token))
      .then(r => r.ok ? r.json() : null);
    if (!info || info.aud !== CLIENT_ID) return resp(401, "invalid token");
    if (String(info.email_verified) !== "true") return resp(403, "email not verified");
    const email = (info.email || "").toLowerCase();
    const authorized = ALLOWED.includes(email);

    const body = JSON.parse(event.body || "{}");
    // Lightweight access check used by the editor gate right after sign-in.
    if (body.check === true) {
      const artistId = artistIdFor(email);
      const artist = authorized ? await readArtist(artistId) : null;
      return resp(200, JSON.stringify({ authorized, email, artistId, artist }));
    }
    if (!authorized) return resp(403, "This Google account isn't approved yet. Email brian.e2014@gmail.com to request access.");

    // Artist profile — always scoped to the caller's own id, so one account can't edit another's.
    if (body.action === "artistGet" || body.action === "artistPut") {
      const artistId = artistIdFor(email);
      if (body.action === "artistGet") {
        const artist = await readArtist(artistId);
        return resp(200, JSON.stringify({ artistId, artist }));
      }
      return resp(200, JSON.stringify({ artistId, artist: await writeArtist(artistId, body) }));
    }

    // Manage an existing walk — owner only.
    if (body.action === "delete" || body.action === "update") {
      const walkId = String(body.walkId || "");
      if (!/^[\w.-]+$/.test(walkId)) return resp(400, "bad walkId");
      const owner = await ownerOf(walkId);
      if (owner === null) return resp(404, "walk not found");
      if (owner !== email) return resp(403, "this walk belongs to someone else");
      if (body.action === "delete") { await deleteWalk(walkId); return resp(200, JSON.stringify({ deleted: walkId })); }
      return resp(200, JSON.stringify(await writeMetaAndPresign(walkId, body, email)));  // update existing id
    }

    // New publish → fresh id.
    const walkId = slug(String(body.name || "Untitled sound walk")) + "-" + randomUUID().slice(0, 8);
    return resp(200, JSON.stringify(await writeMetaAndPresign(walkId, body, email)));
  } catch (e) {
    console.error(e);
    return resp(500, "error: " + (e?.message || String(e)));
  }
};

async function writeMetaAndPresign(walkId, body, email) {
  // The artist profile is the single source of truth for the display name when one exists, so a
  // rename propagates to every walk on its next publish instead of drifting per bundle.
  const artistId = artistIdFor(email);
  const artist = await readArtist(artistId);
  const meta = {
    id: walkId,
    name: String(body.name || "Untitled sound walk").slice(0, 120),
    creator: String(artist?.name || body.creator || "").slice(0, 120),
    artistId,
    about: String(body.about || "").slice(0, 2000),
    center: Array.isArray(body.center) ? body.center : null,
    zoom: Number(body.zoom) || 16,
    shapeCount: Number(body.shapeCount) || 0,
    owner: email, updatedAt: new Date().toISOString(),
    // Rights attestation. The client stamp is when the author ticked the box; the server stamp is
    // when we received it — a client clock can be wrong or set deliberately, so keep both.
    rightsConfirmedAt: /^\d{4}-\d{2}-\d{2}T[\d:.]+Z$/.test(String(body.rightsConfirmedAt || ""))
      ? String(body.rightsConfirmedAt) : null,
    rightsConfirmedReceivedAt: body.rightsConfirmedAt ? new Date().toISOString() : null,
  };
  await s3.send(new PutObjectCommand({
    Bucket: BUCKET, Key: `walks/${walkId}/meta.json`, Body: JSON.stringify(meta), ContentType: "application/json",
  }));
  const uploadUrl = await getSignedUrl(s3, new PutObjectCommand({
    Bucket: BUCKET, Key: `walks/${walkId}/bundle.zip`, ContentType: "application/zip",
  }), { expiresIn: 3600 });
  return { uploadUrl, walkId };
}

async function ownerOf(walkId) {
  try {
    const g = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: `walks/${walkId}/meta.json` }));
    return (JSON.parse(await g.Body.transformToString()).owner || "").toLowerCase();
  } catch { return null; }
}

async function deleteWalk(id) {
  let token;
  do {
    const r = await s3.send(new ListObjectsV2Command({ Bucket: BUCKET, Prefix: `walks/${id}/`, ContinuationToken: token }));
    const objs = (r.Contents || []).map((o) => ({ Key: o.Key }));
    if (objs.length) await s3.send(new DeleteObjectsCommand({ Bucket: BUCKET, Delete: { Objects: objs } }));
    token = r.IsTruncated ? r.NextContinuationToken : undefined;
  } while (token);
}
