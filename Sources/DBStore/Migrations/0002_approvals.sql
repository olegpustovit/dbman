-- P6: approvals gain kind 'remove' and status 'consumed' (a spent ALLOW ONCE); a deleted connection no longer deletes its approval row
-- (the waiting agent call still reads its decision). SQLite cannot alter a CHECK, so the table is rebuilt.
DROP VIEW v_pending_approvals;
ALTER TABLE approvals RENAME TO approvals_v1;
CREATE TABLE approvals (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('credentials','prod_guard','apply','remove')),
  agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
  connection_id TEXT REFERENCES connections(id) ON DELETE SET NULL,
  payload TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(payload)),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','expired','consumed')),
  expires_at INTEGER NOT NULL,
  decided_at INTEGER,
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER))
) STRICT;
INSERT INTO approvals SELECT * FROM approvals_v1;
DROP TABLE approvals_v1;
CREATE VIEW v_pending_approvals AS
  SELECT * FROM approvals
  WHERE status = 'pending' AND expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER);
