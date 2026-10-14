#!/usr/bin/env bash
# Creates the Artifactory repositories used by the secure pipeline.
# Usage:
#   export JF_URL=https://trialmrial.jfrog.io
#   export JF_ADMIN_TOKEN=<admin access token>   # never commit this
#   bash scripts/jfrog-setup.sh
set -euo pipefail

: "${JF_URL:?set JF_URL}"
: "${JF_ADMIN_TOKEN:?set JF_ADMIN_TOKEN}"
PROJECT_KEY="${PROJECT_KEY:-jfjs}"   # JFrog Project key; repo keys must start with it

create_repo() {
  local key="$1" body="$2"
  # inject the project key as the first field of the JSON payload
  body="${body/\{/{\"projectKey\":\"${PROJECT_KEY}\",}"
  echo "==> ${key}"
  curl -sS -o /dev/stderr -w "HTTP %{http_code}\n" \
    -X PUT "${JF_URL}/artifactory/api/repositories/${key}" \
    -H "Authorization: Bearer ${JF_ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${body}"
}

# ---- npm ----
create_repo jfjs-npm-remote '{
  "rclass":"remote","packageType":"npm",
  "url":"https://registry.npmjs.org",
  "xrayIndex":true,
  "description":"Proxy of npmjs.org"
}'

create_repo jfjs-npm '{
  "rclass":"virtual","packageType":"npm",
  "repositories":["jfjs-npm-remote"],
  "description":"Single npm resolution endpoint"
}'

# ---- Docker: upstream proxies ----
create_repo jfjs-docker-remote '{
  "rclass":"remote","packageType":"docker",
  "url":"https://registry-1.docker.io",
  "enableTokenAuthentication":true,
  "xrayIndex":true,
  "description":"Proxy of Docker Hub"
}'

create_repo jfjs-gcr-remote '{
  "rclass":"remote","packageType":"docker",
  "url":"https://gcr.io",
  "xrayIndex":true,
  "description":"Proxy of gcr.io (distroless base image)"
}'

# ---- Docker: local repos (dev -> prod promotion) ----
create_repo jfjs-docker-dev-local '{
  "rclass":"local","packageType":"docker",
  "xrayIndex":true,
  "description":"Images built by CI, not yet promoted"
}'

create_repo jfjs-docker-prod-local '{
  "rclass":"local","packageType":"docker",
  "xrayIndex":true,
  "description":"Images that passed the quality gate"
}'

# ---- Docker: virtual (single pull/push endpoint) ----
create_repo jfjs-docker '{
  "rclass":"virtual","packageType":"docker",
  "repositories":["jfjs-docker-dev-local","jfjs-docker-prod-local","jfjs-docker-remote","jfjs-gcr-remote"],
  "defaultDeploymentRepo":"jfjs-docker-dev-local",
  "description":"Single Docker endpoint: pulls base images, pushes to dev-local"
}'

echo "Done. Check Administration > Repositories in the JFrog UI."
