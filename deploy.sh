#!/bin/bash

#-----------------------------------------------------------------------------
# 배포 전제 조건:
# 1. AWS CLI가 설치되어 있고, AWS 자격 증명(credentials)이 구성되어 있어야 함.
# 2. 'npm install --production'을 실행하여 의존성을 설치해야 함.
#-----------------------------------------------------------------------------

# 에러 발생 시 스크립트 즉시 종료
set +x

# .env 파일이 존재하는지 확인하고, 주석과 빈 줄을 건너뛰고 환경 변수를 로드합니다.
if [ -f .env ]; then
    # grep -v '^#'로 주석(#)으로 시작하는 줄을 제외하고, grep -v '^\s*$'로 공백만 있는 줄을 제외합니다.
    export $(grep -v '^#' .env | grep -v '^\s*$' | xargs)
    echo ".env 파일에서 환경 변수를 로드했습니다."
else
    echo "오류: .env 파일을 찾을 수 없습니다."
    exit 1
fi

# 필수 환경 변수 확인
if [ -z "$AWS_ACCOUNT_ID" ] || [ -z "$AWS_REGION" ] || [ -z "$PUSHOVER_USER_KEY" ] || [ -z "$PUSHOVER_API_TOKEN" ] || [ -z "$ALLOWED_ORIGINS" ]; then
    echo "오류: .env 파일에 필수 환경 변수(AWS_ACCOUNT_ID, AWS_REGION, PUSHOVER_USER_KEY, PUSHOVER_API_TOKEN, ALLOWED_ORIGINS)가 누락되었습니다."
    exit 1
fi

# 람다 함수명과 IAM 역할 이름 설정
LAMBDA_FUNCTION_NAME="contact-api-lambda"
IAM_ROLE_NAME="lambda-contact-api-role"

#-----------------------------------------------------------------------------
# 1단계: 코드 패키징
#-----------------------------------------------------------------------------
echo "1. 배포 패키지 압축..."
# 필요한 파일만 포함하도록 압축 대상을 명시합니다.
zip -r contact-api-lambda.zip \
  lambda.js \
  package.json \
  package-lock.json \
  node_modules/ \
  -x "*.git*" "*.env" "deploy.sh"

#-----------------------------------------------------------------------------
# 2단계: AWS Lambda IAM 역할 생성 또는 업데이트
#-----------------------------------------------------------------------------
echo "2. IAM 역할 생성 또는 확인 중..."
ROLE_ARN=$(aws iam get-role --role-name $IAM_ROLE_NAME --query 'Role.Arn' --output text 2>/dev/null)

if [ -z "$ROLE_ARN" ]; then
    echo "  IAM 역할 '$IAM_ROLE_NAME'이 존재하지 않습니다. 새로 생성합니다."
    aws iam create-role \
        --role-name $IAM_ROLE_NAME \
        --assume-role-policy-document '{"Version": "2012-10-17","Statement": [{"Effect": "Allow","Principal": {"Service": "lambda.amazonaws.com"},"Action": "sts:AssumeRole"}]}' > /dev/null
    
    aws iam attach-role-policy \
        --role-name $IAM_ROLE_NAME \
        --policy-arn arn:aws:iam::aws:policy/AWSLambdaBasicExecutionRole
    
    # 역할이 생성되는 데 시간이 필요할 수 있으므로 5초 대기
    sleep 5
    ROLE_ARN=$(aws iam get-role --role-name $IAM_ROLE_NAME --query 'Role.Arn' --output text)
    echo "  IAM 역할 생성 완료. ARN: $ROLE_ARN"
else
    echo "  IAM 역할 '$IAM_ROLE_NAME'이 이미 존재합니다. ARN: $ROLE_ARN"
fi

#-----------------------------------------------------------------------------
# 3단계: AWS Lambda 함수 생성 또는 업데이트
#-----------------------------------------------------------------------------
echo "3. Lambda 함수 '$LAMBDA_FUNCTION_NAME' 배포 중..."

FUNCTION_ARN=$(aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME --query 'Configuration.FunctionArn' --output text 2>/dev/null)

if [ -z "$FUNCTION_ARN" ]; then
    echo "  함수가 존재하지 않습니다. 새로 생성합니다."
    aws lambda create-function \
        --function-name $LAMBDA_FUNCTION_NAME \
        --runtime nodejs20.x \
        --role "$ROLE_ARN" \
        --handler lambda.handler \
        --zip-file fileb://contact-api-lambda.zip \
        --timeout 30 \
        --environment '{"Variables":{"PUSHOVER_USER_KEY":"'"$PUSHOVER_USER_KEY"'","PUSHOVER_API_TOKEN":"'"$PUSHOVER_API_TOKEN"'","ALLOWED_ORIGINS":"'"$ALLOWED_ORIGINS"'"}}' > /dev/null
    echo "  Lambda 함수 생성 완료."
else
    echo "  함수가 이미 존재합니다. 코드와 환경 변수를 업데이트합니다."
    aws lambda update-function-code \
        --function-name $LAMBDA_FUNCTION_NAME \
        --zip-file fileb://contact-api-lambda.zip > /dev/null
    
    # 람다 함수 업데이트가 완료될 때까지 대기
    echo "  코드 업데이트 완료. 환경 변수 업데이트를 위해 대기 중..."
    aws lambda wait function-updated --function-name $LAMBDA_FUNCTION_NAME
    
    # 혼합 따옴표를 사용하여 AWS CLI에 환경 변수를 JSON 형식으로 전달합니다.
    aws lambda update-function-configuration \
        --function-name $LAMBDA_FUNCTION_NAME \
        --environment '{"Variables":{"PUSHOVER_USER_KEY":"'"$PUSHOVER_USER_KEY"'","PUSHOVER_API_TOKEN":"'"$PUSHOVER_API_TOKEN"'","ALLOWED_ORIGINS":"'"$ALLOWED_ORIGINS"'"}}' > /dev/null
    
    echo "  Lambda 함수 업데이트 완료."
fi

#-----------------------------------------------------------------------------
# 4단계: AWS API Gateway 생성 및 Lambda 연결 (수정된 부분)
#-----------------------------------------------------------------------------
echo "4. API Gateway 설정 중..."

API_ID=$(aws apigateway get-rest-apis --query "items[?name=='Contact API'].id" --output text 2>/dev/null)
if [ -z "$API_ID" ]; then
    echo "  API Gateway가 존재하지 않습니다. 새로 생성합니다."
    API_ID=$(aws apigateway create-rest-api --name "Contact API" --query 'id' --output text)
    echo "  새로운 API ID: $API_ID"
else
    echo "  API Gateway가 이미 존재합니다. ID: $API_ID"
fi

# 루트 리소스 ID 가져오기
PARENT_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id $API_ID --query 'items[?path==`/`].id' --output text)

# 1. 루트 경로(/)에 ANY 메서드 추가
echo "  루트 경로에 ANY 메서드 설정 중..."
aws apigateway put-method \
    --rest-api-id $API_ID \
    --resource-id $PARENT_RESOURCE_ID \
    --http-method ANY \
    --authorization-type "NONE" 2>/dev/null || echo "  루트 ANY 메서드가 이미 존재합니다."

# 루트 경로에 Lambda 통합 설정
aws apigateway put-integration \
    --rest-api-id $API_ID \
    --resource-id $PARENT_RESOURCE_ID \
    --http-method ANY \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:$LAMBDA_FUNCTION_NAME/invocations" 2>/dev/null || echo "  루트 Lambda 통합이 이미 존재합니다."

# 2. {proxy+} 리소스 생성 또는 확인
PROXY_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id $API_ID --query 'items[?path==`/{proxy+}`].id' --output text 2>/dev/null)
if [ -z "$PROXY_RESOURCE_ID" ]; then
    echo "  {proxy+} 리소스 생성 중..."
    PROXY_RESOURCE_ID=$(aws apigateway create-resource \
        --rest-api-id $API_ID \
        --parent-id $PARENT_RESOURCE_ID \
        --path-part "{proxy+}" \
        --query 'id' --output text)
else
    echo "  {proxy+} 리소스가 이미 존재합니다."
fi

# {proxy+}에 ANY 메서드 추가
echo "  {proxy+}에 ANY 메서드 설정 중..."
aws apigateway put-method \
    --rest-api-id $API_ID \
    --resource-id $PROXY_RESOURCE_ID \
    --http-method ANY \
    --authorization-type "NONE" 2>/dev/null || echo "  {proxy+} ANY 메서드가 이미 존재합니다."

# {proxy+}에 Lambda 통합 설정
aws apigateway put-integration \
    --rest-api-id $API_ID \
    --resource-id $PROXY_RESOURCE_ID \
    --http-method ANY \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "arn:aws:apigateway:$AWS_REGION:lambda:path/2015-03-31/functions/arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:$LAMBDA_FUNCTION_NAME/invocations" 2>/dev/null || echo "  {proxy+} Lambda 통합이 이미 존재합니다."

# 3. CORS 설정 (OPTIONS 메서드)
echo "  CORS 설정 중..."
aws apigateway put-method \
    --rest-api-id $API_ID \
    --resource-id $PARENT_RESOURCE_ID \
    --http-method OPTIONS \
    --authorization-type "NONE" 2>/dev/null || echo "  루트 OPTIONS 메서드가 이미 존재합니다."

aws apigateway put-method \
    --rest-api-id $API_ID \
    --resource-id $PROXY_RESOURCE_ID \
    --http-method OPTIONS \
    --authorization-type "NONE" 2>/dev/null || echo "  {proxy+} OPTIONS 메서드가 이미 존재합니다."

# OPTIONS 메서드에 대한 Mock 통합 설정 (루트)
aws apigateway put-integration \
    --rest-api-id $API_ID \
    --resource-id $PARENT_RESOURCE_ID \
    --http-method OPTIONS \
    --type MOCK \
    --request-templates '{"application/json":"{\"statusCode\": 200}"}' 2>/dev/null || true

# OPTIONS 메서드에 대한 Mock 통합 설정 ({proxy+})
aws apigateway put-integration \
    --rest-api-id $API_ID \
    --resource-id $PROXY_RESOURCE_ID \
    --http-method OPTIONS \
    --type MOCK \
    --request-templates '{"application/json":"{\"statusCode\": 200}"}' 2>/dev/null || true

# OPTIONS 응답 설정 (루트)
aws apigateway put-method-response \
    --rest-api-id $API_ID \
    --resource-id $PARENT_RESOURCE_ID \
    --http-method OPTIONS \
    --status-code 200 \
    --response-parameters '{"method.response.header.Access-Control-Allow-Headers": false, "method.response.header.Access-Control-Allow-Methods": false, "method.response.header.Access-Control-Allow-Origin": false}' 2>/dev/null || true

# OPTIONS 응답 설정 ({proxy+})
aws apigateway put-method-response \
    --rest-api-id $API_ID \
    --resource-id $PROXY_RESOURCE_ID \
    --http-method OPTIONS \
    --status-code 200 \
    --response-parameters '{"method.response.header.Access-Control-Allow-Headers": false, "method.response.header.Access-Control-Allow-Methods": false, "method.response.header.Access-Control-Allow-Origin": false}' 2>/dev/null || true

# OPTIONS 통합 응답 설정 (루트)
aws apigateway put-integration-response \
    --rest-api-id $API_ID \
    --resource-id $PARENT_RESOURCE_ID \
    --http-method OPTIONS \
    --status-code 200 \
    --response-parameters '{"method.response.header.Access-Control-Allow-Headers": "'"'"'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"'"'", "method.response.header.Access-Control-Allow-Methods": "'"'"'DELETE,GET,HEAD,OPTIONS,PATCH,POST,PUT'"'"'", "method.response.header.Access-Control-Allow-Origin": "'"'"'*'"'"'"}' \
    --response-templates '{"application/json":""}' 2>/dev/null || true

# OPTIONS 통합 응답 설정 ({proxy+})
aws apigateway put-integration-response \
    --rest-api-id $API_ID \
    --resource-id $PROXY_RESOURCE_ID \
    --http-method OPTIONS \
    --status-code 200 \
    --response-parameters '{"method.response.header.Access-Control-Allow-Headers": "'"'"'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"'"'", "method.response.header.Access-Control-Allow-Methods": "'"'"'DELETE,GET,HEAD,OPTIONS,PATCH,POST,PUT'"'"'", "method.response.header.Access-Control-Allow-Origin": "'"'"'*'"'"'"}' \
    --response-templates '{"application/json":""}' 2>/dev/null || true

# API Gateway가 Lambda를 호출할 권한 추가
echo "  Lambda 호출 권한 설정 중..."
aws lambda add-permission \
    --function-name $LAMBDA_FUNCTION_NAME \
    --statement-id "AllowAPIGatewayInvokeRoot" \
    --action "lambda:InvokeFunction" \
    --principal "apigateway.amazonaws.com" \
    --source-arn "arn:aws:execute-api:$AWS_REGION:$AWS_ACCOUNT_ID:$API_ID/*/*" 2>/dev/null || echo "  루트 권한이 이미 존재합니다."

aws lambda add-permission \
    --function-name $LAMBDA_FUNCTION_NAME \
    --statement-id "AllowAPIGatewayInvokeProxy" \
    --action "lambda:InvokeFunction" \
    --principal "apigateway.amazonaws.com" \
    --source-arn "arn:aws:execute-api:$AWS_REGION:$AWS_ACCOUNT_ID:$API_ID/*/*/{proxy+}" 2>/dev/null || echo "  Proxy 권한이 이미 존재합니다."

echo "  설정 완료. 배포를 위해 잠시 대기 중..."
sleep 5

#-----------------------------------------------------------------------------
# 5단계: 배포
#-----------------------------------------------------------------------------
echo "5. 배포 중..."

# 기존 배포 삭제 (있다면)
aws apigateway delete-deployment --rest-api-id $API_ID --deployment-id $(aws apigateway get-deployments --rest-api-id $API_ID --query 'items[?stageName==`prod`].id' --output text 2>/dev/null) 2>/dev/null || true

# 새 배포 생성
echo "  API를 'prod' 스테이지로 배포합니다."
DEPLOYMENT_ID=$(aws apigateway create-deployment \
    --rest-api-id $API_ID \
    --stage-name prod \
    --description "Automated deployment $(date)" \
    --query 'id' --output text 2>/dev/null)

if [ -z "$DEPLOYMENT_ID" ]; then
    echo "오류: 배포에 실패했습니다. AWS 콘솔에서 수동으로 확인해 주세요."
    exit 1
fi

echo "  배포 ID: $DEPLOYMENT_ID"

# 배포된 URL 출력
API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/prod"
echo "6. 배포 완료! API 엔드포인트: $API_URL"
echo "   테스트 URL: $API_URL/api/contact"


curl -X POST https://0mri4b4l4g.execute-api.ap-south-1.amazonaws.com/prod/api/contact \
  -H "Content-Type: application/json" \
  -d '{"name":"테스트","message":"테스트 메시지 10글자 이상","phone":"010-1234-5678"}'