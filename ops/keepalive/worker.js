// Keeps the gateway on Render's free plan awake.
//
// Render puts a free service to sleep after 15 minutes without a request, and
// the next request then waits about 30 seconds while it boots. A judge or a
// parent opening the app would meet that wait first. Cloudflare's cron
// scheduler does not sleep, so a ping every 10 minutes from here keeps the
// gateway warm. It has no fetch handler and no public URL: it only runs on
// the schedule in wrangler.toml.

const HEALTHZ = "https://heygilli-gateway.onrender.com/healthz";

export default {
  async scheduled(event, env, ctx) {
    ctx.waitUntil(ping(event.cron));
  },
};

async function ping(cron) {
  const started = Date.now();
  try {
    const res = await fetch(HEALTHZ, {
      headers: { "user-agent": "heygilli-keepalive" },
      signal: AbortSignal.timeout(60_000),
    });
    console.log(`${cron} ${res.status} in ${Date.now() - started} ms`);
  } catch (err) {
    console.log(`${cron} failed after ${Date.now() - started} ms: ${err}`);
  }
}
