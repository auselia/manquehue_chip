// Behavioural model of a serial NOR flash for simulation (Verilator, Icarus), for what qqspi (rtl/obi_qspi) sends:
//   READ (0x03):       command, 24-bit byte address and data on single lines (MOSI = sio0, MISO = sio1)
//   FAST READ QUAD (0xEB): command on sio0, 24-bit address on sio[3:0] (6 clocks), 6 clocks that are ignored
//                       (mode byte and dummy cycles of a W25Q; qqspi drives nothing there), data on sio[3:0]
// SPI mode 0: the host drives at the falling SCLK edge and samples at the rising edge. The content comes from a
// byte-addressed hex file (objcopy -O verilog, addresses relative to the flash base). An erased flash reads 0xFF.
// Not modelled: continuous-read mode, the QE bit (quad is always accepted), program and erase, timing checks.
`timescale 1ns/1ps
module spi_flash_model #(
  parameter int unsigned SizeBytes = 1 << 20,   // modelled part of the 16 MB flash
  parameter real         TcoNs     = 6.0        // output valid after the SCLK falling edge
) (
  input  wire       csn,
  input  wire       sclk,
  input  wire [3:0] sio_i,                      // lines driven by the host (sio0 = MOSI)
  output wire [3:0] sio_o,                      // lines driven by the flash
  output wire [3:0] sio_oe                      // which lines the flash drives
);
  reg [7:0]  mem [SizeBytes];
  reg [7:0]  cmd;
  reg [23:0] addr;
  integer    nclk;                              // rising SCLK edges since CS fell
  reg [3:0]  out_q, oe_q;
  string     image;

  initial begin
    for (int i = 0; i < SizeBytes; i++) mem[i] = 8'hFF;
    if ($value$plusargs("flash=%s", image)) begin
      $readmemh(image, mem);
      $display("[FLASH] loaded %s", image);
    end
    out_q = 4'h0;
    oe_q  = 4'h0;
  end

  assign #(TcoNs) sio_o  = out_q;
  assign #(TcoNs) sio_oe = oe_q;

  always @(negedge csn) begin
    nclk = 0;
    cmd  = 8'h00;
    addr = 24'h0;
    oe_q = 4'h0;
  end
  always @(posedge csn) oe_q = 4'h0;

  always @(posedge sclk) if (!csn) begin
    if (nclk < 8)                                    cmd  = {cmd[6:0], sio_i[0]};
    else if (cmd == 8'h03 && nclk < 32)              addr = {addr[22:0], sio_i[0]};
    else if (cmd == 8'hEB && nclk < 14)              addr = {addr[19:0], sio_i[3:0]};
    nclk = nclk + 1;
  end

  always @(negedge sclk) if (!csn) begin
    integer k;
    reg [7:0] b;
    if (cmd == 8'h03 && nclk >= 32) begin            // one bit per clock, MSB first, on MISO
      k     = nclk - 32;
      b     = mem[(addr + k / 8) % SizeBytes];
      out_q = {2'b00, b[7 - (k % 8)], 1'b0};
      oe_q  = 4'b0010;
    end else if (cmd == 8'hEB && nclk >= 20) begin   // one nibble per clock, high nibble first
      k     = nclk - 20;
      b     = mem[(addr + k / 2) % SizeBytes];
      out_q = (k % 2 == 0) ? b[7:4] : b[3:0];
      oe_q  = 4'b1111;
    end
  end
endmodule
