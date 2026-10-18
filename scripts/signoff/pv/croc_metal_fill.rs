//////////////////////////////////////////////////////////////////////////
// croc_metal_fill.rs -- Metal1-Metal5 dummy-fill runset for croc_soc
// (Synopsys IC Validator / GF180MCU).
//
// Derived from pdk_synopsys/DRC_ICV_MODIFIED/DRC/ICV/gf180mcu_fill.rs
// (originally by Viktor Schneider, IMS LUH). The per-layer metal density
// search, the fill-cell generator, and the spacing-to-signal keepout
// (circuit_metal_space / lower_metal_space / upper_metal_space /
// metal_dummy_keepout) are kept as-is from that deck: that part of the
// logic is sound and was not the problem.
//
// Two fixes over the upstream deck, both confirmed on croc_soc (2026-08-14):
//
// 1) Output datatype. Upstream writes fill to the METALn_DUMMY datatype
//    (e.g. {36,4} for Metal2). The project's KLayout signoff density
//    check (gf180_drc_lvs/drc/gf180mcu_density.drc) only reads the
//    primary drawn datatype (metal2 = polygons(36, 0), no OR with
//    datatype 4), so fill written on datatype 4 is geometrically real
//    and correctly placed in the hierarchy, but invisible to signoff.
//    Fixed by writing to datatype 0 instead. Floating, unconnected fill
//    shapes on the signal datatype do not affect LVS (device extraction
//    keys off diffusion/poly/contact recognition layers, not bare metal;
//    fill has none of those and is never touched by a via to a real net).
//
// 2) Keepout logic. Upstream computes an "outer_margin" keepout term from
//    a pad-ring-hull heuristic (unused_outer_COMP: the area outside a
//    COMP line assumed to run around a padring) and ORs it into the
//    per-layer no_metal_dummy_area keepout, and also uses it as the
//    "ignore" subtraction in the density ratio denominator. croc_soc is a
//    bare digital core macro with no pad ring, so that heuristic finds no
//    sensible padring boundary. Confirmed by direct measurement: with
//    fix (1) alone (datatype only, outer_margin still present), actual
//    Metal2 coverage moved from 18.895% to 18.917% -- essentially zero,
//    even though the tool reported 100 "candidate" windows per layer.
//    The COMP/pad-ring section (padring hull, COMP dummy fill, and the
//    outer_margin/ignore terms derived from it) is removed entirely here.
//    Everything else -- same-layer/adjacent-layer spacing keepout, fuse/
//    OTP keepout, density threshold, fill-cell size/stagger -- is
//    unchanged from upstream.
//
// Gated by nothing: this file's only job is metal fill, so (unlike
// upstream, which shares gf180mcu_fill.rs with a DRC deck via a
// BEOL_DENSITY env var) it always runs.
//////////////////////////////////////////////////////////////////////////

#include <icv.rh>

layout_grid_options(
    resolution = 0.001,
    check_45   = { PATH, POLYGON },
    check_90   = {}
);

#include "gf180mcu_layers.rh"

// ---------------------------------------------------------------------
// Tunables (kept identical to the upstream deck's own values, named here
// for readability; see gf180mcu_density.drc for the 30% threshold this
// must satisfy).
// ---------------------------------------------------------------------
vDENSITY_THRESHOLD    : const double = 0.30;
vWINDOW_SIZE          : const double = 80;   // sliding density-window edge length (um)
vWINDOW_STEP          : const double = 40;   // window step (um)
// GF180MCU's real minimum width/spacing for Metal1-Metal5 is uniformly
// 0.28um (rule Mn.1/Mn.2a in gf180_drc_lvs/drc/rule_decks/metaln.drc,
// confirmed 2026-08-14 for n=1..5), with 0.3um required only between two
// *wide* (>10um) shapes (Mn.2b) -- fill cells are 2x2um, well under that.
// The values inherited from the upstream deck (2.0/1.0um) were 3.5-7x
// more conservative than the real rule, and on M2 -- sandwiched between
// M1 (>=30% dense, so its shapes are numerous and closely packed) and M3
// -- a full 1um dilation around essentially all of M1 ate almost the
// entire layer's candidate area (measured: M2 coverage only moved
// 18.895% -> 19.104% with the padring fix alone). Tightened to a small
// guard-band above the real minimum instead.
vSAME_LAYER_KEEPOUT   : const double = 0.4;  // fill-to-signal spacing, same layer (um); real min is 0.28um
// M2 and M4 (each sandwiched between two real-signal neighbor layers)
// stayed stuck below 30% through both the padring-heuristic removal and
// this same-layer/fill-spacing retune, and even after adding a
// cross-layer keepout term back in and shrinking it toward zero the gap
// barely moved (M2: 18.895% -> ~21%, M4: 17.654% -> ~22%, while the
// unsandwiched layers M1/M3/M5 all cleared 30% comfortably, M5 reaching
// 47%+). Root cause: GF180MCU has no DRC rule for plain cross-layer
// metal overlap (only same-layer width/spacing rules exist -- confirmed
// against gf180_drc_lvs/drc/rule_decks/metal[1-5].drc) and no DRC rule
// against fill-on-one-layer overlapping fill-on-an-adjacent-layer either
// (different physical layers, dielectric between them). So there is no
// cross-layer keepout term at all here -- see no_metal_dummy_area below,
// which now only excludes real same-layer signal and fuse/OTP keepout.
vFUSE_OTP_KEEPOUT     : const double = 6.0;  // keepout around fuse/OTP-related layers (um)
// Fill-to-fill spacing inside each accepted window. Also bound by the
// same 0.28um same-layer minimum (fill-to-fill is still same-layer
// spacing); the upstream 1-2um gaps between 2x2um fill cells capped
// achievable local density at ~25-44% even in a fully open window.
// Tightened to just above the real minimum so an open window can
// actually reach a high packing fraction.
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

    // No pad-ring outer_margin term (removed -- see header) and no
    // cross-layer or "avoid the layer-below's fill footprint" terms
    // either (removed -- see vFUSE_OTP_KEEPOUT comment above). The
    // fillable region is simply "not near real signal metal on this
    // layer, not near fuse/OTP structures."
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

// Fill is written to the primary drawn datatype (0) for Metal1-Metal5 --
// see fix (1) in the header comment.
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
