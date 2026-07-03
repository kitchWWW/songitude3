// Songitude — manifest + unpack Lambda.
// Triggered by S3 ObjectCreated on walks/*/bundle.zip. It (1) unpacks the zip into individual
// public objects under walks/<id>/ (map.json, audio/*, album art) so the iOS app can download
// only the files it needs, and (2) rebuilds walks/manifest.json from every complete walk.
//
// Env: WALKS_BUCKET, PUBLIC_BASE (e.g. https://songitude-walks.s3.amazonaws.com)
import { S3Client, ListObjectsV2Command, GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
import AdmZip from "adm-zip";

const BUCKET = process.env.WALKS_BUCKET;
const PUBLIC_BASE = (process.env.PUBLIC_BASE || "").replace(/\/+$/, "");
const s3 = new S3Client({});

function contentType(name) {
  const n = name.toLowerCase();
  if (n.endsWith(".json")) return "application/json";
  if (n.endsWith(".mp3")) return "audio/mpeg";
  if (n.endsWith(".wav")) return "audio/wav";
  if (n.endsWith(".m4a") || n.endsWith(".aac")) return "audio/aac";
  if (n.endsWith(".ogg")) return "audio/ogg";
  if (n.endsWith(".caf")) return "audio/x-caf";
  if (n.endsWith(".jpg") || n.endsWith(".jpeg")) return "image/jpeg";
  if (n.endsWith(".png")) return "image/png";
  return "application/octet-stream";
}

async function unpack(id) {
  const obj = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: `walks/${id}/bundle.zip` }));
  const buf = Buffer.from(await obj.Body.transformToByteArray());
  const zip = new AdmZip(buf);
  for (const entry of zip.getEntries()) {
    if (entry.isDirectory) continue;
    await s3.send(new PutObjectCommand({
      Bucket: BUCKET, Key: `walks/${id}/${entry.entryName}`,
      Body: entry.getData(), ContentType: contentType(entry.entryName),
    }));
  }
  console.log(`unpacked walks/${id}/ (${zip.getEntries().length} entries)`);
}

async function rebuildManifest() {
  const walks = {};
  let token;
  do {
    const r = await s3.send(new ListObjectsV2Command({ Bucket: BUCKET, Prefix: "walks/", ContinuationToken: token }));
    for (const o of r.Contents || []) {
      const m = o.Key.match(/^walks\/([^/]+)\/(bundle\.zip|meta\.json)$/);
      if (!m) continue;
      const w = (walks[m[1]] ||= {});
      if (m[2] === "bundle.zip") { w.zip = true; w.size = o.Size; w.updatedAt = o.LastModified?.toISOString?.() || null; }
      else w.meta = true;
    }
    token = r.IsTruncated ? r.NextContinuationToken : undefined;
  } while (token);

  const items = [];
  for (const [id, w] of Object.entries(walks)) {
    if (!(w.zip && w.meta)) continue;
    try {
      const g = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: `walks/${id}/meta.json` }));
      const meta = JSON.parse(await g.Body.transformToString());
      items.push({
        id, name: meta.name, creator: meta.creator || "", about: meta.about || "",
        center: meta.center, zoom: meta.zoom, shapeCount: meta.shapeCount, owner: meta.owner,
        updatedAt: meta.updatedAt || w.updatedAt, sizeBytes: w.size,
        base: `${PUBLIC_BASE}/walks/${id}`,
        mapUrl: `${PUBLIC_BASE}/walks/${id}/map.json`,
        zipUrl: `${PUBLIC_BASE}/walks/${id}/bundle.zip`,
      });
    } catch (e) { console.error("meta read failed for", id, e); }
  }
  items.sort((a, b) => String(b.updatedAt || "").localeCompare(String(a.updatedAt || "")));

  const manifest = { version: 1, generatedAt: new Date().toISOString(), walks: items };
  await s3.send(new PutObjectCommand({
    Bucket: BUCKET, Key: "walks/manifest.json",
    Body: JSON.stringify(manifest, null, 2), ContentType: "application/json", CacheControl: "no-cache",
  }));
  console.log("wrote manifest with", items.length, "walks");
  return items.length;
}

export const handler = async (event) => {
  for (const rec of event?.Records || []) {
    const key = decodeURIComponent((rec.s3?.object?.key || "").replace(/\+/g, " "));
    const m = key.match(/^walks\/([^/]+)\/bundle\.zip$/);
    // Only unpack on upload; deletes (ObjectRemoved) just trigger a manifest rebuild.
    if (m && (rec.eventName || "").startsWith("ObjectCreated")) {
      try { await unpack(m[1]); } catch (e) { console.error("unpack failed", m[1], e); }
    }
  }
  const n = await rebuildManifest();
  return { statusCode: 200, body: `manifest: ${n} walks` };
};
