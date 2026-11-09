import test from 'node:test';
import assert from 'node:assert/strict';
import { parseDirect, retainDirect, selectWindows, attemptAllowed } from './policy.mjs';

const w = (utilization, resets_at = '2026-10-31T12:00:00Z') => ({ utilization, resets_at });
const response = (rate_limits) => ({ rate_limits_available: true, rate_limits });
const parse = (rate_limits, at = 1000) => parseDirect(response(rate_limits), at);

test('two windows, 100% used means 0% remaining', () => {
  const result = parse({ five_hour: w(100), seven_day: w(35) });
  assert.equal(result.kind, 'data');
  assert.equal(result.windows.five_hour.remainingPercent, 0);
  assert.equal(result.windows.seven_day.remainingPercent, 65);
  assert.equal(result.windows.five_hour.resetAt, '2026-10-31T12:00:00.000Z');
});

test('missing and null windows are independent', () => {
  assert.deepEqual(Object.keys(parse({ five_hour: w(20) }).windows), ['five_hour']);
  assert.deepEqual(Object.keys(parse({ five_hour: null, seven_day: w(40) }).windows), ['seven_day']);
  assert.equal(parse({ five_hour: null }).kind, 'noData');
});

test('true with null rate limits is no data, not unsupported', () => {
  assert.equal(parseDirect(response(null), 1000).kind, 'noData');
  assert.equal(parseDirect({ rate_limits_available: false, rate_limits: null }, 1000).kind, 'noData');
});

test('null or malformed reset keeps percent with unknown reset', () => {
  assert.equal(parse({ five_hour: w(10, null) }).windows.five_hour.resetAt, null);
  assert.equal(parse({ five_hour: w(10, 'tomorrow') }).windows.five_hour.resetAt, null);
  assert.equal(parse({ five_hour: w(10, '2026-10-31T12:00:00') }).windows.five_hour.resetAt, null);
  assert.equal(parse({ five_hour: w(10, '2026-02-30T12:00:00Z') }).windows.five_hour.resetAt, null);
  assert.equal(parse({ five_hour: w(10, '2026-10-31T14:00:00+02:00') }).windows.five_hour.resetAt,
    '2026-10-31T12:00:00.000Z');
});

test('invalid utilization rejects only its window', () => {
  for (const value of [null, -1, 101, '50', Number.NaN]) {
    const result = parse({ five_hour: w(value), seven_day: w(50) });
    assert.equal(result.windows.five_hour, undefined);
    assert.equal(result.windows.seven_day.remainingPercent, 50);
  }
});

test('failed or empty direct query retains last accepted windows and success time', () => {
  const first = retainDirect(null, parse({ five_hour: w(20) }, 1000));
  assert.deepEqual(retainDirect(first, parse(null, 2000)), first);
  const second = retainDirect(first, parse({ seven_day: w(30) }, 3000));
  assert.equal(second.lastSuccessAt, 3000);
  assert.equal(second.windows.five_hour.receivedAt, 1000);
  assert.equal(second.windows.seven_day.receivedAt, 3000);
});

test('per-window statusLine fallback does not overwrite fresh direct data', () => {
  const direct = retainDirect(null, parse({ five_hour: w(25) }, 1000));
  const statusLine = { windows: {
    five_hour: { remainingPercent: 99, source: 'statusLine', receivedAt: 1100 },
    seven_day: { remainingPercent: 70, source: 'statusLine', receivedAt: 1100 },
  } };
  const selected = selectWindows({ direct, statusLine, now: 1200,
    directMaxAgeMs: 500, statusMaxAgeMs: 900000 });
  assert.equal(selected.five_hour.source, 'direct');
  assert.equal(selected.seven_day.source, 'statusLine');
  const later = selectWindows({ direct, statusLine, now: 2000,
    directMaxAgeMs: 500, statusMaxAgeMs: 900000 });
  assert.equal(later.five_hour.source, 'statusLine');
});

test('stale last success remains marked by its original time', () => {
  const direct = retainDirect(null, parse({ five_hour: w(25) }, 1000));
  const selected = selectWindows({ direct, statusLine: null, now: 999999,
    directMaxAgeMs: 500, statusMaxAgeMs: 900000 });
  assert.equal(selected.five_hour.receivedAt, 1000);
});

test('in-flight and backoff gate prevent duplicate attempts', () => {
  assert.equal(attemptAllowed({ inFlight: true, now: 2000, nextAllowedAt: 0 }), false);
  assert.equal(attemptAllowed({ inFlight: false, now: 1999, nextAllowedAt: 2000 }), false);
  assert.equal(attemptAllowed({ inFlight: false, now: 2000, nextAllowedAt: 2000 }), true);
});
