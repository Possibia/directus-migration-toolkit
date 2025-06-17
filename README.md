# 🚀 Directus Migration Toolkit

**The ultimate migration tool for self-hosted Directus instances**

Migrate between ANY environments with ANY names. From `dev` to `prod`, `potato` to `tomato`, or `staging` to `live` - this toolkit adapts to YOUR setup, not the other way around.

---

## ✨ Why This Tool?

🛡️ **Production-Safe** - Full backups, validation, and recovery  
🧠 **Intelligent** - Auto-detects your schema and handles edge cases  
⚡ **Fast Setup** - Running migrations in under 30 seconds  
🎯 **Flexible** - Schema-only or full data migrations  

---

## 🎬 Quick Demo

```bash
# Copy configuration template
cp example.env .env

# Add your environment details (any names you want!)
nano .env

# Run your first migration
./directus-dynamic-migrate.sh dev prod
```

**That's it!** No complex setup, no hardcoded names, no YAML configs.

---

## 🔄 Migration Types

### **Schema Migration (Default)**
Perfect for deploying structural changes safely.

```bash
./directus-dynamic-migrate.sh dev prod
```

✅ **Migrates**: Collections, fields, relationships  
✅ **Preserves**: ALL existing data, users, settings  
✅ **Safe**: Cannot cause data loss  
✅ **Fast**: API-only, no database operations  

### **Full Migration**
Deploy both structure and content changes.

```bash
./directus-dynamic-migrate.sh dev prod --full
```

✅ **Migrates**: Schema + content data  
✅ **Preserves**: Users, settings, permissions  
✅ **Safety**: Full backup before changes  
✅ **Smart**: Only touches tables being migrated  
✅ **Recovery**: Clear instructions if anything goes wrong  

---

## ⚙️ Setup

### 1. **Configure Your Environments**

```bash
cp example.env .env
```

Edit `.env` with your environment details:

```bash
# Use ANY environment names you want!
DEV_URL=https://dev.yourdomain.com
DEV_TOKEN=your-dev-admin-token
DEV_DB_CONTAINER=dev-directus-db
DEV_DB_NAME=directus

PROD_URL=https://yourdomain.com  
PROD_TOKEN=your-prod-admin-token
PROD_DB_CONTAINER=prod-directus-db
PROD_DB_NAME=directus

# Creative names work too!
POTATO_URL=https://potato.example.com
POTATO_TOKEN=your-potato-token
POTATO_DB_CONTAINER=potato-db-container
POTATO_DB_NAME=directus

BANANA_URL=https://banana.example.com
BANANA_TOKEN=your-banana-token
BANANA_DB_CONTAINER=banana-db-container
BANANA_DB_NAME=directus
```

### 2. **Get Your Admin Tokens**

In Directus Admin → Settings → Project Settings → Security:
- Create a **Static Token** with admin permissions
- Copy the token to your `.env` file

### 3. **Find Your Container Names** (for full migrations)

```bash
docker ps --format "table {{.Names}}\t{{.Image}}"
```

Add container names and database names to `.env`:
```bash
DEV_DB_CONTAINER=your-dev-database-container
DEV_DB_NAME=directus
PROD_DB_CONTAINER=your-prod-database-container
PROD_DB_NAME=directus
```

---

## 🎯 Usage Examples

### **Development Workflow**
```bash
# Deploy schema changes from dev to production
./directus-dynamic-migrate.sh dev prod

# Copy production content to development  
./directus-dynamic-migrate.sh prod dev --full

# Sync staging with development
./directus-dynamic-migrate.sh dev staging --full --quiet
```

### **Content Management**
```bash
# Deploy content from editing environment to live
./directus-dynamic-migrate.sh content-edit live --full

# Sync draft content to published site
./directus-dynamic-migrate.sh draft published --full
```

### **Creative Environment Names**
```bash
# Your imagination is the limit!
./directus-dynamic-migrate.sh experimental stable
./directus-dynamic-migrate.sh v1 v2 --full
./directus-dynamic-migrate.sh internal-cms client-site --full
```

---

## 🛡️ Safety Features

### **Automatic Backups**
Every full migration creates a complete backup:
```
✅ Target backup created: ./backups/prod_full_backup_20240117_143022.dump (45MB)
```

### **Pre-flight Validation**
- Container existence and connectivity
- Database access verification  
- API endpoint and permission testing
- User count monitoring

### **Smart Recovery**
If something goes wrong:
```bash
# Automatic recovery instructions provided
docker exec prod-container pg_restore -U directus -d directus --clean backup_file.dump
```

### **User Reference Protection**
Automatically handles user references across environments:
- Detects tables with `user_created`/`user_updated` fields
- Clears references to prevent foreign key errors
- Preserves all users in target environment

---

## 📊 Output Options

### **Verbose (Default)**
See every step of the migration process:
```bash
./directus-dynamic-migrate.sh dev prod --verbose
```

### **Quiet Mode**  
Minimal output for automated scripts:
```bash
./directus-dynamic-migrate.sh dev prod --quiet
```

---

## 🚨 Requirements

- **Self-hosted Directus** (any version with schema API)
- **Docker containers** (for full data migrations)
- **Admin API tokens** for each environment
- **PostgreSQL database** (MySQL support coming soon)

---

## 🔧 Advanced Usage

### **Environment Variables Pattern**
```bash
# Required for each environment:
{ENV_NAME}_URL         # Directus URL
{ENV_NAME}_TOKEN       # Admin token

# Optional for full migrations:
{ENV_NAME}_DB_CONTAINER # Docker container name
{ENV_NAME}_DB_NAME     # Database name (usually 'directus')
```

### **Help & Options**
```bash
./directus-dynamic-migrate.sh --help
```

Shows all available options and examples based on your configured environments.

---

## ❓ FAQ

**Q: Can I migrate between different Directus versions?**  
A: Yes! The tool uses the schema API which is compatible across versions.

**Q: What if my environments have different user accounts?**  
A: Perfect! The tool preserves users in each environment and handles user references automatically.

**Q: Can I roll back a migration?**  
A: Yes! Every full migration creates a backup with recovery instructions.

**Q: Does it work with custom collections?**  
A: Absolutely! The tool dynamically detects your schema structure.

---

## 🎉 What Makes This Special?

Unlike other migration tools:

🎯 **No Configuration Hell** - Works with your existing setup  
🧠 **Intelligent** - Adapts to any schema structure  
🛡️ **Production-Grade** - Used in real production environments  
🚀 **Lightning Fast** - Get started in seconds, not hours  
🎨 **Your Way** - Use any environment names you want  

---

## 📈 Roadmap

🔄 **Selective Data Transfer** - Migrate specific collections or records  
🗄️ **MySQL Support** - Full support for MySQL databases  
🌐 **Remote Database** - Direct database connections without Docker  
📱 **Web Interface** - Optional GUI for non-technical users  

---

## 🤝 Contributing

Found a bug? Have a feature idea? Contributions welcome!

1. Fork the repository
2. Create your feature branch
3. Test with your Directus setup  
4. Submit a pull request

---

## 📄 License

MIT License - Use freely in your projects!

---

<div align="center">

**⭐ Star this repo if it saved you time!**

Built with ❤️ for the Directus community

</div>
