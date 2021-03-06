#!/bin/csh -f
### SGE variables:
## job shell:
#$ -S /bin/csh
## job name:
#$ -N fms_super_dh00_g1_q01_2d
## queue:
#$ -q E5-2667v2h6deb128
## parallel environment & cpu nb:
#$ -pe mpi16_debian 16
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

set HOSTFILE = "${TMPDIR}/machines"
# change the working directory (default is home directory)
cd ${SGE_O_WORKDIR}
echo "Working directory is $cwd"

###
#   Choose machine, model, analysis and integration parameters (USER-MODIFIABLE)
###

set model_type     = dry                          # if "moist", the moist model is run and if "dry, it is the dry. "moist_hydro" is for the bucket hydrology model. The namelists for the parameters are below (L212).
set machine        = psmn                          # machine = euler or brutus, use the alternate runscripts for fram, or change mkmf templates, submission commands, and modules for other machines
set platform       = ifc                           # a unique identifier for your platform
set analysis_type  = 2d                             # choose type of analysis: 2d (zonally averaged) or 3d (zonally varying) outputs
set run_name       = "superrot_${model_type}_dh00_g1_q01_${analysis_type}"          # label for run; output dir and working dir are run_name specific
set run_script     = "$cwd/run_atf0_psmn.csh"                  # path/name of this run script (for resubmit)
#set echo
echo "*** Running ${run_script} on `hostname` ***"
date

set days            = 90                             # length of integration
set runs_per_script = 20                              # number of runs within this script
set start_analysis  = 13                              # number of script run at which to start analysis (after spin-up)
set num_script_runs = 1                              # how many times to resubmit script to queue
set days_per_segment = ${days}                       # days per segment of analysis (for seasonally-varying analysis)

@ num_segments       = ${days} / ${days_per_segment} # number of analysis segments
echo "num_segments    = $num_segments"

###
#   Information about MPI and CPUS; load machine-specific environment
###

# Tell me which nodes it is run on; for sending messages to help-hpc
#echo " "
#echo This jobs runs on the following processors:
#echo $LSB_HOSTS
#echo " "

#source /etc/profile.d/modules.sh
if (${machine} == euler) then
    module load new
    module load intel/14.0.1
    module load open_mpi/1.6.5
    module list
else if (${machine} == brutus) then
    module load intel/12.1.2
    module load open_mpi/1.4.5
    module list
else if (${machine} == psmn) then
    source /usr/share/lmod/lmod/init/tcsh
    module load IntelComp/2017.4/OpenMPI/3.0.0
    module list
endif

echo "MPI Used:" `which mpirun`

#set NPROCS=`echo $LSB_HOSTS| wc -w` # this only works with Intel Platform LSF
echo "This job has allocated $NSLOTS cpus" # NSLOTS is defined by SGE

#--------------------------------------------------------------------------------------------------------

###
#   Setting up the directory hierarchy
###

# Input dirs:
set exp_home    = "$cwd:h"                                               # directory containing run/$run_script and input/
set exp_name    = "$exp_home:t"                                          # name of experiment (i.e., name of this model build)
set fms_home    = "$cwd:h:h:h/idealized"                                 # directory containing model source code, etc, usually /home/$USER/fms/idealized
set pathnames   = $exp_home/input/path_names                             # path to file containing list of source paths
set namelist    = $exp_home/input/namelists_${model_type}                # path to namelist file
set fieldtable  = $exp_home/input/field_table_${model_type}              # path to field table (specifies tracers)
set template    = $fms_home/bin/mkmf_template                            # path to template for your platform
set mkmf        = $fms_home/bin/mkmf                                     # path to executable mkmf
set sourcedir   = $fms_home/src                                          # path to directory containing model source code
set time_stamp  = $fms_home/bin/time_stamp.csh                           # generates string date for file name labels


# Output dirs:
# Set up work directory on scratch space (MACHINE-DEPENDENT)
if (${machine} == euler) then
   set scratchdir    = "/cluster/work/beta2/clidyn/"        # (EULER) please change clidyn to a folder name of your choice (beta1-4 available)
else if (${machine} == brutus) then
   set scratchdir    = "/cluster/scratch_xp/public/clidyn/" # (BRUTUS) please change clidyn to a folder name of your choice
else
   set scratchdir    = "$fms_home:h"                        # Fall-back: use the base fms-idealized directory
endif
set data_dir         = ${scratchdir}/fms_output/${exp_name}/${run_name}
set tmpdir1          = ${scratchdir}/fms_tmp/${exp_name}
set run_dir          = $tmpdir1/$run_name                   # tmp directory for current run
set workdir          = $run_dir/workdir                     # where model is run and model output is produced; deleted at the end of the script if everything goes well
set output_dir       = $run_dir/output                      # output directory will be created here
set execdir          = $tmpdir1/exe.fms                     # where code is compiled and executable is created
set mppnccombine     = $tmpdir1/mppnccombine.$platform      # path to executable mppnccombine
set run_analysis     = $run_dir/analysis                    # where analysis is run
set analysis_out_err = $run_analysis/out_err                # out and err for analysis (I THINK THIS DIRECTORY IS NEVER USED!!!)

# zonally averaged analysis
set analysis_version = analysis_${analysis_type}
set analysis_script = run_analysis_${model_type}_${analysis_type}_${machine}.csh
set diagtable   = $exp_home/input/diag_table_${model_type}_${analysis_type}     # path to diagnostics table
set analysis_dir = ${fms_home:h}/analysis/$analysis_version/run                 # location of analysis directory

#--------------------------------------------------------------------------------------------------------

limit stacksize unlimited

cd $exp_home

# note the following init_cond's are overwritten later if reload_commands exists
set init_cond   = ""

set ireload     = 1                                  # counter for resubmitting this run script
set irun        = 1                                  # counter for multiple model submissions within this script
#--------------------------------------------------------------------------------------------------------

###
#   Preparing the run (compile code, etc)
###

# if exists, load reload file
set reload_file = ${run_dir}/reload_commands
if ( -d $run_dir )  then
  if ( -f $reload_file ) then
     # set irun, ireload, init_cond
     source $reload_file
  endif
endif

# otherwise, prepare for a new run

# creating directory structure
mkdir -p $execdir $run_analysis $analysis_out_err
mkdir -p $output_dir/{combine,logfiles,restart}
if ( ! -e $workdir ) then
    mkdir -p $workdir/{INPUT,RESTART} && echo "Directory $workdir created with subdirectories INPUT and RESTART."
else
    rm -rf $workdir
    mkdir -p $workdir/{INPUT,RESTART}
    echo "WARNING: Existing workdir $workdir removed and replaced with empty one, with subdirectories INPUT and RESTART."
endif


# compile mppnccombine.c, needed only if $npes > 1
if ( ! -f $mppnccombine ) then
  gcc -O -o $mppnccombine -I$fms_home/bin/nc_inc -L$fms_home/bin/nc_lib $fms_home/postprocessing/mppnccombine.c -lnetcdf
endif


# compile the model code and create executable

# append fms_home (containing netcdf libraries and include files) to template
/bin/cp $template $workdir/tmp_template
echo "fms_home = $fms_home" >> $workdir/tmp_template

# Prepend fortran files in srcmods directory to pathnames.
# Use 'find' to make list of srcmod/*.f90 files. mkmf uses only the first instance of any file name.
cd $sourcedir
find $exp_home/srcmods/ -maxdepth 1 -iname "*.f90" -o -iname "*.inc" -o -iname "*.c" -o -iname "*.h" > $workdir/tmp_pathnames
echo "Using the following sourcecode modifications:"
cat $workdir/tmp_pathnames
cat $pathnames >> $workdir/tmp_pathnames

cd $execdir
$mkmf -p fms.x -t $workdir/tmp_template -c "-Duse_libMPI -Duse_netCDF" -a $sourcedir $workdir/tmp_pathnames $sourcedir/shared/include $sourcedir/shared/mpp/include
make -f Makefile

cd $workdir/INPUT

#--------------------------------------------------------------------------------------------------------

# set initial conditions and move to executable directory

if ( $init_cond != "" ) then
  cp $init_cond $init_cond:t
  cpio -iv  < $init_cond:t
#  rm -f $init_cond:t
endif

# if ocean_mask exists, move it to workdir/INPUT folder O.A. May 2014
set ocean_mask = ocean_mask_T42.nc # name of ocean mask file, will only be used if load_mask = .true. in atmosphere_nml
if (-e $exp_home/input/${ocean_mask}) then
   cp $exp_home/input/${ocean_mask} ocean_mask.nc
   cd $output_dir
   cp $exp_home/input/${ocean_mask} ocean_mask.nc
endif

#--------------------------------------------------------------------------------------------------------

###
#   The actual model run starts here
###


#  --- begin loop over $irun ---
while ($irun <= $runs_per_script)

    cd $workdir

    # set run length and time step, get input data and executable
    if ( $ireload == 1 && $irun == 1 ) then
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
    endif

    if (${model_type} == dry) then
    cat >> input.nml <<EOF

      &atmosphere_nml
	two_stream           = .false.,
	turb                 = .true., ! enable vertical diffusion
	ldry_convection      = .true.,
	dry_model            = .true.,
	lwet_convection      = .false.,
	mixed_layer_bc       = .false.,
	do_virtual           = .false.,
	tapio_forcing        = .false.,
	hs                   = .true.,
	atmos_water_correction = .false.,
	roughness_mom        = 0.05,
	roughness_heat       = 0.05,
	roughness_moist      = 0.05,
	bucket               = .false./

EOF
    else if (${model_type} == moist) then

    cat >> input.nml <<EOF

      &atmosphere_nml
	two_stream           = .true.,
	turb                 = .true.,
	ldry_convection      = .false.,
        dry_model            = .false.,
	lwet_convection      = .true.,
	mixed_layer_bc       = .true.,
	do_virtual           = .true.,
	tapio_forcing        = .false.,
	hs                   = .false.,
	atmos_water_correction = .false.,
	roughness_mom        = 5e-03,
	roughness_heat       = 1e-05,
	roughness_moist      = 1e-05,
	bucket               = .false./

EOF

    else if (${model_type} == moist_hydro) then

    cat >> input.nml <<EOF

      &atmosphere_nml
	two_stream           = .true.,
	turb                 = .true.,
	ldry_convection      = .false.,
        dry_model            = .false.,
	lwet_convection      = .true.,
	mixed_layer_bc       = .true.,
	do_virtual           = .true.,
	tapio_forcing        = .false.,
	hs                   = .false.,
	atmos_water_correction = .false.,
	roughness_mom        = 5e-03,
	roughness_heat       = 1e-05,
	roughness_moist      = 1e-05,
	bucket               = .true.,
        load_mask            = .true.,
        init_bucket_depth    = 1000.,
        init_bucket_depth_land = 1.,
        land_left            = 0.,
        land_right           = 360.,
        land_bottom          = 10.,
        land_top             = 30.,
        max_bucket_depth_land= 2.,
        robert_bucket        = 0.04,
        raw_bucket           = 0.53,
        damping_coeff_bucket = 200/

EOF
   endif

    cat >> input.nml <<EOF

      &hs_forcing_nml
        delh                 = 0.0/

      &atf_forcing_nml
	q0atf                = 0.1/

      &grid_phys_list
	tsfc_sp                  = 260.0,
	delh                     = 90.,
	ka_days                  = 50.0,
	ks_days                  = 7.0,
	Cdrag                    = 0.0e-5,
	t_strat                  = 200.0,
	sigma_b                  = 0.85,
	scale_height_ratio       = 3.5,
	reference_sea_level_press = 100000.,
	phi0                     = 0.0/

      &dry_convection_nml
	gamma                    = 1.0,
	tau                      = 14400.0/

      &spectral_init_cond_nml
	initial_temperature  = 280.0 /

      &diag_manager_nml
        mix_snapshot_average_fields = .true. /

      &radiation_nml
        albedo_value                 = 0.38,
        lw_linear_frac               = 0.2,
        perpetual_equinox            =.true.,
        annual_mean                  =.false.,
        fixed_day                    =.false.,
        fixed_day_value              = 90.0,
        solar_constant               = 1360,
        lw_tau_exponent              = 4.0,
        sw_tau_exponent              = 2.0,
        odp                          = 1.0,
        lw_tau0_pole                 = 1.8,
        lw_tau0_eqtr                 = 7.2,
        del_sol                      = 1.2,
        atm_abs                      = 0.22,
        days_in_year                 = 360,
        orb_long_perh                = 0,
        orb_ecc                      = 0.0,
        orb_obl                      = 23.5 /


      &mixed_layer_nml
        depth              = 40.0,
        qflux_amp          = 0.0,
        qflux_width        = 16.0,
        ekman_layer        = .false.,
        load_qflux         = .false.,
        evaporation        = .true.,
	depth_land         = 1.0/


      &qe_moist_convection_nml
        tau_bm               = 7200.0,
        rhbm                 = 0.7,
        val_inc              = 0.01,
        Tmin                 = 50.,
        Tmax                 = 450. /

      &lscale_cond_nml
	do_evap              = .false./

      # requires topography_option = 'gaussian' in spectral_dynamics_nml
      &gaussian_topog_nml
        height		   = 0.0,
        olon		   = 90.0,
        olat		   = 35.0,
	rlon               = 0.0,
	rlat               = 2.5,
        wlon		   = 4.95,
        wlat   		   = 4.95 /

      &spectral_dynamics_nml
	damping_option          = 'resolution_dependent',
	damping_order           = 4,
	damping_coeff           = 6.9444444e-05,
	cutoff_wn               = 15,
	do_mass_correction      =.true.,
	do_energy_correction    =.true.,
	do_water_correction     =.true.,
	do_spec_tracer_filter   =.false.,
	use_virtual_temperature =.true.,
	vert_advect_uv          = 'second_centered',
	vert_advect_t           = 'second_centered',
	longitude_origin        = 0.,
	robert_coeff            = .04,
	raw_factor              = 0.53,
	alpha_implicit          = .5,
	reference_sea_level_press=1.e5,
	lon_max                 = 128,
	lat_max                 = 64,
	num_levels              = 18,
	num_fourier             = 42,
	num_spherical           = 43,
	fourier_inc             = 1,
	triang_trunc            =.true.,
	valid_range_t 	        = 100. 800.,
	vert_coord_option       = 'uneven_sigma',
	topography_option       = 'flat',
	surf_res                = 0.1,
	scale_heights           = 5.0,
	exponent                = 2.0,
	do_no_eddy_eddy         = .false. /

EOF
#     endif

    cat $namelist >> input.nml
    cp $diagtable diag_table
    cp $fieldtable field_table
    cp $execdir/fms.x fms.x

    cp input.nml $run_dir


    #--------------------------------------------------------------------------------------------------------

    # run the model with mpirun
    set MX_RCACHE=2
    mpirun -v -mca btl vader,openib,self -hostfile ${HOSTFILE} -np ${NSLOTS} ${workdir}/fms.x

    #--------------------------------------------------------------------------------------------------------

    #   --- generate date for file names ---

    set date_name = `$time_stamp -eh`
    if ( $date_name == "" ) set date_name = tmp`date '+%j%H%M%S'`
    if ( -f time_stamp.out ) rm -f time_stamp.out

    #--------------------------------------------------------------------------------------------------------

    #   --- move output files to their own directories (don't combine) ---

    mkdir $output_dir/combine/$date_name

    foreach ncfile ( `/bin/ls *.nc *.nc.????` )
	mv $ncfile $output_dir/combine/$date_name/$date_name.$ncfile
    end

    #   --- save ascii output files to local disk ---

    foreach out (`/bin/ls *.out`)
	mv $out $output_dir/logfiles/$date_name.$out
    end

    #   --- move restart files to output directory ---

    cd $workdir/RESTART
    set resfiles = `/bin/ls *.res*`
    #     --- desired filename for cpio of output restart files ---
    set restart_file = "${output_dir}/restart/${date_name}.cpio"
    if ( $#resfiles > 0 ) then
    	if ( ! -d $restart_file:h ) mkdir -p $restart_file:h
    	#     --- also save namelist and diag_table ---
    	cp $workdir/{*.nml,diag_table} .
    	set files = ( $resfiles input.nml diag_table )
    	/bin/ls $files | cpio -ocv > $restart_file:t
    	mv $restart_file:t $restart_file
    	#     --- set up restart for next run ---
    	if ( $irun < $runs_per_script ) then
    	    mv -f *.res*  ../INPUT
    	endif
    endif

    cd $workdir

    #--------------------------------------------------------------------------------------------------------

    #   --- write new reload information ---
    # for comparison with $start_analysis,  run_number = (ireload-1)*runs_per_script + irun
    set run_number = `expr $ireload \* $runs_per_script - $runs_per_script + $irun`
    echo "Completed run $irun of $runs_per_script in bsub $ireload."
    set irun_prev = $irun
    @ irun++

    # remove restart file (init_cond) that is no longer in {reload_file} or ${reload_file}_prev
    if ( -f "${reload_file}_prev" ) then
       set irun_tmp = $irun
       set ireload_tmp = $ireload
       set init_cond_tmp = $init_cond
       source "${reload_file}_prev"
       rm -r $init_cond
       set irun = $irun_tmp
       set ireload = $ireload_tmp
       set init_cond = $init_cond_tmp
    endif
    if ( -f "$reload_file" ) mv -f "$reload_file" "${reload_file}_prev"

    if ( $irun <= $runs_per_script ) then
	echo "set irun         =  $irun"          >  $reload_file
    else
	@ ireload++
	echo "set irun         =  1"              >  $reload_file
    endif

    echo     "set init_cond    =  $restart_file"  >> $reload_file
    echo     "set ireload      =  $ireload"       >> $reload_file

#     ############################# post processing ############################

    cd $run_analysis
    if (${run_number} >= ${start_analysis}) then # combine data and do analysis

        # need to be careful not to write on top of file for analysis job currently pending in queue.
        # put each job in separate directory.
        set postproc_dir = ${run_analysis}/${date_name} # directory for this analysis run

        if ( ! -e $postproc_dir ) then
          mkdir -p ${postproc_dir}
        else
          rm -rf ${postproc_dir}
          mkdir ${postproc_dir}
          echo "WARNING: Existing analysis directory ${postproc_dir} removed."
        endif
        cd ${postproc_dir}

	echo "set exp_name = $exp_name" > post_processing_info
	echo "set data_dir = $data_dir" >> post_processing_info
	echo "set run_name = $run_name" >> post_processing_info
	echo "set run_script = $run_script" >> post_processing_info
	echo "set date_name = $date_name" >> post_processing_info
	echo "set run_analysis = $run_analysis" >> post_processing_info
	echo "set fms_home = $fms_home" >> post_processing_info
	echo "set tmpdir1 = $tmpdir1" >> post_processing_info
        # specify model resolution, which is set in spectral_dynamics_nml section of input/namelists
        echo "set `grep num_fourier $namelist | tr ',' ' ' `" >> post_processing_info
	echo "set irun = $irun_prev" >> post_processing_info
	echo "set runs_per_script = $runs_per_script" >> post_processing_info
        # information for segmentation of analysis
        echo "set days_per_segment = $days_per_segment" >> post_processing_info
	echo "set num_segments = $num_segments" >> post_processing_info
	echo "set isegment = 1" >> post_processing_info

        if ($irun_prev == $runs_per_script) then
	   echo "set final = 1" >> post_processing_info
	else
	   echo "set final = 0" >> post_processing_info
	endif

         cp "$analysis_dir/$analysis_script" ./

        # ssh to head node and submit analysis script
	echo "*** Submitting analyis script"
	ssh psmnsb "bash -l -c 'qsub -wd ${postproc_dir} ${postproc_dir}/${analysis_script}'"
    else
	rm -rf "${output_dir}/combine/${date_name}"
    endif

    # don't resubmit if model failed to build a restart file
    if ( ! -f $restart_file ) then
      echo "FATAL ERROR: model restart file not saved. Try moving ${reload_file}_prev to ${reload_file} and re-running."
      echo "ireload = $ireload, irun = $irun"
      set irun = `expr $runs_per_script + 1 `
      set ireload = `expr $num_script_runs + 1 `
    endif

end # --- loop over $irun ended ---

rm -rf $workdir

cd $exp_home/run

if ($ireload > $num_script_runs) then
  echo "Note: not resubmitting job."
else
  echo "Submitting run $ireload."
  ssh psmnsb "source ~/.profile; qsub $run_script"
endif

date
