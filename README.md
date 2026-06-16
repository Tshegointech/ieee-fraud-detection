# IEEE-CIS Fraud Detection Pipeline

An end-to-end fraud detection pipeline built on the [IEEE-CIS Fraud Detection dataset](https://www.kaggle.com/c/ieee-fraud-detection), developed entirely on a **Ryzen 5 laptop with 16 GB RAM** using open-source tools.

**Author:** Tshegofatso Skhumbuzo Shabangu | [github.com/Tshegointech](https://github.com/Tshegointech)  
**Student No.:** 202436819 | Sol Plaatje University

---

## Results at a Glance

| Model | PR-AUC | ROC-AUC | Precision | Recall | F1 |
|---|---|---|---|---|---|
| **Random Forest** | **0.679** | **0.927** | 0.583* | 0.663* | 0.621* |
| XGBoost | 0.544 | 0.906 | 0.784 | 0.364 | 0.497 |
| Logistic Regression | 0.197 | 0.817 | 0.204 | 0.383 | 0.266 |

*At optimal threshold τ = 0.25 (F2-tuned). Default threshold metrics: Precision 0.867, Recall 0.479.

---

## Project Structure

```
ieee-fraud-detection/
├── R/
│   └── 01_pipeline.R        # Full tidymodels pipeline (load → model → evaluate → save)
├── sql/
│   └── setup.sql            # PostgreSQL schema creation and results logging
├── dashboard/
│   └── app.R                # Shiny dashboard (4 tabs, reads live from PostgreSQL)
└── report/
    ├── fraud_detection_report.pdf   # Full technical report (18 pages)
    ├── fraud_detection_report.tex   # LaTeX source
    └── images/                      # Screenshots embedded in the report
```

---

## Stack

- **Database:** PostgreSQL 16 — four-schema architecture (`raw_data` → `staging` → `analytics` → `models`)
- **Language:** R 4.6 with `tidymodels`, `ranger`, `xgboost`, `themis`, `vip`
- **Dashboard:** Shiny (`shinydashboard` + `DT`), reads live from PostgreSQL
- **OS:** Ubuntu 24.04
- **Hardware:** Ryzen 5, 16 GB RAM

---

## Quickstart

### 1. Database setup

```bash
psql -U postgres -c "CREATE DATABASE ieee_fraud;"
psql -U postgres -d ieee_fraud -f sql/setup.sql
```

Load the Kaggle CSVs into `raw_data.transactions` and `raw_data.identity` via `\copy`.

### 2. Set your database password

```bash
export DB_PASSWORD=yourpassword
```

### 3. Run the pipeline

```r
source("R/01_pipeline.R")
```

### 4. Launch the dashboard

```r
shiny::runApp("dashboard/app.R")
```

---

## Pipeline Overview

```
Raw CSV files
    ↓
raw_data schema (PostgreSQL)
    ↓
staging.clean_transactions
  - Left join transactions + identity
  - Feature engineering: amount_log, hour_of_day, day_of_week, has_identity
    ↓
tidymodels recipe
  - Drop >50% missing columns
  - Median/mode imputation
  - One-hot encoding
  - Normalisation
  - SMOTE oversampling (over_ratio = 0.3)
    ↓
Model training (25% sample — RAM constraint)
  - Logistic Regression (glmnet, LASSO)
  - Random Forest (ranger, 200 trees)
  - XGBoost (300 rounds, depth 5)
    ↓
Threshold tuning via F2 score → τ* = 0.25
    ↓
models.predictions (PostgreSQL)
    ↓
Shiny Dashboard
```

---

## Key Design Decisions

**Why 25% sample?** The full post-SMOTE training set (~683,800 rows × 135 features) caused an out-of-memory crash on 16 GB RAM. A stratified 25% sample was used to keep the fraud prevalence intact while fitting within memory.

**Why F2 for threshold tuning?** In fraud detection, a missed fraud case (false negative) costs more than a false alarm (false positive). F2 weights recall twice as heavily as precision, making τ = 0.25 the operationally correct choice over the default 0.50.

**Why PR-AUC as the primary metric?** With a 27.6:1 class imbalance, ROC-AUC is overly optimistic. PR-AUC focuses specifically on model performance over the minority positive class.

---

## Limitations

- Models trained on 25% of data due to RAM constraints — full dataset training on cloud hardware would improve PR-AUC
- No cross-validated hyperparameter tuning (conservative values used throughout)
- Top features (`c14`, `c13`) are anonymised Vesta proprietary features with no public definitions, limiting explainability
- Static threshold requires periodic recalibration as fraud patterns shift (concept drift)

---

## Dataset

[IEEE-CIS Fraud Detection](https://www.kaggle.com/c/ieee-fraud-detection) — Vesta Corporation via Kaggle, 2019.
590,540 transactions | 3.5% fraud rate | 100 engineered features after staging.

The raw dataset is not included in this repository. Download it from Kaggle and load it following the instructions in `sql/setup.sql`.
