#!/bin/bash
#
# gpu_schedule.sh - Analyze GPU availability and job scheduling
#
# Shows: 1) When GPUs will free up from current jobs
#        2) When next job might be scheduled
#

set -uo pipefail

PARTITION="${1:-cocosys}"

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
    
    # Get detailed GPU info
    gpu_info=$(scontrol show job "$jobid" 2>/dev/null | grep -oP 'GRES=gpu:[^(]*\([^)]+\)' || echo "")
    if [[ -z "$gpu_info" ]]; then
        gpu_info="no GPUs"
    fi
    
    end_time=$(scontrol show job "$jobid" 2>/dev/null | grep -oP 'EndTime=\K[^ ]+' || echo "N/A")
    
    echo "$jobid $user $time -> $end_time | $gpu_info"
done

echo ""
echo "=== Pending Jobs (top priority) ==="
squeue --states=pending -p "$PARTITION" --sort=-p -o "%.18i %.9P %.8j %.8u %.2t %.10M %G" 2>/dev/null | head -10 | while read -r jobid partition name user state time gres; do
    [[ -z "$jobid" ]] && continue
    [[ "$jobid" == "JOBID" ]] && continue
    priority=$(squeue -o "%.18i %.20Q" -j "$jobid" 2>/dev/null | tail -1 | awk '{print $2}')
    echo "$jobid priority=$priority $user"
done

echo ""
echo "=== GPU Utilization Summary ==="
total=0
used=0

for node in $(sinfo -p "$PARTITION" -N 2>/dev/null | awk 'NR>1 {print $1}' | sort -u); do
    [[ -z "$node" ]] && continue
    
    sinfo_line=$(sinfo -NO "Gres:20,GresUsed:30" -n "$node" 2>/dev/null | tail -1)
    [[ -z "$sinfo_line" ]] && continue
    
    gres_used=$(echo "$sinfo_line" | grep -oP 'GRES_USED=\Kgpu:[^ ]+' || true)
    
    # Total GPUs
    if [[ "$sinfo_line" =~ gpu:h200:([0-9]+) ]]; then
        node_total=${BASH_REMATCH[1]}
        total=$(( total + node_total ))
    elif [[ "$sinfo_line" =~ gpu:([0-9]+) ]]; then
        node_total=${BASH_REMATCH[1]}
        total=$(( total + node_total ))
    fi
    
    # Used GPUs
    if [[ -n "$gres_used" ]]; then
        if [[ "$gres_used" =~ IDX:([0-9,\-]+) ]]; then
            idx="${BASH_REMATCH[1]}"
            count=$(echo "$idx" | tr ',' '\n' | while read -r r; do
                if [[ "$r" == *-* ]]; then
                    seq "${r%-*}" "${r#*-}" 2>/dev/null | wc -l
                else
                    echo 1
                fi
            done | paste -sd+ | bc)
            used=$(( used + ${count:-0} ))
        elif [[ "$gres_used" =~ gpu:h200:([0-9]+) ]]; then
            used=$(( used + ${BASH_REMATCH[1]} ))
        fi
    fi
done

echo "Total GPUs: ${total:-0}"
echo "Used GPUs: ${used:-0}"
echo "Free GPUs: $(( ${total:-0} - ${used:-0} ))"

echo ""
echo "=== Next Jobs to Complete ==="
squeue --states=running -p "$PARTITION" --sort=S -o "%.18i" 2>/dev/null | head -5 | while read jobid; do
    [[ -z "$jobid" ]] && continue
    end_time=$(scontrol show job "$jobid" 2>/dev/null | grep -oP 'EndTime=\K[^ ]+' || echo "N/A")
    echo "  Job $jobid completes at $end_time"
done

echo ""
echo "=========================================="
