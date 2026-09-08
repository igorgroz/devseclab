// graphql-server.js
// ─────────────────────────────────────────────────────────────────────────────
// Apollo Server v4 + Express integration.
// Mounted at /graphql by index.js.
//
// v3 → v4 migration notes:
//   • Package:  apollo-server / apollo-server-express  →  @apollo/server
//   • Express:  ApolloServer({ typeDefs, resolvers }).applyMiddleware()
//               →  server.start() + expressMiddleware(server)
//   • Resolvers: rootValue (v2/v3)  →  proper { Query: {}, Mutation: {} } shape
//   • Startup:  server.listen()     →  async server.start(), then Express handles HTTP
//   • Context:  context: ({ req })  →  context: async ({ req }) (always async in v4)
//
// This file exports createApolloMiddleware() — an async factory that starts the
// Apollo server and returns the Express middleware. index.js awaits it during
// app startup before mounting routes.
// ─────────────────────────────────────────────────────────────────────────────

const { ApolloServer } = require("@apollo/server");
const { expressMiddleware } = require("@apollo/server/express4");
const pool = require("./db");

// ── Schema ────────────────────────────────────────────────────────────────────
// Mirrors the schema in insecureGraphQL.js / secureGraphQL.js so the Apollo
// endpoint exposes the same data surface.
// NOTE: This endpoint uses parameterised queries (safe). The intentionally
// vulnerable SQL injection targets remain in insecureGraphQL.js / insecureRoutes.js.
const typeDefs = `#graphql
  type User {
    userid: ID!
    name: String!
    surname: String!
  }

  type Cloth {
    clothid: ID!
    description: String!
    color: String!
  }

  type UserWithClothes {
    userid:      ID!
    name:        String!
    surname:     String!
    clothid:     ID!
    description: String!
    color:       String!
  }

  type Query {
    getUsers:                        [User]
    getClothesByUser(userid: ID!):   [UserWithClothes]
  }

  type Mutation {
    addCloth(userid: ID!, clothid: ID!):    String
    removeCloth(userid: ID!, clothid: ID!): String
  }
`;

// ── Resolvers ─────────────────────────────────────────────────────────────────
// v4 uses { Query: {}, Mutation: {} } resolver map, not rootValue.
// Args are destructured from the second parameter: (parent, args, context, info)
const resolvers = {
  Query: {
    getUsers: async () => {
      const result = await pool.query("SELECT * FROM users ORDER BY userid");
      return result.rows;
    },

    getClothesByUser: async (_parent, { userid }) => {
      const result = await pool.query(
        `SELECT u.userid, u.name, u.surname, c.clothid, c.description, c.color
         FROM user_clothes uc
         JOIN clothes c ON uc.clothid = c.clothid
         JOIN users u   ON uc.userid  = u.userid
         WHERE uc.userid = $1
         ORDER BY c.clothid`,
        [userid]
      );
      return result.rows;
    },
  },

  Mutation: {
    addCloth: async (_parent, { userid, clothid }) => {
      await pool.query(
        "INSERT INTO user_clothes (userid, clothid) VALUES ($1, $2)",
        [userid, clothid]
      );
      return `ClothID ${clothid} added for userID ${userid}`;
    },

    removeCloth: async (_parent, { userid, clothid }) => {
      await pool.query(
        "DELETE FROM user_clothes WHERE userid = $1 AND clothid = $2",
        [userid, clothid]
      );
      return `ClothID ${clothid} removed for userID ${userid}`;
    },
  },
};

// ── Factory ───────────────────────────────────────────────────────────────────
// Apollo v4 requires server.start() to be awaited before expressMiddleware()
// can be called. index.js calls this once at startup inside its async IIFE.
async function createApolloMiddleware() {
  const server = new ApolloServer({
    typeDefs,
    resolvers,
    // v4 default: introspection is disabled in production (NODE_ENV=production).
    // Enable explicitly for the lab so GraphiQL / Apollo Sandbox works locally.
    introspection: true,
  });

  await server.start();

  // expressMiddleware passes req, res, next — compatible with global express.json()
  // already applied in index.js. Context function gives resolvers access to req
  // (e.g. req.user set by requireJwt if the route is protected).
  return expressMiddleware(server, {
    context: async ({ req }) => ({ user: req.user || null }),
  });
}

module.exports = { createApolloMiddleware };
