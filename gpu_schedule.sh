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
sinfo -NO "NodeList:15,Gres:20,GresUsed:30,State:10" -p "$PARTITION" 2>/dev/null | \
    grep -v "^$" | \
    while read line; do
        echo "$line"
    done

echo ""
echo "=== Running Jobs with GPU Reservations ==="
squeue -o "%.18i %.9P %.8j %.8u %.2t %.10M %.6D %G" --states=running -p "$PARTITION" 2>/dev/null | \
    grep "gpu:" | \
    while read -r jobid partition user state time nodes gpus; do
        if [[ -z "$jobid" ]] || [[ "$jobid" == "JOBID" ]]; then
            continue
        fi
        
        # Get job details
        job_info=$(scontrol show job "$jobid" 2>/dev/null)
        
        # Time limit
        timelimit=$(echo "$job_info" | grep -oP 'TimeLimit=\K[^ ]+' || echo "unknown")
        
        # Start time
        start_time=$(echo "$job_info" | grep -oP 'StartTime=\K[^ ]+' || echo "unknown")
        
        # End time (estimated)
        end_time=$(echo "$job_info" | grep -oP 'EndTime=\K[^ ]+' || echo "unknown")
        
        # GPU indices
        gpu_idx=$(echo "$job_info" | grep -oP 'GRES=gpu[^(]*\(IDX:\K[0-9,\-]+\)' || echo "unknown")
        
        echo "Job $jobid ($user)"
        echo "  GPUs: $gpu_idx"
        echo "  Time: $time / $timelimit"
        echo "  Started: $start_time"
        echo "  Est. End: $end_time"
        echo ""
    done

echo "=== Pending Jobs (waiting for resources) ==="
squeue -o "%.18i %.9P %.8j %.8u %.2t %.10M %.6D %G" --states=pending -p "$PARTITION" 2>/dev/null | \
    head -20 | \
    while read -r jobid partition user state time nodes gpus; do
        if [[ -z "$jobid" ]] || [[ "$jobid" == "JOBID" ]]; then
            continue
        fi
        echo "Job $jobid ($user) - Priority: $(squeue -o "%.18i %.18p" -j "$jobid" 2>/dev/null | tail -1 | awk '{print $2}')"
    done

echo ""
echo "=== Soonest GPU Availability ==="
squeue -o "%.18i %.9P %.8j %.8u %.2t %.10M %.6D %G" --states=running -p "$PARTITION" 2>/dev/null | \
    grep "gpu:" | \
    while read -r jobid partition user state time nodes gpus; do
        [[ -z "$jobid" ]] && continue
        job_info=$(scontrol show job "$jobid" 2>/dev/null)
        end_time=$(echo "$job_info" | grep -oP 'EndTime=\K[^ ]+' || echo "unknown")
        gpu_idx=$(echo "$job_info" | grep -oP 'GRES=gpu[^(]*\(IDX:\K[0-9,\-]+\)' || echo "unknown")
        
        if [[ "$end_time" != "Unknown" ]]; then
            echo "Job $jobid: GPUs $gpu_idx free at $end_time"
        fi
    done | head -10

echo ""
echo "=== GPU Utilization Summary ==="
total_gpus=0
used_gpus=0

while read -r node; do
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
            used=$(echo "$idx" | tr ',' '\n' | while read -r r; do
                if [[ "$r" == *-* ]]; then
                    seq "${r%-*}" "${r#*-}" 
                else
                    echo "$r"
                fi
            done | wc -l)
            used_gpus=$(( used_gpus + used ))
        elif [[ "$gres_used" =~ gpu:h200:([0-9]+) ]]; then
            used_gpus=$(( used_gpus + ${BASH_REMATCH[1]} ))
        fi
    fi
done < <(sinfo -n -p "$PARTITION" 2>/dev/null | awk 'NR>1 {print $1}' | sort -u)

echo "Total GPUs: $total_gpus"
echo "Used GPUs: $used_gpus"
echo "Free GPUs: $(( total_gpus - used_gpus ))"

echo ""
echo "=========================================="
