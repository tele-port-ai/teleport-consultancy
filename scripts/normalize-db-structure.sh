#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# TELE PORT CONSULTANCY
# DATABASE STRUCTURE NORMALIZER
# Production safe refactor (non-destructive)
# =========================================================

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DB_DIR="${ROOT_DIR}/packages/database"
BACKUP_DIR="${DB_DIR}/_backup_$(date +%Y%m%d_%H%M%S)"

echo "Root: ${ROOT_DIR}"
echo "Database dir: ${DB_DIR}"

[[ -d "${DB_DIR}" ]] || { echo "❌ packages/database not found"; exit 1; }

# ---------------------------------------------------------
# Backup
# ---------------------------------------------------------
mkdir -p "${BACKUP_DIR}"
cp -r "${DB_DIR}"/*.sql "${BACKUP_DIR}" 2>/dev/null || true
echo "✔ Backup created at ${BACKUP_DIR}"

# ---------------------------------------------------------
# Rename base schema
# ---------------------------------------------------------
if [[ -f "${DB_DIR}/00_base_schema.sql" ]]; then
    mv "${DB_DIR}/00_base_schema.sql" "${DB_DIR}/00_identity_schema.sql"
    echo "✔ 00_base_schema.sql → 00_identity_schema.sql"
fi

# ---------------------------------------------------------
# Merge workflow engines
# ---------------------------------------------------------
WORKFLOW_TARGET="${DB_DIR}/02_workflow_engine.sql"

{
    echo "-- AUTO MERGED WORKFLOW FILE"
    echo "-- DO NOT EDIT HISTORY ABOVE"
    echo

    [[ -f "${DB_DIR}/01_workflow_engine.sql" ]] && cat "${DB_DIR}/01_workflow_engine.sql"
    echo
    [[ -f "${DB_DIR}/02_workflow_engine.sql" ]] && cat "${DB_DIR}/02_workflow_engine.sql"
} > "${WORKFLOW_TARGET}.tmp"

mv "${WORKFLOW_TARGET}.tmp" "${WORKFLOW_TARGET}"

rm -f "${DB_DIR}/01_workflow_engine.sql" 2>/dev/null || true
echo "✔ Workflow engines merged → 02_workflow_engine.sql"

# ---------------------------------------------------------
# Ensure canonical files exist
# ---------------------------------------------------------
touch "${DB_DIR}/01_case_engine.sql"
touch "${DB_DIR}/03_document_system.sql"
touch "${DB_DIR}/04_operations_engine.sql"
touch "${DB_DIR}/05_security_rls.sql"

# ---------------------------------------------------------
# Normalize names (if variants existed)
# ---------------------------------------------------------
[[ -f "${DB_DIR}/03_documents.sql" ]] && mv "${DB_DIR}/03_documents.sql" "${DB_DIR}/03_document_system.sql"

# ---------------------------------------------------------
# Final structure
# ---------------------------------------------------------
echo
echo "Final database structure:"
ls -1 "${DB_DIR}" | sed 's/^/  - /'

echo
echo "✅ Database architecture normalized"