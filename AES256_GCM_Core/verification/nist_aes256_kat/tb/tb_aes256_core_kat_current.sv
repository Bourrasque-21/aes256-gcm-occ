`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// NIST AESAVS known-answer test for this repository's aes256_core.
// Reads NIST ENCRYPT vectors directly from .rsp files.
//   +VECDIR=<dir>    Override the vector directory.
//   KAT_MAX_VECTORS  Limit vectors per file; 0 runs all 405.
//   KAT_DUMP_VCD     Enable a portable waveform dump.
`ifndef KAT_MAX_VECTORS
  `define KAT_MAX_VECTORS 0
`endif

module tb_aes256_core_kat;

  localparam int MAX_VEC = `KAT_MAX_VECTORS;

  // Search the launcher workspace, then a Vivado simulation tree.
  localparam int NUM_SEARCH = 2;
  string search_dirs [NUM_SEARCH] = '{
      ".",
      "../../../../../../verification/nist_aes256_kat/kat_vectors"
  };
  localparam int    NUM_FILES      = 4;

  string vec_files [NUM_FILES] = '{
      "ECBGFSbox256.rsp",
      "ECBKeySbox256.rsp",
      "ECBVarKey256.rsp",
      "ECBVarTxt256.rsp"
  };

  // ---------------------------------------------------------------- clocking
  logic clk = 1'b0;
  always #5 clk = ~clk;          // 100 MHz

  logic rst_n = 1'b0;

  // ------------------------------------------------------------------- DUT
  logic [255:0]  key_in    = 256'h0;
  logic          data_start = 1'b0;
  logic [127:0]  data_in    = 128'h0;
  logic          data_busy;
  logic          data_done;
  logic [127:0]  data_out;

  aes256_core u_dut (
      .clk(clk), .rst_n(rst_n), .start(data_start),
      .plaintext(data_in), .key(key_in),
      .ciphertext(data_out), .busy(data_busy), .done(data_done)
  );

  // --------------------------------------------------------------- tallies
  int total_vectors = 0;
  int total_fail    = 0;
  int expand_count  = 0;

  logic [255:0] loaded_key = 256'hx;
  bit           key_loaded = 1'b0;

  // ---------------------------------------------------------------- helpers
  function automatic bit has_prefix(input string s, input string p);
    if (s.len() < p.len()) return 1'b0;
    return (s.substr(0, p.len()-1) == p);
  endfunction

  // Return true when the first vector file is readable.
  function automatic bit dir_has_vectors(input string dir);
    int fd;
    fd = $fopen({dir, "/", vec_files[0]}, "r");
    if (fd == 0) return 1'b0;
    $fclose(fd);
    return 1'b1;
  endfunction

  // Change keys only when needed; the DUT caches expanded round keys.
  task automatic load_key(input logic [255:0] k);
    if (key_loaded && (k === loaded_key)) return;
    @(negedge clk);
    key_in       = k;
    loaded_key   = k;
    key_loaded   = 1'b1;
    expand_count = expand_count + 1;
  endtask

  // Encrypt one block and sample the result after done.
  task automatic encrypt_block(input logic [127:0] pt, output logic [127:0] ct);
    @(negedge clk);
    data_in    = pt;
    data_start = 1'b1;
    @(negedge clk);
    data_start = 1'b0;
    do @(negedge clk); while (!data_done);
    ct = data_out;
  endtask

  // ------------------------------------------------------------ .rsp reader
  task automatic run_file(input string path, input string label);
    int           fd;
    int           code;
    string        line;
    bit           in_encrypt;
    logic [255:0] k;
    logic [127:0] p;
    logic [127:0] c;
    logic [127:0] got;
    int           count;
    int           fails;

    in_encrypt = 1'b0;
    count      = 0;
    fails      = 0;

    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "[KAT] cannot open vector file: %s", path);

    forever begin
      line = "";
      code = $fgets(line, fd);
      if (code <= 0) break;

      if (has_prefix(line, "[ENCRYPT]")) begin
        in_encrypt = 1'b1;
      end else if (has_prefix(line, "[DECRYPT]")) begin
        // Encryption-only DUT.
        break;
      end else if (in_encrypt) begin
        if ($sscanf(line, "KEY = %h", k) == 1) begin
          // Hold until the vector is complete.
        end else if ($sscanf(line, "PLAINTEXT = %h", p) == 1) begin
          // Hold until the vector is complete.
        end else if ($sscanf(line, "CIPHERTEXT = %h", c) == 1) begin
          // Run after KEY, PLAINTEXT, and CIPHERTEXT are available.
          load_key(k);
          encrypt_block(p, got);
          count = count + 1;
          if (got !== c) begin
            fails = fails + 1;
            if (fails <= 5)
              $display("  [FAIL] %s #%0d\n         KEY = %064h\n         PT  = %032h\n         EXP = %032h\n         GOT = %032h",
                       label, count-1, k, p, c, got);
          end
          if ((MAX_VEC != 0) && (count >= MAX_VEC)) break;
        end
      end
    end
    $fclose(fd);

    $display("  %-18s vectors=%0d  fail=%0d  %s",
             label, count, fails, (fails == 0) ? "PASS" : "*** FAIL ***");

    total_vectors = total_vectors + count;
    total_fail    = total_fail + fails;
  endtask

  // ------------------------------------------------------------------- main
  initial begin
    string vec_dir;
    string path;

    if ($value$plusargs("VECDIR=%s", vec_dir)) begin
      if (!dir_has_vectors(vec_dir))
        $fatal(1, "[KAT] cannot open %s in +VECDIR=%s",
               vec_files[0], vec_dir);
    end else begin
      vec_dir = "";
      foreach (search_dirs[i])
        if (dir_has_vectors(search_dirs[i])) begin
          vec_dir = search_dirs[i];
          break;
        end
      if (vec_dir == "") begin
        $display("[KAT] vector directory not found.  tried:");
        foreach (search_dirs[i]) $display("        %s", search_dirs[i]);
        $fatal(1, "[KAT] no .rsp files found - specify +VECDIR=<dir>");
      end
    end

`ifdef KAT_DUMP_VCD
    $dumpfile("aes_core_kat.vcd");
    $dumpvars(0, tb_aes256_core_kat);
`endif
`ifdef KAT_DUMP_FSDB
    // Requires the Verdi PLI.
    $fsdbDumpfile("aes_core_kat.fsdb");
    $fsdbDumpvars(0, tb_aes256_core_kat);
`endif

    $display("========================================================");
    $display(" AES-256 ECB Known Answer Test (NIST AESAVS)");
    $display(" DUT        : rtl/aes256_core.sv");
    $display(" Vector dir : %s", vec_dir);
    if (MAX_VEC != 0)
      $display(" NOTE       : limited to %0d vectors per file - waveform run, NOT full verification", MAX_VEC);
    $display("========================================================");

    repeat (8) @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(negedge clk);

    foreach (vec_files[i]) begin
      path = {vec_dir, "/", vec_files[i]};
      run_file(path, vec_files[i]);
    end

    $display("--------------------------------------------------------");
    $display(" TOTAL      : %0d vectors, %0d fail", total_vectors, total_fail);
    $display(" key expand : %0d times", expand_count);
    $display("--------------------------------------------------------");

    // Full runs must parse all 405 vectors.
    if ((MAX_VEC == 0) && (total_vectors != 405))
      $fatal(1, "[KAT] expected 405 ENCRYPT vectors, parsed %0d - parse failed", total_vectors);
    if (total_fail != 0)
      $fatal(1, "[KAT] FAILED: %0d/%0d mismatch", total_fail, total_vectors);

    if (MAX_VEC != 0)
      $display(" RESULT     : PASS - %0d vectors matched (LIMITED RUN, not full verification)",
               total_vectors);
    else
      $display(" RESULT     : PASS - all %0d NIST AESAVS vectors matched", total_vectors);
    $display("========================================================");
    $finish;
  end

  initial begin
    #50000000;
    $fatal(1, "[KAT] simulation timeout");
  end

endmodule
