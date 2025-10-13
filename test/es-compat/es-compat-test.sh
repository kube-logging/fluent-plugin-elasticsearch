#!/bin/bash
# e2e_test.sh - End-to-End Test for Elasticsearch Plugin
# Tests fluent-plugin-elasticsearch against ES 7.x, 8.x, and 9.x

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
declare -a FAILED_TEST_NAMES
declare -a PASSED_TEST_NAMES

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${SCRIPT_DIR}/e2e_test_temp"

find_project_root() {
  local dir="$SCRIPT_DIR"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/lib/fluent/plugin" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  
  echo "$SCRIPT_DIR"
}

PROJECT_ROOT=$(find_project_root)
LIB_PATH="${PROJECT_ROOT}/lib"

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
  echo -e "${RED}[✗]${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}[!]${NC} $1"
}

print_banner() {
  echo ""
  echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}  $1"
  echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

print_section() {
  echo ""
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}========================================${NC}"
}

print_subsection() {
  echo ""
  echo -e "${YELLOW}--- $1 ---${NC}"
}

increment_test() {
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

pass_test() {
  PASSED_TESTS=$((PASSED_TESTS + 1))
  PASSED_TEST_NAMES+=("$1")
  log_success "$1"
}

fail_test() {
  FAILED_TESTS=$((FAILED_TESTS + 1))
  FAILED_TEST_NAMES+=("$1")
  log_error "$1"
}

cleanup() {
  print_section "Cleanup"
  
  if [ -d "$TEST_DIR" ]; then
    log_info "Removing test directory: $TEST_DIR"
    rm -rf "$TEST_DIR"
  fi
  
  log_info "Stopping Docker containers..."
  docker-compose down -v 2>/dev/null || true
  
  for port in 9207 9208 9209; do
    if curl -s "http://localhost:${port}/_cat/health" > /dev/null 2>&1; then
      log_info "Cleaning up test indices on port ${port}..."
      curl -s -X DELETE "http://localhost:${port}/test-*,fluentd-*" > /dev/null 2>&1 || true
    fi
  done
  
  log_success "Cleanup complete"
}

trap cleanup EXIT

check_prerequisites() {
  print_section "Checking Prerequisites"
  
  local missing_deps=()
  
  if ! command -v docker &> /dev/null; then
    missing_deps+=("docker")
  fi
  
  if ! command -v docker-compose &> /dev/null; then
    missing_deps+=("docker-compose")
  fi
  
  if ! command -v curl &> /dev/null; then
    missing_deps+=("curl")
  fi
  
  if ! command -v jq &> /dev/null; then
    missing_deps+=("jq")
  fi
  
  if ! command -v bundle &> /dev/null; then
    missing_deps+=("bundle")
  fi
  
  if [ ${#missing_deps[@]} -ne 0 ]; then
    log_error "Missing required dependencies: ${missing_deps[*]}"
    log_info "Please install missing dependencies and try again"
    exit 1
  fi
  
  if [ ! -d "$LIB_PATH/fluent/plugin" ]; then
    log_error "Cannot find lib/fluent/plugin directory"
    log_error "Expected at: $LIB_PATH"
    log_error "Please run this script from the project root or a subdirectory"
    exit 1
  fi
  
  local es_version=$(bundle exec ruby -e "require 'elasticsearch'; puts Elasticsearch::VERSION" 2>/dev/null || echo "unknown")
  log_info "Elasticsearch gem version: $es_version"
  
  local gem_major=$(echo "$es_version" | cut -d. -f1)
  
  log_success "All prerequisites satisfied"
  log_info "Project root: $PROJECT_ROOT"
  log_info "Lib path: $LIB_PATH"
}

setup_test_environment() {
  print_section "Setting Up Test Environment"
  
  mkdir -p "$TEST_DIR"
  log_success "Created test directory: $TEST_DIR"
}

start_elasticsearch() {
  print_section "Starting Elasticsearch Containers"
  
  log_info "Starting Docker Compose..."
  docker-compose up -d
  
  log_info "Waiting for Elasticsearch instances to be ready..."
  
  local ports=(9207 9208 9209)
  local names=("ES 7.x" "ES 8.x" "ES 9.x")
  
  for i in "${!ports[@]}"; do
    local port=${ports[$i]}
    local name=${names[$i]}
    local max_attempts=60
    local attempt=0
    
    log_info "Checking ${name} on port ${port}..."
    
    while [ $attempt -lt $max_attempts ]; do
      if curl -s "http://localhost:${port}/_cluster/health" > /dev/null 2>&1; then
        local version=$(curl -s "http://localhost:${port}" | jq -r '.version.number' 2>/dev/null || echo "unknown")
        log_success "${name} is ready (version: ${version})"
        break
      fi
      attempt=$((attempt + 1))
      if [ $((attempt % 10)) -eq 0 ]; then
        echo -n "."
      fi
      sleep 1
    done
    
    if [ $attempt -eq $max_attempts ]; then
      log_error "${name} failed to start after ${max_attempts} seconds"
      exit 1
    fi
  done
  
  echo ""
}

create_test_script() {
  local es_version=$1
  local es_port=$2
  local test_name=$3
  local extra_config=$4
  
  cat > "${TEST_DIR}/test_${test_name}.rb" << EOF
require 'bundler/setup'
require 'fluent/test'
require 'fluent/test/driver/output'

# Add lib directory to load path
\$LOAD_PATH.unshift('${LIB_PATH}')
require 'fluent/plugin/out_elasticsearch'

config = %[
  host localhost
  port ${es_port}
  logstash_format true
  logstash_prefix test-${test_name}
  type_name _doc
  ${extra_config}
]

driver = Fluent::Test::Driver::Output.new(Fluent::Plugin::ElasticsearchOutput).configure(config)

begin
  driver.run(default_tag: 'test') do
    driver.feed(Time.now.to_i, {
      "message" => "Test message for ${test_name}",
      "version" => "${es_version}",
      "test_name" => "${test_name}",
      "timestamp" => Time.now.iso8601
    })
  end
  puts "SUCCESS"
  exit 0
rescue => e
  puts "FAILED: \#{e.class}: \#{e.message}"
  puts e.backtrace.first(5).join("\n") if ENV['DEBUG']
  exit 1
end
EOF
}

run_test() {
  local test_name=$1
  local es_version=$2
  local es_port=$3
  local extra_config=$4
  
  increment_test
  
  create_test_script "$es_version" "$es_port" "$test_name" "$extra_config"
  
  if timeout 30 bundle exec ruby "${TEST_DIR}/test_${test_name}.rb" > "${TEST_DIR}/${test_name}.log" 2>&1; then
    pass_test "${test_name}"
    return 0
  else
    fail_test "${test_name}"
    if [ -f "${TEST_DIR}/${test_name}.log" ]; then
      # Show abbreviated error
      local error_msg=$(grep -E "FAILED:|Error|error" "${TEST_DIR}/${test_name}.log" | head -3)
      if [ -n "$error_msg" ]; then
        echo "    └─ $error_msg"
      fi
    fi
    return 1
  fi
}

verify_data() {
  local port=$1
  local index_pattern=$2
  local expected_count=$3
  local test_description=$4
  
  increment_test
  
  sleep 2
  
  local result=$(curl -s "http://localhost:${port}/${index_pattern}/_search?size=0" || echo '{}')
  local actual_count=$(echo "$result" | jq -r '.hits.total.value // .hits.total // 0' 2>/dev/null || echo "0")
  
  if [ "$actual_count" -ge "$expected_count" ]; then
    pass_test "${test_description}: Found ${actual_count} docs"
    return 0
  else
    fail_test "${test_description}: Found ${actual_count} docs (expected >= ${expected_count})"
    return 1
  fi
}

test_baseline() {
  print_subsection "Test 1: Baseline - Default Configuration"
  
  run_test "es7-baseline" "7" "9207" ""
  verify_data "9207" "test-es7-baseline-*" 1 "ES7 Baseline Data"
  
  run_test "es8-baseline" "8" "9208" ""
  verify_data "9208" "test-es8-baseline-*" 1 "ES8 Baseline Data"
  
  run_test "es9-baseline" "9" "9209" ""
  verify_data "9209" "test-es9-baseline-*" 1 "ES9 Baseline Data"
}

test_without_logstash_format() {
  print_subsection "Test 2: Without Logstash Format"
  
  local config="logstash_format false
  index_name test-direct"
  
  run_test "es7-direct" "7" "9207" "$config"
  verify_data "9207" "test-direct" 1 "ES7 Direct Index"
  
  run_test "es8-direct" "8" "9208" "$config"
  verify_data "9208" "test-direct" 1 "ES8 Direct Index"
  
  run_test "es9-direct" "9" "9209" "$config"
  verify_data "9209" "test-direct" 1 "ES9 Direct Index"
}

test_bulk_writes() {
  print_subsection "Test 3: Bulk Writes (10 documents)"
  
  for es_ver in 7 8 9; do
    local port=$((9207 + es_ver - 7))
    local test_name="es${es_ver}-bulk"
    
    increment_test
    
    cat > "${TEST_DIR}/test_${test_name}.rb" << EOF
require 'bundler/setup'
require 'fluent/test'
require 'fluent/test/driver/output'

\$LOAD_PATH.unshift('${LIB_PATH}')
require 'fluent/plugin/out_elasticsearch'

config = %[
  host localhost
  port ${port}
  logstash_format true
  logstash_prefix test-${test_name}
  type_name _doc
]

driver = Fluent::Test::Driver::Output.new(Fluent::Plugin::ElasticsearchOutput).configure(config)

begin
  driver.run(default_tag: 'test') do
    10.times do |i|
      driver.feed(Time.now.to_i, {
        "message" => "Bulk message \#{i}",
        "index" => i,
        "version" => "${es_ver}",
        "test_name" => "${test_name}"
      })
    end
  end
  puts "SUCCESS"
  exit 0
rescue => e
  puts "FAILED: \#{e.class}: \#{e.message}"
  exit 1
end
EOF
    
    if timeout 30 bundle exec ruby "${TEST_DIR}/test_${test_name}.rb" > "${TEST_DIR}/${test_name}.log" 2>&1; then
      pass_test "${test_name}"
    else
      fail_test "${test_name}"
    fi
    
    verify_data "$port" "test-${test_name}-*" 10 "ES${es_ver} Bulk Data"
  done
}

show_data_summary() {
  print_section "Data Summary in Elasticsearch"
  
  for es_ver in 7 8 9; do
    local port=$((9207 + es_ver - 7))
    print_subsection "ES ${es_ver}.x (port ${port})"
    
    local indices=$(curl -s "http://localhost:${port}/_cat/indices/test-*?h=index,docs.count,store.size" 2>/dev/null || echo "")
    
    if [ -n "$indices" ]; then
      echo "$indices" | while read -r line; do
        echo "  ${line}"
      done
    else
      echo "  No test indices found"
    fi
  done
}

create_compatibility_report() {
  print_section "Compatibility Report"
  
  local gem_version=$(bundle exec ruby -e "require 'elasticsearch'; puts Elasticsearch::VERSION" 2>/dev/null || echo "unknown")
  
  echo ""
  echo "Gem Version: elasticsearch ${gem_version}"
  echo ""
  
  local es7_pass=0
  local es7_fail=0
  local es8_pass=0
  local es8_fail=0
  local es9_pass=0
  local es9_fail=0
  
  for test_name in "${PASSED_TEST_NAMES[@]}"; do
    if [[ "$test_name" == *"es7"* ]]; then
      es7_pass=$((es7_pass + 1))
    elif [[ "$test_name" == *"es8"* ]]; then
      es8_pass=$((es8_pass + 1))
    elif [[ "$test_name" == *"es9"* ]]; then
      es9_pass=$((es9_pass + 1))
    fi
  done
  
  for test_name in "${FAILED_TEST_NAMES[@]}"; do
    if [[ "$test_name" == *"es7"* ]]; then
      es7_fail=$((es7_fail + 1))
    elif [[ "$test_name" == *"es8"* ]]; then
      es8_fail=$((es8_fail + 1))
    elif [[ "$test_name" == *"es9"* ]]; then
      es9_fail=$((es9_fail + 1))
    fi
  done
  
  printf "%-15s | %-6s | %-6s | %-10s\n" "ES Version" "Passed" "Failed" "Status"
  printf "%-15s-+-%-6s-+-%-6s-+-%-10s\n" "---------------" "------" "------" "----------"
  
  local es7_status="✓ OK"
  [ $es7_fail -gt 0 ] && es7_status="✗ FAILED"
  printf "%-15s | %-6s | %-6s | %-10s\n" "ES 7.x" "$es7_pass" "$es7_fail" "$es7_status"
  
  local es8_status="✓ OK"
  [ $es8_fail -gt 0 ] && es8_status="✗ FAILED"
  printf "%-15s | %-6s | %-6s | %-10s\n" "ES 8.x" "$es8_pass" "$es8_fail" "$es8_status"
  
  local es9_status="✓ OK"
  [ $es9_fail -gt 0 ] && es9_status="✗ FAILED"
  printf "%-15s | %-6s | %-6s | %-10s\n" "ES 9.x" "$es9_pass" "$es9_fail" "$es9_status"
  
  echo ""
  
  if [ $es7_fail -gt 0 ] || [ $es8_fail -gt 0 ]; then
    log_warning "Some tests failed with ES 7.x/8.x"
    if [[ "$gem_version" == 9.* ]]; then
      log_warning "You're using elasticsearch gem 9.x which has compatibility issues with ES 7/8"
      log_info "Recommendation: Use elasticsearch gem ~> 7.17 or ~> 8.x for ES 7/8 servers"
    fi
  fi
  
  if [ $es9_fail -gt 0 ]; then
    log_warning "Some tests failed with ES 9.x"
    if [[ "$gem_version" == 7.* ]] || [[ "$gem_version" == 8.* ]]; then
      log_info "Note: ES 9.x is not released yet, testing against ES 8.x placeholder"
    fi
  fi
}

print_summary() {
  print_banner "Test Results Summary"
  
  echo -e "${CYAN}Total Tests:${NC}  ${TOTAL_TESTS}"
  echo -e "${GREEN}Passed:${NC}       ${PASSED_TESTS}"
  echo -e "${RED}Failed:${NC}       ${FAILED_TESTS}"
  
  local pass_rate=0
  if [ $TOTAL_TESTS -gt 0 ]; then
    pass_rate=$((PASSED_TESTS * 100 / TOTAL_TESTS))
  fi
  
  echo -e "${CYAN}Pass Rate:${NC}    ${pass_rate}%"
  
  if [ $FAILED_TESTS -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed Tests:${NC}"
    for test_name in "${FAILED_TEST_NAMES[@]}"; do
      echo -e "  ${RED}✗${NC} ${test_name}"
      if [ -f "${TEST_DIR}/${test_name}.log" ]; then
        echo -e "    └─ Log: ${TEST_DIR}/${test_name}.log"
      fi
    done
    echo ""
    echo -e "${YELLOW}To view detailed logs:${NC}"
    echo "  cat ${TEST_DIR}/<test-name>.log"
  fi
  
  echo ""
  
  create_compatibility_report
  
  if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  🎉 ALL TESTS PASSED! 🎉           ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════╝${NC}"
    return 0
  else
    echo -e "${RED}╔════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ❌ SOME TESTS FAILED              ║${NC}"
    echo -e "${RED}╚════════════════════════════════════╝${NC}"
    return 1
  fi
}

main() {
  print_banner "Elasticsearch Plugin E2E Test Suite (Vanilla)"
  
  check_prerequisites
  setup_test_environment
  start_elasticsearch
  
  print_section "Running Tests"
  
  test_baseline
  test_without_logstash_format
  test_bulk_writes
  
  show_data_summary
  print_summary
  
  if [ $FAILED_TESTS -gt 0 ]; then
    exit 1
  else
    exit 0
  fi
}

main
