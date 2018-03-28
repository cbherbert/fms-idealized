#!/bin/bash
### SGE variables:
## job shell:
#$ -S /bin/bash
## job name:
#$ -N fms_default_analysis2d
## queue:
#$ -q monointeldeb128
## SGE user environment:
#$ -cwd
## Error/output files:
#$ -o $JOB_NAME-$JOB_ID.out
#$ -e $JOB_NAME-$JOB_ID.err
## Export environment variables:
#$ -V
#BSUB -R "rusage[scratch=320000]"
#BSUB -R "rusage[mem=56000]"
#Note: 320000 MB scratch space and 56000 MB RAM should work for output of up to 90 days (T85, 180 days at T42)

# Ian Eisenman, Yohai Kaspi, Tim Merlis, November 2010
# Xavier Levine, February 2012
# Farid Ait Chaalal, August 2012
# Robb Wills, Zhihong Tan, August 2013
# Corentin Herbert, May 2016


source /usr/share/lmod/lmod/init/bash
module load IntelComp/2017.4
module list


#limit stacksize unlimited
#set echo

#set NPROCS = `echo $LSB_HOSTS| wc -w`
echo "This job has allocated ${NSLOTS} cpus"

#change the working directory (default is home directory)
#cd $LS_SUBCWD
echo "Working directory is $PWD"

# maximum and minimum potential temperature values for isentropic analyses
PotTmin=170
PotTmax=650

# default frequency of FMS output [can be overwritten by post_processing_info]
fms_output_freq='4xday'
fms_surface_freq='1x20days'

# whether to concatenate multiple time segments of analysis output (history) into a single netcdf file, only used if num_segments > 1 [can be overwritten by post_processing_info]
concatenate_history=0                 # (=1) single netcdf file with all times, (=0) separate files each with single time

# file generated by model run script to set exp_name, data_dir, run_name, date_name, run_analysis, fms_home, tmpdir, num_fourier, irun, runs_per_script, days_per_segment, num_segments, i_segment, final
source post_processing_info

times_per_segment=$((days_per_segment * ${fms_output_freq:0:1} )) # number of instances in each segment
echo "$times_per_segment instants per segment, frequency $fms_output_freq."

# directories
analysis_dir="$(dirname "$fms_home")/analysis/analysis_2d"           # directory with analysis code
run_dir="${tmpdir1}/${run_name}"                  # tmp directory for current run
#set scratch_dir    = $TMPDIR/${exp_name}/${run_name}     # scratch directory on specific compute node (faster read/write)
scratch_dir="$(dirname "$fms_home")/fms_tmp/${exp_name}/${run_name}"
uncombined_dir="${tmpdir1}/${run_name}/output/combine/${date_name}" # directory with uncombined input data
input_dir="${scratch_dir}/combine"                     # directory where combined netcdf files are written
output_dir="${scratch_dir}/history"                     # directory where output is written

src_dir="$analysis_dir/src"                          # prefix for path_names
exe_dir="$run_analysis/exe.analysis"                 # executable directory
executable="analysis"                                   # executable name
mppnccombine="${tmpdir1}/mppnccombine" # path to the combine executable
include_dir="$fms_home/bin/nc_inc"
template="$analysis_dir/input/mkmf.template.ifc_psmn" # machine-specific compilation templates for your platform
diag_table="$analysis_dir/input/diag_table.dt"
pathnames="$analysis_dir/input/path_list"              # file containing list of code

mkmf="$fms_home/bin/mkmf"                         # produces makefile

echo "*** Running ${analysis_dir}/run_analysis_dry_2d for ${date_name} of ${run_name} on $HOSTNAME ***"

#### STEP 1: Combine the data files ####
# This takes all the nc files in output/combine/$date_name/ and creates a combined nc file in combine/

mkdir -p ${input_dir}
cd ${scratch_dir}
for ncfile in $uncombined_dir/${date_name}.*.nc.0000; do
  \cp ${ncfile%.*}.* ${scratch_dir}
  ncfile_tail=${ncfile##*/}
  rm -f ${ncfile_tail%.*}
  $mppnccombine ${ncfile_tail%.*}
  if [ $? -eq 0 ]; then
     mv -f ${ncfile_tail%.*} ${input_dir}
     echo "${ncfile%.*} combined in ${scratch_dir} on $HOSTNAME"
  fi
  rm -f ${ncfile_tail%.*}.*
done

#### STEP 2: Run the analysis ####
# This creates the analysis executable and copies it to the date_name directory, and also the diag_table file.
# Then the loop creates the input.nml file and the analysis code creates the nc file in history/

successful_analysis=1 # this gets set to 0 if an indicator suggests any instance of analysis failed.


# Build analysis code
mkdir -p $exe_dir
mkdir -p $output_dir
cd $exe_dir
# create make file
# append fms_home (containing netcdf libraries and include files) to template
echo "fms_home =  $fms_home" > $exe_dir/tmp_template
/bin/cat $template >> $exe_dir/tmp_template
$mkmf -a $src_dir -c"-Daix" -t $exe_dir/tmp_template -p $executable $pathnames $include_dir
make $executable
\cp $executable $run_analysis/$date_name
\cp $diag_table $run_analysis/$date_name/diag_table

cd $run_analysis/$date_name
# Loop over analysis segments and run analysis on each one
while [ $isegment -le $num_segments ]; do
  if [ $num_segments -eq 1 ]; then
    output_file_name="$output_dir/$date_name.nc"
    TimeIn=0
  else
    output_file_name="$output_dir/$date_name.segment${isegment}.nc"
    TimeIn=$(( (isegment - 1) * times_per_segment ))
    echo "Segment ${isegment}"
    echo "TimeIn = $TimeIn"
  fi

  filename_list=$(cat -e <<EOF
    &filename_list
      InputFileName = '$input_dir/$date_name.${fms_output_freq}.nc',
      OutputFileName = '$output_file_name'/
EOF
	       )

  echo $filename_list  | tr \$ "\n" >  $run_analysis/$date_name/input.nml

  main_list=$(cat -e <<EOF
    &main_list
      DataIn = 1,
      data_source = 1,
      num_fourier = $num_fourier,
      TimeIn     = $TimeIn,
      smooth_surface = .true.,
      MaxIsentrLev = 100,
      PotTempMin = $PotTmin,
      PotTempMax = $PotTmax,
      UVarName  =  'ucomp',
      VVarName  =  'vcomp',
      VorVarName = 'vor',
      DivVarName = 'div',
      TempVarName = 'temp',
      TSVarName = 't_surf',
      PSVarName = 'ps',
      ShumVarName = 'sphum',
      CondVarName = 'dt_qg_condensation',
      ConvVarName = 'dt_qg_convection',
      DiffVarName = 'dt_qg_diffusion',
      PrecipCondVarName = 'condensation_rain',
      PrecipConvVarName = 'convection_rain',
      ToaFluxSWVarName = 'swdn_toa',
      ToaFluxLWUVarName = 'lwup_toa',
      SfcFluxSWVarName = 'swdn_sfc',
      SfcFluxLWDVarName = 'lwdn_sfc',
      SfcFluxLWUVarName = 'lwup_sfc',
      SfcFluxLHVarName = 'flux_lhe',
      SfcFluxSHVarName = 'flux_t',
      SfcFluxQFVarName = 'flux_oceanq',
      DiabCondVarName = 'dt_tg_condensation',
      DiabConvVarName = 'dt_tg_convection',
      DiabDiffVarName = 'dt_tg_diffusion',
      DiabRadVarName = 'dt_tg_radiation',
      DiabSWVarName = 'dt_tg_solar',
      BucketDepthVarName = 'bucket_depth',
      BucketDepthConvVarName = 'bucket_depth_conv',
      BucketDepthCondVarName = 'bucket_depth_cond',
      BucketDepthLHVarName = 'bucket_depth_lh',
      BucketDiffusionVarName = 'bucket_diffusion',
      DragMOVarName = 'drag_coeff_mo',
      DragLHVarName = 'drag_coeff_lh',
      DragSHVarName = 'drag_coeff_sh',
      is_gaussian = .true.,
      isentrope = .true.,
      moisture  = .false.,
      virtual   = .false.,
      bucket    = .false.,
      precip_daily_threshold = 1.1574e-5,
      moist_isentropes = .false.,
      num_segments = ${num_segments},
      num_bin = 41/
EOF
	      )

  echo $main_list  | tr \$ "\n" >>  $run_analysis/$date_name/input.nml

  ./$executable
  analysis_return_value=$?
  echo "Return value of analysis: $analysis_return_value"
  if [ $analysis_return_value -ne 0 ]; then successful_analysis=0; fi

  ((isegment++))

done # loop over $isegment ended

if [ $successful_analysis -eq 1 ]; then

    #### STEP 3: Move model output (analysis and surface) to data_dir ####
    # i.e. outside of the temporary directories, to the fms_output tree

  # copy model history and logfiles to ${data_dir}
  mkdir -p ${data_dir}/history
  mkdir -p ${data_dir}/logfiles
  mkdir -p ${data_dir}/surface

  mv -f $output_dir/${date_name}*.nc  ${data_dir}/history/
  mv -f $input_dir/${date_name}.${fms_surface_freq}.nc ${data_dir}/surface/
  \cp -f $run_dir/output/logfiles/${date_name}.* ${data_dir}/logfiles/

  # copy run script and srcmods to a tar file in output (overwrite this file with each submission of this run)
  tar czvf ${data_dir}/scripts.tgz ${run_script} "$(dirname "$fms_home")/exp/${exp_name}/srcmods"

fi

# remove combined input files from /scratch dir (leaving uncombined files in ~/fms_tmp/...)
rm -f $input_dir/${date_name}.*.nc
# also remove any output files (normally should not be any)
rm -f $output_dir/${date_name}.*.nc


#### STEP 4: Check if files are successfully in data_dir; if so, remove original uncombined files from model output directory ####

successful_data=1

# check time-mean history output for each segment (make sure file exists and is not too small)
cd ${data_dir}/history
isegment=1
while [ $isegment -le $num_segments ]; do
  if [ $num_segments -eq 1 ]; then
    output_file_name="$date_name.nc"
  else
    output_file_name="$date_name.segment${isegment}.nc"
  fi
  if [ -e $output_file_name ]; then
    sz=$(stat -c %s $output_file_name)
    if [ $sz -lt 1000000 ]; then successful_data=0; fi
  else
    successful_data=0
  fi
  ((isegment++))
done

# check surface output (make sure file exists - size depends on number of times)
#cd ${data_dir}/surface
#if [ ! -e ${date_name}.${fms_surface_freq}.nc ]; then successful_data=0; fi

# if these tests passed, remove uncombined model output
if [ ${successful_data} -eq 1 ]; then
    echo "  History and surface files at ${data_dir}, removing uncombined files at ${uncombined_dir}"
    rm -f ${uncombined_dir}/${date_name}.*.nc.*
    rmdir ${uncombined_dir}
fi

# clean up
rm $run_analysis/$date_name/$executable
rm $run_analysis/$date_name/diag_table
rm $run_analysis/$date_name/input.nml
