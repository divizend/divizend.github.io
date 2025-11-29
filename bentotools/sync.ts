#!/usr/bin/env bun
/**
 * Bento Streams Sync Script (TypeScript)
 *
 * This script compiles TypeScript exports and syncs them to Bento via HTTP API.
 *
 * IMPORTANT: Bento API does NOT perform environment variable interpolation.
 * All variable substitution must be done BEFORE sending configs to the API.
 */

interface BentoStreamConfig {
  input: any;
  pipeline?: any;
  output: any;
}

interface ParsedToolsRoot {
  owner: string;
  repo: string;
  branch: string;
  path: string;
}

// Parse TOOLS_ROOT_GITHUB to extract repo, branch, and path
function parseToolsRoot(toolsRoot: string): ParsedToolsRoot {
  const regex =
    /^https:\/\/github\.com\/([^/]+)\/([^/]+)(?:\/([^/]+))?(?:\/(.*))?$/;
  const match = toolsRoot.match(regex);

  if (!match) {
    throw new Error(
      `Invalid TOOLS_ROOT_GITHUB format. Expected: https://github.com/owner/repo[/branch][/path]`
    );
  }

  const [, owner, repo, branch, path] = match;

  return {
    owner,
    repo,
    branch: branch || "", // Will be resolved later if empty
    path: path || "",
  };
}

// Get default branch from GitHub API
async function getDefaultBranch(owner: string, repo: string): Promise<string> {
  try {
    const response = await fetch(
      `https://api.github.com/repos/${owner}/${repo}`
    );
    if (!response.ok) {
      console.warn("⚠ Could not determine default branch, using 'main'");
      return "main";
    }
    const data = await response.json();
    return data.default_branch || "main";
  } catch (error) {
    console.warn("⚠ Could not determine default branch, using 'main'");
    return "main";
  }
}

// Fetch index.ts from GitHub
async function fetchIndexTs(parsed: ParsedToolsRoot): Promise<string> {
  let branch = parsed.branch;

  // If branch not specified, get default branch
  if (!branch) {
    console.log(
      `📡 Fetching default branch for ${parsed.owner}/${parsed.repo}...`
    );
    branch = await getDefaultBranch(parsed.owner, parsed.repo);
  }

  // Construct raw GitHub URL
  const pathPart = parsed.path ? `${parsed.path}/`.replace(/\/+$/, "") : "";
  const rawUrl = `https://raw.githubusercontent.com/${parsed.owner}/${parsed.repo}/${branch}/${pathPart}index.ts`;

  console.log(`📥 Fetching index.ts from ${rawUrl}...`);

  const response = await fetch(rawUrl);
  if (!response.ok) {
    throw new Error(
      `Failed to fetch index.ts from ${rawUrl}: ${response.statusText}`
    );
  }

  return await response.text();
}

// Compile TypeScript exports to get stream configurations
async function compileStreams(
  indexTsCode: string
): Promise<Record<string, BentoStreamConfig>> {
  // Create a temporary file and import it as a module
  // Use a unique filename to avoid conflicts
  const tempFile = `/tmp/bento-sync-index-${Date.now()}-${Math.random()
    .toString(36)
    .substring(7)}.ts`;
  await Bun.write(tempFile, indexTsCode);

  // Import the module (it's guaranteed to be a proper module)
  const module = await import(tempFile);

  // Clean up temp file
  try {
    await Bun.file(tempFile).unlink();
  } catch {
    // Ignore cleanup errors
  }

  const streams: Record<string, BentoStreamConfig> = {};

  for (const [key, value] of Object.entries(module)) {
    // Skip default export and private exports
    if (key === "default" || key.startsWith("_")) {
      continue;
    }

    // Skip functions (these are tool functions, not stream definitions)
    if (typeof value === "function") {
      console.log(`✓ Found tool function: ${key}`);
      continue;
    }

    // This is a stream definition
    if (
      value &&
      typeof value === "object" &&
      "input" in value &&
      "output" in value
    ) {
      streams[key] = value as BentoStreamConfig;
      console.log(`✓ Found stream definition: ${key}`);
    } else {
      console.warn(
        `⚠ Skipping export '${key}': not a function or stream definition`
      );
    }
  }

  return streams;
}

// Substitute environment variables in stream configs
// IMPORTANT: Bento API does NOT perform interpolation, so we must do it here
function substituteVariables(config: any, vars: Record<string, string>): any {
  if (typeof config === "string") {
    // Substitute variables in strings
    let result = config;
    for (const [key, value] of Object.entries(vars)) {
      result = result.replace(new RegExp(`\\$\\{${key}\\}`, "g"), value);
    }
    return result;
  }

  if (Array.isArray(config)) {
    return config.map((item) => substituteVariables(item, vars));
  }

  if (config && typeof config === "object") {
    const result: any = {};
    for (const [key, value] of Object.entries(config)) {
      result[key] = substituteVariables(value, vars);
    }
    return result;
  }

  return config;
}

// Sync a single stream to Bento via HTTP API
async function syncStream(
  name: string,
  config: BentoStreamConfig,
  apiUrl: string
): Promise<boolean> {
  console.log(`  → Syncing stream: ${name}`);

  // Try POST first (create), then PUT (update) if that fails
  try {
    let response = await fetch(`${apiUrl}/streams/${name}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(config),
    });

    // If POST fails with 409 (conflict) or 404, try PUT (update)
    if (response.status === 409 || response.status === 404) {
      response = await fetch(`${apiUrl}/streams/${name}`, {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(config),
      });
    }

    if (response.ok) {
      console.log(`    ✓ Stream '${name}' synced successfully`);
      return true;
    } else {
      const body = await response.text();
      console.warn(
        `    ⚠ Stream '${name}' sync returned HTTP ${response.status}`
      );
      if (body) {
        console.warn(`    Response: ${body}`);
      }
      return false;
    }
  } catch (error) {
    console.error(`    ✗ Error syncing stream '${name}':`, error);
    return false;
  }
}

// Main sync function
async function main() {
  const BENTO_API_URL = process.env.BENTO_API_URL || "http://localhost:4195";
  const TOOLS_ROOT_GITHUB = process.env.TOOLS_ROOT_GITHUB;

  if (!TOOLS_ROOT_GITHUB) {
    console.error(
      "❌ Error: TOOLS_ROOT_GITHUB environment variable is required"
    );
    process.exit(1);
  }

  console.log(`🔄 Syncing Bento streams from ${TOOLS_ROOT_GITHUB}...`);

  // Parse TOOLS_ROOT_GITHUB
  const parsed = parseToolsRoot(TOOLS_ROOT_GITHUB);

  // Fetch index.ts
  const indexTsCode = await fetchIndexTs(parsed);

  // Compile streams
  console.log(`🔧 Compiling TypeScript exports...`);
  const streams = await compileStreams(indexTsCode);

  if (Object.keys(streams).length === 0) {
    console.error("❌ No stream definitions found in exports");
    process.exit(1);
  }

  console.log(`✓ Found ${Object.keys(streams).length} stream definition(s)`);

  // Get environment variables for substitution
  // IMPORTANT: Bento API does NOT perform variable interpolation
  // We must substitute all variables BEFORE sending to the API
  const BASE_DOMAIN = process.env.BASE_DOMAIN || "";
  const S2_ACCESS_TOKEN = process.env.S2_ACCESS_TOKEN || "";
  const RESEND_API_KEY = process.env.RESEND_API_KEY || "";
  
  // S2_BASIN: if not set, derive from BASE_DOMAIN (replace dots with hyphens, lowercase)
  // S2 basin names must be lowercase letters, numbers, and hyphens only
  let S2_BASIN = process.env.S2_BASIN || "";
  if (!S2_BASIN && BASE_DOMAIN) {
    S2_BASIN = BASE_DOMAIN.replace(/\./g, "-").toLowerCase();
    console.log(`📝 Derived S2_BASIN from BASE_DOMAIN: ${S2_BASIN}`);
  }

  if (!S2_BASIN || !BASE_DOMAIN || !S2_ACCESS_TOKEN || !RESEND_API_KEY) {
    console.warn(
      "⚠ Warning: Some environment variables are missing. Stream configs may contain unsubstituted variables."
    );
    console.warn(
      `  Missing: S2_BASIN=${S2_BASIN ? "SET" : "MISSING"} BASE_DOMAIN=${
        BASE_DOMAIN ? "SET" : "MISSING"
      } S2_ACCESS_TOKEN=${S2_ACCESS_TOKEN ? "SET" : "MISSING"} RESEND_API_KEY=${
        RESEND_API_KEY ? "SET" : "MISSING"
      }`
    );
  }

  // Substitute variables in all stream configs
  const vars = {
    S2_BASIN,
    BASE_DOMAIN,
    S2_ACCESS_TOKEN,
    RESEND_API_KEY,
  };

  const substitutedStreams: Record<string, BentoStreamConfig> = {};
  for (const [name, config] of Object.entries(streams)) {
    substitutedStreams[name] = substituteVariables(
      config,
      vars
    ) as BentoStreamConfig;
  }

  // Check if Bento API is accessible
  console.log(`🔍 Checking Bento API at ${BENTO_API_URL}...`);
  try {
    const response = await fetch(`${BENTO_API_URL}/ready`);
    if (!response.ok) {
      console.warn(
        `⚠ Warning: Bento API at ${BENTO_API_URL} is not accessible`
      );
      console.warn(
        "This is expected if Bento is not running or not publicly accessible"
      );
      process.exit(0);
    }
  } catch (error) {
    console.warn(`⚠ Warning: Bento API at ${BENTO_API_URL} is not accessible`);
    console.warn(
      "This is expected if Bento is not running or not publicly accessible"
    );
    process.exit(0);
  }

  // Sync streams to Bento
  console.log(`📤 Syncing streams to Bento...`);
  let successCount = 0;
  for (const [name, config] of Object.entries(substitutedStreams)) {
    if (await syncStream(name, config, BENTO_API_URL)) {
      successCount++;
    }
  }

  console.log(
    `✅ Stream sync completed (${successCount}/${
      Object.keys(substitutedStreams).length
    } successful)`
  );
}

// Run if executed directly
if (import.meta.main) {
  main().catch((error) => {
    console.error("❌ Sync failed:", error);
    process.exit(1);
  });
}
