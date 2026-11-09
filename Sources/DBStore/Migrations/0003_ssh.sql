-- SSH tunnels: a connection may be reached through an SSH host (DBMan runs the system ssh; host/port are then as seen from that host).
-- Approvals gain kind 'update' (an agent proposes changed connection settings; the human confirms in the credential sheet).
ALTER TABLE connections ADD COLUMN ssh_host TEXT;
ALTER TABLE connections ADD COLUMN ssh_user TEXT;
ALTER TABLE connections ADD COLUMN ssh_port INTEGER;
ALTER TABLE connections ADD COLUMN ssh_identity TEXT;

DROP VIEW v_pending_approvals;
ALTER TABLE approvals RENAME TO approvals_v2;
CREATE TABLE approvals (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('credentials','prod_guard','apply','remove','update')),
  agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
  connection_id TEXT REFERENCES connections(id) ON DELETE SET NULL,
  payload TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(payload)),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','expired','consumed')),
  expires_at INTEGER NOT NULL,
  decided_at INTEGER,
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER))
) STRICT;
INSERT INTO approvals SELECT * FROM approvals_v2;
DROP TABLE approvals_v2;
CREATE VIEW v_pending_approvals AS
  SELECT * FROM approvals
  WHERE status = 'pending' AND expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER);
