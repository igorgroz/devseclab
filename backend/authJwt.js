const { webcrypto } = require("node:crypto");
const jsonwebtoken = require("jsonwebtoken");

if (!globalThis.crypto) {
  globalThis.crypto = webcrypto;
}

// ─────────────────────────────────────────────────────────────────────────────
// AUTH_MODE=dast — evaluated once at startup, never per-request.
// Evaluated at module load so it cannot be toggled via a request header or
// runtime injection. In normal operation this is always false.
// ─────────────────────────────────────────────────────────────────────────────
const isDastMode = process.env.AUTH_MODE === "dast";

if (isDastMode) {
  console.warn(
    "[authJwt] AUTH_MODE=dast — Entra ID validation DISABLED. " +
    "This mode is for CI/CD DAST scanning only and must never run in production."
  );
}

const requiredIssuer = process.env.JWT_ISSUER;
const requiredAudience = process.env.JWT_AUDIENCE;
const tenantId = process.env.ENTRA_TENANT_ID;

const jwksUrl = new URL(
  `https://login.microsoftonline.com/${tenantId}/discovery/v2.0/keys`
);

let joseModulePromise;

async function getJose() {
  if (!joseModulePromise) {
    joseModulePromise = import("jose");
  }
  return joseModulePromise;
}

async function verifyEntraToken(token) {
  const { createRemoteJWKSet, jwtVerify } = await getJose();
  const JWKS = createRemoteJWKSet(jwksUrl);

  const { payload } = await jwtVerify(token, JWKS, {
    issuer: requiredIssuer,
    audience: requiredAudience,
  });

  return payload;
}

// ─────────────────────────────────────────────────────────────────────────────
// DAST path — HS256 verification against a static secret.
// The token is minted by generateDastToken.js and stored as a GitHub secret.
// Claims shape mirrors the Entra ID token so scope and role checks work unchanged.
// ─────────────────────────────────────────────────────────────────────────────
async function verifyDastToken(token) {
  const secret = process.env.DAST_JWT_SECRET;
  if (!secret) {
    throw new Error("DAST_JWT_SECRET is not set — cannot verify DAST token");
  }
  // jsonwebtoken.verify is synchronous; wrap in a promise for a uniform interface
  return new Promise((resolve, reject) => {
    jsonwebtoken.verify(token, secret, { algorithms: ["HS256"] }, (err, payload) => {
      if (err) reject(err);
      else resolve(payload);
    });
  });
}

async function requireJwt(req, res, next) {
  try {
    const authHeader = req.headers.authorization || "";

    if (!authHeader.startsWith("Bearer ")) {
      return res.status(401).json({ error: "missing_bearer_token" });
    }

    const token = authHeader.slice("Bearer ".length);

    const claims = isDastMode
      ? await verifyDastToken(token)
      : await verifyEntraToken(token);

    req.user = {
      sub: claims.sub,
      oid: claims.oid || claims.sub,   // oid absent in DAST token; fall back to sub
      tid: claims.tid || "dast",
      roles: claims.roles || [],
      scp: claims.scp ? claims.scp.split(" ") : [],
    };

    return next();
  } catch (err) {
    return res.status(401).json({
      error: "invalid_token",
      detail: err.message,
    });
  }
}

function requireScope(requiredScope) {
  return (req, res, next) => {
    const scopes = req.user?.scp || [];

    if (!scopes.includes(requiredScope)) {
      return res.status(403).json({
        error: "insufficient_scope",
        required: requiredScope,
      });
    }

    return next();
  };
}

function requireAnyRole(...allowedRoles) {
  return (req, res, next) => {
    const roles = req.user?.roles || [];

    if (!allowedRoles.some((role) => roles.includes(role))) {
      return res.status(403).json({
        error: "insufficient_role",
        allowed: allowedRoles,
      });
    }

    return next();
  };
}

module.exports = { requireJwt, requireScope, requireAnyRole };
