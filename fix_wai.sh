#!/bin/bash
restart_stuck_instance() {
    local instance_name=$1
    echo "$(date): Restarting stuck instance $instance_name"
    pm2 restart $instance_name
    sleep 60
}
while true; do
    for i in {1..9}; do
        instance_name="wai-$i"
        recent_logs=$(pm2 logs $instance_name --lines 15 --nostream 2>/dev/null)
        update_checks=$(echo "$recent_logs" | grep -c "Checking for updates")
        if [ "$update_checks" -ge 5 ]; then
            task_activity=$(echo "$recent_logs" | grep -c "Task completed\|earned.*coin\|Task in progress")
            if [ "$task_activity" -eq 0 ]; then
                restart_stuck_instance $instance_name
            fi
        fi
    done
    sleep 70
done
