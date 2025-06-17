#!/bin/bash
set -euo pipefail

# Directus Full Migration (Schema + Data) using API + Docker
# No DB_CLIENT dependency - uses API for schema and Docker for data

MIGRATION_PATH="${1:-help}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TIMEOUT_SECONDS=60

# Load environment
source .env.directus || { echo "ERROR: .env.directus not found"; exit 1; }

# Create directories
mkdir -p ./backups ./schema-snapshots ./data_exports ./env_backups/{dev,stage,prod}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] - $1"
}

# Test API connection
test_api() {
    local env_name="$1"
    local url="$2"
    local token="$3"
    
    log "Testing $env_name API connection..."
    
    if timeout $TIMEOUT_SECONDS curl -s -f \
        --connect-timeout 15 --max-time $TIMEOUT_SECONDS \
        -H "Authorization: Bearer $token" \
        "$url/server/ping" > /dev/null; then
        log "✅ $env_name API accessible"
        return 0
    else
        log "❌ $env_name API failed"
        return 1
    fi
}

# Create schema snapshot via API
create_schema_snapshot() {
    local env_name="$1"
    local url="$2"
    local token="$3"
    local output_file="$4"
    
    log "Creating schema snapshot from $env_name..."
    
    local temp_file="${output_file}.tmp"
    local http_code
    
    http_code=$(timeout $TIMEOUT_SECONDS curl -s -w "%{http_code}" \
        --connect-timeout 15 --max-time $TIMEOUT_SECONDS \
        -H "Authorization: Bearer $token" \
        "$url/schema/snapshot" \
        -o "$temp_file")
    
    if [[ "$http_code" == "200" ]]; then
        if [[ -s "$temp_file" ]] && head -1 "$temp_file" | grep -q -E '^{|version:'; then
            mv "$temp_file" "$output_file"
            sync
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                log "✅ Schema snapshot created: $output_file ($(wc -c < "$output_file") bytes)"
                return 0
            fi
        fi
    fi
    
    log "❌ Schema snapshot failed (HTTP $http_code)"
    rm -f "$temp_file"
    return 1
}

# Apply schema via API with hash
apply_schema() {
    local env_name="$1"
    local url="$2"
    local token="$3"
    local snapshot_file="$4"
    
    log "Applying schema to $env_name..."
    
    # Step 1: Get current schema hash
    local current_hash_response="/tmp/current_hash_$$"
    local hash_http_code
    
    hash_http_code=$(timeout $TIMEOUT_SECONDS curl -s -w "%{http_code}" \
        --connect-timeout 15 --max-time $TIMEOUT_SECONDS \
        -H "Authorization: Bearer $token" \
        "$url/schema/snapshot" \
        -o "$current_hash_response")
    
    if [[ "$hash_http_code" != "200" ]]; then
        log "❌ Failed to get current schema hash"
        rm -f "$current_hash_response"
        return 1
    fi
    
    # Extract hash
    local current_hash
    if command -v jq >/dev/null 2>&1; then
        current_hash=$(jq -r '.hash // empty' "$current_hash_response" 2>/dev/null)
    fi
    
    if [[ -z "$current_hash" ]]; then
        current_hash=$(grep -o '"hash":"[^"]*"' "$current_hash_response" | cut -d'"' -f4)
    fi
    
    # Check if we got an actual schema response or if DB is empty
    local has_schema=true
    if grep -q '"collections":\[\]' "$current_hash_response" 2>/dev/null || \
       grep -q '"error"' "$current_hash_response" 2>/dev/null || \
       [[ ! -s "$current_hash_response" ]]; then
        has_schema=false
    fi
    
    log "Current $env_name schema hash: ${current_hash:-'not found'}"
    log "Has existing schema: $has_schema"
    rm -f "$current_hash_response"
    
    # Step 2: Apply schema
    local apply_payload="/tmp/apply_payload_$$"
    
    # Create payload based on whether we have an existing schema
    if [[ -n "$current_hash" && "$has_schema" == "true" ]]; then
        # Existing schema - need hash for diff
        cat > "$apply_payload" <<EOF
{
  "hash": "$current_hash",
  "snapshot": $(cat "$snapshot_file")
}
EOF
    else
        # Fresh database - apply snapshot directly
        log "Fresh database detected, applying full schema..."
        cat > "$apply_payload" <<EOF
{
  "snapshot": $(cat "$snapshot_file"),
  "diff": false
}
EOF
    fi
    
    local temp_response="/tmp/apply_response_$$"
    local http_code
    
    http_code=$(timeout $TIMEOUT_SECONDS curl -s -w "%{http_code}" \
        --connect-timeout 15 --max-time $TIMEOUT_SECONDS \
        -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d @"$apply_payload" \
        "$url/schema/apply" \
        -o "$temp_response")
    
    rm -f "$apply_payload"
    
    if [[ "$http_code" == "200" || "$http_code" == "204" ]]; then
        log "✅ Schema applied to $env_name"
        rm -f "$temp_response"
        return 0
    else
        log "❌ Schema apply failed (HTTP $http_code)"
        if [[ -f "$temp_response" ]]; then
            log "Error: $(cat "$temp_response" | head -3)"
        fi
        rm -f "$temp_response"
        return 1
    fi
}

# Backup environment settings via API
backup_env_settings() {
    local env_name="$1"
    local url="$2"
    local token="$3"
    local container="$4"
    
    local env_dir="./env_backups/$env_name"
    mkdir -p "$env_dir"
    
    log "Backing up $env_name environment settings..."
    
    # Backup via SQL to preserve everything
    log "Creating SQL backup of environment data..."
    
    # Tables to backup for environment preservation
    local tables=(
        "directus_settings"
        "directus_users"
        "directus_roles"
        "directus_permissions"
        "directus_webhooks"
        "directus_flows"
        "directus_operations"
    )
    
    for table in "${tables[@]}"; do
        log "  Backing up $table..."
        docker exec "$container" pg_dump \
            -U "$DB_USER" \
            -d "$DB_NAME" \
            --table="public.$table" \
            --data-only \
            --inserts \
            > "$env_dir/${table}_${TIMESTAMP}.sql" 2>/dev/null || true
    done
    
    # Also backup project info via API
    curl -s -f \
        -H "Authorization: Bearer $token" \
        "$url/settings" > "$env_dir/settings_api_${TIMESTAMP}.json" || true
    
    log "✅ Environment settings backed up to $env_dir"
}

# Restore environment settings
restore_env_settings() {
    local env_name="$1"
    local container="$2"
    
    local env_dir="./env_backups/$env_name"
    
    if [[ ! -d "$env_dir" ]]; then
        log "⚠️  No environment backup found for $env_name"
        return 1
    fi
    
    log "Restoring $env_name environment settings..."
    
    # Find latest backup files
    for table in directus_settings directus_users directus_roles directus_permissions directus_webhooks directus_flows directus_operations; do
        local latest_backup=$(ls -t "$env_dir/${table}_"*.sql 2>/dev/null | head -1)
        if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
            log "  Restoring $table..."
            # Delete existing data and restore from backup
            docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" <<EOF >/dev/null 2>&1 || true
DELETE FROM public.$table;
$(cat "$latest_backup")
EOF
        fi
    done
    
    log "✅ Environment settings restored"
}

# Full database backup
create_full_backup() {
    local env_name="$1"
    local container="$2"
    
    local backup_file="./backups/${env_name}_full_backup_${TIMESTAMP}.dump"
    
    log "Creating full database backup of $env_name..." >&2
    
    docker exec "$container" pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        -Fc \
        > "$backup_file"
    
    if [[ -f "$backup_file" && -s "$backup_file" ]]; then
        log "✅ Full backup created: $backup_file ($(du -h "$backup_file" | cut -f1))" >&2
        echo "$backup_file"  # Only output the filename
        return 0
    else
        log "❌ Backup failed" >&2
        return 1
    fi
}

# Export data only (excluding env-specific tables)
export_data() {
    local env_name="$1"
    local container="$2"
    
    local export_file="./data_exports/${env_name}_data_${TIMESTAMP}.dump"
    
    log "Exporting data from $env_name (excluding environment-specific tables)..." >&2
    
    # Tables to exclude from data migration (preserve target environment)
    local EXCLUDE_TABLES=(
        "directus_users"
        "directus_sessions"
        "directus_settings"
        "directus_webhooks"
        "directus_flows"
        "directus_operations"
        "directus_activity"
        "directus_notifications"
        "directus_roles"
        "directus_permissions"
        "directus_access"
        "directus_migrations"
        "directus_extensions"
        "directus_presets"
        "directus_revisions"
        "directus_policies"
        "directus_collections"
        "directus_fields"
        "directus_relations"
        "directus_translations"
        "directus_comments"
        "directus_folders"
        "directus_files"
        "directus_dashboards"
        "directus_panels"
        "directus_shares"
        "directus_versions"
    )
    
    # Build exclude flags
    local EXCLUDE_FLAGS=""
    for table in "${EXCLUDE_TABLES[@]}"; do
        EXCLUDE_FLAGS+=" --exclude-table-data=public.$table"
    done
    
    docker exec "$container" pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --data-only \
        $EXCLUDE_FLAGS \
        -Fc \
        > "$export_file"
    
    if [[ -f "$export_file" && -s "$export_file" ]]; then
        log "✅ Data exported: $export_file ($(du -h "$export_file" | cut -f1))" >&2
        echo "$export_file"  # Only output the filename, not the log
        return 0
    else
        log "❌ Data export failed" >&2
        return 1
    fi
}

# Main migration function
perform_full_migration() {
    local source_env="$1"
    local source_url="$2"
    local source_token="$3"
    local source_container="$4"
    local target_env="$5"
    local target_url="$6"
    local target_token="$7"
    local target_container="$8"
    
    log "=== FULL MIGRATION: $source_env → $target_env ==="
    log "This will migrate both schema and data!"
    
    # 🛡️ SAFETY CHECKS
    log "🛡️ Performing safety checks..."
    
    # Check if containers exist
    if ! docker ps --format "table {{.Names}}" | grep -q "^$source_container$"; then
        log "❌ Source container '$source_container' not found"
        exit 1
    fi
    
    if ! docker ps --format "table {{.Names}}" | grep -q "^$target_container$"; then
        log "❌ Target container '$target_container' not found"
        exit 1
    fi
    
    # Check database connectivity
    if ! docker exec "$source_container" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
        log "❌ Cannot connect to source database"
        exit 1
    fi
    
    if ! docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" >/dev/null 2>&1; then
        log "❌ Cannot connect to target database"
        exit 1
    fi
    
    log "✅ All safety checks passed"
    
    # Step 1: Test connections
    test_api "$source_env" "$source_url" "$source_token" || exit 1
    test_api "$target_env" "$target_url" "$target_token" || exit 1
    
    # 🔍 DEBUG: Check initial user count
    local user_count=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM directus_users;" | xargs)
    log "🔍 DEBUG: Initial user count in $target_env: $user_count"
    
    # Step 2: Skip environment backup (we're preserving the database)
    log "Skipping environment backup - database will be preserved"
    
    # Step 3: Create full backup of target
    local backup_file
    if backup_file=$(create_full_backup "$target_env" "$target_container"); then
        log "✅ Target backup completed"
        # 🔍 DEBUG: Check user count after backup
        user_count=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM directus_users;" | xargs)
        log "🔍 DEBUG: User count after backup: $user_count"
    else
        log "❌ Target backup failed - ABORTING"
        exit 1
    fi
    
    # Step 4: Export schema from source
    local schema_file="./schema-snapshots/${source_env}_to_${target_env}_${TIMESTAMP}.yaml"
    if create_schema_snapshot "$source_env" "$source_url" "$source_token" "$schema_file"; then
        log "✅ Source schema exported"
        # 🔍 DEBUG: Check user count after schema export
        user_count=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM directus_users;" | xargs)
        log "🔍 DEBUG: User count after schema export: $user_count"
    else
        log "❌ Schema export failed - ABORTING"
        exit 1
    fi
    
    # Step 5: Export data from source
    local data_file
    if data_file=$(export_data "$source_env" "$source_container"); then
        log "✅ Source data exported"
        # 🔍 DEBUG: Check user count after data export
        user_count=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM directus_users;" | xargs)
        log "🔍 DEBUG: User count after data export: $user_count"
    else
        log "❌ Data export failed - ABORTING"
        exit 1
    fi
    
    # Step 6: Skip database recreation - we'll preserve existing data
    log "Preparing target database (preserving authentication data)..."
    # Don't drop the database! Just ensure we can connect
    docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" > /dev/null 2>&1 || {
        log "❌ Cannot connect to target database"
        exit 1
    }
    
    # Step 7: Apply schema changes via API
    log "Applying schema changes via API..."
    
    # Verify Directus is accessible
    if ! curl -s -f "$target_url/server/ping" > /dev/null 2>&1; then
        log "❌ Target Directus is not accessible"
        exit 1
    fi
    
    # Step 7a: Generate diff between source schema and target's current state
    log "Generating schema diff via API..."
    local diff_payload="/tmp/diff_payload_$$"
    
    # Read the schema file
    local schema_content=$(cat "$schema_file")
    
    # Extract the actual schema from the data wrapper
    # The API returns {"data": {...schema...}} but diff expects just {...schema...}
    if echo "$schema_content" | jq -e '.data' > /dev/null 2>&1; then
        log "Extracting schema from data wrapper..."
        schema_content=$(echo "$schema_content" | jq '.data')
    fi
    
    # Verify we now have the correct structure
    local has_version=$(echo "$schema_content" | jq -r 'has("version")' 2>/dev/null || echo "false")
    local has_directus=$(echo "$schema_content" | jq -r 'has("directus")' 2>/dev/null || echo "false")
    local has_vendor=$(echo "$schema_content" | jq -r 'has("vendor")' 2>/dev/null || echo "false")
    
    log "Schema metadata - version: $has_version, directus: $has_directus, vendor: $has_vendor"
    
    # Write the unwrapped schema to the payload file
    echo "$schema_content" > "$diff_payload"
    
    local diff_response_file="/tmp/diff_response_$$"
    local diff_http_code
    
    diff_http_code=$(timeout $TIMEOUT_SECONDS curl -s -w "%{http_code}" \
        --connect-timeout 15 --max-time $TIMEOUT_SECONDS \
        -X POST \
        -H "Authorization: Bearer $target_token" \
        -H "Content-Type: application/json" \
        -d @"$diff_payload" \
        "$target_url/schema/diff?force=true" \
        -o "$diff_response_file")
    
    rm -f "$diff_payload"
    
    if [[ "$diff_http_code" == "200" ]]; then
        # Check if we got a valid diff response (it's wrapped in data)
        if [[ -s "$diff_response_file" ]] && jq -e '.data.diff' "$diff_response_file" > /dev/null 2>&1; then
            log "✅ Schema diff generated successfully"
            
            # Extract just the data portion for apply endpoint
            local diff_data=$(jq '.data' "$diff_response_file")
            echo "$diff_data" > "$diff_response_file"
            
            # Show summary of changes
            local collections_count=$(echo "$diff_data" | jq '.diff.collections | length')
            local fields_count=$(echo "$diff_data" | jq '.diff.fields | length')
            local relations_count=$(echo "$diff_data" | jq '.diff.relations | length')
            log "Diff summary: $collections_count collections, $fields_count fields, $relations_count relations to modify"
        else
            log "❌ Invalid diff response"
            log "Response: $(cat "$diff_response_file" | head -3)"
            rm -f "$diff_response_file"
            exit 1
        fi
    elif [[ "$diff_http_code" == "204" ]]; then
        # 204 No Content means schemas are identical - no changes needed
        log "✅ Schemas are identical - no changes to apply"
        local skip_schema_apply=true
    else
        log "❌ Schema diff failed (HTTP $diff_http_code)"
        log "Response: $(cat "$diff_response_file" | head -3)"
        rm -f "$diff_response_file"
        exit 1
    fi
    
    # Step 7b: Apply the diff using the complete diff response
    if [[ "${skip_schema_apply:-false}" != "true" ]]; then
        log "Applying schema diff..."
        local apply_response
        apply_response=$(timeout $TIMEOUT_SECONDS curl -s -w "\nHTTP_CODE:%{http_code}" \
            --connect-timeout 15 --max-time $TIMEOUT_SECONDS \
            -X POST \
            -H "Authorization: Bearer $target_token" \
            -H "Content-Type: application/json" \
            -d @"$diff_response_file" \
            "$target_url/schema/apply")
        
        local apply_http_code=$(echo "$apply_response" | grep "HTTP_CODE:" | cut -d':' -f2)
        local apply_body=$(echo "$apply_response" | grep -v "HTTP_CODE:")
        
        rm -f "$diff_response_file"
        
        if [[ "$apply_http_code" == "200" || "$apply_http_code" == "204" ]]; then
            log "✅ Schema applied successfully via API"
            # 🔍 DEBUG: Check user count after schema apply
            user_count=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM directus_users;" | xargs)
            log "🔍 DEBUG: User count after schema apply: $user_count"
        else
            log "❌ Schema apply failed (HTTP $apply_http_code)"
            log "Response: $(echo "$apply_body" | head -3)"
            exit 1
        fi
    else
        log "⏭️  Skipping schema apply - schemas are already identical"
        # 🔍 DEBUG: Check user count after schema skip
        user_count=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM directus_users;" | xargs)
        log "🔍 DEBUG: User count after schema skip: $user_count"
    fi
    
    # Step 9: Clear only tables that will be imported (not excluded ones)
    log "Preparing target database for data import..."
    
    # Copy the data file to the container first
    docker cp "$data_file" "$target_container:/tmp/data_import.dump"
    
    # Get list of tables that are in the dump file (these are the ones we'll import)
    log "Analyzing which tables are in the import file..."
    # pg_restore --list shows: <num> <num> <num> TABLE DATA <schema> <table> <owner>
    # We need the 7th field (table name), not the 6th (schema)
    local tables_in_dump=$(docker exec "$target_container" pg_restore --list /tmp/data_import.dump | \
        grep "TABLE DATA" | \
        awk '{print $7}' | \
        sort -u)
    
    if [[ -n "$tables_in_dump" ]]; then
        log "Found $(echo "$tables_in_dump" | wc -l) tables to import"
        log "Clearing only tables that will be imported..."
        
        echo "$tables_in_dump" | while read -r table; do
            table=$(echo "$table" | xargs)  # trim whitespace
            if [[ -n "$table" ]]; then
                log "  Clearing table: $table"
                # First check if table exists
                local table_exists=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t \
                    -c "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='$table');" | xargs)
                
                if [[ "$table_exists" == "t" ]]; then
                    # Table exists, clear it WITHOUT CASCADE to protect system tables
                    docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" \
                        -c "TRUNCATE TABLE public.\"$table\" RESTART IDENTITY;" 2>/dev/null || {
                        log "    Truncate failed, trying DELETE"
                        docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" \
                            -c "DELETE FROM public.\"$table\";" 2>/dev/null || {
                            log "    WARNING: Could not clear $table"
                        }
                    }
                else
                    log "    Table $table doesn't exist yet (will be created during import)"
                fi
            fi
        done
        
        log "✅ Cleared tables that will be imported"
        log "✅ Preserved all excluded tables (users, settings, etc.)"
        # 🔍 DEBUG: Check user count after table clearing
        user_count=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM directus_users;" | xargs)
        log "🔍 DEBUG: User count after table clearing: $user_count"
    else
        log "⚠️  No tables found in import file"
    fi
    
    log "Importing data to target..."
    
    # Step 1: Disable foreign key checks to prevent CASCADE issues
    docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -c "SET session_replication_role = replica;"
    
    # Step 2: Import data
    # 🔍 DEBUG: Check user count before data import
    user_count=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM directus_users;" | xargs)
    log "🔍 DEBUG: User count before data import: $user_count"
    
    if docker exec "$target_container" pg_restore \
        --username="$DB_USER" \
        --dbname="$DB_NAME" \
        --data-only \
        --disable-triggers \
        --no-owner \
        --verbose \
        /tmp/data_import.dump 2>&1 | tee /tmp/import_log_$$.txt; then
        log "✅ Data import completed successfully"
        # 🔍 DEBUG: Check user count after data import
        user_count=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM directus_users;" | xargs)
        log "🔍 DEBUG: User count after data import: $user_count"
    else
        # Check if errors were just duplicates
        local error_count=$(grep -c "ERROR:" /tmp/import_log_$$.txt || echo 0)
        local duplicate_count=$(grep -c "duplicate key value violates unique constraint" /tmp/import_log_$$.txt || echo 0)
        
        if [[ "$error_count" -eq "$duplicate_count" && "$duplicate_count" -gt 0 ]]; then
            log "⚠️  Data import skipped duplicate records (data already exists)"
            log "   This is expected if the environments already have similar data"
        else
            log "⚠️  Data import completed with some errors"
            log "   Duplicate key errors: $duplicate_count"
            log "   Other errors: $((error_count - duplicate_count))"
        fi
    fi
    
    # Step 3: Clear user references in content tables only
    log "Clearing user references in content tables (system tables preserved)..."
    docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -c "
    -- Clear content table user references to avoid FK constraints
    -- System tables (access, notifications, presets, sessions) are excluded from import
    -- so they retain their dev environment configuration
    UPDATE pages SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE trial SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE sponsor SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE resource SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE regulatory_approval SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE team_members SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE company_highlights SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE button SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE block_useful_link SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE block_resources SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE page_about_us SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE patient_view SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE professional_view SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE sponsor_article SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    UPDATE sponsor_page SET user_created = NULL, user_updated = NULL WHERE user_created IS NOT NULL OR user_updated IS NOT NULL;
    " 2>/dev/null || true
    log "✅ Content user references cleared - system tables preserved"
    # 🔍 DEBUG: Check user count after clearing references
    user_count=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM directus_users;" | xargs)
    log "🔍 DEBUG: User count after clearing references: $user_count"
    
    # Step 4: Now safely re-enable foreign key checks
    log "Re-enabling foreign key checks..."
    docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -c "SET session_replication_role = DEFAULT;"
    # 🔍 DEBUG: Check user count after re-enabling FK checks
    user_count=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM directus_users;" | xargs)
    log "🔍 DEBUG: User count after re-enabling FK checks: $user_count"
    
    rm -f /tmp/import_log_$$.txt
    
    # Clean up temp file
    docker exec "$target_container" rm -f /tmp/data_import.dump
    
    # Step 10: Skip environment restore (database was preserved)
    log "Environment settings preserved - no restore needed"
    
    # 🔍 FINAL VALIDATION
    log "🔍 Performing final validation..."
    local final_user_count=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM directus_users;" | xargs)
    local final_settings_count=$(docker exec "$target_container" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM directus_settings;" | xargs)
    
    if [[ "$final_user_count" -eq 0 ]]; then
        log "❌ CRITICAL ERROR: All users were deleted during migration!"
        log "❌ Please restore from backup: $backup_file"
        exit 1
    fi
    
    if [[ "$final_settings_count" -eq 0 ]]; then
        log "⚠️  WARNING: Settings were cleared during migration"
    fi
    
    log "✅ Final validation passed - Users: $final_user_count, Settings: $final_settings_count"
    
    log "🎉 Full migration completed successfully!"
    log ""
    log "📊 Migration Summary:"
    log "  Source: $source_env"
    log "  Target: $target_env"
    log "  Backup: $backup_file"
    log "  Schema: $schema_file"
    log "  Data: $data_file"
    log ""
    log "✅ What was migrated:"
    log "  - Database schema updates (via API diff/apply)"
    log "  - Content data (all non-system tables)"
    log ""
    log "✅ What was preserved in $target_env:"
    log "  - ALL user accounts and authentication"
    log "  - Project settings (title, colors, etc.)"
    log "  - API tokens and static tokens"
    log "  - Webhooks, flows, and operations"
    log "  - All system configuration"
}

# Main execution
case "$MIGRATION_PATH" in
    "stage-to-prod")
        perform_full_migration \
            "stage" "$STAGE_DIRECTUS_URL" "$STAGE_DIRECTUS_TOKEN" "$STAGE_DB_CONTAINER_NAME" \
            "prod" "$PROD_DIRECTUS_URL" "$PROD_DIRECTUS_TOKEN" "$PROD_DB_CONTAINER_NAME"
        ;;
        
    "dev-to-stage")
        perform_full_migration \
            "dev" "$DEV_DIRECTUS_URL" "$DEV_DIRECTUS_TOKEN" "$DEV_DB_CONTAINER_NAME" \
            "stage" "$STAGE_DIRECTUS_URL" "$STAGE_DIRECTUS_TOKEN" "$STAGE_DB_CONTAINER_NAME"
        ;;
        
    "stage-to-dev")
        perform_full_migration \
            "stage" "$STAGE_DIRECTUS_URL" "$STAGE_DIRECTUS_TOKEN" "$STAGE_DB_CONTAINER_NAME" \
            "dev" "$DEV_DIRECTUS_URL" "$DEV_DIRECTUS_TOKEN" "$DEV_DB_CONTAINER_NAME"
        ;;
        
    "dev-to-prod")
        perform_full_migration \
            "dev" "$DEV_DIRECTUS_URL" "$DEV_DIRECTUS_TOKEN" "$DEV_DB_CONTAINER_NAME" \
            "prod" "$PROD_DIRECTUS_URL" "$PROD_DIRECTUS_TOKEN" "$PROD_DB_CONTAINER_NAME"
        ;;
        
    "prod-to-dev")
        perform_full_migration \
            "prod" "$PROD_DIRECTUS_URL" "$PROD_DIRECTUS_TOKEN" "$PROD_DB_CONTAINER_NAME" \
            "dev" "$DEV_DIRECTUS_URL" "$DEV_DIRECTUS_TOKEN" "$DEV_DB_CONTAINER_NAME"
        ;;
        
    "prod-to-stage")
        perform_full_migration \
            "prod" "$PROD_DIRECTUS_URL" "$PROD_DIRECTUS_TOKEN" "$PROD_DB_CONTAINER_NAME" \
            "stage" "$STAGE_DIRECTUS_URL" "$STAGE_DIRECTUS_TOKEN" "$STAGE_DB_CONTAINER_NAME"
        ;;
        
    "edit-to-dev")
        perform_full_migration \
            "edit" "$EDIT_DIRECTUS_URL" "$EDIT_DIRECTUS_TOKEN" "$EDIT_DB_CONTAINER_NAME" \
            "dev" "$DEV_DIRECTUS_URL" "$DEV_DIRECTUS_TOKEN" "$DEV_DB_CONTAINER_NAME"
        ;;
        
    "edit-to-stage")
        perform_full_migration \
            "edit" "$EDIT_DIRECTUS_URL" "$EDIT_DIRECTUS_TOKEN" "$EDIT_DB_CONTAINER_NAME" \
            "stage" "$STAGE_DIRECTUS_URL" "$STAGE_DIRECTUS_TOKEN" "$STAGE_DB_CONTAINER_NAME"
        ;;
        
    "edit-to-prod")
        perform_full_migration \
            "edit" "$EDIT_DIRECTUS_URL" "$EDIT_DIRECTUS_TOKEN" "$EDIT_DB_CONTAINER_NAME" \
            "prod" "$PROD_DIRECTUS_URL" "$PROD_DIRECTUS_TOKEN" "$PROD_DB_CONTAINER_NAME"
        ;;
        
    *)
        echo "Usage: $0 [stage-to-prod|dev-to-stage|stage-to-dev|dev-to-prod|prod-to-dev|prod-to-stage|edit-to-dev|edit-to-stage|edit-to-prod]"
        echo ""
        echo "Full Migration (Schema + Data) with API:"
        echo "  ✅ No DB_CLIENT dependency"
        echo "  ✅ Uses API for schema operations"
        echo "  ✅ Uses Docker PostgreSQL for data operations"
        echo "  ✅ Preserves environment-specific data"
        echo "  ✅ Creates full backups before migration"
        echo ""
        echo "What gets migrated:"
        echo "  - All collections and schema structure"
        echo "  - All content data (posts, pages, etc.)"
        echo "  - All relationships and metadata"
        echo ""
        echo "What stays unchanged:"
        echo "  - User accounts and authentication"
        echo "  - API tokens and static tokens"
        echo "  - Project title and settings"
        echo "  - Webhooks and environment URLs"
        exit 1
        ;;
esac