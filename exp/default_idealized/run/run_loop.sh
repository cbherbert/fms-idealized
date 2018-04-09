# -*-mode: shell-script -*-


function do_run {
    # required input:
    local exp_home="$1"
    local run_dir="$2"
    local run_script="$3"

    if [ ! -f "${exp_home}/run/post_processing_info" ]; then
	echo "Error: Run parameter file ${exp_home}/run/post_processing_info does not exist. Exiting"
	exit 1
    fi
    if [ "$run_dir" == "" ]; then
	echo "Error: empty run directory. You probably forgot to pass it to the run_loop script. Exiting"
	exit 1
    fi

    copy_parameters "$run_dir" "$exp_home/run/post_processing_info" "$exp_home/run/run_nml"
    prepare_rundir "$exp_home" "$run_dir"
    main_loop "$run_dir"
    #rm -rf "${run_dir}/workdir"
    resubmit_script "$exp_home" "$ireload" "$num_script_runs" "$run_script"
    date
}


###
#   Prepare the run (input files, etc)
###

function prepare_rundir {
    # Careful: this function has side effects! It sources post_processing_info
    local exp_home="$1"
    local run_dir="$2"
    local workdir="${run_dir}/workdir"         # where model is run and model output is produced; deleted at the end of the script if everything goes well
    local output_dir="${run_dir}/output"       # output directory will be created here
    local run_analysis="${run_dir}/analysis"   # where analysis is run

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

    # Get run parameters
    source "${run_dir}/post_processing_info" # needed for $diagtable, $fieldtable, $namelist and $tmpdir1

    # Copy input files
    # If ocean_mask exists, move it to workdir/INPUT folder O.A. May 2014
    local ocean_mask="ocean_mask_T42.nc" # name of ocean mask file, will only be used if load_mask = .true. in atmosphere_nml
    if [ -e "$exp_home/input/${ocean_mask}" ]; then
	cp "$exp_home/input/${ocean_mask}" "$workdir/INPUT/ocean_mask.nc"
	cp "$exp_home/input/${ocean_mask}" "$output_dir/ocean_mask.nc"
    fi

    cp "$diagtable" "${workdir}/diag_table"
    cp "$fieldtable" "${workdir}/field_table"
    cp "${tmpdir1}/exe.fms/fms.x" "${workdir}/fms.x"

    # combine experience namelists template and local run modifications
    cat "$namelist" >> "${run_dir}/input.nml"

    echo "run_analysis=$run_analysis" >> "${run_dir}/post_processing_info"
    # specify model resolution, which is set in spectral_dynamics_nml section of input/namelists
    echo "$(grep num_fourier $namelist | tr ',' ' ' | tr -d '[:blank:]')" >> "${run_dir}/post_processing_info" # CAREFUL: if num_fourier is overwridden in this script, we will get the wrong value !!!

}

function copy_parameters {
    local run_dir="$1"
    local run_par="$2" # technical run parameters (for the run and analysis scripts)
    local run_nml="$3" # physical run parameters (input namelist passed ot the code)
    mkdir -p "$run_dir"
    cp "$run_par" "${run_dir}/post_processing_info"
    [ -e "$run_nml" ] && cat "$run_nml" > "${run_dir}/input.nml"
}

###
#   The actual model run starts here
###


function main_loop {
    # This function takes run_dir as an argument. It reads run parameters from files copied into run_dir.
    # It has side effects on the global variables ireload and MX_RCACHE, plus the variables sourced from post_processing_info
    # It remains to make a general mechanism to pass the mpirun and qsub commands
    local run_dir="$1"
    local workdir="${run_dir}/workdir"         # where model is run and model output is produced; deleted at the end of the script if everything goes well
    local output_dir="${run_dir}/output"       # output directory will be created here
    local run_analysis="${run_dir}/analysis"   # where analysis is run
    local reload_file="${run_dir}/reload_commands"
    source "${run_dir}/post_processing_info"

    # Define counters for the main loop and set initial conditions
    ireload=1         # counter for resubmitting this run script
    local irun=1      # counter for multiple model submissions within this script
    [ -f "$reload_file" ] && source "$reload_file" # if exists, load reload file (set irun, ireload, init_cond)
    if [ "$init_cond" != "" ]; then
	cd "$workdir/INPUT"
	cp "$init_cond" "$(basename $init_cond)"
	cpio -iv  < "$(basename $init_cond)"
	#  rm -f $init_cond:t
    fi


    #  --- begin loop over $irun ---
    while [ $irun -le $runs_per_script ]; do

	cd "$workdir"

	# set run length and time step, get input namelist for the current run
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
	cat "${run_dir}/input.nml" >> input.nml

	#--------------------------------------------------------------------------------------------------------

	# run the model with mpirun
	MX_RCACHE=2
	mpirun -v -mca btl vader,openib,self -hostfile ${HOSTFILE} -np ${NSLOTS} ${workdir}/fms.x

	#--------------------------------------------------------------------------------------------------------

	#   --- generate date for file names ---

	local date_name="$($time_stamp -eh)" # generates string date for file name labels
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
	local resfiles=(./*.res*)
	#     --- desired filename for cpio of output restart files ---
	local restart_file="${output_dir}/restart/${date_name}.cpio"
	if [ ${#resfiles[@]} -gt 0 ]; then
    	    if [ ! -d "$(dirname $restart_file)" ]; then mkdir -p "$(dirname $restart_file)"; fi
    	    #     --- also save namelist and diag_table ---
    	    cp $workdir/{*.nml,diag_table} .
    	    local files=(${resfiles[@]} input.nml diag_table)
    	    /bin/ls ${files[@]} | cpio -ocv > "$(basename $restart_file)"
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
	local run_number=$((runs_per_script*(ireload-1) + irun))
	echo "Completed run $irun of $runs_per_script in bsub $ireload."
	local irun_prev=$irun
	((irun++))

	# remove restart file (init_cond) that is no longer in {reload_file} or ${reload_file}_prev
	if [ -f "${reload_file}_prev" ]; then
	    local irun_tmp=$irun
	    local ireload_tmp=$ireload
	    local init_cond_tmp=$init_cond
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
            local postproc_dir="${run_analysis}/${date_name}" # directory for this analysis run

            if [ ! -e "$postproc_dir" ]; then
		mkdir -p "${postproc_dir}"
            else
		rm -rf "${postproc_dir}"
		mkdir "${postproc_dir}"
		echo "WARNING: Existing analysis directory ${postproc_dir} removed."
            fi
            cd "${postproc_dir}"
	    cp "${run_dir}/post_processing_info" .
	    echo "date_name=$date_name" >> post_processing_info
	    echo "irun=$irun_prev" >> post_processing_info

            if [ $irun_prev -eq $runs_per_script ]; then
		echo "final=1" >> post_processing_info
	    else
		echo "final=0" >> post_processing_info
	    fi

            cp "$analysis_script" ./

            # ssh to head node and submit analysis script
	    echo "*** Submitting analyis script"
	    ssh psmnsb "bash -l -c 'qsub -wd ${postproc_dir} ${postproc_dir}/$(basename ${analysis_script})'"
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
}


function resubmit_script {
    local exp_home="$1"
    local ireload="$2"
    local num_script_runs="$3"
    local run_script="$4"

    cd "$exp_home/run"
    if [ "$ireload" -gt "$num_script_runs" ]; then
	echo "Note: not resubmitting job."
    else
	echo "Resubmitting run script ($ireload of $num_script_runs)."
	ssh psmnsb "source ~/.profile; qsub $run_script"
    fi
}
