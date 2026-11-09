import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { EXIT, classifyFailure, retryAfterSeconds } from './claude-usage-helper.mjs';

const source = fileURLToPath(new URL('./claude-usage-helper.mjs', import.meta.url));
const withCode = (code, extra = {}) => Object.assign(new Error('secret detail'), { code }, extra);

test('connection failures, fetch failures and 5xx are retryable network failures', () => {
  for (const code of ['ENOTFOUND', 'ECONNRESET', 'ETIMEDOUT', 'EAI_AGAIN', 'ECONNREFUSED', 'UND_ERR_SOCKET']) {
    assert.equal(classifyFailure(withCode(code)), EXIT.network, code);
  }
  const fetchFailed = new TypeError('fetch failed');
  fetchFailed.cause = withCode('ENOTFOUND');
  assert.equal(classifyFailure(fetchFailed), EXIT.network);
  assert.equal(classifyFailure(new TypeError('fetch failed')), EXIT.network);
  assert.equal(classifyFailure(Object.assign(new Error('x'), { name: 'APIConnectionError' })), EXIT.network);
  assert.equal(classifyFailure(new Error('timeout')), EXIT.network);
  assert.equal(classifyFailure(Object.assign(new Error('x'), { status: 503 })), EXIT.network);
  assert.equal(classifyFailure(Object.assign(new Error('x'), { status: 408 })), EXIT.network);
});

test('account, rate-limit and model-activity outcomes are never reported as network failures', () => {
  const reset = withCode('ECONNRESET');
  assert.equal(classifyFailure(Object.assign(new Error('x'), { status: 401, cause: reset })), EXIT.authentication);
  assert.equal(classifyFailure(Object.assign(new Error('x'), { status: 403, cause: reset })), EXIT.permission);
  assert.equal(classifyFailure(Object.assign(new Error('x'), { statusCode: 429, cause: reset })), EXIT.rateLimited);
  assert.equal(classifyFailure(Object.assign(new Error('x'), { response: { status: 401 } })), EXIT.authentication);
  assert.equal(classifyFailure(withCode('ENOTFOUND'), { messageSeen: true }), EXIT.unexpectedMessage);
  assert.equal(classifyFailure(new Error('incompatible_sdk')), EXIT.incompatible);
  assert.equal(classifyFailure(withCode('ERR_MODULE_NOT_FOUND')), EXIT.unavailable);
  assert.equal(classifyFailure(Object.assign(new Error('x'), { status: 400 })), EXIT.failed);
  assert.equal(classifyFailure(new Error('something else')), EXIT.failed);
  assert.equal(classifyFailure(undefined), EXIT.failed);
});

test('Retry-After is read as bounded whole seconds from seconds or an HTTP date', () => {
  const now = Date.parse('2026-11-04T05:00:00Z');
  assert.equal(retryAfterSeconds({ headers: { 'Retry-After': '120' } }, now), 120);
  assert.equal(retryAfterSeconds({ headers: new Headers({ 'retry-after': '30' }) }, now), 30);
  assert.equal(retryAfterSeconds({ response: { headers: { 'retry-after': 'Wed, 04 Nov 2026 05:10:00 GMT' } } }, now), 600);
  assert.equal(retryAfterSeconds({ headers: { 'retry-after': '99999999' } }, now), 6 * 3600);
  assert.equal(retryAfterSeconds({ headers: { 'retry-after': 'Wed, 04 Nov 2026 04:00:00 GMT' } }, now), 0);
  assert.equal(retryAfterSeconds({ headers: { 'retry-after': 'soon' } }, now), undefined);
  assert.equal(retryAfterSeconds({ headers: {} }, now), undefined);
  assert.equal(retryAfterSeconds({}, now), undefined);
});

// Runs the real helper against a fake SDK package; no Claude CLI, account or network is used.
function runWithFakeSDK(mode) {
  const root = mkdtempSync(join(tmpdir(), 'tokenly-helper-errors-'));
  try {
    copyFileSync(source, join(root, 'claude-usage-helper.mjs'));
    const sdk = join(root, 'node_modules', '@anthropic-ai', 'claude-agent-sdk');
    mkdirSync(sdk, { recursive: true });
    writeFileSync(join(sdk, 'package.json'),
      '{"name":"@anthropic-ai/claude-agent-sdk","version":"0.3.169","type":"module","exports":"./sdk.mjs"}');
    writeFileSync(join(sdk, 'sdk.mjs'), `
      export function query() {
        const fail = () => {
          const mode = process.env.FAKE_SDK_MODE;
          if (mode === 'network') {
            const error = new TypeError('fetch failed');
            error.cause = Object.assign(new Error('getaddrinfo ENOTFOUND private.example token=abc'), { code: 'ENOTFOUND' });
            throw error;
          }
          if (mode === 'rate') {
            throw Object.assign(new Error('rate limited body token=abc'), { status: 429, headers: { 'retry-after': '120' } });
          }
          if (mode === 'auth') {
            throw Object.assign(new Error('unauthorized token=abc'), { status: 401, cause: { code: 'ECONNRESET' } });
          }
          throw new Error('unknown token=abc');
        };
        return {
          async *[Symbol.asyncIterator]() { await new Promise(() => {}); },
          initializationResult: async () => fail(),
          close() {},
        };
      }`);
    return spawnSync(process.execPath, [join(root, 'claude-usage-helper.mjs'), '/usr/bin/true'],
      { env: { ...process.env, FAKE_SDK_MODE: mode }, timeout: 10000 });
  } finally { rmSync(root, { recursive: true, force: true }); }
}

test('helper process exit codes and output stay minimal for each failure class', () => {
  const network = runWithFakeSDK('network');
  assert.equal(network.status, EXIT.network);
  assert.equal(network.stdout.length, 0);
  const rate = runWithFakeSDK('rate');
  assert.equal(rate.status, EXIT.rateLimited);
  assert.equal(rate.stdout.toString(), '{"retry_after_seconds":120}\n');
  const auth = runWithFakeSDK('auth');
  assert.equal(auth.status, EXIT.authentication);
  assert.equal(auth.stdout.length, 0);
  const unknown = runWithFakeSDK('unknown');
  assert.equal(unknown.status, EXIT.failed);
  for (const result of [network, rate, auth, unknown]) {
    assert.equal(result.stderr.length, 0);
    assert.ok(!result.stdout.toString().includes('token'));
    assert.ok(!result.stdout.toString().includes('private.example'));
  }
});
