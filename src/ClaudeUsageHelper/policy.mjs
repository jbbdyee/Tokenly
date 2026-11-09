// Experiment-only pure data policy. No SDK import, process launch, network, or storage.
export function parseDirect(response, receivedAt) {
  if (response?.rate_limits_available !== true || !plain(response.rate_limits)) {
    return { kind: 'noData', windows: {}, receivedAt: null };
  }
  const windows = {};
  for (const key of ['five_hour', 'seven_day']) {
    const raw = response.rate_limits[key];
    if (!plain(raw) || typeof raw.utilization !== 'number' ||
        !Number.isFinite(raw.utilization) || raw.utilization < 0 || raw.utilization > 100) continue;
    const resetAt = parseISO(raw.resets_at);
    windows[key] = { remainingPercent: 100 - raw.utilization, resetAt,
      source: 'direct', receivedAt };
  }
  return { kind: Object.keys(windows).length ? 'data' : 'noData', windows,
    receivedAt: Object.keys(windows).length ? receivedAt : null };
}

function plain(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }

// Accept an explicit timezone; Date.parse's permissive local-time fallback is unsuitable here.
function parseISO(value) {
  if (typeof value !== 'string') return null;
  const parts = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|([+-])(\d{2}):(\d{2}))$/.exec(value);
  if (!parts) return null;
  const [, year, month, day, hour, minute, second, , sign, offsetHour, offsetMinute] = parts;
  if (Number(offsetHour ?? 0) > 23 || Number(offsetMinute ?? 0) > 59) return null;
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) return null;
  const offset = sign ? (sign === '+' ? 1 : -1) *
    (Number(offsetHour) * 60 + Number(offsetMinute)) * 60000 : 0;
  const local = new Date(milliseconds + offset);
  if (local.getUTCFullYear() !== Number(year) || local.getUTCMonth() + 1 !== Number(month) ||
      local.getUTCDate() !== Number(day) || local.getUTCHours() !== Number(hour) ||
      local.getUTCMinutes() !== Number(minute) || local.getUTCSeconds() !== Number(second)) return null;
  return new Date(milliseconds).toISOString();
}

export function retainDirect(previous, parsed) {
  if (parsed.kind !== 'data') return previous;
  return { windows: { ...(previous?.windows ?? {}), ...parsed.windows },
    lastSuccessAt: parsed.receivedAt };
}

// Freshness thresholds are caller-supplied; product polling interval is intentionally unset.
export function selectWindows({ direct, statusLine, now, directMaxAgeMs, statusMaxAgeMs }) {
  const selected = {};
  for (const key of ['five_hour', 'seven_day']) {
    const d = direct?.windows?.[key];
    const s = statusLine?.windows?.[key];
    const fresh = (v, maxAge) => v && Number.isFinite(v.receivedAt) &&
      v.receivedAt <= now && now - v.receivedAt <= maxAge;
    selected[key] = fresh(d, directMaxAgeMs) ? d :
      fresh(s, statusMaxAgeMs) ? s : d ?? s ?? null;
  }
  return selected;
}

export function attemptAllowed({ inFlight, now, nextAllowedAt }) {
  return !inFlight && now >= nextAllowedAt;
}
