# Browser Cache Mitigation for SPCS Web Apps

## Problem

When a Snowflake SPCS service is suspended and then resumed (either manually or by Gallery Operator), browsers may continue displaying stale cached pages instead of fetching fresh content from the restarted service.

**Symptoms:**
- After Compute Pool SUSPEND → RESUME, the app shows old content or error pages
- Regular refresh (F5) does not fix it
- Hard refresh (Ctrl+Shift+R) may work
- Private/incognito browsing always works

**Root cause:** Browsers cache HTML responses by default. When the service is suspended, Snowflake's proxy may return an error page (503 or auth redirect), which the browser then caches.

## Solution: Cache-Control Headers

Add `Cache-Control` headers to HTML responses so browsers never cache them. This ensures that after a SUSPEND → RESUME cycle, the browser always fetches the latest page from the running service.

### Flask

```python
# In create_app() or after app instantiation
@app.after_request
def set_cache_headers(response):
    if response.content_type and "text/html" in response.content_type:
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
    return response
```

### Express.js (Node)

```javascript
app.use((req, res, next) => {
  res.on('finish', () => {});
  const originalSend = res.send;
  res.send = function (body) {
    if (res.getHeader('content-type')?.includes('text/html')) {
      res.set('Cache-Control', 'no-cache, no-store, must-revalidate');
      res.set('Pragma', 'no-cache');
      res.set('Expires', '0');
    }
    return originalSend.call(this, body);
  };
  next();
});
```

### FastAPI / Starlette

```python
from starlette.middleware.base import BaseHTTPMiddleware

class NoCacheHTMLMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        response = await call_next(request)
        ct = response.headers.get("content-type", "")
        if "text/html" in ct:
            response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
            response.headers["Pragma"] = "no-cache"
            response.headers["Expires"] = "0"
        return response

app.add_middleware(NoCacheHTMLMiddleware)
```

## What This Does NOT Fix

- **Snowflake proxy-level caching:** When the service is not yet running, Snowflake's endpoint proxy returns its own error/auth pages. These responses are outside your app's control and may still be cached by the browser.
- **Static assets:** JS, CSS, and images are intentionally excluded from `no-cache` to preserve performance. If you need to bust static asset caches after a deploy, use versioned filenames or query strings (e.g., `style.css?v=2`).

## Recommendations

1. **Always apply these headers** to any SPCS web app that may be suspended/resumed
2. **Use versioned image tags** (`:v1`, `:v2`) instead of `:latest` — SPCS may cache `:latest` and not pull the updated image on service recreation
3. **Wait for service READY** before accessing the endpoint — if you hit the URL during provisioning, the browser may cache the error page
4. **Instruct users** to use Ctrl+Shift+R if they see stale content after a known suspend/resume cycle

## Reference

- [Postgres Learning Studio](https://github.com/KosukeKida/PostgresLearningStudio) — production implementation of this pattern
- Flask `after_request` docs: https://flask.palletsprojects.com/en/stable/api/#flask.Flask.after_request
