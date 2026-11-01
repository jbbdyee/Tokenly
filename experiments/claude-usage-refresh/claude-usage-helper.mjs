// Development-only SDK bridge. Do not invoke without separate real-account authorization.
// stdout is one minimal JSON object on success; never print SDK errors or raw responses.
import { readFileSync } from 'node:fs';
const EXIT = { unavailable: 20, unexpectedMessage: 21, failed: 22, incompatible: 23,
               authentication: 24, permission: 25, rateLimited: 26 };
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
  // Inspect only numeric status fields; never print SDK error text or a response body.
  // The SDK's actual error shape is not yet verified against a real failure.
  const status = [error?.status, error?.statusCode, error?.response?.status]
    .find((value) => typeof value === 'number');
  process.exitCode = error?.message === 'incompatible_sdk' ? EXIT.incompatible
    : ['ERR_MODULE_NOT_FOUND', 'ENOENT'].includes(error?.code) ? EXIT.unavailable
    : status === 401 ? EXIT.authentication
    : status === 403 ? EXIT.permission
    : status === 429 ? EXIT.rateLimited : EXIT.failed;
} finally {
  if (timer) clearTimeout(timer);
  session?.close();
}
