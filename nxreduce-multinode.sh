#!/bin/bash -l
#PBS -l select=1:system=polaris
#PBS -l place=scatter
#PBS -l walltime=01:00:00
#PBS -q debug
#PBS -l filesystems=home:eagle
#PBS -A AXMAS-Reduction
#PBS -N nxrefine-manual-submission
#PBS -j oe

# TODO: Modify for multi-node jobs:
# - Probably write a separate script (bash or python) to provide the user interface:
#   - Run this script with a list of files (either on the command line, in a file, or stdin)
#   - Modify qsub request depending on the number of input files
#   - Do some input-sanity-checking:
#       - Input files should exist.
#       - If list is less than 10 lines long, input a warning and quit unless `--force`.
# - The qsub script will run on the head node only. Use it to distribute work to the other nodes.
#   - mpiexec/pbsdsh/ssh should all work.
#   - Probably most elegant to just have the head node do the mapping to match file names to nodes, rather than having each node read the file list.
#   - 

echo "Running job $PBS_JOBNAME (ID: $PBS_JOBID) by user $USER in $PBS_QUEUE queue, starting $(date '+%Y/%m/%d %H:%M:%S %Z')"

source /eagle/AXMAS-Reduction/sw/bin/nxsetup.sh
# TODO: Replace with actual nxreduce <NXSERVER>

echo "Finished job $PBS_JOBID at $(date '+%Y/%m/%d %H:%M:%S %Z')"
