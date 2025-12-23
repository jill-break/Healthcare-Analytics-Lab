-- ETL SCRIPT: OLTP (Source) -> OLAP (Target)
-- Source DB: oltp_healthtech
-- Target DB: olap_healthtech

-- 0. HELPER: Create Index on Source for Speed
-- If this fails with "Duplicate Key", just ignore it and continue.
-- We removed 'IF NOT EXISTS' to fix your Error 1064.
CREATE INDEX idx_etl_speed 
ON oltp_healthtech.encounters(patient_id, encounter_date, encounter_type);

-- 1. LOAD DIMENSIONS (Directly from OLTP)

INSERT INTO olap_healthtech.dim_specialty (specialty_id, specialty_name, specialty_code)
SELECT specialty_id, specialty_name, specialty_code 
FROM oltp_healthtech.specialties;

INSERT INTO olap_healthtech.dim_department (department_id, department_name, floor, capacity)
SELECT department_id, department_name, floor, capacity 
FROM oltp_healthtech.departments;

INSERT INTO olap_healthtech.dim_provider (provider_id, full_name, credential)
SELECT provider_id, CONCAT(first_name, ' ', last_name), credential 
FROM oltp_healthtech.providers;

INSERT INTO olap_healthtech.dim_patient (patient_id, first_name, last_name, gender, date_of_birth, mrn, current_age, age_group)
SELECT 
    patient_id, first_name, last_name, gender, date_of_birth, mrn,
    TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()),
    CASE 
        WHEN TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()) < 18 THEN '0-18'
        WHEN TIMESTAMPDIFF(YEAR, date_of_birth, CURDATE()) BETWEEN 18 AND 65 THEN '19-65'
        ELSE '65+'
    END
FROM oltp_healthtech.patients;

INSERT INTO olap_healthtech.dim_encounter_type (encounter_type_name)
SELECT DISTINCT encounter_type 
FROM oltp_healthtech.encounters;

INSERT INTO olap_healthtech.dim_diagnoses (diagnosis_id, icd10_code, icd10_description)
SELECT diagnosis_id, icd10_code, icd10_description 
FROM oltp_healthtech.diagnoses;

INSERT INTO olap_healthtech.dim_procedures (procedure_id, cpt_code, cpt_description)
SELECT procedure_id, cpt_code, cpt_description 
FROM oltp_healthtech.procedures;

-- Load Date Dimension
INSERT INTO olap_healthtech.dim_date (date_key, full_date, year, quarter, month, month_name, week_of_year, day_of_month, day_name, is_weekend)
SELECT DISTINCT 
    CAST(DATE_FORMAT(encounter_date, '%Y%m%d') AS UNSIGNED),
    DATE(encounter_date),
    YEAR(encounter_date),
    QUARTER(encounter_date),
    MONTH(encounter_date),
    MONTHNAME(encounter_date),
    WEEKOFYEAR(encounter_date),
    DAY(encounter_date),
    DAYNAME(encounter_date),
    CASE WHEN DAYOFWEEK(encounter_date) IN (1, 7) THEN 1 ELSE 0 END
FROM oltp_healthtech.encounters;

-- 2. STAGED LOAD FOR FACT TABLE

-- Stage A: Create Temporary Helper Tables for Counts
DROP TEMPORARY TABLE IF EXISTS temp_diag_counts;
DROP TEMPORARY TABLE IF EXISTS temp_proc_counts;

CREATE TEMPORARY TABLE temp_diag_counts (
    encounter_id INT PRIMARY KEY,
    cnt INT
);

INSERT INTO temp_diag_counts (encounter_id, cnt)
SELECT encounter_id, COUNT(*) 
FROM oltp_healthtech.encounter_diagnoses 
GROUP BY encounter_id;

CREATE TEMPORARY TABLE temp_proc_counts (
    encounter_id INT PRIMARY KEY,
    cnt INT
);

INSERT INTO temp_proc_counts (encounter_id, cnt)
SELECT encounter_id, COUNT(*) 
FROM oltp_healthtech.encounter_procedures 
GROUP BY encounter_id;

-- Stage B: Insert into Fact Table (With 10,000 Limit)
INSERT INTO olap_healthtech.fact_encounters (
    encounter_id, date_key, patient_key, provider_key, specialty_key, department_key, encounter_type_key,
    is_readmission, total_claim_amount, total_allowed_amount, length_of_stay_days, diagnosis_count, procedure_count
)
SELECT 
    e.encounter_id,
    CAST(DATE_FORMAT(e.encounter_date, '%Y%m%d') AS UNSIGNED) AS date_key,
    pat.patient_key,
    prov.provider_key,
    spec.specialty_key,
    dept.department_key,
    et.encounter_type_key,
    
    0, -- Default to 0, will update in Stage C
    
    COALESCE(b.claim_amount, 0),
    COALESCE(b.allowed_amount, 0),
    DATEDIFF(e.discharge_date, e.encounter_date),
    COALESCE(td.cnt, 0),
    COALESCE(tp.cnt, 0)

FROM oltp_healthtech.encounters e
-- Join to Dimensions to get Surrogate Keys
JOIN olap_healthtech.dim_patient pat ON e.patient_id = pat.patient_id
JOIN olap_healthtech.dim_provider prov ON e.provider_id = prov.provider_id
JOIN olap_healthtech.dim_department dept ON e.department_id = dept.department_id
JOIN olap_healthtech.dim_encounter_type et ON e.encounter_type = et.encounter_type_name
-- Join back to OLTP Source to get Specialty ID correctly
JOIN oltp_healthtech.providers p_source ON e.provider_id = p_source.provider_id
JOIN olap_healthtech.dim_specialty spec ON p_source.specialty_id = spec.specialty_id

-- Join Optional Tables
LEFT JOIN oltp_healthtech.billing b ON e.encounter_id = b.encounter_id
LEFT JOIN temp_diag_counts td ON e.encounter_id = td.encounter_id
LEFT JOIN temp_proc_counts tp ON e.encounter_id = tp.encounter_id
LIMIT 10000;

-- Stage C: Update Readmission Logic

-- 1. Disable Safe Update Mode temporarily
SET SQL_SAFE_UPDATES = 0;

-- 2. Run the Update
UPDATE olap_healthtech.fact_encounters f
JOIN oltp_healthtech.encounters e ON f.encounter_id = e.encounter_id
SET f.is_readmission = 1
WHERE EXISTS (
    SELECT 1 FROM oltp_healthtech.encounters e2 
    WHERE e2.patient_id = e.patient_id 
    AND e2.encounter_date < e.encounter_date 
    AND e2.encounter_date >= DATE_SUB(e.encounter_date, INTERVAL 30 DAY)
    AND e2.encounter_type = 'Inpatient'
);

-- 3. Re-enable Safe Update Mode (Good practice)
SET SQL_SAFE_UPDATES = 1;


-- 3. LOAD BRIDGE TABLES

INSERT INTO olap_healthtech.bridge_encounter_diagnoses (encounter_key, diagnosis_key, diagnosis_sequence)
SELECT f.encounter_key, d.diagnosis_key, ed.diagnosis_sequence
FROM oltp_healthtech.encounter_diagnoses ed
JOIN olap_healthtech.fact_encounters f ON ed.encounter_id = f.encounter_id
JOIN olap_healthtech.dim_diagnoses d ON ed.diagnosis_id = d.diagnosis_id;

INSERT INTO olap_healthtech.bridge_encounter_procedures (encounter_key, procedure_key, procedure_date)
SELECT f.encounter_key, p.procedure_key, ep.procedure_date
FROM oltp_healthtech.encounter_procedures ep
JOIN olap_healthtech.fact_encounters f ON ep.encounter_id = f.encounter_id
JOIN olap_healthtech.dim_procedures p ON ep.procedure_id = p.procedure_id;

-- Cleanup
DROP TEMPORARY TABLE temp_diag_counts;
DROP TEMPORARY TABLE temp_proc_counts;