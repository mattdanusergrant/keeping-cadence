// Keeping Cadence — Neon Auth same-origin proxy (Cloudflare Worker)
// ===================================================================
// WHY THIS EXISTS
// Neon Auth's session is an HttpOnly cookie set by the Neon endpoint
// (ep-tiny-sun-a6wesvb9.neonauth.us-west-2.aws.neon.tech). Talking to that host
// directly makes the cookie cross-site to app.keepingcadence.com, so Safari ITP /
// Firefox ETP / iOS drop it on refresh (a same-site SUBDOMAIN cookie wasn't enough
// either — iOS won't persist a cookie for a host the user never visited top-level).
//
// Fix: proxy auth through the app's OWN origin so the cookie is same-origin:
//
//   app.keepingcadence.com/__neonauth/*
//     -> (vercel.json rewrite) -> https://auth.keepingcadence.com/neondb/auth/*
//     -> (this Worker) -> Neon Auth
//
// The session cookie therefore lands on app.keepingcadence.com itself, which every
// browser keeps. (The Data API stays on neon.tech — it uses the bearer JWT, no cookie.)
//
// DEPLOYMENT
//   - Cloudflare Worker "keepingcadence", custom domain auth.keepingcadence.com
//     (zone keepingcadence.com — must be in the same CF account as the Worker).
//   - vercel.json rewrites /__neonauth/:path* -> https://auth.keepingcadence.com/neondb/auth/:path*
//   - app.html: CLOUD.authBase = 'https://app.keepingcadence.com/__neonauth'
//
// TRANSFORMS (the non-obvious bits, each learned the hard way)
//   - delete `host`            : let CF set the correct upstream Host for Neon.
//   - delete `x-forwarded-host`: Vercel adds it; Neon rejects it -> INVALID_HOSTNAME.
//   - strip `Partitioned`      : not needed once first-party; keep the cookie plain.
//   - SameSite=None -> Lax     : correct for a first-party cookie; ITP-friendly.

const UPSTREAM = 'https://ep-tiny-sun-a6wesvb9.neonauth.us-west-2.aws.neon.tech';

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const headers = new Headers(request.headers);
    headers.delete('host');
    headers.delete('x-forwarded-host');
    const r = await fetch(UPSTREAM + url.pathname + url.search, {
      method: request.method,
      headers,
      body: ['GET', 'HEAD'].includes(request.method) ? undefined : request.body,
      redirect: 'manual',
    });
    const out = new Headers(r.headers);
    const cookies = r.headers.getSetCookie?.() ?? [];
    if (cookies.length) {
      out.delete('set-cookie');
      for (const c of cookies) {
        out.append('set-cookie',
          c.replace(/;\s*Partitioned/gi, '').replace(/SameSite=None/gi, 'SameSite=Lax'));
      }
    }
    return new Response(r.body, { status: r.status, statusText: r.statusText, headers: out });
  },
};
