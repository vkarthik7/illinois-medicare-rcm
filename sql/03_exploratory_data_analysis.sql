/* ============================================================================
   HOSPITAL MANAGEMENT SYSTEM (HMS)  —  PHASE 3: EXPLORATORY DATA ANALYSIS
   ----------------------------------------------------------------------------
   PURPOSE
     Five analytical queries that answer real revenue-cycle (RCM) questions
     against the star schema, progressing from basic aggregation to chained
     CTEs with window functions. Each query states its business question, the
     technique it demonstrates, and the headline finding.

   READING THE MONEY MATH
     billed_amount / paid_amount are AVERAGES per service, so every dollar total
     is  SUM(amount * total_services)  — average per service × number of services.

   READING THE "RATE"
     paid / billed is the share of the provider's LIST PRICE that Medicare pays.
     A low value isn't bad collections — it's the gap between a provider's
     submitted charge and Medicare's fixed fee schedule. (Power BI labels this
     "Collection Rate"; conceptually it's a payment-to-charge ratio.)
   ============================================================================ */

USE healthcare_db;


/* ============================================================================
   QUERY 1  —  Payment-to-charge ratio by specialty (worst performers)
   QUESTION : Which specialties have the biggest billed-vs-paid gap?
   TECHNIQUE: aggregate SUM with GROUP BY + HAVING (filter groups, not rows)
   FINDING  : Anesthesia specialties land at only 7–9%, because Medicare prices
              anesthesia on a unit-based formula far below the list charge.
   HAVING vs WHERE: WHERE filters individual rows BEFORE grouping; HAVING
   filters the GROUPS after aggregation (here, keep specialties with >100 claims).
   ============================================================================ */
SELECT
    doc.specialty,
    COUNT(*)                                                       AS total_claims,
    CONCAT('$', FORMAT(SUM(f.billed_amount * f.total_services), 0)) AS total_billed,
    CONCAT('$', FORMAT(SUM(f.paid_amount   * f.total_services), 0)) AS total_paid,
    CONCAT(ROUND(
        SUM(f.paid_amount   * f.total_services) /
        SUM(f.billed_amount * f.total_services) * 100, 1), '%')     AS collection_rate
FROM fact_claims f
JOIN dim_doctors doc ON f.doctor_id = doc.doctor_id
GROUP BY doc.specialty
HAVING COUNT(*) > 100                       -- ignore tiny, noisy specialties
ORDER BY
    SUM(f.paid_amount   * f.total_services) /
    SUM(f.billed_amount * f.total_services) ASC     -- lowest ratio first
LIMIT 15;


/* ============================================================================
   QUERY 2  —  Top 3 providers within each specialty by Medicare payment
   QUESTION : Who are the biggest billers inside every specialty?
   TECHNIQUE: RANK() window function with PARTITION BY
   FINDING  : Tempus AI (a lab) was #1 overall at $148M.
   HOW IT WORKS: RANK() restarts the numbering for each specialty (PARTITION BY
   specialty) and orders providers by total paid. The window function has to run
   in an inner query first, then the outer query keeps only ranks 1–3, because
   you can't reference a window alias inside a WHERE on the same query level.
   ============================================================================ */
SELECT *
FROM (
    SELECT
        doc.specialty,
        CONCAT(doc.first_name, ' ', doc.last_name) AS provider_name,
        doc.city,
        SUM(f.paid_amount * f.total_services)       AS total_paid,
        RANK() OVER (
            PARTITION BY doc.specialty
            ORDER BY SUM(f.paid_amount * f.total_services) DESC
        ) AS rank_in_specialty
    FROM fact_claims f
    JOIN dim_doctors doc ON f.doctor_id = doc.doctor_id
    GROUP BY doc.doctor_id, doc.specialty, doc.first_name, doc.last_name, doc.city
) ranked
WHERE rank_in_specialty <= 3
ORDER BY specialty, rank_in_specialty;


/* ============================================================================
   QUERY 3  —  Biggest write-off procedures
   QUESTION : Which procedures leave the most money unpaid (billed − paid)?
   TECHNIQUE: a single CTE (a named, reusable subquery via WITH)
   FINDING  : Office visits = $679M written off (driven by sheer volume); knee
              replacement has the lowest payment ratio at ~10%.
   WHY A CTE: we compute the per-procedure totals once in procedure_totals, then
   read from it in the main query — cleaner and easier to read than nesting.
   ============================================================================ */
WITH procedure_totals AS (
    SELECT
        p.hcpcs_code,
        p.description,
        SUM(f.billed_amount * f.total_services) AS total_billed,
        SUM(f.paid_amount   * f.total_services) AS total_paid,
        SUM(f.total_services)                   AS times_performed
    FROM fact_claims f
    JOIN dim_procedures p ON f.procedure_id = p.procedure_id
    GROUP BY p.hcpcs_code, p.description
)
SELECT
    description,
    times_performed,
    total_billed,
    total_paid,
    total_billed - total_paid                        AS amount_written_off,
    ROUND(total_paid / total_billed * 100, 1)        AS collection_pct
FROM procedure_totals
WHERE total_billed > 1000000                          -- focus on material procedures
ORDER BY amount_written_off DESC
LIMIT 15;


/* ============================================================================
   QUERY 4  —  Geographic analysis by city
   QUESTION : Which Illinois cities capture the most Medicare spending?
   TECHNIQUE: GROUP BY with COUNT(DISTINCT) to count providers per city
   FINDING  : Peoria ranks #2 statewide ($108M); the payment ratio swings
              12–38% based on each city's PROVIDER MIX, not its location.
   ============================================================================ */
SELECT
    doc.city,
    COUNT(DISTINCT doc.doctor_id)                                       AS providers,
    COUNT(*)                                                            AS claims,
    SUM(f.paid_amount * f.total_services)                               AS total_paid,
    ROUND(SUM(f.paid_amount   * f.total_services) /
          SUM(f.billed_amount * f.total_services) * 100, 1)             AS collection_pct
FROM fact_claims f
JOIN dim_doctors doc ON f.doctor_id = doc.doctor_id
GROUP BY doc.city
HAVING COUNT(*) > 500                                 -- only well-represented cities
ORDER BY total_paid DESC
LIMIT 20;


/* ============================================================================
   QUERY 5  —  Market concentration: top provider's share of each department
   QUESTION : What % of a department's Medicare spend goes to its single
              biggest provider?
   TECHNIQUE: two chained CTEs + two window functions in one pass —
              SUM() OVER (department total) and RANK() OVER (top provider)
   FINDING  : Diagnostics is highly concentrated — Tempus AI alone holds 29%;
              every other department is fragmented below 5%.
   HOW IT WORKS:
     provider_spend  → total paid per provider per department
     ranked          → adds the department TOTAL (SUM OVER, no collapse of rows)
                       and the provider's RANK within the department
     final SELECT    → keeps rank 1 and divides their spend by the dept total
   ============================================================================ */
WITH provider_spend AS (
    SELECT
        dept.department_type,
        doc.doctor_id,
        CONCAT(doc.first_name, ' ', doc.last_name) AS provider_name,
        SUM(f.paid_amount * f.total_services)       AS provider_paid
    FROM fact_claims f
    JOIN dim_doctors     doc  ON f.doctor_id     = doc.doctor_id
    JOIN dim_departments dept ON f.department_id = dept.department_id
    GROUP BY dept.department_type, doc.doctor_id, doc.first_name, doc.last_name
),
ranked AS (
    SELECT
        department_type,
        provider_name,
        provider_paid,
        SUM(provider_paid) OVER (PARTITION BY department_type)            AS dept_total,
        RANK() OVER (PARTITION BY department_type ORDER BY provider_paid DESC) AS rnk
    FROM provider_spend
)
SELECT
    department_type,
    provider_name                                    AS top_provider,
    provider_paid                                    AS top_provider_paid,
    dept_total,
    ROUND(provider_paid / dept_total * 100, 1)       AS market_share_pct
FROM ranked
WHERE rnk = 1
ORDER BY market_share_pct DESC;
