#!/bin/bash -l
#PBS -l select=1:system=polaris
#PBS -l place=scatter
#PBS -l walltime=01:00:00
#PBS -q debug
#PBS -l filesystems=home:eagle
#PBS -A AXMAS-Reduction
#PBS -N nxreduce-multinode
#PBS -j oe

set -euo pipefail

echo "Running job $PBS_JOBNAME (ID: $PBS_JOBID) by user $USER in $PBS_QUEUE queue, starting $(date '+%Y/%m/%d %H:%M:%S %Z')"

# cd to the submission directory if set. Helps avoid errors if relative paths
# slip through the input processing.
if [[ -n "${PBS_O_WORKDIR:-}" ]]; then
    cd "${PBS_O_WORKDIR}"
fi

# The launcher must pass RUN_DIR (shared filesystem path) via qsub -v RUN_DIR=<path>
if [[ -z "${RUN_DIR:-}" ]]; then
  echo "ERROR: RUN_DIR is not set. Submit this script via nxreduce-launch.sh which will prepare RUN_DIR and pass it to qsub."
  exit 1
fi

INPUTS_FILE="${RUN_DIR}/inputs.txt"
CMD_FILE="${RUN_DIR}/cmd.txt"
LOGDIR="${RUN_DIR}/logs"
STATUSDIR="${RUN_DIR}/status"

mkdir -p "${LOGDIR}" "${STATUSDIR}"

if [[ ! -f "${INPUTS_FILE}" ]]; then
  echo "ERROR: inputs file not found at ${INPUTS_FILE}"
  exit 1
fi

if [[ ! -f "${CMD_FILE}" ]]; then
  echo "ERROR: command file not found at ${CMD_FILE}"
  exit 1
fi

# Source environment on the head node (each worker will also source this)
source /eagle/AXMAS-Reduction/sw/bin/nxsetup.sh

NUM_TASKS=$(wc -l < "${INPUTS_FILE}")
if [[ "${NUM_TASKS}" -le 0 ]]; then
  echo "ERROR: No inputs found in ${INPUTS_FILE}"
  exit 1
fi

# Create a per-rank worker script that will run on each node
WORKER="${RUN_DIR}/worker.sh"
cat > "${WORKER}" <<'EOF'
#!/bin/bash -l
set -euo pipefail

rank=${PMI_RANK:-${OMPI_COMM_WORLD_RANK:-${MV2_COMM_WORLD_RANK:-0}}}

INPUTS_FILE="$1"
CMD_FILE="$2"
LOGDIR="$3"
STATUSDIR="$4"

# Select the input for this rank (one-based line number)
input=$(sed -n "$((rank+1))p" "$INPUTS_FILE" || true)
if [[ -z "${input}" ]]; then
  echo "Rank ${rank}: No input assigned (empty line or out of range)"
  exit 1
fi

# Ensure input exists
if [[ ! -d "${input}" && ! -f "${input}" ]]; then
  echo "Rank ${rank}: Input path does not exist: ${input}"
  exit 2
fi

# Environment setup for each rank
source /eagle/AXMAS-Reduction/sw/bin/nxsetup.sh

# Read the base command (first line of CMD_FILE)
CMD=$(head -n 1 "${CMD_FILE}")

# Prepare log file names
base_name="$(basename "${input}")"
out_file="${LOGDIR}/${rank}-${base_name}.out"
err_file="${LOGDIR}/${rank}-${base_name}.err"

echo "Rank ${rank}: Starting command on input: ${input}" | tee -a "${out_file}"

# Execute the command, appending the input path as the final argument.
# Use bash -lc to honor any shell expansions contained in CMD.
# Note: quoting ensures the input path is treated as a single argument.
bash -lc "${CMD} \"${input}\"" >>"${out_file}" 2>>"${err_file}"
status=$?

echo "Rank ${rank}: Finished with exit code ${status}" | tee -a "${out_file}"
echo "${status}" > "${STATUSDIR}/rank-${rank}.exitcode"

exit "${status}"
EOF

chmod +x "${WORKER}"

# Use a single source of truth for the mpiexec command if available
MPIEXEC_SCRIPT="${RUN_DIR}/mpiexec.sh"
if [[ -x "${MPIEXEC_SCRIPT}" ]]; then
  echo "Dispatching tasks via mpiexec script: ${MPIEXEC_SCRIPT}"
  "${MPIEXEC_SCRIPT}"
else
  echo "mpiexec script not found at ${MPIEXEC_SCRIPT}; constructing inline mpiexec command..."
  echo "Dispatching ${NUM_TASKS} tasks (one per node) via mpiexec..."
  mpiexec -n "${NUM_TASKS}" -ppn 1 "${WORKER}" "${INPUTS_FILE}" "${CMD_FILE}" "${LOGDIR}" "${STATUSDIR}"
fi

# Summarize results
echo "Aggregating task statuses..."
fail_count=0
success_count=0
for f in "${STATUSDIR}"/rank-*.exitcode; do
  [[ -e "$f" ]] || continue
  code=$(cat "$f" || echo 1)
  if [[ "$code" == "0" ]]; then
    success_count=$((success_count+1))
  else
    fail_count=$((fail_count+1))
  fi
done

echo "Summary: ${success_count} succeeded, ${fail_count} failed (of ${NUM_TASKS} requested)."
echo "Logs: ${LOGDIR}"
echo "Status files: ${STATUSDIR}"

echo "Finished job $PBS_JOBID at $(date '+%Y/%m/%d %H:%M:%S %Z')"
