# Notes on fms-idealized source code
*Corentin Herbert (ENS Lyon, France), corentin.herbert@ens-lyon.fr (2018)*

These notes are intended for pedagogical purpose only.
The source tree should not be edited directly; instead, use the src_mods directory in the experiment tree to replace individual source files.

                                               `src`
                                                 |
                                                 |
      -----------------------------------------------------------------------------------
      |                |                 |               |                 |            |
      |                |                 |               |                 |            |
      |                |                 |               |                 |            |
`atmos_param`    `atmos_shared`    `atmos_solo`    `atmos_spectral`    `coupler`    `shared`

## atmos_param
Various parametrizations for physical processes.
Containts in particular the following Fortran modules:
- `betts_miller_mod` (actually several implementations of it).
- `dargan_bettsmiller_mod`
- `diffusivity_mod`
- `dry_convection_mod`
- `hs_forcing_mod`: Held-Suarez forcing
- `lscale_cond_mod`
- `monin_obukhov_mod`
- `my25_turb_mod`
- `bm_omp_mod`
- `qe_moist_convection_mod`
- `shallow_conv_mod`
- `grid_physics`
- `radiation_mod`
- `vert_diff_mod`
- `vert_diff_driver_mod`
- `vert_turb_driver_mod`

## atmos_shared
- `vert_advection_mod`

## atmos_solo
Contains the main file for the atmospheric code (`program atmos_model`).

## atmos_spectral
Spectral core for the model.

### driver/solo/atmosphere.f90

- `atmosphere_mod`

### init

- `spectral_init_cond_mod`
- `spectral_initialize_fields_mod`
- `topog_regularization_mod`
- `vert_coordinate_mod`

### model

- `every_step_diagnostics_mod`
- `fv_advection_mod`
- `global_integral_mod`
- `implicit_mod`
- `leapfrog_mod`
- `matrix_invert_mod`
- `press_and_geopot_mod`
- `spectral_damping_mod`
- `spectral_dynamics_mod`
- `tracer_type_mod`
- `water_borrowing_mod`

### tools

- `gaus_and_legendre_mod`
- `grid_fourier_mod`
- `spec_mpp_mod`
- `spherical_mod`
- `spherical_fourier_mod`
- `transforms_mod`

## coupler
Contains the main file for the coupled code (`program coupler_main`)

Modules:
- `flux_exchange_mod`
- `mixed_layer_mod`
- `surface_flux_mod`

## shared

- `fms_platform.h`

- `constants_mod`
- `field_manager_mod`
- `horiz_interp_mod`
- `memutils_mod`
- `platform_mod`
- `sat_vapor_pres_mod`
- `simple_sat_vapor_pres_mod`
- `tracer_manager_mod`
- `tridiagonal_mod`


### diag_manager

- `diag_axis_mod`
- `diag_data_mod`
- `diag_manager_mod`
- `diag_output_mod`
- `diag_util_mod`

### fft

- `fft99_mod`
- `fft_mod`

### fms

- `fms_mod`
- `fms_io_mod`

### mpp

- `mpp_data_mod`
- `mpp_domains_mod`
- `mpp_mod`
- `mpp_io_mod`
- `mpp_parameter_mod`
- `mpp_pset_mod`

### time_manager

- `time_manager_mod`
- `get_cal_time_mod`

### topography

- `topography_mod`
- `gaussian_topog_mod`
