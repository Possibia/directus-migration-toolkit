#!/bin/bash
set -euo pipefail

# Script to preserve and restore environment-specific Directus data
# Usage: ./directus-env-preserve.sh [backup|restore] <container_name> <db_user> <db_name> <backup_dir>

ACTION="$1"
CONTAINER_NAME="$2"
DB_USER="$3"
DB_NAME="$4"
BACKUP_DIR="${5:-./env_backups}"

mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] - $1"
}

backup_env_data() {
    log "Backing up environment-specific data from $CONTAINER_NAME"
    
    # 1. Backup directus_settings (preserves title, description, custom CSS, etc.)
    log "Backing up project settings..."
    sudo docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "\
        COPY directus_settings TO STDOUT WITH (FORMAT CSV, HEADER);" \
        > "$BACKUP_DIR/settings_${TIMESTAMP}.csv"
    
    # 2. Backup user tokens and auth data
    log "Backing up user authentication data..."
    sudo docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "\
        COPY (SELECT id, email, token, tfa_secret, external_identifier, provider \
        FROM directus_users WHERE token IS NOT NULL OR tfa_secret IS NOT NULL) \
        TO STDOUT WITH (FORMAT CSV, HEADER);" \
        > "$BACKUP_DIR/user_auth_${TIMESTAMP}.csv"
    
    # 3. Backup webhooks (environment-specific URLs)
    log "Backing up webhooks..."
    sudo docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "\
        COPY directus_webhooks TO STDOUT WITH (FORMAT CSV, HEADER);" \
        > "$BACKUP_DIR/webhooks_${TIMESTAMP}.csv"
    
    # 4. Backup flows and operations (may contain API keys)
    log "Backing up flows..."
    sudo docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "\
        COPY directus_flows TO STDOUT WITH (FORMAT CSV, HEADER);" \
        > "$BACKUP_DIR/flows_${TIMESTAMP}.csv"
    
    sudo docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "\
        COPY directus_operations TO STDOUT WITH (FORMAT CSV, HEADER);" \
        > "$BACKUP_DIR/operations_${TIMESTAMP}.csv"
    
    # 5. Backup environment-specific permissions
    log "Backing up custom permissions..."
    sudo docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "\
        COPY directus_permissions TO STDOUT WITH (FORMAT CSV, HEADER);" \
        > "$BACKUP_DIR/permissions_${TIMESTAMP}.csv"
    
    # Create manifest file
    cat > "$BACKUP_DIR/manifest_${TIMESTAMP}.json" << EOF
{
    "timestamp": "$TIMESTAMP",
    "container": "$CONTAINER_NAME",
    "database": "$DB_NAME",
    "files": {
        "settings": "settings_${TIMESTAMP}.csv",
        "user_auth": "user_auth_${TIMESTAMP}.csv",
        "webhooks": "webhooks_${TIMESTAMP}.csv",
        "flows": "flows_${TIMESTAMP}.csv",
        "operations": "operations_${TIMESTAMP}.csv",
        "permissions": "permissions_${TIMESTAMP}.csv"
    }
}
EOF
    
    log "Environment backup completed. Manifest: $BACKUP_DIR/manifest_${TIMESTAMP}.json"
}

restore_env_data() {
    # Find the latest manifest or use specific timestamp
    RESTORE_TIMESTAMP="${RESTORE_TIMESTAMP:-$(ls -t "$BACKUP_DIR"/manifest_*.json 2>/dev/null | head -1 | grep -oP '\d{8}_\d{6}' || echo '')}"
    
    if [[ -z "$RESTORE_TIMESTAMP" ]]; then
        log "ERROR: No backup found to restore"
        exit 1
    fi
    
    log "Restoring environment data from timestamp: $RESTORE_TIMESTAMP"
    
    # 1. Restore settings (this preserves your title, description, etc.)
    if [[ -f "$BACKUP_DIR/settings_${RESTORE_TIMESTAMP}.csv" ]]; then
        log "Restoring project settings..."
        
        # Create temp table and restore
        sudo docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" << EOF
-- Backup current settings just in case
CREATE TABLE IF NOT EXISTS directus_settings_backup AS SELECT * FROM directus_settings;

-- Clear and restore settings
TRUNCATE directus_settings;
\COPY directus_settings FROM STDIN WITH (FORMAT CSV, HEADER)
EOF
        cat "$BACKUP_DIR/settings_${RESTORE_TIMESTAMP}.csv" | sudo docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME"
    fi
    
    # 2. Restore user auth data
    if [[ -f "$BACKUP_DIR/user_auth_${RESTORE_TIMESTAMP}.csv" ]]; then
        log "Restoring user authentication..."
        
        sudo docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" << 'EOF'
CREATE TEMP TABLE temp_user_auth (
    id uuid,
    email varchar(255),
    token varchar(255),
    tfa_secret varchar(255),
    external_identifier varchar(255),
    provider varchar(128)
);
\COPY temp_user_auth FROM STDIN WITH (FORMAT CSV, HEADER)
EOF
        cat "$BACKUP_DIR/user_auth_${RESTORE_TIMESTAMP}.csv" | sudo docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME"
        
        sudo docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "\
            UPDATE directus_users u SET \
                token = COALESCE(t.token, u.token), \
                tfa_secret = COALESCE(t.tfa_secret, u.tfa_secret), \
                external_identifier = COALESCE(t.external_identifier, u.external_identifier) \
            FROM temp_user_auth t WHERE u.id = t.id;"
    fi
    
    # 3. Restore webhooks
    if [[ -f "$BACKUP_DIR/webhooks_${RESTORE_TIMESTAMP}.csv" ]]; then
        log "Restoring webhooks..."
        sudo docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" << EOF
TRUNCATE directus_webhooks;
\COPY directus_webhooks FROM STDIN WITH (FORMAT CSV, HEADER)
EOF
        cat "$BACKUP_DIR/webhooks_${RESTORE_TIMESTAMP}.csv" | sudo docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME"
    fi
    
    log "Environment restoration completed"
}

# Main execution
case "$ACTION" in
    "backup")
        backup_env_data
        ;;
    "restore")
        restore_env_data
        ;;
    *)
        echo "Usage: $0 [backup|restore] <container_name> <db_user> <db_name> [backup_dir]"
        exit 1
        ;;
esac