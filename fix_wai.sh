#!/bin/bash

# Configuration
NO_GENERATION_TIMEOUT=300   # 5 minutes without task activity triggers restart
CHECK_INTERVAL=60           # How often to check (seconds) - reduced for faster detection
RESTART_COOLDOWN=120        # Wait time after restart before next check
HEALTH_REPORT_INTERVAL=300  # How often to print health message (seconds)
INSTANCE_NAME="wai-1"       # The PM2 instance name to monitor

# Variables to track state
last_health_report=$(date +%s)
generation_count=0

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
    echo "$(date): 🔄 Restarting stuck instance $INSTANCE_NAME - Reason: $reason"
    pm2 restart $INSTANCE_NAME
    generation_count=0
    sleep $RESTART_COOLDOWN
}

echo "$(date): Starting w.ai monitor script for $INSTANCE_NAME..."
echo "$(date): No generation timeout: ${NO_GENERATION_TIMEOUT}s, Check interval: ${CHECK_INTERVAL}s"

while true; do
    recent_logs=$(pm2 logs $INSTANCE_NAME --lines 100 --nostream 2>/dev/null)
    current_time=$(date +%s)
    
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
        
        if [ "$recent_task_count" -gt 0 ]; then
            if [ "$last_task_epoch" -gt 0 ]; then
                time_since_task=$((current_time - last_task_epoch))
                echo "$(date): ✅ Healthy - $recent_task_count tasks completed in last 5 min (last task ${time_since_task}s ago)"
            else
                echo "$(date): ✅ Healthy - $recent_task_count tasks completed in last 5 min"
            fi
        else
            if [ "$last_task_epoch" -gt 0 ]; then
                time_since_task=$((current_time - last_task_epoch))
                echo "$(date): ⚠️ Warning - 0 tasks in last 5 min (last task ${time_since_task}s ago)"
            else
                echo "$(date): ⚠️ Warning - 0 tasks detected, no recent activity"
            fi
        fi
        last_health_report=$current_time
    fi
    
    sleep $CHECK_INTERVAL
done
