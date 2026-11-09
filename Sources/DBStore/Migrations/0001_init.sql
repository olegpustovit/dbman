-- 0001 init: every table STRICT, timestamps are unix ms. JSON columns are TEXT guarded by json_valid().
PRAGMA application_id = 0x44424D4E; -- "DBMN"

CREATE TABLE meta (
  key TEXT PRIMARY KEY, value TEXT,
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER))
) STRICT;

CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL CHECK (json_valid(value)),
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER))
) STRICT;

-- The internal connection (id 'internal', env 'system') is the store itself; the two CHECKs tie id and env together.
CREATE TABLE connections (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  engine TEXT NOT NULL CHECK (engine IN ('postgres','mysql','sqlite')),
  host TEXT NOT NULL DEFAULT '',
  port INTEGER NOT NULL DEFAULT 0,
  "database" TEXT NOT NULL DEFAULT '',
  "user" TEXT NOT NULL DEFAULT '',
  ssl_mode TEXT NOT NULL DEFAULT 'prefer' CHECK (ssl_mode IN ('disable','prefer','require','verify-full')),
  ssl_root_cert TEXT,
  env TEXT NOT NULL DEFAULT 'local' CHECK (env IN ('local','staging','production','system')),
  file_path TEXT,
  secret_ref TEXT,
  read_only INTEGER NOT NULL DEFAULT 0 CHECK (read_only IN (0,1)),
  stage_writes INTEGER NOT NULL DEFAULT 1 CHECK (stage_writes IN (0,1)),
  last_opened_at INTEGER,
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  CONSTRAINT connections_internal_is_system CHECK ((env = 'system') = (id = 'internal'))
) STRICT;

CREATE TABLE agents (
  id TEXT PRIMARY KEY,
  client_name TEXT NOT NULL,
  platform TEXT,
  version TEXT,
  config_path TEXT,
  installed_via TEXT NOT NULL DEFAULT 'manual' CHECK (installed_via IN ('native','agentpack','manual')),
  first_seen INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  last_seen INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER))
) STRICT;

-- Agents can never hold rights on the internal store (it holds this very table): enforced here and in the MCP gate.
CREATE TABLE permissions (
  agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
  level TEXT NOT NULL CHECK (level IN ('off','read','overlay')),
  timeout_ms INTEGER,
  row_cap INTEGER,
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  PRIMARY KEY (agent_id, connection_id),
  CONSTRAINT permissions_not_internal CHECK (connection_id <> 'internal')
) STRICT;

CREATE TABLE sensitive_columns (
  connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
  table_name TEXT NOT NULL,
  column_name TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('auto','user')),
  hidden INTEGER NOT NULL DEFAULT 1 CHECK (hidden IN (0,1)),
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  PRIMARY KEY (connection_id, table_name, column_name)
) STRICT;

CREATE TABLE layers (
  id TEXT PRIMARY KEY,
  connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
  owner TEXT NOT NULL CHECK (owner IN ('human','agent')),
  agent_id TEXT REFERENCES agents(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  visible INTEGER NOT NULL DEFAULT 1 CHECK (visible IN (0,1)),
  position INTEGER NOT NULL DEFAULT 0,
  archived_at INTEGER,
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  CHECK ((owner = 'agent') = (agent_id IS NOT NULL))
) STRICT;
CREATE UNIQUE INDEX layers_one_mine ON layers(connection_id) WHERE owner = 'human';

CREATE TABLE overlay_items (
  id TEXT PRIMARY KEY,
  layer_id TEXT NOT NULL REFERENCES layers(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('view','relation','row_patch','note','saved_query','dashboard','computed_column')),
  name TEXT,
  payload TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(payload)),
  base_hash TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','stale','adopted','discarded')),
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER))
) STRICT;

CREATE TABLE row_patches (
  item_id TEXT NOT NULL REFERENCES overlay_items(id) ON DELETE CASCADE,
  table_name TEXT NOT NULL,
  pk TEXT NOT NULL CHECK (json_valid(pk)),
  op TEXT NOT NULL CHECK (op IN ('insert','update','delete')),
  "before" TEXT CHECK ("before" IS NULL OR json_valid("before")),
  "after" TEXT CHECK ("after" IS NULL OR json_valid("after")),
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  PRIMARY KEY (item_id)
) STRICT;

-- Append-only; 30-day retention is applied by the writer (P1).
CREATE TABLE activity (
  id INTEGER PRIMARY KEY,
  ts INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
  connection_id TEXT REFERENCES connections(id) ON DELETE SET NULL,
  tool TEXT NOT NULL,
  args_summary TEXT,
  ms INTEGER,
  "rows" INTEGER,
  status TEXT NOT NULL CHECK (status IN ('ok','overlay','blocked','denied','error')),
  error TEXT,
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER))
) STRICT;
CREATE INDEX activity_ts ON activity(ts);

CREATE TABLE approvals (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('credentials','prod_guard','apply')),
  agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
  connection_id TEXT REFERENCES connections(id) ON DELETE CASCADE,
  payload TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(payload)),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','expired')),
  expires_at INTEGER NOT NULL,
  decided_at INTEGER,
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER))
) STRICT;

CREATE TABLE query_history (
  id INTEGER PRIMARY KEY,
  connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
  source TEXT NOT NULL CHECK (source IN ('human','agent')),
  agent_id TEXT REFERENCES agents(id) ON DELETE SET NULL,
  sql TEXT NOT NULL,
  ms INTEGER,
  "rows" INTEGER,
  ts INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER))
) STRICT;

CREATE TABLE schema_cache (
  connection_id TEXT PRIMARY KEY REFERENCES connections(id) ON DELETE CASCADE,
  snapshot TEXT NOT NULL CHECK (json_valid(snapshot)),
  fetched_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER))
) STRICT;

CREATE TABLE map_layouts (
  connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
  layout TEXT NOT NULL,
  positions TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(positions)),
  created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  updated_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
  PRIMARY KEY (connection_id, layout)
) STRICT;

CREATE VIEW v_agent_activity_daily AS
  SELECT date(ts / 1000, 'unixepoch') AS day, agent_id, count(*) AS calls,
         sum(status = 'blocked') AS blocked, sum(status = 'denied') AS denied,
         coalesce(sum("rows"), 0) AS "rows", cast(avg(ms) AS INTEGER) AS avg_ms
  FROM activity GROUP BY day, agent_id;

CREATE VIEW v_layer_summary AS
  SELECT l.id AS layer_id, l.connection_id, l.owner, l.agent_id, l.name, l.visible,
         count(i.id) AS items, coalesce(sum(i.status = 'active'), 0) AS active,
         coalesce(sum(i.status = 'stale'), 0) AS stale
  FROM layers l LEFT JOIN overlay_items i ON i.layer_id = l.id AND i.status IN ('active','stale')
  GROUP BY l.id;

CREATE VIEW v_pending_approvals AS
  SELECT * FROM approvals
  WHERE status = 'pending' AND expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER);

CREATE VIEW v_dashboard_widgets AS
  SELECT i.id AS dashboard_id, i.layer_id, i.name AS dashboard,
         w.key AS position, json_extract(w.value, '$.type') AS widget_type,
         json_extract(w.value, '$.title') AS title, w.value AS spec
  FROM overlay_items i, json_each(i.payload, '$.widgets') w
  WHERE i.kind = 'dashboard' AND i.status IN ('active','stale');
