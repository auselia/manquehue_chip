/* -----------------------------------------------------------------------
 * ICV runset config override -- database resolution
 * -----------------------------------------------------------------------
 * Both pdk_synopsys/DRC_ICV/.../gf180mcu_drc.rs and
 * pdk_synopsys/LVS_ICV/.../cmos018hv.3p3.6v.design_inc.rs hard-code
 * resolution_options(layout_resolution_check = {action = ABORT,
 * resolution = 0.001}), i.e. they assume a 1nm (0.001um) GDS database
 * unit. Fusion Compiler's write_gds (see scripts/06_finish.tcl) instead
 * writes GDS at 0.1nm (0.0001um), which makes ICV abort immediately with:
 *   ERROR: Library resolution "0.0001" does not match specified runset
 *   layout_resolution "0.001".
 *
 * Loaded via `icv -runset_config` (see the drc-icv/lvs-icv Makefile
 * targets), which splices this in right after the deck's own options and
 * before its ASSIGN section -- so this resolution_options() call is the
 * one that takes effect. If Fusion Compiler's GDS export precision ever
 * changes, update the `resolution` value below (and ICV_LAYOUT_RESOLUTION
 * in the Makefile, which only documents it) to match.
 * ----------------------------------------------------------------------- */
resolution_options(
    drc_angle_precision     = 0.0,
    drc_length_precision    = 0.0,
    internal_resolution     = 0.0001,
    layout_resolution_check = {
        action = ABORT,
        resolution = 0.0001
    },
    spacing_tolerance       = 0.0
);
