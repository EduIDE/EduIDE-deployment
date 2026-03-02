# Keycloak Setup

This guide explains how to configure Keycloak authentication for Theia Cloud deployments.

## Overview

Theia Cloud uses Keycloak (via OAuth2 Proxy) to provide authentication and authorization. Each deployment requires:

1. A Keycloak realm
2. A Keycloak client configured for the specific environment
3. Client scopes with custom mappers
4. GitHub Environment secrets with Keycloak credentials

## Prerequisites

- Access to a Keycloak instance
- Admin permissions in the Keycloak realm
- The deployment domain/URLs for your environment

## Step 1: Create or Configure Keycloak Client

### 1.1 Create a New Client

1. Log in to Keycloak Admin Console
2. Select your realm (e.g., `Test`, `Production`)
3. Navigate to **Clients**
4. Click **Create client**
5. Configure the basic settings:

   ```
   Client ID: theia-cloud (or theia-cloud-test2, etc.)
   Name: Theia Cloud
   Description: OAuth2 client for Theia Cloud deployment
   ```

6. Click **Next**

### 1.2 Configure Client Settings

**Capability config:**
- ✅ Client authentication: OFF (for public clients)
- ✅ Authorization: OFF
- ✅ Standard flow: ON
- ✅ Direct access grants: OFF (optional)
- ✅ Implicit flow: OFF

Click **Next**

**Login settings:**

Configure these URLs based on your environment domain:

For test environments (e.g., `test1.theia-test.artemis.cit.tum.de`):
```
Root URL: https://test1.theia-test.artemis.cit.tum.de
Home URL: https://test1.theia-test.artemis.cit.tum.de
Valid redirect URIs:
  - https://test1.theia-test.artemis.cit.tum.de/*
  - https://instance.test1.theia-test.artemis.cit.tum.de/*
Valid post logout redirect URIs: +
Web origins: +
```

For production:
```
Root URL: https://theia.artemis.cit.tum.de
Home URL: https://theia.artemis.cit.tum.de
Valid redirect URIs:
  - https://theia.artemis.cit.tum.de/*
  - https://instance.theia.artemis.cit.tum.de/*
Valid post logout redirect URIs: +
Web origins: +
```

Click **Save**


3. Store this securely for use in GitHub Environment secrets

## Step 2: Configure Client Scopes

Client scopes provide additional user information to Theia Cloud. You need to create a dedicated scope with custom mappers.

### 2.1 Create Dedicated Client Scope

1. Go to **Clients > [your-client] > Client scopes**
2. Click on the dedicated scope (e.g., `theia-cloud-dedicated`)
   - If it doesn't exist, create it: **Clients > Client scopes > Create client scope**
   ```
   Name: theia-cloud-dedicated
   Protocol: openid-connect
   Display on consent screen: OFF
   Include in token scope: ON
   ```
3. Click on **Mappers** tab
4. Add the following mappers:

### 2.2 Add Username Mapper

Click **Add mapper > By configuration > User Property**

```
Name: username
Mapper Type: User Property
Property: username
Token Claim Name: username
Claim JSON Type: String
Add to ID token: ON
Add to access token: ON
Add to userinfo: ON
```

![Username Mapper Example](images/keycloak_client_scope_username.png)

Click **Save**

### 2.3 Add Audience Mapper

Click **Add mapper > By configuration > Audience**

```
Name: audience
Mapper Type: Audience
Included Client Audience: theia-cloud (your client ID)
Add to ID token: ON
Add to access token: ON
```

![Audience Mapper Example](images/keycloak_client_scope_audience.png)

Click **Save**

### 2.4 Add Groups Mapper

Click **Add mapper > By configuration > Group Membership**

```
Name: groups
Mapper Type: Group Membership
Token Claim Name: groups
Full group path: OFF
Add to ID token: ON
Add to access token: ON
Add to userinfo: ON
```

![Groups Mapper Example](images/keycloak_client_scope_groups.png)

Click **Save**

### 2.5 Configure Admin Group for Scaling Operations

Theia Cloud scaling endpoints are admin-only and require that the authenticated user is in the Keycloak group configured as:

- Helm value: `theia-cloud.keycloak.adminGroup`
- Service property: `theia.cloud.auth.admin.group`

In this repository, the default is:

```yaml
theia-cloud:
  keycloak:
    adminGroup: "/theia-cloud/admin"
```

Users must have that exact group in their JWT `groups` claim to use:

- `GET /service/admin/appdefinition/{appId}`
- `GET /service/admin/appdefinition/{appDefinitionName}/{appId}`
- `PATCH /service/admin/appdefinition/{appDefinitionName}`

### 2.6 Verify Client Scope Assignment

1. Go back to **Clients > [your-client] > Client scopes**
2. Verify that `theia-cloud-dedicated` appears under **Assigned client scopes**
3. If not, add it:
   - Click **Add client scope**
   - Select `theia-cloud-dedicated`
   - Choose **Default** scope type
   - Click **Add**

## Test Authentication

After deploying with Keycloak configuration:

### Access the Landing Page

1. Navigate to your environment URL (e.g., `https://test1.theia-test.artemis.cit.tum.de`)
2. You should be redirected to Keycloak login page
3. Log in with valid credentials

### Verify Token Claims

After successful login, you can verify that user information is correctly passed:

1. Open browser Developer Tools (F12)
2. Go to **Application > Cookies**
3. Find cookies starting with `_oauth2_proxy`
4. The session should contain user information

### Test IDE Session Creation

1. From the landing page, try to create a new IDE session
2. Verify that the session starts correctly
3. Check that your username appears in the session management interface

## Common Issues

### Issue: Redirect Loop

**Symptoms:** Browser keeps redirecting between application and Keycloak

**Causes:**
- Incorrect redirect URI configuration
- Cookie secret mismatch
- Domain/protocol mismatch (HTTP vs HTTPS)

**Solutions:**
- Verify all redirect URIs are correctly configured in Keycloak
- Check that wildcard redirect URIs include `/*` suffix
- Ensure cookie secret is correctly base64-encoded
- Verify all URLs use HTTPS

### Issue: "Invalid Client" Error

**Symptoms:** Keycloak shows "We're sorry... Invalid client"

**Causes:**
- Client ID doesn't match
- Client is disabled
- Client doesn't exist in the realm

**Solutions:**
- Verify `THEIA_KEYCLOAK_CLIENT_ID` matches the client ID in Keycloak
- Check client is enabled in Keycloak
- Verify you're using the correct realm

### Issue: "Access Denied" After Login

**Symptoms:** Successfully log in to Keycloak, but access is denied to Theia

**Causes:**
- User doesn't have required roles/groups
- Token claims are missing
- Client scopes not configured correctly

**Solutions:**
- Verify user has necessary roles in Keycloak
- Check that client scopes (username, groups, audience) are configured
- Use Keycloak's token introspection to verify claims are present
