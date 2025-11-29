# GitHub Actions Secrets Setup

This repository uses [SOPS](https://github.com/getsops/sops) with [age](https://github.com/FiloSottile/age) encryption to store secrets securely in the repository.

## Initial Setup

1. **Install SOPS:**
   ```bash
   # macOS
   brew install sops
   
   # Linux
   curl -LO https://github.com/getsops/sops/releases/latest/download/sops-v3.8.1.linux
   chmod +x sops-v3.8.1.linux
   sudo mv sops-v3.8.1.linux /usr/local/bin/sops
   ```

2. **Generate age keypair:**
   ```bash
   age-keygen -o age-key.txt
   ```
   This creates two files:
   - `age-key.txt` - Contains both public and private key (KEEP SECRET!)
   - The public key starts with `age1...`

3. **Update `.sops.yaml`:**
   - Open `.sops.yaml`
   - Replace the placeholder `age1xxxxxxxxx...` with your actual public key from `age-key.txt`

4. **Create and encrypt secrets:**
   ```bash
   # Copy the example file
   cp secrets.example.yaml secrets.yaml
   
   # Edit secrets.yaml with your actual values
   nano secrets.yaml  # or use your preferred editor
   
   # Encrypt the secrets
   sops -e secrets.yaml > secrets.encrypted.yaml
   ```

5. **Add GitHub Secret:**
   - Go to your GitHub repository
   - Navigate to Settings → Secrets and variables → Actions
   - Click "New repository secret"
   - Name: `SOPS_AGE_KEY`
   - Value: The entire contents of `age-key.txt` (the private key)
   - Click "Add secret"

6. **Commit encrypted file:**
   ```bash
   git add secrets.encrypted.yaml .sops.yaml
   git commit -m "Add encrypted secrets for GitHub Actions"
   git push
   ```

7. **Clean up:**
   ```bash
   # Remove unencrypted files (they're in .gitignore)
   rm secrets.yaml age-key.txt
   ```

## Editing Secrets

To edit encrypted secrets:

```bash
# Decrypt, edit, and re-encrypt
sops secrets.encrypted.yaml

# Or manually:
sops -d secrets.encrypted.yaml > secrets.yaml
# Edit secrets.yaml
sops -e secrets.yaml > secrets.encrypted.yaml
rm secrets.yaml
```

## Security Notes

- ✅ **DO commit:** `secrets.encrypted.yaml` and `.sops.yaml`
- ❌ **NEVER commit:** `secrets.yaml`, `age-key.txt`, or any unencrypted secrets
- 🔒 Keep your `age-key.txt` file secure and backed up safely
- 🔄 Rotate keys periodically by generating a new keypair and re-encrypting

## Troubleshooting

If GitHub Actions fails to decrypt:
- Verify `SOPS_AGE_KEY` secret is set correctly in GitHub
- Ensure the public key in `.sops.yaml` matches the keypair
- Check that `secrets.encrypted.yaml` was encrypted with the correct key
