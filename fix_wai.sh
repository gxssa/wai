#!/bin/bash

# Configuration
NO_GENERATION_TIMEOUT=300   # 5 minutes without task activity triggers restart
CHECK_INTERVAL=180          # How often to check (seconds)
RESTART_COOLDOWN=120        # Wait time after restart before next check
HEALTH_REPORT_INTERVAL=300  # How often to print health message (seconds)
INSTANCE_NAME="wai-1"       # The PM2 instance name to monitor

# Variables to track state
last_task_activity=$(date +%s)
last_health_report=$(date +%s)
generation_count=0

restart_stuck_instance() {
    local reason=$1
    echo "$(date): Restarting stuck instance $INSTANCE_NAME - Reason: $reason"
    pm2 restart $INSTANCE_NAME
    # Reset the last activity time after restart
    last_task_activity=$(date +%s)
    generation_count=0
    sleep $RESTART_COOLDOWN
}

echo "$(date): Starting w.ai monitor script for $INSTANCE_NAME..."
echo "$(date): No generation timeout: ${NO_GENERATION_TIMEOUT}s, Check interval: ${CHECK_INTERVAL}s"

while true; do
    recent_logs=$(pm2 logs $INSTANCE_NAME --lines 20 --nostream 2>/dev/null)
    current_time=$(date +%s)
    
    # Count completed tasks in recent logs
    task_patterns="Task completed|earned.*coin|Task in progress|Task.*completed in"
    completed_tasks=$(echo "$recent_logs" | grep -cE "Task completed|Task.*completed in")
    
    # Check 1: Update loop stuck (5+ "Checking for updates" without task activity)
    update_checks=$(echo "$recent_logs" | grep -c "Checking for updates")
    if [ "$update_checks" -ge 5 ]; then
        task_activity=$(echo "$recent_logs" | grep -cE "Task completed|earned.*coin|Task in progress")
        if [ "$task_activity" -eq 0 ]; then
            restart_stuck_instance "Update loop detected"
            continue
        fi
    fi
    
    # Check 2: No generation detected for too long
    has_recent_task=$(echo "$recent_logs" | grep -cE "$task_patterns")
    
    if [ "$has_recent_task" -gt 0 ]; then
        # Update last activity timestamp and count generations
        last_task_activity=$current_time
        generation_count=$((generation_count + completed_tasks))
    else
        # Check if we've exceeded the timeout
        time_since_activity=$((current_time - last_task_activity))
        
        if [ "$time_since_activity" -ge "$NO_GENERATION_TIMEOUT" ]; then
            # Double check with more log lines to be sure
            extended_logs=$(pm2 logs $INSTANCE_NAME --lines 50 --nostream 2>/dev/null)
            extended_task_activity=$(echo "$extended_logs" | grep -cE "$task_patterns")
            
            if [ "$extended_task_activity" -eq 0 ]; then
                restart_stuck_instance "No task generation for ${time_since_activity}s"
                continue
            else
                # Found activity in extended logs, reset timer
                last_task_activity=$current_time
            fi
        fi
    fi
    
    # Check 3: Model loading timeout (stuck on loading for too long)
    loading_model=$(echo "$recent_logs" | grep -c "loading into memory")
    model_loaded=$(echo "$recent_logs" | grep -c "loaded into memory")
    if [ "$loading_model" -gt 0 ] && [ "$model_loaded" -eq 0 ]; then
        time_since_activity=$((current_time - last_task_activity))
        
        if [ "$time_since_activity" -ge "$NO_GENERATION_TIMEOUT" ]; then
            restart_stuck_instance "Model loading timeout"
            continue
        fi
    fi
    
    # Health report: Print status every HEALTH_REPORT_INTERVAL seconds
    time_since_report=$((current_time - last_health_report))
    if [ "$time_since_report" -ge "$HEALTH_REPORT_INTERVAL" ]; then
        if [ "$generation_count" -gt 0 ]; then
            echo "$(date): ✅ Healthy - $generation_count generations detected in the last 5 minutes"
        else
            echo "$(date): ⚠️ Warning - 0 generations detected in the last 5 minutes"
        fi
        last_health_report=$current_time
        generation_count=0
    fi
    
    sleep $CHECK_INTERVAL
done
