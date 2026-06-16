-- ============================================================
-- IEEE-CIS Fraud Detection Pipeline — Database Setup
-- Author: Tshegofatso Skhumbuzo Shabangu (202436819)
-- Run against: ieee_fraud database in PostgreSQL
-- ============================================================

-- Create schemas
CREATE SCHEMA IF NOT EXISTS raw_data;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS models;

-- ============================================================
-- RAW DATA LAYER
-- ============================================================

CREATE TABLE IF NOT EXISTS raw_data.transactions (
    "TransactionID"   BIGINT PRIMARY KEY,
    "isFraud"         SMALLINT,
    "TransactionDT"   INTEGER,
    "TransactionAmt"  NUMERIC(12, 2),
    "ProductCD"       VARCHAR(10),
    "card1"           INTEGER,
    "card2"           NUMERIC(6, 1),
    "card3"           NUMERIC(6, 1),
    "card4"           VARCHAR(20),
    "card5"           NUMERIC(6, 1),
    "card6"           VARCHAR(20),
    "addr1"           NUMERIC(6, 1),
    "addr2"           NUMERIC(6, 1),
    "dist1"           NUMERIC(10, 1),
    "dist2"           NUMERIC(10, 1),
    "P_emaildomain"   VARCHAR(50),
    "R_emaildomain"   VARCHAR(50)
    -- V1-V339 and M1-M9 columns added during COPY
);

CREATE TABLE IF NOT EXISTS raw_data.identity (
    "TransactionID"   BIGINT REFERENCES raw_data.transactions("TransactionID"),
    "DeviceType"      VARCHAR(20),
    "DeviceInfo"      VARCHAR(100)
    -- id_01 to id_38 columns added during COPY
);

-- ============================================================
-- STAGING LAYER
-- ============================================================

CREATE TABLE IF NOT EXISTS staging.clean_transactions AS
SELECT
    t."TransactionID"                                   AS "TransactionID",
    t."isFraud"                                         AS is_fraud,
    t."TransactionDT"                                   AS transaction_dt,
    t."TransactionAmt"                                  AS amount,
    LN(1 + t."TransactionAmt")                         AS amount_log,
    t."ProductCD"                                       AS product_cd,
    (t."TransactionDT" / 3600) % 24                    AS hour_of_day,
    (t."TransactionDT" / 86400) % 7                    AS day_of_week,
    t."card1"                                           AS card1,
    t."card2"                                           AS card2,
    t."card3"                                           AS card3,
    t."card4"                                           AS card_type,
    t."card5"                                           AS card5,
    t."card6"                                           AS card_category,
    t."addr1"                                           AS addr1,
    t."addr2"                                           AS addr2,
    CASE WHEN i."TransactionID" IS NOT NULL THEN 1 ELSE 0 END AS has_identity
FROM raw_data.transactions t
LEFT JOIN raw_data.identity i ON t."TransactionID" = i."TransactionID";

-- ============================================================
-- MODELS LAYER
-- ============================================================

CREATE TABLE IF NOT EXISTS models.predictions (
    transactionid    BIGINT,
    predicted_prob   NUMERIC(6, 4),
    predicted_class  VARCHAR(3),
    threshold_used   NUMERIC(4, 2),
    model_name       VARCHAR(50),
    created_at       TIMESTAMP
);

CREATE TABLE IF NOT EXISTS models.model_performance (
    run_id           SERIAL PRIMARY KEY,
    model_name       VARCHAR(50),
    threshold        NUMERIC(4, 2),
    pr_auc           NUMERIC(6, 4),
    roc_auc          NUMERIC(6, 4),
    precision        NUMERIC(6, 4),
    recall           NUMERIC(6, 4),
    f1               NUMERIC(6, 4),
    f2               NUMERIC(6, 4),
    train_rows       INTEGER,
    test_rows        INTEGER,
    sample_pct       NUMERIC(4, 2),
    created_at       TIMESTAMP DEFAULT NOW()
);

-- Insert final results
INSERT INTO models.model_performance
    (model_name, threshold, pr_auc, roc_auc, precision, recall, f1, f2,
     train_rows, test_rows, sample_pct)
VALUES
    ('random_forest',       0.25, 0.679, 0.927, 0.583, 0.663, 0.621, 0.647, 118108, 29527, 0.25),
    ('xgboost',             0.50, 0.544, 0.906, 0.784, 0.364, 0.497, NULL,   118108, 29527, 0.25),
    ('logistic_regression', 0.50, 0.197, 0.817, 0.204, 0.383, 0.266, NULL,   118108, 29527, 0.25);
