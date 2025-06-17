# Directus Migration Toolkit

A production-ready toolkit for safely migrating self-hosted Directus instances running on Docker between environments (dev, stage, prod) with comprehensive safety features and environment preservation.

## 📋 Requirements

- Self-hosted Directus instances
- Docker containers for database access
- Administrative API tokens for each environment

## 🎯 Overview

This toolkit provides bulletproof migration scripts that handle both schema-only and full content migrations between Directus environments while preserving critical environment-specific data like users, settings, and configurations.

## 🛠️ Migration Scripts

### Schema-Only Migration
```bash
./directus-api-migration.sh <source>-to-<target>
```
- Migrates database schema (collections, fields, relationships)
- Preserves ALL existing data, users, and settings
- API-only approach (no direct database access needed)

### Full Migration
```bash
./directus-api-full-migration.sh <source>-to-<target>
```
- Migrates schema changes via API
- Migrates content data via database dump/restore
- Preserves users, settings, and environment configuration
- Includes automatic backups and safety validation

## 🌐 Supported Environment Combinations

- `dev-to-stage` - Development to staging
- `stage-to-prod` - Staging to production (deployment)
- `stage-to-dev` - Pull staging content to development
- `edit-to-stage` - Content editing workflow
- `prod-to-dev` - Copy production to development
- And all other combinations

## ⚙️ Setup

1. Copy and configure environment variables:
```bash
cp env.directus .env.directus
```

2. Update `.env.directus` with your environment details:
```bash
# Environment URLs
DEV_DIRECTUS_URL=https://dev.example.com
STAGE_DIRECTUS_URL=https://stage.example.com
PROD_DIRECTUS_URL=https://prod.example.com

# Static Admin Tokens
DEV_DIRECTUS_TOKEN=your-dev-token
STAGE_DIRECTUS_TOKEN=your-stage-token
PROD_DIRECTUS_TOKEN=your-prod-token

# Database Configuration
DB_USER=directus
DB_NAME=directus

# Docker Container Names
DEV_DB_CONTAINER_NAME=your-dev-container
STAGE_DB_CONTAINER_NAME=your-stage-container
PROD_DB_CONTAINER_NAME=your-prod-container
```

## 🚀 Quick Start

Deploy schema changes to production:
```bash
./directus-api-migration.sh stage-to-prod
```

Full content migration from staging to development:
```bash
./directus-api-full-migration.sh stage-to-dev
```

## 🛡️ Safety Features

- **Automatic Backups** - Full database backup before any migration
- **CASCADE Protection** - Fixed critical truncation issues
- **Environment Isolation** - Preserves users, settings, and configurations per environment
- **Pre-flight Validation** - API connectivity and permission checks
- **Post-migration Verification** - User count and system integrity validation
- **Error Recovery** - Clear restoration instructions if issues occur

## 📋 What Gets Preserved

The migration scripts preserve environment-specific data:
- User accounts and authentication
- Project settings (title, colors, branding)
- API tokens and static tokens
- Webhooks and environment-specific URLs
- Flows and operations
- User sessions and access controls
- Permissions and roles
- File uploads and organization

## 📚 Documentation

- [Migration Guide](MIGRATION_GUIDE.md) - Comprehensive guide with all features and troubleshooting
- [Quick Start](QUICK_START.md) - Essential commands for daily usage

## 🔧 Utilities

- `diagnose-schema-auth.sh` - Diagnose schema and authentication issues
- `directus-env-preserve.sh` - Environment preservation utilities

## ⚠️ Important Notes

- The edit environment may share containers with production
- Always test migrations on development first
- Use schema-only migrations for structure changes
- Use full migrations for content deployment
- Monitor logs during migration for any issues

## 🎯 Best Practices

1. Always backup production before migrations
2. Test on development environment first
3. Use schema-only for structural changes
4. Use full migration for content deployment
5. Validate user count after migration (should be > 0)
6. Test target environment functionality post-migration

---

**Status**: Production-tested with comprehensive safety measures and full environment support.