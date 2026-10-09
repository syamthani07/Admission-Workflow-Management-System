
-- ============================================================
-- ADMISSION WORKFLOW MANAGEMENT SYSTEM
-- Script 2 of 5: NESTED AND CORRELATED QUERIES
-- Run review.sql first; this script works on the database it builds.
--
-- Nested queries (a subquery inside a subquery)
--   Nested query 1      Applicant with the second-highest JEE score
--   Nested query 2      Students enrolled in the course with the most seats
--   Nested query 3      Students with the largest single scholarship award
--   Nested query 4      Courses with more allocations than the average course
--   Nested query 5      Rejected applicants whose appeal was denied
-- Correlated queries (the inner query uses the outer row)
--   Correlated query 1  Applicants above their own category's average
--   Correlated query 2  Top scorer in each category
--   Correlated query 3  Applicants holding a scholarship (EXISTS)
--   Correlated query 4  Offers not yet turned into an enrollment (NOT EXISTS)
--   Correlated query 5  Awards per scholarship scheme (subqueries in SELECT)
-- ============================================================

USE admission_workflow_db;


-- ============================================================
-- NESTED QUERIES
-- ============================================================

-- Nested query 1: The applicant with the second-highest JEE score
SELECT first_name, last_name, jee_score
FROM Application_Master
WHERE jee_score = (
    SELECT MAX(jee_score) FROM Application_Master
    WHERE jee_score < (SELECT MAX(jee_score) FROM Application_Master)
);

-- Nested query 2: Students enrolled in the course with the most seats (5 levels deep)
SELECT first_name, last_name
FROM Application_Master
WHERE application_id IN (
    SELECT application_id FROM Acceptance_Table
    WHERE acceptance_id IN (
        SELECT acceptance_id FROM Enrolled_Students
        WHERE course_id = (
            SELECT course_id FROM Course_Master
            WHERE total_seats = (SELECT MAX(total_seats) FROM Course_Master)
        )
    )
);

-- Nested query 3: Students who received the largest single scholarship award
SELECT first_name, last_name, category
FROM Application_Master
WHERE application_id IN (
    SELECT application_id FROM Acceptance_Table
    WHERE acceptance_id IN (
        SELECT acceptance_id FROM Scholarship_Table
        WHERE amount_awarded = (SELECT MAX(amount_awarded) FROM Scholarship_Table)
    )
);

-- Nested query 4: Courses with more allocations than the average course
SELECT course_name, department
FROM Course_Master
WHERE course_id IN (
    SELECT course_id FROM Course_Eligibility_Table
    WHERE allocation_status = 'ALLOCATED'
    GROUP BY course_id
    HAVING COUNT(*) > (
        SELECT AVG(allocated) FROM (
            SELECT COUNT(*) AS allocated FROM Course_Eligibility_Table
            WHERE allocation_status = 'ALLOCATED'
            GROUP BY course_id
        ) per_course
    )
);

-- Nested query 5: Rejected applicants whose appeal was denied
SELECT first_name, last_name, jee_score, status
FROM Application_Master
WHERE application_id IN (
    SELECT application_id FROM Rejection_Table
    WHERE rejection_id IN (
        SELECT rejection_id FROM Appeal_Table WHERE appeal_status = 'DENIED'
    )
);


-- ============================================================
-- CORRELATED QUERIES
-- ============================================================

-- Correlated query 1: Applicants who scored above their own category's average
SELECT a.first_name, a.last_name, a.category, a.jee_score
FROM Application_Master a
WHERE a.jee_score > (
    SELECT AVG(b.jee_score) FROM Application_Master b
    WHERE b.category = a.category
)
ORDER BY a.category, a.jee_score DESC;

-- Correlated query 2: Top scorer in each category
SELECT a.category, a.first_name, a.last_name, a.jee_score
FROM Application_Master a
WHERE a.jee_score = (
    SELECT MAX(b.jee_score) FROM Application_Master b
    WHERE b.category = a.category
)
ORDER BY a.jee_score DESC;

-- Correlated query 3: Applicants holding at least one scholarship (EXISTS)
SELECT am.first_name, am.last_name, am.category
FROM Application_Master am
WHERE EXISTS (
    SELECT 1
    FROM Acceptance_Table acc
    JOIN Scholarship_Table st ON st.acceptance_id = acc.acceptance_id
    WHERE acc.application_id = am.application_id
)
ORDER BY am.first_name;

-- Correlated query 4: Offers that have not turned into an enrollment (NOT EXISTS)
SELECT am.first_name, am.last_name, acc.student_decision
FROM Acceptance_Table acc
JOIN Application_Master am ON am.application_id = acc.application_id
WHERE NOT EXISTS (
    SELECT 1 FROM Enrolled_Students es
    WHERE es.acceptance_id = acc.acceptance_id
)
ORDER BY acc.student_decision, am.first_name;

-- Correlated query 5: Awards and largest award per scholarship scheme (correlated subqueries in SELECT)
SELECT sm.scholarship_name, sm.max_amount,
       (SELECT COUNT(*) FROM Scholarship_Table st
        WHERE st.scholarship_code = sm.scholarship_code)          AS awards,
       (SELECT MAX(st.amount_awarded) FROM Scholarship_Table st
        WHERE st.scholarship_code = sm.scholarship_code)          AS largest_award
FROM Scholarship_Master sm
ORDER BY awards DESC;
