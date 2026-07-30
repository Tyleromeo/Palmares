// REFERENCE COPY of the deployed Supabase Edge Function (sync-strava).
// The authoritative source lives outside this repo at
// supabase/functions/sync-strava/index.ts on the working machine and is what
// `supabase functions deploy` uploads. This copy exists so both machines can
// read the action contract without guessing. Do not deploy from here.

// Supabase Edge Function backing the Eldorado dashboard's callEdge() calls.
// Implements the action contract documented in the HTML near callEdge():
//   exchange_token, refresh_token, get_cache, set_cache, list_activities,
//   sync_activities, load_power_prs, patch_achievement_counts,
//   list_road_reports, add_road_report, get_weather, get_maps_token, disconnect
//
// Required secrets (set via `supabase secrets set`, never committed):
//   STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically by the
// Supabase runtime and are not set manually.

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const STRAVA_CLIENT_ID = Deno.env.get('STRAVA_CLIENT_ID')!;
const STRAVA_CLIENT_SECRET = Deno.env.get('STRAVA_CLIENT_SECRET')!;

const supabase: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

function badRequest(message: string): Response {
  return json({ error: message }, 400);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return badRequest('Invalid JSON body');
  }

  const action = body.action as string | undefined;
  if (!action) return badRequest('Missing action');

  try {
    switch (action) {
      case 'exchange_token': return await exchangeToken(body);
      case 'refresh_token': return await refreshToken(body);
      case 'get_cache': return await getCache(body);
      case 'set_cache': return await setCache(body);
      case 'list_activities': return await listActivities(body);
      case 'sync_activities': return await syncActivities(body);
      case 'prune_activities': return await pruneActivities(body);
      case 'load_power_prs': return await loadPowerPrs(body);
      case 'patch_achievement_counts': return await patchAchievementCounts(body);
      case 'list_road_reports': return await listRoadReports();
      case 'add_road_report': return await addRoadReport(body);
      case 'get_weather': return await getWeather(body);
      case 'get_maps_token': return await getMapsToken();
      case 'disconnect': return await disconnect(body);
      default: return badRequest('Unknown action: ' + action);
    }
  } catch (e) {
    console.error('sync-strava error for action', action, e);
    // Supabase/Postgrest errors are plain objects (not Error instances), so
    // `instanceof Error` alone was swallowing their .message and reporting a
    // useless generic "Internal error" for every DB-level failure.
    const message = e instanceof Error
      ? e.message
      : (e && typeof e === 'object' && 'message' in e ? String((e as any).message) : 'Internal error');
    return json({ error: message }, 500);
  }
});

// ---------- Strava OAuth helpers ----------

async function stravaTokenRequest(params: Record<string, string>) {
  const resp = await fetch('https://www.strava.com/oauth/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: STRAVA_CLIENT_ID,
      client_secret: STRAVA_CLIENT_SECRET,
      ...params,
    }),
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) console.error('Strava token endpoint error', resp.status, JSON.stringify(data));
  return { ok: resp.ok, data };
}

// Strava's token error bodies look like:
//   { message: "Authorization Error", errors: [{ resource, field, code }] }
// The top-level message alone (e.g. "Authorization Error") doesn't say which
// field is wrong, so fold in the errors array for a diagnosable message.
function stravaErrorMessage(data: any, fallback: string): string {
  const base = data?.message || fallback;
  const detail = Array.isArray(data?.errors)
    ? data.errors.map((e: any) => [e.resource, e.field, e.code].filter(Boolean).join(' ')).join('; ')
    : '';
  return detail ? `${base}: ${detail}` : base;
}

// ---------- actions ----------

async function exchangeToken(body: any): Promise<Response> {
  const { code } = body;
  if (!code) return badRequest('Missing code');

  const { ok, data } = await stravaTokenRequest({ code, grant_type: 'authorization_code' });
  if (!ok) return json({ error: stravaErrorMessage(data, 'Strava token exchange failed') }, 400);

  const athlete = data.athlete || {};
  if (!athlete.id) return json({ error: 'Strava did not return an athlete id' }, 502);

  const { data: row, error } = await supabase
    .from('athletes')
    .upsert({
      id: athlete.id, // athletes.id has no default; convention here is id === strava_id
      strava_id: athlete.id,
      access_token: data.access_token,
      refresh_token: data.refresh_token,
      token_expires_at: data.expires_at,
      firstname: athlete.firstname || null,
      lastname: athlete.lastname || null,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'strava_id' })
    .select('id')
    .single();
  if (error) throw error;

  return json({
    access_token: data.access_token,
    expires_at: data.expires_at,
    session_id: row.id,
    athlete,
  });
}

async function refreshToken(body: any): Promise<Response> {
  const { session_id, athlete_id } = body;
  if (!session_id && !athlete_id) return badRequest('Missing session_id or athlete_id');

  let row = null;
  if (session_id) {
    const { data, error } = await supabase.from('athletes').select('*').eq('id', session_id).maybeSingle();
    if (error) throw error;
    row = data;
  }
  if (!row && athlete_id) {
    const { data, error } = await supabase.from('athletes').select('*').eq('strava_id', athlete_id).maybeSingle();
    if (error) throw error;
    row = data;
  }
  if (!row) return json({ error: 'Session not found' }, 404);

  const now = Math.floor(Date.now() / 1000);
  if (row.token_expires_at - 60 > now) {
    return json({ access_token: row.access_token, expires_at: row.token_expires_at });
  }

  const { ok, data } = await stravaTokenRequest({
    grant_type: 'refresh_token',
    refresh_token: row.refresh_token,
  });
  if (!ok) return json({ error: stravaErrorMessage(data, 'Strava token refresh failed') }, 400);

  await supabase.from('athletes').update({
    access_token: data.access_token,
    refresh_token: data.refresh_token || row.refresh_token,
    token_expires_at: data.expires_at,
    updated_at: new Date().toISOString(),
  }).eq('id', row.id);

  return json({ access_token: data.access_token, expires_at: data.expires_at });
}

async function getCache(body: any): Promise<Response> {
  const { athlete_id, cache_key, max_age_ms } = body;
  if (!athlete_id || !cache_key) return badRequest('Missing athlete_id or cache_key');

  const { data: row, error } = await supabase
    .from('api_cache')
    .select('payload, updated_at')
    .eq('athlete_id', athlete_id)
    .eq('cache_key', cache_key)
    .maybeSingle();
  if (error) throw error;
  if (!row) return json({ payload: null });

  if (max_age_ms) {
    const age = Date.now() - new Date(row.updated_at).getTime();
    if (age > max_age_ms) return json({ payload: null });
  }
  return json({ payload: row.payload });
}

async function setCache(body: any): Promise<Response> {
  const { athlete_id, cache_key, payload } = body;
  if (!athlete_id || !cache_key) return badRequest('Missing athlete_id or cache_key');

  const { error } = await supabase.from('api_cache').upsert({
    athlete_id,
    cache_key,
    payload: payload ?? null,
    updated_at: new Date().toISOString(),
  }, { onConflict: 'athlete_id,cache_key' });
  if (error) throw error;
  return json({ ok: true });
}

async function listActivities(body: any): Promise<Response> {
  const { athlete_id, limit } = body;
  if (!athlete_id) return badRequest('Missing athlete_id');

  const targetLimit = limit && limit > 0 ? Math.min(limit, 5000) : 500;
  // PostgREST enforces its own row cap per-connection (default 1000) on top
  // of whatever .limit() asks for, and that cap doesn't reliably apply to
  // already-pooled connections right after raising it project-wide - some
  // requests would silently get 1000 rows even after that config change.
  // Paginating with .range() in <=1000-row pages sidesteps the cap entirely
  // regardless of what any given connection's effective setting is.
  const pageSize = 1000;
  const activities: any[] = [];
  let offset = 0;

  while (activities.length < targetLimit) {
    const want = Math.min(pageSize, targetLimit - activities.length);
    const { data, error } = await supabase
      .from('strava_activities')
      .select('*')
      .eq('athlete_id', athlete_id)
      .order('start_date', { ascending: false })
      .range(offset, offset + want - 1);
    if (error) throw error;
    if (!data || !data.length) break;
    activities.push(...data);
    offset += data.length;
    if (data.length < want) break; // fewer rows than requested = reached the end
  }

  return json({ activities });
}

// Delete cached activities that no longer exist on Strava.
//
// sync_activities only ever upserts, so an activity deleted on Strava stayed
// in the cache forever: a rider who split a ride, uploaded the pieces, then
// deleted them and re-uploaded one merged file kept seeing the deleted
// fragments, and "Force full resync" couldn't help because the next load read
// those ghosts straight back out of the cache.
//
// Only ever called after a FULL resync, where the caller has genuinely
// enumerated every activity Strava returns - pruning against a partial
// (incremental) list would wipe real history. The caller sends the complete
// id set; we diff server-side and delete only the difference, so a truncated
// or failed fetch can't cascade into data loss.
async function pruneActivities(body: any): Promise<Response> {
  const { athlete_id, ids } = body;
  if (!athlete_id) return badRequest('Missing athlete_id');
  if (!Array.isArray(ids)) return badRequest('Missing ids');
  // Refuse to prune against a suspiciously empty set: an upstream fetch
  // failure must never be able to empty someone's history.
  if (ids.length === 0) return json({ ok: true, deleted: 0, skipped: 'empty id set' });

  const { data: existing, error: readErr } = await supabase
    .from('strava_activities')
    .select('id')
    .eq('athlete_id', athlete_id);
  if (readErr) throw readErr;

  const keep = new Set(ids.map((n: any) => String(n)));
  const stale = (existing || [])
    .map((r: any) => r.id)
    .filter((id: any) => !keep.has(String(id)));
  if (!stale.length) return json({ ok: true, deleted: 0 });

  // Chunked so a large cleanup can't build an oversized statement.
  let deleted = 0;
  for (let i = 0; i < stale.length; i += 200) {
    const chunk = stale.slice(i, i + 200);
    const { error } = await supabase
      .from('strava_activities')
      .delete()
      .eq('athlete_id', athlete_id)
      .in('id', chunk);
    if (error) throw error;
    deleted += chunk.length;
  }
  return json({ ok: true, deleted });
}

async function syncActivities(body: any): Promise<Response> {
  const { athlete, activities } = body;
  if (!athlete || !athlete.id) return badRequest('Missing athlete');
  if (!Array.isArray(activities) || !activities.length) return json({ ok: true });

  const rows = activities.map((a: any) => ({
    id: a.id,
    athlete_id: athlete.id,
    name: a.name ?? null,
    type: a.type ?? null,
    distance: a.distance ?? null,
    moving_time: a.moving_time ?? null,
    total_elevation_gain: a.total_elevation_gain ?? null,
    average_watts: a.average_watts ?? null,
    max_watts: a.max_watts ?? null,
    average_heartrate: a.average_heartrate ?? null,
    max_heartrate: a.max_heartrate ?? null,
    average_speed: a.average_speed ?? null,
    average_cadence: a.average_cadence ?? null,
    suffer_score: a.suffer_score ?? null,
    achievement_count: a.achievement_count ?? 0,
    gear_id: a.gear_id ?? null,
    start_date: a.start_date ?? null,
    start_date_local: a.start_date_local ?? a.start_date ?? null,
    updated_at: new Date().toISOString(),
  }));

  const { error } = await supabase.from('strava_activities').upsert(rows, { onConflict: 'id' });
  if (error) throw error;

  if (athlete.firstname || athlete.lastname) {
    await supabase.from('athletes').update({
      firstname: athlete.firstname || null,
      lastname: athlete.lastname || null,
      updated_at: new Date().toISOString(),
    }).eq('strava_id', athlete.id);
  }

  return json({ ok: true });
}

async function loadPowerPrs(body: any): Promise<Response> {
  const { athlete_id } = body;
  if (!athlete_id) return badRequest('Missing athlete_id');

  const { data, error } = await supabase
    .from('power_prs')
    .select('*')
    .eq('athlete_id', athlete_id);
  if (error) throw error;
  return json({ prs: data || [] });
}

async function patchAchievementCounts(body: any): Promise<Response> {
  const { corrections } = body;
  if (!Array.isArray(corrections) || !corrections.length) return json({ ok: true });

  for (const c of corrections) {
    if (!c || typeof c.id === 'undefined') continue;
    const { error } = await supabase
      .from('strava_activities')
      .update({ achievement_count: c.achievement_count, updated_at: new Date().toISOString() })
      .eq('id', c.id);
    if (error) throw error;
  }
  return json({ ok: true });
}

// ---------- Weather (Apple WeatherKit proxy) ----------
// WeatherKit REST requires an ES256-signed JWT from a private key, which
// can never ship in client-side JS - so the browser asks this function
// instead. The response is transformed server-side into the exact
// Open-Meteo shape the frontend has always consumed (F temps, m/s winds,
// WMO weather codes, local wall-clock timestamps), so the site's charts,
// advisory, and tailwind logic needed zero changes for the migration.
//
// Secrets (all four required before this activates; until then the action
// returns { available: false } and the frontend falls back to Open-Meteo):
//   WEATHERKIT_TEAM_ID     - Apple Developer Team ID
//   WEATHERKIT_SERVICE_ID  - the App ID / bundle id with WeatherKit enabled
//   WEATHERKIT_KEY_ID      - Key ID of the WeatherKit-enabled key
//   WEATHERKIT_PRIVATE_KEY - full contents of the downloaded .p8 file

const WX_TZ = 'America/New_York';
const weatherCache = new Map<string, { at: number; payload: unknown }>();
const WEATHER_CACHE_MS = 30 * 60 * 1000;

function b64url(data: Uint8Array | string): string {
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data;
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function weatherKitJWT(teamId: string, serviceId: string, keyId: string, privateKeyPem: string): Promise<string> {
  const pem = privateKeyPem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: keyId, id: `${teamId}.${serviceId}` }));
  const payload = b64url(JSON.stringify({ iss: teamId, sub: serviceId, iat: now, exp: now + 3600 }));
  const signingInput = `${header}.${payload}`;
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(signingInput));
  return `${signingInput}.${b64url(new Uint8Array(sig))}`;
}

// WeatherKit conditionCode -> WMO code (what the frontend's icons/advisory
// logic keys off). Coarse but faithful buckets.
const CONDITION_TO_WMO: Record<string, number> = {
  Clear: 0, MostlyClear: 1, PartlyCloudy: 2, MostlyCloudy: 3, Cloudy: 3,
  Foggy: 45, Haze: 45, Smoky: 45, BlowingDust: 45,
  Breezy: 1, Windy: 2, Frigid: 0, Hot: 0,
  Drizzle: 51, FreezingDrizzle: 51, SunShowers: 80,
  Rain: 61, FreezingRain: 63, HeavyRain: 65, Hail: 65,
  Flurries: 71, SunFlurries: 71, Snow: 71, Sleet: 71, WintryMix: 71,
  BlowingSnow: 73, HeavySnow: 75,
  IsolatedThunderstorms: 95, ScatteredThunderstorms: 95, Thunderstorm: 95,
  Thunderstorms: 95, SevereThunderstorm: 95, StrongStorms: 95,
  TropicalStorm: 95, Hurricane: 95,
};
const wmoOf = (c: string | undefined) => (c && c in CONDITION_TO_WMO ? CONDITION_TO_WMO[c] : 3);

// Local wall-clock formatting: the frontend string-matches dates/hours
// (e.g. hourly.time.startsWith(dayStr)) exactly like Open-Meteo's
// timezone-localized output, so timestamps must be NY wall-clock, not UTC.
function localParts(iso: string): { date: string; time: string; hour: number } {
  const d = new Date(iso);
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: WX_TZ, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  });
  const parts: Record<string, string> = {};
  for (const p of fmt.formatToParts(d)) parts[p.type] = p.value;
  const hour = parseInt(parts.hour, 10) % 24; // en-CA can emit "24" for midnight
  const hh = String(hour).padStart(2, '0');
  const date = `${parts.year}-${parts.month}-${parts.day}`;
  return { date, time: `${date}T${hh}:${parts.minute}`, hour };
}

const cToF = (c: number | undefined | null) => (c == null ? null : Math.round((c * 9 / 5 + 32) * 10) / 10);
const kmhToMs = (k: number | undefined | null) => (k == null ? null : Math.round((k / 3.6) * 100) / 100);

function transformWeatherKit(wk: any) {
  const days = (wk.forecastDaily?.days || []).slice(0, 7);
  const hours = wk.forecastHourly?.hours || [];

  const hourly = {
    time: [] as string[], temperature_2m: [] as (number | null)[], apparent_temperature: [] as (number | null)[],
    weathercode: [] as number[], windspeed_10m: [] as (number | null)[], winddirection_10m: [] as (number | null)[],
    precipitation_probability: [] as number[], precipitation: [] as number[],
  };
  // Per-local-day wind stats derived from hourly data, since WeatherKit's
  // day objects don't carry a dominant wind direction at the top level.
  const windByDay: Record<string, { max: number; dirAtMax: number }> = {};
  for (const h of hours) {
    const lp = localParts(h.forecastStart);
    hourly.time.push(lp.time);
    hourly.temperature_2m.push(cToF(h.temperature));
    hourly.apparent_temperature.push(cToF(h.temperatureApparent));
    hourly.weathercode.push(wmoOf(h.conditionCode));
    const ms = kmhToMs(h.windSpeed);
    hourly.windspeed_10m.push(ms);
    hourly.winddirection_10m.push(h.windDirection ?? null);
    hourly.precipitation_probability.push(Math.round((h.precipitationChance ?? 0) * 100));
    hourly.precipitation.push(h.precipitationIntensity ?? h.precipitationAmount ?? 0);
    if (ms != null) {
      const w = windByDay[lp.date];
      if (!w || ms > w.max) windByDay[lp.date] = { max: ms, dirAtMax: h.windDirection ?? 0 };
    }
  }

  const daily = {
    time: [] as string[], weathercode: [] as number[],
    temperature_2m_max: [] as (number | null)[], temperature_2m_min: [] as (number | null)[],
    windspeed_10m_max: [] as number[], winddirection_10m_dominant: [] as number[],
    precipitation_sum: [] as number[], precipitation_probability_max: [] as number[],
  };
  for (const day of days) {
    const lp = localParts(day.forecastStart);
    daily.time.push(lp.date);
    daily.weathercode.push(wmoOf(day.conditionCode));
    daily.temperature_2m_max.push(cToF(day.temperatureMax));
    daily.temperature_2m_min.push(cToF(day.temperatureMin));
    const wind = windByDay[lp.date];
    const dayFallbackWind = kmhToMs(day.daytimeForecast?.windSpeed) ?? 0;
    daily.windspeed_10m_max.push(wind ? wind.max : dayFallbackWind);
    daily.winddirection_10m_dominant.push(wind ? wind.dirAtMax : (day.daytimeForecast?.windDirection ?? 0));
    daily.precipitation_sum.push(day.precipitationAmount ?? 0);
    daily.precipitation_probability_max.push(Math.round((day.precipitationChance ?? 0) * 100));
  }

  return { daily, hourly, _source: 'weatherkit' };
}

async function getWeather(body: any): Promise<Response> {
  const teamId = Deno.env.get('WEATHERKIT_TEAM_ID');
  const serviceId = Deno.env.get('WEATHERKIT_SERVICE_ID');
  const keyId = Deno.env.get('WEATHERKIT_KEY_ID');
  const privateKey = Deno.env.get('WEATHERKIT_PRIVATE_KEY');
  if (!teamId || !serviceId || !keyId || !privateKey) return json({ available: false });

  const lat = Number(body.lat), lon = Number(body.lon);
  if (!isFinite(lat) || !isFinite(lon)) return badRequest('Missing lat/lon');

  const cacheKey = lat.toFixed(2) + ',' + lon.toFixed(2);
  const cached = weatherCache.get(cacheKey);
  if (cached && Date.now() - cached.at < WEATHER_CACHE_MS) return json({ weather: cached.payload });

  const token = await weatherKitJWT(teamId, serviceId, keyId, privateKey);
  const hourlyEnd = new Date(Date.now() + 7 * 24 * 3600 * 1000).toISOString();
  const url = `https://weatherkit.apple.com/api/v1/weather/en/${lat}/${lon}` +
    `?dataSets=forecastDaily,forecastHourly&timezone=${encodeURIComponent(WX_TZ)}` +
    `&countryCode=US&hourlyEnd=${encodeURIComponent(hourlyEnd)}`;
  const resp = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!resp.ok) {
    const text = await resp.text().catch(() => '');
    console.error('WeatherKit error', resp.status, text.slice(0, 300));
    return json({ available: false, error: 'WeatherKit returned ' + resp.status });
  }
  const wk = await resp.json();
  const payload = transformWeatherKit(wk);
  weatherCache.set(cacheKey, { at: Date.now(), payload });
  return json({ weather: payload });
}

// ---------- MapKit JS token ----------
// Apple Maps in the browser. The page can't hold the signing key, so it
// asks for a short-lived JWT here and hands it to mapkit.init()'s
// authorizationCallback. Claims differ from WeatherKit's: MapKit uses no
// `sub`, and instead scopes the token to an `origin` so a leaked token
// can't be replayed from another site.
//
// Secrets (until all three exist this returns { available: false } and the
// frontend keeps using its existing map):
//   MAPKIT_TEAM_ID, MAPKIT_KEY_ID, MAPKIT_PRIVATE_KEY
//   MAPKIT_ORIGIN - optional, e.g. https://palmares-gilt.vercel.app

const MAPKIT_TOKEN_TTL_SEC = 30 * 60;
let mapsTokenCache: { token: string; exp: number } | null = null;

async function getMapsToken(): Promise<Response> {
  const teamId = Deno.env.get('MAPKIT_TEAM_ID');
  const keyId = Deno.env.get('MAPKIT_KEY_ID');
  const privateKeyPem = Deno.env.get('MAPKIT_PRIVATE_KEY');
  const origin = Deno.env.get('MAPKIT_ORIGIN');
  if (!teamId || !keyId || !privateKeyPem) return json({ available: false });

  const now = Math.floor(Date.now() / 1000);
  // Reuse until it's within a minute of expiry - mapkit re-requests often.
  if (mapsTokenCache && mapsTokenCache.exp - 60 > now) {
    return json({ token: mapsTokenCache.token, expiresAt: mapsTokenCache.exp });
  }

  const pem = privateKeyPem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);

  const exp = now + MAPKIT_TOKEN_TTL_SEC;
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }));
  const claims: Record<string, unknown> = { iss: teamId, iat: now, exp };
  if (origin) claims.origin = origin;
  const payload = b64url(JSON.stringify(claims));
  const signingInput = `${header}.${payload}`;
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(signingInput));
  const token = `${signingInput}.${b64url(new Uint8Array(sig))}`;

  mapsTokenCache = { token, exp };
  return json({ token, expiresAt: exp });
}

// ---------- Community road-work reports ----------
// Shared across all athletes: anyone can report a road being milled,
// repaved, or freshly finished, and everyone's dashboard shows the same
// feed. No per-athlete filtering by design.

async function listRoadReports(): Promise<Response> {
  // Was 30. Confirmations are rows too, so a single road could consume the
  // whole window: one rider tapped confirm 27 times on Kohr Road, which with
  // three other rows filled the limit exactly and pushed every original report
  // out of the feed. The client has a fallback for a group with no primary
  // report, but the real fix is a window that a busy road cannot exhaust.
  // These rows are tiny and infrequent; 500 is not a meaningful payload.
  const { data, error } = await supabase
    .from('road_reports')
    .select('*')
    .order('created_at', { ascending: false })
    .limit(500);
  if (error) throw error;
  return json({ reports: data || [] });
}

async function addRoadReport(body: any): Promise<Response> {
  const { road_name, town, status, note, reported_by, athlete_id } = body;
  if (!road_name || typeof road_name !== 'string' || !road_name.trim()) return badRequest('Missing road_name');
  if (!['milled', 'repaving', 'fresh'].includes(status)) return badRequest('status must be milled, repaving, or fresh');

  const cleanName = String(road_name).trim().slice(0, 120);
  const cleanNote = note ? String(note).trim().slice(0, 300) : null;

  // One confirmation per athlete per road, enforced here rather than trusting
  // the client. The board already de-duplicates confirmers for display, but the
  // ROWS still accumulated: 27 identical taps from one rider were all stored,
  // and rows are what the feed window is spent on.
  //
  // Scoped to confirmations made since the road's newest original report, so a
  // rider can confirm again after someone re-reports the road - that is a new
  // statement about a new report, not a repeat of the old one.
  if (cleanNote === '[confirm]' && typeof athlete_id === 'number') {
    // An original report is one WITHOUT a [tag] note - not one with a null
    // note. The seeded reports carry real text ("Just repaved - new tarmac."),
    // so matching on null found nothing, pinned `since` to 1970, and would have
    // blocked a rider from ever confirming a road again once they had confirmed
    // it a single time - including after someone re-reported it.
    const { data: recent } = await supabase
      .from('road_reports')
      .select('created_at, note')
      .eq('road_name', cleanName)
      .order('created_at', { ascending: false })
      .limit(200);
    const isTag = (n: string | null) => !!n && /^\[(confirm|cleared)\]$/i.test(n.trim());
    const newestPrimary = (recent || []).find((r: any) => !isTag(r.note));
    const since = newestPrimary ? newestPrimary.created_at : '1970-01-01T00:00:00Z';
    const { data: mine } = await supabase
      .from('road_reports')
      .select('id, created_at')
      .eq('road_name', cleanName)
      .eq('athlete_id', athlete_id)
      .eq('note', '[confirm]')
      .gte('created_at', since)
      .limit(1);
    if (mine && mine.length) return json({ report: mine[0], duplicate: true });
  }

  const { data, error } = await supabase.from('road_reports').insert({
    road_name: cleanName,
    town: town ? String(town).trim().slice(0, 80) : null,
    status,
    note: cleanNote,
    reported_by: reported_by ? String(reported_by).trim().slice(0, 80) : null,
    athlete_id: typeof athlete_id === 'number' ? athlete_id : null,
  }).select().single();
  if (error) throw error;
  return json({ report: data });
}

async function disconnect(body: any): Promise<Response> {
  const { session_id } = body;
  if (!session_id) return badRequest('Missing session_id');

  const { data: row } = await supabase
    .from('athletes')
    .select('access_token')
    .eq('id', session_id)
    .maybeSingle();

  if (row?.access_token) {
    try {
      await fetch('https://www.strava.com/oauth/deauthorize?access_token=' + encodeURIComponent(row.access_token), {
        method: 'POST',
      });
    } catch (e) {
      console.log('Strava deauthorize call failed (continuing):', e);
    }
  }

  // Clear tokens rather than deleting the row: power_prs has a foreign key on
  // athletes.strava_id, and the row also holds ftp/weight_kg history that
  // should survive a disconnect. Empty string (not null) so this update works
  // regardless of whether the columns are NOT NULL.
  const { error } = await supabase.from('athletes').update({
    access_token: '',
    refresh_token: '',
    token_expires_at: 0,
    updated_at: new Date().toISOString(),
  }).eq('id', session_id);
  if (error) throw error;
  return json({ ok: true });
}
