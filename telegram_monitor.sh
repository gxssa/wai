#!/bin/bash

# ============================================================================
# Telegram Monitor Bot for w.ai
# Sends periodic status updates via Telegram
# ============================================================================

# --------------------------
# TELEGRAM CONFIGURATION
# --------------------------
# How to get these values:
# 1. TELEGRAM_BOT_TOKEN: 
#    - Open Telegram and search for @BotFather
#    - Send /newbot and follow the prompts
#    - Copy the token provided (looks like: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz)
#
# 2. TELEGRAM_CHAT_ID:
#    - After creating the bot, start a chat with it (send any message)
#    - Visit: https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
#    - Find "chat":{"id": YOUR_CHAT_ID} in the response
#    - For groups, add bot to group First, then check getUpdates

TELEGRAM_BOT_TOKEN="8047244720:AAHyeoL-1-gRHbKFHMmUP0pOqCdgh1B9OqU"  # Your bot token from @BotFather
TELEGRAM_CHAT_ID="1242203100"    # Your chat ID (can be personal or group)

# --------------------------
# MONITORING CONFIGURATION  
# --------------------------
REPORT_INTERVAL=300           # 5 minutes (matches fix_wai.sh HEALTH_REPORT_INTERVAL)
INSTANCE_NAME="wai-1"         # PM2 instance name to monitor
DESIRED_MODEL_PATTERNS="flux|mistral|gemma|sdxl"  # Same as fix_wai.sh

# --------------------------
# STATE TRACKING
# --------------------------
last_model=""
last_known_model=""  # Persistent model tracking (survives log rotation)
total_tasks_today=0
total_coins_today=0
day_start_time=$(date +%s)

# --------------------------
# SHUTDOWN HANDLER
# --------------------------
cleanup() {
    echo "$(date): Monitor shutting down..."
    
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=${INSTANCE_NAME} Monitor OFFLINE%0A%0AThe monitoring script has stopped. Check your server status." \
            -d "parse_mode=Markdown" > /dev/null 2>&1
    fi
    
    exit 0
}

# Trap common shutdown signals
trap cleanup SIGTERM SIGINT SIGHUP EXIT

# --------------------------
# FUNCTIONS
# --------------------------

# Send message via Telegram
send_telegram() {
    local message="$1"
    local parse_mode="${2:-Markdown}"
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "$(date): ⚠️ Telegram not configured - would send: $message"
        return 1
    fi
    
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=${parse_mode}" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo "$(date): 📤 Telegram message sent"
    else
        echo "$(date): ❌ Failed to send Telegram message"
    fi
}

# Parse log timestamp to epoch (same as fix_wai.sh)
parse_log_timestamp() {
    local log_line="$1"
    local timestamp=$(echo "$log_line" | grep -oE '\[[0-9]{2}/[0-9]{2}/[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}\]' | head -1)
    
    if [ -z "$timestamp" ]; then
        echo "0"
        return
    fi
    
    timestamp="${timestamp:1:-1}"
    
    local month=$(echo "$timestamp" | cut -d'/' -f1)
    local day=$(echo "$timestamp" | cut -d'/' -f2)
    local year=$(echo "$timestamp" | cut -d'/' -f3 | cut -d' ' -f1)
    local time=$(echo "$timestamp" | cut -d' ' -f2)
    
    local epoch=$(date -d "$year-$month-$day $time" +%s 2>/dev/null)
    
    if [ -z "$epoch" ]; then
        echo "0"
    else
        echo "$epoch"
    fi
}

# Get current loaded model from PM2 log file (robust - reads entire log file)
get_loaded_model() {
    local logs="$1"
    local loaded_line=""
    
    # PM2 log file path
    local log_file="$HOME/.pm2/logs/${INSTANCE_NAME}-out.log"
    
    # First try to find from the log file for robustness
    if [ -f "$log_file" ]; then
        loaded_line=$(grep -E "loaded into memory\.$" "$log_file" | tail -1)
    fi
    
    # Fallback to the passed logs if log file doesn't have it
    if [ -z "$loaded_line" ]; then
        loaded_line=$(echo "$logs" | grep -E "loaded into memory\.$" | tail -1)
    fi
    
    if [ -z "$loaded_line" ]; then
        # Return last known model if we have one
        echo "$last_known_model"
        return
    fi
    
    local model_name=$(echo "$loaded_line" | grep -oE "Model '[^']+' loaded" | sed "s/Model '//;s/' loaded//")
    
    if [ -z "$model_name" ]; then
        model_name=$(echo "$loaded_line" | grep -oiE "(flux|mistral|gemma|sdxl|qwen)[^ ]*" | head -1)
    fi
    
    # Update last known model if we found something valid
    if [ -n "$model_name" ]; then
        last_known_model="$model_name"
    fi
    
    echo "$model_name"
}

# Check if model is desired
is_desired_model() {
    local model="$1"
    if echo "$model" | grep -qiE "$DESIRED_MODEL_PATTERNS"; then
        return 0
    else
        return 1
    fi
}

# Count tasks in a time window
count_tasks_in_window() {
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

# Sum coins earned in a time window (from log string)
sum_coins_in_window() {
    local logs="$1"
    local current_time="$2"
    local window="$3"
    local total=0
    
    while IFS= read -r line; do
        # Match: "You earned x w.ai coins"
        if echo "$line" | grep -qE "You earned [0-9]+ w\.ai coins"; then
            local epoch=$(parse_log_timestamp "$line")
            if [ "$epoch" -gt 0 ]; then
                local age=$((current_time - epoch))
                if [ "$age" -le "$window" ] && [ "$age" -ge 0 ]; then
                    # Extract the number after "earned" and before "w.ai"
                    local coins=$(echo "$line" | grep -oE "earned [0-9]+" | grep -oE "[0-9]+")
                    if [ -n "$coins" ]; then
                        total=$((total + coins))
                    fi
                fi
            fi
        fi
    done <<< "$logs"
    
    echo "$total"
}

# Sum coins earned in last 24 hours from PM2 log FILE (robust - reads entire log file)
sum_coins_last_24h_from_file() {
    local current_time="$1"
    local window=86400  # 24 hours in seconds
    local total=0
    
    # PM2 log file path (stdout log for the instance)
    local log_file="$HOME/.pm2/logs/${INSTANCE_NAME}-out.log"
    
    # Fallback: if log file doesn't exist, use pm2 logs command with large line count
    if [ ! -f "$log_file" ]; then
        # Fallback to pm2 logs with 50k lines (should cover 24hrs)
        local logs=$(pm2 logs $INSTANCE_NAME --lines 50000 --nostream 2>/dev/null)
        while IFS= read -r line; do
            if echo "$line" | grep -qE "You earned [0-9]+ w\.ai coins"; then
                local epoch=$(parse_log_timestamp "$line")
                if [ "$epoch" -gt 0 ]; then
                    local age=$((current_time - epoch))
                    if [ "$age" -le "$window" ] && [ "$age" -ge 0 ]; then
                        local coins=$(echo "$line" | grep -oE "earned [0-9]+" | grep -oE "[0-9]+")
                        if [ -n "$coins" ]; then
                            total=$((total + coins))
                        fi
                    fi
                fi
            fi
        done <<< "$logs"
        echo "$total"
        return
    fi
    
    # Read log file and filter by timestamp
    while IFS= read -r line; do
        # Match: "You earned x w.ai coins"
        if echo "$line" | grep -qE "You earned [0-9]+ w\.ai coins"; then
            local epoch=$(parse_log_timestamp "$line")
            if [ "$epoch" -gt 0 ]; then
                local age=$((current_time - epoch))
                if [ "$age" -le "$window" ] && [ "$age" -ge 0 ]; then
                    local coins=$(echo "$line" | grep -oE "earned [0-9]+" | grep -oE "[0-9]+")
                    if [ -n "$coins" ]; then
                        total=$((total + coins))
                    fi
                fi
            fi
        fi
    done < "$log_file"
    
    echo "$total"
}

# Get total coins from PM2 log FILE (robust - reads entire log file)
get_total_coins_from_file() {
    # PM2 log file path
    local log_file="$HOME/.pm2/logs/${INSTANCE_NAME}-out.log"
    local total_line=""
    
    # Fallback: if log file doesn't exist, use pm2 logs command
    if [ ! -f "$log_file" ]; then
        # Fallback to pm2 logs with 1000 lines (recent is enough for total)
        total_line=$(pm2 logs $INSTANCE_NAME --lines 1000 --nostream 2>/dev/null | grep -E "You now have [0-9]+ w\.ai coins" | tail -1)
    else
        # Find the most recent "You now have X w.ai coins" line from the entire log file
        total_line=$(grep -E "You now have [0-9]+ w\.ai coins" "$log_file" | tail -1)
    fi
    
    if [ -z "$total_line" ]; then
        echo "0"
        return
    fi
    
    # Extract the number (after "now have")
    local total=$(echo "$total_line" | grep -oE "now have [0-9]+" | grep -oE "[0-9]+")
    echo "${total:-0}"
}



# Format the Telegram status message (uses %0A for newlines)
format_status_message() {
    local model="$1"
    local tasks_5min="$2"
    local coins_5min="$3"
    local model_status="$4"
    local total_coins="$5"
    local coins_24h="$6"
    
    # Calculate projected daily pts
    local projected_daily=$((coins_5min * 288))
    
    # Model status text
    local status_text=""
    if [ "$model_status" = "wrong" ]; then
        status_text=" (wrong model, trying to change)"
    fi
    
    # Build message with %0A for newlines
    local message="*${INSTANCE_NAME} Status*%0A"
    message+="Model: ${model:-Unknown}${status_text}%0A%0A"
    message+="💰 Total Pts: ${total_coins}%0A"
    message+="📅 Last 24h Pts: ${coins_24h}%0A%0A"
    message+="Last 5 min:%0A"
    message+="- Tasks: ${tasks_5min}%0A"
    message+="- Pts: ${coins_5min}%0A%0A"
    message+="Projected daily: ${projected_daily} pts%0A%0A"
    message+="$(date '+%Y-%m-%d %H:%M:%S')"
    
    echo "$message"
}

# --------------------------
# MAIN LOOP
# --------------------------

echo "$(date): Starting Telegram Monitor for $INSTANCE_NAME"
echo "$(date): Report interval: ${REPORT_INTERVAL}s (5 minutes)"
echo "$(date): Desired models: $DESIRED_MODEL_PATTERNS"

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo "$(date): WARNING: Telegram credentials not configured!"
    echo "$(date): Please set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in this script"
fi

# Send startup message
send_telegram "${INSTANCE_NAME} Monitor started%0AReporting every 5 minutes"

while true; do
    # Get recent logs (200 lines for 5-min window)
    recent_logs=$(pm2 logs $INSTANCE_NAME --lines 200 --nostream 2>/dev/null)
    
    current_time=$(date +%s)
    
    # Get current model
    current_model=$(get_loaded_model "$recent_logs")
    
    # Check model status
    model_status=""
    if [ -n "$current_model" ]; then
        if is_desired_model "$current_model"; then
            model_status="correct"
        else
            model_status="wrong"
        fi
    fi
    
    # Count tasks and coins in last 5 minutes
    tasks_5min=$(count_tasks_in_window "$recent_logs" "$current_time" "$REPORT_INTERVAL")
    coins_5min=$(sum_coins_in_window "$recent_logs" "$current_time" "$REPORT_INTERVAL")
    
    # Get TOTAL coins from PM2 log file (robust - reads entire file)
    total_coins=$(get_total_coins_from_file)
    
    # Calculate coins earned in last 24 hours from PM2 log file (robust - timestamp filtered)
    coins_24h=$(sum_coins_last_24h_from_file "$current_time")
    
    # Update daily totals
    total_tasks_today=$((total_tasks_today + tasks_5min))
    total_coins_today=$(echo "$total_coins_today + $coins_5min" | bc 2>/dev/null || echo "$total_coins_today")
    
    # Check if it's a new day (reset at midnight based on time elapsed > 24h)
    elapsed=$((current_time - day_start_time))
    if [ "$elapsed" -ge 86400 ]; then
        total_tasks_today=0
        total_coins_today=0
        day_start_time=$current_time
        send_telegram "New day started - daily counters reset"
    fi
    
    # Format and send status message
    message=$(format_status_message "$current_model" "$tasks_5min" "$coins_5min" "$model_status" "$total_coins" "$coins_24h")
    send_telegram "$message"
    
    # Log to console as well
    echo "$(date): 📊 Status - Model: $current_model | Tasks (5min): $tasks_5min | Pts (5min): $coins_5min | Total: $total_coins | 24h: $coins_24h"
    
    # Sleep until next report
    sleep $REPORT_INTERVAL
done
