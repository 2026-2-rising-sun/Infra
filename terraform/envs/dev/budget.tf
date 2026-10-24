# 예산 알림. 월 상한 30만원(≈ $200) 기준으로 $50 / $100 / $200 에서 메일을 보낸다.
# Budgets 는 하루 몇 번만 집계하므로 "켜 두고 잊은" 상황을 하루 안에 알려 주는 안전망이지 실시간 차단은 아니다.
# 알림을 받으면 `make aws-down` 으로 지운다.

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = "200"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [25, 50, 100] # $50, $100, $200

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }
}
