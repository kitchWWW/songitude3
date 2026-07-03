// Songitude — presign Lambda (Function URL).
// Verifies a Google ID token against an allowlist, then returns a presigned S3 PUT URL so the
// browser uploads the (possibly huge) bundle zip DIRECTLY to S3 — no file passes through Lambda.
//
// Env: WALKS_BUCKET, GOOGLE_CLIENT_ID, ALLOWED_EMAILS (comma-separated), ALLOW_ORIGIN
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { randomUUID } from "crypto";

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
    if (body.check === true) return resp(200, JSON.stringify({ authorized, email }));
    if (!authorized) return resp(403, "This Google account isn't approved yet. Email brian.e2014@gmail.com to request access.");

    const name = String(body.name || "Untitled sound walk").slice(0, 120);
    const creator = String(body.creator || "").slice(0, 120);
    const about = String(body.about || "").slice(0, 2000);
    const walkId = slug(name) + "-" + randomUUID().slice(0, 8);

    // Store lightweight metadata now (the manifest builder reads this — no need to unzip).
    const meta = {
      id: walkId, name, creator, about,
      center: Array.isArray(body.center) ? body.center : null,
      zoom: Number(body.zoom) || 16,
      shapeCount: Number(body.shapeCount) || 0,
      owner: email, updatedAt: new Date().toISOString(),
    };
    await s3.send(new PutObjectCommand({
      Bucket: BUCKET, Key: `walks/${walkId}/meta.json`,
      Body: JSON.stringify(meta), ContentType: "application/json",
    }));

    const uploadUrl = await getSignedUrl(s3, new PutObjectCommand({
      Bucket: BUCKET, Key: `walks/${walkId}/bundle.zip`, ContentType: "application/zip",
    }), { expiresIn: 3600 });

    return resp(200, JSON.stringify({ uploadUrl, walkId }));
  } catch (e) {
    console.error(e);
    return resp(500, "error: " + (e?.message || String(e)));
  }
};
