#!/bin/bash

# Configuration
NO_GENERATION_TIMEOUT=300   # 5 minutes without task activity triggers restart
CHECK_INTERVAL=60           # How often to check (seconds) - reduced for faster detection
RESTART_COOLDOWN=120        # Wait time after restart before next check
HEALTH_REPORT_INTERVAL=300  # How often to print health message (seconds)
INSTANCE_NAME="wai-1"       # The PM2 instance name to monitor
DESIRED_MODEL_PATTERNS="flux|mistral|gemma|sdxl"  # Desired model keywords (case-insensitive, pipe-separated)
MAX_MODEL_RESTARTS=3        # Max restarts before entering fallback mode
FALLBACK_DURATION=1800      # 30 minutes in fallback mode before retrying desired model

# Variables to track state
last_health_report=$(date +%s)
generation_count=0
wrong_model_restart_count=0  # Track restarts for wrong model
correct_model_announced=0    # Track if we've announced correct model
current_loaded_model=""      # Currently loaded model name
fallback_mode=0              # 1 = accept any model, 0 = require desired model
fallback_start_time=0        # When fallback mode started
fallback_announced=0         # Track if fallback mode was announced

# Function to check if the system is in initialization state
# Returns 0 (true) if in initialization, 1 (false) if not
is_in_initialization_state() {
    local logs="$1"
    
    # Get the last 20 lines to check recent state
    local recent_lines=$(echo "$logs" | tail -20)
    
    # Check for model loading (ends with "...")
    if echo "$recent_lines" | grep -qE "loading into memory\.\.\.$"; then
        # Verify this loading message is more recent than any "loaded" message
        local last_loading_line=$(echo "$recent_lines" | grep -n "loading into memory\.\.\.$" | tail -1 | cut -d: -f1)
        local last_loaded_line=$(echo "$recent_lines" | grep -n "loaded into memory\.$" | tail -1 | cut -d: -f1)
        
        # If no loaded line or loading is after loaded, we're still loading
        if [ -z "$last_loaded_line" ] || [ "$last_loading_line" -gt "$last_loaded_line" ]; then
            echo "Model is still loading"
            return 0
        fi
    fi
    
    # Check for model downloading
    if echo "$recent_lines" | grep -qiE "downloading.*model|model.*download|fetching.*model"; then
        echo "Model is downloading"
        return 0
    fi
    
    # Check for starting w.ai worker
    if echo "$recent_lines" | grep -qiE "starting.*worker|worker.*starting|initializing|w\.ai.*starting"; then
        # Make sure we haven't already completed startup
        local has_ready=$(echo "$recent_lines" | grep -ciE "loaded into memory\.$|ready|listening")
        if [ "$has_ready" -eq 0 ]; then
            echo "Worker is starting"
            return 0
        fi
    fi
    
    # Not in initialization state
    return 1
}

# Function to check if the loaded model matches desired patterns
# Returns 0 (true) if correct model, 1 (false) if wrong or no model
check_loaded_model() {
    local logs="$1"
    
    # Find the most recent "loaded into memory" message
    local loaded_line=$(echo "$logs" | grep -E "loaded into memory\.$" | tail -1)
    
    if [ -z "$loaded_line" ]; then
        # No model loaded yet
        return 2
    fi
    
    # Extract model name from the line (e.g., "Model 'flux-xxx' loaded into memory.")
    local model_name=$(echo "$loaded_line" | grep -oE "Model '[^']+' loaded" | sed "s/Model '//;s/' loaded//")
    
    if [ -z "$model_name" ]; then
        # Couldn't parse model name, try alternate format
        model_name=$(echo "$loaded_line" | grep -oiE "(flux|mistral)[^ ]*")
    fi
    
    if [ -n "$model_name" ]; then
        # Check if model matches desired patterns (case-insensitive)
        if echo "$model_name" | grep -qiE "$DESIRED_MODEL_PATTERNS"; then
            echo "$model_name"
            return 0  # Correct model
        else
            echo "$model_name"
            return 1  # Wrong model
        fi
    fi
    
    return 2  # Couldn't determine model
}

# Function to parse w.ai log timestamp and convert to epoch
# Format: [MM/DD/YYYY HH:MM:SS]
parse_log_timestamp() {
    local log_line="$1"
    # Extract timestamp like [01/13/2026 04:09:06]
    local timestamp=$(echo "$log_line" | grep -oE '\[[0-9]{2}/[0-9]{2}/[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}\]' | head -1)
    
    if [ -z "$timestamp" ]; then
        echo "0"
        return
    fi
    
    # Remove brackets
    timestamp="${timestamp:1:-1}"
    
    # Parse MM/DD/YYYY HH:MM:SS
    local month=$(echo "$timestamp" | cut -d'/' -f1)
    local day=$(echo "$timestamp" | cut -d'/' -f2)
    local year=$(echo "$timestamp" | cut -d'/' -f3 | cut -d' ' -f1)
    local time=$(echo "$timestamp" | cut -d' ' -f2)
    
    # Convert to epoch using date command
    local epoch=$(date -d "$year-$month-$day $time" +%s 2>/dev/null)
    
    if [ -z "$epoch" ]; then
        echo "0"
    else
        echo "$epoch"
    fi
}

# Function to get the most recent task completion timestamp from logs
get_last_task_time() {
    local logs="$1"
    local latest_epoch=0
    
    # Look for task completion lines
    while IFS= read -r line; do
        if echo "$line" | grep -qE "Task.*completed in|earned.*coin"; then
            local epoch=$(parse_log_timestamp "$line")
            if [ "$epoch" -gt "$latest_epoch" ]; then
                latest_epoch=$epoch
            fi
        fi
    done <<< "$logs"
    
    echo "$latest_epoch"
}

# Function to count recent task completions (within timeout window)
count_recent_tasks() {
    local logs="$1"
    local current_time="$2"
    local window="$3"
    local count=0
    
    while IFS= read -r line; do
        if echo "$line" | grep -qE "Task.*completed in"; then
            local epoch=$(parse_log_timestamp "$line")
            if [ "$epoch" -gt 0 ]; then
                local age=$((current_time - epoch))
                if [ "$age" -le "$window" ] && [ "$age" -ge 0 ]; then
                    count=$((count + 1))
                fi
            fi
        fi
    done <<< "$logs"
    
    echo "$count"
}

restart_stuck_instance() {
    local reason=$1
    
    # Check if we're in initialization state - don't restart during model loading/downloading
    local init_state
    init_state=$(is_in_initialization_state "$recent_logs")
    if [ $? -eq 0 ]; then
        echo "$(date): ⏳ Skipping restart - $init_state"
        return 1
    fi
    
    echo "$(date): 🔄 Restarting stuck instance $INSTANCE_NAME - Reason: $reason"
    pm2 restart $INSTANCE_NAME
    generation_count=0
    sleep $RESTART_COOLDOWN
}

# Force restart function - bypasses initialization check (used for wrong model restarts)
force_restart_instance() {
    local reason=$1
    echo "$(date): 🔄 Force restarting instance $INSTANCE_NAME - Reason: $reason"
    pm2 restart $INSTANCE_NAME
    generation_count=0
    wrong_model_restart_count=$((wrong_model_restart_count + 1))
    sleep $RESTART_COOLDOWN
}

echo "$(date): Starting w.ai monitor script for $INSTANCE_NAME..."
echo "$(date): No generation timeout: ${NO_GENERATION_TIMEOUT}s, Check interval: ${CHECK_INTERVAL}s"
echo "$(date): Desired models: $DESIRED_MODEL_PATTERNS"

while true; do
    recent_logs=$(pm2 logs $INSTANCE_NAME --lines 100 --nostream 2>/dev/null)
    current_time=$(date +%s)
    
    # Check 0: Model preference check - restart if wrong model is loaded
    loaded_model=$(check_loaded_model "$recent_logs")
    model_check_result=$?
    
    # Check if we should exit fallback mode (30 min elapsed)
    if [ "$fallback_mode" -eq 1 ]; then
        fallback_elapsed=$((current_time - fallback_start_time))
        if [ "$fallback_elapsed" -ge "$FALLBACK_DURATION" ]; then
            echo "$(date): 🔄 Fallback period ended (${FALLBACK_DURATION}s) - restarting to try for desired model ($DESIRED_MODEL_PATTERNS)"
            fallback_mode=0
            fallback_announced=0
            wrong_model_restart_count=0
            force_restart_instance "Exiting fallback mode - trying for flux/mistral again"
            continue
        fi
    fi
    
    if [ "$model_check_result" -eq 1 ]; then
        # Wrong model loaded
        if [ "$fallback_mode" -eq 1 ]; then
            # In fallback mode - accept any model
            current_loaded_model="$loaded_model"
            if [ "$fallback_announced" -eq 0 ]; then
                remaining=$((FALLBACK_DURATION - (current_time - fallback_start_time)))
                echo "$(date): ⏳ Fallback mode: accepting '$loaded_model' (retry desired in $((remaining/60))m)"
                fallback_announced=1
            fi
        else
            # Not in fallback - check if we should enter fallback mode
            if [ "$wrong_model_restart_count" -ge "$MAX_MODEL_RESTARTS" ]; then
                # Check if we have any recent task completions
                recent_task_count=$(count_recent_tasks "$recent_logs" "$current_time" "$NO_GENERATION_TIMEOUT")
                if [ "$recent_task_count" -eq 0 ]; then
                    echo "$(date): ⚠️ Entering fallback mode - $wrong_model_restart_count restarts with no generations"
                    echo "$(date): ⏳ Will accept any model for next $((FALLBACK_DURATION/60)) minutes"
                    fallback_mode=1
                    fallback_start_time=$current_time
                    fallback_announced=0
                    # Accept current model
                    current_loaded_model="$loaded_model"
                    correct_model_announced=0
                else
                    # Reset counter if we're getting generations
                    echo "$(date): ℹ️ Got $recent_task_count tasks despite wrong model - resetting restart counter"
                    wrong_model_restart_count=0
                fi
            else
                # Normal behavior - restart for desired model
                echo "$(date): ❌ Wrong model detected: '$loaded_model' (want: $DESIRED_MODEL_PATTERNS)"
                force_restart_instance "Wrong model '$loaded_model' - restarting for flux/mistral (attempt #$((wrong_model_restart_count + 1)))"
                correct_model_announced=0
                current_loaded_model=""
                continue
            fi
        fi
    elif [ "$model_check_result" -eq 0 ]; then
        # Correct model loaded
        current_loaded_model="$loaded_model"
        
        # Exit fallback mode if we got the desired model
        if [ "$fallback_mode" -eq 1 ]; then
            echo "$(date): 🎉 Got desired model '$loaded_model' - exiting fallback mode early!"
            fallback_mode=0
            fallback_announced=0
        fi
        
        if [ "$wrong_model_restart_count" -gt 0 ]; then
            echo "$(date): ✅ Correct model loaded: '$loaded_model' after $wrong_model_restart_count restart(s)"
            wrong_model_restart_count=0
            correct_model_announced=1
        elif [ "$correct_model_announced" -eq 0 ]; then
            echo "$(date): ✅ Correct model already loaded: '$loaded_model' - monitoring started"
            correct_model_announced=1
        fi
    fi
    # model_check_result == 2 means no model loaded yet, continue with normal checks
    
    # Check 1: Update loop stuck (5+ "Checking for updates" without recent task activity)
    update_checks=$(echo "$recent_logs" | grep -c "Checking for updates")
    if [ "$update_checks" -ge 5 ]; then
        recent_task_count=$(count_recent_tasks "$recent_logs" "$current_time" "$NO_GENERATION_TIMEOUT")
        if [ "$recent_task_count" -eq 0 ]; then
            restart_stuck_instance "Update loop detected - no tasks in last ${NO_GENERATION_TIMEOUT}s"
            continue
        fi
    fi
    
    # Check 2: No task completion for too long (using actual timestamps)
    last_task_epoch=$(get_last_task_time "$recent_logs")
    
    if [ "$last_task_epoch" -gt 0 ]; then
        time_since_task=$((current_time - last_task_epoch))
        
        if [ "$time_since_task" -ge "$NO_GENERATION_TIMEOUT" ]; then
            # Double check with more log lines
            extended_logs=$(pm2 logs $INSTANCE_NAME --lines 200 --nostream 2>/dev/null)
            last_task_extended=$(get_last_task_time "$extended_logs")
            
            if [ "$last_task_extended" -gt 0 ]; then
                time_since_extended=$((current_time - last_task_extended))
                if [ "$time_since_extended" -ge "$NO_GENERATION_TIMEOUT" ]; then
                    restart_stuck_instance "No task completion for ${time_since_extended}s (last task at $(date -d @$last_task_extended '+%H:%M:%S'))"
                    continue
                fi
            else
                restart_stuck_instance "No task completion timestamps found in logs"
                continue
            fi
        fi
    else
        # No task timestamps found at all - could be fresh start or stuck
        # Check if model is loaded and we should have tasks
        model_loaded=$(echo "$recent_logs" | grep -c "loaded into memory")
        if [ "$model_loaded" -gt 0 ]; then
            # Model is loaded but no tasks - give it some time then restart
            echo "$(date): ⚠️ Model loaded but no task completions found - monitoring..."
        fi
    fi
    
    # Check 3: Model loading timeout (stuck on loading for too long)
    loading_model=$(echo "$recent_logs" | grep -c "loading into memory")
    model_loaded=$(echo "$recent_logs" | grep -c "loaded into memory")
    if [ "$loading_model" -gt "$model_loaded" ]; then
        # Find timestamp of loading message
        loading_line=$(echo "$recent_logs" | grep "loading into memory" | tail -1)
        loading_epoch=$(parse_log_timestamp "$loading_line")
        
        if [ "$loading_epoch" -gt 0 ]; then
            loading_duration=$((current_time - loading_epoch))
            if [ "$loading_duration" -ge "$NO_GENERATION_TIMEOUT" ]; then
                restart_stuck_instance "Model loading timeout - stuck for ${loading_duration}s"
                continue
            fi
        fi
    fi
    
    # Health report: Print status every HEALTH_REPORT_INTERVAL seconds
    time_since_report=$((current_time - last_health_report))
    if [ "$time_since_report" -ge "$HEALTH_REPORT_INTERVAL" ]; then
        recent_task_count=$(count_recent_tasks "$recent_logs" "$current_time" "$HEALTH_REPORT_INTERVAL")
        
        # Get model info for health report
        model_info=""
        if [ -n "$current_loaded_model" ]; then
            model_info=" [Model: $current_loaded_model]"
        fi
        
        # Add fallback mode indicator
        if [ "$fallback_mode" -eq 1 ]; then
            remaining=$((FALLBACK_DURATION - (current_time - fallback_start_time)))
            model_info="$model_info [FALLBACK: ${remaining}s until retry]"
        fi
        
        if [ "$recent_task_count" -gt 0 ]; then
            if [ "$last_task_epoch" -gt 0 ]; then
                time_since_task=$((current_time - last_task_epoch))
                echo "$(date): ✅ Healthy - $recent_task_count tasks in last 5 min (last: ${time_since_task}s ago)$model_info"
            else
                echo "$(date): ✅ Healthy - $recent_task_count tasks in last 5 min$model_info"
            fi
        else
            if [ "$last_task_epoch" -gt 0 ]; then
                time_since_task=$((current_time - last_task_epoch))
                echo "$(date): ⚠️ Warning - 0 tasks in last 5 min (last: ${time_since_task}s ago)$model_info"
            else
                echo "$(date): ⚠️ Warning - 0 tasks detected, no recent activity$model_info"
            fi
        fi
        last_health_report=$current_time
    fi
    
    sleep $CHECK_INTERVAL
done
