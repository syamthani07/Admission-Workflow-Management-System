
-- ============================================================
-- ADMISSION WORKFLOW MANAGEMENT SYSTEM
-- Script 3 of 5: VIEWS AND JOINS
-- Run review.sql first; this script works on the database it builds.
-- Safe to re-run: views use CREATE OR REPLACE, and the update through
-- View 5 is rolled back.
--
-- Views
--   View 1  vw_accepted_students   accepted applicants with allocated course
--   View 2  vw_fee_balance         fee balance per student (computed column)
--   View 3  vw_course_seat_status  seats allocated and left per course (aggregate)
--   View 4  vw_pending_documents   documents each incomplete applicant owes
--   View 5  vw_pending_offers      offers awaiting a reply (updatable, WITH CHECK OPTION)
-- Joins
--   Join 1  INNER JOIN  scholarship awards with student and scheme
--   Join 2  LEFT JOIN   every applicant with rejection and appeal details
--   Join 3  RIGHT JOIN  every course with its enrolled students
--   Join 4  SELF JOIN   same-category applicants within 2 marks
--   Join 5  CROSS JOIN  every CSE course with every scholarship scheme
-- ============================================================

USE admission_workflow_db;

-- Workbench's Safe Updates mode blocks UPDATEs without a key in WHERE
SET SQL_SAFE_UPDATES = 0;


-- ============================================================
-- VIEWS
-- ============================================================

-- View 1: Accepted applicants with their allocated course (join view)
CREATE OR REPLACE VIEW vw_accepted_students AS
SELECT am.application_id,
       CONCAT(am.first_name, ' ', am.last_name) AS student_name,
       am.category,
       am.jee_score,
       acc.student_decision,
       cm.course_name AS allocated_course
FROM Acceptance_Table acc
JOIN Application_Master am             ON am.application_id = acc.application_id
LEFT JOIN Course_Eligibility_Table cet ON cet.acceptance_id = acc.acceptance_id
                                      AND cet.allocation_status = 'ALLOCATED'
LEFT JOIN Course_Master cm             ON cm.course_id = cet.course_id;

SELECT * FROM vw_accepted_students
WHERE student_decision = 'ACCEPTED'
ORDER BY jee_score DESC;

-- View 2: Fee balance per student (view with a computed column)
CREATE OR REPLACE VIEW vw_fee_balance AS
SELECT am.application_id,
       CONCAT(am.first_name, ' ', am.last_name) AS student_name,
       acc.student_decision,
       fp.amount_due,
       fp.amount_paid,
       fp.amount_due - fp.amount_paid AS balance,
       fp.payment_status
FROM Fee_Payment_Table fp
JOIN Acceptance_Table acc  ON acc.acceptance_id  = fp.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id;

SELECT * FROM vw_fee_balance
WHERE balance > 0
ORDER BY balance DESC;

-- View 3: Seats allocated and left per course (aggregate view)
CREATE OR REPLACE VIEW vw_course_seat_status AS
SELECT cm.course_name,
       cm.department,
       cm.total_seats,
       COUNT(cet.eligibility_id)                                    AS allocated,
       cm.total_seats - COUNT(cet.eligibility_id)                   AS seats_left,
       ROUND(COUNT(cet.eligibility_id) * 100 / cm.total_seats, 1)   AS fill_pct
FROM Course_Master cm
LEFT JOIN Course_Eligibility_Table cet ON cet.course_id = cm.course_id
                                      AND cet.allocation_status = 'ALLOCATED'
GROUP BY cm.course_id, cm.course_name, cm.department, cm.total_seats;

SELECT * FROM vw_course_seat_status ORDER BY fill_pct DESC;

-- View 4: Documents each incomplete applicant still owes
CREATE OR REPLACE VIEW vw_pending_documents AS
SELECT am.application_id,
       CONCAT(am.first_name, ' ', am.last_name) AS applicant_name,
       it.grace_period_end,
       COUNT(*) AS documents_missing,
       GROUP_CONCAT(dc.document_type ORDER BY dc.document_type SEPARATOR ', ') AS missing_documents
FROM Incomplete_Table it
JOIN Application_Master am ON am.application_id = it.application_id
JOIN Document_Checklist dc ON dc.incomplete_id  = it.incomplete_id
WHERE dc.status IN ('PENDING', 'REJECTED')
GROUP BY am.application_id, am.first_name, am.last_name, it.grace_period_end;

SELECT * FROM vw_pending_documents ORDER BY documents_missing DESC;

-- View 5: Offers awaiting a reply (updatable view, WITH CHECK OPTION).
--         Updates through the view reach Acceptance_Table; CHECK OPTION
--         blocks any change that would move a row out of the view.
CREATE OR REPLACE VIEW vw_pending_offers AS
SELECT acceptance_id, application_id, offer_date, response_deadline, student_decision
FROM Acceptance_Table
WHERE student_decision = 'PENDING'
WITH CHECK OPTION;

SELECT * FROM vw_pending_offers;

-- Extend every pending deadline by a week through the view, then undo it
START TRANSACTION;
UPDATE vw_pending_offers
SET response_deadline = DATE_ADD(response_deadline, INTERVAL 7 DAY);
SELECT * FROM vw_pending_offers;
ROLLBACK;


-- ============================================================
-- JOINS
-- ============================================================

-- Join 1: INNER JOIN -- every scholarship award with the student and the scheme
SELECT am.first_name, am.last_name, sm.scholarship_name,
       st.amount_awarded, sm.max_amount
FROM Scholarship_Table st
INNER JOIN Scholarship_Master sm ON sm.scholarship_code = st.scholarship_code
INNER JOIN Acceptance_Table acc  ON acc.acceptance_id   = st.acceptance_id
INNER JOIN Application_Master am ON am.application_id   = acc.application_id
ORDER BY sm.scholarship_name, st.amount_awarded DESC;

-- Join 2: LEFT JOIN -- every applicant, with rejection and appeal details where they exist
SELECT am.application_id, am.first_name, am.last_name, am.status,
       rt.rejection_reason, ap.appeal_status
FROM Application_Master am
LEFT JOIN Rejection_Table rt ON rt.application_id = am.application_id
LEFT JOIN Appeal_Table ap    ON ap.rejection_id   = rt.rejection_id
ORDER BY am.application_id;

-- Join 3: RIGHT JOIN -- every course, with its enrolled students (NULL when none)
SELECT cm.course_name, cm.department, es.roll_number, es.enrollment_date
FROM Enrolled_Students es
RIGHT JOIN Course_Master cm ON cm.course_id = es.course_id
ORDER BY cm.course_name, es.roll_number;

-- Join 4: SELF JOIN -- pairs of applicants in the same category within 2 marks of each other
SELECT a.category,
       a.first_name AS applicant_1, a.jee_score AS score_1,
       b.first_name AS applicant_2, b.jee_score AS score_2,
       ABS(a.jee_score - b.jee_score) AS difference
FROM Application_Master a
JOIN Application_Master b ON  b.category = a.category
                          AND b.application_id > a.application_id
                          AND ABS(a.jee_score - b.jee_score) <= 2
ORDER BY a.category, difference;

-- Join 5: CROSS JOIN -- every CSE course paired with every scholarship scheme,
--         showing the lowest fee possible (150000 is the base tuition)
SELECT cm.course_name, sm.scholarship_name,
       150000.00 - sm.max_amount AS lowest_possible_fee
FROM Course_Master cm
CROSS JOIN Scholarship_Master sm
WHERE cm.department = 'CSE'
ORDER BY cm.course_name, lowest_possible_fee;


-- Back to Workbench's default
SET SQL_SAFE_UPDATES = 1;
