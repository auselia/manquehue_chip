// port-only model of the SRAM macro: the ATPG tool treats it as a black box (outputs unknown)
module gf180mcu_fd_ip_sram__sram512x8m8wm1 (CLK, CEN, GWEN, WEN, A, D, Q, VDD, VSS);
  input CLK, CEN, GWEN;
  input [7:0] WEN;
  input [8:0] A;
  input [7:0] D;
  output [7:0] Q;
  inout VDD, VSS;
endmodule
