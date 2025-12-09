#!/bin/bash
# Launcher for multi-node nxreduce job submission.
# - Accepts a list of input paths via args, a file, or stdin.
# - Validates inputs.
# - Writes an inputs.txt and cmd.txt into a run directory on a shared filesystem.
# - Submits nxreduce-multinode.sh to PBS with a node count equal to number of inputs.
#
# Optional flags:
#   --force                 Proceed even if only 1 input is provided.
#   --queue Q               PBS queue name (default: debug)
#   --walltime HH:MM:SS     Walltime (default: 01:00:00)
#   --account A             Project/account (default: AXMAS-Reduction)
#   --name NAME             PBS job name (default: nxreduce-multinode)
#   --place P               Placement (default: scatter)
#   --system S              System resource (default: polaris)
#   --filesystems FS        Filesystems resource (default: home:eagle)
#   --runs-dir DIR          Base directory to store run artifacts (default: $PWD/nxreduce_runs)
#   --max-nodes N           Cap the number of nodes to N (fail if inputs > N)
#   --dry-run               Prepare RUN_DIR and print planned commands/paths, but do NOT submit the job.
#
# Note:
#   - Ensure you run this from a directory on a shared filesystem (home/eagle) so the compute nodes can access RUN_DIR.
#   - The command string provided via --cmd should NOT include the final input path; it will be appended by the worker.

set -euo pipefail

cmd=""
inputs_file=""
force="false"
queue="debug"
walltime="01:00:00"
account="AXMAS-Reduction"
name="nxreduce-multinode"
place="scatter"
system="polaris"
filesystems="home:eagle"
runs_dir="${PWD}/nxreduce_runs"
max_nodes=""
dry_run="false"

# TODO: Make this more robust by relying on something other than hard-coded line numbers.
print_usage() {
    sed -n '1,100p' "$0" | sed -n '1,50p' | grep -E '^(#|\s*$)' | sed 's/^#\s*//'
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
        --place)
            shift
            place="${1:-}"
            ;;
        --system)
            shift
            system="${1:-}"
            ;;
        --filesystems)
            shift
            filesystems="${1:-}"
            ;;
        --runs-dir)
            shift
            runs_dir="${1:-}"
            ;;
        --max-nodes)
            shift
            max_nodes="${1:-}"
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

if [[ -z "${cmd}" ]]; then
    # TODO: the `\` seems like a problem (or at least unnecessary). Remove it?
    echo "ERROR: --cmd 'your_command and options (without the input path)\' is required." >&2
    exit 1
fi

# Collect inputs
inputs=()

# From file, if provided
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

# From positional arguments
if [[ "${#args[@]}" -gt 0 ]]; then
    inputs+=("${args[@]}")
fi

# From stdin if none collected yet and stdin has data
if [[ "${#inputs[@]}" -eq 0 && ! -t 0 ]]; then
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
    if command -v readlink > /dev/null 2>&1; then
        abs="$(readlink -f "${p_trim}" || echo "${p_trim}")"
        normalized_inputs+=("${abs}")
    else
        normalized_inputs+=("${p_trim}")
    fi
done

num_inputs="${#normalized_inputs[@]}"

if [[ "${num_inputs}" -lt 1 && "${force}" != "true" ]]; then
    echo "ERROR: At least one input is required (use --force to bypass this check)." >&2
    exit 1
fi

if [[ -n "${max_nodes}" ]]; then
    if [[ "${num_inputs}" -gt "${max_nodes}" ]]; then
        echo "ERROR: Number of inputs (${num_inputs}) exceeds --max-nodes (${max_nodes})." >&2
        exit 1
    fi
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

# Build the qsub command that would be executed
qsub_cmd="qsub -l \"select=${num_inputs}:system=${system}\" -l \"place=${place}\" -l \"filesystems=${filesystems}\" -q \"${queue}\" -l \"walltime=${walltime}\" -A \"${account}\" -N \"${name}\" -v \"RUN_DIR=${run_dir}\" \"${pbs_script}\""

# If dry-run, print planned commands and paths, then exit without submitting
if [[ "${dry_run}" == "true" ]]; then
    echo "DRY-RUN: would submit the following qsub command:"
    echo "${qsub_cmd}"
    echo "DRY-RUN: paths to review:"
    echo " - PBS job script: ${pbs_script}"
    echo " - RUN_DIR: ${run_dir}"
    echo " - inputs.txt: ${inputs_txt}"
    echo " - cmd.txt: ${cmd_txt}"
    echo " - planned worker script path (created at job start): ${run_dir}/worker.sh"
    echo " - planned logs directory: ${run_dir}/logs"
    echo " - planned status directory: ${run_dir}/status"
    echo " - mpiexec script: ${mpiexec_script}"
    echo "Dry-run complete. No job was submitted."
    exit 0
fi

# Submit job; override select to match number of inputs; other resources can be overridden via flags
# TODO: Seems like a lot of this is redundant with the PBS directives in the script
qsub_out=$(qsub \
    -l "select=${num_inputs}:system=${system}" \
    -l "place=${place}" \
    -l "filesystems=${filesystems}" \
    -q "${queue}" \
    -l "walltime=${walltime}" \
    -A "${account}" \
    -N "${name}" \
    -v "RUN_DIR=${run_dir}" \
    "${pbs_script}")

if [[ -z "${qsub_out}" ]]; then
    echo "ERROR: qsub did not return a job ID." >&2
    exit 1
fi

job_id="$(echo "${qsub_out}" | awk '{print $1}')"
echo "Submitted job ${job_id}"
echo "Logs will be written to: ${run_dir}/logs"
echo "Status files will be in: ${run_dir}/status"
echo "Use 'qstat -f ${job_id}' to monitor; job will start from ${pbs_script}."
