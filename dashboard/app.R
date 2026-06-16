# ============================================================
# Fraud Detection Shiny Dashboard
# Author: Tshegofatso Skhumbuzo Shabangu (202436819)
# Reads live from models.predictions in PostgreSQL
# Run: shiny::runApp("dashboard/app.R")
# ============================================================

library(shiny)
library(shinydashboard)
library(ggplot2)
library(dplyr)
library(DBI)
library(RPostgres)
library(DT)

# --- Load data from PostgreSQL ---
con <- dbConnect(
  Postgres(),
  dbname   = "ieee_fraud",
  host     = "localhost",
  port     = 5432,
  user     = Sys.getenv("DB_USER"),
  password = Sys.getenv("DB_PASSWORD")
)

preds <- dbGetQuery(con, "SELECT * FROM models.predictions")
preds$predicted_class <- factor(preds$predicted_class, levels = c("no", "yes"))

transactions <- dbGetQuery(con, '
  SELECT "TransactionID" AS transactionid,
         amount, product_cd, card1, card2
  FROM staging.clean_transactions
')

dbDisconnect(con)

dashboard_data <- preds |>
  left_join(transactions, by = "transactionid")

# --- UI ---
ui <- dashboardPage(
  dashboardHeader(title = "Fraud Detection"),
  dashboardSidebar(
    sidebarMenu(
      menuItem("Overview",          tabName = "overview", icon = icon("chart-bar")),
      menuItem("Score Distribution",tabName = "scores",   icon = icon("chart-area")),
      menuItem("Threshold Tuning",  tabName = "thresh",   icon = icon("sliders-h")),
      menuItem("Flagged Transactions", tabName = "table", icon = icon("table"))
    )
  ),
  dashboardBody(
    tabItems(

      tabItem(tabName = "overview",
        fluidRow(
          valueBoxOutput("total_box"),
          valueBoxOutput("fraud_box"),
          valueBoxOutput("precision_box")
        ),
        fluidRow(
          box(plotOutput("class_bar"), title = "Prediction Breakdown", width = 6),
          box(plotOutput("prob_hist"), title = "Fraud Probability Distribution", width = 6)
        )
      ),

      tabItem(tabName = "scores",
        fluidRow(
          box(plotOutput("score_density"), title = "Probability by Predicted Class", width = 12)
        )
      ),

      tabItem(tabName = "thresh",
        fluidRow(
          box(
            sliderInput("threshold", "Decision Threshold",
                        min = 0.05, max = 0.95, value = 0.25, step = 0.025),
            width = 4
          ),
          valueBoxOutput("t_precision"),
          valueBoxOutput("t_recall")
        ),
        fluidRow(
          box(plotOutput("thresh_cm"), title = "Confusion Matrix at Selected Threshold", width = 12)
        )
      ),

      tabItem(tabName = "table",
        fluidRow(
          box(
            sliderInput("min_prob", "Minimum Fraud Probability",
                        min = 0.25, max = 0.99, value = 0.50, step = 0.05),
            width = 4
          )
        ),
        fluidRow(
          box(DT::dataTableOutput("flagged_table"), width = 12)
        )
      )
    )
  )
)

# --- Server ---
server <- function(input, output) {

  output$total_box <- renderValueBox({
    valueBox(nrow(preds), "Total Transactions", icon = icon("credit-card"), color = "blue")
  })

  output$fraud_box <- renderValueBox({
    n <- sum(preds$predicted_class == "yes")
    valueBox(n, "Flagged as Fraud", icon = icon("exclamation-triangle"), color = "red")
  })

  output$precision_box <- renderValueBox({
    valueBox("0.583", "Model Precision", icon = icon("bullseye"), color = "yellow")
  })

  output$class_bar <- renderPlot({
    preds |>
      count(predicted_class) |>
      ggplot(aes(predicted_class, n, fill = predicted_class)) +
      geom_col(show.legend = FALSE) +
      scale_fill_manual(values = c("no" = "#2196F3", "yes" = "#F44336")) +
      labs(x = "Predicted Class", y = "Count") +
      theme_minimal()
  })

  output$prob_hist <- renderPlot({
    ggplot(preds, aes(predicted_prob, fill = predicted_class)) +
      geom_histogram(bins = 50, alpha = 0.7, position = "identity") +
      scale_fill_manual(values = c("no" = "#2196F3", "yes" = "#F44336")) +
      labs(x = "Fraud Probability", y = "Count", fill = "Class") +
      theme_minimal()
  })

  output$score_density <- renderPlot({
    ggplot(preds, aes(predicted_prob, fill = predicted_class)) +
      geom_density(alpha = 0.5) +
      scale_fill_manual(values = c("no" = "#2196F3", "yes" = "#F44336")) +
      labs(x = "Predicted Fraud Probability", y = "Density", fill = "Predicted Class") +
      theme_minimal()
  })

  thresh_preds <- reactive({
    preds |>
      mutate(pred_t = factor(
        ifelse(predicted_prob >= input$threshold, "yes", "no"),
        levels = c("no", "yes")
      ))
  })

  output$t_precision <- renderValueBox({
    tp <- sum(thresh_preds()$pred_t == "yes" & thresh_preds()$predicted_class == "yes")
    fp <- sum(thresh_preds()$pred_t == "yes" & thresh_preds()$predicted_class == "no")
    p  <- ifelse((tp + fp) == 0, 0, round(tp / (tp + fp), 3))
    valueBox(p, "Precision", icon = icon("check"), color = "green")
  })

  output$t_recall <- renderValueBox({
    tp <- sum(thresh_preds()$pred_t == "yes" & thresh_preds()$predicted_class == "yes")
    fn <- sum(thresh_preds()$pred_t == "no"  & thresh_preds()$predicted_class == "yes")
    r  <- ifelse((tp + fn) == 0, 0, round(tp / (tp + fn), 3))
    valueBox(r, "Recall", icon = icon("search"), color = "orange")
  })

  output$thresh_cm <- renderPlot({
    thresh_preds() |>
      count(predicted_class, pred_t) |>
      ggplot(aes(predicted_class, pred_t, fill = n)) +
      geom_tile() +
      geom_text(aes(label = n), size = 6, color = "white") +
      scale_fill_gradient(low = "#1565C0", high = "#B71C1C") +
      labs(x = "Original Prediction", y = "At New Threshold", fill = "Count") +
      theme_minimal()
  })

  output$flagged_table <- DT::renderDataTable({
    dashboard_data |>
      filter(predicted_prob >= input$min_prob) |>
      arrange(desc(predicted_prob)) |>
      select(transactionid, predicted_prob, amount, product_cd, card1, card2) |>
      DT::datatable(options = list(pageLength = 15))
  })
}

shinyApp(ui, server)
