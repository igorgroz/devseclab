#!/usr/bin/env node
// generateDastToken.js
// ─────────────────────────────────────────────────────────────────────────────
// Mints a DAST test JWT signed with DAST_JWT_SECRET.
// Run this once to generate the token, then store it as a GitHub Actions secret.
//
// Usage:
//   DAST_JWT_SECRET=<your-secret> node generateDastToken.js
//
// Or with a .env file:
//   node -r dotenv/config generateDastToken.js
//
// Output: prints the signed JWT to stdout.
// ─────────────────────────────────────────────────────────────────────────────

const jwt = require("jsonwebtoken");

const secret = process.env.DAST_JWT_SECRET;

if (!secret) {
  console.error("Error: DAST_JWT_SECRET environment variable is not set.");
  console.error("Usage: DAST_JWT_SECRET=<your-secret> node generateDastToken.js");
  process.exit(1);
}

if (secret.length < 32) {
  console.warn("Warning: DAST_JWT_SECRET is shorter than 32 characters. Use a longer secret.");
}

// Claims mirror what Entra ID issues so scope and role checks in authJwt.js
// work without any changes.
// scp is a space-separated string — same format as Entra ID access tokens.
const claims = {
  sub:   "dast-test-user",
  oid:   "00000000-0000-0000-0000-000000000001",
  tid:   "dast",
  roles: ["Wardrobe.Creator"],
  scp:   "user.read user.write",    // grants access to all secure routes
};

const token = jwt.sign(claims, secret, {
  algorithm:  "HS256",
  expiresIn:  "8h",               // long enough for a CI pipeline run
  issuer:     "dast-ci",
  audience:   "dsl-backend",
});

console.log("\n=== DAST Bearer Token ===");
console.log(token);
console.log("\nStore this as the DAST_BEARER_TOKEN GitHub Actions secret.");
console.log("It expires in 8h — regenerate before each release if needed,");
console.log("or set a longer expiry (e.g. '30d') if you want a stable token.\n");
