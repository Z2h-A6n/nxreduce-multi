#!/bin/bash
# Launcher for multi-node nxreduce job submission.
# - Accepts a list of input paths via args, a file, or stdin.
# - Validates inputs.
# - Writes an inputs.txt and cmd.txt into a run directory on a shared filesystem.
# - Submits nxreduce-multinode.sh to PBS with a node count based on queue limits and number of inputs.
#
# Optional flags:
#   --force                 Proceed even if inputs are fewer than the queue's minimum node count.
#   --queue Q               PBS queue name (default: debug). Queue selection sets min/max node limits.
#   --walltime HH:MM:SS     Walltime (default: 01:00:00)
#   --account A             Project/account (default: AXMAS-Reduction)
#   --name NAME             PBS job name (default: nxreduce-multinode)
#   --runs-dir DIR          Base directory to store run artifacts (default: $PWD/nxreduce_runs)
#   --dry-run               Prepare RUN_DIR and print planned commands/paths, but do NOT submit the job.
#
# Notes:
#   - Ensure you run this from a directory on a shared filesystem (home/eagle) so the compute nodes can access RUN_DIR.
#   - The command string provided via --cmd can include '{}' as a placeholder for the input path. If '{}' is not present,
#     the input path will be appended as the final argument by the worker. Avoid quoting '{}' in cmd.txt; the worker will
#     safely escape the path.
#   - Queue constraints: each queue defines a minimum and maximum number of nodes. Requests below the minimum will be
#     adjusted up to the minimum (unless --force is not used, in which case it's an error). Requests above the maximum
#     are an error.

set -euo pipefail

cmd=""
inputs_file=""
force="false"
queue="debug"
walltime="01:00:00"
account="AXMAS-Reduction"
name="nxreduce-multinode"
runs_dir="/eagle/AXMAS-Reduction/nxreduce_runs"
dry_run="false"

# Per-queue limits (set via set_queue_limits)
min_nodes=""
max_nodes=""

# Helper: set per-queue node limits. Replace placeholder values with real limits for your PBS configuration.
set_queue_limits() {
    local q="${1:-}"
    case "${q}" in
        'debug')
            min_nodes=1
            max_nodes=2
            ;;
        'debug-scaling')
            min_nodes=1
            max_nodes=10
            ;;
        'preemptable')
            min_nodes=1
            max_nodes=10
            ;;
        'prod')
            # max_nodes is set artificially low to avoid submitting huge jobs
            # without being sure of it. Use prod-large for large jobs.
            min_nodes=10
            max_nodes=50
            ;;
        'prod-large')
            # This isn't a real queue, it's just a way of bypassing the
            # artificially-low max_nodes set for 'prod' above.
            # max_nodes is set lower than total node count to avoid issues with
            # node downtime.
            queue='prod'
            min_nodes=10
            max_nodes=476
            ;;
        *)
            echo "ERROR: Unsupported or unknown queue: '${q}'. Please choose a valid queue." >&2
            exit 1
            ;;
    esac
}

# TODO: Make this more robust by relying on something other than hard-coded line numbers.
print_usage() {
    sed -n '1,100p' "$0" | sed -n '1,60p' | grep -E '^(#|\s*$)' | sed 's/^#\s*//'
}

# Parse arguments
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cmd)
            shift
            cmd="${1:-}"
            ;;
        --inputs-file)
            shift
            inputs_file="${1:-}"
            ;;
        --force)
            force="true"
            ;;
        --queue)
            shift
            queue="${1:-}"
            ;;
        --walltime)
            shift
            walltime="${1:-}"
            ;;
        --account)
            shift
            account="${1:-}"
            ;;
        --name)
            shift
            name="${1:-}"
            ;;
        --runs-dir)
            shift
            runs_dir="${1:-}"
            ;;
        --dry-run)
            dry_run="true"
            ;;
        -h | --help)
            print_usage
            exit 0
            ;;
        --)
            shift
            # Remaining args are inputs
            while [[ $# -gt 0 ]]; do
                args+=("$1")
                shift
            done
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            args+=("$1")
            ;;
    esac
    shift || true
done

# Validate queue and set limits early
set_queue_limits "${queue}"

if [[ -z "${cmd}" ]]; then
    echo "ERROR: --cmd 'your_command and options (without the input path)' is required." >&2
    exit 1
fi

# Collect inputs ...
inputs=()

# ... from file, if provided
if [[ -n "${inputs_file}" ]]; then
    if [[ ! -f "${inputs_file}" ]]; then
        echo "ERROR: Inputs file not found: ${inputs_file}" >&2
        exit 1
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        inputs+=("$line")
    done < "${inputs_file}"
fi

# ... from positional arguments
if [[ "${#args[@]}" -gt 0 ]]; then
    inputs+=("${args[@]}")
fi

# ... from stdin if stdin has data
if [[ ! -t 0 ]]; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        inputs+=("$line")
    done
fi

if [[ "${#inputs[@]}" -eq 0 ]]; then
    echo "ERROR: No input paths provided. Use positional args, --inputs-file, or pipe via stdin." >&2
    exit 1
fi

# Validate inputs and normalize to absolute paths if possible
normalized_inputs=()
for p in "${inputs[@]}"; do
    # Trim whitespace
    p_trim="$(printf "%s" "$p" | awk '{$1=$1};1')"
    if [[ ! -d "${p_trim}" && ! -f "${p_trim}" ]]; then
        echo "ERROR: Input path does not exist: ${p_trim}" >&2
        exit 1
    fi
    # Try to resolve all paths to absolute paths
    if command -v readlink > /dev/null 2>&1; then
        abs="$(readlink -f "${p_trim}" || echo "${p_trim}")"
    elif [[ "${p_trim}" = /* ]]; then
        abs="${p_trim}"
    else
        abs="$(cd "$(dirname "${p_trim}")" && pwd -P)/$(basename "${p_trim}")"
    fi
    normalized_inputs+=("${abs}")
done

num_inputs="${#normalized_inputs[@]}"

if [[ "${num_inputs}" -lt 1 ]]; then
    echo "ERROR: At least one input is required (use --force to bypass this check)." >&2
    exit 1
fi

# Enforce queue-specific limits
# Too many inputs for this queue?
if (( num_inputs > max_nodes )); then
    echo "ERROR: Number of inputs (${num_inputs}) exceeds queue '${queue}' max-nodes (${max_nodes})." >&2
    if [[ "${queue}" == "prod" ]]; then
        echo "       Use virtual queue 'prod-large' to submit large jobs." >&2
    fi
    exit 1
fi

# Fewer inputs than the queue's minimum? Require --force to proceed.
if (( num_inputs < min_nodes )) && [[ "${force}" != "true" ]]; then
    echo "ERROR: Number of inputs (${num_inputs}) is below queue '${queue}' min-nodes (${min_nodes}). Use --force to proceed anyway." >&2
    exit 1
fi

# Compute requested nodes: at least min_nodes, otherwise num_inputs
requested_nodes="${num_inputs}"
if (( num_inputs < min_nodes )); then
    requested_nodes="${min_nodes}"
fi

# Prepare run directory
timestamp="$(date +'%Y%m%d_%H%M%S')"
run_dir="${runs_dir}/${name}_${timestamp}"
mkdir -p "${run_dir}"

# Write inputs.txt
inputs_txt="${run_dir}/inputs.txt"
printf "%s\n" "${normalized_inputs[@]}" > "${inputs_txt}"

# Write cmd.txt (single line with the base command)
cmd_txt="${run_dir}/cmd.txt"
printf "%s\n" "${cmd}" > "${cmd_txt}"

# Generate a single source-of-truth mpiexec script that both dry-run and PBS job will use
mpiexec_script="${run_dir}/mpiexec.sh"
cat > "${mpiexec_script}" <<EOF
#!/bin/bash
set -euo pipefail
# Auto-generated by nxreduce-launch.sh on $(date -u +'%Y-%m-%dT%H:%M:%SZ')
RUN_DIR="${run_dir}"
INPUTS_FILE="\${RUN_DIR}/inputs.txt"
CMD_FILE="\${RUN_DIR}/cmd.txt"
LOGDIR="\${RUN_DIR}/logs"
STATUSDIR="\${RUN_DIR}/status"
WORKER="\${RUN_DIR}/worker.sh"

# Determine number of tasks dynamically from the inputs file
NUM_TASKS=\$(wc -l < "\${INPUTS_FILE}")

echo "Dispatching \${NUM_TASKS} tasks (one per node) via mpiexec..."
mpiexec -n "\${NUM_TASKS}" -ppn 1 "\${WORKER}" "\${INPUTS_FILE}" "\${CMD_FILE}" "\${LOGDIR}" "\${STATUSDIR}"
EOF
chmod +x "${mpiexec_script}"

echo "Prepared run directory: ${run_dir}"
echo " - Inputs: ${inputs_txt} (${num_inputs} items)"
echo " - Command: ${cmd_txt}"
echo " - mpiexec script: ${mpiexec_script}"

# Locate PBS script (assumed to be alongside this launcher)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pbs_script="${script_dir}/nxreduce-multinode.sh"
if [[ ! -f "${pbs_script}" ]]; then
    echo "ERROR: PBS script not found at ${pbs_script}" >&2
    exit 1
fi

# Build the qsub command (as an array) that would be executed
qsub_cmd=( qsub )
qsub_cmd+=( -l "select=${requested_nodes}" )
qsub_cmd+=( -q "${queue}" )
qsub_cmd+=( -l "walltime=${walltime}" )
qsub_cmd+=( -A "${account}" )
qsub_cmd+=( -N "${name}" )
qsub_cmd+=( -v "RUN_DIR=${run_dir}" )
qsub_cmd+=( "${pbs_script}" )

# If dry-run, print planned commands and paths, then exit without submitting
if [[ "${dry_run}" == "true" ]]; then
    echo "DRY-RUN: queue '${queue}' limits: min_nodes=${min_nodes}, max_nodes=${max_nodes}"
    echo "DRY-RUN: inputs=${num_inputs}, requested_nodes=${requested_nodes}"
    echo "DRY-RUN: would submit the following qsub command:"
    printf '%q ' "${qsub_cmd[@]}"; printf '\n'
    echo "DRY-RUN: paths to review:"
    echo " - PBS job script: ${pbs_script}"
    echo " - RUN_DIR: ${run_dir}"
    echo " - inputs.txt: ${inputs_txt}"
    echo " - cmd.txt: ${cmd_txt}"
    echo " - planned worker script path (created at job start): ${run_dir}/worker.sh"
    echo " - planned logs directory: ${run_dir}/logs"
    echo " - planned status directory: ${run_dir}/status"
    echo " - mpiexec script: ${mpiexec_script}"
    echo "This was a dry run, no job was submitted." > "${run_dir}/DRY_RUN.txt"
    echo "Dry-run complete. No job was submitted."
    exit 0
fi

# Submit job using the same qsub command that was constructed above
qsub_out=$( "${qsub_cmd[@]}" )

if [[ -z "${qsub_out}" ]]; then
    echo "ERROR: qsub did not return a job ID." >&2
    exit 1
fi

job_id="$(echo "${qsub_out}" | awk '{print $1}')"
echo "Submitted job ${job_id}"
echo "Queue '${queue}' limits: min_nodes=${min_nodes}, max_nodes=${max_nodes}"
echo "Requested nodes: ${requested_nodes}"
echo "Logs will be written to: ${run_dir}/logs"
echo "Status files will be in: ${run_dir}/status"
echo "Use 'qstat -f ${job_id}' to monitor; job will start from ${pbs_script}."
