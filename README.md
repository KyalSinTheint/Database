# Training Record Database Portal

Static single-page app (`index.html`) backed by Supabase. No backend server needed.

## Setup

1. Create a Supabase project. In **SQL Editor**, run `supabase/schema.sql`.
2. In **Project Settings → API**, copy the Project URL and the `anon public` key.
3. In `index.html`, set `SUPABASE_URL` and `SUPABASE_ANON_KEY` (near the top of the main `<script>`).
4. Commit and push. Vercel redeploys automatically.

## Deploy on Vercel

1. vercel.com → **Add New… → Project** → import this GitHub repository.
2. Framework Preset: **Other**. Leave Build Command and Output Directory empty.
3. Click **Deploy**.

## Security

The anon key is public by design. With the default policies in `schema.sql`, anyone who
has the site URL can read and edit all records (including NRC numbers). Add Supabase Auth
and switch the policies to `to authenticated` before sharing the URL widely.
