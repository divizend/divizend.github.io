# Encrypted Secrets Management

This repository uses [SOPS](https://github.com/getsops/sops) with [age](https://github.com/FiloSottile/age) encryption to store secrets securely. **No `.env` file is needed** - all secrets are stored in `secrets.encrypted.yaml` and can be decrypted by multiple recipients (local machine, server, and GitHub Actions).

## Architecture

The secrets are encrypted with **multiple recipients**, allowing:
- **Local machine**: Edit secrets using `npm run secrets edit`
- **Server**: Decrypt secrets during `setup.sh` execution
- **GitHub Actions**: Decrypt secrets for CI/CD workflows

Each recipient has their own age keypair, and the public keys are stored in `.sops.yaml`.

## Initial Setup

### 1. Local Machine Setup

The `deploy.sh` script automatically:
- Checks for or creates a local age keypair at `.age-key-local`
- Adds the local public key to `.sops.yaml`
- Loads secrets from `secrets.encrypted.yaml`

**First time setup:**
```bash
./deploy.sh  # This will generate .age-key-local automatically
```

### 2. Server Setup

The `setup.sh` script automatically:
- Checks for or creates a server age keypair at `/root/.age-key-server`
- Adds the server public key to `.sops.yaml`
- Re-encrypts `secrets.encrypted.yaml` with all recipients

**No manual steps needed** - this happens automatically when you run `./deploy.sh`.

### 3. GitHub Actions Setup

1. **Generate a separate age keypair for GitHub Actions:**
   ```bash
   age-keygen -o .age-key-github
   ```

2. **Extract the public key:**
   ```bash
   grep "^# public key:" .age-key-github | cut -d' ' -f4
   ```

3. **Add the GitHub Actions public key to `.sops.yaml`:**
   ```bash
   npm run secrets add-recipient <public-key>
   # Or directly: bash secrets.sh add-recipient <public-key>
   ```

4. **Re-encrypt secrets with the new recipient:**
   ```bash
   npm run secrets edit  # This will re-encrypt with all recipients
   ```

5. **Add GitHub Secret:**
   - Go to your GitHub repository
   - Navigate to Settings → Secrets and variables → Actions
   - Click "New repository secret"
   - Name: `SOPS_AGE_KEY`
   - Value: The entire contents of `.age-key-github` (the private key)
   - Click "Add secret"

6. **Commit changes:**
   ```bash
   git add secrets.encrypted.yaml .sops.yaml
   git commit -m "Add GitHub Actions recipient for secrets"
   git push
   ```

## Managing Secrets

### Get a Secret

```bash
npm run secrets get <key>
# Example: npm run secrets get BASE_DOMAIN
# Or directly: bash secrets.sh get BASE_DOMAIN
```

### Set a Secret

```bash
npm run secrets set <key> <value>
# Example: npm run secrets set BASE_DOMAIN "example.com"
# Or directly: bash secrets.sh set BASE_DOMAIN "example.com"
```

### Delete a Secret

```bash
npm run secrets delete <key>
# Example: npm run secrets delete OLD_KEY
# Or directly: bash secrets.sh delete OLD_KEY
```

### List All Secrets

```bash
npm run secrets list
# Or directly: bash secrets.sh list
```

### Edit All Secrets

Edit secrets in your default editor:

```bash
npm run secrets edit
# Or directly: bash secrets.sh edit
```

This will:
1. Decrypt `secrets.encrypted.yaml`
2. Open in your default editor (`$EDITOR` or `nano`)
3. Re-encrypt when you save and close

### View All Secrets

Dump all decrypted secrets to stdout:

```bash
npm run secrets dump
# Or directly: bash secrets.sh dump
```

### Add a Recipient

Add a new recipient (public key) to `.sops.yaml`:

```bash
npm run secrets add-recipient <public-key>
# Or directly: bash scripts/secrets.sh add-recipient <public-key>
```

**Note:** After adding a recipient, you must re-encrypt secrets:
```bash
npm run secrets edit
```

## How It Works

### Key Management

- **Local key** (`.age-key-local`): Generated automatically by `deploy.sh`, used for local editing
- **Server key** (`/root/.age-key-server`): Generated automatically by `setup.sh`, used for server decryption
- **GitHub Actions key** (`.age-key-github`): Generated manually, stored as GitHub secret `SOPS_AGE_KEY`

### Secret Loading Priority

When `get_config_value` is called, it checks in this order:
1. Environment variable (highest priority)
2. Encrypted secrets (`secrets.encrypted.yaml`)
3. User prompt (if interactive)
4. Default value (if provided)

### Automatic Saving

When you enter a new value during setup (via `get_config_value`), it's automatically:
- Saved to `secrets.encrypted.yaml` using SOPS
- Available for all recipients (local, server, GitHub Actions)

## Security Notes

- ✅ **DO commit:** `secrets.encrypted.yaml` and `.sops.yaml`
- ❌ **NEVER commit:** `.age-key-*` files or unencrypted secrets
- 🔒 Keep your `.age-key-*` files secure and backed up safely
- 🔄 Rotate keys periodically by generating new keypairs and re-encrypting

## Troubleshooting

### "Error: SOPS is not installed"
Install SOPS:
```bash
# macOS
brew install sops

# Linux
curl -LO https://github.com/getsops/sops/releases/latest/download/sops-v3.8.1.linux
chmod +x sops-v3.8.1.linux
sudo mv sops-v3.8.1.linux /usr/local/bin/sops
```

### "Error: age-keygen is not installed"
Install age:
```bash
# macOS
brew install age

# Linux
curl -LO https://github.com/FiloSottile/age/releases/latest/download/age-v1.1.1-linux-amd64.tar.gz
tar -xzf age-v1.1.1-linux-amd64.tar.gz
sudo mv age/age /usr/local/bin/age
sudo mv age/age-keygen /usr/local/bin/age-keygen
```

### "Error: Local age key not found"
Run `./deploy.sh` first - it will generate the local keypair automatically.

### "Failed to decrypt secrets"
- Verify you have the correct key: `export SOPS_AGE_KEY=$(cat .age-key-local)`
- Check that `.sops.yaml` contains your public key
- Ensure `secrets.encrypted.yaml` was encrypted with your key

### GitHub Actions fails to decrypt
- Verify `SOPS_AGE_KEY` secret is set correctly in GitHub
- Ensure the GitHub Actions public key is in `.sops.yaml`
- Check that `secrets.encrypted.yaml` was re-encrypted with all recipients
