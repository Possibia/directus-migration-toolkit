# 🚀 Quick Start - Directus Migrations

## 1. Setup (One Time)

Update `.env.directus` with your production info:
```bash
# Add your production URL and token
PROD_DIRECTUS_URL=https://prod.possibia.com
PROD_DIRECTUS_TOKEN=your-production-static-token

# Update stage/edit tokens if needed
STAGE_DIRECTUS_TOKEN=your-stage-static-token
EDIT_DIRECTUS_TOKEN=your-edit-static-token
```

Test setup:
```bash
./setup-migration-env.sh
```

## 2. Daily Usage

Load environment:
```bash
source .env.directus
```

### Schema Changes (Most Common)
```bash
# Dev to Stage
./directus-schema-migration.sh dev-to-stage

# Stage to Production  
./directus-schema-migration.sh stage-to-prod
```

### Schema + Content
```bash
# Full migration with environment preservation
./directus-full-migration.sh stage-to-prod
```

### Specific Collections
```bash
# Migrate only certain collections
./directus-selective-migration.sh collections blog_posts products
```

## ✅ Done!

Your production title, tokens, and settings will never be overwritten again.