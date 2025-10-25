---
name: testing-protocol
description: 6-phase testing protocol with fix-and-retest cycles, automated validation, and quality gates (≥95% pass rate)
---

# Generic Comprehensive Testing Protocol

**Version**: 1.0
**Purpose**: Universal testing requirements for any .NET project
**Applicability**: All .NET migrations, releases, and significant changes

---

## 1. Overview

This protocol defines **mandatory** testing requirements for all software changes. It ensures:
- ✅ Complete test execution (not partial)
- ✅ All test failures investigated and fixed
- ✅ Re-testing after fixes to validate resolution
- ✅ No test gaps or skipped validation
- ✅ Production-ready quality

**Core Principle**: **No shortcuts. Complete testing = Production confidence.**

---

## 2. Testing Phases (Mandatory Sequence)

### Phase 1: Pre-Test Setup ✅

**Requirements**:
- [ ] External dependencies running and verified (databases, message brokers, caches, etc.)
- [ ] Environment variables configured (connection strings, API keys, etc.)
- [ ] All projects build successfully (100%)
- [ ] Test projects compile without errors
- [ ] Test data/fixtures prepared
- [ ] Network connectivity verified

**Validation Commands**:
```bash
# Verify external dependencies (customize for your stack)
docker ps | grep <your-dependencies>
docker logs <container-name> | tail -20

# Verify environment
env | grep <YOUR_PREFIX>

# Verify all builds
dotnet build <YourSolution>.sln --configuration Release

# Verify test compilation
dotnet build <YourSolution>.sln --configuration Release --no-restore
```

**Common External Dependencies**:
- **Databases**: SQL Server, PostgreSQL, MySQL, MongoDB
- **Message Brokers**: RabbitMQ, Kafka, Azure Service Bus
- **Caches**: Redis, Memcached
- **Services**: Elasticsearch, S3, Azure Storage

**Exit Criteria**: All checks pass ✅

---

### Phase 2: Unit Tests (Complete Execution) ✅

**Requirements**:
- [ ] Run ALL unit tests to completion
- [ ] No timeouts or hangs
- [ ] Capture full test results (passed/failed/skipped)
- [ ] Document ALL failures with stack traces
- [ ] Measure code coverage (target: ≥80%)

**Execution Commands**:
```bash
# Run with extended timeout and detailed logging
dotnet test <YourSolution>.sln \
  --filter "Category=Unit" \
  --logger "console;verbosity=detailed" \
  --configuration Release \
  --no-build \
  --collect:"XPlat Code Coverage"

# Alternative: Run specific test project
dotnet test test/<YourProject>.Tests/<YourProject>.Tests.csproj \
  --logger "console;verbosity=detailed" \
  --configuration Release
```

**Success Criteria**:
- Pass rate 100% (MANDATORY - ALL tests must pass)
- Code coverage ≥ 80%
- Zero failures tolerated
- Execution completes (no timeouts)
- Any failing tests must be fixed immediately

**Failure Response**:
1. Document each failure (test name, error, stack trace)
2. Categorize by severity (P0/P1/P2/P3)
3. Create fix tasks for each failure
4. **DO NOT PROCEED** until fixes applied

---

### Phase 3: Integration Tests (Complete Execution) ✅

**Requirements**:
- [ ] External dependencies must be running
- [ ] Run ALL integration tests
- [ ] Test all external integrations (databases, APIs, services)
- [ ] Validate end-to-end scenarios
- [ ] Test error handling and resilience

**Execution Commands**:
```bash
# Ensure dependencies are ready
docker-compose up -d
sleep 30  # Wait for services to stabilize

# Run integration tests
dotnet test <YourSolution>.sln \
  --filter "Category=Integration" \
  --logger "console;verbosity=detailed" \
  --configuration Release \
  --no-build

# Alternative: Run specific integration test project
dotnet test test/<YourProject>.IntegrationTests/<YourProject>.IntegrationTests.csproj \
  --logger "console;verbosity=detailed" \
  --configuration Release
```

**Success Criteria**:
- Pass rate 100% (MANDATORY - ALL tests must pass)
- All external integrations validated
- End-to-end scenarios verified
- Error handling tested
- Any failing tests must be fixed immediately

**Common Integration Test Scenarios**:
- Database CRUD operations
- Message broker publish/subscribe
- HTTP API calls (internal and external)
- File system operations
- Authentication/authorization flows

**Failure Response**:
1. Document each failure with context
2. Check external dependency health
3. Verify configuration and credentials
4. Fix immediately (do not defer)
5. Re-run after fixes

---

### Phase 4: Component/Module Tests (Complete Execution) ✅

**Requirements**:
- [ ] Test all major components/modules
- [ ] Test plugin/extension systems (if applicable)
- [ ] Test middleware/pipeline components
- [ ] Test serialization/deserialization
- [ ] Test configuration systems

**Execution Commands**:
```bash
# Run tests for specific components
dotnet test <YourSolution>.sln \
  --filter "Category=Component" \
  --logger "console;verbosity=detailed" \
  --configuration Release

# Or test by namespace/module
dotnet test <YourSolution>.sln \
  --filter "FullyQualifiedName~YourProject.Components" \
  --logger "console;verbosity=detailed"
```

**Success Criteria**:
- Pass rate 100% (MANDATORY - ALL tests must pass)
- All components validated
- Plugin systems tested
- Configuration scenarios covered
- Any failing tests must be fixed immediately

---

### Phase 5: Performance Tests (Validation Build + Smoke Test) ✅

**Requirements**:
- [ ] Performance tests build successfully
- [ ] Run at least 1-2 smoke test benchmarks
- [ ] Document baseline metrics
- [ ] Compare against previous baselines (if available)
- [ ] Identify regressions >10%

**Execution Commands**:
```bash
# Build verification
dotnet build test/<YourProject>.PerformanceTests/<YourProject>.PerformanceTests.csproj \
  --configuration Release

# Run smoke test (quick benchmark)
dotnet run --project test/<YourProject>.PerformanceTests/<YourProject>.PerformanceTests.csproj \
  --configuration Release \
  -- --filter "*Critical*" --job short

# Alternative: Use BenchmarkDotNet
dotnet run --project test/<YourProject>.PerformanceTests \
  --configuration Release \
  -- --filter * --memory
```

**Success Criteria**:
- Builds successfully
- At least 2 benchmarks complete
- No performance regression >10%
- Baseline metrics documented

**Key Metrics to Track**:
- Throughput (operations/second)
- Latency (p50, p95, p99)
- Memory allocation
- CPU utilization
- Database query performance

---

### Phase 6: Sample Application Runtime Testing ✅

**Requirements**:
- [ ] All sample applications run without crashes
- [ ] Web applications start and respond to requests
- [ ] Console applications complete successfully
- [ ] No unhandled exceptions
- [ ] Logs show expected behavior

**Execution Commands**:
```bash
# Console Application
cd sample/<YourProject>.ConsoleApp.Sample
dotnet run --configuration Release &
CONSOLE_PID=$!
sleep 30  # Let it run
kill $CONSOLE_PID || true
cd ../..

# Web Application
cd sample/<YourProject>.Web.Sample
dotnet run --configuration Release &
WEB_PID=$!
sleep 10
curl -s http://localhost:5000/health || echo "Web app running"
curl -s http://localhost:5000/api/version
kill $WEB_PID || true
cd ../..
```

**Success Criteria**:
- All sample apps run without crashes
- Web apps respond to HTTP requests
- No runtime exceptions
- Logs clean (no errors)

---

## 3. Fix-and-Retest Cycle (MANDATORY) 🔄

### When Tests Fail

**DO NOT PROCEED TO NEXT PHASE** until all failures resolved.

**Fix-and-Retest Process**:

1. **Document Failures**:
   ```markdown
   ## Test Failure Log
   **Date**: YYYY-MM-DD HH:MM
   **Phase**: [Unit/Integration/Performance]

   ### Failure 1: [Test Name]
   - **Error**: [Error message]
   - **Stack Trace**:
     ```
     [Full stack trace]
     ```
   - **Root Cause**: [Analysis of why it failed]
   - **Fix Applied**: [Description of fix]
   - **Verification**: [Re-test results]
   ```

2. **Categorize by Priority**:
   - **P0 (Critical)**: Blocks core functionality → Fix immediately (same day)
   - **P1 (High)**: Blocks important features → Fix within 1 business day
   - **P2 (Medium)**: Non-critical functionality → Fix before release
   - **P3 (Low)**: Nice-to-have, edge cases → Backlog

3. **Fix Each Issue**:
   - Create specific fix task
   - Apply fix with proper code review
   - **RE-RUN SPECIFIC TEST** to validate
   - Document fix result
   - Check for related issues

4. **Re-run Full Suite**:
   - After all fixes applied
   - Execute complete test suite again
   - Verify no regressions introduced
   - Update test report with final results

5. **Iterate Until Success**:
   - Repeat fix-and-retest until pass rate met
   - Maximum 3 iterations (escalate if more needed)
   - Document all iterations

---

## 4. Test Reporting (Comprehensive) 📊

### Required Reports

**After Each Test Phase**:

1. **Test Execution Report**:
   ```markdown
   ## [Phase Name] Test Results

   **Date**: YYYY-MM-DD HH:MM
   **Duration**: X minutes
   **Configuration**: Release
   **Framework**: .NET X.0

   ### Summary
   - Total Tests: X
   - Passed: X (Y%)
   - Failed: X (Y%)
   - Skipped: X (Y%)

   ### Failures
   1. **[Test Name]**: [Error summary]
      - Category: [Unit/Integration/Performance]
      - Priority: [P0/P1/P2/P3]
      - Status: [Fixed/In Progress/Deferred]

   2. **[Test Name]**: [Error summary]
      - Category: [Unit/Integration/Performance]
      - Priority: [P0/P1/P2/P3]
      - Status: [Fixed/In Progress/Deferred]

   ### Performance Metrics (if applicable)
   - Code Coverage: X%
   - Execution Time: X seconds
   - Memory Usage: X MB

   ### Next Steps
   - [ ] Fix [Issue 1]
   - [ ] Re-test [Phase]
   - [ ] Document findings
   ```

2. **Cumulative Test Report** (updated after each phase):
   ```markdown
   ## Cumulative Testing Progress

   | Phase | Total | Passed | Failed | Pass Rate | Status |
   |-------|-------|--------|--------|-----------|--------|
   | Unit Tests | X | Y | Z | W% | ✅/⚠️/❌ |
   | Integration Tests | X | Y | Z | W% | ✅/⚠️/❌ |
   | Component Tests | X | Y | Z | W% | ✅/⚠️/❌ |
   | Performance Tests | X | Y | Z | W% | ✅/⚠️/❌ |
   | Sample Apps | X | Y | Z | W% | ✅/⚠️/❌ |

   ### Overall Status: [GREEN ✅ / YELLOW ⚠️ / RED ❌]

   ### Key Metrics
   - Overall Pass Rate: X%
   - Code Coverage: Y%
   - P0 Issues: N
   - P1 Issues: M

   ### Risk Assessment
   - [Risk 1]: [Description and mitigation]
   - [Risk 2]: [Description and mitigation]
   ```

3. **Final Test Report** (end of all phases):
   - Executive summary
   - All test results
   - All fixes applied
   - Production readiness assessment
   - Known issues and workarounds
   - Performance baseline
   - Recommendations

---

## 5. Success Criteria (Go/No-Go Decision) 🚦

### GREEN ✅ - Production Ready

**Requirements** (UPDATED: 100% Pass Rate Mandatory):
- Unit tests: 100% pass rate (ALL tests must pass)
- Integration tests: 100% pass rate (ALL tests must pass)
- Component tests: 100% pass rate (ALL tests must pass)
- Performance tests: Build + smoke test pass, <10% regression
- Sample apps: All run successfully (100%)
- Code coverage: ≥80%
- Zero P0 issues
- Zero P1 issues
- Zero P2 issues (or documented with explicit approval)

**Action**: ✅ Approve for production release

**Rationale**: 100% pass rate ensures maximum quality and reliability. Any test failure indicates a potential production bug.

---

### YELLOW ⚠️ - Conditional Go (Beta/Preview Releases Only)

**Requirements**:
- Unit tests: 100% pass rate (MANDATORY even for beta)
- Integration tests: ≥95% pass rate (exceptional cases only)
- Performance tests: Build successful
- Sample apps: At least 90% run successfully
- Code coverage: ≥75%
- Zero P0 issues
- Zero P1 issues
- P2 issues documented with workarounds

**Action**: ⚠️ Approve with conditions (beta release, limited availability, staged rollout)

**Note**: This is ONLY acceptable for beta/preview releases with explicit documentation of known issues.

---

### RED ❌ - No Go

**Criteria**:
- Unit tests: <100% pass rate
- Integration tests: <95% pass rate
- Any P0 issues unresolved
- Any P1 issues unresolved
- Core functionality broken
- Critical test infrastructure failures
- Security vulnerabilities unresolved
- Performance regression >20%

**Action**: ❌ Block release, continue fix-and-retest cycle

**Rationale**: Shipping with failing tests is unacceptable. All tests must pass before release.

---

## 6. Test Infrastructure Requirements 🛠️

### Generic Infrastructure Template

**External Dependencies** (customize for your project):

```yaml
# docker-compose.test.yml
version: '3.8'

services:
  # Database (example: PostgreSQL)
  database:
    image: postgres:16
    environment:
      POSTGRES_USER: testuser
      POSTGRES_PASSWORD: testpass
      POSTGRES_DB: testdb
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U testuser"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Message Broker (example: RabbitMQ)
  messagebroker:
    image: rabbitmq:3-management
    environment:
      RABBITMQ_DEFAULT_USER: guest
      RABBITMQ_DEFAULT_PASS: guest
    ports:
      - "5672:5672"
      - "15672:15672"
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Cache (example: Redis)
  cache:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
```

### Setup Script Template

```bash
#!/bin/bash
# setup-test-environment.sh - Universal test environment setup

set -e

PROJECT_NAME="YourProject"
echo "🚀 Setting up test environment for $PROJECT_NAME..."

# Start external dependencies
echo "📦 Starting external dependencies..."
docker-compose -f docker-compose.test.yml up -d

# Wait for services to be healthy
echo "⏳ Waiting for services to be ready..."
sleep 30

# Verify services
echo "✅ Verifying services..."
docker-compose -f docker-compose.test.yml ps

# Set environment variables
echo "🔧 Setting environment variables..."
export DATABASE_CONNECTION_STRING="Host=localhost;Port=5432;Database=testdb;Username=testuser;Password=testpass"
export MESSAGE_BROKER_URL="amqp://guest:guest@localhost:5672"
export CACHE_CONNECTION_STRING="localhost:6379"

# Restore dependencies
echo "📥 Restoring NuGet packages..."
dotnet restore "$PROJECT_NAME.sln"

# Build solution
echo "🔨 Building solution..."
dotnet build "$PROJECT_NAME.sln" --configuration Release --no-restore

echo "✅ Test environment ready!"
echo ""
echo "Run tests with:"
echo "  dotnet test $PROJECT_NAME.sln --configuration Release --no-build"
```

### Teardown Script Template

```bash
#!/bin/bash
# teardown-test-environment.sh

echo "🧹 Cleaning up test environment..."

# Stop and remove containers
docker-compose -f docker-compose.test.yml down -v

# Clean build artifacts
dotnet clean

echo "✅ Test environment cleaned"
```

---

## 7. Common Testing Mistakes to Avoid ❌

1. **Partial Test Execution**:
   - ❌ Running tests until first failure, then stopping
   - ✅ Run complete suite, document ALL failures

2. **Skipping Re-testing**:
   - ❌ Fixing issues but not validating with tests
   - ✅ Re-run after EVERY fix

3. **Ignoring Test Infrastructure**:
   - ❌ "Tests fail because dependencies not available" → acceptable
   - ✅ Set up dependencies properly, run tests correctly

4. **Accepting Low Pass Rates**:
   - ❌ "80% is good enough for now"
   - ✅ Target ≥95%, investigate all failures

5. **Not Documenting Failures**:
   - ❌ "Some tests failed, moving on"
   - ✅ Document every failure with details

6. **Deferring Fixes**:
   - ❌ "We'll fix these later"
   - ✅ Fix immediately, validate before proceeding

7. **Skipping Performance Tests**:
   - ❌ "Performance tests take too long"
   - ✅ Run at least smoke tests, track baselines

8. **Not Testing Sample Apps**:
   - ❌ "Samples are just examples"
   - ✅ Samples prove the library works end-to-end

---

## 8. Testing Checklist (Use This Every Time) ✅

### Pre-Testing
- [ ] External dependencies running and healthy
- [ ] Environment variables configured correctly
- [ ] All projects build (100%) with no errors
- [ ] Test infrastructure verified and documented
- [ ] Test data/fixtures prepared

### During Testing
- [ ] Phase 1: Unit tests (complete execution)
- [ ] Phase 2: Integration tests (all scenarios)
- [ ] Phase 3: Component tests (all modules)
- [ ] Phase 4: Performance tests (build + smoke)
- [ ] Phase 5: Sample apps (runtime validation)

### After Testing
- [ ] All test results documented
- [ ] All failures categorized (P0/P1/P2/P3)
- [ ] Fixes applied to ALL P0 and P1 issues
- [ ] Re-testing completed and documented
- [ ] Final test report generated
- [ ] Production readiness decision made
- [ ] HISTORY.md updated with test results

### Fix-and-Retest Cycle
- [ ] Document each failure with details
- [ ] Apply fix with code review
- [ ] Re-run specific test to validate
- [ ] Verify fix successful
- [ ] Re-run full suite to check for regressions
- [ ] Update cumulative report

### Completion
- [ ] Pass rate 100% (ALL tests passing - MANDATORY)
- [ ] Zero P0 issues remaining
- [ ] Zero P1 issues remaining
- [ ] All P2 issues documented (if any)
- [ ] All documentation updated
- [ ] Test environment cleaned up
- [ ] Approval obtained (if required)

---

## 9. Enforcement

**This protocol is MANDATORY for**:
- All migration stages
- All releases (major, minor, patch)
- All significant feature additions
- All dependency updates (major versions)
- All security fixes

**Violations**:
- Incomplete testing → Block release
- Skipped re-testing → Escalate to lead
- Missing documentation → Return to testing phase
- Low pass rates → Continue fix-and-retest

**Approval Authority**:
- Technical Lead: Final approval
- Testing Agent: Must follow protocol
- Project Coordinator: Verify compliance

---

## 10. Protocol Customization

### Adapt for Your Project

1. **Update external dependencies** in docker-compose.test.yml
2. **Configure test categories** (Unit, Integration, E2E, etc.)
3. **Set pass rate thresholds** based on project maturity
4. **Define P0/P1/P2/P3** criteria for your context
5. **Customize performance metrics** relevant to your domain
6. **Add project-specific test phases** (e.g., UI tests, load tests)

### Integration with CI/CD

```yaml
# Example: GitHub Actions
name: Comprehensive Testing

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: testuser
          POSTGRES_PASSWORD: testpass
        ports:
          - 5432:5432

      rabbitmq:
        image: rabbitmq:3-management
        ports:
          - 5672:5672

    steps:
      - uses: actions/checkout@v4

      - name: Setup .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '9.0.x'

      - name: Restore dependencies
        run: dotnet restore

      - name: Build
        run: dotnet build --configuration Release --no-restore

      - name: Unit Tests
        run: dotnet test --filter "Category=Unit" --logger "trx" --collect:"XPlat Code Coverage"

      - name: Integration Tests
        run: dotnet test --filter "Category=Integration" --logger "trx"

      - name: Upload Test Results
        uses: actions/upload-artifact@v3
        with:
          name: test-results
          path: '**/TestResults/*.trx'
```

---

## 11. Protocol Updates

**Version History**:
- v1.0 (2025-10-10): Initial generic protocol for all .NET projects

**Update Process**:
- Lessons learned from each release
- Continuous improvement based on failures
- Annual review and update
- Adapt to new .NET versions and testing tools

---

**Document Owner**: Testing Team / QA Lead
**Last Updated**: 2025-10-10
**Next Review**: Annually or after major project milestones
**Applicability**: Universal - All .NET projects

**Remember**: **Complete testing = Production confidence** ✅
