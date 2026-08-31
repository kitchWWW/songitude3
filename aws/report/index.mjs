// Songitude — report Lambda (Function URL).
// Takes a report from the app's Settings → Report section and emails it, verbatim, to the address
// in REPORT_TO. No account or identifier is involved: the app sends only what the person typed
// plus which walk they were looking at.
//
// Env: REPORT_TO, REPORT_FROM (both must be SES-verified while the account is in the sandbox)
import { SESv2Client, SendEmailCommand } from "@aws-sdk/client-sesv2";

const ses = new SESv2Client({});
const TO = process.env.REPORT_TO;
const FROM = process.env.REPORT_FROM || TO;

const KINDS = { walk: "Soundwalk", artist: "Artist", issue: "App issue" };
const clip = (s, n) => String(s ?? "").slice(0, n);

function cors() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
    "Access-Control-Max-Age": "3000",
  };
}
const resp = (code, body) => ({ statusCode: code, headers: { ...cors(), "Content-Type": "text/plain" }, body });

export const handler = async (event) => {
  if (event?.requestContext?.http?.method === "OPTIONS") return { statusCode: 204, headers: cors() };
  try {
    const b = JSON.parse(event.body || "{}");
    const kind = KINDS[b.kind] ? b.kind : "issue";
    const message = clip(b.message, 5000).trim();
    if (!message) return resp(400, "empty report");

    const subjectName = clip(b.subjectName, 200).trim();
    const subject = `[Songitude report] ${KINDS[kind]}${subjectName ? ": " + subjectName : ""}`;

    // Everything the app knows, laid out plainly — no interpretation, no filtering.
    const lines = [
      `Type:        ${KINDS[kind]}`,
      subjectName ? `Subject:     ${subjectName}` : null,
      b.walkId ? `Walk id:     ${clip(b.walkId, 120)}` : null,
      b.artist ? `Artist:      ${clip(b.artist, 200)}` : null,
      b.appVersion ? `App version: ${clip(b.appVersion, 40)}` : null,
      b.device ? `Device:      ${clip(b.device, 80)}` : null,
      `Received:    ${new Date().toISOString()}`,
      "",
      "----- what they wrote -----",
      message,
    ].filter(Boolean);

    await ses.send(new SendEmailCommand({
      FromEmailAddress: FROM,
      Destination: { ToAddresses: [TO] },
      Content: { Simple: {
        Subject: { Data: subject },
        Body: { Text: { Data: lines.join("\n") } },
      } },
    }));
    return resp(200, "sent");
  } catch (e) {
    console.error(e);
    return resp(500, "could not send that report");
  }
};
