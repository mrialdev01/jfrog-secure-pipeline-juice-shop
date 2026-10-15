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

Each remote repository also has an auto-created `-cache` repository that stores the proxied packages.

| Stage | What happens | Gate |
|---|---|---|
| Authenticate | GitHub OIDC (provider `github-oidc`): a short-lived JFrog token per run, no stored credentials | Build fails if no token is issued |
| Resolve and compile | `jf npm install` through `jfjs-npm`; base images pulled through `jfjs-docker` | Build fails if a dependency can't be resolved via Artifactory |
| Test | `npm test` (one retry, because one upstream test calls github.com) | Any failing test stops the run |
| Package | Multi-stage Docker build; npm credentials via BuildKit secret, so they never land in a layer | n/a |
| Publish | `jf docker push` plus build-info (env, git revision, dependencies, image) | n/a |
| Scan | `jf build-scan --fail=true` against watch `jfjs-juice-shop-watch` | Fails on any High or Critical (policy `jfjs-block-high-critical`) |
| SBOM | CycloneDX export of the image from Xray, kept as workflow artifact `sbom` | n/a |
| Promote | Build promoted to `jfjs-docker-prod-local` | Only on `main`, only if all gates passed |

## Traceability and auditability

Every image is tied to its build number, Git commit, workflow run URL, the exact npm dependencies
and the image digest through the published build-info (`jfrog-juice-shop` #N in project `jfjs`).
Xray scan results and the promotion status are recorded against that same build. The CycloneDX
SBOM is generated on every run and stored with the workflow run.

## Xray results (build 12)

Xray reports **10 Critical and 31 High** vulnerabilities. The policy gate fails the build, so the
image stays in `jfjs-docker-dev-local` and is not promoted.

### Most risky finding: `jsonwebtoken` 0.4.0 (Critical)

- **What:** in the `jsonwebtoken` node module before 4.2.2 it is possible for an attacker to bypass
  verification when a token is digitally signed with an asymmetric key (RS/ES family of algorithms)
  but the attacker instead sends a token digitally signed with a symmetric algorithm (HS* family).
- **Impact:** complete authentication bypass.
- **Remediation:** upgrade the library (`npm install jsonwebtoken@latest`) and explicitly whitelist
  the expected algorithm in the verification code
  (`jwt.verify(token, key, { algorithms: ['RS256'] });`).

The application is intentionally left unchanged, so the gate stays red and promotion is blocked.

## Run the pipeline

To reproduce it you need a JFrog Platform with Xray (a trial is enough) and a GitHub repository.

1. **Fork or clone this repository** and edit the `env` block of `.github/workflows/secure-pipeline.yml`
   (`JF_URL`, `JF_HOST`, and `JFROG_CLI_BUILD_PROJECT` if your JFrog project key is not `jfjs`).
2. **Create the repositories.** In JFrog, create a project with key `jfjs`, then run:
   ```bash
   export JF_URL=https://<your-instance>.jfrog.io
   export JF_ADMIN_TOKEN=<admin access token>   # never commit this
   bash scripts/jfrog-setup.sh
   ```
3. **Set up keyless authentication (OIDC).** In *Administration > General Management > Manage
   Integrations* add an OpenID Connect integration (provider `github-oidc`, type GitHub, audience
   `jfrog-github`, your GitHub organization or user). Add an identity mapping with claim
   `{"repository":"<owner>/<repo>"}` that maps to a group (here `github-ci`) holding the project roles
   Developer, Release Manager and Security Manager.
4. **Set up the Xray gate.** Create a policy (minimum severity High, *Fail Build* enabled) and a watch
   covering the build `jfrog-juice-shop` and the `jfjs-docker-dev-local` / `jfjs-docker-prod-local`
   repositories, then add the build under *Xray > Indexed Resources > Builds* after its first run
   has published it.
5. **Run it.** Push to `main`, open a pull request, or use *Actions > secure-pipeline > Run workflow*.

Expected result: dependencies resolve through Artifactory, tests pass, the image is pushed to
`jfjs-docker-dev-local`, and the Xray scan fails the build on the High and Critical findings, so
promotion is skipped. Where to look afterwards: *Artifactory > Builds > jfrog-juice-shop* for the
build record, *Xray > Scans List* for the findings, and the workflow run's `sbom` artifact for the
CycloneDX SBOM.

## Run the image

The registry is private. Log in with a read-only token, then:

Docker:

```bash
docker login trialmrial.jfrog.io -u <user>
docker run --rm -p 3000:3000 trialmrial.jfrog.io/jfjs-docker/jfrog-juice-shop:12
# open http://localhost:3000
```

Kubernetes (`deploy/jfrog-juice-shop.yaml`):

```bash
kubectl create secret docker-registry jfrog-pull \
  --docker-server=trialmrial.jfrog.io --docker-username=<user> --docker-password=<read-only-token>
kubectl apply -f deploy/jfrog-juice-shop.yaml
kubectl rollout status deploy/jfrog-juice-shop
kubectl port-forward svc/jfrog-juice-shop 3000:3000
# open http://localhost:3000
```

## Repository layout

| Path | Purpose |
|---|---|
| `.github/workflows/secure-pipeline.yml` | The pipeline |
| `Dockerfile` | Multi-stage build, base images parameterised so CI routes them through Artifactory |
| `scripts/jfrog-setup.sh` | Creates the repositories (admin token via env var, never committed) |
| `deploy/jfrog-juice-shop.yaml` | Kubernetes Deployment and Service |
| `docs/UPSTREAM_README.md` | Original Juice Shop README |
