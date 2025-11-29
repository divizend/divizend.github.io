/**
 * Resend Email Webhook Payload Types
 * Based on Resend API webhook structure for email.received events
 */

export interface EmailAddress {
  email: string;
  name?: string;
}

export interface EmailAttachment {
  filename: string;
  content_type: string;
  size: number;
  content_id?: string;
}

export interface EmailHeaders {
  [key: string]: string | string[];
}

export interface Email {
  id: string;
  from: string;
  to: string[];
  cc?: string[];
  bcc?: string[];
  reply_to?: string[];
  subject: string;
  html?: string;
  text?: string;
  created_at: string;
  headers?: EmailHeaders;
  attachments?: EmailAttachment[];
  tags?: Array<{ name: string; value: string }>;
}

export interface ResendWebhookPayload {
  type: string; // e.g., "email.received"
  created_at: string;
  data: Email;
}

