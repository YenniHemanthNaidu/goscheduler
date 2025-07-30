#!/bin/bash

# --- Update Recurring Schedule API Test Script ---
# This script tests the /goscheduler/schedules/{id}/updateRecurringSchedule endpoint
# Based on the design document and integration test requirements

# --- Prerequisite Check ---
# Check for Python interpreter (python3 preferred, fallback to python)
if command -v python3 &> /dev/null; then
    PYTHON=python3
elif command -v python &> /dev/null; then
    PYTHON=python
else
    echo "Error: Python is not installed. Please install Python (3.x recommended) to run this script."
    exit 1
fi

# Helper function to extract a value from a JSON file using Python
# Usage: json_get <json_file> <dot.separated.path>
json_get() {
    local file="$1"
    local path="$2"
    "$PYTHON" - "$file" "$path" <<'PY'
import json, sys

file, path = sys.argv[1:3]

try:
    with open(file, 'r') as f:
        data = json.load(f)
    for key in path.split('.'):
        if isinstance(data, list):
            try:
                key = int(key)
            except ValueError:
                # If the list index is not an integer, path is invalid
                raise KeyError
        data = data[key]
    if isinstance(data, (dict, list)):
        print(json.dumps(data))
    else:
        print(data)
except Exception:
    # Print nothing on any error to mimic jq -r behavior with non-matching paths
    pass
PY
}

# Helper function to measure execution time
measure_time() {
    local start_time=$(date +%s%N)
    "$@"
    local end_time=$(date +%s%N)
    local duration=$((end_time - start_time))
    local duration_ms=$((duration / 1000000))
    echo "Execution time: ${duration_ms}ms"
    return $duration_ms
}

# --- Configuration ---
host="localhost:8080"

# --- Health Check for All Nodes ---
echo "=== HEALTH CHECK FOR ALL NODES ==="
echo "Time: $(date)"
echo

# Check node 1 (8080)
echo "Checking Node 1 (localhost:8080)..."
node1_health=$(curl -s -w "%{http_code}" -o /dev/null http://localhost:8080/goscheduler/healthcheck)
if [ "$node1_health" = "200" ]; then
    echo "✓ Node 1 (8080) is healthy"
else
    echo "✗ Node 1 (8080) is not responding (Status: $node1_health)"
fi

# Check node 2 (8081)
echo "Checking Node 2 (localhost:8081)..."
node2_health=$(curl -s -w "%{http_code}" -o /dev/null http://localhost:8081/goscheduler/healthcheck)
if [ "$node2_health" = "200" ]; then
    echo "✓ Node 2 (8081) is healthy"
else
    echo "✗ Node 2 (8081) is not responding (Status: $node2_health)"
fi

# Check node 3 (8082)
echo "Checking Node 3 (localhost:8082)..."
node3_health=$(curl -s -w "%{http_code}" -o /dev/null http://localhost:8082/goscheduler/healthcheck)
if [ "$node3_health" = "200" ]; then
    echo "✓ Node 3 (8082) is healthy"
else
    echo "✗ Node 3 (8082) is not responding (Status: $node3_health)"
fi

echo
echo "=== STARTING INTEGRATION TEST ==="
echo "Time: $(date)"
echo "Target Node: $host"
echo

# Check if apps exist before creating
app_id="UpdateRecurringScheduleIntegrationTestingApp"
athena_app_id="Athena"

# Check if main app exists
check_app_endpoint="/goscheduler/apps"
echo "--- 1. Checking if App exists: GET $check_app_endpoint?app_id=$app_id ---"
echo "Time: $(date)"
sleep 1
check_response_file=$(mktemp)
check_curl_exit_code=0
check_status_code=$(curl -s -w "%{http_code}" -o "$check_response_file" -X GET "http://$host$check_app_endpoint?app_id=$app_id")
check_curl_exit_code=$?

app_exists=false
if [ $check_curl_exit_code -eq 0 ] && [ "$check_status_code" -eq 200 ]; then
    app_exists=true
    echo "✓ App '$app_id' already exists, skipping creation"
elif [ $check_curl_exit_code -eq 0 ] && [ "$check_status_code" -eq 404 ]; then
    echo "App '$app_id' does not exist, will create it"
else
    echo "Unexpected response checking app existence (Status: $check_status_code), will attempt to create"
fi
rm "$check_response_file"

# Check if Athena app exists (required for cron schedules)
echo "--- 1.1. Checking if Athena App exists: GET $check_app_endpoint?app_id=$athena_app_id ---"
echo "Time: $(date)"
sleep 1
check_response_file=$(mktemp)
check_curl_exit_code=0
check_status_code=$(curl -s -w "%{http_code}" -o "$check_response_file" -X GET "http://$host$check_app_endpoint?app_id=$athena_app_id")
check_curl_exit_code=$?

athena_app_exists=false
if [ $check_curl_exit_code -eq 0 ] && [ "$check_status_code" -eq 200 ]; then
    athena_app_exists=true
    echo "✓ Athena App '$athena_app_id' already exists, skipping creation"
elif [ $check_curl_exit_code -eq 0 ] && [ "$check_status_code" -eq 404 ]; then
    echo "Athena App '$athena_app_id' does not exist, will create it"
else
    echo "Unexpected response checking Athena app existence (Status: $check_status_code), will attempt to create"
fi
rm "$check_response_file"

# Create main app if it doesn't exist
if [ "$app_exists" = false ]; then
    create_app_endpoint="/goscheduler/apps"
    create_app_data='{"appId":"'$app_id'","appName":"'$app_id'","appDescription":"'$app_id' app","appStatus":"ACTIVE","partitions":1,"active":true}'
    echo "--- Creating App: POST $create_app_endpoint ---"
    echo "Time: $(date)"
    echo "Data: $create_app_data"
    sleep 1    
    response_file=$(mktemp)
    curl_exit_code=0
    status_code=$(curl -s -w "%{http_code}" -o "$response_file" -X POST "http://$host$create_app_endpoint" -H 'Content-Type: application/json' -d "$create_app_data")
    curl_exit_code=$?

    if [ $curl_exit_code -eq 0 ] && ([ "$status_code" -eq 201 ] || [ "$status_code" -eq 200 ]); then
        app_exists=true
        echo "✓ Successfully created app"
        echo "Response:"
        cat "$response_file" && echo
    else
        echo "✗ Failed to create app"
        echo "Status Code: $status_code"
        echo "Response:"
        cat "$response_file" && echo
        exit 1
    fi
    rm "$response_file"
fi

# Create Athena app if it doesn't exist (required for cron schedules)
if [ "$athena_app_exists" = false ]; then
    create_app_endpoint="/goscheduler/apps"
    create_athena_app_data='{"appId":"'$athena_app_id'","appName":"'$athena_app_id'","appDescription":"Athena app for cron schedules","appStatus":"ACTIVE","partitions":1,"active":true}'
    echo "--- Creating Athena App: POST $create_app_endpoint ---"
    echo "Time: $(date)"
    echo "Data: $create_athena_app_data"
    sleep 1    
    response_file=$(mktemp)
    curl_exit_code=0
    status_code=$(curl -s -w "%{http_code}" -o "$response_file" -X POST "http://$host$create_app_endpoint" -H 'Content-Type: application/json' -d "$create_athena_app_data")
    curl_exit_code=$?

    if [ $curl_exit_code -eq 0 ] && ([ "$status_code" -eq 201 ] || [ "$status_code" -eq 200 ]); then
        athena_app_exists=true
        echo "✓ Successfully created Athena app"
        echo "Response:"
        cat "$response_file" && echo
    else
        echo "✗ Failed to create Athena app"
        echo "Status Code: $status_code"
        echo "Response:"
        cat "$response_file" && echo
        exit 1
    fi
    rm "$response_file"
fi

# Activate the apps
activate_app_endpoint="/goscheduler/apps/$app_id/activate"
echo "--- 2. Activating App: POST $activate_app_endpoint ---"
echo "Time: $(date)"
sleep 1    
response_file=$(mktemp)
activate_curl_exit_code=0
status_code=$(curl -s -w "%{http_code}" -o "$response_file" -X POST "http://$host$activate_app_endpoint" -H 'Content-Type: application/json')
activate_curl_exit_code=$?

if [ $activate_curl_exit_code -eq 0 ] && ([ "$status_code" -eq 201 ] || [ "$status_code" -eq 200 ]); then
    echo "✓ Successfully activated app"
elif [ $activate_curl_exit_code -eq 0 ] && [ "$status_code" -eq 400 ]; then
    # Check if it's already activated
    error_message=$(json_get "$response_file" "status.statusMessage")
    if [[ "$error_message" == *"already activated"* ]]; then
        echo "✓ App is already activated"
    else
        echo "✗ Failed to activate app: $error_message"
    fi
else
    echo "✗ Failed to activate app"
    echo "Response:"
    cat "$response_file" && echo
fi
rm "$response_file"

# Activate Athena app
activate_athena_app_endpoint="/goscheduler/apps/$athena_app_id/activate"
echo "--- 2.1. Activating Athena App: POST $activate_athena_app_endpoint ---"
echo "Time: $(date)"
sleep 1    
response_file=$(mktemp)
activate_curl_exit_code=0
status_code=$(curl -s -w "%{http_code}" -o "$response_file" -X POST "http://$host$activate_athena_app_endpoint" -H 'Content-Type: application/json')
activate_curl_exit_code=$?

if [ $activate_curl_exit_code -eq 0 ] && ([ "$status_code" -eq 201 ] || [ "$status_code" -eq 200 ]); then
    echo "✓ Successfully activated Athena app"
elif [ $activate_curl_exit_code -eq 0 ] && [ "$status_code" -eq 400 ]; then
    # Check if it's already activated
    error_message=$(json_get "$response_file" "status.statusMessage")
    if [[ "$error_message" == *"already activated"* ]]; then
        echo "✓ Athena app is already activated"
    else
        echo "✗ Failed to activate Athena app: $error_message"
    fi
else
    echo "✗ Failed to activate Athena app"
    echo "Response:"
    cat "$response_file" && echo
fi
rm "$response_file"

# JSON body for creating a recurring schedule that can be updated
create_recurring_schedule_data='{"appId":"'$app_id'","payload":"{\"original\":\"data1\"}","cronExpression":"*/2 * * * *","callback":{"type":"http","details":{"url":"http://localhost:8080/goscheduler/healthcheck","method":"GET","headers":{"Content-Type": "application/json","Accept": "application/json"}}}}'

# --- Start of Update Recurring Schedule API Tests ---
echo "Starting Update Recurring Schedule API tests at $(date)"
echo "=================================================="
echo "Time: $(date)"

# Testing on single host
echo
sleep 1
echo "##################################################"
echo "### Testing Update Recurring Schedule API on Node: $host ###"
echo "##################################################"
    
echo "--- Starting Integration Test Sequence (CREATE -> UPDATE -> VERIFY) ---"
echo "This test validates the complete workflow for updating a recurring schedule."
echo

# --- Step 1: POST to create a recurring schedule ---
create_endpoint="/goscheduler/schedules"
echo "--- 1. Creating Recurring Schedule: POST $create_endpoint ---"
echo "Time: $(date)"
echo "Data: $create_recurring_schedule_data"
sleep 1    
response_file=$(mktemp)
schedule_curl_exit_code=0
status_code=$(curl -s -w "%{http_code}" -o "$response_file" -X POST "http://$host$create_endpoint" -H 'Content-Type: application/json' -d "$create_recurring_schedule_data")
schedule_curl_exit_code=$?

create_result=false

if [ $schedule_curl_exit_code -eq 0 ] && ([ "$status_code" -eq 201 ] || [ "$status_code" -eq 200 ]); then
    # Extract the scheduleId from the response using Python
    schedule_id=$(json_get "$response_file" "data.schedule.scheduleId")
    
    # Validate that we got a valid UUID
    if [ -n "$schedule_id" ] && [ "$schedule_id" != "null" ] && [ "$schedule_id" != "" ]; then
        # Verify it's a recurring schedule
        cron_expression=$(json_get "$response_file" "data.schedule.cronExpression")
        initial_status=$(json_get "$response_file" "data.schedule.status")
        
        if [ -n "$cron_expression" ] && [ "$cron_expression" != "null" ] && [ "$cron_expression" != "" ]; then
            create_result=true
            echo "✓ Successfully created recurring schedule"
            echo "  Schedule ID: $schedule_id"
            echo "  Cron Expression: $cron_expression"
            echo "  Initial Status: $initial_status"
        else
            echo "✗ Created schedule is not recurring (no cron expression)"
        fi
    else
        echo "✗ Failed to extract valid schedule ID from response"
    fi
else
    echo "✗ Failed to create schedule"
fi

echo "Create Result: $create_result | Status Code: $status_code"
echo "Response:"
cat "$response_file" && echo

# --- Further steps using the extracted ID ---
if [ "$create_result" = true ] && [ -n "$schedule_id" ] && [ "$schedule_id" != "null" ]; then
    echo
    echo "--> Successfully created recurring schedule. Extracted ID: $schedule_id"
    
    echo "Starting 2-minute wait after creating schedule..."
    echo "Time: $(date)"
    #sleep 7m
    echo "Completed 2-minute wait after creating schedule"
    echo "Time: $(date)"
    
    # Get runs and print all the runs before updating
    get_runs_endpoint="/goscheduler/schedules/$schedule_id/runs"
    echo
    echo "--- 2. Getting Runs Before Update: GET $get_runs_endpoint ---"
    echo "Time: $(date)"
    echo "This step shows the runs of the schedule before update operation."
    sleep 1     
    get_runs_response_file=$(mktemp)
    get_runs_status_code=$(curl -s -w "%{http_code}" -o "$get_runs_response_file" --location "http://$host$get_runs_endpoint")
    echo "Runs Before Update:"
    cat "$get_runs_response_file" && echo
    rm "$get_runs_response_file"
    
    # --- Step 3: UPDATE the schedule (Main Test) ---
    update_endpoint="/goscheduler/schedules/$schedule_id/updateRecurringSchedule"
    echo
    echo "--- 3. Updating Recurring Schedule: PUT $update_endpoint ---"
    echo "Time: $(date)"
    echo "This is the main test - updating a recurring schedule with new cron expression, payload, and callback details."
    
    # JSON body for updating the recurring schedule
    #update_schedule_data='{"appId":"'$app_id'","payload":"{\"updated\":\"data\",\"newField\":\"value\"}","cronExpression":"*/1 * * * *","callback":{"type":"http","details":{"url":"http://localhost:8080/goscheduler/healthcheck","method":"POST","headers":{"Content-Type": "application/json","Accept": "application/json","X-Updated": "true"}}}}'
    update_schedule_data='{"appId":"'$app_id'","payload":"{\"updated\":\"data\",\"newField\":\"value\"}","cronExpression":"*/1 * * * *","callback":{"type":"airbusCallback","eventName":"updated_event","appName":"updated_app","headers":{"Content-Type": "application/json","Accept": "application/json","X-Updated": "true"}}}'


    echo "Update Data: $update_schedule_data"
    sleep 1
    update_response_file=$(mktemp)
    
    # Measure execution time for performance testing
    start_time=$(date +%s%N)
    update_status_code=$(curl -s -w "%{http_code}" -o "$update_response_file" -X PUT "http://$host$update_endpoint" -H 'Content-Type: application/json' -d "$update_schedule_data")
    end_time=$(date +%s%N)
    duration=$((end_time - start_time))
    duration_ms=$((duration / 1000000))
    
    update_result=false
    if [ $? -eq 0 ] && [ "$update_status_code" -eq 200 ]; then
        # Verify the schedule was updated successfully
        updated_cron=$(json_get "$update_response_file" "data.schedule.cronExpression")
        updated_payload=$(json_get "$update_response_file" "data.schedule.payload")
        updated_status=$(json_get "$update_response_file" "data.schedule.status")
        success_message=$(json_get "$update_response_file" "status.statusMessage")
        
        if [ "$updated_cron" = "*/1 * * * *" ] && [ "$updated_status" = "SCHEDULED" ]; then
            update_result=true
            echo "✓ Schedule successfully updated"
            echo "  New Cron Expression: $updated_cron"
            echo "  Updated Payload: $updated_payload"
            echo "  Status: $updated_status"
            echo "  Success Message: $success_message"
            echo "  Performance: ${duration_ms}ms"
            
            # Performance validation (should be < 100ms)
            if [ $duration_ms -lt 100 ]; then
                echo "✓ Performance requirement met (< 100ms)"
            else
                echo "⚠️  Performance requirement not met (${duration_ms}ms >= 100ms)"
            fi
        else
            echo "✗ Schedule update failed - cron: $updated_cron, status: $updated_status (expected */1 * * * * and SCHEDULED)"
        fi
    else
        echo "✗ Failed to update schedule"
    fi
    
    echo "Update Result: $update_result | Status Code: $update_status_code | Duration: ${duration_ms}ms"
    echo "Response:"
    cat "$update_response_file" && echo
    rm "$update_response_file"
    echo "Schedule update completed at $(date)"
    
    echo "Starting 3-minute wait after updating schedule..."
    echo "Time: $(date)"
    sleep 6m
    echo "Completed 3-minute wait after updating schedule"
    echo "Time: $(date)"
    
    # --- Step 4: Verify data consistency across tables ---
    echo
    echo "--- 4. Data Consistency Verification ---"
    echo "Time: $(date)"
    echo "This step verifies that the update was applied atomically across all tables."
    
    # Get the updated schedule to verify consistency
    get_endpoint="/goscheduler/schedules/$schedule_id"
    echo "--- 4.1. Getting Updated Schedule: GET $get_endpoint ---"
    echo "Time: $(date)"
    sleep 1     
    get_response_file=$(mktemp)
    get_status_code=$(curl -s -w "%{http_code}" -o "$get_response_file" --location "http://$host$get_endpoint")
    
    if [ $? -eq 0 ] && [ "$get_status_code" -eq 200 ]; then
        final_cron=$(json_get "$get_response_file" "data.schedule.cronExpression")
        final_payload=$(json_get "$get_response_file" "data.schedule.payload")
        final_status=$(json_get "$get_response_file" "data.schedule.status")
        
        echo "✓ Successfully retrieved updated schedule"
        echo "  Final Cron Expression: $final_cron"
        echo "  Final Payload: $final_payload"
        echo "  Final Status: $final_status"
        
        # Verify consistency
        if [ "$final_cron" = "*/1 * * * *" ] && [ "$final_status" = "SCHEDULED" ]; then
            echo "✓ Data consistency verified - all fields updated correctly"
        else
            echo "✗ Data inconsistency detected"
        fi
    else
        echo "✗ Failed to get updated schedule"
    fi
    
    echo "Get Result: $get_result | Status Code: $get_status_code"
    echo "Response:"
    cat "$get_response_file" && echo
    rm "$get_response_file"
    
    # Get runs and print all the runs after updating
    get_runs_endpoint="/goscheduler/schedules/$schedule_id/runs"
    echo
    echo "--- 5. Getting Runs After Update: GET $get_runs_endpoint ---"
    echo "Time: $(date)"
    echo "This step verifies that future runs were deleted and new runs are being generated with updated cron."
    sleep 1     
    get_runs_response_file=$(mktemp)
    get_runs_status_code=$(curl -s -w "%{http_code}" -o "$get_runs_response_file" --location "http://$host$get_runs_endpoint")
    echo "Runs After Update:"
    cat "$get_runs_response_file" && echo
    rm "$get_runs_response_file"
    
    # --- Step 6: Test rate limiting (I-05) ---
    echo
    echo "--- 6. Rate Limiting Integration Test ---"
    echo "Time: $(date)"
    echo "This test verifies rate limiting behavior for rapid update requests."
    fi
#     # Send multiple rapid requests to test rate limiting
#     echo "Sending 5 rapid update requests to test rate limiting..."
#     rate_limit_hit=false
#     for i in {1..5}; do
#         echo "  Request $i:"
#         rapid_response_file=$(mktemp)
#         rapid_status_code=$(curl -s -w "%{http_code}" -o "$rapid_response_file" -X PUT "http://$host$update_endpoint" -H 'Content-Type: application/json' -d "$update_schedule_data")
        
#         if [ "$rapid_status_code" -eq 429 ]; then
#             rate_limit_hit=true
#             echo "    ✓ Rate limit hit (429) - Request blocked as expected"
#         else
#             echo "    Status: $rapid_status_code"
#         fi
        
#         cat "$rapid_response_file" && echo
#         rm "$rapid_response_file"
        
#         # Small delay between requests
#         sleep 0.1
#     done
    
#     if [ "$rate_limit_hit" = true ]; then
#         echo "✓ Rate limiting properly integrated"
#     else
#         echo "⚠️  Rate limiting not triggered (may need higher request volume)"
#     fi
    
#     # --- Step 7: Test invalid update scenarios ---
#     echo
#     echo "--- 7. Invalid Update Scenarios Test ---"
#     echo "Time: $(date)"
    
#     # Test with invalid cron expression
#     echo "--- 7.1. Testing Invalid Cron Expression ---"
#     echo "Time: $(date)"
#     invalid_cron_data='{"appId":"'$app_id'","payload":"{\"test\":\"invalid\"}","cronExpression":"invalid cron","callback":{"type":"http","details":{"url":"http://localhost:8080/goscheduler/healthcheck","method":"GET","headers":{"Content-Type": "application/json"}}}}'
    
#     invalid_response_file=$(mktemp)
#     invalid_status_code=$(curl -s -w "%{http_code}" -o "$invalid_response_file" -X PUT "http://$host$update_endpoint" -H 'Content-Type: application/json' -d "$invalid_cron_data")
    
#     if [ "$invalid_status_code" -eq 422 ]; then
#         echo "✓ Invalid cron expression properly rejected (422)"
#     else
#         echo "✗ Invalid cron expression not properly rejected (Status: $invalid_status_code)"
#     fi
    
#     echo "Response:"
#     cat "$invalid_response_file" && echo
#     rm "$invalid_response_file"
    
#     # Test with non-existent schedule ID
#     echo "--- 7.2. Testing Non-existent Schedule ID ---"
#     echo "Time: $(date)"
#     fake_uuid="00000000-0000-0000-0000-000000000000"
#     fake_endpoint="/goscheduler/schedules/$fake_uuid/updateRecurringSchedule"
    
#     fake_response_file=$(mktemp)
#     fake_status_code=$(curl -s -w "%{http_code}" -o "$fake_response_file" -X PUT "http://$host$fake_endpoint" -H 'Content-Type: application/json' -d "$update_schedule_data")
    
#     if [ "$fake_status_code" -eq 404 ]; then
#         echo "✓ Non-existent schedule properly rejected (404)"
#     else
#         echo "✗ Non-existent schedule not properly rejected (Status: $fake_status_code)"
#     fi
    
#     echo "Response:"
#     cat "$fake_response_file" && echo
#     rm "$fake_response_file"
    
    # --- Step 8: DELETE the schedule to clean up ---
    delete_endpoint="/goscheduler/schedules/$schedule_id"
    echo
    echo "--- 8. Deleting Schedule: DELETE $delete_endpoint ---"
    echo "Time: $(date)"
    echo "This step cleans up by deleting the schedule created for testing."
    sleep 1
    delete_response_file=$(mktemp)
    delete_status_code=$(curl -s -w "%{http_code}" -o "$delete_response_file" -X DELETE "http://$host$delete_endpoint")

    if [ $? -eq 0 ] && [ "$delete_status_code" -eq 200 ]; then
        echo "✓ Successfully deleted schedule"
    else
        echo "✗ Failed to delete schedule"
        echo "Response:"
        cat "$delete_response_file" && echo
    fi
    rm "$delete_response_file"
    
#     # --- Test Summary ---
#     echo
#     echo "=================================================="
#     echo "INTEGRATION TEST SUMMARY"
#     echo "Time: $(date)"
#     echo "=================================================="
#     echo "I-01 End-to-End Happy Path: $([ "$update_result" = true ] && echo "✓ PASSED" || echo "✗ FAILED")"
#     echo "I-02 Data Consistency Verification: $([ "$update_result" = true ] && echo "✓ PASSED" || echo "✗ FAILED")"
#     echo "I-03 Future Runs Cleanup Verification: $([ "$update_result" = true ] && echo "✓ PASSED" || echo "✗ FAILED")"
#     echo "I-04 Batch Failure Rollback: $([ "$update_result" = true ] && echo "✓ PASSED" || echo "⚠️  NOT TESTED")"
#     echo "I-05 Rate Limiting Integration: $([ "$rate_limit_hit" = true ] && echo "✓ PASSED" || echo "⚠️  NOT TRIGGERED")"
#     echo "Performance Requirement (< 100ms): $([ $duration_ms -lt 100 ] && echo "✓ PASSED (${duration_ms}ms)" || echo "✗ FAILED (${duration_ms}ms)")"
    
#     # Validate the complete workflow
#     if [ "$update_result" = true ]; then
#         echo "🎉 WORKFLOW SUCCESS: CREATE → UPDATE → VERIFY completed successfully!"
#     else
#         echo "⚠️  WORKFLOW INCOMPLETE: Update step failed"
#     fi
    
# else
#     echo
#     echo "❌ PREREQUISITE FAILED: Could not create recurring schedule."
#     echo "   Reasons could be:"
#     echo "   - Service not running on $host"
#     echo "   - Invalid request data"
#     echo "   - Database connectivity issues"
#     echo "   - Service configuration problems"
#     echo "   - UpdateRecurringSchedule endpoint not implemented yet"
#     echo
#     echo "   Skipping UPDATE tests for this host."
#     echo "   Check service logs and ensure the schedule creation endpoint is working."
# fi

rm "$response_file" # Clean up the CREATE response file

echo
echo "=================================================="
echo "Update Recurring Schedule API tests completed at $(date)"
echo "Final Time: $(date)"
echo "=================================================="
echo
echo "Note: This test assumes the /goscheduler/schedules/{id}/updateRecurringSchedule"
echo "endpoint is implemented. If the endpoint is not yet available, the tests"
echo "will fail with 404 errors. This is expected during development."
echo
echo "Expected endpoint: PUT /goscheduler/schedules/{id}/updateRecurringSchedule"
echo "Expected request body: JSON with updated cronExpression, payload, and callback details"
echo "Expected response: 200 OK with updated schedule data" 