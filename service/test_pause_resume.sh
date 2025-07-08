#!/bin/bash

# --- Pause and Resume Schedule API Test Script ---
# This script tests the /goscheduler/schedules/{id}/pause and /goscheduler/schedules/{id}/resume endpoints
# Following the pattern from the provided test script

# --- Prerequisite Check ---
if ! command -v jq &> /dev/null
then
    echo "Error: 'jq' is not installed. Please install jq to run this script."
    echo "e.g., 'sudo apt-get install jq' or 'brew install jq'"
    exit 1
fi

# --- Configuration ---
host="localhost:8080"

# Check if app exists before creating
app_id="PauseAndPlayIntegrationTestingApp"
check_app_endpoint="/goscheduler/apps/$app_id"
echo "--- 1. Checking if App exists: GET $check_app_endpoint ---"
sleep 1
check_response_file=$(mktemp)
check_status_code=$(curl -s -w "%{http_code}" -o "$check_response_file" -X GET "http://$host$check_app_endpoint")

app_exists=false
if [ $? -eq 0 ] && [ "$check_status_code" -eq 200 ]; then
    app_exists=true
    echo "✓ App '$app_id' already exists, skipping creation"
else
    echo "App '$app_id' does not exist, will create it"
fi
rm "$check_response_file"

# Create app if it doesn't exist
  if [ "$app_exists" = false ]; then
    create_app_endpoint="/goscheduler/apps"
    create_app_data='{"appId":"'$app_id'","appName":"'$app_id'","appDescription":"'$app_id' app","appStatus":"ACTIVE"}'
    echo "--- Creating App: POST $create_app_endpoint ---"
    echo "Data: $create_app_data"
    sleep 1    
    response_file=$(mktemp)
    status_code=$(curl -s -w "%{http_code}" -o "$response_file" -X POST "http://$host$create_app_endpoint" -H 'Content-Type: application/json' -d "$create_app_data")

    if [ $? -eq 0 ] && [ "$status_code" -eq 200 ]; then
        app_exists=true
        echo "✓ Successfully created app"
    else
        echo "✗ Failed to create app"
        echo "Response:"
        cat "$response_file" && echo
        exit 1
    fi
    rm "$response_file"
fi

#Activate the app
activate_app_endpoint="/goscheduler/apps/$app_id/activate"
echo "--- 2. Activating App: POST $activate_app_endpoint ---"
sleep 1    
response_file=$(mktemp)
status_code=$(curl -s -w "%{http_code}" -o "$response_file" -X POST "http://$host$activate_app_endpoint" -H 'Content-Type: application/json')

if [ $? -eq 0 ] && [ "$status_code" -eq 200 ]; then
    echo "✓ Successfully activated app"
else
    echo "✗ Failed to activate app"
    echo "Response:"
    cat "$response_file" && echo
fi
rm "$response_file"

# JSON body for creating a recurring schedule that can be paused/resumed
create_recurring_schedule_data='{"appId":"'$app_id'","payload":"{}","cronExpression":"*/1 * * * *","callback":{"type":"http","details":{"url":"http://127.0.0.1:8080/goscheduler/healthcheck","method":"GET","headers":{"Content-Type":"application/json","Accept":"application/json"}}}}'

# --- Start of Pause and Resume API Tests ---
echo "Starting Pause and Resume Schedule API tests at $(date)"
echo "=================================================="

# Testing on single host
echo
sleep 1
echo "##################################################"
echo "### Testing Pause and Resume API on Node: $host ###"
echo "##################################################"
    
echo "--- Starting Dynamic Test Sequence (CREATE -> PAUSE -> RESUME) ---"
echo "This test validates the complete workflow for pausing and resuming a recurring schedule."
echo

# --- Step 1: POST to create a recurring schedule ---
create_endpoint="/goscheduler/schedules"
echo "--- 1. Creating Recurring Schedule: POST $create_endpoint ---"
echo "Data: $create_recurring_schedule_data"
sleep 1    
response_file=$(mktemp)
status_code=$(curl -s -w "%{http_code}" -o "$response_file" -X POST "http://$host$create_endpoint" -H 'Content-Type: application/json' -d "$create_recurring_schedule_data")

create_result=false

if [ $? -eq 0 ] && [ "$status_code" -eq 200 ]; then
    # Extract the scheduleId from the response using jq
    schedule_id=$(jq -r '.data.schedule.scheduleId' "$response_file" 2>/dev/null)
    
    # Validate that we got a valid UUID
    if [ -n "$schedule_id" ] && [ "$schedule_id" != "null" ] && [ "$schedule_id" != "" ]; then
        # Verify it's a recurring schedule
        cron_expression=$(jq -r '.data.schedule.cronExpression' "$response_file" 2>/dev/null)
        initial_status=$(jq -r '.data.schedule.status' "$response_file" 2>/dev/null)
        
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
    
    sleep 3m
    echo " slept for 3 mins after creating the schedule $(date)"
    
    # Get runs and print all the runs before pausing
    get_runs_endpoint="/goscheduler/schedules/$schedule_id/runs"
    echo
    echo "--- 2. Getting Runs Before Pause: GET $get_runs_endpoint ---"
    echo "This step shows the runs of the schedule before pause operation."
    sleep 1     
    get_runs_response_file=$(mktemp)
    get_runs_status_code=$(curl -s -w "%{http_code}" -o "$get_runs_response_file" --location "http://$host$get_runs_endpoint")
    echo "Runs Before Pause:"
    cat "$get_runs_response_file" && echo
    rm "$get_runs_response_file"
    
    # --- Step 3: PAUSE the schedule ---
    pause_endpoint="/goscheduler/schedules/$schedule_id/pause"
    echo
    echo "--- 3. Pausing Schedule: PUT $pause_endpoint ---"
    echo "This step pauses the recurring schedule to prepare it for resume testing."
    sleep 1
    pause_response_file=$(mktemp)
    pause_status_code=$(curl -s -w "%{http_code}" -o "$pause_response_file" -X PUT "http://$host$pause_endpoint")
    
    pause_result=false
    if [ $? -eq 0 ] && [ "$pause_status_code" -eq 200 ]; then
        # Verify the schedule is now paused
        paused_status=$(jq -r '.data.schedule.status' "$pause_response_file" 2>/dev/null)
        if [ "$paused_status" = "PAUSED" ]; then
            pause_result=true
            echo "✓ Successfully paused schedule - Status: $paused_status"
        else
            echo "✗ Schedule pause failed - Status: $paused_status (expected PAUSED)"
        fi
    else
        echo "✗ Failed to pause schedule"
    fi
    
    echo "Pause Result: $pause_result | Status Code: $pause_status_code"
    echo "Response:"
    cat "$pause_response_file" && echo
    rm "$pause_response_file"
    echo "paused the schedule at $(date)"
    
    # Before resuming, check if the schedule is paused
    get_endpoint="/goscheduler/schedules/$schedule_id"
    echo
    echo "--- 4. Getting Schedule State After Pause: GET $get_endpoint ---"
    echo "This step verifies the state of the schedule before resume operation."
    sleep 1     
    get_response_file=$(mktemp)
    schedule_status_code=$(curl -s -w "%{http_code}" -o "$get_response_file" --location "http://$host$get_endpoint")
    schedule_status=$(jq -r '.data.schedule.status' "$get_response_file" 2>/dev/null)
    if [ "$schedule_status" = "PAUSED" ]; then
        echo "✓ Schedule is paused"
    else
        echo "✗ Schedule is not paused"
    fi
    rm "$get_response_file"

    sleep 2m
    echo "slept for 2 mins after pausing the schedule at $(date)"

    # --- Step 5: RESUME the schedule (Main Test) ---
    if [ "$pause_result" = true ]; then
        resume_endpoint="/goscheduler/schedules/$schedule_id/resume"
        echo
        echo "--- 5. Resuming Schedule: PUT $resume_endpoint ---"
        echo "This is the main test - resuming a paused recurring schedule."
        sleep 1     
        resume_response_file=$(mktemp)
        resume_status_code=$(curl -s -w "%{http_code}" -o "$resume_response_file" -X PUT "http://$host$resume_endpoint")
        
        resume_result=false
        if [ $? -eq 0 ] && [ "$resume_status_code" -eq 200 ]; then
            # Verify the schedule status is now SCHEDULED
            resumed_status=$(jq -r '.data.schedule.status' "$resume_response_file" 2>/dev/null)
            success_message=$(jq -r '.status.statusMessage' "$resume_response_file" 2>/dev/null)
            
            if [ "$resumed_status" = "SCHEDULED" ]; then
                resume_result=true
                echo "✓ Schedule successfully resumed and status is SCHEDULED"
                echo "  Success Message: $success_message"
            else
                echo "✗ Schedule resume failed - status is $resumed_status (expected SCHEDULED)"
            fi
        else
            echo "✗ Failed to resume schedule"
        fi
        
        echo "Resume Result: $resume_result | Status Code: $resume_status_code"
        echo "Response:"
        cat "$resume_response_file" && echo
        rm "$resume_response_file"
    else
        echo
        echo "⚠️  PREREQUISITE FAILED: Could not pause schedule. Skipping RESUME test."
        echo "   The resume test requires a successfully paused recurring schedule."
    fi
    echo "resumed the schedule at $(date)"
    
    sleep 5m
    echo "slept for 5 mins after resuming the schedule at $(date)"
    
    # Get runs and print all the runs after resuming
    get_runs_endpoint="/goscheduler/schedules/$schedule_id/runs"
    echo
    echo "--- 6. Getting Runs After Resume: GET $get_runs_endpoint ---"
    echo "This step verifies the runs of the schedule after resume operation."
    sleep 1     
    get_runs_response_file=$(mktemp)
    get_runs_status_code=$(curl -s -w "%{http_code}" -o "$get_runs_response_file" --location "http://$host$get_runs_endpoint")
    echo "Runs After Resume:"
    cat "$get_runs_response_file" && echo
    rm "$get_runs_response_file"
    
    # --- Step 7: GET the schedule to verify final state ---
    get_endpoint="/goscheduler/schedules/$schedule_id"
    echo
    echo "--- 7. Getting Schedule Final State: GET $get_endpoint ---"
    echo "This step verifies the final state of the schedule after resume operation."
    sleep 1     
    get_response_file=$(mktemp)
    get_status_code=$(curl -s -w "%{http_code}" -o "$get_response_file" --location "http://$host$get_endpoint")
    
    get_result=false
    if [ $? -eq 0 ] && [ "$get_status_code" -eq 200 ]; then
        final_status=$(jq -r '.data.schedule.status' "$get_response_file" 2>/dev/null)
        final_cron=$(jq -r '.data.schedule.cronExpression' "$get_response_file" 2>/dev/null)
        
        if [ -n "$final_status" ] && [ "$final_status" != "null" ]; then
            get_result=true
            echo "✓ Successfully retrieved schedule state"
            echo "  Final Status: $final_status"
            echo "  Cron Expression: $final_cron"
            
            # Validate the complete workflow
            if [ "$resume_result" = true ] && [ "$final_status" = "SCHEDULED" ]; then
                echo "🎉 WORKFLOW SUCCESS: CREATE → PAUSE → RESUME completed successfully!"
            elif [ "$resume_result" = false ]; then
                echo "⚠️  WORKFLOW INCOMPLETE: Resume step failed"
            else
                echo "⚠️  WORKFLOW INCONSISTENT: Resume succeeded but final status is $final_status"
            fi
        else
            echo "✗ Failed to extract schedule status from response"
        fi
    else
        echo "✗ Failed to get schedule state"
    fi
    
    echo "Get Result: $get_result | Status Code: $get_status_code"
    echo "Response:"
    cat "$get_response_file" && echo
    rm "$get_response_file"
    
else
    echo
    echo "❌ PREREQUISITE FAILED: Could not create recurring schedule."
    echo "   Reasons could be:"
    echo "   - Service not running on $host"
    echo "   - Invalid request data"
    echo "   - Database connectivity issues"
    echo "   - Service configuration problems"
    echo
    echo "   Skipping PAUSE/RESUME tests for this host."
    echo "   Check service logs and ensure the schedule creation endpoint is working."
fi

rm "$response_file" # Clean up the CREATE response file

echo
echo "=================================================="
echo "Pause and Resume Schedule API tests completed at $(date)"  