# Admission Workflow Management System

A MySQL project that models a college admission process, from application to acceptance or rejection, course allocation, scholarships, fee payment, hostel allotment and enrollment.

`review.sql` builds the database and sample data. Five lab scripts then work through the SQL topics on top of it.

## Files

| File | What it does |
|---|---|
| `review.sql` | Creates `admission_workflow_db`: 16 tables, 6 triggers, 2 procedures, 2 views and sample data |
| `1_queries_subqueries.sql` | 5 queries, 5 subqueries |
| `2_nested_correlated_queries.sql` | 5 nested queries, 5 correlated queries |
| `3_views_joins.sql` | 5 views, 5 joins |
| `4_plsql.sql` | 5 PL/SQL-style stored functions |
| `5_triggers_cursors_procedures.sql` | 5 triggers, 5 cursors, 5 procedures |

## Running it

Requires **MySQL 8.0.16 or later** (enforced `CHECK` constraints, window functions).

1. Run `review.sql`. It starts with `DROP DATABASE IF EXISTS`, so it always gives a clean copy.
2. Run any of the five lab scripts, in any order. Each one only needs `review.sql`, not the others.

In MySQL Workbench, open a file with **File → Open SQL Script…** and run the whole thing with the lightning-bolt button (Ctrl+Shift+Enter). From the command line:

```bash
mysql -u <user> -p < review.sql
mysql -u <user> -p < 1_queries_subqueries.sql
```

The lab scripts are safe to re-run. Every view, function, trigger and procedure is dropped before it is created. Every demo that changes data runs inside a transaction that is rolled back, so the sample data stays as `review.sql` left it.

Re-running `review.sql` wipes everything the lab scripts created, so run them again afterwards.

## Schema

`Application_Master` is the entry point: every applicant gets one row there first, and every other applicant-owned table links back to it.

```
Application_Master
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
```

`Course_Master` and `Scholarship_Master` are lookup tables shared by all applicants.

`sp_decide_application` routes each application:

- Documents missing → **Incomplete**
- JEE score ≥ cutoff (70.00) → **Accepted**
- Otherwise → **Rejected**, with the option to appeal

The sample data has 25 applicants, 8 courses and 5 scholarship schemes. It ends with 16 accepted, 6 rejected and 3 incomplete applicants, 4 appeals (2 approved, 1 denied, 1 still open), 13 scholarship awards, 12 hostel requests, 3 refunds and 9 enrolled students.

## Lab scripts

Each script's header lists its items. Items are labelled "Query 1", "Trigger 3" and so on.

**1. Queries and subqueries**
- Queries: WHERE / ORDER BY / LIMIT, aggregate functions, GROUP BY + HAVING, BETWEEN + LIKE, CASE
- Subqueries: scalar, `IN`, `NOT IN`, `ALL`, subquery in `FROM`

**2. Nested and correlated queries**
- Nested: second-highest score, up to 5 levels of nesting, comparison against an average of counts
- Correlated: above own category's average, top scorer per category, `EXISTS`, `NOT EXISTS`, subqueries in `SELECT`

**3. Views and joins**
- Views: `vw_accepted_students`, `vw_fee_balance`, `vw_course_seat_status`, `vw_pending_documents`, and `vw_pending_offers` (updatable, `WITH CHECK OPTION`)
- Joins: `INNER`, `LEFT`, `RIGHT`, `SELF`, `CROSS`

**4. PL/SQL**

PL/SQL is Oracle's language. MySQL's equivalent is stored programs, so each item is a function built around one construct:

- `fn_score_grade` uses `IF / ELSEIF`
- `fn_category_concession` uses `CASE`
- `fn_working_days_left` uses a `WHILE` loop
- `fn_fee_balance` uses a `NOT FOUND` handler
- `fn_merit_score` uses variables and arithmetic

**5. Triggers, cursors and procedures**
- Triggers: clean input, minimum age 16, log new applications, refund cap, seat guard
- Cursors: `LOOP … LEAVE`, `REPEAT … UNTIL`, `WHILE`, a cursor that writes data, nested cursors
- Procedures: `IN`, `OUT` and `INOUT` parameters, checks before an `UPDATE`, error handlers

The five triggers from script 5 stay active after it runs. New applicants are trimmed, age-checked and logged automatically.
