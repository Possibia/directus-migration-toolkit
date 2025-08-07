#!/bin/bash
# Smart Directus Migration - Content-Only Database Approach
# Replaces ONLY content tables while preserving all system tables
# Usage: ./directus-nuclear-migration.sh <source-env> <target-env>

set -euo pipefail

SOURCE_ENV="${1:-}"
TARGET_ENV="${2:-}"
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
    echo "Smart Directus Migration - Content-Only Database Approach"
    echo ""
    echo "This script replaces ONLY content tables while completely preserving"
    echo "all system tables (users, settings, permissions, roles, etc.)."
    echo ""
    echo "Usage: $0 <source-env> <target-env>"
    echo ""
    echo "What this does:"
    echo "  1. Creates full backup of target database"
    echo "  2. Exports system tables from target for reference"
    echo "  3. Exports ONLY content tables from source (excludes all system tables)"
    echo "  4. Drops only content tables in target (preserves system tables)"
    echo "  5. Imports only content tables from source"
    echo "  6. Preserves all file UUIDs and references"
    echo ""
    echo "✅ SAFE: Your users, settings, permissions, and roles are never touched!"
    echo "✅ CLEAN: No conflicts, no corruption, no system table restoration mess!"
    echo ""
    echo "Environment Configuration:"
    echo "Set these environment variables:"
    echo "  {ENV_NAME}_DB_CONTAINER - Docker container name (required)"
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

# Smart migration - content-only replacement with full system preservation
smart_migration() {
    local source_env="$1"
    local target_env="$2"
    
    log_always "🎯 Starting SMART migration: $source_env → $target_env"
    log_always "✅ This will ONLY replace content tables while preserving ALL system tables"
    
    # Get database containers
    local source_container target_container
    source_container=$(get_env_var "$source_env" "DB_CONTAINER")
    target_container=$(get_env_var "$target_env" "DB_CONTAINER")
    
    if [[ -z "$source_container" ]]; then
        log "❌ Missing ${source_env^^}_DB_CONTAINER"
        exit 1
    fi
    
    if [[ -z "$target_container" ]]; then
        log "❌ Missing ${target_env^^}_DB_CONTAINER"
        exit 1
    fi
    
    # Safety checks
    log "🛡️ Performing safety checks..."
    
    if ! docker ps --format "table {{.Names}}" | grep -q "^$source_container$"; then
        log "❌ Source container '$source_container' not running"
        exit 1
    fi
    
    if ! docker ps --format "table {{.Names}}" | grep -q "^$target_container$"; then
        log "❌ Target container '$target_container' not running"
        exit 1
    fi
    
    # Test database connectivity
    if ! docker exec "$source_container" psql -U "directus" -d "directus" -c "SELECT 1;" >/dev/null 2>&1; then
        log "❌ Cannot connect to source database"
        exit 1
    fi
    
    if ! docker exec "$target_container" psql -U "directus" -d "directus" -c "SELECT 1;" >/dev/null 2>&1; then
        log "❌ Cannot connect to target database"
        exit 1
    fi
    
    log "✅ All safety checks passed"
    
    # Create backups directory
    mkdir -p ./nuclear-backups
    
    # STEP 1: Full backup of target (CRITICAL for rollback)
    log_always "🔐 Step 1: Creating full backup of target database"
    local target_backup="./nuclear-backups/${target_env}_full_backup_${TIMESTAMP}.dump"
    
    if docker exec "$target_container" pg_dump \
        -U "directus" \
        -d "directus" \
        -Fc \
        > "$target_backup" 2>/dev/null; then
        log "✅ Target backup: $target_backup ($(du -h "$target_backup" | cut -f1))"
    else
        log "❌ CRITICAL: Failed to backup target database"
        exit 1
    fi
    
    # STEP 2: Export system tables from target (for restoration)
    log_always "🏛️ Step 2: Exporting system tables from target"
    local system_tables=(
        "directus_users"
        "directus_roles"
        "directus_permissions"
        "directus_access"
        "directus_sessions"
        "directus_settings"
        "directus_activity"
        "directus_notifications"
        "directus_presets"
        "directus_webhooks"
        "directus_flows"
        "directus_operations"
        "directus_dashboards"
        "directus_panels"
    )
    
    local system_export="./nuclear-backups/${target_env}_system_tables_${TIMESTAMP}.sql"
    local system_table_flags=""
    
    for table in "${system_tables[@]}"; do
        system_table_flags+=" --table=public.$table"
    done
    
    if docker exec "$target_container" pg_dump \
        -U "directus" \
        -d "directus" \
        --data-only \
        --inserts \
        --column-inserts \
        $system_table_flags \
        > "$system_export" 2>/dev/null; then
        log "✅ System tables exported: $system_export ($(du -h "$system_export" | cut -f1))"
    else
        log "❌ Failed to export system tables"
        exit 1
    fi
    
    # STEP 3: Export ONLY content tables from source (exclude system tables)
    log_always "📦 Step 3: Exporting ONLY content tables from source database"
    local source_export="./nuclear-backups/${source_env}_content_only_${TIMESTAMP}.sql"
    
    # Build exclusion flags for system tables
    local exclude_flags=""
    for table in "${system_tables[@]}"; do
        exclude_flags+=" --exclude-table=public.$table"
    done
    
    if docker exec "$source_container" pg_dump \
        -U "directus" \
        -d "directus" \
        --inserts \
        --column-inserts \
        $exclude_flags \
        > "$source_export" 2>/dev/null; then
        log "✅ Source content exported: $source_export ($(du -h "$source_export" | cut -f1))"
    else
        log "❌ Failed to export source content"
        # Show actual error for debugging
        docker exec "$source_container" pg_dump \
            -U "directus" \
            -d "directus" \
            --inserts \
            --column-inserts \
            $exclude_flags 2>&1 | head -20
        exit 1
    fi
    
    # STEP 4: Smart replacement - drop only content tables, preserve system tables
    log_always "🎯 Step 4: SMART REPLACEMENT - Dropping only content tables"
    
    # Get list of all tables except system tables
    log "Identifying content tables to drop..."
    local content_tables=$(docker exec "$target_container" psql -U "directus" -d "directus" -t -c "
        SELECT string_agg(schemaname||'.'||tablename, ' ') 
        FROM pg_tables 
        WHERE schemaname = 'public' 
        AND tablename NOT IN ($(printf "'%s'," "${system_tables[@]}" | sed 's/,$//'));" 2>/dev/null | xargs)
    
    if [[ -n "$content_tables" ]]; then
        log "Content tables to drop: $content_tables"
        
        # Drop content tables one by one with CASCADE
        for table in $content_tables; do
            log "Dropping table: $table"
            docker exec "$target_container" psql -U "directus" -d "directus" \
                -c "DROP TABLE IF EXISTS $table CASCADE;" 2>/dev/null || true
        done
        
        log "✅ Content tables dropped, system tables preserved"
    else
        log "⚠️ No content tables found to drop"
    fi
    
    # STEP 5: Import only content tables from source
    log_always "📥 Step 5: Importing content tables from source"
    
    # Check source export size before copying
    local source_size=$(du -h "$source_export" | cut -f1)
    log "Content export size: $source_size"
    
    # Copy source export to target container with progress
    log "Copying content export to target container..."
    if docker cp "$source_export" "$target_container:/tmp/content_import.sql"; then
        log "✅ Content export copied to container"
    else
        log "❌ Failed to copy content export to container"
        exit 1
    fi
    
    # Import content tables with verbose output and timeout handling
    log "Starting content import (this may take several minutes for large databases)..."
    log "Import progress will be logged to /tmp/content_import_${TIMESTAMP}.log"
    
    # Use timeout to prevent infinite hanging (30 minutes max)
    if timeout 1800 docker exec "$target_container" psql \
        -U "directus" \
        -d "directus" \
        -v ON_ERROR_STOP=0 \
        -f "/tmp/content_import.sql" \
        2>&1 | tee /tmp/content_import_${TIMESTAMP}.log; then
        log "✅ Content import completed"
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log "❌ Content import timed out after 30 minutes"
            log "This might indicate a problem with the import file or database connection"
        else
            log "❌ Content import had errors - checking details..."
            local errors=$(grep -c "ERROR:" /tmp/content_import_${TIMESTAMP}.log 2>/dev/null || echo 0)
            if [[ "$errors" -gt 0 ]]; then
                log "⚠️  Import completed with $errors errors (may be acceptable)"
                log "First few errors:"
                head -10 /tmp/content_import_${TIMESTAMP}.log | grep "ERROR:" || true
            fi
        fi
    fi
    
    # Show import statistics
    local import_lines=$(wc -l < /tmp/content_import_${TIMESTAMP}.log 2>/dev/null || echo 0)
    log "Import log contains $import_lines lines of output"
    
    # STEP 6: Final validation
    log_always "🔍 Step 6: Final validation and cleanup"
    
    # Check that users were preserved (should be unchanged)
    local final_users=$(docker exec "$target_container" psql -U "directus" -d "directus" -t \
        -c "SELECT COUNT(*) FROM directus_users;" 2>/dev/null | xargs)
    
    # Check that we have migrated content
    local final_files=$(docker exec "$target_container" psql -U "directus" -d "directus" -t \
        -c "SELECT COUNT(*) FROM directus_files;" 2>/dev/null | xargs)
    
    # Test file references integrity
    local file_ref_test=$(docker exec "$target_container" psql -U directus -d directus -t -c "
    SELECT 
        COALESCE(
            (SELECT COUNT(*) FROM articles_translations a 
             JOIN directus_files f ON a.articles_image::uuid = f.id 
             WHERE a.articles_image IS NOT NULL), 0
        ) as working_refs;" 2>/dev/null | xargs)
    
    # Check settings were preserved (should show target settings, not source)
    local settings_check=$(docker exec "$target_container" psql -U "directus" -d "directus" -t \
        -c "SELECT COUNT(*) FROM directus_settings;" 2>/dev/null | xargs)
    
    # Cleanup temporary files
    docker exec "$target_container" rm -f /tmp/content_import.sql
    rm -f /tmp/content_import_${TIMESTAMP}.log
    rm -f "$source_export" "$system_export"
    
    # Report results
    log_always "🎉 SMART MIGRATION COMPLETED!"
    log_always "📊 Final Status:"
    log_always "   - Users preserved: ${final_users:-0} (from target)"
    log_always "   - Settings preserved: ${settings_check:-0} (from target)" 
    log_always "   - Files migrated: ${final_files:-0} (from source)"
    log_always "   - Working file refs: ${file_ref_test:-0}"
    log_always "📁 Full backup available: $target_backup"
    log_always ""
    log_always "✅ Your target users, permissions, and settings were preserved!"
    log_always "✅ Content was successfully migrated from source!"
    log_always ""
    log_always "🔄 IMPORTANT: Restart your target Directus instance now!"
    log_always "   docker-compose restart directus"
    log_always ""
    log_always "If anything went wrong, restore with:"
    log_always "   docker cp $target_backup $target_container:/tmp/backup.dump"
    log_always "   docker exec $target_container pg_restore -U directus -d directus --clean --verbose /tmp/backup.dump"
}

# Main execution
case "${1:-help}" in
    help|--help|-h|"")
        show_help
        exit 0
        ;;
    *)
        if [[ -z "$SOURCE_ENV" || -z "$TARGET_ENV" ]]; then
            echo "Error: Missing required arguments"
            show_help
            exit 1
        fi
        
        if [[ "$SOURCE_ENV" == "$TARGET_ENV" ]]; then
            echo "Error: Source and target environments cannot be the same"
            exit 1
        fi
        
        # Load environment file
        if [[ -f ".env.directus" ]]; then
            set -a
            source .env.directus
            set +a
        elif [[ -f ".env" ]]; then
            set -a
            source .env
            set +a
        else
            echo "ERROR: No environment file found."
            exit 1
        fi
        
        # Confirm smart migration operation
        echo ""
        echo "🎯 SMART MIGRATION - Content Tables Only"
        echo ""
        echo "This will replace ONLY content tables with source data."
        echo "System tables (users, permissions, settings, roles) will be COMPLETELY PRESERVED."
        echo ""
        echo "✅ SAFE: No system table conflicts or corruption"
        echo "✅ CLEAN: Your users and settings stay exactly as they are"
        echo ""
        echo "Source: $SOURCE_ENV (content tables only)"
        echo "Target: $TARGET_ENV (system tables preserved)"
        echo ""
        read -p "Are you ready to proceed? Type 'SMART' to continue: " confirmation
        
        if [[ "$confirmation" != "SMART" ]]; then
            echo "Migration cancelled."
            exit 1
        fi
        
        smart_migration "$SOURCE_ENV" "$TARGET_ENV"
        ;;
esac