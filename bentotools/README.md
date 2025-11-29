# Bento Tools

This directory contains TypeScript tools and type definitions for Bento stream processing.

## Structure

- `index.ts` - Main tools export (e.g., `reverser` function)
- `types.ts` - TypeScript type definitions for Resend email webhooks

## Auto-Sync

The Bento instance automatically syncs these tools from `https://setup.divizend.com/bentotools` via:
- GitHub Actions workflow (on push to main)
- Terraform daemon (periodic sync every 5 minutes)

## Usage

Tools are automatically loaded by Bento and can be referenced in stream configurations.

