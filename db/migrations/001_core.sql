-- db/migrations/001_core.sql
-- Core accounting schema (PostgreSQL 15+)
-- All money values are BIGINT in Rials (no decimals, no float errors).
-- Dates are stored as Gregorian DATE; convert to Jalali only in the UI.

BEGIN;

-- =========================================================
-- 1. Users & roles
-- =========================================================
CREATE TABLE roles (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name        text  NOT NULL UNIQUE,
  permissions jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE users (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  username      text   NOT NULL UNIQUE,
  full_name     text   NOT NULL,
  password_hash text   NOT NULL,
  role_id       bigint NOT NULL REFERENCES roles(id),
  is_active     boolean NOT NULL DEFAULT true,
  last_login_at timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- =========================================================
-- 2. Fiscal years (سال مالی)
-- =========================================================
CREATE TABLE fiscal_years (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title      text NOT NULL,
  start_date date NOT NULL,
  end_date   date NOT NULL,
  status     text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (end_date > start_date),
  -- fiscal years must never overlap
  CONSTRAINT fiscal_years_no_overlap
    EXCLUDE USING gist (daterange(start_date, end_date, '[]') WITH &&)
);

-- =========================================================
-- 3. Chart of accounts (کدینگ حساب‌ها)
--    level 1 = گروه, 2 = کل, 3 = معین
--    Only level-3 accounts can receive journal lines.
-- =========================================================
CREATE TABLE accounts (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  parent_id       bigint REFERENCES accounts(id),
  code            text     NOT NULL UNIQUE,
  name            text     NOT NULL,
  level           smallint NOT NULL CHECK (level IN (1, 2, 3)),
  nature          text     NOT NULL CHECK (nature IN ('debit', 'credit', 'both')),
  is_postable     boolean  NOT NULL DEFAULT false,
  requires_detail boolean  NOT NULL DEFAULT false,
  is_active       boolean  NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (is_postable = false OR level = 3),
  CHECK ((level = 1 AND parent_id IS NULL) OR (level > 1 AND parent_id IS NOT NULL))
);
CREATE INDEX ix_accounts_parent ON accounts(parent_id);

-- Detail accounts (حساب تفصیلی): customers, suppliers, banks, cost centers...
CREATE TABLE detail_accounts (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code       text NOT NULL UNIQUE,
  name       text NOT NULL,
  kind       text NOT NULL DEFAULT 'other'
             CHECK (kind IN ('customer', 'supplier', 'employee', 'bank', 'cash', 'cost_center', 'other')),
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- =========================================================
-- 4. Journal entries (سند حسابداری)
-- =========================================================
CREATE TABLE journal_entries (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  fiscal_year_id     bigint NOT NULL REFERENCES fiscal_years(id),
  number             bigint,                       -- assigned when posted
  entry_date         date   NOT NULL,
  description        text,
  status             text   NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'posted')),
  source_type        text   NOT NULL DEFAULT 'manual',  -- manual, sales_invoice, treasury, reversal...
  source_id          bigint,
  reverses_entry_id  bigint REFERENCES journal_entries(id),
  total_debit        bigint NOT NULL DEFAULT 0,
  total_credit       bigint NOT NULL DEFAULT 0,
  created_by         bigint NOT NULL REFERENCES users(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  posted_by          bigint REFERENCES users(id),
  posted_at          timestamptz,
  CHECK (status = 'draft' OR number IS NOT NULL)
);

CREATE UNIQUE INDEX ux_je_year_number ON journal_entries(fiscal_year_id, number)
  WHERE number IS NOT NULL;
CREATE UNIQUE INDEX ux_je_reverses ON journal_entries(reverses_entry_id)
  WHERE reverses_entry_id IS NOT NULL;
CREATE INDEX ix_je_year_date ON journal_entries(fiscal_year_id, entry_date);
CREATE INDEX ix_je_drafts ON journal_entries(created_by) WHERE status = 'draft';
CREATE INDEX ix_je_source ON journal_entries(source_type, source_id);

CREATE TABLE journal_lines (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entry_id    bigint NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  line_no     int    NOT NULL,
  account_id  bigint NOT NULL REFERENCES accounts(id),
  detail_id   bigint REFERENCES detail_accounts(id),
  description text,
  debit       bigint NOT NULL DEFAULT 0 CHECK (debit  >= 0),
  credit      bigint NOT NULL DEFAULT 0 CHECK (credit >= 0),
  CHECK (debit = 0 OR credit = 0),        -- a line is either debit or credit
  CHECK (debit > 0 OR credit > 0),        -- no empty lines
  UNIQUE (entry_id, line_no)
);

-- These two indexes are what keep ledger/subsidiary reports fast with big data
CREATE INDEX ix_jl_account_entry ON journal_lines(account_id, entry_id);
CREATE INDEX ix_jl_detail_account ON journal_lines(detail_id, account_id)
  WHERE detail_id IS NOT NULL;

-- Gapless document numbering per fiscal year
CREATE TABLE entry_counters (
  fiscal_year_id bigint PRIMARY KEY REFERENCES fiscal_years(id),
  last_number    bigint NOT NULL DEFAULT 0
);

-- =========================================================
-- 5. Audit log (لاگ ممیزی)
-- =========================================================
CREATE TABLE audit_logs (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    bigint REFERENCES users(id),
  action     text   NOT NULL,           -- create, update, post, reverse, login...
  entity     text   NOT NULL,           -- journal_entry, account, user...
  entity_id  bigint,
  details    jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_audit_entity ON audit_logs(entity, entity_id);
CREATE INDEX ix_audit_created ON audit_logs(created_at);

-- =========================================================
-- 6. Business rules enforced by the database itself
-- =========================================================

-- 6.1 Entry guard: validates on posting, blocks edits/deletes after posting
CREATE FUNCTION trg_entries_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_fy_status text;
  v_in_year   boolean;
  v_cnt       int;
  v_debit     bigint;
  v_credit    bigint;
  v_bad       int;
  v_num       bigint;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'posted' THEN
      RAISE EXCEPTION 'Posted entries cannot be deleted. Create a reversing entry instead.';
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.status = 'posted' THEN
    RAISE EXCEPTION 'Posted entries are immutable.';
  END IF;

  IF NEW.status = 'posted' THEN
    SELECT status, (NEW.entry_date BETWEEN start_date AND end_date)
      INTO v_fy_status, v_in_year
      FROM fiscal_years WHERE id = NEW.fiscal_year_id;

    IF v_fy_status IS DISTINCT FROM 'open' THEN
      RAISE EXCEPTION 'Fiscal year is closed or not found.';
    END IF;
    IF NOT v_in_year THEN
      RAISE EXCEPTION 'Entry date is outside the fiscal year.';
    END IF;

    SELECT count(*), coalesce(sum(debit), 0), coalesce(sum(credit), 0)
      INTO v_cnt, v_debit, v_credit
      FROM journal_lines WHERE entry_id = NEW.id;

    IF v_cnt < 2 THEN
      RAISE EXCEPTION 'An entry needs at least two lines.';
    END IF;
    IF v_debit <> v_credit THEN
      RAISE EXCEPTION 'Entry is not balanced: debit % <> credit %.', v_debit, v_credit;
    END IF;

    SELECT count(*) INTO v_bad
      FROM journal_lines l
      JOIN accounts a ON a.id = l.account_id
     WHERE l.entry_id = NEW.id
       AND (NOT a.is_postable
            OR NOT a.is_active
            OR (a.requires_detail AND l.detail_id IS NULL));
    IF v_bad > 0 THEN
      RAISE EXCEPTION 'Entry has % invalid line(s): non-postable/inactive account or missing detail account.', v_bad;
    END IF;

    INSERT INTO entry_counters (fiscal_year_id, last_number)
    VALUES (NEW.fiscal_year_id, 1)
    ON CONFLICT (fiscal_year_id)
    DO UPDATE SET last_number = entry_counters.last_number + 1
    RETURNING last_number INTO v_num;

    NEW.number       := v_num;
    NEW.total_debit  := v_debit;
    NEW.total_credit := v_credit;
    NEW.posted_at    := now();
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER entries_guard
  BEFORE UPDATE OR DELETE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION trg_entries_guard();

-- 6.2 Line guard: lines of a posted entry can never change
CREATE FUNCTION trg_lines_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_status   text;
  v_entry_id bigint;
BEGIN
  v_entry_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.entry_id ELSE NEW.entry_id END;
  SELECT status INTO v_status FROM journal_entries WHERE id = v_entry_id;
  IF v_status = 'posted' THEN
    RAISE EXCEPTION 'Lines of a posted entry are immutable.';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE TRIGGER lines_guard
  BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
  FOR EACH ROW EXECUTE FUNCTION trg_lines_guard();

-- 6.3 Reversal: creates a DRAFT entry with debit/credit swapped
CREATE FUNCTION reverse_entry(p_entry_id bigint, p_user_id bigint, p_date date DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_old journal_entries%ROWTYPE;
  v_new bigint;
BEGIN
  SELECT * INTO v_old FROM journal_entries WHERE id = p_entry_id AND status = 'posted';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Only posted entries can be reversed.';
  END IF;

  INSERT INTO journal_entries
    (fiscal_year_id, entry_date, description, source_type, reverses_entry_id, created_by)
  VALUES
    (v_old.fiscal_year_id, coalesce(p_date, v_old.entry_date),
     'برگشت سند شماره ' || v_old.number, 'reversal', v_old.id, p_user_id)
  RETURNING id INTO v_new;

  INSERT INTO journal_lines (entry_id, line_no, account_id, detail_id, description, debit, credit)
  SELECT v_new, line_no, account_id, detail_id, description, credit, debit
    FROM journal_lines WHERE entry_id = p_entry_id;

  RETURN v_new;
END $$;

-- =========================================================
-- 7. Reports (starting point)
-- =========================================================
CREATE VIEW v_trial_balance AS
SELECT e.fiscal_year_id,
       l.account_id,
       a.code,
       a.name,
       sum(l.debit)                 AS total_debit,
       sum(l.credit)                AS total_credit,
       sum(l.debit) - sum(l.credit) AS balance
  FROM journal_lines l
  JOIN journal_entries e ON e.id = l.entry_id AND e.status = 'posted'
  JOIN accounts a        ON a.id = l.account_id
 GROUP BY e.fiscal_year_id, l.account_id, a.code, a.name;

-- =========================================================
-- 8. Seed
-- =========================================================
INSERT INTO roles (name, permissions) VALUES
  ('admin',      '["*"]'),
  ('accountant', '["entries.read","entries.write","entries.post","reports.read"]'),
  ('viewer',     '["entries.read","reports.read"]');

COMMIT;