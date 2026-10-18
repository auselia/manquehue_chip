// Behavioural model of a serial NOR flash for simulation (Verilator, Icarus): command READ (0x03) in SPI
// mode 0 with a 24-bit byte address, what qqspi (rtl/obi_qspi) sends in single-SPI mode. Other commands are
// ignored and leave MISO undriven. The content comes from a byte-addressed hex file (objcopy -O verilog, with
// the addresses made relative to the flash base). An erased flash reads 0xFF.
// Not modelled: quad read (0xEB), program and erase, status register, timing checks.
`timescale 1ns/1ps
module spi_flash_model #(
  parameter int unsigned SizeBytes = 1 << 20,   // modelled part of the 16 MB flash
  parameter real         TcoNs     = 6.0        // MISO valid after the SCLK falling edge
) (
  input  wire csn,
  input  wire sclk,
  input  wire mosi,
  output wire miso
);
  reg [7:0]  mem [SizeBytes];
  reg [7:0]  cmd;
  reg [23:0] addr;
  integer    nbits;
  reg        miso_q, drive;
  string     image;

  initial begin
    for (int i = 0; i < SizeBytes; i++) mem[i] = 8'hFF;
    if ($value$plusargs("flash=%s", image)) begin
      $readmemh(image, mem);
      $display("[FLASH] loaded %s", image);
    end
    miso_q = 1'b0;
    drive  = 1'b0;
  end

  assign #(TcoNs) miso = drive ? miso_q : 1'bz;

  // a new command at every CS fall
  always @(negedge csn) begin
    nbits = 0;
    cmd   = 8'h00;
    addr  = 24'h0;
    drive = 1'b0;
  end
  always @(posedge csn) drive = 1'b0;

  // command and address are sampled at the rising SCLK edges
  always @(posedge sclk) if (!csn) begin
    if (nbits < 8)       cmd  = {cmd[6:0], mosi};
    else if (nbits < 32) addr = {addr[22:0], mosi};
    nbits = nbits + 1;
  end

  // READ data: MSB first, shifted out at the falling SCLK edges after the last address bit
  always @(negedge sclk) if (!csn && cmd == 8'h03 && nbits >= 32) begin
    integer bitpos;
    bitpos = nbits - 32;                        // number of data bits already sampled by the host
    drive  = 1'b1;
    miso_q = mem[(addr + bitpos / 8) % SizeBytes][7 - (bitpos % 8)];
  end
endmodule
