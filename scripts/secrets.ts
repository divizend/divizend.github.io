#!/usr/bin/env bun
/**
 * Unified secrets management script using SOPS with age encryption
 *
 * Usage:
 *   bun scripts/secrets.ts get <key>          - Get a secret value
 *   bun scripts/secrets.ts set <key> <value>  - Set a secret value
 *   bun scripts/secrets.ts list               - List all secrets
 *   bun scripts/secrets.ts edit               - Edit all secrets in editor
 *   bun scripts/secrets.ts dump               - Dump all secrets (decrypted)
 *   bun scripts/secrets.ts add-recipient <key> - Add a recipient to .sops.yaml
 */

import { existsSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { spawn, execSync, execFile } from "child_process";

const SCRIPT_DIR = new URL(".", import.meta.url).pathname.replace(
  "/scripts",
  ""
);
const SECRETS_FILE = join(SCRIPT_DIR, "secrets.encrypted.yaml");
const SOPS_CONFIG = join(SCRIPT_DIR, ".sops.yaml");
const AGE_KEY_LOCAL = join(SCRIPT_DIR, ".age-key-local");

// Colors for output
const GREEN = "\x1b[32m";
const BLUE = "\x1b[34m";
const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";
const NC = "\x1b[0m";

// Check if SOPS is available
async function checkSops(): Promise<boolean> {
  try {
    execSync("sops --version", { stdio: "ignore" });
    return true;
  } catch {
    console.error(`${RED}Error: SOPS is not installed${NC}`);
    console.error(
      `${YELLOW}Install with: brew install sops (macOS) or download from https://github.com/getsops/sops${NC}`
    );
    return false;
  }
}

// Get SOPS_AGE_KEY from .age-key-local or environment
function getAgeKey(): string | null {
  if (process.env.SOPS_AGE_KEY) {
    return process.env.SOPS_AGE_KEY;
  }

  if (existsSync(AGE_KEY_LOCAL)) {
    return readFileSync(AGE_KEY_LOCAL, "utf-8");
  }

  return null;
}

// Decrypt secrets file
async function decryptSecrets(): Promise<Record<string, string>> {
  if (!existsSync(SECRETS_FILE)) {
    return {};
  }

  const ageKey = getAgeKey();
  if (!ageKey) {
    throw new Error(
      "SOPS_AGE_KEY not set and .age-key-local not found. Run ./deploy.sh first."
    );
  }

  const yaml = execSync(`sops -d "${SECRETS_FILE}"`, {
    env: { ...process.env, SOPS_AGE_KEY: ageKey },
    encoding: "utf-8",
  });

  // Simple YAML parsing (key: "value" format)
  const secrets: Record<string, string> = {};
  for (const line of yaml.split("\n")) {
    if (line.trim().startsWith("#") || !line.trim()) continue;

    const match = line.match(/^([^:]+):\s*(.+)$/);
    if (match) {
      const key = match[1].trim();
      let value = match[2].trim();
      // Remove quotes
      value = value.replace(/^["']|["']$/g, "");
      secrets[key] = value;
    }
  }

  return secrets;
}

// Encrypt secrets object to file
async function encryptSecrets(secrets: Record<string, string>): Promise<void> {
  const ageKey = getAgeKey();
  if (!ageKey) {
    throw new Error(
      "SOPS_AGE_KEY not set and .age-key-local not found. Run ./deploy.sh first."
    );
  }

  // Convert to YAML format
  const yaml = Object.entries(secrets)
    .map(([key, value]) => `${key}: "${value}"`)
    .join("\n");

  const tempFile = join(tmpdir(), `secrets-${Date.now()}.yaml`);
  writeFileSync(tempFile, yaml, "utf-8");

  try {
    const encrypted = execSync(`sops -e "${tempFile}"`, {
      env: { ...process.env, SOPS_AGE_KEY: ageKey },
      encoding: "utf-8",
    });
    writeFileSync(SECRETS_FILE, encrypted, "utf-8");
    console.log(`${GREEN}✓ Secrets encrypted and saved${NC}`);
  } finally {
    if (existsSync(tempFile)) {
      execSync(`rm "${tempFile}"`);
    }
  }
}

// Get a secret value
async function getSecret(key: string): Promise<void> {
  if (!(await checkSops())) process.exit(1);

  try {
    const secrets = await decryptSecrets();
    if (key in secrets) {
      console.log(secrets[key]);
    } else {
      console.error(`${RED}Error: Secret '${key}' not found${NC}`);
      process.exit(1);
    }
  } catch (error: any) {
    console.error(`${RED}Error: ${error.message}${NC}`);
    process.exit(1);
  }
}

// Set a secret value
async function setSecret(key: string, value: string): Promise<void> {
  if (!(await checkSops())) process.exit(1);

  try {
    const secrets = await decryptSecrets();
    secrets[key] = value;
    await encryptSecrets(secrets);
    console.log(`${GREEN}✓ Set ${key}${NC}`);
  } catch (error: any) {
    console.error(`${RED}Error: ${error.message}${NC}`);
    process.exit(1);
  }
}

// List all secrets (keys only)
async function listSecrets(): Promise<void> {
  if (!(await checkSops())) process.exit(1);

  try {
    const secrets = await decryptSecrets();
    if (Object.keys(secrets).length === 0) {
      console.log("No secrets found");
      return;
    }

    for (const key of Object.keys(secrets).sort()) {
      console.log(key);
    }
  } catch (error: any) {
    console.error(`${RED}Error: ${error.message}${NC}`);
    process.exit(1);
  }
}

// Edit secrets in editor
async function editSecrets(): Promise<void> {
  if (!(await checkSops())) process.exit(1);

  try {
    const secrets = await decryptSecrets();

    // Convert to simple KEY=value format for editing
    const envFormat = Object.entries(secrets)
      .map(([key, value]) => `${key}=${value}`)
      .join("\n");

    const tempFile = join(tmpdir(), `secrets-edit-${Date.now()}.txt`);
    writeFileSync(tempFile, envFormat, "utf-8");

    // Open in editor
    // Check multiple environment variables and common editors
    let editor = process.env.EDITOR || process.env.VISUAL;

     // If no editor is set, find nano explicitly
     if (!editor) {
       // Try common paths first (more reliable than which)
       const commonPaths = [
         "/usr/bin/nano",
         "/bin/nano",
         "/opt/homebrew/bin/nano",
       ];
       for (const path of commonPaths) {
         if (existsSync(path)) {
           editor = path;
           break;
         }
       }
       
       // If not found in common paths, try which as fallback
       if (!editor) {
         try {
           const nanoPath = execSync("which nano", { encoding: "utf-8" }).trim();
           // Verify it's actually nano, not a symlink to vi
           if (nanoPath && existsSync(nanoPath) && nanoPath.includes("nano")) {
             editor = nanoPath;
           }
         } catch {
           // which failed, editor stays null
         }
       }
     }

    if (!editor) {
      throw new Error(
        "No editor found. Please install nano or set $EDITOR environment variable."
      );
    }

     // Verify editor exists before trying to use it
     const editorParts = editor.split(/\s+/);
     let editorCmd = editorParts[0];

     // If editorCmd is already an absolute path, use it directly
     // Only resolve if it's a relative path or command name
     if (!editorCmd.startsWith("/")) {
       // For nano specifically, use known paths instead of which
       if (editorCmd === "nano") {
         const nanoPaths = [
           "/usr/bin/nano",
           "/bin/nano",
           "/opt/homebrew/bin/nano",
         ];
         for (const path of nanoPaths) {
           if (existsSync(path)) {
             editorCmd = path;
             break;
           }
         }
       } else {
         // For other editors, try which
         try {
           const resolved = execSync(`which ${editorCmd}`, {
             encoding: "utf-8",
           }).trim();
           if (resolved && existsSync(resolved)) {
             editorCmd = resolved;
           }
         } catch {
           // which failed
         }
       }
     }

     if (!existsSync(editorCmd)) {
       throw new Error(`Editor "${editorCmd}" not found.`);
     }
     
     // Final safety check: if somehow we got vi, force nano
     if (editorCmd.includes("vi") && !editorCmd.includes("nano")) {
       console.log(`${YELLOW}Warning: Detected vi, forcing nano instead${NC}`);
       const nanoPaths = [
         "/usr/bin/nano",
         "/bin/nano",
         "/opt/homebrew/bin/nano",
       ];
       for (const path of nanoPaths) {
         if (existsSync(path)) {
           editorCmd = path;
           break;
         }
       }
     }

    console.log(`${BLUE}📝 Opening secrets in ${editorCmd}...${NC}`);
    console.log(
      `${YELLOW}Debug: Using editor: ${editorCmd}, args: ${JSON.stringify([
        ...editorParts.slice(1),
        tempFile,
      ])}${NC}`
    );

    await new Promise<void>((resolve, reject) => {
      // Use execFile for better control and to avoid shell interpretation
      const editorArgs = [...editorParts.slice(1), tempFile];

      const proc = execFile(editorCmd, editorArgs, {
        stdio: "inherit",
      });

      proc.on("exit", (code) => {
        if (code === 0 || code === null) {
          resolve();
        } else {
          reject(new Error(`Editor exited with code ${code}`));
        }
      });

      proc.on("error", (error) => {
        reject(new Error(`Failed to start editor: ${error.message}`));
      });
    });

    // Read edited file and parse
    const edited = readFileSync(tempFile, "utf-8");
    const newSecrets: Record<string, string> = {};

    for (const line of edited.split("\n")) {
      if (line.trim().startsWith("#") || !line.trim()) continue;
      const match = line.match(/^([^=]+)=(.*)$/);
      if (match) {
        const key = match[1].trim();
        let value = match[2].trim();
        // Remove quotes
        value = value.replace(/^["']|["']$/g, "");
        newSecrets[key] = value;
      }
    }

    // Merge with existing secrets (preserve keys not in edited file)
    const merged = { ...secrets, ...newSecrets };
    await encryptSecrets(merged);

    // Clean up
    if (existsSync(tempFile)) {
      execSync(`rm "${tempFile}"`);
    }
  } catch (error: any) {
    console.error(`${RED}Error: ${error.message}${NC}`);
    process.exit(1);
  }
}

// Dump all secrets (decrypted)
async function dumpSecrets(): Promise<void> {
  if (!(await checkSops())) process.exit(1);

  try {
    const ageKey = getAgeKey();
    if (!ageKey) {
      throw new Error(
        "SOPS_AGE_KEY not set and .age-key-local not found. Run ./deploy.sh first."
      );
    }

    const decrypted = execSync(`sops -d "${SECRETS_FILE}"`, {
      env: { ...process.env, SOPS_AGE_KEY: ageKey },
      encoding: "utf-8",
    });
    console.log(decrypted);
  } catch (error: any) {
    console.error(`${RED}Error: ${error.message}${NC}`);
    process.exit(1);
  }
}

// Add a recipient to .sops.yaml
async function addRecipient(publicKey: string): Promise<void> {
  if (!existsSync(SOPS_CONFIG)) {
    console.error(`${RED}Error: .sops.yaml not found${NC}`);
    process.exit(1);
  }

  const config = readFileSync(SOPS_CONFIG, "utf-8");

  // Check if key is already present
  if (config.includes(publicKey)) {
    console.log(`${YELLOW}Recipient already in .sops.yaml${NC}`);
    return;
  }

  // Extract existing keys from age: >- section
  const ageMatch = config.match(/age:\s*>-\s*\n\s*([^\n#]+)/);
  let existingKeys: string[] = [];

  if (ageMatch) {
    const keysLine = ageMatch[1].trim();
    existingKeys = keysLine
      .split(",")
      .map((k) => k.trim())
      .filter(Boolean);
  }

  // Add new key
  existingKeys.push(publicKey);
  const newKeysLine = existingKeys.join(",\n      ");

  // Replace the age section
  const newConfig = config.replace(
    /age:\s*>-\s*\n\s*[^\n#]+/,
    `age: >-\n      ${newKeysLine}`
  );

  writeFileSync(SOPS_CONFIG, newConfig, "utf-8");
  console.log(`${GREEN}✓ Added recipient to .sops.yaml${NC}`);
  console.log(
    `${YELLOW}⚠ Remember to re-encrypt secrets with: bun scripts/secrets.ts edit${NC}`
  );
}

// Main command handler
async function main() {
  const command = process.argv[2];
  const args = process.argv.slice(3);

  switch (command) {
    case "get":
      if (args.length !== 1) {
        console.error(`${RED}Usage: bun scripts/secrets.ts get <key>${NC}`);
        process.exit(1);
      }
      await getSecret(args[0]);
      break;

    case "set":
      if (args.length !== 2) {
        console.error(
          `${RED}Usage: bun scripts/secrets.ts set <key> <value>${NC}`
        );
        process.exit(1);
      }
      await setSecret(args[0], args[1]);
      break;

    case "list":
      await listSecrets();
      break;

    case "edit":
      await editSecrets();
      break;

    case "dump":
      await dumpSecrets();
      break;

    case "add-recipient":
      if (args.length !== 1) {
        console.error(
          `${RED}Usage: bun scripts/secrets.ts add-recipient <public-key>${NC}`
        );
        process.exit(1);
      }
      await addRecipient(args[0]);
      break;

    default:
      console.error(`${RED}Unknown command: ${command || "(none)"}${NC}`);
      console.error("\nUsage:");
      console.error(
        "  bun scripts/secrets.ts get <key>          - Get a secret value"
      );
      console.error(
        "  bun scripts/secrets.ts set <key> <value>  - Set a secret value"
      );
      console.error(
        "  bun scripts/secrets.ts list               - List all secrets"
      );
      console.error(
        "  bun scripts/secrets.ts edit               - Edit all secrets in editor"
      );
      console.error(
        "  bun scripts/secrets.ts dump               - Dump all secrets (decrypted)"
      );
      console.error(
        "  bun scripts/secrets.ts add-recipient <key> - Add a recipient to .sops.yaml"
      );
      process.exit(1);
  }
}

main().catch((error) => {
  console.error(`${RED}Error: ${error.message}${NC}`);
  process.exit(1);
});
