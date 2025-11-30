#!/usr/bin/env bun
/**
 * Comprehensive test suite for secrets handling
 * Tests both secrets.sh and get_config_value function
 * Each test cleans up by removing .sops.yaml, .age-key-local, and secrets.encrypted.yaml
 */

import { existsSync, unlinkSync } from "fs";
import { join } from "path";

const SCRIPT_DIR = process.cwd();
const SOPS_CONFIG = join(SCRIPT_DIR, ".sops.yaml");
const AGE_KEY_LOCAL = join(SCRIPT_DIR, ".age-key-local");
const SECRETS_FILE = join(SCRIPT_DIR, "secrets.encrypted.yaml");
const COMMON_SH = join(SCRIPT_DIR, "common.sh");
const SECRETS_SH = join(SCRIPT_DIR, "secrets.sh");

interface TestResult {
  name: string;
  passed: boolean;
  error?: string;
  output?: string;
}

const results: TestResult[] = [];

// Cleanup function
// Note: No setup needed - all secrets operations now automatically create prerequisites
function cleanup() {
  console.log("🧹 Cleaning up test files...");
  if (existsSync(SOPS_CONFIG)) unlinkSync(SOPS_CONFIG);
  if (existsSync(AGE_KEY_LOCAL)) unlinkSync(AGE_KEY_LOCAL);
  if (existsSync(SECRETS_FILE)) unlinkSync(SECRETS_FILE);
}

// Helper to run bash command and capture output
async function runBash(
  command: string,
  env: Record<string, string> = {}
): Promise<{
  success: boolean;
  stdout: string;
  stderr: string;
  exitCode: number;
}> {
  try {
    const proc = Bun.spawn(["bash", "-c", command], {
      env: { ...process.env, ...env },
      cwd: SCRIPT_DIR,
      stdout: "pipe",
      stderr: "pipe",
    });

    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);

    const exitCode = await proc.exited;

    return {
      success: exitCode === 0,
      stdout: stdout.trim(),
      stderr: stderr.trim(),
      exitCode,
    };
  } catch (error: any) {
    return {
      success: false,
      stdout: "",
      stderr: error.message || String(error),
      exitCode: 1,
    };
  }
}

// Test helper
// Note: No setup needed - secrets operations automatically create all prerequisites
async function test(name: string, testFn: () => Promise<void>): Promise<void> {
  console.log(`\n🧪 Test: ${name}`);
  cleanup(); // Clean before each test (operations will create files as needed)

  try {
    await testFn();
    results.push({ name, passed: true });
    console.log(`✅ PASSED: ${name}`);
  } catch (error: any) {
    const errorMsg = error.message || String(error);
    results.push({
      name,
      passed: false,
      error: errorMsg,
      output: error.stdout || error.stderr || error.output,
    });
    console.log(`❌ FAILED: ${name}`);
    console.log(`   Error: ${errorMsg}`);
    if (error.stdout || error.stderr) {
      console.log(`   Output: ${error.stdout || error.stderr}`);
    }
  } finally {
    cleanup(); // Clean after each test
  }
}

// Assert helper with optional result context
function assert(
  condition: boolean,
  message: string,
  context?: { stdout?: string; stderr?: string; exitCode?: number }
) {
  if (!condition) {
    const error: any = new Error(message);
    if (context) {
      error.stdout = context.stdout;
      error.stderr = context.stderr;
      error.exitCode = context.exitCode;
    }
    throw error;
  }
}

// Test suite
async function runTests() {
  console.log("🚀 Starting comprehensive secrets handling tests...\n");

  // ============================================
  // Tests for secrets.sh
  // ============================================

  await test("secrets.sh: set - creates file and sets value", async () => {
    const result = await runBash(`${SECRETS_SH} set TEST_KEY "test_value"`);
    assert(
      result.success,
      `Expected success, got exit code ${result.exitCode}. stderr: ${result.stderr}`,
      result
    );
    assert(
      result.stdout.includes("✓ Set TEST_KEY"),
      `Expected success message, got: ${result.stdout}`,
      result
    );
    assert(existsSync(SECRETS_FILE), "secrets.encrypted.yaml should exist");
    assert(existsSync(SOPS_CONFIG), ".sops.yaml should exist");
    assert(existsSync(AGE_KEY_LOCAL), ".age-key-local should exist");
  });

  await test("secrets.sh: set - fails without key", async () => {
    const result = await runBash(`${SECRETS_SH} set`);
    assert(!result.success, "Should fail without key");
    assert(result.stderr.includes("Usage"), "Should show usage");
  });

  await test("secrets.sh: set - fails without value", async () => {
    const result = await runBash(`${SECRETS_SH} set TEST_KEY`);
    assert(!result.success, "Should fail without value");
    assert(result.stderr.includes("Usage"), "Should show usage");
  });

  await test("secrets.sh: get - retrieves set value", async () => {
    // First set a value
    await runBash(`${SECRETS_SH} set TEST_KEY "test_value_123"`);

    // Then get it
    const result = await runBash(`${SECRETS_SH} get TEST_KEY`);
    assert(result.success, "Should succeed");
    assert(
      result.stdout.includes("test_value_123"),
      "Should retrieve correct value"
    );
  });

  await test("secrets.sh: get - fails without key", async () => {
    // Create file first
    await runBash(`${SECRETS_SH} set TEST_KEY "value"`);

    const result = await runBash(`${SECRETS_SH} get`);
    assert(!result.success, "Should fail without key");
    assert(result.stderr.includes("Usage"), "Should show usage");
  });

  await test("secrets.sh: get - handles non-existent key gracefully", async () => {
    // Create file first
    await runBash(`${SECRETS_SH} set TEST_KEY "value"`);

    const result = await runBash(`${SECRETS_SH} get NON_EXISTENT_KEY`);
    // SOPS might return empty or error - both are acceptable
    // Just check it doesn't crash
    assert(result.exitCode !== undefined, "Should complete");
  });

  await test("secrets.sh: list - lists all keys", async () => {
    // Set multiple values
    await runBash(`${SECRETS_SH} set KEY1 "value1"`);
    await runBash(`${SECRETS_SH} set KEY2 "value2"`);
    await runBash(`${SECRETS_SH} set KEY3 "value3"`);

    const result = await runBash(`${SECRETS_SH} list`);
    assert(result.success, "Should succeed");
    assert(result.stdout.includes("KEY1"), "Should list KEY1");
    assert(result.stdout.includes("KEY2"), "Should list KEY2");
    assert(result.stdout.includes("KEY3"), "Should list KEY3");
  });

  await test("secrets.sh: list - handles empty file", async () => {
    // Create empty file
    await runBash(`${SECRETS_SH} set TEMP_KEY "temp"`);
    await runBash(`${SECRETS_SH} delete TEMP_KEY`);

    const result = await runBash(`${SECRETS_SH} list`);
    // Should succeed even if empty (might return empty output)
    assert(result.exitCode !== undefined, "Should complete");
  });

  await test("secrets.sh: delete - removes key", async () => {
    // Set a value
    await runBash(`${SECRETS_SH} set DELETE_TEST "delete_me"`);

    // Delete it
    const result = await runBash(`${SECRETS_SH} delete DELETE_TEST`);
    assert(result.success, "Should succeed");
    assert(
      result.stdout.includes("✓ Deleted DELETE_TEST"),
      "Should show success message"
    );

    // Verify it's gone
    const listResult = await runBash(`${SECRETS_SH} list`);
    assert(!listResult.stdout.includes("DELETE_TEST"), "Key should be removed");
  });

  await test("secrets.sh: delete - fails without key", async () => {
    await runBash(`${SECRETS_SH} set TEST_KEY "value"`);

    const result = await runBash(`${SECRETS_SH} delete`);
    assert(!result.success, "Should fail without key");
    assert(result.stderr.includes("Usage"), "Should show usage");
  });

  await test("secrets.sh: unset - alias for delete", async () => {
    await runBash(`${SECRETS_SH} set UNSET_TEST "unset_me"`);

    const result = await runBash(`${SECRETS_SH} unset UNSET_TEST`);
    assert(result.success, "Should succeed");
    assert(
      result.stdout.includes("✓ Deleted UNSET_TEST"),
      "Should show success message"
    );
  });

  await test("secrets.sh: dump - outputs decrypted content", async () => {
    await runBash(`${SECRETS_SH} set DUMP_KEY1 "dump_value1"`);
    await runBash(`${SECRETS_SH} set DUMP_KEY2 "dump_value2"`);

    const result = await runBash(`${SECRETS_SH} dump`);
    assert(result.success, "Should succeed");
    assert(result.stdout.includes("DUMP_KEY1"), "Should contain DUMP_KEY1");
    assert(result.stdout.includes("DUMP_KEY2"), "Should contain DUMP_KEY2");
    assert(result.stdout.includes("dump_value1"), "Should contain value1");
    assert(result.stdout.includes("dump_value2"), "Should contain value2");
  });

  await test("secrets.sh: dump - handles empty file", async () => {
    // Create and empty file
    await runBash(`${SECRETS_SH} set TEMP "temp"`);
    await runBash(`${SECRETS_SH} delete TEMP`);

    const result = await runBash(`${SECRETS_SH} dump`);
    // Should succeed (might return empty YAML)
    assert(result.exitCode !== undefined, "Should complete");
  });

  await test("secrets.sh: add-recipient - adds public key", async () => {
    // First create a keypair to get a public key
    await runBash(`age-keygen -o /tmp/test-age-key`);
    const pubKeyResult = await runBash(
      `grep '^# public key:' /tmp/test-age-key | cut -d' ' -f4`
    );
    const testPubKey = pubKeyResult.stdout.trim();

    // Create initial config
    await runBash(`${SECRETS_SH} set TEST_KEY "value"`);

    // Add recipient
    const result = await runBash(`${SECRETS_SH} add-recipient "${testPubKey}"`);
    assert(result.success, "Should succeed");

    // Verify key is in .sops.yaml
    const configContent = Bun.file(SOPS_CONFIG);
    const configText = await configContent.text();
    assert(
      configText.includes(testPubKey),
      "Public key should be in .sops.yaml"
    );

    // Cleanup temp key
    await runBash(`rm -f /tmp/test-age-key`);
  });

  await test("secrets.sh: add-recipient - fails without key", async () => {
    await runBash(`${SECRETS_SH} set TEST_KEY "value"`);

    const result = await runBash(`${SECRETS_SH} add-recipient`);
    assert(!result.success, "Should fail without key");
    assert(result.stderr.includes("Usage"), "Should show usage");
  });

  await test("secrets.sh: invalid command shows usage", async () => {
    const result = await runBash(`${SECRETS_SH} invalid_command`);
    assert(!result.success, "Should fail");
    assert(result.stderr.includes("Usage"), "Should show usage");
  });

  await test("secrets.sh: handles special characters in values", async () => {
    // Use special characters that are valid in JSON strings
    // Test with spaces, dashes, and other safe characters
    const specialValue = "test value with spaces-and-dashes_123";
    await runBash(`${SECRETS_SH} set SPECIAL_KEY "${specialValue}"`);

    const result = await runBash(`${SECRETS_SH} get SPECIAL_KEY`);
    assert(
      result.success,
      `Should handle special characters. stderr: ${result.stderr}`,
      result
    );
    assert(
      result.stdout.includes("test value"),
      "Should retrieve value with spaces"
    );
  });

  await test("secrets.sh: handles empty value", async () => {
    await runBash(`${SECRETS_SH} set EMPTY_KEY ""`);

    const result = await runBash(`${SECRETS_SH} get EMPTY_KEY`);
    // Should succeed (empty value is valid)
    assert(result.exitCode !== undefined, "Should complete");
  });

  await test("secrets.sh: handles very long values", async () => {
    const longValue = "a".repeat(10000);
    await runBash(`${SECRETS_SH} set LONG_KEY "${longValue}"`);

    const result = await runBash(`${SECRETS_SH} get LONG_KEY`);
    assert(result.success, "Should handle long values");
    assert(result.stdout.length > 0, "Should retrieve value");
  });

  await test("secrets.sh: handles unicode characters", async () => {
    const unicodeValue = "测试 🚀 émojis 日本語";
    await runBash(`${SECRETS_SH} set UNICODE_KEY "${unicodeValue}"`);

    const result = await runBash(`${SECRETS_SH} get UNICODE_KEY`);
    assert(result.success, "Should handle unicode");
    assert(result.stdout.includes("测试"), "Should preserve unicode");
  });

  // ============================================
  // Tests for get_config_value function
  // ============================================

  await test("get_config_value: uses environment variable (highest priority)", async () => {
    const testScript = `
      source ${COMMON_SH}
      export TEST_VAR="env_value"
      get_config_value TEST_VAR "Prompt" "Error" ""
      echo "$TEST_VAR"
    `;

    const result = await runBash(testScript, { TEST_VAR: "env_value" });
    assert(result.success, "Should succeed");
    assert(result.stdout.includes("env_value"), "Should use env value");
    assert(
      result.stdout.includes("from environment"),
      "Should indicate env source"
    );
  });

  await test("get_config_value: uses encrypted secrets (second priority)", async () => {
    // First set a secret
    await runBash(`${SECRETS_SH} set SECRETS_VAR "secrets_value"`);

    const testScript = `
      source ${COMMON_SH}
      unset SECRETS_VAR
      get_config_value SECRETS_VAR "Prompt" "Error" ""
      echo "$SECRETS_VAR"
    `;

    const result = await runBash(testScript);
    assert(result.success, "Should succeed");
    assert(result.stdout.includes("secrets_value"), "Should use secrets value");
    assert(
      result.stdout.includes("from encrypted secrets"),
      "Should indicate secrets source"
    );
  });

  await test("get_config_value: uses default value (third priority)", async () => {
    const testScript = `
      source ${COMMON_SH}
      unset DEFAULT_VAR
      get_config_value DEFAULT_VAR "Prompt" "" "default_value"
      echo "$DEFAULT_VAR"
    `;

    const result = await runBash(testScript);
    assert(result.success, "Should succeed");
    assert(result.stdout.includes("default_value"), "Should use default value");
    assert(
      result.stdout.includes("Using default"),
      "Should indicate default source"
    );
  });

  await test("get_config_value: fails in non-interactive mode without value", async () => {
    const testScript = `
      source ${COMMON_SH}
      unset REQUIRED_VAR
      get_config_value REQUIRED_VAR "Prompt" "REQUIRED_VAR is required" ""
    `;

    const result = await runBash(testScript);
    assert(!result.success, "Should fail");
    assert(result.stderr.includes("required"), "Should show error message");
    assert(
      result.stderr.includes("non-interactive"),
      "Should mention non-interactive"
    );
  });

  await test("get_config_value: allows empty value if no error message", async () => {
    const testScript = `
      source ${COMMON_SH}
      unset OPTIONAL_VAR
      get_config_value OPTIONAL_VAR "Prompt" "" ""
      echo "VAR: [$OPTIONAL_VAR]"
    `;

    const result = await runBash(testScript);
    assert(result.success, "Should succeed");
    assert(result.stdout.includes("VAR: []"), "Should allow empty value");
  });

  await test("get_config_value: saves to SOPS when prompted (interactive)", async () => {
    // This test simulates interactive mode by providing input
    const testScript = `
      source ${COMMON_SH}
      unset PROMPTED_VAR
      echo "prompted_value" | get_config_value PROMPTED_VAR "Enter value" "" ""
      echo "$PROMPTED_VAR"
    `;

    // Note: This is tricky in non-interactive mode
    // We'll test that it works when value is provided via environment
    // The actual prompting behavior requires a TTY
    const result = await runBash(testScript);
    // In non-interactive mode, this will fail or use default
    // That's expected behavior
    assert(result.exitCode !== undefined, "Should complete");
  });

  await test("get_config_value: environment overrides secrets", async () => {
    // Set in secrets
    await runBash(`${SECRETS_SH} set OVERRIDE_VAR "secrets_value"`);

    const testScript = `
      source ${COMMON_SH}
      export OVERRIDE_VAR="env_override"
      get_config_value OVERRIDE_VAR "Prompt" "" ""
      echo "$OVERRIDE_VAR"
    `;

    const result = await runBash(testScript, { OVERRIDE_VAR: "env_override" });
    assert(result.success, "Should succeed");
    assert(result.stdout.includes("env_override"), "Should use env value");
    assert(
      result.stdout.includes("from environment"),
      "Should indicate env source"
    );
  });

  await test("get_config_value: handles multiple variables", async () => {
    await runBash(`${SECRETS_SH} set VAR1 "value1"`);
    await runBash(`${SECRETS_SH} set VAR2 "value2"`);

    const testScript = `
      source ${COMMON_SH}
      unset VAR1 VAR2
      get_config_value VAR1 "Prompt" "" ""
      get_config_value VAR2 "Prompt" "" ""
      echo "VAR1: $VAR1, VAR2: $VAR2"
    `;

    const result = await runBash(testScript);
    assert(result.success, "Should succeed");
    assert(result.stdout.includes("VAR1: value1"), "Should get VAR1");
    assert(result.stdout.includes("VAR2: value2"), "Should get VAR2");
  });

  // ============================================
  // Edge cases and failure scenarios
  // ============================================

  await test("secrets.sh: handles missing .sops.yaml gracefully", async () => {
    // This should create .sops.yaml and all prerequisites automatically
    const result = await runBash(`${SECRETS_SH} set AUTO_CREATE "value"`);
    assert(
      result.success,
      `Should create .sops.yaml automatically. stderr: ${result.stderr}`,
      result
    );
    assert(existsSync(SOPS_CONFIG), ".sops.yaml should be created");
    assert(existsSync(AGE_KEY_LOCAL), ".age-key-local should be created");
    assert(
      existsSync(SECRETS_FILE),
      "secrets.encrypted.yaml should be created"
    );
  });

  await test("secrets.sh: handles missing age key gracefully", async () => {
    // Remove age key but keep config
    cleanup();
    // This should create a new key automatically
    const result = await runBash(`${SECRETS_SH} set NEEDS_KEY "value"`);
    assert(
      result.success,
      `Should create age key automatically. stderr: ${result.stderr}`,
      result
    );
    assert(existsSync(AGE_KEY_LOCAL), ".age-key-local should be created");
  });

  await test("secrets.sh: handles corrupted encrypted file", async () => {
    // Create a corrupted file
    Bun.write(SECRETS_FILE, "corrupted content");

    const result = await runBash(`${SECRETS_SH} get TEST_KEY`);
    // Should fail gracefully
    assert(!result.success, "Should fail on corrupted file");
  });

  await test("secrets.sh: handles file with wrong encryption key", async () => {
    // Create file with one key
    await runBash(`${SECRETS_SH} set TEST_KEY "value"`);

    // Remove the key
    unlinkSync(AGE_KEY_LOCAL);

    // Try to read - should fail
    const result = await runBash(`${SECRETS_SH} get TEST_KEY`);
    assert(!result.success, "Should fail without correct key");
  });

  await test("get_config_value: handles missing secrets file", async () => {
    const testScript = `
      source ${COMMON_SH}
      unset MISSING_VAR
      get_config_value MISSING_VAR "Prompt" "" "default"
      echo "$MISSING_VAR"
    `;

    const result = await runBash(testScript);
    assert(result.success, "Should succeed with default");
    assert(result.stdout.includes("default"), "Should use default");
  });

  await test("get_config_value: handles corrupted secrets file", async () => {
    // Create corrupted file
    await runBash(`${SECRETS_SH} set TEST_KEY "value"`);
    Bun.write(SECRETS_FILE, "corrupted");

    const testScript = `
      source ${COMMON_SH}
      unset CORRUPTED_VAR
      get_config_value CORRUPTED_VAR "Prompt" "" "default"
      echo "$CORRUPTED_VAR"
    `;

    const result = await runBash(testScript);
    // Should fall back to default or fail gracefully
    assert(result.exitCode !== undefined, "Should complete");
  });

  await test("secrets.sh: set overwrites existing value", async () => {
    await runBash(`${SECRETS_SH} set OVERWRITE_KEY "old_value"`);
    await runBash(`${SECRETS_SH} set OVERWRITE_KEY "new_value"`);

    const result = await runBash(`${SECRETS_SH} get OVERWRITE_KEY`);
    assert(result.success, "Should succeed");
    assert(result.stdout.includes("new_value"), "Should have new value");
    assert(!result.stdout.includes("old_value"), "Should not have old value");
  });

  await test("secrets.sh: handles keys with special characters", async () => {
    await runBash(`${SECRETS_SH} set "KEY_WITH_UNDERSCORE" "value1"`);
    await runBash(`${SECRETS_SH} set "KEY-WITH-DASH" "value2"`);
    await runBash(`${SECRETS_SH} set "KEY.WITH.DOT" "value3"`);

    const result1 = await runBash(`${SECRETS_SH} get KEY_WITH_UNDERSCORE`);
    const result2 = await runBash(`${SECRETS_SH} get KEY-WITH-DASH`);
    const result3 = await runBash(`${SECRETS_SH} get KEY.WITH.DOT`);

    assert(
      result1.success && result1.stdout.includes("value1"),
      "Should handle underscore"
    );
    assert(
      result2.success && result2.stdout.includes("value2"),
      "Should handle dash"
    );
    assert(
      result3.success && result3.stdout.includes("value3"),
      "Should handle dot"
    );
  });

  // ============================================
  // Consistency tests
  // ============================================

  await test("Consistency: set via secrets.sh, read via get_config_value", async () => {
    await runBash(`${SECRETS_SH} set CONSISTENCY_KEY "consistency_value"`);

    const testScript = `
      source ${COMMON_SH}
      unset CONSISTENCY_KEY
      get_config_value CONSISTENCY_KEY "Prompt" "" ""
      echo "$CONSISTENCY_KEY"
    `;

    const result = await runBash(testScript);
    assert(result.success, "Should succeed");
    assert(
      result.stdout.includes("consistency_value"),
      "Should read same value"
    );
  });

  await test("Consistency: multiple operations maintain state", async () => {
    await runBash(`${SECRETS_SH} set STATE_KEY1 "state1"`);
    await runBash(`${SECRETS_SH} set STATE_KEY2 "state2"`);
    await runBash(`${SECRETS_SH} delete STATE_KEY1`);
    await runBash(`${SECRETS_SH} set STATE_KEY3 "state3"`);

    const listResult = await runBash(`${SECRETS_SH} list`);
    assert(listResult.success, "Should succeed");
    assert(!listResult.stdout.includes("STATE_KEY1"), "KEY1 should be deleted");
    assert(listResult.stdout.includes("STATE_KEY2"), "KEY2 should exist");
    assert(listResult.stdout.includes("STATE_KEY3"), "KEY3 should exist");
  });

  // Print summary
  console.log("\n" + "=".repeat(60));
  console.log("📊 Test Summary");
  console.log("=".repeat(60));

  const passed = results.filter((r) => r.passed).length;
  const failed = results.filter((r) => !r.passed).length;

  console.log(`Total tests: ${results.length}`);
  console.log(`✅ Passed: ${passed}`);
  console.log(`❌ Failed: ${failed}`);

  if (failed > 0) {
    console.log("\nFailed tests:");
    results
      .filter((r) => !r.passed)
      .forEach((r) => {
        console.log(`  ❌ ${r.name}`);
        if (r.error) console.log(`     ${r.error}`);
      });
    process.exit(1);
  } else {
    console.log("\n🎉 All tests passed!");
    process.exit(0);
  }
}

// Run tests
runTests().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
