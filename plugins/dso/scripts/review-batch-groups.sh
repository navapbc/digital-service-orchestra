#!/usr/bin/env bash
# Reads a file list from stdin (one file per line).
# Groups files into at most MAX_AGENTS groups using ceiling distribution.
# Output: GROUP_1: f1 f2 ... GROUP_2: f3 f4 ... (one line per group)
#
# Usage: echo "$file_list" | MAX_AGENTS=3 bash review-batch-groups.sh
set -euo pipefail

files=()
while IFS= read -r line; do
    [[ -n "$line" ]] && files+=("$line")
done

total=${#files[@]}
max_agents="${MAX_AGENTS:-4}"
# Number of groups = min(total, MAX_AGENTS)
num_groups=$(( total < max_agents ? total : max_agents ))

if (( num_groups == 0 )); then
    exit 0
fi

# Ceiling division
base=$(( total / num_groups ))
remainder=$(( total % num_groups ))

idx=0
for (( g=1; g<=num_groups; g++ )); do
    size=$(( g <= remainder ? base + 1 : base ))
    group_files=("${files[@]:idx:size}")
    echo "GROUP_${g}: ${group_files[*]}"
    idx=$(( idx + size ))
done
