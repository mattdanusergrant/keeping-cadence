# Keeping Cadence

A weekly schedule app for groups of people. Plot each person's hours on a shared
timeline, log actual hours worked, and share read-only views with anyone on the
schedule.

Live at: https://mattdanusergrant.github.io/keeping-cadence/

## Shape

- **Front-end** — a single self-contained `index.html` (HTML + CSS + vanilla JS,
  no build step). Works fully offline using `localStorage` + URL-hash share
  links. Hosted as a static page on GitHub Pages.
- **Backend (optional)** — a Neon Postgres database behind a small serverless
  API (`/api`, deployed on Vercel) that adds accounts, cross-device sync, share
  links by slug, and Stripe subscriptions. The browser never connects to Neon
  directly — only the API does. Cloud features are **off by default**; the app
  is unchanged until you enable them. See **[BACKEND.md](BACKEND.md)**.
