// Behavioural model of the SX1262 SPI command interface (Semtech SX1261/2 datasheet, section 13). Simulation only:
// commands, BUSY, data buffer, registers and the IRQ status, no radio. For the driver sim/sw/fpga_bringup/sx1262.h.
//
//   - SPI mode 0, MSB first. First byte = opcode, then the parameters. MISO sends the status byte, except for the
//     data of the read commands below. MISO is high impedance while NSS is high.
//   - BUSY (to croc rf_dio0_i) is high while NRESET is low, RESET_BUSY_NS after NRESET rises, and from BUSY_RISE_NS
//     to BUSY_RISE_NS + BUSY_NS after each NSS rise (CAL_BUSY_NS for the calibration commands).
//   - Read commands: GetStatus C0 (status at byte 1), GetIrqStatus 12 (IRQ at bytes 2-3), ReadRegister 1D (address at
//     bytes 1-2, data from byte 4), ReadBuffer 1E (offset at byte 1, data from byte 3).
//   - Write commands: WriteRegister 0D (address at bytes 1-2, data from byte 3), WriteBuffer 0E (offset at byte 1, data
//     from byte 2), ClearIrqStatus 02, SetBufferBaseAddress 8F, SetPacketParams 8C (payload length at byte 4).
//   - SetTx 83: the payload (length of SetPacketParams, from the TX base address) goes to `last_tx`, and the IRQ
//     TxDone (bit 0) sets TX_DELAY_NS later (+rf_airtime_ns=<n> replaces it). The chip mode is TX until then.
//   - The other configuration opcodes of the driver are accepted with no effect. Errors are counted and printed:
//     `cmd_while_busy` (NSS falls while BUSY is high: the real chip ignores the command), `unknown_ops`,
//     `short_cmds` (fewer bytes than the opcode needs), and `timing_errors` (an SCLK edge less than TcsNs from an
//     NSS edge: the real chip can count it as a clock, see qspi_cmd handover, 9 Nov 2026).
`timescale 1ns/1ps
module sx1262_model #(
  parameter string Name        = "SX1262",
  parameter real TX_DELAY_NS   = 20000.0,
  parameter real BUSY_RISE_NS  = 100.0,
  parameter real BUSY_NS       = 1000.0,
  parameter real CAL_BUSY_NS   = 20000.0,
  parameter real RESET_BUSY_NS = 10000.0,
  parameter real TcsNs         = 5.0
) (
  input  wire nreset,
  input  wire nss_n,
  input  wire sclk,
  input  wire mosi,
  output wire miso,
  output reg  busy
);
  reg [7:0]  regs [0:4095];                    // register space 0x0000 to 0x0FFF
  reg [7:0]  buffer [0:255];
  reg [7:0]  last_tx [0:255];
  reg [7:0]  cmd [0:299];
  integer    last_tx_len = 0, tx_count = 0;
  integer    cmd_count = 0, cmd_while_busy = 0, unknown_ops = 0, short_cmds = 0, timing_errors = 0;
  reg [15:0] irq = 16'h0000;
  reg [2:0]  chip_mode = 3'd2;                 // 2 STBY_RC, 6 TX
  reg [7:0]  tx_base = 8'h00, payload_len = 8'h00;
  reg        tx_done = 1'b0;                   // toggles when a TX ends
  real       tx_delay_ns = TX_DELAY_NS;
  integer    airtime_ns = 0;
  initial if ($value$plusargs("rf_airtime_ns=%d", airtime_ns)) tx_delay_ns = airtime_ns;

  wire [7:0] status = {1'b0, chip_mode, 3'd0, 1'b0};

  reg [2:0] bitcnt;
  reg [7:0] rx_byte, tx_byte;
  integer   bytecnt;
  reg       miso_r = 1'b0;
  assign miso = nss_n ? 1'bz : miso_r;

  integer i;
  initial begin
    for (i = 0; i < 4096; i = i + 1) regs[i] = 8'h00;
    for (i = 0; i < 256; i = i + 1) buffer[i] = 8'h00;
    regs[16'h0740] = 8'h14; regs[16'h0741] = 8'h24;   // LoRa sync word reset value (private network 0x12)
    busy = 1'b1;
  end

  // reset: BUSY high while NRESET is low and RESET_BUSY_NS after it rises
  always @(negedge nreset) begin
    busy = 1'b1; irq = 16'h0000; chip_mode = 3'd2;
  end
  always @(posedge nreset) busy <= #(RESET_BUSY_NS) 1'b0;

  // the next byte on MISO, from the bytes received so far (cmd[0..k-1]) and the byte index k
  function [7:0] out_byte(input integer k);
    reg [15:0] a;
    begin
      out_byte = status;
      case (cmd[0])
        8'h12: if (k == 2) out_byte = irq[15:8]; else if (k == 3) out_byte = irq[7:0];
        8'h1D: if (k >= 4) begin a = {cmd[1], cmd[2]} + k - 4; out_byte = regs[a[11:0]]; end
        8'h1E: if (k >= 3) out_byte = buffer[(cmd[1] + k - 3) & 8'hFF];
        default: ;
      endcase
    end
  endfunction

  // bytes each opcode needs at least (opcode included); 0 for an unknown opcode
  function integer min_len(input [7:0] op);
    case (op)
      8'hC0, 8'h80, 8'h89, 8'h9D, 8'h96, 8'h8A: min_len = 2;
      8'h12: min_len = 4;
      8'h02, 8'h8E, 8'h8F, 8'h98: min_len = 3;
      8'h97, 8'h86, 8'h95: min_len = 5;
      8'h83: min_len = 4;
      8'h8B, 8'h08: min_len = 9;
      8'h8C: min_len = 7;
      8'h0D: min_len = 4;
      8'h0E: min_len = 3;
      8'h1D: min_len = 5;
      8'h1E: min_len = 4;
      default: min_len = 0;
    endcase
  endfunction

  always @(negedge nss_n) begin
    bitcnt = 3'd0; bytecnt = 0; rx_byte = 8'h00; miso_r = status[7]; tx_byte = status;
    if (nreset === 1'b1 && busy === 1'b1) begin
      cmd_while_busy = cmd_while_busy + 1;
      $display("@%t | [%s] ERROR: NSS falls while BUSY is high", $time, Name);
    end
  end

  always @(posedge sclk) if (!nss_n) begin           // sample MOSI on the rising edge
    rx_byte = {rx_byte[6:0], mosi};
    if (bitcnt == 3'd7) begin
      if (bytecnt < 300) cmd[bytecnt] = rx_byte;
      // writes take effect byte by byte
      if (cmd[0] == 8'h0D && bytecnt >= 3) regs[({cmd[1], cmd[2]} + bytecnt - 3) & 16'h0FFF] = rx_byte;
      if (cmd[0] == 8'h0E && bytecnt >= 2) buffer[(cmd[1] + bytecnt - 2) & 8'hFF] = rx_byte;
      bytecnt = bytecnt + 1;
      tx_byte = out_byte(bytecnt);
    end
    bitcnt = bitcnt + 3'd1;
  end

  // MISO changes on the falling edge (mode 0)
  always @(negedge sclk) if (!nss_n) miso_r = tx_byte[7 - bitcnt];

  // end of a command: execute it, then BUSY
  real busy_ns;
  always @(posedge nss_n) if (nreset === 1'b1 && bytecnt > 0) begin
    cmd_count = cmd_count + 1;
    busy_ns = BUSY_NS;
    if (min_len(cmd[0]) == 0) begin
      unknown_ops = unknown_ops + 1;
      $display("@%t | [%s] ERROR: unknown opcode %02h", $time, Name, cmd[0]);
    end else if (bytecnt < min_len(cmd[0])) begin
      short_cmds = short_cmds + 1;
      $display("@%t | [%s] ERROR: opcode %02h with %0d bytes, needs %0d", $time, Name, cmd[0], bytecnt, min_len(cmd[0]));
    end else begin
      case (cmd[0])
        8'h02: irq = irq & ~{cmd[1], cmd[2]};
        8'h8F: tx_base = cmd[1];
        8'h8C: payload_len = cmd[4];
        8'h80: chip_mode = 3'd2;
        8'h89, 8'h98: busy_ns = CAL_BUSY_NS;
        8'h83: begin
          last_tx_len = payload_len;
          for (i = 0; i < 256; i = i + 1) last_tx[i] = buffer[(tx_base + i) & 8'hFF];
          chip_mode = 3'd6;
          tx_count = tx_count + 1;
          tx_done <= #(tx_delay_ns) ~tx_done;
        end
        default: ;
      endcase
    end
    busy <= #(BUSY_RISE_NS) 1'b1;
    busy <= #(BUSY_RISE_NS + busy_ns) 1'b0;
  end

  always @(tx_done) if (tx_count > 0) begin
    irq = irq | 16'h0001;
    chip_mode = 3'd2;
    $write("@%t | [%s] TX done #%0d, payload %0d bytes:", $time, Name, tx_count, last_tx_len);
    for (i = 0; i < last_tx_len && i < 32; i = i + 1) $write(" %02h", last_tx[i]);
    $display("");
  end

  // an SCLK edge less than TcsNs before or after an NSS edge
  realtime t_sclk = -1.0e9, t_nss = -1.0e9;
  always @(sclk) if ($realtime > 0) begin
    if (nreset === 1'b1 && $realtime - t_nss < TcsNs) begin
      timing_errors = timing_errors + 1;
      $display("@%t | [%s] TIMING ERROR: SCLK edge %0.1f ns after an NSS edge", $time, Name, $realtime - t_nss);
    end
    t_sclk = $realtime;
  end
  always @(nss_n) if ($realtime > 0) begin
    if (nreset === 1'b1 && $realtime - t_sclk < TcsNs) begin
      timing_errors = timing_errors + 1;
      $display("@%t | [%s] TIMING ERROR: SCLK edge %0.1f ns before an NSS edge", $time, Name, $realtime - t_sclk);
    end
    t_nss = $realtime;
  end
endmodule
