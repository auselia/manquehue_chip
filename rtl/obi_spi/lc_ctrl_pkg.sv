// Copyright and related rights waived via CC0.
//
// Minimal, project-local stand-in for OpenTitan's life-cycle-controller
// package. spi_host's `scanmode_i` port only needs the *type* lc_tx_t to
// exist -- inside spi_host.sv it is XOR-reduced straight into an unused
// signal and never otherwise consulted (this build has no scan/DFT chain
// running through spi_host), so we tie it permanently to Off and don't vendor
// the real lc_ctrl IP for one throwaway port.
package lc_ctrl_pkg;
  typedef logic [3:0] lc_tx_t;
  parameter lc_tx_t On  = 4'h6;
  parameter lc_tx_t Off = 4'h9;
endpackage
