#!/bin/bash
# Focused diagnosis of Directus schema endpoint authentication

source .env.directus

echo "🔍 DIRECTUS SCHEMA ENDPOINT DIAGNOSIS"
echo "===================================="
echo ""

# 1. First verify the token format
echo "1️⃣ Token validation:"
echo "Length: ${#STAGE_DIRECTUS_TOKEN}"
echo "Contains whitespace: $(echo "$STAGE_DIRECTUS_TOKEN" | grep -E '[ \t\n]' > /dev/null && echo 'YES' || echo 'NO')"
echo "Starts with Bearer: $(echo "$STAGE_DIRECTUS_TOKEN" | grep -E '^Bearer ' > /dev/null && echo 'YES' || echo 'NO')"

# 2. Test user permissions
echo -e "\n2️⃣ Testing user permissions:"
response=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    -H "Authorization: Bearer $STAGE_DIRECTUS_TOKEN" \
    "$STAGE_DIRECTUS_URL/users/me")
http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d':' -f2)
body=$(echo "$response" | grep -v "HTTP_CODE:")

if [[ "$http_code" == "200" ]]; then
    echo "✅ Authentication works (HTTP 200)"
    echo "User role: $(echo "$body" | jq -r '.data.role.name' 2>/dev/null)"
    echo "User status: $(echo "$body" | jq -r '.data.status' 2>/dev/null)"
    
    # Check admin access
    admin_access=$(echo "$body" | jq -r '.data.role.admin_access' 2>/dev/null)
    echo "Admin access: $admin_access"
    
    # Check app access
    app_access=$(echo "$body" | jq -r '.data.role.app_access' 2>/dev/null)
    echo "App access: $app_access"
else
    echo "❌ Basic authentication failed (HTTP $http_code)"
    echo "Response: $(echo "$body" | head -c 200)"
fi

# 3. Test different Directus endpoints to understand the pattern
echo -e "\n3️⃣ Testing various endpoints:"
endpoints=(
    "server/info"
    "collections"
    "fields"
    "relations"
    "permissions"
    "roles"
    "schema/snapshot"
    "schema/diff"
    "utils/hash/generate"
)

for endpoint in "${endpoints[@]}"; do
    http_code=$(curl -s -w "%{http_code}" -o /dev/null \
        -H "Authorization: Bearer $STAGE_DIRECTUS_TOKEN" \
        "$STAGE_DIRECTUS_URL/$endpoint")
    echo "$endpoint: HTTP $http_code"
done

# 4. Try schema endpoint with different methods
echo -e "\n4️⃣ Testing schema/snapshot with different approaches:"

# Method A: GET with Bearer
echo -n "GET with Bearer header: "
curl -s -w "HTTP %{http_code}\n" -o /tmp/schema_test_a.json \
    -H "Authorization: Bearer $STAGE_DIRECTUS_TOKEN" \
    "$STAGE_DIRECTUS_URL/schema/snapshot"

# Method B: POST with Bearer (some versions require POST)
echo -n "POST with Bearer header: "
curl -s -w "HTTP %{http_code}\n" -o /tmp/schema_test_b.json \
    -X POST \
    -H "Authorization: Bearer $STAGE_DIRECTUS_TOKEN" \
    -H "Content-Type: application/json" \
    "$STAGE_DIRECTUS_URL/schema/snapshot"

# Method C: GET with X-Directus-Token header
echo -n "GET with X-Directus-Token: "
curl -s -w "HTTP %{http_code}\n" -o /tmp/schema_test_c.json \
    -H "X-Directus-Token: $STAGE_DIRECTUS_TOKEN" \
    "$STAGE_DIRECTUS_URL/schema/snapshot"

# 5. Check if schema endpoints are disabled
echo -e "\n5️⃣ Checking schema endpoint availability:"
# Try to get schema information through collections
collections_response=$(curl -s \
    -H "Authorization: Bearer $STAGE_DIRECTUS_TOKEN" \
    "$STAGE_DIRECTUS_URL/collections")

if echo "$collections_response" | jq -e '.data' > /dev/null 2>&1; then
    echo "✅ Can access collections (alternative to schema)"
    echo "Number of collections: $(echo "$collections_response" | jq '.data | length')"
else
    echo "❌ Cannot access collections either"
fi

# 6. Check Directus version
echo -e "\n6️⃣ Checking Directus version:"
server_info=$(curl -s "$STAGE_DIRECTUS_URL/server/info")
if echo "$server_info" | jq -e '.data' > /dev/null 2>&1; then
    version=$(echo "$server_info" | jq -r '.data.directus.version' 2>/dev/null)
    echo "Directus version: $version"
    
    # Check if schema endpoints require specific permissions in this version
    if [[ "$version" =~ ^10\. ]]; then
        echo "Note: Directus 10.x may have different schema endpoint requirements"
    fi
fi

# 7. Alternative approach - use GraphQL
echo -e "\n7️⃣ Testing GraphQL schema introspection:"
graphql_query='{"query":"{ __schema { types { name } } }"}'
curl -s -w "\nHTTP %{http_code}\n" \
    -X POST \
    -H "Authorization: Bearer $STAGE_DIRECTUS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$graphql_query" \
    "$STAGE_DIRECTUS_URL/graphql" | head -5

# Cleanup
rm -f /tmp/schema_test_*.json

echo -e "\n📊 Summary:"
echo "If schema/snapshot returns 401 but other endpoints work, this could indicate:"
echo "1. Schema endpoints are disabled in your Directus configuration"
echo "2. Your Directus version requires different permissions for schema access"
echo "3. Schema endpoints need a different authentication method"
echo "4. The instance is configured to block schema exports for security"