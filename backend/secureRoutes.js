const express = require("express");
const router = express.Router();
const pool = require("./db");
const { requireJwt, requireScope, requireAnyRole } = require("./authJwt");

const requireReader = requireAnyRole("Wardrobe.Reader", "Wardrobe.Creator");
const requireCreator = requireAnyRole("Wardrobe.Creator");

router.get("/safe-users", requireJwt, requireScope("user.read"), requireReader, async (req, res) => {
  try {
    const result = await pool.query("SELECT * FROM users ORDER BY userid");
    res.json(result.rows);
  } catch (err) {
    console.error("Error fetching safe users:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

router.get("/safe-users/:userid", requireJwt, requireScope("user.read"), requireReader, async (req, res) => {
  try {
    const { userid } = req.params;

    const result = await pool.query(
      "SELECT * FROM users WHERE userid = $1",
      [userid]
    );

    res.json(result.rows[0] || null);
  } catch (err) {
    console.error("Error fetching safe user:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

router.get("/safe-users/:userid/clothes", requireJwt, requireScope("user.read"), requireReader, async (req, res) => {
  try {
    const { userid } = req.params;

    const result = await pool.query(
      `
      SELECT c.*
      FROM clothes c
      INNER JOIN user_clothes uc ON c.clothid = uc.clothid
      WHERE uc.userid = $1
      ORDER BY c.clothid
      `,
      [userid]
    );

    res.json(result.rows);
  } catch (err) {
    console.error("Error fetching safe user clothes:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

router.post("/safe-users/clothes", requireJwt, requireScope("user.write"), requireCreator, async (req, res) => {
  try {
    const { userid, clothid } = req.body;

    if (!userid || !clothid) {
      return res.status(400).json({ error: "userid and clothid are required" });
    }

    const result = await pool.query(
      `
      INSERT INTO user_clothes (userid, clothid)
      VALUES ($1, $2)
      RETURNING *
      `,
      [userid, clothid]
    );

    res.status(201).json(result.rows[0]);
  } catch (err) {
    console.error("Error adding clothing safely:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

router.post("/safe-users/remove-cloth", requireJwt, requireScope("user.write"), requireCreator, async (req, res) => {
  try {
    const { userid, clothid } = req.body;

    if (!userid || !clothid) {
      return res.status(400).json({ error: "userid and clothid are required" });
    }

    const result = await pool.query(
      `
      DELETE FROM user_clothes
      WHERE userid = $1 AND clothid = $2
      RETURNING *
      `,
      [userid, clothid]
    );

    res.json({
      message: "Cloth removed safely",
      removed: result.rows,
    });
  } catch (err) {
    console.error("Error removing clothing safely:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

module.exports = router;
