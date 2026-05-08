terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1" # Cambia a tu región preferida
}

# 1. Tabla de DynamoDB
resource "aws_dynamodb_table" "cerebro_table" {
  name         = "cerebro_secundario"
  billing_mode = "PAY_PER_REQUEST" # Solo pagas por lo que usas (Capa gratuita)
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# 2. Empaquetar la función Python en un ZIP
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../src/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

# 3. Rol IAM para Lambda
resource "aws_iam_role" "lambda_role" {
  name = "cerebro_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Permisos para escribir en DynamoDB y generar logs
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "dynamodb_policy" {
  name = "dynamodb_access"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "dynamodb:PutItem",
        "dynamodb:GetItem"
      ]
      Effect   = "Allow"
      Resource = aws_dynamodb_table.cerebro_table.arn
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_policy" {
  name = "bedrock_access"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "bedrock:InvokeModel"
      ]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

# 4. CloudWatch Log Group con retención
resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/CerebroAPI"
  retention_in_days = 14
}

# 5. Función Lambda
resource "aws_lambda_function" "api_lambda" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "CerebroAPI"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 15

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.cerebro_table.name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda_log_group
  ]
}

# 6. API Gateway (REST API)
resource "aws_api_gateway_rest_api" "rest_api" {
  name        = "cerebro-rest-api"
  description = "API REST para capturar ideas en Second Brain"
}

resource "aws_api_gateway_resource" "resource" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = "capturar"
}

resource "aws_api_gateway_method" "method" {
  rest_api_id      = aws_api_gateway_rest_api.rest_api.id
  resource_id      = aws_api_gateway_resource.resource.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "integration" {
  rest_api_id             = aws_api_gateway_rest_api.rest_api.id
  resource_id             = aws_api_gateway_resource.resource.id
  http_method             = aws_api_gateway_method.method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api_lambda.invoke_arn
}

# Permiso para API Gateway invocar a Lambda
resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.rest_api.execution_arn}/*/${aws_api_gateway_method.method.http_method}${aws_api_gateway_resource.resource.path}"
}

resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id

  depends_on = [
    aws_api_gateway_integration.integration
  ]
  
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod_stage" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  stage_name    = "prod"
}

# 7. API Key y Usage Plan
resource "aws_api_gateway_usage_plan" "usage_plan" {
  name        = "CerebroUsagePlan"
  description = "Plan de uso para Second Brain API"

  api_stages {
    api_id = aws_api_gateway_rest_api.rest_api.id
    stage  = aws_api_gateway_stage.prod_stage.stage_name
  }

  quota_settings {
    limit  = 1000
    offset = 0
    period = "MONTH"
  }

  throttle_settings {
    burst_limit = 10
    rate_limit  = 5
  }
}

resource "aws_api_gateway_api_key" "api_key" {
  name    = "CerebroAPIKey"
  enabled = true
}

resource "aws_api_gateway_usage_plan_key" "usage_plan_key" {
  key_id        = aws_api_gateway_api_key.api_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.usage_plan.id
}

# 8. Outputs
output "api_url" {
  value       = "${aws_api_gateway_stage.prod_stage.invoke_url}/capturar"
  description = "Pega esta URL en tu Atajo de iOS"
}

output "api_key" {
  value       = aws_api_gateway_api_key.api_key.value
  description = "Clave de la API (añadir como header x-api-key en el Atajo)"
  sensitive   = true
}
