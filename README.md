# Secure pipeline for OWASP Juice Shop with JFrog

A GitHub Actions pipeline that compiles, tests and containerises OWASP Juice Shop, resolves every
dependency through Artifactory, and is gated by Xray before anything can be promoted.

> Juice Shop is deliberately vulnerable. The findings below are expected, and the point is that
> the pipeline detects them, blocks the build and records the evidence.

## Architecture

```
GitHub Actions ──► Artifactory (project jfjs) ──► Xray
  npm install        jfjs-npm  (virtual) ──► jfjs-npm-remote (npmjs)
  docker build       jfjs-docker (virtual) ─► jfjs-docker-remote (Docker Hub), jfjs-gcr-remote (gcr.io)
  docker push        jfjs-docker-dev-local ──(promotion, main only)──► jfjs-docker-prod-local
  build-info         jfjs-build-info
```

| Stage | What happens | Gate |
|---|---|---|
| Resolve and compile | `jf npm install` through `jfjs-npm`; base images pulled through `jfjs-docker` | Build fails if a dependency can't be resolved via Artifactory |
| Test | `npm test` (one retry, because one upstream test calls github.com) | Any failing test stops the run |
| Package | Multi-stage Docker build; npm credentials via BuildKit secret, so they never land in a layer | n/a |
| Publish | `jf docker push` plus build-info (env, git revision, dependencies, image) | n/a |
| Scan | `jf build-scan --fail=true` against watch `jfjs-juice-shop-watch` | Fails on any High or Critical (policy `jfjs-block-high-critical`) |
| SBOM | CycloneDX export of the image | n/a |
| Promote | Build promoted to `jfjs-docker-prod-local` | Only on `main`, only if all gates passed |

## Traceability and auditability

Every image is tied to its build number, Git commit, workflow run URL, the exact npm dependencies
and the image digest through the published build-info (`jfrog-juice-shop` #N in project `jfjs`).
Xray violations, the SBOM and the promotion status all hang off that same record.

## Xray results (build 7)

58 violations: **11 Critical, 47 High** (39 npm, 19 Debian base-image findings).
Full data: `docs/xray-scan-report.json` (and the CycloneDX SBOM in `docs/sbom-cyclonedx.json`).

### Most risky finding: `jsonwebtoken` 0.4.0, algorithm confusion (Critical)

- **What:** versions before 4.2.2 accept a token signed with HS256 when the application expects an
  asymmetric algorithm (RS256). An attacker signs a forged token using the public key as the HMAC
  secret and the library accepts it.
- **Impact:** complete authentication bypass. Forged tokens for any user, including admin, with no
  credentials and no user interaction.
- **Why this one first:** Critical, network-reachable and unauthenticated. Code review confirms the
  vulnerable pattern: `lib/insecurity.ts:189` and `routes/verify.ts:125` call
  `jwt.verify(token, publicKey, ...)` with an asymmetric key and no `algorithms` option. Xray's
  contextual analysis marks it *Not Covered*, so the scanner cannot rule it out and the manual
  review closes the gap.
- **Remediation:** upgrade to `jsonwebtoken` >= 9.0.0 and pass `algorithms: ['RS256']` explicitly to
  every `verify()` call (`jwt.verify(token, publicKey, { algorithms: ['RS256'] }, cb)`); the option
  alone neutralises the attack even before the upgrade. The same upgrade closes the related `none`-algorithm and key-type
  findings, and the nested copy pulled in by `express-jwt` (0.1.0).
- **Other items:** refresh the distroless base image digest (clears most of the Debian libc/GCC
  findings), and bump `@cyclonedx/cyclonedx-npm` to >= 6.0.0.

This is a recommendation. The application is intentionally left unchanged, so the gate stays red
and promotion is correctly blocked.

## Run the image

The registry is private. Log in with a read-only token, then:

```bash
docker login trialmrial.jfrog.io -u <user>
docker run --rm -p 3000:3000 trialmrial.jfrog.io/jfjs-docker/jfrog-juice-shop:9
# open http://localhost:3000
```

Kubernetes: `deploy/jfrog-juice-shop.yaml` (create the pull secret as described at the top of the file),
then `kubectl apply -f deploy/jfrog-juice-shop.yaml` and `kubectl port-forward svc/jfrog-juice-shop 3000:80`.

Build locally without JFrog: `docker build -t jfrog-juice-shop .` (the Dockerfile defaults pull
public base images and the npm secret mount is optional).

## Repository layout

| Path | Purpose |
|---|---|
| `.github/workflows/secure-pipeline.yml` | The pipeline |
| `Dockerfile` | Multi-stage build, base images parameterised so CI routes them through Artifactory |
| `scripts/jfrog-setup.sh` | Creates the repositories (admin token via env var, never committed) |
| `deploy/jfrog-juice-shop.yaml` | Kubernetes Deployment and Service |
| `docs/` | Xray scan export and CycloneDX SBOM |

## Security notes and next steps

- CI credentials live only in GitHub Actions secrets (`JF_ACCESS_TOKEN`, `JF_USER`).
- Next step: replace the token with GitHub OIDC so no long-lived secret exists.
- The `github-ci` identity currently holds broader project roles than strictly needed; a custom
  role limited to deploy, build-info and Xray scan would be the least-privilege version.
- Not done: Frogbot SCA comparison (optional in the brief).
