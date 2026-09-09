# Admission Workflow Management System

A MySQL project that models a college admission process end to end — from application submission to acceptance/rejection, course allocation, fee payment, hostel allotment, and final enrollment.

## How it works

Every application starts in `Application_Master`. Based on `jee_score` and `docs_submitted`, it's routed into one of three outcomes:

- **Accepted** (score ≥ cutoff, docs complete) → `Acceptance_Table`
- **Rejected** (score below cutoff) → `Rejection_Table`
- **Incomplete** (docs missing) → `Incomplete_Table`

From there, accepted students branch out into course allocation, scholarships, fee payment, hostel accommodation, and enrollment. Rejected students can file an appeal. Incomplete applications get a document checklist and a grace period. Status changes and notifications are logged automatically.

## Schema

16 tables. `Application_Master` is the master table — every applicant gets exactly one row there first, and nothing downstream can exist without it. Every other applicant-owned table reaches it by foreign key, directly or through a parent:

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
```

`Course_Master` and `Scholarship_Master` are the two lookup tables — shared reference data, not owned by any one applicant.

Applicant-owned tables cascade on delete, so removing an application removes its whole subtree. The two lookup tables use `ON DELETE RESTRICT`, so a course or scholarship scheme that is still referenced cannot be deleted out from under the rows that point at it.

Beyond the foreign keys, the schema enforces:

- `UNIQUE (acceptance_id, priority_preference)` and `UNIQUE (acceptance_id, course_id)` — one course per priority slot, and no listing the same course twice
- `UNIQUE (acceptance_id, scholarship_code)` — no double-awarding the same scheme
- `UNIQUE (incomplete_id, document_type)` — no duplicate checklist entries
- `UNIQUE` on `allotted_room_number` and `roll_number` — no two students in one room or on one roll number
- `CHECK` constraints on score ranges, seat counts, and money amounts

## logic

**Triggers**

- `trg_log_status_change` — fires whenever `Application_Master.status` changes and logs it into `Application_Status_History` automatically, so it can't be forgotten or fall out of sync.
- `trg_fee_row_on_accept` — creates the `Fee_Payment_Table` row as soon as an acceptance exists. This is what makes the 1:1 relationship actually hold: someone accepted later, on appeal, can't end up with no fee record just because the bulk load already ran.
- `trg_fee_discount_on_scholarship` — deducts an award from `amount_due` whenever it is granted, so the fee stays derived from `Scholarship_Table` rather than hand-entered.
- `trg_fee_status_ins` / `trg_fee_status_upd` — recompute `payment_status` from `amount_paid` vs `amount_due`, so the enum can never contradict the numbers next to it.
- `trg_scholarship_cap` — rejects an award larger than the scheme's `max_amount`.

**Stored procedures**

- `sp_decide_application(application_id, cutoff_score)` — runs the accept/reject/incomplete routing logic and inserts the correct child row.
- `sp_approve_appeal(appeal_id)` — approves an appeal, flips the master status, *and* creates the `Acceptance_Table` row. Doing that by hand is the easy way to leave an applicant marked `ACCEPTED` with nothing to join to, which every downstream query then silently drops.

**Views**

- `vw_admission_funnel` — count of applicants by status, for a dashboard.
- `vw_applicant_360` — one row per applicant, walking the chain from the master table down to course, fees, hostel, and roll number. All `LEFT JOIN`, because most applicants stop partway.

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

Open `review.sql` in MySQL Workbench and run the whole script (lightning bolt icon, or Ctrl+Shift+Enter) rather than statement by statement. It starts with `DROP DATABASE IF EXISTS`, so it can be re-run from scratch anytime.

Or from the command line:

\`\`\`bash
mysql -u root -p < review.sql
\`\`\`

## What's included

Sample data for 25 applicants, 8 courses, and 5 scholarship schemes, covering every branch of the workflow: 16 acceptances, 6 standing rejections (8 rejection records, two of them later overturned on appeal), 3 incomplete applications, 4 appeals (two approved, one denied, one still open), 13 scholarship awards, 16 fee records, 12 hostel requests, 3 refunds, 9 enrolments, and 68 communication-log entries.

Edge cases are deliberately included — an applicant exactly on the cutoff, one 0.10 below it who wins on appeal, a high scorer blocked purely by missing documents, a student who declines after part-paying and gets a refund, and one offer still unanswered.

Downstream rows are keyed off `email` rather than hard-coded ids. The ids are deterministic, since the script drops and recreates the database, but "which student is this row about" should be readable without counting `AUTO_INCREMENT` values by hand.

Some data is derived rather than typed in, which is the point of having the relationships in the first place: fee amounts come from the scholarships awarded, and `Enrolled_Students` is populated by a single `INSERT ... SELECT` that only admits students who cleared all three gates — offer accepted, fees paid, course allocated — generating roll numbers per department with `ROW_NUMBER()`.

Then 6 DML examples (updates, deletes, cascade behaviour) and 15 DQL queries covering joins, aggregates, subqueries, and window functions — fee balances, seat demand per course, category-wise outcomes, scholarship spend, appeal outcomes, offers that never converted, and an integrity check that no one is marked `ACCEPTED` without an acceptance row.

## Possible extensions

- Scheduled event to auto-reject incomplete applications once the grace period passes
- Enforce seat capacity — refuse an `ALLOCATED` row once a course hits `total_seats`
- Enforce at most one `ALLOCATED` preference per acceptance (a plain constraint can't express it; needs a trigger)
- Separate views for the admissions office vs. the finance team
