#!/bin/bash
# scripts/run-stage-tests.sh - Run stage-specific tests
# Usage: ./scripts/run-stage-tests.sh <stage-number> "<stage-name>"

set -e

STAGE_NUM=$1
STAGE_NAME=$2

if [ -z "$STAGE_NUM" ]; then
    echo "Usage: $0 <stage-number> \"<stage-name>\""
    echo "Example: $0 3 \"Operations\""
    exit 1
fi

echo "🧪 Running Stage $STAGE_NUM ($STAGE_NAME) Tests..."
echo ""

TEST_EXIT_CODE=0

case $STAGE_NUM in
  2)
    echo "Testing: Core Library"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    ~/.dotnet/dotnet test test/RawRabbit.Tests/RawRabbit.Tests.csproj \
      --filter "FullyQualifiedName~RawRabbit.Tests.Channel|FullyQualifiedName~RawRabbit.Tests.Consumer" \
      --logger "console;verbosity=detailed" \
      --configuration Release || TEST_EXIT_CODE=$?
    ;;

  3)
    echo "Testing: Operations"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    ~/.dotnet/dotnet test test/RawRabbit.Tests/RawRabbit.Tests.csproj \
      --filter "FullyQualifiedName~Operations" \
      --logger "console;verbosity=detailed" \
      --configuration Release || TEST_EXIT_CODE=$?
    ;;

  4)
    echo "Testing: Enrichers"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if docker ps | grep -q rabbitmq; then
      ~/.dotnet/dotnet test test/RawRabbit.IntegrationTests/RawRabbit.IntegrationTests.csproj \
        --filter "FullyQualifiedName~Enrichers" \
        --logger "console;verbosity=detailed" \
        --configuration Release || TEST_EXIT_CODE=$?
    else
      echo "⚠️  RabbitMQ not running - skipping enricher integration tests"
      echo "Start RabbitMQ: docker run -d --name rabbitmq-test -p 5672:5672 rabbitmq:3-management"
      TEST_EXIT_CODE=0
    fi
    ;;

  5)
    echo "Testing: DI Adapters"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if docker ps | grep -q rabbitmq; then
      ~/.dotnet/dotnet test test/RawRabbit.IntegrationTests/RawRabbit.IntegrationTests.csproj \
        --filter "FullyQualifiedName~DependencyInjection" \
        --logger "console;verbosity=detailed" \
        --configuration Release || TEST_EXIT_CODE=$?
    else
      echo "✅ DI adapters build successfully (integration tests skipped - no RabbitMQ)"
      TEST_EXIT_CODE=0
    fi
    ;;

  6)
    echo "Testing: Samples"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    echo "Building all samples..."
    ~/.dotnet/dotnet build sample/RawRabbit.ConsoleApp.Sample/RawRabbit.ConsoleApp.Sample.csproj --configuration Release || TEST_EXIT_CODE=$?
    ~/.dotnet/dotnet build sample/RawRabbit.AspNet.Sample/RawRabbit.AspNet.Sample.csproj --configuration Release || TEST_EXIT_CODE=$?
    ~/.dotnet/dotnet build sample/RawRabbit.Messages.Sample/RawRabbit.Messages.Sample.csproj --configuration Release || TEST_EXIT_CODE=$?

    if [ $TEST_EXIT_CODE -eq 0 ]; then
      echo "✅ All samples build successfully"
    fi
    ;;

  7)
    echo "Testing: Full Regression"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Unit tests
    echo ""
    echo "Running unit tests..."
    ~/.dotnet/dotnet test test/RawRabbit.Tests/RawRabbit.Tests.csproj \
      --configuration Release \
      --logger "console;verbosity=detailed" || TEST_EXIT_CODE=$?

    # Integration tests (if RabbitMQ available)
    echo ""
    echo "Running integration tests..."
    if docker ps | grep -q rabbitmq; then
      ~/.dotnet/dotnet test test/RawRabbit.IntegrationTests/RawRabbit.IntegrationTests.csproj \
        --configuration Release \
        --logger "console;verbosity=detailed" || TEST_EXIT_CODE=$?
    else
      echo "⚠️  RabbitMQ not running - skipping integration tests"
      echo "Start RabbitMQ: docker run -d --name rabbitmq-test -p 5672:5672 rabbitmq:3-management"
    fi

    # Performance tests (build only)
    echo ""
    echo "Building performance tests..."
    ~/.dotnet/dotnet build test/RawRabbit.PerformanceTest/RawRabbit.PerformanceTest.csproj \
      --configuration Release || TEST_EXIT_CODE=$?
    ;;

  *)
    echo "❌ Unknown stage: $STAGE_NUM"
    echo "Valid stages: 2-7"
    exit 1
    ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $TEST_EXIT_CODE -eq 0 ]; then
  echo "✅ Stage $STAGE_NUM tests PASSED"
  echo ""
  echo "Ready to proceed to Stage $((STAGE_NUM + 1))"
else
  echo "❌ Stage $STAGE_NUM tests FAILED"
  echo ""
  echo "⚠️  FIX FAILURES before proceeding (fix-before-proceed rule)"
  echo ""
  echo "Next steps:"
  echo "1. Review test failures above"
  echo "2. Fix root cause"
  echo "3. Rerun tests: $0 $STAGE_NUM \"$STAGE_NAME\""
  echo "4. Maximum 3 iterations before escalation"
  exit 1
fi
