#!/usr/bin/env bash
# Assemble and deploy heygilli.com.
#
# The site is two things on one origin:
#
#   /              the public page — what HeyGilli is, plus privacy and terms.
#                  Static HTML, readable without JavaScript. Google's OAuth
#                  verification fetches this and has to find real prose; a
#                  Flutter shell renders as an empty page to a crawler, which
#                  reads as "homepage is behind a login page".
#   /app/          the Flutter app itself, built with a matching --base-href.
#
# Same origin either way, so the OAuth JavaScript origin covers both.
set -euo pipefail

cd "$(dirname "$0")"
# If a custom CLOUDFLARE_API_TOKEN is set in the parent shell with insufficient
# scopes, unsetting it allows wrangler to use the valid OAuth credentials in default.toml.
unset CLOUDFLARE_API_TOKEN 2>/dev/null || true
CID="$(sed -n 's/^GOOGLE_CLIENT_ID=//p' agents/.env | tail -1 | tr -d '"'"'"' \r')"
[ -n "$CID" ] || { echo "no GOOGLE_CLIENT_ID in agents/.env"; exit 1; }

echo "==> building Flutter web for /app/"
# No service worker. Flutter's default one caches the whole bundle and hands
# it to the page that is already open, picking a new build up only on some
# later load — so a parent who had the app open when a deploy landed kept
# being served the previous UI, and so did the person testing it, and neither
# of them had any way to tell that was what they were looking at. Nothing here
# works offline anyway: without the gateway there are no videos, no screening
# and no sign-in.
(cd app && flutter build web --release --pwa-strategy=none \
  --base-href=/app/ \
  --dart-define=HEYGILLI_API_URL=https://heygilli-gateway.onrender.com \
  --dart-define=HEYGILLI_GOOGLE_SERVER_CLIENT_ID="$CID")

DIST=build/site
rm -rf "$DIST"
mkdir -p "$DIST/app" "$DIST/assets/assets"

# Structured data is a copy of the FAQ a few hundred lines below it in the
# same file. A copy is only true while something checks: a stale schema serves
# old wording to Google and to every model that reads the page, which is worse
# than no schema — a confident wrong answer with a site behind it.
echo "==> checking SEO/AEO"
python3 app/web/check_seo.py

echo "==> assembling $DIST"
cp app/web/about.html   "$DIST/index.html"     # root is the public page
cp app/web/about.html   "$DIST/about.html"     # and reachable by name too
cp app/web/privacy.html "$DIST/"
cp app/web/terms.html   "$DIST/"
cp app/web/try.html     "$DIST/"     # /try — the screening demo, its own page
cp app/web/faq.html     "$DIST/"     # /faq — carries the FAQPage schema, and only it does
cp app/web/site.css     "$DIST/"     # shared by the three pages above
# Findable, and quotable by the answer engines people actually ask. og.png is
# the link preview; llms.txt is the plain-text summary for models, which the
# rendered page cannot be — /app/ is a canvas an LLM reads as nothing.
cp app/web/robots.txt   "$DIST/"
cp app/web/sitemap.xml  "$DIST/"
cp app/web/llms.txt     "$DIST/"
cp app/web/og.png       "$DIST/"
cp app/web/favicon.png  "$DIST/"
cp app/assets/gilli.svg "$DIST/assets/assets/gilli.svg"
cp -R app/build/web/.   "$DIST/app/"

# Cache headers, rewritten for the /app/ prefix: Flutter reuses the same
# filenames every build, so without this a browser can sit on a stale bundle.
cat > "$DIST/_headers" << 'HDR'
/index.html
  Cache-Control: no-cache
/app/index.html
  Cache-Control: no-cache
/app/main.dart.js
  Cache-Control: no-cache
/app/flutter.js
  Cache-Control: no-cache
/app/flutter_bootstrap.js
  Cache-Control: no-cache
/app/flutter_service_worker.js
  Cache-Control: no-cache
/app/version.json
  Cache-Control: no-cache
HDR
rm -f "$DIST/app/_headers"

echo "==> deploying"
wrangler pages deploy "$DIST" --project-name heygilli-site --branch main --commit-dirty=true
