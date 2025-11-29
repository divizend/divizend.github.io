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
let sender_domain = "${BASE_DOMAIN}"
let sender_email = $inbox_name + "@" + $sender_domain

# Automatically determine receiver (original sender)
let receiver = $sender

# Business Logic: Call tool function from TOOLS_ROOT_GITHUB/index.ts
# The tool function name matches the inbox name (e.g., inbox "reverser" calls "reverser" function)
# For now, we use a script processor to call bun and execute the tool function
# The tool function will be called with the email data and return transformed text
let transformed_text = $original_text.split("").reverse().join("")

# Construct Resend API Payload with automatically determined emails
root.from = $inbox_name.capitalize() + " <" + $sender_email + ">"
root.to = [$receiver]
root.subject = "Re: " + $subject
root.html = "<p>Here is your transformed text:</p><blockquote>" + $transformed_text + "</blockquote>"`,
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
