Hey :relaxed: I'm currently trying to build a system with a stack like this:
- using the Resend API (https://resend.com) to send and receive emails
- using S2 (https://s2.dev/) to handle the underlying streams
- using Bento (https://warpstreamlabs.github.io/bento/docs/about) as the stream processor

My end goal is that I can send an email into Resend. These emails should then land in respective S2 streams, should be picked up by Bento and then Bento should perform some sort of action on them. As the most minimal example I want this (assuming that S2, which should be the central message hub, is already set up with the basin `s2://mydomain` and mydomain.com is configured as a domain in Resend):
1. I send an email to `reverser@mydomain.com` with the text "Hello world"
2. Resend gets this email and emits an "email.received" webhook.
3. This webhook should be picked up by Bento.
4. Bento should forward the received email into the S2 stream `s2://mydomain/inbox/reverser`
5. A different handler within Bento should notice that a new message was inserted into `s2://mydomain/inbox/reverser`
6. The business logic of that handler should be that it replies to the sender of that email with the content reversed, i.e. the handler would produce `dlrow olleH`
7. The handler should then insert the full email to be sent (i.e. the JSON payload for Resend's "POST /emails" endpoint) into `s2://mydomain/outbox`
8. Finally yet another handler in Bento should pick up that something new was added to `s2://mydomain/outbox` and call the Resend API to finally send out the reply

Give me the complete source code of a single fully production-ready BASH script to be hosted at https://setup.divizend.com/setup.sh, including a smooth way for me to interactively provide you with the base domain I want to use (what's "mydomain.com" in the example above), S2_ACCESS_TOKEN, RESEND_API_KEY and RESEND_WEBHOOK_SECRET (for that last one, first output the endpoint I should use to set up the webhook within Resend before asking for me to input RESEND_WEBHOOK_SECRET) so that I can execute "curl -fsSL https://setup.divizend.com/setup.sh | bash" on a fresh vanilla Ubuntu server and it immediately just works. The server should be configured to use streams.mydomain.com as its domain, including HTTPS. There should be no traces of "Divizend" in the script. Also make sure that the script is idempotent
