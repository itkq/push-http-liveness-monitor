# Push HTTP Liveness Monitor

Push-style heartbeat endpoints backed by API Gateway, SQS, and CloudWatch. Clients POST to a target-specific URL; each request is sent to an SQS queue, and a CloudWatch alarm fires if messages stop arriving.

## How it works

- Creates one SQS queue per target (`${name_prefix}-${target}-heartbeat`, retention 1 day).
- Creates an API Gateway REST API with a POST endpoint per `targets`; requests require an API key.
- API Gateway forwards the raw request body to the corresponding SQS queue.
- CloudWatch alarm per queue (`LessThanThreshold` on `NumberOfMessagesSent`, 5 min period, 2 evaluations, `treat_missing_data=breaching`). Optionally notifies an SNS topic.

## Deploy

Example:

```hcl
resource "aws_sns_topic" "push_http_liveness_monitor_topic" {
  name = "push-http-liveness-monitor"
}
module "push_http_liveness_monitor" {
  source = "github.com/itkq/push-http-liveness-monitor?ref=v0.1.0"
  targets = [
    "device-1",
  ]
  alarm_sns_topic_arn = aws_sns_topic.push_http_liveness_monitor_topic.arn
  tags = {
    Project = "push-http-liveness-monitor"
  }
}
output "push_http_liveness_endpoints" {
  value = module.push_http_liveness_monitor.endpoints
}
```

Send a heartbeat:

```
curl -X POST \
  -H "content-type: application/json" \
  -H "x-api-key: <api-key>" \
  -d '{}' \
  $endpoint
```

Any body is accepted; it is forwarded to the target's SQS queue.

## Notes

- Alarms trigger after ~10 minutes of missing heartbeats (2x 5-minute periods).
- Requests without `x-api-key` are rejected by API Gateway.
- The auto-generated API key value is stored in Terraform state; handle state securely.
