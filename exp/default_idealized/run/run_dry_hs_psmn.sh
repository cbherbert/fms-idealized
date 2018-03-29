#!/bin/bash
### SGE variables:
## job shell:
#$ -S /bin/bash
## job name:
#$ -N fms_test
## queue:
#$ -q x5570deb24A
## parallel environment & cpu nb:
#$ -pe mpi8_debian 8
## SGE user environment:
#$ -cwd
## Error/output files:
#$ -o $JOB_NAME-$JOB_ID.out
#$ -e $JOB_NAME-$JOB_ID.err
## Export environment variables:
#$ -V

# === Default test run script for idealized GCM ===

# See description at run_test.readme

# Ian Eisenman, Yohai Kaspi, Tim Merlis, November 2010
# Farid Ait Chaalal, Xavier Levine, Zhihong Tan, March 2012
# Farid Ait Chaalal, September 2012
# Robb Wills, Zhihong Tan, August 2013
# Robb Wills, Ori Adam, May 2014
# Corentin Herbert, May 2016

HOSTFILE="${TMPDIR}/machines"
# change the working directory (default is home directory)
cd ${SGE_O_WORKDIR}
echo "Working directory is $PWD"


source /usr/share/lmod/lmod/init/bash
module load IntelComp/2017.4/OpenMPI/3.0.0
module list


###
#   Choose machine, model, analysis and integration parameters (USER-MODIFIABLE)
###

model_type="dry"     # if "moist", the moist model is run and if "dry, it is the dry. "moist_hydro" is for the bucket hydrology model. The namelists for the parameters are below (L212).
machine="psmn"       # machine = euler or brutus, use the alternate runscripts for fram, or change mkmf templates, submission commands, and modules for other machines
analysis_type="2d"   # choose type of analysis: 2d (zonally averaged) or 3d (zonally varying) outputs
run_name="test_hs_${model_type}_${analysis_type}"  # label for run; output dir and working dir are run_name specific
run_script="$PWD/run_dry_hs_psmn.sh"                      # path/name of this run script (for resubmit)
echo "*** Running ${run_script} on $(hostname) ***"
date

days=10                                 # length of integration
runs_per_script=2                      # number of runs within this script
start_analysis=1                       # number of script run at which to start analysis (after spin-up)
num_script_runs=1                       # how many times to resubmit script to queue
days_per_segment=${days}                # days per segment of analysis (for seasonally-varying analysis)
num_segments=$((days/days_per_segment)) # number of analysis segments
echo "num_segments = $num_segments"

###
#   Information about MPI and CPUS; load machine-specific environment
###

echo "MPI Used:" $(which mpirun)

#set NPROCS=`echo $LSB_HOSTS| wc -w` # this only works with Intel Platform LSF
echo "This job has allocated $NSLOTS cpus" # NSLOTS is defined by SGE

#--------------------------------------------------------------------------------------------------------

###
#   Setting up the directory hierarchy
###

# Input dirs:
exp_home="$(dirname "$PWD")"                                      # directory containing run/$run_script and input/
exp_name="$(basename "$exp_home")"                                # name of experiment (i.e., name of this model build)
fms_home="$(dirname "$(dirname $exp_home)")/idealized"            # directory containing model source code, etc, usually /home/$USER/fms/idealized
namelist="$exp_home/input/namelists_${model_type}"                # path to namelist file
fieldtable="$exp_home/input/field_table_${model_type}"            # path to field table (specifies tracers)
diagtable="$exp_home/input/diag_table_${model_type}_${analysis_type}"       # path to diagnostics table
analysis_script="$(dirname $fms_home)/analysis/analysis_${analysis_type}/run/run_analysis_${model_type}_${analysis_type}_${machine}.sh"  # location of analysis script

# Output dirs:
scratchdir="$(dirname $fms_home)"               # Fall-back: use the base fms-idealized directory

#--------------------------------------------------------------------------------------------------------
#limit stacksize unlimited
#--------------------------------------------------------------------------------------------------------

###
#   Compile the model code
###

# compile mppnccombine.c, needed only if $npes > 1
# mppnccombine compiles with all the gcc version in module files (4.9.4, 5.4.0, 6.4.0, 7.2.0) or with icc 17.0.4 but not with the default Debian gcc (6.3.0-18)
$fms_home/bin/compile_mppnccombine "$fms_home" "${scratchdir}/fms_tmp/${exp_name}/mppnccombine"
$fms_home/bin/compile_fms "$exp_home" "${scratchdir}/fms_tmp/${exp_name}/exe.fms"

###
#   Prepare input files
###

echo "exp_name=$exp_name" > post_processing_info
echo "run_name=$run_name" >> post_processing_info
echo "run_script=$run_script" >> post_processing_info
echo "namelist=$namelist" >> post_processing_info
echo "diagtable=$diagtable" >> post_processing_info
echo "fieldtable=$fieldtable" >> post_processing_info
echo "runs_per_script=$runs_per_script" >> post_processing_info
echo "num_script_runs=$num_script_runs" >> post_processing_info
echo "days=$days" >> post_processing_info
echo "init_cond=" >> post_processing_info
echo "time_stamp=$fms_home/bin/time_stamp.csh" >> post_processing_info
echo "tmpdir1=${scratchdir}/fms_tmp/${exp_name}" >> post_processing_info
echo "fms_home=$fms_home" >> post_processing_info
echo "data_dir=${scratchdir}/fms_output/${exp_name}/${run_name}" >> post_processing_info
echo "start_analysis=$start_analysis" >> post_processing_info
echo "analysis_script=$analysis_script" >> post_processing_info
# information for segmentation of analysis
echo "days_per_segment=$days_per_segment" >> post_processing_info
echo "num_segments=$num_segments" >> post_processing_info
echo "isegment=1" >> post_processing_info




###
#   Run the model
###

source run_loop.sh
do_run "$exp_home" "${scratchdir}/fms_tmp/${exp_name}/${run_name}" "${run_script}"
