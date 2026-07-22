# Finishing the WeatherKit cutover

The frontend is already done: `loadWeather()` in `index.html` asks the Edge
Function (`get_weather`) first and falls back to Open-Meteo, and the deployed
function currently answers `{ "available": false }` — the exact "secrets not
configured yet" state the code anticipates. Apple attribution is already
rendered when the source is WeatherKit. **No frontend change is needed at
any point in this document.**

What remains is credential work in two dashboards, which only you can do.

## 1. Apple Developer portal (~10 minutes)

WeatherKit REST auth is a JWT signed with a key you create once:

1. **Certificates, Identifiers & Profiles → Identifiers → +** →
   *Services IDs*. Create one, e.g. `com.palmares.weatherkit`. This becomes
   `WEATHERKIT_SERVICE_ID`.
2. Edit the new Service ID and enable the **WeatherKit** capability
   (App IDs with WeatherKit enabled also work, but a dedicated Services ID
   keeps it clean).
3. **Keys → +**. Name it, check **WeatherKit**, create, and **download the
   `.p8` file — Apple lets you download it exactly once.** Note the
   **Key ID** (10 characters) shown on that page → `WEATHERKIT_KEY_ID`.
4. Your **Team ID** is in Membership details → `WEATHERKIT_TEAM_ID`.

Keep the `.p8` out of the repo — this is a public site; anything committed
here is world-readable. It goes only into Supabase secrets in the next step.

## 2. Supabase secrets

With the [Supabase CLI](https://supabase.com/docs/guides/cli) logged in and
linked to project `chvrtqrjnatjftqzvgbv`:

```sh
supabase secrets set \
  WEATHERKIT_TEAM_ID=XXXXXXXXXX \
  WEATHERKIT_SERVICE_ID=com.palmares.weatherkit \
  WEATHERKIT_KEY_ID=YYYYYYYYYY \
  WEATHERKIT_PRIVATE_KEY="$(cat /path/to/AuthKey_YYYYYYYYYY.p8)"
```

(Or paste the four values in the dashboard: Project → Edge Functions →
Secrets. The private key is multi-line; paste it verbatim, header and
footer lines included.)

## 3. Server code

The deployed `sync-strava` function already routes `get_weather` (it answers
`{"available": false}`, not an unknown-action error). If its WeatherKit path
is complete, setting the secrets is the whole job. If it turns out to be a
stub, `docs/get_weather-reference.ts` in this repo is a drop-in handler:
JWT signing via the WebCrypto API, the WeatherKit fetch, and the reshape
into the Open-Meteo format the frontend consumes (including °F and the
WMO-style weather codes `wxDesc`/`wxIcon` expect). Redeploy after merging:

```sh
supabase functions deploy sync-strava
```

## 4. Verify

```sh
curl -s -X POST "https://chvrtqrjnatjftqzvgbv.supabase.co/functions/v1/sync-strava" \
  -H "Content-Type: application/json" \
  -H "apikey: <SUPABASE_ANON_KEY from index.html>" \
  -H "Authorization: Bearer <same anon key>" \
  -d '{"action":"get_weather","lat":40.86,"lon":-73.2}'
```

- Still `{"available":false}` → secrets not visible to the function
  (re-deploy after setting them; secrets only apply to new deployments).
- `{"weather":{...,"daily":{...}}}` → done. Reload the site: the Today card
  footer switches from "Forecast by Open-Meteo" to " Apple Weather" with
  the attribution link, confirming the cutover end-to-end.

## Notes

- WeatherKit includes 500,000 calls/month with the developer membership.
  One user hitting a cached Edge Function will not approach this.
- Consider caching the WeatherKit response server-side for ~15 minutes
  (the reference handler does) so repeated page loads don't burn calls.
- If Apple returns 401s: the usual culprits are a Service ID without the
  WeatherKit capability enabled, or a `.p8` pasted with mangled newlines.
