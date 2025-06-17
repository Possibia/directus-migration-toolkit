# Directus Migration System Guide

## ✅ Production-Ready Migration Scripts

After extensive debugging and testing, we have bulletproof migration scripts that safely handle all environment combinations.

### 🛡️ Key Safety Features

1. **CASCADE Protection** - Fixed the critical `TRUNCATE CASCADE` issue that was deleting users
2. **Comprehensive Debugging** - Full logging at every step to catch issues early
3. **Safety Validation** - Pre-flight checks and post-migration validation
4. **Environment Isolation** - Each environment maintains separate users, settings, and configuration
5. **Automatic Backups** - Full database backup before any migration
6. **Error Recovery** - Clear instructions for restoring from backup if issues occur

## 🔧 Available Scripts

### 1. Schema-Only Migration: `directus-api-migration.sh`
**What it does:**
- ✅ Migrates database schema (collections, fields, relationships)
- ✅ Preserves ALL data, users, and settings
- ✅ Uses API-only approach (no database access needed)

**Use cases:**
- Syncing schema changes between environments
- Safe updates that only affect structure
- When you want to preserve all existing data

### 2. Full Migration: `directus-api-full-migration.sh`
**What it does:**
- ✅ Migrates schema changes via API
- ✅ Migrates content data via database dump/restore
- ✅ Preserves users, settings, and environment configuration
- ✅ Clears user references to prevent conflicts

**Use cases:**
- Complete content migration between environments
- Syncing both structure and content
- When environments should have separate user bases

## 🌐 Supported Environment Combinations

Both scripts support all possible combinations:
- `stage-to-prod` - Deploy to production
- `dev-to-stage` - Push development to staging
- `stage-to-dev` - Pull staging to development
- `dev-to-prod` - Direct dev to prod (use with caution)
- `prod-to-dev` - Copy production to development
- `prod-to-stage` - Copy production to staging
- `edit-to-dev` - Copy edit environment to development
- `edit-to-stage` - Copy edit environment to staging
- `edit-to-prod` - Copy edit environment to production

## 📋 Environment Requirements

### .env.directus Configuration
```bash
# Environment URLs
DEV_DIRECTUS_URL=https://dev.possibia.com
STAGE_DIRECTUS_URL=https://stage.possibia.com
EDIT_DIRECTUS_URL=https://edit.possibia.com
PROD_DIRECTUS_URL=https://prod.possibia.com

# Static Admin Tokens
DEV_DIRECTUS_TOKEN=your-dev-token
STAGE_DIRECTUS_TOKEN=your-stage-token
EDIT_DIRECTUS_TOKEN=your-edit-token
PROD_DIRECTUS_TOKEN=your-prod-token

# Database Configuration
DB_USER=directus
DB_NAME=directus

# Docker Container Names (based on actual docker ps output)
DEV_DB_CONTAINER_NAME=directus-dev-docker-database-1
STAGE_DB_CONTAINER_NAME=directus-stage-docker-database-1
EDIT_DB_CONTAINER_NAME=directus-prod-docker-database-1  # Edit uses prod containers
PROD_DB_CONTAINER_NAME=directus-prod-docker-database-1
```

## 🚀 Usage Examples

### Schema-Only Migration
```bash
# Sync schema from stage to dev (preserves all dev data)
./directus-api-migration.sh stage-to-dev

# Deploy schema changes to production
./directus-api-migration.sh stage-to-prod
```

### Full Migration (Schema + Content)
```bash
# Complete migration from stage to dev
./directus-api-full-migration.sh stage-to-dev

# Deploy to production
./directus-api-full-migration.sh stage-to-prod
```

## 🔍 What Gets Migrated vs Preserved

### Full Migration

**✅ What Gets Migrated:**
- Database schema (collections, fields, relationships)
- Content data (pages, articles, trials, etc.)
- Content structure and relationships

**✅ What Gets Preserved (target environment):**
- ALL user accounts and authentication
- Project settings (title, colors, branding)
- API tokens and static tokens
- Webhooks and environment-specific URLs
- Flows and operations (may contain API keys)
- User sessions and access controls
- Permissions and roles
- File uploads and organization
- User preferences and dashboards

### Schema-Only Migration

**✅ What Gets Migrated:**
- Database schema structure only

**✅ What Gets Preserved (target environment):**
- All of the above PLUS all existing content data

## ⚠️ Important Notes

### Edit/Prod Environment Sharing
**Important:** The edit environment (edit.possibia.com) shares the same Docker containers as production (directus-prod-docker-*). This means:
- `edit-to-prod` and `prod-to-edit` operations affect the same database
- Be extra careful with any edit environment migrations
- Consider edit environment as "production-like" in terms of safety

## ⚠️ Critical Lessons Learned

### The CASCADE Issue
**Problem:** `TRUNCATE TABLE ... CASCADE` was following foreign key relationships backwards and deleting users even though `directus_users` wasn't being truncated directly.

**Solution:** Removed `CASCADE` from all `TRUNCATE` commands and use simple `DELETE` as fallback.

### User Reference Conflicts
**Problem:** Imported content referenced user IDs from source environment that didn't exist in target.

**Solution:** Clear all user references (`user_created`, `user_updated`) to NULL, allowing each environment to maintain separate user bases.

### System Table Exclusions
**Problem:** Need to exclude system tables that contain environment-specific data.

**Solution:** Comprehensive exclusion list of 25+ system tables including users, sessions, settings, permissions, etc.

## 🛡️ Safety Measures

### Pre-Migration Checks
- Container existence verification
- Database connectivity testing
- API endpoint validation
- Permission verification

### During Migration
- Full database backup before starting
- Step-by-step user count monitoring
- Transaction safety with FK disable/re-enable
- Error handling with meaningful messages

### Post-Migration Validation
- User count verification (fails if 0 users)
- Settings count verification
- Automatic backup restoration instructions if issues occur

## 🔧 Troubleshooting

### If Migration Fails
1. Check the logs for the exact step where failure occurred
2. Restore from the automatic backup:
   ```bash
   docker exec [container] pg_restore --username="directus" --dbname="directus" --clean --if-exists [backup-file]
   ```
3. Review the error message and environment configuration
4. Ensure all containers are running and accessible

### Common Issues
- **Container not found**: Update container names in `.env.directus`
- **API connection failed**: Check URLs and tokens
- **Permission denied**: Ensure tokens have schema and admin permissions
- **Database connection failed**: Verify container and database names

## 📈 Migration Matrix

| Source → Target | Schema Only | Full Migration | Notes |
|----------------|-------------|----------------|-------|
| dev → stage | ✅ | ✅ | Common development workflow |
| stage → prod | ✅ | ✅ | Standard deployment |
| stage → dev | ✅ | ✅ | Pull staging content to dev |
| edit → stage | ✅ | ✅ | Content editing workflow |
| edit → prod | ⚠️ | ⚠️ | Use with caution |
| prod → * | ⚠️ | ⚠️ | Always backup first |

## 🎯 Best Practices

1. **Always test migrations on dev first**
2. **Use schema-only for structure changes**
3. **Use full migration for content deployment**
4. **Backup production before any migration**
5. **Monitor logs during migration**
6. **Validate user count after migration**
7. **Test the target environment after migration**

## 🏆 Success Criteria

A successful migration should:
- ✅ Preserve all target environment users (count > 0)
- ✅ Maintain target environment settings and branding
- ✅ Successfully apply schema changes
- ✅ Import content without errors
- ✅ Keep all system configurations intact
- ✅ Allow normal login and operation post-migration

---

**Remember:** These scripts are production-tested and include comprehensive safety measures. The CASCADE issue has been resolved, debugging is comprehensive, and all environment combinations are supported. 🎉