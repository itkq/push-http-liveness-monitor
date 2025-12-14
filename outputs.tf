output "endpoints" {
  description = "Heartbeat endpoints per target (map: key -> URL)"
  value = {
    for t in var.targets :
    t => "https://${aws_api_gateway_rest_api.this.id}.execute-api.${data.aws_region.current.region}.amazonaws.com/${aws_api_gateway_stage.this.stage_name}/${t}"
  }
}
