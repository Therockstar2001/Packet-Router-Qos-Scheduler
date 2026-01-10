// ============================================================
// Shared types package
// ============================================================
package pkt_pkg;
  typedef struct packed {
    logic        dst;     
    logic [1:0]  prio;    
    logic [7:0]  len;     
  } pkt_hdr_t;
endpackage


// ============================================================
// Streaming packet interface
// ============================================================
interface packet_if #(parameter int DATA_W = 32)
(
  input logic clk,
  input logic rst_n
);
  import pkt_pkg::*;

  logic valid;
  logic ready;

  logic     sof;
  pkt_hdr_t hdr;

  logic [DATA_W-1:0] data;
  logic              last;

  modport src (
    output valid, sof, hdr, data, last,
    input  ready
  );

  modport sink (
    input  valid, sof, hdr, data, last,
    output ready
  );

endinterface


// ============================================================
// Top module (router)
// ============================================================
module packet_router_qos #(
  parameter int DATA_W      = 32,
  parameter int N_IN        = 4,
  parameter int N_OUT       = 2,
  parameter int FIFO_DEPTH  = 8,
  parameter bit USE_QOS     = 1'b1
)(
  input  logic clk,
  input  logic rst_n,

  packet_if.sink in_if  [N_IN],
  packet_if.src  out_if [N_OUT],

  output logic [31:0] drop_count,
  output logic [31:0] in_pkt_count  [N_IN],
  output logic [31:0] out_pkt_count [N_OUT]
);

  import pkt_pkg::*;

  typedef struct packed {
    logic      sof;
    pkt_hdr_t  hdr;
    logic [DATA_W-1:0] data;
    logic      last;
  } beat_t;

  localparam int BEAT_W = $bits(beat_t);

  // FIFO status/data
  logic [N_IN-1:0] fifo_full, fifo_empty;
  beat_t           fifo_rd_data [N_IN];

  // FIFO controls
  logic [N_IN-1:0] fifo_wr_en;
  beat_t           fifo_wr_data [N_IN];

  // FIFO read enable 
  logic [N_IN-1:0] fifo_rd_en;

  // FIFO levels
  logic [$clog2(FIFO_DEPTH+1)-1:0] fifo_level [N_IN];

  // QoS prio vector from FIFO head
  logic [N_IN-1:0][1:0] prio_vec;

  // Requests/grants per output
  logic [N_OUT-1:0][N_IN-1:0] req;
  logic [N_OUT-1:0][N_IN-1:0] gnt;

  // Locking per output
  logic [N_OUT-1:0] locked;
  logic [N_OUT-1:0][$clog2(N_IN)-1:0] locked_in;

  // Per-output rd_en contributions 
  logic [N_OUT-1:0][N_IN-1:0] fifo_rd_en_o;

  // ------------------------------------------------------------
  // FIFO instances + write packing + input ready
  // ------------------------------------------------------------
  genvar i;
  generate
    for (i = 0; i < N_IN; i++) begin : GEN_FIFO
      small_fifo #(
        .WIDTH(BEAT_W),
        .DEPTH(FIFO_DEPTH)
      ) u_fifo (
        .clk   (clk),
        .rst_n (rst_n),

        .wr_en   (fifo_wr_en[i]),
        .wr_data (fifo_wr_data[i]),
        .full    (fifo_full[i]),

        .rd_en   (fifo_rd_en[i]),
        .rd_data (fifo_rd_data[i]),
        .empty   (fifo_empty[i]),

        .level   (fifo_level[i])
      );

      
      always_comb begin
        in_if[i].ready = ~fifo_full[i];
      end

      
      always_comb begin
        fifo_wr_en[i] = in_if[i].valid && in_if[i].ready;

        fifo_wr_data[i].sof  = in_if[i].sof;
        fifo_wr_data[i].hdr  = in_if[i].hdr;
        fifo_wr_data[i].data = in_if[i].data;
        fifo_wr_data[i].last = in_if[i].last;
      end

      
      always_comb begin
        prio_vec[i] = fifo_rd_data[i].hdr.prio;
      end
    end
  endgenerate

  
  integer oi, ii;
  always_comb begin
    req = '0;
    for (oi = 0; oi < N_OUT; oi++) begin
      for (ii = 0; ii < N_IN; ii++) begin
        if (!fifo_empty[ii] &&
            fifo_rd_data[ii].sof &&
            (fifo_rd_data[ii].hdr.dst == oi))
          req[oi][ii] = 1'b1;
      end
    end
  end

  // ------------------------------------------------------------
  // Arbitration per output 
  // grant_accept = "lock acquired now"
  // ------------------------------------------------------------
  genvar og;
  generate
    for (og = 0; og < N_OUT; og++) begin : GEN_ARB
      logic grant_accept;

      always_comb begin
        grant_accept = (!locked[og]) && (|gnt[og]);
      end

      if (USE_QOS) begin
        qos_arbiter #(.N(N_IN), .PRIO_W(2)) u_qos (
          .clk(clk),
          .rst_n(rst_n),
          .req(req[og]),
          .prio(prio_vec),
          .grant_accept(grant_accept),
          .gnt(gnt[og])
        );
      end else begin
        rr_arbiter #(.N(N_IN)) u_rr (
          .clk(clk),
          .rst_n(rst_n),
          .req(req[og]),
          .grant_accept(grant_accept),
          .gnt(gnt[og])
        );
      end
    end
  endgenerate

  // ------------------------------------------------------------
  // Lock acquire/release
  // ------------------------------------------------------------
  genvar lo_g;
  generate
    for (lo_g = 0; lo_g < N_OUT; lo_g++) begin : GEN_LOCK
      integer li;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          locked[lo_g]    <= 1'b0;
          locked_in[lo_g] <= '0;
        end else begin
          // Acquire lock
          if (!locked[lo_g] && (|gnt[lo_g])) begin
            locked[lo_g] <= 1'b1;
            for (li = 0; li < N_IN; li++) begin
              if (gnt[lo_g][li])
                locked_in[lo_g] <= li[$clog2(N_IN)-1:0];
            end
          end

          // Release lock on last beat handshake
          if (locked[lo_g] &&
              out_if[lo_g].valid && out_if[lo_g].ready &&
              fifo_rd_data[locked_in[lo_g]].last) begin
            locked[lo_g] <= 1'b0;
          end
        end
      end
    end
  endgenerate

  // ------------------------------------------------------------
  // Drive outputs + produce per-output rd_en contributions
  // ------------------------------------------------------------
  genvar o_g;
  generate
    for (o_g = 0; o_g < N_OUT; o_g++) begin : GEN_OUT
      always_comb begin
        fifo_rd_en_o[o_g] = '0;

        out_if[o_g].valid = 1'b0;
        out_if[o_g].sof   = 1'b0;
        out_if[o_g].hdr   = '0;
        out_if[o_g].data  = '0;
        out_if[o_g].last  = 1'b0;

        if (locked[o_g]) begin
          out_if[o_g].valid = 1'b1;

          out_if[o_g].sof   = fifo_rd_data[locked_in[o_g]].sof;
          out_if[o_g].hdr   = fifo_rd_data[locked_in[o_g]].hdr;
          out_if[o_g].data  = fifo_rd_data[locked_in[o_g]].data;
          out_if[o_g].last  = fifo_rd_data[locked_in[o_g]].last;

          if (out_if[o_g].ready)
            fifo_rd_en_o[o_g][locked_in[o_g]] = 1'b1;
        end
      end
    end
  endgenerate

  // ------------------------------------------------------------
  // Combine rd_en: fifo_rd_en[i] = OR over all outputs
  // ------------------------------------------------------------
  genvar fi, fo;
  generate
    for (fi = 0; fi < N_IN; fi++) begin : GEN_RDEN_COMBINE
      logic [N_OUT-1:0] tmp;
      for (fo = 0; fo < N_OUT; fo++) begin : GEN_RDEN_TMP
        always_comb tmp[fo] = fifo_rd_en_o[fo][fi];
      end
      always_comb fifo_rd_en[fi] = |tmp;
    end
  endgenerate

  // ------------------------------------------------------------
  // Telemetry counters
  // ------------------------------------------------------------
  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      drop_count <= 32'd0;
      for (k = 0; k < N_IN;  k++) in_pkt_count[k]  <= 32'd0;
      
    end else begin
      
      for (k = 0; k < N_IN; k++) begin
        if (fifo_wr_en[k] && fifo_wr_data[k].sof)
          in_pkt_count[k] <= in_pkt_count[k] + 1;
      end
    end
  end

  genvar oc;
  generate
    for (oc = 0; oc < N_OUT; oc++) begin : GEN_OUT_CNT
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          out_pkt_count[oc] <= 32'd0;
        end else begin
          if (out_if[oc].valid && out_if[oc].ready &&
              fifo_rd_data[locked_in[oc]].last) begin
            out_pkt_count[oc] <= out_pkt_count[oc] + 1;
          end
        end
      end
    end
  endgenerate

endmodule


// ============================================================
// Small FIFO
// ============================================================
module small_fifo #(
  parameter int WIDTH = 64,
  parameter int DEPTH = 8
)(
  input  logic clk,
  input  logic rst_n,

  input  logic             wr_en,
  input  logic [WIDTH-1:0] wr_data,
  output logic             full,

  input  logic             rd_en,
  output logic [WIDTH-1:0] rd_data,
  output logic             empty,

  output logic [$clog2(DEPTH+1)-1:0] level
);

  localparam int AW = (DEPTH <= 2) ? 1 : $clog2(DEPTH);

  logic [WIDTH-1:0] mem [DEPTH];
  logic [AW-1:0]    wptr, rptr;

  logic do_wr, do_rd;
  assign do_wr = wr_en && !full;
  assign do_rd = rd_en && !empty;

  always_comb begin
    empty = (level == 0);
    full  = (level == DEPTH);
  end

  always_comb begin
    rd_data = mem[rptr];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr  <= '0;
      rptr  <= '0;
      level <= '0;
    end else begin
      if (do_wr) begin
        mem[wptr] <= wr_data;
        wptr <= (wptr == DEPTH-1) ? '0 : (wptr + 1'b1);
      end

      if (do_rd) begin
        rptr <= (rptr == DEPTH-1) ? '0 : (rptr + 1'b1);
      end

      unique case ({do_wr, do_rd})
        2'b10: level <= level + 1'b1;
        2'b01: level <= level - 1'b1;
        default: level <= level;
      endcase
    end
  end

endmodule


// ============================================================
// Round Robin Arbiter
// ============================================================
module rr_arbiter #(
  parameter int N = 4
)(
  input  logic clk,
  input  logic rst_n,

  input  logic [N-1:0] req,
  input  logic         grant_accept,

  output logic [N-1:0] gnt
);

  logic [$clog2(N)-1:0] ptr;

  integer j;
  always_comb begin
    gnt = '0;
    for (j = 0; j < N; j++) begin
      int idx;
      idx = (ptr + j) % N;
      if (req[idx]) begin
        gnt[idx] = 1'b1;
        break;
      end
    end
  end

  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ptr <= '0;
    end else if (grant_accept && |gnt) begin
      for (k = 0; k < N; k++) begin
        if (gnt[k]) ptr <= (k == N-1) ? '0 : (k + 1'b1);
      end
    end
  end

endmodule


// ============================================================
// QoS Arbiter (Priority + RR tie-break)
// ============================================================
module qos_arbiter #(
  parameter int N = 4,
  parameter int PRIO_W = 2
)(
  input  logic clk,
  input  logic rst_n,

  input  logic [N-1:0] req,
  input  logic [N-1:0][PRIO_W-1:0] prio,

  input  logic grant_accept,
  output logic [N-1:0] gnt
);

  logic [$clog2(N)-1:0] ptr;

  logic [PRIO_W-1:0] max_prio;
  integer a;
  always_comb begin
    max_prio = '0;
    for (a = 0; a < N; a++) begin
      if (req[a] && (prio[a] > max_prio)) max_prio = prio[a];
    end
  end

  integer b;
  always_comb begin
    gnt = '0;
    for (b = 0; b < N; b++) begin
      int idx;
      idx = (ptr + b) % N;
      if (req[idx] && (prio[idx] == max_prio)) begin
        gnt[idx] = 1'b1;
        break;
      end
    end
  end

  integer c;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ptr <= '0;
    end else if (grant_accept && |gnt) begin
      for (c = 0; c < N; c++) begin
        if (gnt[c]) ptr <= (c == N-1) ? '0 : (c + 1'b1);
      end
    end
  end

endmodule
