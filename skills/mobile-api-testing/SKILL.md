---
name: mobile-api-testing
description: "Test the backend APIs an Android app talks to, using endpoints and tokens recovered from static analysis (jadx/apkleaks) or runtime capture (Frida/Objection + the ARTEX recording proxy). Invoke when an APK task produced API endpoints that need HTTP testing: unauthenticated access, broken object-level authorization, hidden parameters, token handling flaws, or injection via app-specific request shapes."
---
# Mobile API testing (mobile findings → ARTEX web toolchain)
A mobile client is just a client. Everything the app does over the network can be tested with
ARTEX's existing web toolchain — but the entry points (endpoints, headers, token shapes) come
from the app itself. This skill bridges the two: register the mobile-derived endpoints in the
asset graph, then test them like any web target with evidence-grade traffic.
## Boundaries (read first)
- Only test API hosts in the engagement scope. An endpoint found in an APK's strings is a
  candidate, not an authorization: check the scope gate before the first request.
- Use the ARTEX recording proxy (`:8788`) for every request so the traffic store keeps the
  request/response pair; findings must bind that evidence.
- Credentials/tokens extracted from the app or a test device are engagement data: keep them in
  the task, redact them in any chat that could be shared, and never use them against third-party
  accounts.
## Inputs you should already have
From `apk-static-analysis`: hardcoded base URLs, API paths, SDK/host inventory.
From `frida-dynamic-instrumentation`: live request/response pairs through the recording proxy,
auth token format, pinned endpoints, per-request headers (User-Agent, signing headers).
## Workflow
**Step 1: inventory the API surface.** Collect endpoints into a file in your run directory:
```text
https://api.example.com/v2/user/profile        GET     bearer
https://api.example.com/v2/orders/{id}         GET     bearer
https://auth.example.com/oauth/token           POST    public
```
Register each unique host as an asset (`subdomain`/`service`) and each path pattern as an
`endpoint` in the asset graph, anchored to the intents that found them. This powers coverage: a
later worker sees which endpoints remain untested.
**Step 2: replay captured traffic first.** For endpoints captured live, replay the exact request
via the proxy (traffic detail → replay, or `curl` with the proxy env) to confirm the capture is
reproducible before mutating anything. If the app signs requests (custom header computed over
the body), find the signer with Frida (`okhttp3.Request` hooks) before spending turns on
parameter testing — an unsigned replay that fails with 401/403 is a fact worth recording, not a
vulnerability.
**Step 3: authorization and access control.** For object-level endpoints:
- replay with no token, an expired token, and a token from a second test account;
- replace object ids (order 1234 → 1235) between two test accounts and compare responses;
- test the same endpoint via the mobile-only route if the web app lacks it.
Record: exact request, exact response, and whether the second account saw the first's data. That
comparison is the finding; a 403 is not.
**Step 4: fuzz the app-specific shapes.** Hidden parameters (from `paramminer`-style wordlists
via ffuf or katana), content-type confusion (`application/json` vs `text/plain`), unexpected
methods (PATCH/PUT on endpoints the app never calls), mass-assignment candidates (mirror fields
the client sends). Keep request rates low; the noise governor paces proxied requests, scanners
you launch get the low-and-slow flags from the agent prompt.
**Step 5: run the standard scanners where they fit.** `nuclei` against the API host (tags:
`cve`, `exposure`, `misconfig`), `ffuf` for path discovery under the app's own API prefix,
`sqlmap` only on endpoints whose responses show genuine reflection differences. Mobile APIs
often break generic scanners (custom headers, signed requests) — prefer targeted replays over
spray when signatures are involved, and say so in the task.
**Step 6: write back.** Findings with the request/response bound from the traffic store; facts
for token formats, signing schemes and rate-limit behavior; endpoints marked tested in the asset
graph. Report noise-limiting behavior (rate limits, WAF) as facts — they are useful for the
retester.
## Practical notes
- Mobile APIs frequently sit behind different auth (device tokens, mTLS, HMAC). If a request
  cannot be reproduced from the container (client cert, device attestation), document the gap
  and move on — do not brute-force.
- The app's own User-Agent and signing headers should be reused verbatim when testing, so
  defenders can correlate the traffic; a scanner UA may trip the WAF and hide the real result.
- GraphQL backends: introspection, persisted-query probing and depth limits apply the same as
  web (see the `api-security` skill for the generic checks; this skill adds the mobile auth
  context).
## Completion self-check
- [ ] every endpoint tested is registered in the asset graph and anchored to an intent.
- [ ] every finding binds a captured request/response from the traffic store.
- [ ] authorization findings show a two-account or two-object comparison, not a single response.
- [ ] tokens extracted from the app never appear outside the task store (redacted in chat).
- [ ] scope gate respected: no request left the approved host list.
