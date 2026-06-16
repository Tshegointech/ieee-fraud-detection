# ============================================================
# IEEE-CIS Fraud Detection Pipeline
# Author: Tshegofatso Skhumbuzo Shabangu (202436819)
# GitHub: github.com/Tshegointech
# ============================================================

# --- 1. Libraries ---
library(DBI)
library(RPostgres)
library(tidyverse)
library(tidymodels)
library(themis)
library(ranger)
library(xgboost)
library(vip)

# --- 2. Database Connection ---
con <- dbConnect(
  Postgres(),
  dbname   = "ieee_fraud",
  host     = "localhost",
  port     = 5432,
  user     = Sys.getenv("DB_USER"),
  password = Sys.getenv("DB_PASSWORD")   # set env var: export DB_PASSWORD=yourpassword
)

df <- dbGetQuery(con, "SELECT * FROM staging.clean_transactions")
df$is_fraud <- factor(df$is_fraud, levels = c(0, 1), labels = c("no", "yes"))
cat("Loaded:", nrow(df), "rows |", ncol(df), "cols\n")
cat("Fraud rate:", round(mean(df$is_fraud == "yes") * 100, 2), "%\n")

# --- 3. Missing Value Analysis ---
missing_summary <- df |>
  summarise(across(everything(), ~mean(is.na(.)))) |>
  pivot_longer(everything(), names_to = "column", values_to = "pct_missing") |>
  filter(pct_missing > 0) |>
  arrange(desc(pct_missing))

drop_cols   <- missing_summary |> filter(pct_missing > 0.50) |> pull(column)
impute_cols <- missing_summary |> filter(pct_missing <= 0.50) |> pull(column)

cat("Columns to drop (>50% missing):", length(drop_cols), "\n")
cat("Columns to impute:", length(impute_cols), "\n")

# --- 4. Train-Test Split (25% sample due to RAM constraints) ---
set.seed(42)

df_sample <- df |>
  group_by(is_fraud) |>
  slice_sample(prop = 0.25) |>
  ungroup()

split <- initial_split(df_sample, prop = 0.80, strata = is_fraud)
train <- training(split)
test  <- testing(split)

cat("Train:", nrow(train), "| Test:", nrow(test), "\n")

# --- 5. Preprocessing Recipe ---
num_cols <- train |> select(all_of(impute_cols)) |> select(where(is.numeric))  |> names()
nom_cols <- train |> select(all_of(impute_cols)) |> select(where(is.character)) |> names()

fraud_recipe <- recipe(is_fraud ~ ., data = train) |>
  step_rm(all_of(drop_cols)) |>
  step_impute_median(all_of(num_cols)) |>
  step_impute_mode(all_of(nom_cols)) |>
  step_string2factor(all_of(nom_cols)) |>
  step_dummy(all_nominal_predictors(), one_hot = TRUE) |>
  step_mutate(across(where(is.logical), as.integer)) |>
  step_normalize(all_numeric_predictors()) |>
  step_zv(all_predictors()) |>
  step_smote(is_fraud, over_ratio = 0.3)

cat("Recipe baked dimensions:",
    fraud_recipe |> prep() |> bake(new_data = NULL) |> dim(), "\n")

# --- 6. Model Specifications ---
lr_spec <- logistic_reg(penalty = 0.001, mixture = 1) |>
  set_engine("glmnet") |>
  set_mode("classification")

rf_spec <- rand_forest(trees = 200, mtry = 15, min_n = 10) |>
  set_engine("ranger", importance = "impurity", num.threads = 4) |>
  set_mode("classification")

xgb_spec <- boost_tree(
  trees = 300, tree_depth = 5, learn_rate = 0.05,
  min_n = 10, sample_size = 0.8
) |>
  set_engine("xgboost", nthread = 4) |>
  set_mode("classification")

# --- 7. Workflows ---
lr_wf  <- workflow() |> add_recipe(fraud_recipe) |> add_model(lr_spec)
rf_wf  <- workflow() |> add_recipe(fraud_recipe) |> add_model(rf_spec)
xgb_wf <- workflow() |> add_recipe(fraud_recipe) |> add_model(xgb_spec)

# --- 8. Fit Models ---
cat("Fitting LR...\n");  lr_fit  <- fit(lr_wf,  data = train); cat("LR done\n")
cat("Fitting RF...\n");  rf_fit  <- fit(rf_wf,  data = train); cat("RF done\n")
cat("Fitting XGB...\n"); xgb_fit <- fit(xgb_wf, data = train); cat("XGB done\n")

# --- 9. Evaluate ---
lr_preds <- predict(lr_fit, test, type = "prob") |>
  bind_cols(predict(lr_fit, test)) |>
  bind_cols(test |> select(is_fraud)) |>
  mutate(model = "Logistic Regression")

rf_preds <- predict(rf_fit, test, type = "prob") |>
  bind_cols(predict(rf_fit, test)) |>
  bind_cols(test |> select(is_fraud)) |>
  mutate(model = "Random Forest")

xgb_preds <- predict(xgb_fit, test, type = "prob") |>
  bind_cols(predict(xgb_fit, test)) |>
  bind_cols(test |> select(is_fraud)) |>
  mutate(model = "XGBoost")

all_preds <- bind_rows(lr_preds, rf_preds, xgb_preds)

metrics <- metric_set(roc_auc, pr_auc, precision, recall, f_meas)

results <- all_preds |>
  group_by(model) |>
  metrics(truth = is_fraud, estimate = .pred_class, .pred_yes,
          event_level = "second") |>
  pivot_wider(names_from = .metric, values_from = .estimate) |>
  arrange(desc(pr_auc))

print(results)

# --- 10. Threshold Tuning (Random Forest) ---
thresholds <- seq(0.10, 0.50, by = 0.025)

threshold_results <- map_dfr(thresholds, function(t) {
  rf_preds |>
    mutate(.pred_class_t = factor(
      ifelse(.pred_yes >= t, "yes", "no"), levels = c("no", "yes")
    )) |>
    summarise(
      threshold = t,
      precision = precision_vec(is_fraud, .pred_class_t, event_level = "second"),
      recall    = recall_vec(is_fraud,    .pred_class_t, event_level = "second"),
      f2        = (5 * precision_vec(is_fraud, .pred_class_t, event_level = "second") *
                      recall_vec(is_fraud,    .pred_class_t, event_level = "second")) /
                  (4 * precision_vec(is_fraud, .pred_class_t, event_level = "second") +
                       recall_vec(is_fraud,    .pred_class_t, event_level = "second"))
    )
})

best_t <- threshold_results |> slice_max(f2, n = 1)
cat("\nOptimal threshold:", best_t$threshold,
    "| Precision:", round(best_t$precision, 3),
    "| Recall:", round(best_t$recall, 3), "\n")

# --- 11. Final Predictions at Optimal Threshold ---
final_preds <- rf_preds |>
  mutate(.pred_final = factor(
    ifelse(.pred_yes >= best_t$threshold, "yes", "no"),
    levels = c("no", "yes")
  ))

conf_mat(final_preds, truth = is_fraud, estimate = .pred_final) |> print()

# --- 12. Variable Importance ---
rf_fit |>
  extract_fit_parsnip() |>
  vip(num_features = 20) +
  labs(title = "Top 20 Features - Random Forest") |>
  print()

# --- 13. Save Predictions to PostgreSQL ---
final_output <- test |>
  select(TransactionID) |>
  bind_cols(rf_preds |> select(.pred_yes)) |>
  mutate(
    predicted_prob  = round(.pred_yes, 4),
    predicted_class = factor(ifelse(.pred_yes >= best_t$threshold, "yes", "no"),
                             levels = c("no", "yes")),
    threshold_used  = best_t$threshold,
    model_name      = "random_forest",
    created_at      = Sys.time()
  ) |>
  select(-.pred_yes) |>
  rename(transactionid = TransactionID)

dbExecute(con, "DROP TABLE IF EXISTS models.predictions")
dbExecute(con, "
  CREATE TABLE models.predictions (
    transactionid    BIGINT,
    predicted_prob   NUMERIC(6,4),
    predicted_class  VARCHAR(3),
    threshold_used   NUMERIC(4,2),
    model_name       VARCHAR(50),
    created_at       TIMESTAMP
  )
")
dbWriteTable(con, Id(schema = "models", table = "predictions"),
             final_output, append = TRUE, row.names = FALSE)

cat("Predictions written:", dbGetQuery(con, "SELECT COUNT(*) FROM models.predictions")[[1]], "\n")
dbDisconnect(con)
