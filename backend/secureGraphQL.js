const { graphqlHTTP } = require("express-graphql");
const { buildSchema, GraphQLError } = require("graphql");
const pool = require("./db");

function requireAccess(context, requiredScope, ...allowedRoles) {
  const scopes = context?.user?.scp || [];
  if (!scopes.includes(requiredScope)) {
    throw new GraphQLError("Insufficient OAuth scope", {
      extensions: { code: "FORBIDDEN", requiredScope },
    });
  }

  const roles = context?.user?.roles || [];
  if (!allowedRoles.some((role) => roles.includes(role))) {
    throw new GraphQLError("Insufficient application role", {
      extensions: { code: "FORBIDDEN", allowedRoles },
    });
  }
}

// Define GraphQL schema
const schema = buildSchema(`
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
  
    # New type that includes User's name and the cloth details
    type UserWithClothes {
      userid: ID!  
      name: String!
      surname: String!
      clothid: ID!
      description: String!
      color: String!
    }
  
    type Query {
      getSafeUsers: [User]
      getSafeClothesByUser(userid: ID!): [UserWithClothes]
    }
  
    type Mutation {
      addSafeCloth(userid: ID!, clothid: ID!): String
      removeSafeCloth(userid: ID!, clothid: ID!): String
    }
  `);
  

// Define resolvers
const root = {
  getSafeUsers: async (_args, context) => {
    requireAccess(context, "user.read", "Wardrobe.Reader", "Wardrobe.Creator");
    try {
      const result = await pool.query("SELECT * FROM users;");
      return result.rows;
    } catch (err) {
      throw new Error(err.message);
    }
  },

  getSafeClothesByUser: async ({ userid }, context) => {
    requireAccess(context, "user.read", "Wardrobe.Reader", "Wardrobe.Creator");
    try {
      const result = await pool.query(
        `SELECT u.userid, u.name, u.surname, c.clothid, c.description, c.color
        FROM user_clothes uc 
        JOIN clothes c ON uc.clothid = c.clothid
        JOIN users u ON uc.userid = u.userid
        WHERE uc.userid = $1`,
        [userid]
      );
      return result.rows;
    } catch (err) {
      throw new Error(err.message);
    }
  },

  addSafeCloth: async ({ userid, clothid }, context) => {
    requireAccess(context, "user.write", "Wardrobe.Creator");
    try {
      await pool.query("INSERT INTO user_clothes (userid, clothid) VALUES ($1, $2);", [userid, clothid]);
      return "ClothID " + clothid + ", for userID " + userid + " added securely!";
    } catch (err) {
      throw new Error(err.message);
    }
  },

  removeSafeCloth: async ({ userid, clothid }, context) => {
    requireAccess(context, "user.write", "Wardrobe.Creator");
    try {
      await pool.query("DELETE FROM user_clothes WHERE userid = $1 AND clothid = $2;", [userid, clothid]);
      return "ClothID " + clothid + ", for userid " + userid + " removed securely!";
    } catch (err) {
      throw new Error(err.message);
    }
  },
};

// Create middleware
const secureGraphQLMiddleware = graphqlHTTP({
  schema,
  rootValue: root,
  context: (req) => ({ user: req.user }),
  graphiql: true, // Enable GraphiQL for debugging
});

module.exports = { secureGraphQLMiddleware };
