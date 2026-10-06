# Admission Workflow Management System

A MySQL project that models a college admission process end to end — from application submission to acceptance/rejection, course allocation, fee payment, hostel allotment, and final enrollment.

It is also a complete tour of SQL and MySQL's stored-program language: every join type, every subquery style, CTEs, window functions, views, functions, procedures, triggers, explicit/nested/implicit cursors, transactions, and an event.

## How it works

Every application starts in `Application_Master`. Based on `jee_score` and `docs_submitted`, it's routed into one of three outcomes:

- **Accepted** (score ≥ cutoff, docs complete) → `Acceptance_Table`
- **Rejected** (score below cutoff) → `Rejection_Table`
- **Incomplete** (docs missing) → `Incomplete_Table`

From there, accepted students branch out into course allocation, scholarships, fee payment, hostel accommodation, and enrollment. Rejected students can file an appeal. Incomplete applications get a document checklist and a grace period, and are rejected automatically if it lapses. Status changes, fee changes and deletions are logged automatically.

## Schema

20 tables: 16 core and 4 supporting. `Application_Master` is the master table — every applicant gets exactly one row there first, and nothing downstream can exist without it. Every other applicant-owned table reaches it by foreign key, directly or through a parent:

```
Application_Master          <-- master table, single entry point
  |
  +-- Acceptance_Table            (1:1, if qualifies)
  |     +-- Course_Eligibility_Table --> Course_Master
  |     +-- Scholarship_Table        --> Scholarship_Master
  |     +-- Fee_Payment_Table (1:1)
  |     |     +-- Refund_Table
  |     +-- Hostel_Accommodation_Table (1:1)
  |     +-- Enrolled_Students (1:1)   --> Course_Master
  |
  +-- Rejection_Table             (1:1, if below cutoff)
  |     +-- Appeal_Table
  |
  +-- Incomplete_Table            (1:1, if docs missing)
  |     +-- Document_Checklist
  |
  +-- Application_Status_History  (1:N audit trail)
  +-- Communication_Log           (1:N notifications)
  +-- Merit_Rank_List             (1:1, filled by a cursor procedure)
```

`Course_Master` and `Scholarship_Master` are the two lookup tables — shared reference data, not owned by any one applicant.

The four supporting tables:

| Table | Purpose | FK? |
|---|---|---|
| `Fee_Audit_Log` | old/new money values for every fee change, written by a trigger | none — an audit trail must outlive its rows |
| `Deleted_Applications_Archive` | tombstone for every deleted application, written by a trigger | none — the parent row is gone |
| `Merit_Rank_List` | merit ranks produced by an explicit cursor | → `Application_Master` |
| `Course_Roster_Report` | per-course roster produced by nested cursors | → `Course_Master` |

Applicant-owned tables cascade on delete, so removing an application removes its whole subtree. The two lookup tables use `ON DELETE RESTRICT`, so a course or scholarship scheme that is still referenced cannot be deleted out from under the rows that point at it.

Beyond the foreign keys, the schema enforces:

- `UNIQUE (acceptance_id, priority_preference)` and `UNIQUE (acceptance_id, course_id)` — one course per priority slot, and no listing the same course twice
- `UNIQUE (acceptance_id, scholarship_code)` — no double-awarding the same scheme
- `UNIQUE (incomplete_id, document_type)` — no duplicate checklist entries
- `UNIQUE` on `allotted_room_number` and `roll_number` — no two students in one room or on one roll number
- `CHECK` constraints on score ranges, seat counts, and money amounts

## Feature coverage

| Topic | Where | What |
|---|---|---|
| Tables, constraints, indexes | §1 | PK, FK (CASCADE / RESTRICT), UNIQUE, CHECK, NOT NULL, DEFAULT, ENUM |
| Triggers | §2 | 15 — BEFORE and AFTER, on INSERT, UPDATE and DELETE |
| Functions | §3 | 5 stored functions, used inside SELECTs and views |
| Stored procedures | §4 | 7 — IN / OUT parameters, transactions, `EXIT HANDLER`, `SIGNAL` / `RESIGNAL` |
| Explicit cursors | §5a–5c | `DECLARE … CURSOR`, `OPEN`, `FETCH`, `CLOSE`; `LOOP`, `REPEAT`, `WHILE` styles |
| Nested cursors | §5c | cursor inside a cursor, each with its own `NOT FOUND` handler |
| Implicit cursors | §5d, §4f–4g | `SELECT … INTO`, `ROW_COUNT()`, `NOT FOUND` / `TOO_MANY_ROWS` handlers |
| Views | §6 | 9 — aggregate, multi-join, nested, updatable `WITH CHECK OPTION`, restricted |
| DML | §8 | INSERT / UPDATE / DELETE, UPSERT, multi-table, subquery-driven, via a view |
| Joins | §10 | INNER, LEFT, RIGHT, FULL (emulated), CROSS, SELF, NATURAL, USING, non-equi, anti-join |
| Subqueries | §11 | scalar, multi-row, `IN` / `NOT IN`, `ANY` / `ALL`, `EXISTS`, correlated, nested (3 levels), derived table, row subquery |
| CTEs, windows, sets | §12 | `WITH`, `WITH RECURSIVE`, ranking / `LAG` / `LEAD` / frames, `UNION`, `INTERSECT` / `EXCEPT`, `ROLLUP` |
| Transactions | §14 | `START TRANSACTION`, `COMMIT`, `ROLLBACK`, `SAVEPOINT` |
| Event scheduler | §15 | daily job that expires incomplete applications |
| Self-test | §16 | 13 attempted rule violations, each caught and reported |
| DCL | §17 | roles, `GRANT`, `REVOKE` (commented out; needs an admin account) |

### A note on "PL/SQL"

PL/SQL is Oracle's language. MySQL's equivalent is its stored-program language (SQL/PSM), and this project uses it throughout. The mapping:

| Oracle PL/SQL | MySQL used here |
|---|---|
| Procedure / function / trigger | `CREATE PROCEDURE` / `FUNCTION` / `TRIGGER` |
| Explicit cursor (`CURSOR … OPEN / FETCH / CLOSE`) | `DECLARE … CURSOR FOR`, `OPEN`, `FETCH`, `CLOSE` |
| Cursor `%NOTFOUND` | `DECLARE CONTINUE HANDLER FOR NOT FOUND` |
| Implicit cursor, `SELECT … INTO` | `SELECT … INTO` |
| `SQL%ROWCOUNT`, `SQL%NOTFOUND` | `ROW_COUNT()` |
| `NO_DATA_FOUND`, `TOO_MANY_ROWS` | `NOT FOUND` handler, error `1172` handler |
| `RAISE_APPLICATION_ERROR` | `SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = …` |
| `EXCEPTION WHEN … THEN` | `DECLARE … HANDLER`, `GET DIAGNOSTICS`, `RESIGNAL` |
| `DBMS_SCHEDULER` job | `CREATE EVENT` |

MySQL has no `FOR rec IN (SELECT …) LOOP` shortcut; an explicit cursor loop is how that is done.

## Logic

### Triggers

| Trigger | Fires | Does |
|---|---|---|
| `trg_app_before_insert` | BEFORE INSERT on `Application_Master` | trims names, lower-cases the e-mail, rejects bad e-mails and applicants under 16 |
| `trg_app_after_insert` | AFTER INSERT on `Application_Master` | logs the first status (`NULL → SUBMITTED`) |
| `trg_app_guard_update` | BEFORE UPDATE on `Application_Master` | blocks re-opening a decided application and freezes its score |
| `trg_log_status_change` | AFTER UPDATE on `Application_Master` | logs every status change into `Application_Status_History` |
| `trg_app_archive_delete` | AFTER DELETE on `Application_Master` | writes a tombstone to `Deleted_Applications_Archive` |
| `trg_fee_row_on_accept` | AFTER INSERT on `Acceptance_Table` | creates the `Fee_Payment_Table` row, which is what makes the 1:1 relationship hold |
| `trg_fee_discount_on_scholarship` | AFTER INSERT on `Scholarship_Table` | deducts the award from `amount_due` |
| `trg_scholarship_cap` | BEFORE INSERT on `Scholarship_Table` | rejects an award above the scheme's `max_amount` |
| `trg_fee_status_ins` / `_upd` | BEFORE INSERT / UPDATE on `Fee_Payment_Table` | recomputes `payment_status` from the amounts |
| `trg_fee_audit` | AFTER UPDATE on `Fee_Payment_Table` | records old and new money values and who changed them |
| `trg_cet_alloc_ins` / `_upd` | BEFORE INSERT / UPDATE on `Course_Eligibility_Table` | enforces seat capacity and at most one `ALLOCATED` course per student |
| `trg_enroll_gate` | BEFORE INSERT on `Enrolled_Students` | requires accepted offer, fees `PAID`, and the allocated course |
| `trg_refund_cap` | BEFORE INSERT on `Refund_Table` | a refund can never exceed the amount paid |

### Functions

`fn_applicant_age(dob)`, `fn_score_band(score)`, `fn_composite_score(jee, school_pct)` (70/30 merit formula), `fn_fee_balance(acceptance_id)`, `fn_seats_left(course_id)`.

### Stored procedures

- `sp_decide_application(application_id, cutoff_score)` — accept / reject / incomplete routing. Validates input, refuses to re-decide an accepted or rejected application, can safely re-decide an incomplete one, and runs as one transaction.
- `sp_approve_appeal(appeal_id)` — approves an appeal, flips the master status, *and* creates the `Acceptance_Table` row. Doing that by hand is the easy way to leave an applicant marked `ACCEPTED` with nothing to join to. Refuses an already-closed appeal.
- `sp_deny_appeal(appeal_id)` — closes the appeal and clears `appeal_eligible`, so nobody appeals twice.
- `sp_record_payment(acceptance_id, amount)` — rejects non-positive amounts and over-payment; the status trigger does the rest.
- `sp_enroll_student(acceptance_id)` — generates the next roll number for the department and enrolls the student, subject to `trg_enroll_gate`.
- `sp_expire_incomplete_applications(OUT expired)` — rejects incomplete applications whose grace period has ended and reports the count via `ROW_COUNT()`.
- `sp_expand_department_seats(department, extra_seats, OUT rows_changed)` — adds seats; raises an error when nothing matched.

### Cursor procedures

- `sp_send_fee_reminders(min_balance, OUT sent)` — explicit cursor, `LOOP … LEAVE`; queues a reminder per unpaid, non-declined fee record.
- `sp_build_merit_rank_list(top_n)` — explicit cursor, `REPEAT … UNTIL`; ranks accepted applicants by composite score with ties sharing a rank (1, 2, 2, 4).
- `sp_course_roster_report()` — **nested** explicit cursors; the outer one walks courses, the inner (`WHILE` loop) walks each course's enrolled students.
- `sp_implicit_cursor_demo(email)` — `SELECT … INTO` with `NOT FOUND` and `TOO_MANY_ROWS` handling.

### Views

| View | Audience / idea |
|---|---|
| `vw_admission_funnel` | applicants by status, with percentage of total |
| `vw_applicant_360` | one row per applicant, master table down to roll number (all `LEFT JOIN`) |
| `vw_fee_defaulters` | finance: who still owes money |
| `vw_course_seat_status` | admissions: allocated, waitlisted, seats left, fill % |
| `vw_pending_documents` | what each incomplete applicant is still missing |
| `vw_scholarship_summary` | awards, total and average per scheme |
| `vw_public_applicant` | front desk: no date of birth, e-mail or scores |
| `vw_open_applications` | updatable, `WITH CHECK OPTION` |
| `vw_category_toppers` | a view built on `vw_applicant_360`: top two per category |

### Event

`ev_expire_incomplete_applications` runs `sp_expire_incomplete_applications` once a day. MySQL only fires events while the scheduler is on: `SET GLOBAL event_scheduler = ON;`.

## Decision logic

The accept/reject/incomplete routing is based directly on what the ERD already specifies:
- `APPLICATION_MASTER → ACCEPTANCE_TABLE` : "if qualifies"
- `APPLICATION_MASTER → REJECTION_TABLE` : "if below cutoff"
- `APPLICATION_MASTER → INCOMPLETE_TABLE` : "if docs missing"

These relationship labels are the actual decision rules, translated into the stored procedure:
1. Check `docs_submitted` first — if `FALSE`, the application goes to Incomplete regardless of score, since missing documents block acceptance even for a high scorer.
2. If docs are complete, compare `jee_score` against a cutoff — `>= cutoff` → Accepted, otherwise → Rejected.

The cutoff value (70.00) isn't from the ERD — it's arbitrary, just picked to get a mix of all three outcomes in the sample data. Replace it with the real cutoff for your use case. In a real system this would likely be category-wise rather than one flat number for everyone.

## Running it

Requires **MySQL 8.0.16 or later** (enforced `CHECK` constraints, window functions, CTEs). The portable forms of `INTERSECT` / `EXCEPT` are used, so 8.0.31 is not required.

Open `review.sql` in MySQL Workbench and run the whole script (lightning bolt icon, or Ctrl+Shift+Enter) rather than statement by statement. It starts with `DROP DATABASE IF EXISTS`, so it can be re-run from scratch anytime. It also runs `SET SQL_SAFE_UPDATES = 0` for the session, because Workbench's default Safe Updates mode blocks several of the `UPDATE` / `DELETE` statements.

Or from the command line:

```bash
mysql -u root -p < review.sql
```

Section 16 deliberately attempts 13 forbidden operations. They are caught inside the procedure and reported in a result table, so they do not stop the script. Every row should show an error message; a row reading `!! NOT BLOCKED` would mean a rule is missing.

## What's included

Sample data for 25 applicants, 8 courses, and 6 scholarship schemes (5 awarded, plus `RURAL` added through the UPSERT example), covering every branch of the workflow: 16 acceptances, 6 standing rejections (8 rejection records, two of them later overturned on appeal), 3 incomplete applications, 4 appeals (two approved, one denied, one still open), 13 scholarship awards, 16 fee records, 12 hostel requests, 3 refunds, 9 enrolments, and 68 communication-log entries (73 once the fee-reminder cursor in §13 has queued its 5 reminders).

Edge cases are deliberately included — an applicant exactly on the cutoff, one 0.10 below it who wins on appeal, a high scorer blocked purely by missing documents, a student who declines after part-paying and gets a refund, and one offer still unanswered.

Downstream rows are keyed off `email` rather than hard-coded ids. The ids are deterministic, since the script drops and recreates the database, but "which student is this row about" should be readable without counting `AUTO_INCREMENT` values by hand.

Some data is derived rather than typed in, which is the point of having the relationships in the first place: fee amounts come from the scholarships awarded, and `Enrolled_Students` is populated by a single `INSERT ... SELECT` that only admits students who cleared all three gates — offer accepted, fees paid, course allocated — generating roll numbers per department with `ROW_NUMBER()`.

Demonstrations that would change the data (payment and enrollment, seat expansion, the expiry job, the savepoint example) run inside a transaction and are rolled back. Only two statements in the demo sections change data permanently: the fee reminders queued by the cursor, and Priya's extra Rs 10,000 payment in the `COMMIT` example.

## Queries

54 numbered query blocks:

- **§9 core (15)** — joins, aggregates, the audit trail, seat demand, category-wise outcomes, scholarship spend, appeal outcomes, offers that never converted, and an integrity check that no one is marked `ACCEPTED` without an acceptance row.
- **§10 joins (11)** — one for each join type listed above, plus a many-table join over a derived table.
- **§11 subqueries (13)** — scalar, `IN` / `NOT IN`, `ANY` / `ALL`, `EXISTS`, correlated in `WHERE` / `SELECT` / `MAX`, `HAVING`, row subquery, three-level nesting.
- **§12 CTEs, windows, sets (15)** — recursive CTEs for a histogram and a date calendar, ranking / `LAG` / moving averages / `PERCENT_RANK`, `UNION`, `INTERSECT` / `EXCEPT`, `ROLLUP`, `GROUP_CONCAT`.

## Possible extensions

- Category-wise cutoffs instead of one flat number
- A cursor-driven waitlist-promotion procedure that fills freed seats in merit order
- An installments table so fee payment is more than a running total
- Role-based `GRANT`s (sketched, commented out, in §17)
