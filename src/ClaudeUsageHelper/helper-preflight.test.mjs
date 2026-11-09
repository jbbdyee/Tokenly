import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const source = fileURLToPath(new URL('./claude-usage-helper.mjs', import.meta.url));

test('missing SDK fails before any CLI or model path', () => {
  const root = mkdtempSync(join(tmpdir(), 'tokenly-helper-missing-'));
  try {
    copyFileSync(source, join(root, 'claude-usage-helper.mjs'));
    const result = spawnSync(process.execPath, [join(root, 'claude-usage-helper.mjs'), '/usr/bin/true']);
    assert.equal(result.status, 20);
    assert.equal(result.stdout.length, 0);
    assert.equal(result.stderr.length, 0);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('SDK version mismatch fails before importing SDK', () => {
  const root = mkdtempSync(join(tmpdir(), 'tokenly-helper-version-'));
  try {
    copyFileSync(source, join(root, 'claude-usage-helper.mjs'));
    const sdk = join(root, 'node_modules', '@anthropic-ai', 'claude-agent-sdk');
    mkdirSync(sdk, { recursive: true });
    writeFileSync(join(sdk, 'package.json'), '{"version":"0.0.0"}');
    const result = spawnSync(process.execPath, [join(root, 'claude-usage-helper.mjs'), '/usr/bin/true']);
    assert.equal(result.status, 23);
    assert.equal(result.stdout.length, 0);
    assert.equal(result.stderr.length, 0);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
