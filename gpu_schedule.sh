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
echo "=== Running Jobs with GPU Reservations ==="
squeue -o "%.18i %.9P %.8j %.8u %.2t %.10M %.6D %20G" --states=running -p "$PARTITION" 2>/dev/null | head -20

echo ""
echo "=== Pending Jobs (waiting for resources) ==="
squeue -o "%.18i %.9P %.8j %.8u %.2t %.10M %.6D %20G" --states=pending -p "$PARTITION" 2>/dev/null | head -20

echo ""
echo "=== Soonest GPU Availability (next 10 jobs to complete) ==="
squeue --states=running -p "$PARTITION" 2>/dev/null | grep -v "JOBID" | head -10 | while read -r jobid rest; do
    [[ -z "$jobid" ]] && continue
    job_info=$(scontrol show job "$jobid" 2>/dev/null)
    end_time=$(echo "$job_info" | grep -oP 'EndTime=\K[^ ]+' || echo "N/A")
    gpu_info=$(echo "$job_info" | grep -oP 'GRES=gpu[^(]*\([^)]+\)' || echo "N/A")
    echo "Job $jobid: $gpu_info | Est. end: $end_time"
done

echo ""
echo "=== GPU Utilization Summary ==="
total=0
used=0

while read -r line; do
    node=$(echo "$line" | awk '{print $1}')
    [[ "$node" == "NODELIST" ]] && continue
    [[ -z "$node" ]] && continue
    
    sinfo_line=$(sinfo -NO "Gres:20,GresUsed:30" -n "$node" -p "$PARTITION" 2>/dev/null | tail -1)
    [[ -z "$sinfo_line" ]] && continue
    
    gres_used=$(echo "$sinfo_line" | grep -oP 'GRES_USED=\Kgpu:[^ ]+' || true)
    
    if [[ "$sinfo_line" =~ gpu:h200:([0-9]+) ]]; then
        total=$(( total + ${BASH_REMATCH[1]} ))
    elif [[ "$sinfo_line" =~ gpu:([0-9]+) ]]; then
        total=$(( total + ${BASH_REMATCH[1]} ))
    fi
    
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
done < <(sinfo -p "$PARTITION" 2>/dev/null | awk 'NR>1 {print $1}' | sort -u)

echo "Total GPUs: ${total:-0}"
echo "Used GPUs: ${used:-0}"
echo "Free GPUs: $(( ${total:-0} - ${used:-0} ))"

echo ""
echo "=========================================="
