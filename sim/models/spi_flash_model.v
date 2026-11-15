// Behavioural model of a serial NOR flash (W25Q128JV command set) for simulation (Verilator, Icarus).
// Memory accesses of qqspi (rtl/obi_qspi):
//   READ (0x03):       command, 24-bit byte address and data on single lines (MOSI = sio0, MISO = sio1)
//   FAST READ QUAD (0xEB): command on sio0, 24-bit address on sio[3:0] (6 clocks), 6 clocks that are ignored
//                       (mode byte and dummy cycles of a W25Q; qqspi drives nothing there), data on sio[3:0]
//   PAGE PROGRAM (0x02): command, address and data on single lines (a store, after a write enable of qspi_cmd)
// Commands of qspi_cmd (rtl/obi_qspi/qspi_cmd.sv), single lines:
//   0x06 write enable, 0x04 write disable, 0x05 / 0x35 read status 1 / 2, 0x01 write status 1 (and 2 with a second
//   byte), 0x31 write status 2, 0x02 page program, 0x20 sector erase (4 KB), 0xD8 block erase (64 KB), 0xC7 / 0x60
//   chip erase, 0x9F JEDEC ID (EF 40 18), 0x0B fast read (8 dummy clocks), 0xB9 power down, 0xAB release power down,
//   0x66 / 0x99 reset.
//   Status 1: [0] BUSY [1] WEL. Status 2: [1] QE. Program, erase and status writes need WEL, take effect when CS
//   rises, set BUSY for BusyNs (erase: EraseNs) and clear WEL. While BUSY, the flash takes only 0x05 and 0x35.
//   Page program clears bits only (new = old AND data) and wraps inside the 256-byte page, as the W25Q.
// SPI mode 0 or 3: the host drives at the falling SCLK edge and samples at the rising edge. The content comes from
// a byte-addressed hex file (+flash=, objcopy -O verilog, addresses relative to the flash base). Erased reads 0xFF.
// Not modelled: continuous-read mode, the QE bit check on quad reads (quad is always accepted), protection bits.
`timescale 1ns/1ps
module spi_flash_model #(
  parameter int unsigned SizeBytes = 1 << 20,   // modelled part of the 16 MB flash
  parameter real         TcoNs     = 6.0,       // output valid after the SCLK falling edge
  parameter real         BusyNs    = 2000.0,    // page program and status write time (W25Q: 0.4 ms, shortened)
  parameter real         EraseNs   = 5000.0,    // erase time (W25Q: 45 ms for a sector, shortened)
  parameter real         TcsNs     = 5.0        // tSHCH / tCHSH: no SCLK edge this close to a CS rise
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
  reg [7:0]  sr1, sr2;                          // status registers (sr1[0] BUSY, sr1[1] WEL, sr2[1] QE)
  reg [7:0]  shreg;                             // byte being shifted in after the address
  reg [7:0]  page [256];                        // page program data, in the order received
  integer    npage;                             // page program bytes received
  reg [7:0]  wr1, wr2;                          // status write data
  integer    nwr;
  reg        pd;                                // power down
  string     image;

  initial begin
    for (int i = 0; i < SizeBytes; i++) mem[i] = 8'hFF;
    if ($value$plusargs("flash=%s", image)) begin
      $readmemh(image, mem);
      $display("[FLASH] loaded %s", image);
    end
    out_q = 4'h0;
    oe_q  = 4'h0;
    sr1   = 8'h00;
    sr2   = 8'h00;
    pd    = 1'b0;
  end

  assign #(TcoNs) sio_o  = out_q;
  assign #(TcoNs) sio_oe = oe_q;

  wire busy = sr1[0];

  // Timing check: an SCLK edge less than TcsNs before or after a CS rise. A real device can count it as a clock of
  // the command and drop the command (seen on the ZedBoard with the W25Q, 9 Nov 2026: qspi_cmd handover in mode 0).
  // In RTL simulation both edges come in the same time step, so without this check the model accepts it.
  realtime t_sclk = -1.0e9, t_csrise = -1.0e9;
  integer  timing_errors = 0;
  always @(sclk) if ($realtime > 0) begin
    if (csn === 1'b1 && $realtime - t_csrise < TcsNs) begin
      timing_errors = timing_errors + 1;
      $display("[FLASH] TIMING ERROR @%0t: SCLK edge %0.1f ns after the CS rise", $time, $realtime - t_csrise);
      $error("SCLK edge at the CS rise");
    end
    t_sclk = $realtime;
  end
  always @(posedge csn) if ($realtime > 0) begin
    if ($realtime - t_sclk < TcsNs) begin
      timing_errors = timing_errors + 1;
      $display("[FLASH] TIMING ERROR @%0t: SCLK edge %0.1f ns before the CS rise", $time, $realtime - t_sclk);
      $error("SCLK edge at the CS rise");
    end
    t_csrise = $realtime;
  end

  always @(negedge csn) begin
    nclk  = 0;
    cmd   = 8'h00;
    addr  = 24'h0;
    oe_q  = 4'h0;
    npage = 0;
    nwr   = 0;
  end

  // commands that act when CS rises (only 8 or more clocks: a full opcode)
  always @(posedge csn) begin
    oe_q = 4'h0;
    if (nclk >= 8 && !busy && !pd) begin
      case (cmd)
        8'h06: sr1[1] = 1'b1;
        8'h04: sr1[1] = 1'b0;
        8'h66, 8'h99: begin sr1 = 8'h00; end
        8'h02: if (sr1[1] && npage > 0) begin
          for (int i = 0; i < npage && i < 256; i++)
            mem[({addr[23:8], 8'h00} + ((addr[7:0] + i) % 256)) % SizeBytes] =
              mem[({addr[23:8], 8'h00} + ((addr[7:0] + i) % 256)) % SizeBytes] & page[i];
          start_busy(BusyNs);
        end
        8'h20: if (sr1[1] && nclk >= 32) begin
          for (int i = 0; i < 4096; i++) mem[({addr[23:12], 12'h000} + i) % SizeBytes] = 8'hFF;
          start_busy(EraseNs);
        end
        8'hD8: if (sr1[1] && nclk >= 32) begin
          for (int i = 0; i < 65536; i++) mem[({addr[23:16], 16'h0000} + i) % SizeBytes] = 8'hFF;
          start_busy(EraseNs);
        end
        8'hC7, 8'h60: if (sr1[1]) begin
          for (int i = 0; i < SizeBytes; i++) mem[i] = 8'hFF;
          start_busy(EraseNs);
        end
        8'h01: if (sr1[1] && nwr >= 1) begin
          sr1[7:2] = wr1[7:2];
          if (nwr >= 2) sr2 = wr2;
          start_busy(BusyNs);
        end
        8'h31: if (sr1[1] && nwr >= 1) begin sr2 = wr1; start_busy(BusyNs); end
        8'hB9: pd = 1'b1;
        default: ;
      endcase
    end else if (nclk >= 8 && pd && cmd == 8'hAB) pd = 1'b0;
  end

  task automatic start_busy(input real ns);
    sr1[0] = 1'b1;
    sr1[1] = 1'b0;
    fork begin #(ns) sr1[0] = 1'b0; end join_none
  endtask

  always @(posedge sclk) if (!csn) begin
    if (nclk < 8)                                    cmd  = {cmd[6:0], sio_i[0]};
    else if ((cmd == 8'h03 || cmd == 8'h0B || cmd == 8'h02 || cmd == 8'h20 || cmd == 8'hD8) && nclk < 32)
                                                     addr = {addr[22:0], sio_i[0]};
    else if (cmd == 8'hEB && nclk < 14)              addr = {addr[19:0], sio_i[3:0]};
    else begin                                       // data bytes after the address (program) or the opcode
      shreg = {shreg[6:0], sio_i[0]};
      if (cmd == 8'h02 && (nclk - 32) % 8 == 7) begin
        if (npage < 256) page[npage] = shreg;
        npage = npage + 1;
      end
      if ((cmd == 8'h01 || cmd == 8'h31) && (nclk - 8) % 8 == 7) begin
        if (nwr == 0) wr1 = shreg; else if (nwr == 1) wr2 = shreg;
        nwr = nwr + 1;
      end
    end
    nclk = nclk + 1;
  end

  // output bits: shifted out at the falling edge, MSB first, on MISO (quad: one nibble per clock)
  task automatic out_bit(input reg [7:0] b, input integer k);
    out_q = {2'b00, b[7 - (k % 8)], 1'b0};
    oe_q  = 4'b0010;
  endtask

  always @(negedge sclk) if (!csn) begin
    integer k;
    reg [7:0] b;
    if (cmd == 8'h05 && nclk >= 8)                   out_bit(sr1, nclk - 8);
    else if (cmd == 8'h35 && nclk >= 8)              out_bit(sr2, nclk - 8);
    else if (busy || pd) ;                           // nothing else while busy or in power down
    else if (cmd == 8'h9F && nclk >= 8) begin
      k = nclk - 8;
      b = (k < 8) ? 8'hEF : (k < 16) ? 8'h40 : 8'h18;
      out_bit(b, k);
    end else if (cmd == 8'h03 && nclk >= 32) begin
      k = nclk - 32;
      out_bit(mem[(addr + k / 8) % SizeBytes], k);
    end else if (cmd == 8'h0B && nclk >= 40) begin   // 8 dummy clocks
      k = nclk - 40;
      out_bit(mem[(addr + k / 8) % SizeBytes], k);
    end else if (cmd == 8'hEB && nclk >= 20) begin   // one nibble per clock, high nibble first
      k     = nclk - 20;
      b     = mem[(addr + k / 2) % SizeBytes];
      out_q = (k % 2 == 0) ? b[7:4] : b[3:0];
      oe_q  = 4'b1111;
    end
  end
endmodule
