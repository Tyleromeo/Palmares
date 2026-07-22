# Enabling external ride calendars: the `fetch_url` Edge Function action

The events card can merge ride listings from outside websites (Settings ›
Group events — e.g. the SBRA upcoming-rides page, or any `.ics` calendar
feed). Browsers cannot fetch those sites directly: none of them send CORS
headers, so the request must go through the Edge Function.

Public CORS proxies were tested and rejected: allorigins and codetabs both
returned 522s for sbraweb.org (its host times out datacenter-range IPs),
and corsproxy.io now 403s unregistered origins. A first-party proxy is the
only dependable path — and it's ~40 lines.

The frontend already calls `callEdge('fetch_url', { url })` and degrades
gracefully until the action exists (sources render as outbound links with a
note). Once deployed, inline events appear with no frontend change.

## Deploying

The `sync-strava` function source may not exist locally — pull the deployed
copy first:

```sh
supabase functions download sync-strava
```

Then add the handler below, wire it into the action switch, and:

```sh
supabase functions deploy sync-strava
```

## Reference handler (Deno)

```ts
// In the action dispatch:
//   case "fetch_url": return json(await handleFetchUrl(body.url));

const FETCH_MAX_BYTES = 512 * 1024;   // ride pages are small; cap defensively
const fetchCache = new Map<string, { at: number; body: string }>();
const FETCH_CACHE_MS = 15 * 60 * 1000;

async function handleFetchUrl(url: unknown): Promise<{ body?: string; error?: string }> {
  if (typeof url !== "string") return { error: "url required" };

  // SSRF guard: only plain http(s) to public hosts. Never let a caller
  // point this at localhost, cloud metadata, or private ranges.
  let parsed: URL;
  try { parsed = new URL(url); } catch { return { error: "invalid url" }; }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return { error: "http(s) only" };
  const host = parsed.hostname;
  if (
    host === "localhost" || host.endsWith(".local") || host.endsWith(".internal") ||
    /^(\d{1,3}\.){3}\d{1,3}$/.test(host) ||       // raw IPv4 (covers 10/172/192/169.254/127)
    host.includes(":")                            // raw IPv6
  ) return { error: "host not allowed" };

  const cached = fetchCache.get(url);
  if (cached && Date.now() - cached.at < FETCH_CACHE_MS) return { body: cached.body };

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 15_000);
  try {
    const resp = await fetch(url, {
      signal: ctrl.signal,
      redirect: "follow",
      headers: { "User-Agent": "Palmares/1.0 (ride calendar sync)" },
    });
    if (!resp.ok) return { error: `upstream ${resp.status}` };
    const text = await resp.text();
    const body = text.length > FETCH_MAX_BYTES ? text.slice(0, FETCH_MAX_BYTES) : text;
    fetchCache.set(url, { at: Date.now(), body });
    return { body };
  } catch (e) {
    return { error: e instanceof Error ? e.message : "fetch failed" };
  } finally {
    clearTimeout(timer);
  }
}
```

Notes:

- The isolate-level cache is best effort; the frontend also caches parsed
  events for 6 hours per source in localStorage, so upstream sites see at
  most a few requests a day per user.
- Redirect chains are followed; the SSRF check only covers the initial URL.
  If that ever matters, re-validate `resp.url` after the fetch.
- The frontend parses two shapes: proper `.ics` feeds, and plain HTML ride
  listings via date-pattern extraction (`MM/DD/YYYY - H:MMam`), tuned to
  the SBRA/Drupal format.

## Verify

```sh
curl -s -X POST "https://chvrtqrjnatjftqzvgbv.supabase.co/functions/v1/sync-strava" \
  -H "Content-Type: application/json" \
  -H "apikey: <anon key>" -H "Authorization: Bearer <anon key>" \
  -d '{"action":"fetch_url","url":"https://www.sbraweb.org/upcoming_rides?q=upcoming_rides_a"}' | head -c 300
```

A JSON `{"body":"<!DOCTYPE html..."}` means it works; reload the site and
the configured calendars' rides appear inline in Upcoming group events.
