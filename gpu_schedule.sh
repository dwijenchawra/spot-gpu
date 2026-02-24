#!/bin/bash
#
# gpu_schedule.sh - Analyze GPU availability and job scheduling
#
# Shows: 1) When GPUs will free up from current jobs
#        2) When next job might be scheduled
#

set -uo pipefail

PARTITION="${1:-cocosys}"
total_all=0
used_all=0

echo "=========================================="
echo "GPU Schedule Analysis for $PARTITION"
echo "=========================================="
echo ""

echo "=== Current GPU Allocation ==="
sinfo -NO "NodeList:15,Gres:20,GresUsed:30,State:10" -p "$PARTITION" 2>/dev/null

echo ""
echo "=== Running Jobs (sorted by end time) ==="
squeue --states=running -p "$PARTITION" --sort=S -o "%.18i %.9P %.8j %.8u %.2t %.10M %G" 2>/dev/null | head -15 | while read -r jobid partition name user state time gres; do
    [[ -z "$jobid" ]] && continue
    [[ "$jobid" == "JOBID" ]] && continue
    
    end_time=$(scontrol show job "$jobid" 2>/dev/null | grep -oP 'EndTime=\K[^ ]+' || echo "N/A")
    
    echo "$jobid $user $time -> $end_time"
done

echo ""
echo "=== Pending Jobs (top priority) ==="
squeue --states=pending -p "$PARTITION" --sort=-p -o "%.18i %.9P %.8j %.8u %.2t %.10M %G" 2>/dev/null | head -10 | while read -r jobid partition name user state time gres; do
    [[ -z "$jobid" ]] && continue
    [[ "$jobid" == "JOBID" ]] && continue
    priority=$(squeue -o "%.18i %.20Q" -j "$jobid" 2>/dev/null | tail -1 | awk '{print $2}')
    echo "$jobid priority=$priority $user"
done

echo "=== GPU Utilization Summary ==="

# Parse each node
for line in $(sinfo -NO "NodeList:15,Gres:20,GresUsed:30" -p "$PARTITION" 2>/dev/null | tail -n +2); do
    node=$(echo "$line" | awk '{print $1}')
    [[ -z "$node" ]] && continue
    
    # Parse total GPUs from GRES column
    if echo "$line" | grep -q "gpu:h200:"; then
        total=$(echo "$line" | grep -oP 'gpu:h200:\K[0-9]+')
    elif echo "$line" | grep -q "gpu:"; then
        total=$(echo "$line" | grep -oP 'gpu:\K[0-9]+')
    else
        continue
    fi
    
    # Parse used GPUs from GRES_USED column
    gres_used=$(echo "$line" | grep -oP 'GRES_USED=\Kgpu:[^ ]+' || echo "")
    
    used=0
    if echo "$gres_used" | grep -q "IDX:"; then
        # Has specific indices like IDX:0-5 or IDX:0,2,4
        idx=$(echo "$gres_used" | grep -oP 'IDX:\K[0-9,\-]+')
        used=$(echo "$idx" | tr ',' '\n' | while read -r r; do
            if [[ "$r" == *-* ]]; then
                seq "${r%-*}" "${r#*-}" 2>/dev/null | wc -l
            else
                echo 1
            fi
        done | paste -sd+ | bc)
    elif echo "$gres_used" | grep -q "gpu:h200:"; then
        used=$(echo "$gres_used" | grep -oP 'gpu:h200:\K[0-9]+')
    fi
    
    used=${used:-0}
    free=$(( total - used ))
    
    echo "$node: ${total}gpus total, ${used} used, ${free} free"
    
    total_all=$(( ${total_all:-0} + total ))
    used_all=$(( used_all + used ))
done

echo ""
echo "Total GPUs: ${total_all:-0}"
echo "Used GPUs: ${used_all:-0}"
echo "Free GPUs: $(( ${total_all:-0} - ${used_all:-0} ))"

echo ""
echo "=== Next Jobs to Complete ==="
squeue --states=running -p "$PARTITION" --sort=S -o "%.18i" 2>/dev/null | head -5 | while read jobid; do
    [[ -z "$jobid" ]] && continue
    end_time=$(scontrol show job "$jobid" 2>/dev/null | grep -oP 'EndTime=\K[^ ]+' || echo "N/A")
    echo "  Job $jobid completes at $end_time"
done

echo ""
echo "=========================================="
