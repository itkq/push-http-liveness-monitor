data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  redeploy_hash = sha1(jsonencode({
    resources              = { for k, r in aws_api_gateway_resource.heartbeat : k => r.id }
    methods                = { for k, m in aws_api_gateway_method.heartbeat_post : k => m.api_key_required }
    integrations_templates = { for k, i in aws_api_gateway_integration.heartbeat_post : k => i.request_templates }
    integrations_params    = { for k, i in aws_api_gateway_integration.heartbeat_post : k => i.request_parameters }
    method_responses       = { for k, r in aws_api_gateway_method_response.heartbeat_200 : k => r.status_code }
    integration_responses  = { for k, r in aws_api_gateway_integration_response.heartbeat_200 : k => r.status_code }
    integration_templates  = { for k, r in aws_api_gateway_integration_response.heartbeat_200 : k => r.response_templates }
  }))
}

resource "aws_sqs_queue" "heartbeat" {
  for_each = toset(var.targets)

  name                      = "${var.name_prefix}-${each.key}-heartbeat"
  message_retention_seconds = 86400 # 1 day enough
  tags                      = var.tags
}

resource "aws_api_gateway_rest_api" "this" {
  name        = "${var.name_prefix}-heartbeat-api"
  description = "HTTP heartbeat API (push style) that sends messages to SQS per target"
  tags        = var.tags
}

resource "aws_api_gateway_api_key" "this" {
  name    = "${var.name_prefix}-heartbeat"
  enabled = true
}

resource "aws_api_gateway_usage_plan" "this" {
  name = "${var.name_prefix}-heartbeat"
  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }
}

resource "aws_api_gateway_usage_plan_key" "this" {
  key_id        = aws_api_gateway_api_key.this.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.this.id
}

resource "aws_api_gateway_resource" "heartbeat" {
  for_each = toset(var.targets)

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = each.key
}

resource "aws_api_gateway_method" "heartbeat_post" {
  for_each = toset(var.targets)

  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.heartbeat[each.key].id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

data "aws_iam_policy_document" "apigw_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_sqs_role" {
  name               = "${var.name_prefix}-apigw-sqs-role"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "apigw_sqs" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
    ]
    resources = [
      for q in aws_sqs_queue.heartbeat : q.arn
    ]
  }
}

resource "aws_iam_role_policy" "apigw_sqs_policy" {
  name   = "${var.name_prefix}-apigw-sqs-policy"
  role   = aws_iam_role.apigw_sqs_role.id
  policy = data.aws_iam_policy_document.apigw_sqs.json
}

resource "aws_api_gateway_integration" "heartbeat_post" {
  for_each = toset(var.targets)

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.heartbeat[each.key].id
  http_method = aws_api_gateway_method.heartbeat_post[each.key].http_method

  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.region}:sqs:path/${data.aws_caller_identity.current.account_id}/${aws_sqs_queue.heartbeat[each.key].name}"
  credentials             = aws_iam_role.apigw_sqs_role.arn
  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }
  request_templates = {
    "application/json" = <<-EOT
        Action=SendMessage&QueueUrl=$util.urlEncode("${aws_sqs_queue.heartbeat[each.key].id}")&MessageBody=$util.urlEncode($input.body) 
    EOT
  }
  passthrough_behavior = "NEVER"
}

resource "aws_api_gateway_method_response" "heartbeat_200" {
  for_each = toset(var.targets)

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.heartbeat[each.key].id
  http_method = aws_api_gateway_method.heartbeat_post[each.key].http_method
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
    "application/xml"  = "Empty"
  }
  response_parameters = {
    "method.response.header.Content-Type" = true
  }
}

resource "aws_api_gateway_integration_response" "heartbeat_200" {
  for_each = toset(var.targets)

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.heartbeat[each.key].id
  http_method = aws_api_gateway_method.heartbeat_post[each.key].http_method
  status_code = aws_api_gateway_method_response.heartbeat_200[each.key].status_code
  response_templates = {
    "application/json" = <<-EOF
      {
        "status": "ok"
      }
    EOF
    "application/xml" = <<-EOF
      {
        "status": "ok"
      }
    EOF
  }
  response_parameters = {
    "method.response.header.Content-Type" = "'application/json'"
  }

  depends_on = [aws_api_gateway_integration.heartbeat_post]
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeploy = local.redeploy_hash
  }

  depends_on = [
    aws_api_gateway_integration.heartbeat_post,
    aws_api_gateway_method_response.heartbeat_200,
    aws_api_gateway_integration_response.heartbeat_200,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage_name
  tags          = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_metric_alarm" "heartbeat_missing" {
  for_each = toset(var.targets)

  alarm_name          = "${var.name_prefix}-${each.key}-heartbeat-missing"
  alarm_description   = "No heartbeat messages for target '${each.key}'"
  namespace           = "AWS/SQS"
  metric_name         = "NumberOfMessagesSent"
  statistic           = "Sum"
  period              = 300 # 5 min
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  dimensions = {
    QueueName = aws_sqs_queue.heartbeat[each.key].name
  }
  alarm_actions = var.alarm_sns_topic_arn == null ? [] : [var.alarm_sns_topic_arn]
  tags          = var.tags
}
