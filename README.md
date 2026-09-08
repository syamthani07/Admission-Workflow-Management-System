# Admission Workflow Management System

A MySQL project that models a college admission process end to end — from application submission to acceptance/rejection, course allocation, fee payment, hostel allotment, and final enrollment.

## How it works

Every application starts in `Application_Master`. Based on `jee_score` and `docs_submitted`, it's routed into one of three outcomes:

- **Accepted** (score ≥ cutoff, docs complete) → `Acceptance_Table`
- **Rejected** (score below cutoff) → `Rejection_Table`
- **Incomplete** (docs missing) → `Incomplete_Table`

From there, accepted students branch out into course allocation, scholarships, fee payment, hostel accommodation, and enrollment. Rejected students can file an appeal. Incomplete applications get a document checklist and a grace period. Status changes and notifications are logged automatically.

## Schema

15 tables in total:

- `Application_Master` — entry point for every application
- `Acceptance_Table`, `Rejection_Table`, `Incomplete_Table` — the three outcomes
- `Course_Eligibility_Table`, `Scholarship_Table`, `Fee_Payment_Table`, `Hostel_Accommodation_Table` — branch off acceptance
- `Course_Master` — lookup table for available courses
- `Appeal_Table` — branches off rejection
- `Document_Checklist` — branches off incomplete
- `Refund_Table` — branches off fee payment
- `Enrolled_Students` — final node, populated once fees + course allocation are done
- `Application_Status_History`, `Communication_Log` — audit logs tied to `Application_Master`

## logic

- **Trigger:** `trg_log_status_change` — fires whenever `Application_Master.status` changes and logs it into `Application_Status_History` automatically, so it can't be forgotten or fall out of sync.
- **Stored procedure:** `sp_decide_application(application_id, cutoff_score)` — runs the accept/reject/incomplete routing logic and inserts the correct child row.
- **View:** `vw_admission_funnel` — quick count of applicants by status, for a dashboard.

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

Open `admission_workflow.sql` in MySQL Workbench and run the whole script (lightning bolt icon, or Ctrl+Shift+Enter) rather than statement by statement. It starts with `DROP DATABASE IF EXISTS`, so it can be re-run from scratch anytime.

Or from the command line:

\`\`\`bash
mysql -u root -p < admission_workflow.sql
\`\`\`

## What's included

Sample data for 4 courses and 5 applicants covering all three outcomes (including one appeal that gets approved), plus DML examples (updates, deletes) and DQL examples (joins, aggregates, subqueries) for common reporting needs like fee balances, seat demand per course, and pending document reminders.

## Possible extensions

- Trigger to auto-populate `Enrolled_Students` once fees are paid and a course is allocated
- Scheduled event to auto-reject incomplete applications once the grace period passes
- Separate views for the admissions office vs. the finance team
