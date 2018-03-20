#!/bin/bash
### SGE variables:
## job shell:
#$ -S /bin/bash
## job name:
#$ -N fms_test
## queue:
#$ -q x5570deb24B
## parallel environment & cpu nb:
#$ -pe mpi8_debian 16
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
time_stamp="$fms_home/bin/time_stamp.csh"                         # generates string date for file name labels


# Output dirs:
# Set up work directory on scratch space (MACHINE-DEPENDENT)
scratchdir="$(dirname $fms_home)"               # Fall-back: use the base fms-idealized directory
data_dir="${scratchdir}/fms_output/${exp_name}/${run_name}"
tmpdir1="${scratchdir}/fms_tmp/${exp_name}"
run_dir="$tmpdir1/$run_name"                   # tmp directory for current run
workdir="$run_dir/workdir"                     # where model is run and model output is produced; deleted at the end of the script if everything goes well
output_dir="$run_dir/output"                   # output directory will be created here
execdir="$tmpdir1/exe.fms"                     # where code is compiled and executable is created
run_analysis="$run_dir/analysis"               # where analysis is run

# zonally averaged analysis
analysis_script="run_analysis_${model_type}_${analysis_type}_${machine}.sh"
analysis_dir="$(dirname $fms_home)/analysis/analysis_${analysis_type}/run"  # location of analysis directory

#--------------------------------------------------------------------------------------------------------
#limit stacksize unlimited
#--------------------------------------------------------------------------------------------------------

###
#   Compile the model code
###

# compile mppnccombine.c, needed only if $npes > 1
# mppnccombine compiles with all the gcc version in module files (4.9.4, 5.4.0, 6.4.0, 7.2.0) or with icc 17.0.4 but not with the default Debian gcc (6.3.0-18)
$fms_home/bin/compile_mppnccombine "$fms_home" "$tmpdir1/mppnccombine"

$fms_home/bin/compile_fms "$exp_home" "$execdir"

###
#   Prepare the run (input files, etc)
###

# Define initial condition and counters for the main loop
init_cond=""
ireload=1         # counter for resubmitting this run script
irun=1            # counter for multiple model submissions within this script
# if exists, load reload file
reload_file="${run_dir}/reload_commands"
[ -f "$reload_file" ] && source "$reload_file" # set irun, ireload, init_cond


# Create directory structure
mkdir -p "$run_analysis"
mkdir -p "$output_dir"/{combine,logfiles,restart}
if [ ! -e "$workdir" ]; then
    mkdir -p "$workdir"/{INPUT,RESTART} && echo "Directory $workdir created with subdirectories INPUT and RESTART."
else
    rm -rf "$workdir"
    mkdir -p "$workdir"/{INPUT,RESTART}
    echo "WARNING: Existing workdir $workdir removed and replaced with empty one, with subdirectories INPUT and RESTART."
fi

cd "$workdir/INPUT"

# Set initial conditions
if [ "$init_cond" != "" ]; then
  cp "$init_cond" "$(basename $init_cond)"
  cpio -iv  < "$(basename $init_cond)"
#  rm -f $init_cond:t
fi

# If ocean_mask exists, move it to workdir/INPUT folder O.A. May 2014
ocean_mask="ocean_mask_T42.nc" # name of ocean mask file, will only be used if load_mask = .true. in atmosphere_nml
if [ -e "$exp_home/input/${ocean_mask}" ]; then
   cp "$exp_home/input/${ocean_mask}" "ocean_mask.nc"
   cd "$output_dir"
   cp "$exp_home/input/${ocean_mask}" "ocean_mask.nc"
fi

###
#   The actual model run starts here
###


#  --- begin loop over $irun ---
while [ $irun -le $runs_per_script ]; do

    cd "$workdir"

    # set run length and time step, get input data and executable
    if [ $ireload -eq 1 ] && [ $irun -eq 1 ]; then
      cat > input.nml <<EOF
	&main_nml
         current_time = 0,
         override = .true.,
         days   = $days,
         dt_atmos = 300 /
EOF
    else
      cat > input.nml <<EOF
	&main_nml
         days   = $days,
         dt_atmos = 300 /
EOF
    fi

    [ -e "$exp_home/run/run_nml" ] && cat "$exp_home/run/run_nml" >> input.nml
    cat "$namelist" >> input.nml
    cp "$diagtable" diag_table
    cp "$fieldtable" field_table
    cp "$execdir/fms.x" fms.x
    cp input.nml "$run_dir"

    #--------------------------------------------------------------------------------------------------------

    # run the model with mpirun
    MX_RCACHE=2
    mpirun -v -mca btl vader,openib,self -hostfile ${HOSTFILE} -np ${NSLOTS} ${workdir}/fms.x

    #--------------------------------------------------------------------------------------------------------

    #   --- generate date for file names ---

    date_name="$($time_stamp -eh)"
    if [ "$date_name" == "" ]; then date_name="tmp$(date '+%j%H%M%S')"; fi
    if [ -f "time_stamp.out" ]; then rm -f "time_stamp.out"; fi

    #--------------------------------------------------------------------------------------------------------

    #   --- move output files to their own directories (don't combine) ---

    mkdir "$output_dir/combine/$date_name"

    for ncfile in *.nc*; do
	mv "$ncfile" "$output_dir/combine/$date_name/$date_name.$ncfile"
    done

    #   --- save ascii output files to local disk ---

    for out in *.out; do
	mv "$out" "$output_dir/logfiles/$date_name.$out"
    done

    #   --- move restart files to output directory ---

    cd "$workdir/RESTART"
    resfiles=(./*.res*)
    #     --- desired filename for cpio of output restart files ---
    restart_file="${output_dir}/restart/${date_name}.cpio"
    if [ ${#resfiles[@]} -gt 0 ]; then
    	if [ ! -d "$(dirname $restart_file)" ]; then mkdir -p "$(dirname $restart_file)"; fi
    	#     --- also save namelist and diag_table ---
    	cp $workdir/{*.nml,diag_table} .
    	files=($resfiles input.nml diag_table)
    	/bin/ls $files | cpio -ocv > "$(basename $restart_file)"
    	mv "$(basename $restart_file)" "$restart_file"
    	#     --- set up restart for next run ---
    	if [ $irun -lt $runs_per_script ]; then
    	    mv -f *.res* ../INPUT
    	fi
    fi

    cd "$workdir"

    #--------------------------------------------------------------------------------------------------------

    #   --- write new reload information ---
    # for comparison with $start_analysis,  run_number = (ireload-1)*runs_per_script + irun
    run_number=$((runs_per_script*(ireload-1) + irun))
    echo "Completed run $irun of $runs_per_script in bsub $ireload."
    irun_prev=$irun
    ((irun++))

    # remove restart file (init_cond) that is no longer in {reload_file} or ${reload_file}_prev
    if [ -f "${reload_file}_prev" ]; then
       irun_tmp=$irun
       ireload_tmp=$ireload
       init_cond_tmp=$init_cond
       source "${reload_file}_prev"
       rm -r "$init_cond"
       irun=$irun_tmp
       ireload=$ireload_tmp
       init_cond=$init_cond_tmp
    fi
    if [ -f "$reload_file" ]; then mv -f "$reload_file" "${reload_file}_prev"; fi

    if [ $irun -le $runs_per_script ]; then
	echo "irun=$irun"          >  "$reload_file"
    else
	((ireload++))
	echo "irun=1"              >  "$reload_file"
    fi

    echo     "init_cond=$restart_file"  >> "$reload_file"
    echo     "ireload=$ireload"       >> "$reload_file"

#     ############################# post processing ############################

    cd "$run_analysis"
    if [ $run_number -ge $start_analysis ]; then # combine data and do analysis

        # need to be careful not to write on top of file for analysis job currently pending in queue.
        # put each job in separate directory.
        postproc_dir="${run_analysis}/${date_name}" # directory for this analysis run

        if [ ! -e "$postproc_dir" ]; then
          mkdir -p "${postproc_dir}"
        else
          rm -rf "${postproc_dir}"
          mkdir "${postproc_dir}"
          echo "WARNING: Existing analysis directory ${postproc_dir} removed."
        fi
        cd "${postproc_dir}"

	echo "exp_name=$exp_name" > post_processing_info
	echo "data_dir=$data_dir" >> post_processing_info
	echo "run_name=$run_name" >> post_processing_info
	echo "run_script=$run_script" >> post_processing_info
	echo "date_name=$date_name" >> post_processing_info
	echo "run_analysis=$run_analysis" >> post_processing_info
	echo "fms_home=$fms_home" >> post_processing_info
	echo "tmpdir1=$tmpdir1" >> post_processing_info
        # specify model resolution, which is set in spectral_dynamics_nml section of input/namelists
        echo "$(grep num_fourier $namelist | tr ',' ' ' | tr -d '[:blank:]')" >> post_processing_info # CAREFUL: if num_fourier is overwridden in this script, we will get the wrong value !!!
	echo "irun=$irun_prev" >> post_processing_info
	echo "runs_per_script=$runs_per_script" >> post_processing_info
        # information for segmentation of analysis
        echo "days_per_segment=$days_per_segment" >> post_processing_info
	echo "num_segments=$num_segments" >> post_processing_info
	echo "isegment=1" >> post_processing_info

        if [ $irun_prev -eq $runs_per_script ]; then
	   echo "final=1" >> post_processing_info
	else
	   echo "final=0" >> post_processing_info
	fi

        cp "$analysis_dir/$analysis_script" ./

        # ssh to head node and submit analysis script
	echo "*** Submitting analyis script"
	ssh psmnsb "bash -l -c 'qsub -wd ${postproc_dir} ${postproc_dir}/${analysis_script}'"
    else
	rm -rf "${output_dir}/combine/${date_name}"
    fi

    # don't resubmit if model failed to build a restart file
    if [ ! -f "$restart_file" ]; then
      echo "FATAL ERROR: model restart file not saved. Try moving ${reload_file}_prev to ${reload_file} and re-running."
      echo "ireload = $ireload, irun = $irun"
      irun=$((runs_per_script + 1))
      ireload=$((num_script_runs + 1))
    fi

done # --- loop over $irun ended ---

#rm -rf "$workdir"

cd "$exp_home/run"

if [ $ireload -gt $num_script_runs ]; then
  echo "Note: not resubmitting job."
else
  echo "Submitting run $ireload."
  ssh psmnsb "source ~/.profile; qsub $run_script"
fi

date
