// Reference implementation of the `get_weather` action for the sync-strava
// Supabase Edge Function (Deno). Only needed if the deployed function's
// WeatherKit path is a stub — see docs/weatherkit-setup.md.
//
// Contract (what index.html's loadWeather() expects):
//   input  { action: "get_weather", lat, lon }
//   output { weather: <Open-Meteo-shaped object with _source: "weatherkit"> }
//          or { available: false } when secrets are unset or Apple errors.
//
// The reshape matters more than the fetch: the frontend consumes Open-Meteo
// field names/units exactly (°F, wind in m/s, WMO weather codes), so this
// converts all three. Fields consumed by the page:
//   daily:  time, weathercode, temperature_2m_max/min, windspeed_10m_max,
//           winddirection_10m_dominant, precipitation_probability_max
//   hourly: time, temperature_2m, apparent_temperature, weathercode,
//           windspeed_10m, winddirection_10m, precipitation_probability,
//           precipitation

const WK_TEAM_ID = Deno.env.get("WEATHERKIT_TEAM_ID") ?? "";
const WK_SERVICE_ID = Deno.env.get("WEATHERKIT_SERVICE_ID") ?? "";
const WK_KEY_ID = Deno.env.get("WEATHERKIT_KEY_ID") ?? "";
const WK_PRIVATE_KEY = Deno.env.get("WEATHERKIT_PRIVATE_KEY") ?? "";

// 15-minute in-memory cache so repeated page loads don't burn WeatherKit
// calls. Edge isolates recycle, so this is best-effort — which is fine.
let wxCache: { key: string; at: number; payload: unknown } | null = null;
const WX_CACHE_MS = 15 * 60 * 1000;

export async function handleGetWeather(lat: number, lon: number) {
  if (!WK_TEAM_ID || !WK_SERVICE_ID || !WK_KEY_ID || !WK_PRIVATE_KEY) {
    return { available: false };
  }

  const cacheKey = `${lat.toFixed(2)},${lon.toFixed(2)}`;
  if (wxCache && wxCache.key === cacheKey && Date.now() - wxCache.at < WX_CACHE_MS) {
    return wxCache.payload;
  }

  try {
    const token = await weatherKitJWT();
    const url =
      `https://weatherkit.apple.com/api/v1/weather/en/${lat}/${lon}` +
      `?dataSets=forecastDaily,forecastHourly&timezone=America/New_York&countryCode=US`;
    const resp = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    if (!resp.ok) {
      console.error("WeatherKit HTTP", resp.status, await resp.text());
      return { available: false };
    }
    const wk = await resp.json();
    const payload = { weather: reshape(wk) };
    wxCache = { key: cacheKey, at: Date.now(), payload };
    return payload;
  } catch (e) {
    console.error("WeatherKit error:", e);
    return { available: false };
  }
}

// ---- JWT (ES256, WebCrypto) ----

async function weatherKitJWT(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: WK_KEY_ID, id: `${WK_TEAM_ID}.${WK_SERVICE_ID}` };
  const claims = { iss: WK_TEAM_ID, sub: WK_SERVICE_ID, iat: now, exp: now + 3600 };

  const b64url = (data: Uint8Array | string) => {
    const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
    return btoa(String.fromCharCode(...bytes))
      .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
  };

  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;

  // .p8 is PEM-wrapped PKCS8
  const pem = WK_PRIVATE_KEY
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));

  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput),
  ));
  return `${signingInput}.${b64url(sig)}`;
}

// ---- Reshape WeatherKit -> Open-Meteo ----

const cToF = (c: number) => c * 9 / 5 + 32;
const kmhToMs = (k: number) => k / 3.6;

// WeatherKit conditionCode -> nearest WMO code (what wxDesc/wxIcon consume).
const WMO: Record<string, number> = {
  Clear: 0, MostlyClear: 1, PartlyCloudy: 2, MostlyCloudy: 3, Cloudy: 3,
  Foggy: 45, Haze: 45, Smoky: 45, Breezy: 1, Windy: 1,
  Drizzle: 51, FreezingDrizzle: 56,
  Rain: 63, HeavyRain: 65, SunShowers: 61, FreezingRain: 66,
  Sleet: 66, WintryMix: 66, Hail: 66,
  Flurries: 71, Snow: 73, HeavySnow: 75, SunFlurries: 71, Blizzard: 75, BlowingSnow: 75,
  IsolatedThunderstorms: 95, ScatteredThunderstorms: 95, Thunderstorms: 95,
  StrongStorms: 95, SevereThunderstorm: 95, Hurricane: 95, TropicalStorm: 95,
};
const wmo = (cc: string) => WMO[cc] ?? 3;

function reshape(wk: any) {
  const days: any[] = wk.forecastDaily?.days ?? [];
  const hours: any[] = wk.forecastHourly?.hours ?? [];

  return {
    _source: "weatherkit",
    daily: {
      time: days.map((d) => (d.forecastStart ?? "").slice(0, 10)),
      weathercode: days.map((d) => wmo(d.conditionCode)),
      temperature_2m_max: days.map((d) => cToF(d.temperatureMax)),
      temperature_2m_min: days.map((d) => cToF(d.temperatureMin)),
      // WeatherKit only gives daytime/overnight wind means; take the max of
      // the two as the daily max — slightly conservative, close enough for
      // the ride advisory thresholds.
      windspeed_10m_max: days.map((d) =>
        kmhToMs(Math.max(
          d.daytimeForecast?.windSpeedMax ?? d.daytimeForecast?.windSpeed ?? 0,
          d.overnightForecast?.windSpeedMax ?? d.overnightForecast?.windSpeed ?? 0,
          d.windSpeedMax ?? 0,
        ))),
      winddirection_10m_dominant: days.map((d) =>
        d.daytimeForecast?.windDirection ?? d.windDirection ?? 0),
      precipitation_sum: days.map((d) =>
        (d.precipitationAmount ?? 0) / 25.4), // mm -> inches, matching imperial display
      precipitation_probability_max: days.map((d) =>
        Math.round((d.precipitationChance ?? 0) * 100)),
    },
    hourly: {
      // Keep the full UTC timestamp, Z included. Open-Meteo returns
      // timezone-naive local strings, but WeatherKit's forecastStart is
      // UTC - trimming the Z off it would make the browser read 19:00Z as
      // 7pm local instead of 3pm EDT, and the dashboard's "next few hours"
      // strip would show the wrong hours. With the Z intact, `new Date()`
      // parses it as UTC and renders in the viewer's own timezone.
      time: hours.map((h) => h.forecastStart ?? ""),
      temperature_2m: hours.map((h) => cToF(h.temperature)),
      apparent_temperature: hours.map((h) => cToF(h.temperatureApparent ?? h.temperature)),
      weathercode: hours.map((h) => wmo(h.conditionCode)),
      windspeed_10m: hours.map((h) => kmhToMs(h.windSpeed ?? 0)),
      winddirection_10m: hours.map((h) => h.windDirection ?? 0),
      precipitation_probability: hours.map((h) =>
        Math.round((h.precipitationChance ?? 0) * 100)),
      precipitation: hours.map((h) => (h.precipitationAmount ?? 0) / 25.4),
    },
  };
}
