# Email Stream Processing System

A production-ready, event-driven email processing platform that transforms email into a programmable, stream-based workflow system.

## Purpose

This system enables you to build intelligent email processing workflows where incoming emails trigger automated, customizable business logic. Instead of traditional email servers that simply store and forward messages, this system treats email as **streams of events** that flow through a processing pipeline.

### Core Functionality

1. **Email Ingestion**: Receives emails via Resend webhooks and routes them into S2 streams
2. **Stream Processing**: Processes emails through configurable Bento pipelines
3. **Tool-Based Logic**: Executes custom JavaScript/TypeScript functions based on inbox names
4. **Automated Responses**: Generates and sends replies through the same stream-based architecture
5. **Self-Managing**: Automated deployment, secret management, and health monitoring

### Example Workflow

```
Email → Resend Webhook → S2 Stream (inbox/reverser) → Bento Processor → 
Custom Tool Function → S2 Stream (outbox) → Resend API → Reply Email
```

## Benefits Over Traditional Software

### 1. **Event-Driven Architecture**
- **Traditional**: Polling, scheduled jobs, database queries
- **This System**: Real-time event streams, immediate processing, zero polling overhead
- **Benefit**: Lower latency, reduced resource usage, true real-time responsiveness

### 2. **Stream-Based Data Flow**
- **Traditional**: Relational databases, complex joins, state management
- **This System**: Append-only streams, immutable event log, natural audit trail
- **Benefit**: Better scalability, built-in replay capabilities, simpler debugging

### 3. **Decoupled Components**
- **Traditional**: Tightly coupled services, shared databases, complex dependencies
- **This System**: Independent processors, stream-based communication, loose coupling
- **Benefit**: Easy to scale individual components, fault isolation, independent deployment

### 4. **Tool-Based Extensibility**
- **Traditional**: Monolithic applications, code deployments, version conflicts
- **This System**: Dynamic tool loading from Git, hot-reloadable functions, version-controlled logic
- **Benefit**: Add new email handlers without redeployment, version control for business logic, rapid iteration

### 5. **Zero-Configuration Secrets Management**
- **Traditional**: Environment files, manual secret rotation, security risks
- **This System**: Encrypted secrets with SOPS, automatic key management, secure by default
- **Benefit**: No secrets in code, automatic encryption, multi-recipient access control

### 6. **Idempotent, Self-Healing Deployment**
- **Traditional**: Manual setup, configuration drift, inconsistent environments
- **This System**: One-command setup, idempotent operations, automatic health checks
- **Benefit**: Reproducible deployments, self-recovery, zero-downtime updates

### 7. **No Vendor Lock-In**
- **Traditional**: Proprietary platforms, closed ecosystems, migration costs
- **This System**: Open-source components, standard protocols, portable architecture
- **Benefit**: Full control, no licensing fees, easy migration

### 8. **Observable by Design**
- **Traditional**: Log aggregation, external monitoring, complex instrumentation
- **This System**: Stream-based events, built-in observability, natural audit logs
- **Benefit**: Complete event history, easy debugging, transparent data flow

### 9. **Cost Efficiency**
- **Traditional**: Always-on servers, database licenses, scaling costs
- **This System**: Event-driven processing, pay-per-use streams, minimal infrastructure
- **Benefit**: Lower operational costs, automatic scaling, resource optimization

### 10. **Developer Experience**
- **Traditional**: Complex setup, environment management, deployment pipelines
- **This System**: Single-command deployment, automated configuration, Git-based tool management
- **Benefit**: Faster development cycles, reduced operational burden, focus on business logic

## Architecture

```
                    ╔═══════════════════════════════════════════════════════════╗
                    ║              Email Stream Processing System              ║
                    ╚═══════════════════════════════════════════════════════════╝

    📧 Incoming Email
         │
         │  (SMTP/IMAP)
         ▼
    ┌─────────────────┐
    │   📮 Resend     │  Email Service (Mailbox/Post Office)
    │   Email API     │
    └────────┬────────┘
             │
             │  Webhook Event (email.received)
             │  🔔
             ▼
    ┌─────────────────┐
    │   🚪 Caddy      │  Reverse Proxy (Gateway/Router)
    │   HTTPS Proxy   │  • Automatic TLS
    └────────┬────────┘  • Request Routing
             │
             │  HTTP POST /webhooks/resend
             │  🔐 (Svix Signature Verified)
             ▼
    ┌─────────────────────────────────────────────────────────┐
    │   ⚙️  Bento Stream Processor (Factory/Workshop)          │
    │   ┌───────────────────────────────────────────────────┐ │
    │   │  📥 ingest_email Stream                           │ │
    │   │  • Receives webhook payload                       │ │
    │   │  • Parses JSON event                              │ │
    │   │  • Validates signature                            │ │
    │   └───────────────┬───────────────────────────────────┘ │
    │                   │                                      │
    │                   │  Processed Event                     │
    │                   ▼                                      │
    │   ┌───────────────────────────────────────────────────┐ │
    │   │  🔄 transform_email Stream                        │ │
    │   │  • Extracts email metadata                        │ │
    │   │  • Routes to inbox stream                         │ │
    │   │  • Loads tool function from Git                    │ │
    │   │  • Executes custom JavaScript logic                │ │
    │   └───────────────┬───────────────────────────────────┘ │
    │                   │                                      │
    │                   │  Transformed Event                   │
    │                   ▼                                      │
    │   ┌───────────────────────────────────────────────────┐ │
    │   │  📤 send_email Stream                             │ │
    │   │  • Formats Resend API payload                     │ │
    │   │  • Queues for delivery                            │ │
    │   └───────────────┬───────────────────────────────────┘ │
    └───────────────────┼──────────────────────────────────────┘
                        │
                        │  Event Streams (Append-Only Logs)
                        ▼
    ┌─────────────────────────────────────────────────────────┐
    │   🌊 S2 Stream Store (River/Event Log)                  │
    │   ┌───────────────────────────────────────────────────┐ │
    │   │  📬 inbox/reverser  (Incoming Mail Stream)        │ │
    │   │  📬 inbox/translator                               │ │
    │   │  📬 inbox/*          (Dynamic Routing)            │ │
    │   └───────────────────────────────────────────────────┘ │
    │   ┌───────────────────────────────────────────────────┐ │
    │   │  📮 outbox          (Outgoing Mail Queue)         │ │
    │   │  • Queued replies                                  │ │
    │   │  • Scheduled sends                                 │ │
    │   └───────────────────────────────────────────────────┘ │
    │                                                          │
    │  Stream Operations:                                      │
    │  • Append-only event log                                 │
    │  • Immutable history                                     │
    │  • Real-time subscriptions                               │
    │  • Automatic persistence                                 │
    └───────────────┬──────────────────────────────────────────┘
                    │
                    │  Stream Events (Read/Write)
                    │  🔄
                    ▼
    ┌─────────────────────────────────────────────────────────┐
    │   🛠️  Tool Functions (GitHub Repository)                │
    │   ┌───────────────────────────────────────────────────┐ │
    │   │  📚 /bentotools/index.ts                          │ │
    │   │  • reverser(email) → reversed text                 │ │
    │   │  • translator(email) → translated text             │ │
    │   │  • custom(email) → your logic                      │ │
    │   └───────────────────────────────────────────────────┘ │
    │                                                          │
    │  🔄 Auto-synced from Git                                 │
    │  • Version controlled                                    │
    │  • Hot-reloadable                                        │
    │  • Zero-downtime updates                                 │
    └──────────────────────────────────────────────────────────┘

    ┌─────────────────────────────────────────────────────────┐
    │   🔐 SOPS Secrets Vault (Encrypted Storage)             │
    │   ┌───────────────────────────────────────────────────┐ │
    │   │  🔑 secrets.encrypted.yaml                         │ │
    │   │  • RESEND_API_KEY                                  │ │
    │   │  • S2_ACCESS_TOKEN                                 │ │
    │   │  • RESEND_WEBHOOK_SECRET                            │ │
    │   │  • GITHUB_PAT                                      │ │
    │   └───────────────────────────────────────────────────┘ │
    │                                                          │
    │  Multi-recipient encryption:                             │
    │  • Local machine key                                     │
    │  • Server key                                            │
    │  • GitHub Actions key                                    │
    └──────────────────────────────────────────────────────────┘

    ┌─────────────────────────────────────────────────────────┐
    │   🎼 Systemd Service Manager (Orchestrator)              │
    │   ┌───────────────────────────────────────────────────┐ │
    │   │  🎯 bento.service        (Main Processor)          │ │
    │   │  ⏰ bento-sync.timer     (Git Sync Scheduler)      │ │
    │   │  🔄 bento-sync.service   (Tool Updater)            │ │
    │   └───────────────────────────────────────────────────┘ │
    │                                                          │
    │  Features:                                               │
    │  • Auto-restart on failure                               │
    │  • Health monitoring                                     │
    │  • Scheduled sync jobs                                    │
    │  • Log management                                        │
    └──────────────────────────────────────────────────────────┘

                        │
                        │  Final Email Delivery
                        ▼
    ┌─────────────────┐
    │   📧 Resend     │  Email Service (Outbound)
    │   Send API      │
    └─────────────────┘
             │
             │  (SMTP)
             ▼
    📬 Recipient's Inbox
```

### Data Flow Metaphors

- **📮 Resend**: The **Post Office** - receives and delivers emails
- **🚪 Caddy**: The **Gateway** - routes traffic, provides security (HTTPS)
- **⚙️ Bento**: The **Factory** - processes events through assembly lines (streams)
- **🌊 S2**: The **River** - streams flow one direction, events are like water drops
- **🛠️ Tools**: The **Workshop** - custom functions that transform materials (emails)
- **🔐 SOPS**: The **Vault** - secure storage with multiple authorized keys
- **🎼 Systemd**: The **Conductor** - orchestrates all services in harmony
- **📚 Git**: The **Library** - version-controlled repository of tool functions

## Quick Start

On a fresh Ubuntu server:

```bash
curl -fsSL https://setup.divizend.com/setup.sh | bash
```

The system will:
- Configure HTTPS automatically
- Set up encrypted secrets management
- Deploy the stream processing pipeline
- Enable automated tool synchronization from Git

## Key Components

- **Resend**: Email sending and receiving platform
- **S2**: Stream store for event persistence and routing
- **Bento**: Stream processor for event transformation
- **SOPS**: Encrypted secrets management
- **Caddy**: Automatic HTTPS reverse proxy

## Philosophy

This system embodies the principle that **email should be programmable**. Instead of treating email as static messages in mailboxes, we treat them as **events in streams** that can trigger arbitrary business logic, be transformed, routed, and processed—all while maintaining a complete audit trail and enabling real-time responsiveness.

The architecture prioritizes:
- **Simplicity**: One command to deploy, one command to update
- **Security**: Encrypted secrets, no credentials in code
- **Reliability**: Idempotent operations, self-healing services
- **Extensibility**: Add new tools without redeployment
- **Observability**: Complete event history, transparent data flow
