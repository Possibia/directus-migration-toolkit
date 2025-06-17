#!/bin/bash
# API-Only Directus Migration (No CLI dependencies, works with Docker)

set -euo pipefail

MIGRATION_PATH="${1:-help}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TIMEOUT_SECONDS=60

# Load environment
source .env.directus || { echo "ERROR: .env.directus not found"; exit 1; }

# Create directories
mkdir -p ./schema-snapshots ./backups ./env_backups

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

# Check token permissions
check_permissions() {
    local env_name="$1"
    local url="$2"
    local token="$3"
    
    log "Checking $env_name permissions..."
    
    # Test schema access - Use Bearer header (recommended method)
    local response=$(timeout $TIMEOUT_SECONDS curl -s -w "%{http_code}" \
        --connect-timeout 15 --max-time $TIMEOUT_SECONDS \
        -H "Authorization: Bearer $token" \
        "$url/schema/snapshot" -o /dev/null)
    
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
    local url="$2"
    local token="$3"
    local output_file="$4"
    
    log "Creating schema snapshot from $env_name..."
    
    # Try API call with proper error handling - Use Bearer header (recommended)
    local temp_file="${output_file}.tmp"
    local http_code
    
    http_code=$(timeout $TIMEOUT_SECONDS curl -s -w "%{http_code}" \
        --connect-timeout 15 --max-time $TIMEOUT_SECONDS \
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

# Apply schema via API using diff/apply approach (same as full migration)
apply_schema() {
    local env_name="$1"
    local url="$2"
    local token="$3"
    local snapshot_file="$4"
    
    log "Applying schema to $env_name using diff/apply..."
    
    # Verify file exists
    if [[ ! -f "$snapshot_file" || ! -s "$snapshot_file" ]]; then
        log "❌ Snapshot file missing: $snapshot_file"
        return 1
    fi
    
    # Step 1: Generate diff between source schema and target's current state
    log "Generating schema diff via API..."
    local diff_payload="/tmp/diff_payload_$$"
    
    # Read the schema file
    local schema_content=$(cat "$snapshot_file")
    
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
        log "Applying schema diff..."
        local apply_response
        apply_response=$(timeout $TIMEOUT_SECONDS curl -s -w "\nHTTP_CODE:%{http_code}" \
            --connect-timeout 15 --max-time $TIMEOUT_SECONDS \
            -X POST \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d @"$diff_response_file" \
            "$url/schema/apply")
        
        local apply_http_code=$(echo "$apply_response" | grep "HTTP_CODE:" | cut -d':' -f2)
        local apply_body=$(echo "$apply_response" | grep -v "HTTP_CODE:")
        
        rm -f "$diff_response_file"
        
        if [[ "$apply_http_code" == "200" || "$apply_http_code" == "204" ]]; then
            log "✅ Schema applied successfully via API"
            return 0
        else
            log "❌ Schema apply failed (HTTP $apply_http_code)"
            log "Response: $(echo "$apply_body" | head -3)"
            return 1
        fi
    else
        log "⏭️  Skipping schema apply - schemas are already identical"
        return 0
    fi
    
}

# Create backup
create_backup() {
    local env_name="$1"
    local url="$2"
    local token="$3"
    
    local backup_file="./backups/${env_name}_backup_${TIMESTAMP}.yaml"
    
    log "Creating backup of $env_name..."
    
    if create_snapshot "$env_name" "$url" "$token" "$backup_file"; then
        log "✅ Backup created: $backup_file"
        echo "$backup_file"
        return 0
    else
        log "❌ Backup failed for $env_name"
        return 1
    fi
}

# Backup environment settings
backup_env_settings() {
    local env_name="$1"
    local url="$2"
    local token="$3"
    
    local env_dir="./env_backups/$env_name"
    mkdir -p "$env_dir"
    
    log "Backing up $env_name environment settings..."
    
    # Backup project settings
    if timeout $TIMEOUT_SECONDS curl -s -f \
        --connect-timeout 15 --max-time $TIMEOUT_SECONDS \
        -H "Authorization: Bearer $token" \
        "$url/settings" > "$env_dir/settings_${TIMESTAMP}.json"; then
        log "✅ Settings backed up"
    else
        log "⚠️  Settings backup failed"
    fi
    
    # List backed up files
    ls -la "$env_dir"/ | tail -n +2 | while read line; do
        log "  📁 $line"
    done
}

# Main migration function
perform_migration() {
    local source_env="$1"
    local source_url="$2" 
    local source_token="$3"
    local target_env="$4"
    local target_url="$5"
    local target_token="$6"
    
    log "=== $source_env to $target_env Schema Migration ==="
    
    # Step 1: Test connections
    test_api "$source_env" "$source_url" "$source_token" || exit 1
    test_api "$target_env" "$target_url" "$target_token" || exit 1
    
    # 🔍 DEBUG: Schema-only migration - preserves all environment data
    log "🔍 DEBUG: Schema-only migration starting - all user data will be preserved"
    
    # Step 2: Check permissions
    check_permissions "$source_env" "$source_url" "$source_token" || exit 1
    check_permissions "$target_env" "$target_url" "$target_token" || exit 1
    
    # Step 3: Backup target environment
    backup_env_settings "$target_env" "$target_url" "$target_token"
    
    # Step 4: Create backup
    local backup_file
    if backup_file=$(create_backup "$target_env" "$target_url" "$target_token"); then
        log "✅ Backup completed: $backup_file"
    else
        log "❌ Backup failed - ABORTING for safety"
        exit 1
    fi
    
    # Step 5: Create snapshot from source
    local snapshot_file="./schema-snapshots/${source_env}_to_${target_env}_${TIMESTAMP}.yaml"
    if create_snapshot "$source_env" "$source_url" "$source_token" "$snapshot_file"; then
        log "✅ Source snapshot created"
    else
        log "❌ Source snapshot failed - ABORTING"
        exit 1
    fi
    
    # Step 6: Apply to target
    if apply_schema "$target_env" "$target_url" "$target_token" "$snapshot_file"; then
        log "✅ Migration successful!"
    else
        log "❌ Migration failed"
        log "🔄 Restore from backup: $backup_file"
        exit 1
    fi
    
    log "🎉 Migration completed successfully!"
    log "📁 Backup: $backup_file"
    log "📁 Snapshot: $snapshot_file"
    log ""
    log "What was migrated:"
    log "  ✅ Database schema (collections, fields, relations)"
    log "  ✅ Directus metadata (permissions, displays)"
    log ""
    log "What was preserved:"
    log "  ✅ All content data"
    log "  ✅ Project title and settings"
    log "  ✅ User accounts and tokens"
    log "  ✅ Environment-specific configurations"
}

# Main execution
case "$MIGRATION_PATH" in
    "stage-to-dev")
        perform_migration \
            "stage" "$STAGE_DIRECTUS_URL" "$STAGE_DIRECTUS_TOKEN" \
            "dev" "$DEV_DIRECTUS_URL" "$DEV_DIRECTUS_TOKEN"
        ;;
        
    "stage-to-prod")
        perform_migration \
            "stage" "$STAGE_DIRECTUS_URL" "$STAGE_DIRECTUS_TOKEN" \
            "prod" "$PROD_DIRECTUS_URL" "$PROD_DIRECTUS_TOKEN"
        ;;
        
    "dev-to-stage")
        perform_migration \
            "dev" "$DEV_DIRECTUS_URL" "$DEV_DIRECTUS_TOKEN" \
            "stage" "$STAGE_DIRECTUS_URL" "$STAGE_DIRECTUS_TOKEN"
        ;;
        
    "dev-to-prod")
        perform_migration \
            "dev" "$DEV_DIRECTUS_URL" "$DEV_DIRECTUS_TOKEN" \
            "prod" "$PROD_DIRECTUS_URL" "$PROD_DIRECTUS_TOKEN"
        ;;
        
    "prod-to-dev")
        perform_migration \
            "prod" "$PROD_DIRECTUS_URL" "$PROD_DIRECTUS_TOKEN" \
            "dev" "$DEV_DIRECTUS_URL" "$DEV_DIRECTUS_TOKEN"
        ;;
        
    "prod-to-stage")
        perform_migration \
            "prod" "$PROD_DIRECTUS_URL" "$PROD_DIRECTUS_TOKEN" \
            "stage" "$STAGE_DIRECTUS_URL" "$STAGE_DIRECTUS_TOKEN"
        ;;
        
    "edit-to-dev")
        perform_migration \
            "edit" "$EDIT_DIRECTUS_URL" "$EDIT_DIRECTUS_TOKEN" \
            "dev" "$DEV_DIRECTUS_URL" "$DEV_DIRECTUS_TOKEN"
        ;;
        
    "edit-to-stage")
        perform_migration \
            "edit" "$EDIT_DIRECTUS_URL" "$EDIT_DIRECTUS_TOKEN" \
            "stage" "$STAGE_DIRECTUS_URL" "$STAGE_DIRECTUS_TOKEN"
        ;;
        
    "edit-to-prod")
        perform_migration \
            "edit" "$EDIT_DIRECTUS_URL" "$EDIT_DIRECTUS_TOKEN" \
            "prod" "$PROD_DIRECTUS_URL" "$PROD_DIRECTUS_TOKEN"
        ;;
        
    *)
        echo "Usage: $0 [stage-to-dev|stage-to-prod|dev-to-stage|dev-to-prod|prod-to-dev|prod-to-stage|edit-to-dev|edit-to-stage|edit-to-prod]"
        echo ""
        echo "Pure API-based schema migration that:"
        echo "  ✅ Works with Docker-hosted Directus"
        echo "  ✅ No DB_CLIENT dependency"
        echo "  ✅ Tests permissions before migration"
        echo "  ✅ Creates automatic backups"
        echo "  ✅ Preserves environment data"
        echo ""
        echo "Requirements:"
        echo "  - Static admin tokens in .env.directus"
        echo "  - Network access to Directus APIs"
        exit 1
        ;;
esac