import type { Email } from "bentotools";

// Tool functions - these are called by transform_email stream
// Each function takes an Email and returns a transformed string
export const reverser = (email: Email): string => {
  return email.text!.split("").reverse().join("");
};

// Bento stream definitions
// These are exported as stream configurations that Bento will use directly

export const ingest_email = {
  input: {
    http_server: {
      path: "/webhooks/resend",
      allowed_verbs: ["POST"],
      timeout: "5s",
    },
  },
  pipeline: {
    processors: [
      {
        bloblang: `# Bento http_server provides the body as the root content
# Try to parse JSON if it's a string, otherwise use as-is
# TODO: Add Svix signature verification once header access is confirmed
root = if this.type() == "string" { this.parse_json() } else { this }`,
      },
    ],
  },
  output: {
    s2: {
      basin: "${S2_BASIN}",
      stream: 'inbox/${!this.data.to[0].split("@")[0]}',
      auth_token: "${S2_ACCESS_TOKEN}",
    },
  },
};

export const transform_email = {
  input: {
    s2: {
      basin: "${S2_BASIN}",
      streams: "inbox/",
      auth_token: "${S2_ACCESS_TOKEN}",
      cache: "s2_inbox_cache",
    },
  },
  pipeline: {
    processors: [
      {
        bloblang: `# Extract relevant fields from Resend Payload
let original_text = this.data.text | ""
let sender = this.data.from
let subject = this.data.subject
let recipient_email = this.data.to[0] | ""

# Extract inbox name from recipient email (e.g., "reverser@domain.com" -> "reverser")
let inbox_name = $recipient_email.split("@")[0] | ""
let sender_domain = "\${BASE_DOMAIN}"
let sender_email = $inbox_name + "@" + $sender_domain

# Automatically determine receiver (original sender)
let receiver = $sender

# Store email data for script processor
root._email_data = {
  "text": $original_text,
  "html": this.data.html | "",
  "from": $sender,
  "to": this.data.to,
  "subject": $subject
}
root._inbox_name = $inbox_name
root._sender_email = $sender_email
root._receiver = $receiver
root._subject = $subject`,
      },
      {
        script: {
          language: "javascript",
          code: `
// Import tools from local index.ts (we're in /opt/bento-sync)
const tools = await import("./index.ts");
import type { Email } from "bentotools";

const inboxName = root._inbox_name;
const emailData = root._email_data;

// Get the tool function that matches the inbox name
const toolFunction = tools[inboxName];

if (!toolFunction || typeof toolFunction !== "function") {
  throw new Error("Tool function \\"" + inboxName + "\\" not found in index.ts");
}

// Construct Email object
const email: Email = {
  text: emailData.text || null,
  html: emailData.html || null,
  from: emailData.from,
  to: emailData.to,
  subject: emailData.subject,
};

// Call the tool function
const transformed_text = toolFunction(email);

// Set the transformed text
root._transformed_text = transformed_text;
`,
        },
      },
      {
        bloblang: `# Construct Resend API Payload with automatically determined emails
root.from = root._inbox_name.capitalize() + " <" + root._sender_email + ">"
root.to = [root._receiver]
root.subject = "Re: " + root._subject
root.html = "<p>Here is your transformed text:</p><blockquote>" + root._transformed_text + "</blockquote>"
# Clean up temporary fields
root = root.delete("_email_data").delete("_inbox_name").delete("_sender_email").delete("_receiver").delete("_subject").delete("_transformed_text")`,
      },
    ],
  },
  output: {
    s2: {
      basin: "${S2_BASIN}",
      stream: "outbox",
      auth_token: "${S2_ACCESS_TOKEN}",
    },
  },
};

export const send_email = {
  input: {
    s2: {
      basin: "${S2_BASIN}",
      streams: "outbox",
      auth_token: "${S2_ACCESS_TOKEN}",
      cache: "s2_outbox_cache",
    },
  },
  output: {
    http_client: {
      url: "https://api.resend.com/emails",
      verb: "POST",
      headers: {
        Authorization: "Bearer ${RESEND_API_KEY}",
        "Content-Type": "application/json",
      },
      retries: 3,
    },
  },
};
