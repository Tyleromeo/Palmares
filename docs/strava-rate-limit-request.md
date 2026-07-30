# Asking Strava for a higher rate limit

## Where to send it

1. **Check the current process first** at [developers.strava.com](https://developers.strava.com)
   and on your app's page at [strava.com/settings/api](https://www.strava.com/settings/api).
   Strava has moved this between a form, an email address and a community
   forum over the years, so trust what the portal says today over anything
   written here.
2. Historically the channel has been **developers@strava.com**, with the
   developer community forum as the fallback for slow replies.
3. Have your **Client ID** ready (it's on the API settings page). Never send
   the client secret.

## What they actually want to know

Strava's first question is whether you're wasteful with calls. Most requests
are refused because the app hammers the API on every page load. Palmarès
doesn't, and that's the case to make — with specifics, not adjectives.

## Draft

> Subject: Rate limit increase request — Palmarès (Client ID: <your id>)
>
> Hello,
>
> I'm the developer of Palmarès, an iOS app and website that gives cyclists and
> runners a deeper view of their own Strava history — KOM and Top-10 records,
> power curve analysis, a fitness-age estimate, and a map that ranks segments
> by forecast tailwind.
>
> I'm requesting an increase above the default 100 requests / 15 minutes and
> 1,000 / day. Those limits are per application rather than per athlete, so
> they cap total users rather than heavy ones.
>
> **How the app limits its own usage.** Athlete data is fetched once and cached
> server-side (Supabase), so a returning athlete costs 2–3 calls rather than a
> full history pull:
>
> - Activity history is stored server-side after the first load. Normal loads
>   read from that cache and query Strava only for activities newer than the
>   most recent cached one — typically a single 12-item request.
> - A full history re-fetch happens only on first connect, or when the athlete
>   explicitly asks for one.
> - Activity geometry, sport types and segment scan progress are cached for a
>   year; enriched segment details for a week; route geometry permanently,
>   since a route's shape never changes.
> - Club events are cached for 20 minutes.
> - Segment scans are chunked and resumable, so they never burst.
>
> **Current usage.** <N> athletes, roughly <X> requests/day at peak. <If you
> have hit the limit, say when and what happened.>
>
> **What I expect to need.** <Requests/day at your target user count, and how
> you got there — e.g. "~15 calls per active athlete per day × 500 athletes".>
>
> **Commercial intent.** <State it plainly: free today; considering a paid tier
> for X. Ask directly whether that changes anything, rather than leaving it to
> be discovered later.>
>
> Happy to walk through the caching in more detail or make changes if any usage
> pattern concerns you.
>
> Thanks,
> Kamil Dobrowolski

## Before you send

- **Get real numbers.** "<N> athletes, <X> requests/day" carries the request;
  vague growth talk doesn't. Instrument first if you don't know.
- **Ask about commercial use in the same message.** It's the same team, and
  finding out after you've built a paid tier is worse.
- **Mention the road reports feature** if you keep it as is: it shows one
  athlete's name to other athletes, which their agreement is stricter about
  than an athlete seeing their own data. Better to raise it than have it
  found.
