# devseclab — Architecture & Design

> A containerised security learning lab demonstrating SQL injection vulnerabilities, secure vs insecure API patterns, and OAuth2/OIDC authentication with Microsoft Entra ID.

---

## Overview

```mermaid
graph TB
    subgraph Browser["🌐 Browser (User)"]
        UI["React SPA\nPort 3000"]
    end

    subgraph Entra["☁️ Microsoft Entra ID"]
        MSAL["MSAL Auth\nOIDC / OAuth2"]
        JWKS["JWKS Endpoint\nsts.windows.net"]
    end

    subgraph Docker["🐳 Docker Compose"]
        FE["sqlinj-frontend\nReact · Node 20\nPort 3000"]
        BE["sqlinj-backend\nNode.js · Express\nPort 5001"]
        DB["sqlinj-db\nPostgreSQL 16\nPort 5432"]
    end

    UI -->|"Login redirect\nOIDC flow"| MSAL
    MSAL -->|"Access token\n(JWT Bearer)"| UI
    UI -->|"HTTP requests\n+ Bearer token"| BE
    BE -->|"Validate token\nfetch public keys"| JWKS
    BE -->|"SQL queries\n(secure + insecure)"| DB
    FE -.->|"serves"| UI
```

---

## Container Architecture

```mermaid
graph LR
    subgraph Compose["docker-compose.yml"]
        direction TB

        FE["**sqlinj-frontend**\n─────────────\nReact 18\nNode 20 Alpine\nCRA dev server\n:3000 → :3000"]

        BE["**sqlinj-backend**\n─────────────\nNode.js Express\nauthJwt.js (jose)\nREST + GraphQL\n:5001 → :5001"]

        DB["**sqlinj-db**\n─────────────\nPostgres 16\nsql_lab_user\ndevseclab DB\n:5432 → :5432"]

        VOL[("postgres_data\nvolume")]
    end

    FE -->|depends_on| BE
    BE -->|depends_on| DB
    DB --- VOL
```

---

## API Surface

```mermaid
graph TD
    subgraph Backend["Node.js Backend :5001"]
        direction TB

        subgraph REST_INS["REST — Insecure (No Auth)"]
            R1["GET  /api/insecure-users"]
            R2["GET  /api/insecure-users/:id"]
            R3["GET  /api/insecure-users/:id/clothes"]
            R4["POST /api/insecure-users/clothes"]
            R5["POST /api/insecure-users/remove-cloth"]
        end

        subgraph REST_SEC["REST — Secure (JWT + Scope)"]
            S1["GET  /api/safe-users\n🔒 user.read"]
            S2["GET  /api/safe-users/:id\n🔒 user.read"]
            S3["GET  /api/safe-users/:id/clothes\n🔒 user.read"]
            S4["POST /api/safe-users/clothes\n🔒 user.write"]
            S5["POST /api/safe-users/remove-cloth\n🔒 user.write"]
        end

        subgraph GQL["GraphQL"]
            G1["/graphql-insecure\n⚠️ No auth — vulnerable"]
            G2["/graphql-secure\n🔒 requireJwt middleware"]
        end
    end

    style REST_INS fill:#fff0f0,stroke:#cc0000
    style REST_SEC fill:#f0fff0,stroke:#006600
    style GQL fill:#f0f4ff,stroke:#0044cc
```

---

## Authentication Flow

```mermaid
sequenceDiagram
    actor User
    participant React as React SPA<br/>:3000
    participant Entra as Microsoft Entra ID<br/>sts.windows.net
    participant Backend as Node.js Backend<br/>:5001
    participant JWKS as JWKS Endpoint<br/>login.microsoftonline.com
    participant DB as PostgreSQL<br/>:5432

    User->>React: Click "Login with Microsoft Entra ID"
    React->>Entra: Redirect → OIDC auth (MSAL)
    Entra->>User: Login prompt (MFA)
    User->>Entra: Credentials + MFA
    Entra->>React: Redirect back with auth code
    React->>Entra: Exchange code → Access Token (JWT)
    Note over React: Token stored in MSAL cache<br/>aud: api://af63b7cb...<br/>scp: user.read user.write<br/>iss: sts.windows.net/...

    User->>React: Navigate to Authenticated REST page
    React->>Backend: GET /api/safe-users<br/>Authorization: Bearer <JWT>
    Backend->>JWKS: Fetch public signing keys
    JWKS->>Backend: RSA public keys
    Backend->>Backend: Verify token signature,<br/>iss, aud, scp claims
    Backend->>DB: SELECT * FROM users (parameterised)
    DB->>Backend: Result rows
    Backend->>React: JSON response
    React->>User: Display users
```

---

## SQL Injection: Vulnerable vs Secure

```mermaid
graph LR
    subgraph Insecure["⚠️ Insecure Route"]
        I1["User input:\nuserid = '1 OR 1=1'"]
        I2["String concat:\nSELECT * FROM users\nWHERE userid = 1 OR 1=1"]
        I3["DB executes\ninjected SQL"]
        I1 --> I2 --> I3
    end

    subgraph Secure["✅ Secure Route"]
        S1["User input:\nuserid = '1 OR 1=1'"]
        S2["Parameterised query:\nSELECT * FROM users\nWHERE userid = $1"]
        S3["DB treats input\nas data only"]
        S1 --> S2 --> S3
    end

    style Insecure fill:#fff0f0,stroke:#cc0000
    style Secure fill:#f0fff0,stroke:#006600
```

---

## Database Schema

```mermaid
erDiagram
    users {
        int userid PK
        text name
        text surname
    }

    clothes {
        int clothid PK
        text description
        text color
        text brand
        text size
        text material
    }

    user_clothes {
        int userid FK
        int clothid FK
    }

    users ||--o{ user_clothes : "has"
    clothes ||--o{ user_clothes : "assigned to"
```

---

## Entra ID App Registrations

```mermaid
graph TB
    subgraph Tenant["IG LAB1 Directory (Entra Tenant)"]

        subgraph FrontendApp["devseclab-frontend App Registration"]
            FE_ID["Client ID: a6960366-...\nType: SPA"]
            FE_REDIR["Redirect URIs:\nhttp://localhost:3000\nhttps://*.app.github.dev"]
            FE_PERMS["API Permissions:\n✓ Graph: User.Read\n✓ MyHR App: user.read\n✓ MyHR App: user.write"]
        end

        subgraph BackendApp["MyHR App Registration (Resource API)"]
            BE_ID["Client ID: af63b7cb-...\nApp ID URI: api://af63b7cb-..."]
            BE_SCOPES["Exposed Scopes:\n• user.read\n• user.write"]
        end
    end

    FrontendApp -->|"requests token scoped to"| BackendApp
```

---

## Environment Support

```mermaid
graph LR
    subgraph Local["💻 Local Mac"]
        L_FE["Frontend\nlocalhost:3000"]
        L_BE["Backend\nlocalhost:5001"]
        L_DB["PostgreSQL\nlocalhost:5432"]
    end

    subgraph CS["☁️ GitHub Codespaces"]
        C_FE["Frontend\n*..-3000.app.github.dev"]
        C_BE["Backend\n*..-5001.app.github.dev"]
        C_DB["PostgreSQL\n(private, internal only)"]
    end

    subgraph Config["⚙️ Environment-aware config"]
        CF["config.js\nwindow.location.hostname\n=== 'localhost'\n? http://localhost:5001\n: https://hostname.replace(\n  '-3000.', '-5001.')"]
        AUTH["authConfig.js\nredirectUri:\nwindow.location.origin"]
        CORS["backend/index.js\nCORS allows:\n• localhost:3000\n• *.app.github.dev"]
    end

    Local & CS --> Config
```

---

## Project Structure

```
devseclab/
├── docker-compose.yml
├── .devcontainer/
│   └── devcontainer.json        # Codespaces port config
├── frontend/
│   ├── Dockerfile
│   ├── src/
│   │   ├── auth/
│   │   │   ├── authConfig.js    # MSAL config (dynamic redirectUri)
│   │   │   └── authHeaders.js   # Token acquisition helpers
│   │   ├── pages/
│   │   │   ├── InsecureUsersRESTPage.js     # ⚠️ No auth
│   │   │   ├── ListUsersRESTPage.js         # ⚠️ No auth
│   │   │   ├── ListUsersGraphQLPage.js      # ⚠️ No auth
│   │   │   ├── FetchUserClothesGraphQLPage  # ⚠️ No auth
│   │   │   ├── SecureUsersGraphQLPage.js    # 🔒 JWT required
│   │   │   └── SecureUserDetailsRESTPage.js # 🔒 JWT required
│   │   ├── apolloClient.js      # GraphQL insecure client
│   │   ├── authApolloClient.js  # GraphQL secure client (Bearer)
│   │   └── config.js            # Central API URL config
├── backend/
│   ├── Dockerfile
│   ├── .env                     # gitignored — secrets
│   ├── .env.example             # committed — template
│   ├── index.js                 # Express app + CORS
│   ├── authJwt.js               # JWT validation (jose + JWKS)
│   ├── insecureRoutes.js        # ⚠️ Vulnerable SQL (string concat)
│   ├── secureRoutes.js          # ✅ Parameterised queries
│   ├── insecureGraphQL.js       # ⚠️ Vulnerable GraphQL
│   ├── secureGraphQL.js         # ✅ Secure GraphQL
│   └── db.js                    # pg Pool connection
├── postgredb/
│   ├── init/01-init.sql         # Schema + seed data
│   └── dump.sql                 # Full DB dump for restore
└── DevSecOps/
    ├── Helm_Charts/             # EKS deployment charts
    └── Stacks/                  # CloudFormation / EKS stacks
```

---

## Security Learning Objectives

| Concept | Insecure Example | Secure Example |
|---|---|---|
| SQL Injection | `WHERE userid = ${userid}` | `WHERE userid = $1` (parameterised) |
| Authentication | No auth on insecure routes | JWT Bearer + scope validation |
| Authorisation | No scope checks | `requireScope("user.read")` |
| GraphQL | `/graphql-insecure` no auth | `/graphql-secure` + `requireJwt` |
| CORS | Open `cors()` | Origin allowlist |
| Secrets | Inline in code | `.env` (gitignored) |
| Token Validation | — | JWKS signature + iss + aud + scp |
