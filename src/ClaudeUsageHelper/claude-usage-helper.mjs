// SDK usage bridge. The app's build route and refresh gate decide when account access is allowed.
// stdout is one minimal JSON object on success; never print SDK errors or raw responses.
import { readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
export const EXIT = { unavailable: 20, unexpectedMessage: 21, failed: 22, incompatible: 23,
                      authentication: 24, permission: 25, rateLimited: 26, network: 27 };
const NETWORK_CODES = new Set(['ENOTFOUND', 'EAI_AGAIN', 'ECONNRESET', 'ECONNREFUSED', 'ECONNABORTED',
  'ETIMEDOUT', 'ENETUNREACH', 'ENETDOWN', 'EHOSTUNREACH', 'EHOSTDOWN', 'EPIPE', 'ENOTCONN',
  'UND_ERR_SOCKET', 'UND_ERR_CONNECT_TIMEOUT', 'UND_ERR_HEADERS_TIMEOUT', 'UND_ERR_BODY_TIMEOUT',
  'UND_ERR_CLOSED']);
const NETWORK_NAMES = new Set(['APIConnectionError', 'APIConnectionTimeoutError', 'FetchError',
  'ConnectTimeoutError', 'HeadersTimeoutError', 'SocketError']);
const MAX_RETRY_AFTER = 6 * 3600;

function numericStatus(error) {
  return [error?.status, error?.statusCode, error?.response?.status]
    .find((value) => typeof value === 'number');
}

// Walks the error and its `cause` chain (fetch wraps the socket error) without reading message bodies.
function causes(error) {
  const chain = [];
  for (let current = error, depth = 0; current && typeof current === 'object' && depth < 5;
       current = current.cause, depth += 1) chain.push(current);
  return chain;
}

function isNetworkFailure(error) {
  return causes(error).some((item) => NETWORK_CODES.has(item.code) || NETWORK_NAMES.has(item.name) ||
    item.message === 'timeout' ||
    (item.name === 'TypeError' && typeof item.message === 'string' && /^fetch failed$/i.test(item.message)));
}

// Maps a thrown error to an exit code. Account, permission, rate-limit and model-activity outcomes are
// decided before any network check, so a wrapped connection error can never hide them.
export function classifyFailure(error, { messageSeen = false } = {}) {
  if (messageSeen) return EXIT.unexpectedMessage;
  if (error?.message === 'incompatible_sdk') return EXIT.incompatible;
  if (['ERR_MODULE_NOT_FOUND', 'ENOENT'].includes(error?.code)) return EXIT.unavailable;
  const status = numericStatus(error);
  if (status === 401) return EXIT.authentication;
  if (status === 403) return EXIT.permission;
  if (status === 429) return EXIT.rateLimited;
  if (status === 408 || (typeof status === 'number' && status >= 500 && status <= 599)) return EXIT.network;
  if (typeof status === 'number') return EXIT.failed;
  return isNetworkFailure(error) ? EXIT.network : EXIT.failed;
}

function header(headers, name) {
  if (!headers) return undefined;
  if (typeof headers.get === 'function') return headers.get(name) ?? undefined;
  const key = Object.keys(headers).find((candidate) => candidate.toLowerCase() === name);
  return key === undefined ? undefined : headers[key];
}

// Reads only the Retry-After header (seconds or HTTP date) and returns whole seconds within 0...6 h.
export function retryAfterSeconds(error, now = Date.now()) {
  const raw = header(error?.headers, 'retry-after') ?? header(error?.response?.headers, 'retry-after');
  if (typeof raw !== 'string' && typeof raw !== 'number') return undefined;
  const text = String(raw).trim();
  if (text.length === 0 || text.length > 64) return undefined;
  let seconds;
  if (/^\d+$/.test(text)) seconds = Number(text);
  else {
    const date = Date.parse(text);
    if (Number.isNaN(date)) return undefined;
    seconds = Math.ceil((date - now) / 1000);
  }
  if (!Number.isFinite(seconds)) return undefined;
  return Math.min(Math.max(seconds, 0), MAX_RETRY_AFTER);
}

async function main() {
  let session;
  let timer;
  let messageSeen = false;
  try {
    const cliPath = process.argv[2];
    if (!cliPath?.startsWith('/')) { process.exitCode = EXIT.unavailable; }
    else {
      const sdkManifest = JSON.parse(readFileSync(
        new URL('./node_modules/@anthropic-ai/claude-agent-sdk/package.json', import.meta.url), 'utf8'));
      if (sdkManifest.version !== '0.3.169') throw new Error('incompatible_sdk');
      const { query } = await import('@anthropic-ai/claude-agent-sdk');
      if (typeof query !== 'function') throw new Error('incompatible_sdk');
      const childEnv = { ...process.env, CLAUDE_CODE_SAFE_MODE: '1', CLAUDE_CODE_MAX_RETRIES: '0' };
      for (const key of ['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC', 'ANTHROPIC_API_KEY',
                         'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_BASE_URL']) delete childEnv[key];
      async function* noMessages() { await new Promise(() => {}); }
      session = query({ prompt: noMessages(), options: {
        pathToClaudeCodeExecutable: cliPath,
        env: childEnv, settingSources: [], strictMcpConfig: true,
        persistSession: false, tools: [], promptSuggestions: false,
      } });
      const observed = (async () => {
        try {
          for await (const message of session) {
            if (message.type === 'assistant' || message.type === 'user') {
              messageSeen = true;
              session.close();
              break;
            }
          }
        } catch { /* Session closed; never print SDK messages. */ }
      })();
      const deadline = new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('timeout')), 25000);
      });
      await Promise.race([session.initializationResult(), deadline]);
      if (typeof session.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET !== 'function') {
        throw new Error('incompatible_sdk');
      }
      const response = await Promise.race([
        session.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET(), deadline,
      ]);
      if (messageSeen || (typeof response?.session?.total_cost_usd === 'number' &&
                          response.session.total_cost_usd > 0)) {
        process.exitCode = EXIT.unexpectedMessage;
      } else if (typeof response?.rate_limits_available !== 'boolean' ||
                 !('rate_limits' in response)) {
        process.exitCode = EXIT.incompatible;
      } else {
        const safeWindow = (window) => {
          if (window === null) return null;
          if (!window || typeof window !== 'object' || Array.isArray(window)) return undefined;
          return {
            utilization: typeof window.utilization === 'number' ? window.utilization : null,
            resets_at: typeof window.resets_at === 'string' && window.resets_at.length <= 64
              ? window.resets_at : null,
          };
        };
        const limits = response.rate_limits;
        const safeLimits = limits && typeof limits === 'object' && !Array.isArray(limits)
          ? Object.fromEntries(['five_hour', 'seven_day'].filter((key) => key in limits)
            .map((key) => [key, safeWindow(limits[key])]).filter(([, value]) => value !== undefined))
          : null;
        process.stdout.write(JSON.stringify({
          rate_limits_available: response.rate_limits_available, rate_limits: safeLimits,
        }) + '\n');
      }
      session.close();
      await Promise.race([observed, new Promise((resolve) => setTimeout(resolve, 100))]);
    }
  } catch (error) {
    // Inspect only status numbers, error codes/names and the Retry-After header; never print SDK error
    // text or a response body. The SDK's actual error shape is not yet verified against a real failure.
    process.exitCode = classifyFailure(error, { messageSeen });
    if (process.exitCode === EXIT.rateLimited) {
      const retryAfter = retryAfterSeconds(error);
      if (retryAfter !== undefined) process.stdout.write(JSON.stringify({ retry_after_seconds: retryAfter }) + '\n');
    }
  } finally {
    if (timer) clearTimeout(timer);
    session?.close();
  }
}

// Runs only as the bundled entry point; tests import the classifiers without starting a session.
const entry = process.argv[1];
let isEntry = false;
try { isEntry = !!entry && realpathSync(entry) === realpathSync(fileURLToPath(import.meta.url)); } catch {}
if (isEntry) await main();
