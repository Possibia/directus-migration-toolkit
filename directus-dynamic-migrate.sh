#!/bin/bash
# Dynamic Directus Migration - Works with ANY environment names
# Usage: ./directus-dynamic-migrate.sh <source-env> <target-env> [--full]

set -euo pipefail

SOURCE_ENV="${1:-}"
TARGET_ENV="${2:-}"
MIGRATION_TYPE="schema"
VERBOSE=true
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] - $1"
    fi
}

log_always() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] - $1"
}

show_help() {
    echo "Dynamic Directus Migration Tool"
    echo ""
    echo "Usage: $0 <source-env> <target-env> [options]"
    echo ""
    echo "Arguments:"
    echo "  source-env    Source environment name (e.g., potato, dev, local)"
    echo "  target-env    Target environment name (e.g., tomato, prod, staging)"
    echo ""
    echo "Migration Types:"
    echo "  (default)     Schema-only migration - safe, preserves all data"
    echo "  --full        Full migration - migrates schema + content data"
    echo ""
    echo "Output Options:"
    echo "  --quiet       Minimal output (only show results)"
    echo "  --verbose     Detailed output (default)"
    echo ""
    echo "Examples:"
    echo "  $0 potato tomato                    # Schema only, verbose"
    echo "  $0 dev prod --full                  # Full migration, verbose"
    echo "  $0 local staging --quiet            # Schema only, minimal output"
    echo "  $0 dev prod --full --verbose        # Full migration, detailed output"
    echo ""
    echo "Migration Type Details:"
    echo "  Schema-only:  Migrates structure (collections, fields, relationships)"
    echo "                Preserves ALL existing data, users, settings"
    echo "                Fast, safe, API-only"
    echo ""
    echo "  Full:         Migrates structure + content data"
    echo "                Preserves users, settings, permissions"
    echo "                Replaces ALL content data (pages, articles, etc.)"
    echo "                Selective data transfer: TODO (not yet implemented)"
    echo "                Requires database containers, slower"
    echo ""
    echo "Environment Configuration:"
    echo "Set these environment variables for each environment:"
    echo "  {ENV_NAME}_URL         - Directus URL (required)"
    echo "  {ENV_NAME}_TOKEN       - Admin token (required)"
    echo "  {ENV_NAME}_DB_CONTAINER - Docker container name (for full migrations)"
    echo ""
    echo "Setup example (.env file):"
    echo "  POTATO_URL=https://potato.example.com"
    echo "  POTATO_TOKEN=your-potato-admin-token"
    echo "  TOMATO_URL=https://tomato.example.com"
    echo "  TOMATO_TOKEN=your-tomato-admin-token"
    echo ""
}

# Get environment variable value dynamically
get_env_var() {
    local env_name="$1"
    local var_suffix="$2"
    local env_upper=$(echo "$env_name" | tr '[:lower:]' '[:upper:]')
    local var_name="${env_upper}_${var_suffix}"
    echo "${!var_name:-}"
}

# Validate environment configuration
validate_env() {
    local env_name="$1"
    local url token
    
    url=$(get_env_var "$env_name" "URL")
    token=$(get_env_var "$env_name" "TOKEN")
    
    if [[ -z "$url" ]]; then
        echo -e "${RED}❌ Missing ${env_name^^}_URL environment variable${NC}"
        return 1
    fi
    
    if [[ -z "$token" ]]; then
        echo -e "${RED}❌ Missing ${env_name^^}_TOKEN environment variable${NC}"
        return 1
    fi
    
    return 0
}

# Test API connection
test_api() {
    local env_name="$1"
    local url token
    
    url=$(get_env_var "$env_name" "URL")
    token=$(get_env_var "$env_name" "TOKEN")
    
    log "Testing $env_name API connection..."
    
    if timeout 10 curl -s -f \
        --connect-timeout 15 --max-time 10 \
        -H "Authorization: Bearer $token" \
        "$url/server/ping" > /dev/null 2>&1; then
        log "✅ $env_name API accessible"
        return 0
    else
        log "❌ $env_name API failed"
        return 1
    fi
}

# Check permissions
check_permissions() {
    local env_name="$1"
    local url token
    
    url=$(get_env_var "$env_name" "URL")
    token=$(get_env_var "$env_name" "TOKEN")
    
    log "Checking $env_name permissions..."
    
    # Test schema access - Use Bearer header (recommended method)
    local response
    response=$(timeout 10 curl -s -w "%{http_code}" \
        --connect-timeout 15 --max-time 10 \
        -H "Authorization: Bearer $token" \
        "$url/schema/snapshot" -o /dev/null 2>/dev/null)
    
    if [[ "$response" == "200" ]]; then
        log "✅ $env_name has schema permissions"
        return 0
    elif [[ "$response" == "403" ]]; then
        log "❌ $env_name token lacks schema permissions"
        return 1
    else
        log "⚠️  $env_name schema access unclear (HTTP $response)"
        return 1
    fi
}

# Create schema snapshot via API
create_snapshot() {
    local env_name="$1"
    local output_file="$2"
    local url token
    
    url=$(get_env_var "$env_name" "URL")
    token=$(get_env_var "$env_name" "TOKEN")
    
    log "Creating schema snapshot from $env_name..."
    
    # Try API call with proper error handling - Use Bearer header (recommended)
    local temp_file="${output_file}.tmp"
    local http_code
    
    http_code=$(timeout 30 curl -s -w "%{http_code}" \
        --connect-timeout 15 --max-time 30 \
        -H "Authorization: Bearer $token" \
        "$url/schema/snapshot" \
        -o "$temp_file")
    
    if [[ "$http_code" == "200" ]]; then
        # Check if response is valid
        if [[ -s "$temp_file" ]] && head -1 "$temp_file" | grep -q -E '^{|version:'; then
            mv "$temp_file" "$output_file"
            # Ensure file is written to disk
            sync
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                log "✅ Schema snapshot created: $output_file ($(wc -c < "$output_file") bytes)"
                return 0
            else
                log "❌ Failed to save snapshot file"
                return 1
            fi
        else
            log "❌ Invalid response from $env_name"
            log "Response: $(head -3 "$temp_file" 2>/dev/null || echo 'empty')"
            rm -f "$temp_file"
            return 1
        fi
    else
        log "❌ Schema snapshot failed (HTTP $http_code)"
        if [[ -f "$temp_file" ]]; then
            log "Error response: $(head -3 "$temp_file" 2>/dev/null)"
            rm -f "$temp_file"
        fi
        return 1
    fi
}

# Apply schema using the correct Directus diff/apply workflow
apply_schema() {
    local env_name="$1"
    local schema_file="$2"
    local url token
    
    url=$(get_env_var "$env_name" "URL")
    token=$(get_env_var "$env_name" "TOKEN")
    
    log "Applying schema to $env_name using diff/apply..."
    
    # Verify file exists
    if [[ ! -f "$schema_file" || ! -s "$schema_file" ]]; then
        log "❌ Snapshot file missing: $schema_file"
        return 1
    fi
    
    # Step 1: Generate diff between source schema and target's current state
    log "Generating schema diff via API..."
    local diff_payload="/tmp/diff_payload_$$"
    local diff_response="/tmp/diff_response_$$"
    local temp_error="/tmp/schema_error_$$.json"
    
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
    
    # Write the schema to payload file
    echo "$schema_content" > "$diff_payload"
    
    local diff_response_file="/tmp/diff_response_$$"
    local diff_http_code
    
    diff_http_code=$(timeout 30 curl -s -w "%{http_code}" \
        --connect-timeout 15 --max-time 30 \
        -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d @"$diff_payload" \
        "$url/schema/diff?force=true" \
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
            return 1
        fi
    elif [[ "$diff_http_code" == "204" ]]; then
        # 204 No Content means schemas are identical - no changes needed
        log "✅ Schemas are identical - no changes to apply"
        local skip_schema_apply=true
    else
        log "❌ Schema diff failed (HTTP $diff_http_code)"
        log "Response: $(cat "$diff_response_file" | head -3)"
        rm -f "$diff_response_file"
        return 1
    fi
    
    # Step 2: Apply the diff using the complete diff response
    if [[ "${skip_schema_apply:-false}" != "true" ]]; then
        log "Applying schema changes to $env_name..."
        
        local apply_response_file="/tmp/apply_response_$$"
        local apply_http_code
        
        apply_http_code=$(timeout 30 curl -s -w "%{http_code}" \
            --connect-timeout 15 --max-time 30 \
            -X POST \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d @"$diff_response_file" \
            "$url/schema/apply" \
            -o "$apply_response_file")
        
        if [[ "$apply_http_code" == "200" || "$apply_http_code" == "204" ]]; then
            log "✅ Schema applied to $env_name successfully"
            rm -f "$diff_response_file" "$apply_response_file"
            return 0
        else
            log "❌ Schema apply failed (HTTP $apply_http_code)"
            log "Response: $(cat "$apply_response_file" | head -3)"
            rm -f "$diff_response_file" "$apply_response_file"
            return 1
        fi
    else
        rm -f "$diff_response_file"
        return 0
    fi
}

# Migrate data using database dump/restore
migrate_data() {
    local source_env="$1"
    local target_env="$2"
    
    log_always "🔄 Starting data migration: $source_env → $target_env"
    
    # Get database configuration
    local source_container target_container
    local source_db_name source_db_user source_db_password
    local target_db_name target_db_user target_db_password
    
    source_container=$(get_env_var "$source_env" "DB_CONTAINER")
    target_container=$(get_env_var "$target_env" "DB_CONTAINER")
    
    source_db_name=$(get_env_var "$source_env" "DB_NAME")
    source_db_user=$(get_env_var "$source_env" "DB_USER") 
    source_db_password=$(get_env_var "$source_env" "DB_PASSWORD")
    source_db_name=${source_db_name:-directus}
    source_db_user=${source_db_user:-directus}
    
    target_db_name=$(get_env_var "$target_env" "DB_NAME")
    target_db_user=$(get_env_var "$target_env" "DB_USER")
    target_db_password=$(get_env_var "$target_env" "DB_PASSWORD") 
    target_db_name=${target_db_name:-directus}
    target_db_user=${target_db_user:-directus}
    
    
    log "Using database credentials - Source: $source_db_user@$source_db_name, Target: $target_db_user@$target_db_name"
    
    # Helper function to execute database commands with password support
    exec_db_cmd() {
        local container="$1"
        local db_user="$2" 
        local db_name="$3"
        local db_password="$4"
        shift 4
        local cmd="$*"
        
        if [[ -n "$db_password" ]]; then
            docker exec -e PGPASSWORD="$db_password" "$container" "$cmd" -U "$db_user" -d "$db_name"
        else
            docker exec "$container" "$cmd" -U "$db_user" -d "$db_name"
        fi
    }
    
    # Fallback to DB_HOST if containers not available
    local source_host target_host
    source_host=$(get_env_var "$source_env" "DB_HOST")
    target_host=$(get_env_var "$target_env" "DB_HOST")
    
    if [[ -z "$source_container" && -z "$source_host" ]]; then
        log "❌ Missing database configuration for $source_env"
        log "   Set ${source_env^^}_DB_CONTAINER or ${source_env^^}_DB_HOST"
        return 1
    fi
    
    if [[ -z "$target_container" && -z "$target_host" ]]; then
        log "❌ Missing database configuration for $target_env"
        log "   Set ${target_env^^}_DB_CONTAINER or ${target_env^^}_DB_HOST"
        return 1
    fi
    
    # 🛡️ SAFETY CHECKS
    log "🛡️ Performing data migration safety checks..."
    
    # Check if containers exist and are running
    if [[ -n "$source_container" ]]; then
        if ! docker ps --format "table {{.Names}}" | grep -q "^$source_container$"; then
            log "❌ Source container '$source_container' not found or not running"
            return 1
        fi
        
        # Test database connectivity
        if ! exec_db_cmd "$source_container" "$source_db_user" "$source_db_name" "$source_db_password" psql -c "SELECT 1;" >/dev/null 2>&1; then
            log "❌ Cannot connect to source database in $source_container"
            return 1
        fi
    fi
    
    if [[ -n "$target_container" ]]; then
        if ! docker ps --format "table {{.Names}}" | grep -q "^$target_container$"; then
            log "❌ Target container '$target_container' not found or not running"
            return 1
        fi
        
        # Test database connectivity
        if ! exec_db_cmd "$target_container" "$target_db_user" "$target_db_name" "$target_db_password" psql -c "SELECT 1;" >/dev/null 2>&1; then
            log "❌ Cannot connect to target database in $target_container"
            return 1
        fi
    fi
    
    log "✅ Container and database connectivity checks passed"
    
    # Create backup directory
    mkdir -p ./backups
    
    # Step 1: Create FULL backup of target before any changes (CRITICAL SAFETY)
    log "Creating full backup of target database before migration..."
    local target_backup="./backups/${target_env}_full_backup_${TIMESTAMP}.dump"
    
    if [[ -n "$target_container" ]]; then
        if docker exec "$target_container" pg_dump \
            -U "$target_db_user" \
            -d "$target_db_name" \
            -Fc \
            > "$target_backup" 2>/dev/null; then
            log "✅ Target backup created: $target_backup ($(du -h "$target_backup" | cut -f1))"
        else
            log "❌ CRITICAL: Failed to backup target database"
            log "   Migration aborted for safety"
            return 1
        fi
        
        # Verify backup is valid
        if [[ ! -s "$target_backup" ]]; then
            log "❌ CRITICAL: Target backup is empty"
            log "   Migration aborted for safety"
            return 1
        fi
    fi
    
    # Step 2: Export data from source (excluding system tables)
    log "Exporting data from $source_env (excluding environment-specific tables)..."
    local data_export="./backups/${source_env}_data_export_${TIMESTAMP}.dump"
    
    # System tables to exclude from data migration (preserve target environment)
    local exclude_tables=(
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
    
    # Build exclude flags for pg_dump
    local exclude_flags=""
    for table in "${exclude_tables[@]}"; do
        exclude_flags+=" --exclude-table-data=public.$table"
    done
    
    if [[ -n "$source_container" ]]; then
        if docker exec "$source_container" pg_dump \
            -U "$source_db_user" \
            -d "$source_db_name" \
            --data-only \
            $exclude_flags \
            -Fc \
            > "$data_export" 2>/dev/null; then
            log "✅ Data exported: $data_export ($(du -h "$data_export" | cut -f1))"
        else
            log "❌ Failed to export data from $source_env"
            return 1
        fi
        
        if [[ ! -s "$data_export" ]]; then
            log "❌ Data export is empty"
            return 1
        fi
    else
        log "❌ Direct database host support not implemented yet"
        return 1
    fi
    
    # Step 3: Copy data file to target container and smart table clearing
    log "Preparing target database for import..."
    
    if [[ -n "$target_container" ]]; then
        # Copy the data file to container
        docker cp "$data_export" "$target_container:/tmp/data_import.dump"
        
        # Get list of tables that will be imported (smart clearing)
        log "Analyzing which tables are in the import file..."
        local tables_in_dump=$(docker exec "$target_container" pg_restore --list /tmp/data_import.dump | \
            grep "TABLE DATA" | \
            awk '{print $7}' | \
            sort -u)
        
        if [[ -n "$tables_in_dump" ]]; then
            log "Found $(echo "$tables_in_dump" | wc -l) tables to import"
            log "Clearing only tables that will be imported..."
            
            # Clear only tables that will actually be imported
            echo "$tables_in_dump" | while read -r table; do
                table=$(echo "$table" | xargs)  # trim whitespace
                if [[ -n "$table" ]]; then
                    log "  Clearing table: $table"
                    
                    # Check if table exists
                    local table_exists=$(docker exec "$target_container" psql -U "$target_db_user" -d "$target_db_name" -t \
                        -c "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='$table');" | xargs)
                    
                    if [[ "$table_exists" == "t" ]]; then
                        # Clear table WITHOUT CASCADE to protect system tables
                        docker exec "$target_container" psql -U "$target_db_user" -d "$target_db_name" \
                            -c "TRUNCATE TABLE public.\"$table\" RESTART IDENTITY;" 2>/dev/null || {
                            log "    Truncate failed, trying DELETE"
                            docker exec "$target_container" psql -U "$target_db_user" -d "$target_db_name" \
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
        else
            log "⚠️  No tables found in import file"
        fi
        
        # Step 4: Import data using pg_restore
        log "Importing data to target..."
        
        # Disable foreign key checks to prevent CASCADE issues
        docker exec "$target_container" psql -U "$target_db_user" -d "$target_db_name" -c "SET session_replication_role = replica;"
        
        # Import using pg_restore (more robust than psql)
        if docker exec "$target_container" pg_restore \
            --username="$target_db_user" \
            --dbname="$target_db_name" \
            --data-only \
            --disable-triggers \
            --no-owner \
            /tmp/data_import.dump 2>&1 | tee /tmp/import_log_$$.txt; then
            log "✅ Data import completed successfully"
        else
            # Analyze errors
            local error_count=$(grep -c "ERROR:" /tmp/import_log_$$.txt || echo 0)
            local duplicate_count=$(grep -c "duplicate key value violates unique constraint" /tmp/import_log_$$.txt || echo 0)
            
            if [[ "$error_count" -eq "$duplicate_count" && "$duplicate_count" -gt 0 ]]; then
                log "⚠️  Data import skipped duplicate records (expected if data already exists)"
            else
                log "⚠️  Data import completed with some errors"
                log "   Duplicate key errors: $duplicate_count"
                log "   Other errors: $((error_count - duplicate_count))"
            fi
        fi
        
        # Step 5: Clear user references in content tables (dynamic detection)
        log "Clearing user references in content tables..."
        
        # Get all tables with user references, excluding system tables
        local tables_with_users=$(docker exec "$target_container" psql \
            --username="$target_db_user" \
            --dbname="$target_db_name" \
            --tuples-only \
            --no-align \
            -c "SELECT DISTINCT table_name 
                FROM information_schema.columns 
                WHERE table_schema = 'public' 
                AND column_name IN ('user_created', 'user_updated')
                AND table_name NOT IN (
                    'directus_users', 'directus_sessions', 'directus_settings',
                    'directus_activity', 'directus_notifications', 'directus_permissions',
                    'directus_presets', 'directus_revisions', 'directus_shares',
                    'directus_webhooks', 'directus_flows', 'directus_operations',
                    'directus_panels', 'directus_dashboards', 'directus_folders',
                    'directus_files', 'directus_versions', 'directus_access',
                    'directus_migrations', 'directus_extensions', 'directus_policies',
                    'directus_collections', 'directus_fields', 'directus_relations',
                    'directus_translations', 'directus_comments'
                );" 2>/dev/null)
        
        if [[ -n "$tables_with_users" ]]; then
            log "Found $(echo "$tables_with_users" | wc -l) content tables with user references"
            
            echo "$tables_with_users" | while read -r table; do
                if [[ -n "$table" ]]; then
                    log "  Clearing user references in: $table"
                    docker exec "$target_container" psql -U "$target_db_user" -d "$target_db_name" \
                        -c "UPDATE public.\"$table\" SET 
                            user_created = NULL, 
                            user_updated = NULL 
                            WHERE user_created IS NOT NULL 
                            OR user_updated IS NOT NULL;" 2>/dev/null || true
                fi
            done
            
            log "✅ User references cleared in content tables"
        else
            log "No content tables with user references found"
        fi
        
        # Re-enable foreign key checks
        docker exec "$target_container" psql -U "$target_db_user" -d "$target_db_name" -c "SET session_replication_role = DEFAULT;"
        log "✅ Foreign key checks re-enabled"
        
        # Cleanup temp files
        docker exec "$target_container" rm -f /tmp/data_import.dump
        rm -f /tmp/import_log_$$.txt
        
    else
        log "❌ Direct database host support not implemented yet"
        return 1
    fi
    
    # Cleanup export file
    rm -f "$data_export"
    
    # 🔍 FINAL VALIDATION
    log "🔍 Performing final validation..."
    local final_user_count=$(docker exec "$target_container" psql -U "$target_db_user" -d "$target_db_name" -t -c "SELECT COUNT(*) FROM directus_users;" 2>/dev/null | xargs)
    local final_settings_count=$(docker exec "$target_container" psql -U "$target_db_user" -d "$target_db_name" -t -c "SELECT COUNT(*) FROM directus_settings;" 2>/dev/null | xargs)
    
    if [[ "$final_user_count" -eq 0 ]]; then
        log "❌ CRITICAL ERROR: All users were deleted during migration!"
        log "❌ Please restore from backup: $target_backup"
        log "   docker exec $target_container pg_restore -U $target_db_user -d $target_db_name --clean $target_backup"
        return 1
    fi
    
    if [[ "$final_settings_count" -eq 0 ]]; then
        log "⚠️  WARNING: Settings were cleared during migration"
        log "   You may want to restore from backup: $target_backup"
    fi
    
    log_always "✅ Final validation passed - Users: $final_user_count, Settings: $final_settings_count"
    log_always "🎉 Data migration completed successfully!"
    log_always "📁 Backup available at: $target_backup"
    
    return 0
}

# Main migration function
run_migration() {
    log_always "🚀 Starting migration: $SOURCE_ENV → $TARGET_ENV ($MIGRATION_TYPE)"
    
    # Create directories
    mkdir -p ./schema-snapshots ./backups
    
    # Validate environments
    if ! validate_env "$SOURCE_ENV"; then
        log "❌ Source environment validation failed"
        exit 1
    fi
    
    if ! validate_env "$TARGET_ENV"; then
        log "❌ Target environment validation failed"
        exit 1
    fi
    
    # Test connections
    if ! test_api "$SOURCE_ENV"; then
        log "❌ Source environment connection failed"
        exit 1
    fi
    
    if ! test_api "$TARGET_ENV"; then
        log "❌ Target environment connection failed"
        exit 1
    fi
    
    # Check permissions
    if ! check_permissions "$SOURCE_ENV"; then
        log "❌ Source environment permissions check failed"
        exit 1
    fi
    
    if ! check_permissions "$TARGET_ENV"; then
        log "❌ Target environment permissions check failed"
        exit 1
    fi
    
    log_always "✅ Pre-flight checks passed"
    
    # Create and apply schema
    local schema_file="./schema-snapshots/${SOURCE_ENV}_to_${TARGET_ENV}_${TIMESTAMP}.json"
    
    if ! create_snapshot "$SOURCE_ENV" "$schema_file"; then
        log "❌ Failed to create schema snapshot"
        exit 1
    fi
    
    if ! apply_schema "$TARGET_ENV" "$schema_file"; then
        log "❌ Failed to apply schema"
        exit 1
    fi
    
    # Handle full migration (data transfer)
    if [[ "$MIGRATION_TYPE" == "full" ]]; then
        migrate_data "$SOURCE_ENV" "$TARGET_ENV"
    fi
    
    log_always "🎉 Migration completed successfully!"
}

# Parse arguments
case "${1:-help}" in
    help|--help|-h|"")
        show_help
        exit 0
        ;;
    *)
        if [[ -z "$SOURCE_ENV" || -z "$TARGET_ENV" ]]; then
            echo "Error: Missing required arguments"
            echo ""
            show_help
            exit 1
        fi
        
        if [[ "$SOURCE_ENV" == "$TARGET_ENV" ]]; then
            echo "Error: Source and target environments cannot be the same"
            exit 1
        fi
        
        # Parse additional flags from all arguments
        args=("$@")
        for ((i=2; i<${#args[@]}; i++)); do
            case "${args[i]}" in
                --full)
                    MIGRATION_TYPE="full"
                    ;;
                --quiet)
                    VERBOSE=false
                    ;;
                --verbose)
                    VERBOSE=true
                    ;;
                *)
                    echo "Unknown option: ${args[i]}"
                    show_help
                    exit 1
                    ;;
            esac
        done
        
        # Debug: Show parsed options
        if [[ "$VERBOSE" == "true" ]]; then
            echo "Migration type: $MIGRATION_TYPE"
            echo "Verbose mode: $VERBOSE"
        fi
        
        # Load environment file if it exists (try both .env and .env.directus)
        if [[ -f ".env.directus" ]]; then
            set -a  # automatically export all variables
            source .env.directus
            set +a
        elif [[ -f ".env" ]]; then
            set -a  # automatically export all variables
            source .env
            set +a
        else
            echo "ERROR: No environment file found. Create .env or .env.directus with your configuration."
            echo "See example.env for the required format."
            exit 1
        fi
        
        run_migration
        ;;
esac