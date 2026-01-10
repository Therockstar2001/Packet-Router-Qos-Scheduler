module tb_top;

  localparam int DATA_W = 32;
  localparam int N_IN   = 4;
  localparam int N_OUT  = 2;

  logic clk;
  logic rst_n;

  // Interfaces
  packet_if #(DATA_W) in_if  [N_IN] (.*);
  packet_if #(DATA_W) out_if [N_OUT] (.*);

  // DUT outputs
  logic [31:0] drop_count;
  logic [31:0] in_pkt_count  [N_IN];
  logic [31:0] out_pkt_count [N_OUT];

  // Monitor variables
  int out0_packets, out1_packets;
  int out0_first_prio_seen;
  bit out0_first_prio_valid;

  // Test2 fairness counters
  int seen_1000, seen_2000;

  // Test3 stall-check counters
  int stall_cycles_seen;
  bit stall_violation;

  // -----------------------------
  // Clock generation
  // -----------------------------
  initial clk = 0;
  always #5 clk = ~clk;

  // -----------------------------
  // Reset
  // -----------------------------
  initial begin
    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
  end

  // -----------------------------
  // VCD dump (for EPWave)
  // -----------------------------
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, tb_top);
  end

  // -----------------------------
  // DUT
  // -----------------------------
  packet_router_qos #(
    .DATA_W(DATA_W),
    .N_IN(N_IN),
    .N_OUT(N_OUT),
    .FIFO_DEPTH(8),
    .USE_QOS(1'b1)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .in_if(in_if),
    .out_if(out_if),
    .drop_count(drop_count),
    .in_pkt_count(in_pkt_count),
    .out_pkt_count(out_pkt_count)
  );

  // -----------------------------
  // Init inputs (avoid Xs)
  // -----------------------------
  genvar gi;
  generate
    for (gi = 0; gi < N_IN; gi++) begin : GEN_INIT_IN
      initial begin
        in_if[gi].valid = 0;
        in_if[gi].sof   = 0;
        in_if[gi].hdr   = '0;
        in_if[gi].data  = '0;
        in_if[gi].last  = 0;
      end
    end
  endgenerate

  // -----------------------------
  // Outputs ready defaults
  // -----------------------------
  initial begin
    out_if[0].ready = 1'b1;
    out_if[1].ready = 1'b1;
  end

  // ===========================================================
  // Timeout waiters 
  // ===========================================================
  task automatic wait_ready0(input int max_cycles);
    int c;
    begin
      c = 0;
      while (!in_if[0].ready) begin
        @(posedge clk);
        c++;
        if (c >= max_cycles) begin
          $display("TIMEOUT: in_if[0].ready stayed LOW for %0d cycles", max_cycles);
          $finish;
        end
      end
    end
  endtask

  task automatic wait_ready1(input int max_cycles);
    int c;
    begin
      c = 0;
      while (!in_if[1].ready) begin
        @(posedge clk);
        c++;
        if (c >= max_cycles) begin
          $display("TIMEOUT: in_if[1].ready stayed LOW for %0d cycles", max_cycles);
          $finish;
        end
      end
    end
  endtask

  // ===========================================================
  // Send packet on IN0
  // ===========================================================
  task automatic send_packet_in0(
    input int dst,
    input int prio,
    input int payload_len,
    input logic [31:0] base_word
  );
    int b;

    // HEADER
    in_if[0].valid    = 1;
    in_if[0].sof      = 1;
    in_if[0].hdr.dst  = dst;
    in_if[0].hdr.prio = prio;
    in_if[0].hdr.len  = payload_len[7:0];
    in_if[0].data     = base_word;
    in_if[0].last     = 0;

    wait_ready0(200);
    @(posedge clk);

    // PAYLOAD
    for (b = 0; b < payload_len; b++) begin
      in_if[0].sof  = 0;
      in_if[0].data = base_word + (b + 1);
      in_if[0].last = (b == payload_len - 1);

      wait_ready0(200);
      @(posedge clk);
    end

    // stop driving
    in_if[0].valid = 0;
    in_if[0].sof   = 0;
    in_if[0].last  = 0;
  endtask

  // ===========================================================
  // Send packet on IN1
  // ===========================================================
  task automatic send_packet_in1(
    input int dst,
    input int prio,
    input int payload_len,
    input logic [31:0] base_word
  );
    int b;

    // HEADER
    in_if[1].valid    = 1;
    in_if[1].sof      = 1;
    in_if[1].hdr.dst  = dst;
    in_if[1].hdr.prio = prio;
    in_if[1].hdr.len  = payload_len[7:0];
    in_if[1].data     = base_word;
    in_if[1].last     = 0;

    wait_ready1(200);
    @(posedge clk);

    // PAYLOAD
    for (b = 0; b < payload_len; b++) begin
      in_if[1].sof  = 0;
      in_if[1].data = base_word + (b + 1);
      in_if[1].last = (b == payload_len - 1);

      wait_ready1(200);
      @(posedge clk);
    end

    // stop driving
    in_if[1].valid = 0;
    in_if[1].sof   = 0;
    in_if[1].last  = 0;
  endtask

  // ===========================================================
  // Output monitor + SOF tracking + stall stability checker
  // ===========================================================
  logic              hold_sof, hold_last;
  logic [31:0]       hold_data;
  logic [7:0]        hold_dst, hold_prio, hold_len;
  bit                hold_valid;

  always @(posedge clk) begin
    // OUT0 prints on real transfers only
    if (out_if[0].valid && out_if[0].ready) begin
      $display("T=%0t OUT0 sof=%0d last=%0d data=%h dst=%0d prio=%0d",
               $time, out_if[0].sof, out_if[0].last, out_if[0].data,
               out_if[0].hdr.dst, out_if[0].hdr.prio);

      // Test1: first prio seen
      if (out_if[0].sof && !out0_first_prio_valid) begin
        out0_first_prio_seen  = out_if[0].hdr.prio;
        out0_first_prio_valid = 1'b1;
      end

      // Test2 fairness tracking (SOF only)
      if (out_if[0].sof) begin
        $display(">>> OUT0 SOF @T=%0t header_data=%h prio=%0d",
                 $time, out_if[0].data, out_if[0].hdr.prio);

        if (out_if[0].data[31:28] == 4'h1) seen_1000++;
        if (out_if[0].data[31:28] == 4'h2) seen_2000++;
      end

      if (out_if[0].last) out0_packets++;
    end

    
    if (out_if[1].valid && out_if[1].ready) begin
      $display("T=%0t OUT1 sof=%0d last=%0d data=%h dst=%0d prio=%0d",
               $time, out_if[1].sof, out_if[1].last, out_if[1].data,
               out_if[1].hdr.dst, out_if[1].hdr.prio);
      if (out_if[1].last) out1_packets++;
    end

    // -------------------------
    // TEST3 stall stability check
    // -------------------------
    if (out_if[0].valid && !out_if[0].ready) begin
      stall_cycles_seen++;

      if (!hold_valid) begin
        hold_valid = 1'b1;
        hold_sof   = out_if[0].sof;
        hold_last  = out_if[0].last;
        hold_data  = out_if[0].data;
        hold_dst   = out_if[0].hdr.dst;
        hold_prio  = out_if[0].hdr.prio;
        hold_len   = out_if[0].hdr.len;
      end else begin
        // compare against latched beat
        if (out_if[0].sof      !== hold_sof  ||
            out_if[0].last     !== hold_last ||
            out_if[0].data     !== hold_data ||
            out_if[0].hdr.dst  !== hold_dst  ||
            out_if[0].hdr.prio !== hold_prio ||
            out_if[0].hdr.len  !== hold_len) begin
          stall_violation = 1'b1;
        end
      end
    end else begin
      // leaving stall region -> reset hold latch
      hold_valid = 1'b0;
    end
  end

  // ===========================================================
  // TEST3 helper: force backpressure on OUT0 mid-packet
  // ===========================================================
  task automatic force_out0_stall_mid_packet(
    input int stall_cycles
  );
    int i;

    
    do @(posedge clk); while (!(out_if[0].valid && out_if[0].ready && out_if[0].sof));

    
    do @(posedge clk); while (!(out_if[0].valid && out_if[0].ready && !out_if[0].sof));

    
    out_if[0].ready = 1'b0;
    for (i = 0; i < stall_cycles; i++) @(posedge clk);
    out_if[0].ready = 1'b1;
  endtask

  // ===========================================================
  // TESTS
  // ===========================================================
  initial begin
    @(posedge rst_n);

    // -----------------------------
    // TEST 1: QoS priority wins
    // -----------------------------
    out0_packets = 0;
    out1_packets = 0;
    out0_first_prio_valid = 0;
    out0_first_prio_seen  = -1;

    $display("\n=== TEST 1: QoS priority wins (prio3 over prio1) to OUT0 ===");

    fork
      send_packet_in0(0, 1, 2, 32'h1000_0000);
      send_packet_in1(0, 3, 2, 32'h2000_0000);
    join

    repeat (30) @(posedge clk);

    if (out0_first_prio_seen !== 3) begin
      $display("FAIL(TEST1): OUT0 first packet prio=%0d, expected 3", out0_first_prio_seen);
      $finish;
    end else begin
      $display("PASS(TEST1): OUT0 first packet prio=3 as expected");
    end

    $display("DUT counters: in_pkt_count[0]=%0d in_pkt_count[1]=%0d out_pkt_count[0]=%0d out_pkt_count[1]=%0d",
             in_pkt_count[0], in_pkt_count[1], out_pkt_count[0], out_pkt_count[1]);

    // -----------------------------
    // TEST 2: RR fairness under tie 
    // -----------------------------
    $display("\n=== TEST 2: RR fairness under tie (same prio=2 to OUT0) ===");
    $display("Goal: OUT0 should show BOTH 1000_xxxx and 2000_xxxx at SOF (no starvation).");

    seen_1000 = 0;
    seen_2000 = 0;

    repeat (6) begin
      fork
        send_packet_in0(0, 2, 1, 32'h1000_0100);
        send_packet_in1(0, 2, 1, 32'h2000_0200);
      join
      repeat (20) @(posedge clk);
    end

    if ((seen_1000 > 0) && (seen_2000 > 0)) begin
      $display("PASS(TEST2): RR fairness verified (seen_1000=%0d, seen_2000=%0d)", seen_1000, seen_2000);
    end else begin
      $display("FAIL(TEST2): starvation detected (seen_1000=%0d, seen_2000=%0d)", seen_1000, seen_2000);
      $finish;
    end

    // -----------------------------
    // TEST 3: Backpressure stall test on OUT0
    // -----------------------------
    $display("\n=== TEST 3: Backpressure stall on OUT0 mid-packet ===");
    $display("Goal: When out_if[0].ready=0, OUT0 must HOLD the same beat stable until ready returns.");

    // reset stall metrics
    stall_cycles_seen = 0;
    stall_violation   = 0;
    hold_valid        = 0;

    // Ensure ready starts high
    out_if[0].ready = 1'b1;

    fork
      
      send_packet_in0(0, 2, 5, 32'h3000_0000); // header + 5 payload beats
      
      force_out0_stall_mid_packet(8);
    join

    
    repeat (40) @(posedge clk);

    if (stall_cycles_seen < 2) begin
      $display("FAIL(TEST3): Did not observe a real stall (stall_cycles_seen=%0d)", stall_cycles_seen);
      $finish;
    end

    if (stall_violation) begin
      $display("FAIL(TEST3): During stall, OUT0 changed signals while ready=0 (protocol violation).");
      $finish;
    end else begin
      $display("PASS(TEST3): Stall held stable for %0d cycles; no signal changes while ready=0", stall_cycles_seen);
    end

    $display("\n ALL TESTS PASSED (TEST1/TEST2/TEST3)");
    $finish;
  end

endmodule
