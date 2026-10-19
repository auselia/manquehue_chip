//////////////////////////////////////////////////////////////////////////
// Croc SoC Sign-off
// Author: Nicolás Villegas - Universidad de los Andes, Chile
// Description: Metal1 to Metal5 dummy fill for croc_soc (IC Validator, called by make fill-icv)
//
// Made from pdk_synopsys/DRC_ICV_MODIFIED/DRC/ICV/gf180mcu_fill.rs (Viktor Schneider, IMS LUH). The density
// search, the fill-cell generator and the keepout to signal metal are the same. Changes:
//   1) The fill goes to the drawn datatype 0, not METALn_DUMMY (datatype 4): gf180mcu_density.drc reads only
//      datatype 0. Floating fill has no devices and does not change LVS.
//   2) No pad-ring keepout (outer_margin from the COMP hull) and no COMP fill: croc_soc is a core macro without a
//      pad ring, and that keepout blocked almost all fill.
//   3) Smaller spacings (see the tunables) and no cross-layer keepout.
// It always runs (upstream shares the file with a DRC deck through BEOL_DENSITY).
//////////////////////////////////////////////////////////////////////////

#include <icv.rh>

layout_grid_options(
    resolution = 0.001,
    check_45   = { PATH, POLYGON },
    check_90   = {}
);

#include "gf180mcu_layers.rh"

// ---------------------------------------------------------------------
// Tunables. The 30 % threshold is the one of gf180mcu_density.drc. The spacings are smaller than upstream.
// ---------------------------------------------------------------------
vDENSITY_THRESHOLD    : const double = 0.30;
vWINDOW_SIZE          : const double = 80;   // sliding density-window edge length (um)
vWINDOW_STEP          : const double = 40;   // window step (um)
// Same-layer minimum width and spacing of Metal1 to Metal5: 0.28 um (Mn.1, Mn.2a), 0.3 um only between shapes wider
// than 10 um (Mn.2b, fill cells are 2 x 2 um). The upstream 2.0 / 1.0 um keepouts left almost no room on M2.
vSAME_LAYER_KEEPOUT   : const double = 0.4;  // fill-to-signal spacing, same layer (um); real min is 0.28um
// No cross-layer keepout: GF180MCU has no rule for metal over metal of another layer, and with one M2 and M4
// stayed below 30 % (about 21 and 22 %).
vFUSE_OTP_KEEPOUT     : const double = 6.0;  // keepout around fuse/OTP-related layers (um)
// Fill-to-fill spacing, also above the same-layer minimum of 0.28 um. The upstream 1 to 2 um gaps limited the
// local density to about 25 to 44 %.
vFILL_SPACING         : const double = 0.3;  // fill-to-fill spacing (um)

metaln_layers       : list of polygon_layer = {METAL1, METAL2, METAL3, METAL4, METAL5};
metaln_dummy_layers : list of polygon_layer = {METAL1_DUMMY, METAL2_DUMMY, METAL3_DUMMY, METAL4_DUMMY, METAL5_DUMMY};

density_metal_min : function(void) returning void {
    areaL : double = den_polygon_area("METAL");
    areaW : double = den_window_area();
    ratio_lw : double = areaL / areaW;
    if (ratio_lw < vDENSITY_THRESHOLD)
        den_save_window(error_names = { "RATIO", "area", "window" },
                         values = { ratio_lw, areaL, areaW });
}

metal_dummy_keepout =
    FUSETOP or
    POLYFUSE or
    FUSEWINDOW_D or
    PMNDMY or
    OTP_MK;

metal_fill_output : list of polygon_layer = {};

for (n = 1 to 5) {

    fill_metal_gen : function(void) returning void {
        strike : polygon = fp_get_current_polygon();
        fp_generate_fill(
            polygon    = strike,
            width      = 2,
            height     = 2,
            space_x    = vFILL_SPACING,
            space_y    = vFILL_SPACING,
            stagger_x  = 2,
            grid_shift = {n / 2, n * 2}
        );
    }

    circuit_metal_space = size(metaln_layers[n - 1], distance = vSAME_LAYER_KEEPOUT, clip_acute = BISECTOR);

    // Fillable: not near signal metal of this layer and not near fuse or OTP structures (no pad-ring and no
    // cross-layer terms, see the header).
    no_metal_dummy_area =
        circuit_metal_space or
        size(metal_dummy_keepout, distance = vFUSE_OTP_KEEPOUT, clip_acute = BISECTOR);

    { @ "METAL" + n + " fill candidates within window: " + (vDENSITY_THRESHOLD * 100) + "%";
        density(
            window_layer  = layer_extent(COMP),
            layer_hash    = { "METAL" => metaln_layers[n - 1] or metaln_dummy_layers[n - 1] },
            window_function = density_metal_min,
            delta_window  = {vWINDOW_SIZE, vWINDOW_SIZE},
            delta_x       = vWINDOW_STEP,
            delta_y       = vWINDOW_STEP,
            resize_delta_xy = true
        );
    }

    candidates_metaln = density(
        window_layer  = layer_extent(COMP),
        layer_hash    = { "METAL" => metaln_layers[n - 1] or metaln_dummy_layers[n - 1] },
        window_function = density_metal_min,
        delta_window  = {vWINDOW_SIZE, vWINDOW_SIZE},
        delta_x       = vWINDOW_STEP,
        delta_y       = vWINDOW_STEP,
        resize_delta_xy = true
    ) not no_metal_dummy_area;

    metal_fill_output.push_back(fill_pattern(
        candidates_metaln,
        fill_function = fill_metal_gen,
        grid_mode     = GLOBAL,
        output_aref   = {output_aref = true}
    ));
}

// The fill goes to the drawn datatype 0 of Metal1 to Metal5 (change 1 in the header).
gds_fh1 = gds_library("filled.gds");
write_gds(gds_fh1, holding_cell = "DUMMY_FILL", merge_input_layout = true, cell_prefix = "FILL_",
    layers = {
        {metal_fill_output[0], {34, 0}},
        {metal_fill_output[1], {36, 0}},
        {metal_fill_output[2], {42, 0}},
        {metal_fill_output[3], {46, 0}},
        {metal_fill_output[4], {81, 0}}
    }
);
