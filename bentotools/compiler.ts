#!/usr/bin/env bun
/**
 * TypeScript to Bento Streams Compiler
 * 
 * This compiler processes the exports from index.ts and generates Bento stream configurations.
 * - If an export is a function (typeof function), it's a tool function and will be called via bun
 * - If an export is an object, it's treated as a Bento stream definition
 */

import { readFileSync, writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

interface BentoStreamConfig {
  input: any;
  pipeline?: any;
  output: any;
}

interface ToolFunction {
  (email: any): string;
}

// Load and evaluate the index.ts file
async function loadExports(): Promise<Record<string, any>> {
  const indexPath = join(__dirname, "index.ts");
  const code = readFileSync(indexPath, "utf-8");
  
  // Use dynamic import to get the exports
  // Note: This requires the file to be a proper module
  const module = await import(indexPath);
  return module;
}

// Check if a value is a function
function isFunction(value: any): value is ToolFunction {
  return typeof value === "function";
}

// Process exports and generate stream configurations
async function compileStreams(): Promise<Map<string, BentoStreamConfig>> {
  const exports = await loadExports();
  const streams = new Map<string, BentoStreamConfig>();
  
  for (const [key, value] of Object.entries(exports)) {
    // Skip default export and non-stream exports
    if (key === "default" || key.startsWith("_")) {
      continue;
    }
    
    if (isFunction(value)) {
      // This is a tool function - it will be called by transform_email stream
      // Tool functions don't generate stream configs, they're used within streams
      console.log(`✓ Found tool function: ${key}`);
      continue;
    }
    
    // This is a stream definition
    if (value && typeof value === "object" && value.input && value.output) {
      streams.set(key, value as BentoStreamConfig);
      console.log(`✓ Found stream definition: ${key}`);
    } else {
      console.warn(`⚠ Skipping export '${key}': not a function or stream definition`);
    }
  }
  
  return streams;
}

// Convert stream config to YAML
function streamToYAML(streamName: string, config: BentoStreamConfig): string {
  const yaml: string[] = [];
  
  // Input
  yaml.push("input:");
  yaml.push(formatYAML(config.input, 2));
  
  // Pipeline (if present)
  if (config.pipeline) {
    yaml.push("pipeline:");
    yaml.push(formatYAML(config.pipeline, 2));
  }
  
  // Output
  yaml.push("output:");
  yaml.push(formatYAML(config.output, 2));
  
  return yaml.join("\n");
}

// Format object as YAML with proper indentation
function formatYAML(obj: any, indent: number = 0): string {
  const spaces = " ".repeat(indent);
  const lines: string[] = [];
  
  if (Array.isArray(obj)) {
    for (const item of obj) {
      if (typeof item === "object" && item !== null) {
        lines.push(`${spaces}-`);
        lines.push(formatYAML(item, indent + 2));
      } else {
        lines.push(`${spaces}- ${formatValue(item)}`);
      }
    }
  } else if (obj && typeof obj === "object") {
    for (const [key, value] of Object.entries(obj)) {
      if (value === null || value === undefined) {
        continue;
      }
      
      if (Array.isArray(value)) {
        lines.push(`${spaces}${key}:`);
        for (const item of value) {
          if (typeof item === "object" && item !== null) {
            lines.push(`${spaces}  -`);
            lines.push(formatYAML(item, indent + 4));
          } else {
            lines.push(`${spaces}  - ${formatValue(item)}`);
          }
        }
      } else if (typeof value === "object" && value !== null) {
        lines.push(`${spaces}${key}:`);
        lines.push(formatYAML(value, indent + 2));
      } else {
        lines.push(`${spaces}${key}: ${formatValue(value)}`);
      }
    }
  } else {
    lines.push(`${spaces}${formatValue(obj)}`);
  }
  
  return lines.join("\n");
}

// Format a value for YAML
function formatValue(value: any): string {
  if (typeof value === "string") {
    // Check if it needs quoting
    if (value.includes(":") || value.includes("#") || value.includes("|") || value.includes("$")) {
      return JSON.stringify(value);
    }
    return value;
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  return JSON.stringify(value);
}

// Main compilation function
async function main() {
  console.log("🔧 Compiling TypeScript exports to Bento stream configurations...\n");
  
  try {
    const streams = await compileStreams();
    
    if (streams.size === 0) {
      console.error("❌ No stream definitions found in exports");
      process.exit(1);
    }
    
    console.log(`\n📦 Generated ${streams.size} stream configuration(s)\n`);
    
    // Output streams as JSON for Bento API consumption
    const streamsJSON: Record<string, BentoStreamConfig> = {};
    for (const [name, config] of streams.entries()) {
      streamsJSON[name] = config;
    }
    
    // Write to stdout as JSON (for Bento API)
    console.log(JSON.stringify(streamsJSON, null, 2));
    
  } catch (error) {
    console.error("❌ Compilation failed:", error);
    process.exit(1);
  }
}

// Run if executed directly
if (import.meta.main) {
  main();
}

export { compileStreams, streamToYAML };

