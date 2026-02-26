#!/usr/bin/env bash
set -euo pipefail

echo "Starting architecture migration..."

mkdir -p {apps/{web,api,admin},packages/{database,auth,workflows,types,config,ui},infrastructure/{firebase,scripts,docker},docs,.github}

echo "Moving existing folders..."

# frontend -> apps/web
if [ -d "frontend" ]; then
  mv frontend/* apps/web/ 2>/dev/null || true
  rm -rf frontend
fi

# api -> apps/api
if [ -d "api" ]; then
  mv api/* apps/api/ 2>/dev/null || true
  rm -rf api
fi

# database -> packages/database
if [ -d "database" ]; then
  mv database/* packages/database/ 2>/dev/null || true
  rm -rf database
fi

# prompts -> workflows/ai
mkdir -p packages/workflows/ai
if [ -d "prompts" ]; then
  mv prompts/* packages/workflows/ai/ 2>/dev/null || true
  rm -rf prompts
fi

# assets -> web public
mkdir -p apps/web/public
if [ -d "assets" ]; then
  mv assets/* apps/web/public/ 2>/dev/null || true
  rm -rf assets
fi

echo "Creating workspace files..."

cat <<EOF > pnpm-workspace.yaml
packages:
  - "apps/*"
  - "packages/*"
EOF

cat <<EOF > turbo.json
{
  "\$schema": "https://turbo.build/schema.json",
  "pipeline": {
    "build": { "dependsOn": ["^build"], "outputs": ["dist/**",".next/**"] },
    "dev": { "cache": false },
    "lint": {},
    "typecheck": {}
  }
}
EOF

echo "Migration complete."