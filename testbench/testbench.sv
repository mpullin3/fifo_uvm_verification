//============================================================================
// FIFO UVM TESTBENCH - single-file version for EDA Playground
// Michael Pullin - week 11 project, combined in compile order.
//
// Every change from the original week 11 files is marked "// FIX:".
// Default test: fifo_full_drain_test. Pick another with +UVM_TESTNAME=<name>.
//============================================================================

`include "uvm_macros.svh"
import uvm_pkg::*;

//============================================================================
// INTERFACE
//============================================================================
interface fifo_if #(int DATA_WIDTH = 8);
  logic clk;
  logic resetN;

  logic write_en;
  logic [DATA_WIDTH-1:0] write_data;
  logic full;

  logic read_en;
  logic [DATA_WIDTH-1:0] read_data;
  logic empty;

  logic [4:0] occupancy;  // For 16 deep FIFO

  // Driver clocking block
  clocking cb @(posedge clk);
    output write_en, write_data;
    output read_en;
    input full, empty;
    input read_data, occupancy;
  endclocking

  // FIX: monitor clocking block. The original monitor read raw signals at
  // posedge clk, which races with the driver. Sampling through a clocking
  // block gives the values the DUT actually saw at that edge.
  clocking mon_cb @(posedge clk);
    input resetN;
    input write_en, write_data, full;
    input read_en, read_data, empty, occupancy;
  endclocking

  modport driver  (clocking cb, input full, empty, occupancy);
  modport monitor (clocking mon_cb);
endinterface

// FIX: fifo_config.sv and fifo_configuration.sv declared the same class twice
// (a compile error) and nothing used it, so both are left out.

//============================================================================
// TRANSACTIONS
//============================================================================
class fifo_transaction extends uvm_sequence_item;
  `uvm_object_utils(fifo_transaction)

  rand int delay_cycles;  // FIX: was not "rand", so it never randomized

  constraint delay_c { delay_cycles inside {[0:5]}; }

  function new(string name = "fifo_transaction");
    super.new(name);
    delay_cycles = 0;
  endfunction

  function void do_print(uvm_printer printer);
    super.do_print(printer);
    printer.print_field("delay_cycles", delay_cycles, 32);
  endfunction

  function string convert2string();
    return $sformatf("delay=%0d", delay_cycles);
  endfunction
endclass

class fifo_write_transaction extends fifo_transaction;
  `uvm_object_utils(fifo_write_transaction)

  rand logic [7:0] write_data;

  constraint write_data_c { write_data inside {[0:255]}; }

  function new(string name = "fifo_write_transaction");
    super.new(name);
  endfunction

  function void do_print(uvm_printer printer);
    super.do_print(printer);
    printer.print_field("write_data", write_data, 8);
  endfunction

  function string convert2string();
    return $sformatf("WRITE: data=%h, delay=%0d", write_data, delay_cycles);
  endfunction
endclass

class fifo_read_transaction extends fifo_transaction;
  `uvm_object_utils(fifo_read_transaction)

  logic [7:0] read_data;
  logic data_valid;

  function new(string name = "fifo_read_transaction");
    super.new(name);
    data_valid = 0;
    read_data = 0;
  endfunction

  function void do_print(uvm_printer printer);
    super.do_print(printer);
    printer.print_field("read_data", read_data, 8);
    printer.print_field("data_valid", data_valid, 1);
  endfunction

  function string convert2string();
    return $sformatf("READ: data=%h, valid=%b, delay=%0d", read_data, data_valid, delay_cycles);
  endfunction
endclass

//============================================================================
// SEQUENCER
//============================================================================
class fifo_sequencer extends uvm_sequencer #(fifo_transaction);
  `uvm_component_utils(fifo_sequencer)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass

//============================================================================
// DRIVER
//============================================================================
class fifo_driver extends uvm_driver #(fifo_transaction);
  `uvm_component_utils(fifo_driver)

  virtual fifo_if vif;

  // FIX: the original driver waited forever when asked to read an empty FIFO
  // (or write a full one). With one driver, nothing else can change the FIFO
  // while it waits, so the test hung. Now it gives up after MAX_WAIT cycles.
  int MAX_WAIT = 20;

  int write_count = 0;
  int read_count = 0;
  int skipped_writes = 0;
  int skipped_reads = 0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual fifo_if)::get(this, "", "vif", vif))
      `uvm_fatal("DRV", "Virtual interface 'vif' not found in config_db!")
  endfunction

  task run_phase(uvm_phase phase);
    vif.cb.write_en   <= 0;
    vif.cb.write_data <= 0;
    vif.cb.read_en    <= 0;

    // FIX: wait for reset to finish before driving anything
    wait (vif.resetN === 1'b1);
    @(vif.cb);

    forever begin
      fifo_transaction txn;
      seq_item_port.get_next_item(txn);
      apply_transaction(txn);
      seq_item_port.item_done();
    end
  endtask

  task apply_transaction(fifo_transaction txn);
    // FIX: $cast needs a variable as its destination, not a class name.
    // The original "$cast(fifo_write_transaction, txn)" does not compile.
    fifo_write_transaction wtxn;
    fifo_read_transaction  rtxn;

    if ($cast(wtxn, txn))
      apply_write_transaction(wtxn);
    else if ($cast(rtxn, txn))
      apply_read_transaction(rtxn);
    else
      `uvm_warning("DRV", "Unknown transaction type!")
  endtask

  task apply_write_transaction(fifo_write_transaction wtxn);
    int wait_cycles = 0;

    repeat (wtxn.delay_cycles) @(vif.cb);

    while (vif.cb.full && wait_cycles < MAX_WAIT) begin
      @(vif.cb);
      wait_cycles++;
    end
    if (vif.cb.full) begin
      skipped_writes++;
      `uvm_info("DRV", $sformatf("FIFO still full after %0d cycles, skipping write", MAX_WAIT), UVM_MEDIUM)
      return;
    end

    vif.cb.write_en   <= 1;
    vif.cb.write_data <= wtxn.write_data;
    @(vif.cb);
    vif.cb.write_en   <= 0;
    @(vif.cb); // Fix #2: added to fix driver race, idle cycle so full/empty
    		   // update before the next flag check.

    write_count++;
    `uvm_info("DRV", $sformatf("WRITE #%0d: data=%h (waited %0d cycles)",
      write_count, wtxn.write_data, wait_cycles), UVM_HIGH)
  endtask

  task apply_read_transaction(fifo_read_transaction rtxn);
    int wait_cycles = 0;

    repeat (rtxn.delay_cycles) @(vif.cb);

    while (vif.cb.empty && wait_cycles < MAX_WAIT) begin
      @(vif.cb);
      wait_cycles++;
    end
    if (vif.cb.empty) begin
      skipped_reads++;
      `uvm_info("DRV", $sformatf("FIFO still empty after %0d cycles, skipping read", MAX_WAIT), UVM_MEDIUM)
      return;
    end

    vif.cb.read_en <= 1;
    @(vif.cb);
    rtxn.read_data  = vif.cb.read_data;
    rtxn.data_valid = 1;
    vif.cb.read_en <= 0;
    @(vif.cb); // Fix #2: idle cycle so full/empty update before the next 
    		   // flag check

    read_count++;
    `uvm_info("DRV", $sformatf("READ #%0d: data=%h (waited %0d cycles)",
      read_count, rtxn.read_data, wait_cycles), UVM_HIGH)
  endtask

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("DRV", $sformatf("Writes applied: %0d, reads applied: %0d, skipped writes: %0d, skipped reads: %0d",
      write_count, read_count, skipped_writes, skipped_reads), UVM_LOW)
  endfunction
endclass

//============================================================================
// MONITOR
//============================================================================
class fifo_monitor extends uvm_monitor;
  `uvm_component_utils(fifo_monitor)

  virtual fifo_if vif;

  uvm_analysis_port #(fifo_write_transaction) write_ap;
  uvm_analysis_port #(fifo_read_transaction)  read_ap;

  // FIX: state variables moved above the covergroups that use them, so every
  // simulator sees them declared before use.
  // FIX: the pointer variables were never updated in the original, so address
  // coverage was stuck at 0. The DUT's pointers aren't on the interface, so
  // the monitor now tracks them itself from observed writes and reads.
  logic [3:0] current_wr_ptr = 0;
  logic [3:0] current_rd_ptr = 0;
  logic [7:0] current_write_data = 0;
  logic [7:0] current_read_data = 0;
  logic [4:0] current_occupancy = 0;
  logic is_full = 0;
  logic is_empty = 1;
  logic write_occurs = 0;
  logic read_occurs = 0;

  int write_count = 0;
  int read_count = 0;
  int concurrent_rw = 0;

  covergroup write_cov;
    write_addr: coverpoint current_wr_ptr {
      bins addr_low  = {[0:7]};
      bins addr_high = {[8:15]};
      bins addr_min  = {0};
      bins addr_max  = {15};
    }
    write_data: coverpoint current_write_data {
      bins data_zeros = {8'h00};
      bins data_ones  = {8'hFF};
      bins data_low   = {[0:127]};
      bins data_high  = {[128:255]};
    }
  endgroup

  covergroup read_cov;
    read_addr: coverpoint current_rd_ptr {
      bins addr_low  = {[0:7]};
      bins addr_high = {[8:15]};
      bins addr_min  = {0};
      bins addr_max  = {15};
    }
    read_data: coverpoint current_read_data {
      bins data_zeros = {8'h00};
      bins data_ones  = {8'hFF};
      bins data_low   = {[0:127]};
      bins data_high  = {[128:255]};
    }
  endgroup

  covergroup flag_cov;
    full_flag: coverpoint is_full {
      bins full_asserts   = {1};
      bins full_deasserts = {0};
    }
    empty_flag: coverpoint is_empty {
      bins empty_asserts   = {1};
      bins empty_deasserts = {0};
    }
    both_flags: cross full_flag, empty_flag {
      illegal_bins impossible = binsof(full_flag) intersect {1} && binsof(empty_flag) intersect {1};
    }
  endgroup

  covergroup occupancy_cov;
    occupancy_level: coverpoint current_occupancy {
      bins empty         = {0};
      bins quarter       = {[1:4]};
      bins half          = {[5:8]};
      bins three_quarter = {[9:12]};
      bins almost_full   = {[13:15]};
      bins full          = {16};
    }
  endgroup

  covergroup operation_cov;
    write_operation: coverpoint write_occurs {
      bins write_happens = {1};
      bins no_write      = {0};
    }
    read_operation: coverpoint read_occurs {
      bins read_happens = {1};
      bins no_read      = {0};
    }
    concurrent: cross write_operation, read_operation;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    write_cov     = new();
    read_cov      = new();
    flag_cov      = new();
    occupancy_cov = new();
    operation_cov = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    write_ap = new("write_ap", this);
    read_ap  = new("read_ap", this);
    if (!uvm_config_db #(virtual fifo_if)::get(this, "", "vif", vif))
      `uvm_fatal("MON", "Virtual interface 'vif' not found in config_db!")
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);

      // FIX: ignore cycles while reset is active
      if (vif.mon_cb.resetN !== 1'b1) begin
        current_wr_ptr = 0;
        current_rd_ptr = 0;
        continue;
      end

      capture_interface_state();

      // FIX: sample write/read coverage only on cycles where a write/read
      // actually happens. The original sampled every cycle, which counted
      // idle cycles as writes and reads.
      if (write_occurs) write_cov.sample();
      if (read_occurs)  read_cov.sample();
      flag_cov.sample();
      occupancy_cov.sample();
      operation_cov.sample();

      if (write_occurs) monitor_write();
      if (read_occurs)  monitor_read();

      if (write_occurs && read_occurs) concurrent_rw++;
    end
  endtask

  function void capture_interface_state();
    current_write_data = vif.mon_cb.write_data;
    current_read_data  = vif.mon_cb.read_data;
    current_occupancy  = vif.mon_cb.occupancy;
    is_full            = vif.mon_cb.full;
    is_empty           = vif.mon_cb.empty;
    write_occurs       = vif.mon_cb.write_en && !vif.mon_cb.full;
    read_occurs        = vif.mon_cb.read_en  && !vif.mon_cb.empty;
  endfunction

  function void monitor_write();
    fifo_write_transaction wtxn = fifo_write_transaction::type_id::create("wtxn");
    wtxn.write_data = current_write_data;
    write_ap.write(wtxn);
    write_count++;
    current_wr_ptr++;  // wraps at 16 automatically (4 bits)
    `uvm_info("MON", $sformatf("WRITE #%0d: data=%h, occupancy=%0d",
      write_count, current_write_data, current_occupancy), UVM_HIGH)
  endfunction

  function void monitor_read();
    fifo_read_transaction rtxn = fifo_read_transaction::type_id::create("rtxn");
    rtxn.read_data  = current_read_data;
    rtxn.data_valid = 1;
    read_ap.write(rtxn);
    read_count++;
    current_rd_ptr++;
    `uvm_info("MON", $sformatf("READ #%0d: data=%h, occupancy=%0d",
      read_count, current_read_data, current_occupancy), UVM_HIGH)
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("MON", $sformatf("Writes observed: %0d, reads observed: %0d, concurrent r/w: %0d",
      write_count, read_count, concurrent_rw), UVM_LOW)
    `uvm_info("COV", "=== COVERAGE SUMMARY ===", UVM_LOW)
    `uvm_info("COV", $sformatf("Write coverage:     %.1f%%", write_cov.get_coverage()), UVM_LOW)
    `uvm_info("COV", $sformatf("Read coverage:      %.1f%%", read_cov.get_coverage()), UVM_LOW)
    `uvm_info("COV", $sformatf("Flag coverage:      %.1f%%", flag_cov.get_coverage()), UVM_LOW)
    `uvm_info("COV", $sformatf("Occupancy coverage: %.1f%%", occupancy_cov.get_coverage()), UVM_LOW)
    `uvm_info("COV", $sformatf("Operation coverage: %.1f%%", operation_cov.get_coverage()), UVM_LOW)
  endfunction
endclass

//============================================================================
// AGENT
//============================================================================
class fifo_agent extends uvm_agent;
  `uvm_component_utils(fifo_agent)

  fifo_driver    driver;
  fifo_sequencer sequencer;
  fifo_monitor   monitor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    driver    = fifo_driver::type_id::create("driver", this);
    sequencer = fifo_sequencer::type_id::create("sequencer", this);
    monitor   = fifo_monitor::type_id::create("monitor", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    driver.seq_item_port.connect(sequencer.seq_item_export);
  endfunction
endclass

//============================================================================
// SCOREBOARD
//============================================================================
class fifo_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(fifo_scoreboard)

  logic [7:0] expected_fifo[$];

  uvm_tlm_analysis_fifo #(fifo_write_transaction) write_fifo;
  uvm_tlm_analysis_fifo #(fifo_read_transaction)  read_fifo;

  int write_count = 0;
  int read_count = 0;
  int match_count = 0;
  int mismatch_count = 0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    write_fifo = new("write_fifo", this);
    read_fifo  = new("read_fifo", this);
  endfunction

  task run_phase(uvm_phase phase);
    fork
      forever begin
        fifo_write_transaction wtxn;
        write_fifo.get(wtxn);
        expected_fifo.push_back(wtxn.write_data);
        write_count++;
      end

      forever begin
        fifo_read_transaction rtxn;
        logic [7:0] expected;
        read_fifo.get(rtxn);
        read_count++;

        if (expected_fifo.size() == 0) begin
          `uvm_error("SCBD", "Read observed but the model FIFO is empty!")
          mismatch_count++;
        end else begin
          expected = expected_fifo.pop_front();
          // FIX: the original popped the expected value but never compared
          // it to the data actually read, so it could never catch a bug.
          if (rtxn.read_data !== expected) begin
            mismatch_count++;
            `uvm_error("SCBD", $sformatf("MISMATCH on read %0d: expected=%h, actual=%h",
              read_count, expected, rtxn.read_data))
          end else begin
            match_count++;
            `uvm_info("SCBD", $sformatf("Read %0d OK: data=%h", read_count, expected), UVM_HIGH)
          end
        end
      end
    join_none
  endtask

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("SCBD", $sformatf("Writes: %0d, reads: %0d, matches: %0d, mismatches: %0d, left in FIFO: %0d",
      write_count, read_count, match_count, mismatch_count, expected_fifo.size()), UVM_LOW)
    if (mismatch_count == 0)
      `uvm_info("SCBD", "PASSED: all reads matched expected data", UVM_LOW)
    else
      `uvm_error("SCBD", $sformatf("FAILED: %0d mismatches detected", mismatch_count))
  endfunction
endclass

//============================================================================
// ENVIRONMENT
//============================================================================
class fifo_env extends uvm_env;
  `uvm_component_utils(fifo_env)

  fifo_agent      agent;
  fifo_scoreboard scoreboard;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent      = fifo_agent::type_id::create("agent", this);
    scoreboard = fifo_scoreboard::type_id::create("scoreboard", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agent.monitor.write_ap.connect(scoreboard.write_fifo.analysis_export);
    agent.monitor.read_ap.connect(scoreboard.read_fifo.analysis_export);
  endfunction
endclass

//============================================================================
// BASE TEST
//============================================================================
class fifo_test_base extends uvm_test;
  `uvm_component_utils(fifo_test_base)

  fifo_env env;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = fifo_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_test_sequence(phase);
    // FIX: let the last transaction reach the monitor and scoreboard
    // before ending the test.
    #100ns;
    phase.drop_objection(this);
  endtask

  virtual task run_test_sequence(uvm_phase phase);
    `uvm_info("TEST", "Base test - no sequence", UVM_LOW)
  endtask
endclass

//============================================================================
// WRITE TEST
//============================================================================
class fifo_write_sequence extends uvm_sequence #(fifo_transaction);
  `uvm_object_utils(fifo_write_sequence)

  int num_writes = 10;

  function new(string name = "fifo_write_sequence");
    super.new(name);
  endfunction

  task body();
    repeat (num_writes) begin
      fifo_write_transaction wtxn = fifo_write_transaction::type_id::create("wtxn");
      start_item(wtxn);
      if (!wtxn.randomize()) `uvm_error("SEQ", "Write randomization failed")
      finish_item(wtxn);
    end
  endtask
endclass

class fifo_write_test extends fifo_test_base;
  `uvm_component_utils(fifo_write_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_test_sequence(uvm_phase phase);
    fifo_write_sequence seq = fifo_write_sequence::type_id::create("seq");
    seq.num_writes = 16;
    seq.start(env.agent.sequencer);
  endtask
endclass

//============================================================================
// READ TEST
//============================================================================
class fifo_read_sequence extends uvm_sequence #(fifo_transaction);
  `uvm_object_utils(fifo_read_sequence)

  int num_reads = 10;

  function new(string name = "fifo_read_sequence");
    super.new(name);
  endfunction

  task body();
    repeat (num_reads) begin
      fifo_read_transaction rtxn = fifo_read_transaction::type_id::create("rtxn");
      start_item(rtxn);
      if (!rtxn.randomize()) `uvm_error("SEQ", "Read randomization failed")
      finish_item(rtxn);
    end
  endtask
endclass

class fifo_read_test extends fifo_test_base;
  `uvm_component_utils(fifo_read_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_test_sequence(uvm_phase phase);
    // FIX: the original read test started on an empty FIFO, so every read
    // had nothing to read. Fill 8 entries first, then read them back.
    fifo_write_sequence wseq = fifo_write_sequence::type_id::create("wseq");
    fifo_read_sequence  rseq = fifo_read_sequence::type_id::create("rseq");
    wseq.num_writes = 8;
    rseq.num_reads  = 8;
    wseq.start(env.agent.sequencer);
    rseq.start(env.agent.sequencer);
  endtask
endclass

//============================================================================
// FULL-DRAIN TEST
//============================================================================
class fifo_full_drain_test extends fifo_test_base;
  `uvm_component_utils(fifo_full_drain_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_test_sequence(uvm_phase phase);
    fifo_write_sequence wseq = fifo_write_sequence::type_id::create("wseq");
    fifo_read_sequence  rseq = fifo_read_sequence::type_id::create("rseq");
    wseq.num_writes = 16;  // fill completely
    rseq.num_reads  = 16;  // drain completely
    wseq.start(env.agent.sequencer);
    rseq.start(env.agent.sequencer);
  endtask
endclass

//============================================================================
// RANDOM MIX SEQUENCE (used by mixed and stress tests)
//============================================================================
class fifo_random_sequence extends uvm_sequence #(fifo_transaction);
  `uvm_object_utils(fifo_random_sequence)

  int num_operations = 20;

  function new(string name = "fifo_random_sequence");
    super.new(name);
  endfunction

  task body();
    repeat (num_operations) begin
      if ($urandom_range(1, 0) == 0) begin
        fifo_write_transaction wtxn = fifo_write_transaction::type_id::create("wtxn");
        start_item(wtxn);
        if (!wtxn.randomize()) `uvm_error("SEQ", "Write randomization failed")
        finish_item(wtxn);
      end else begin
        fifo_read_transaction rtxn = fifo_read_transaction::type_id::create("rtxn");
        start_item(rtxn);
        if (!rtxn.randomize()) `uvm_error("SEQ", "Read randomization failed")
        finish_item(rtxn);
      end
    end
  endtask
endclass

class fifo_mixed_test extends fifo_test_base;
  `uvm_component_utils(fifo_mixed_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_test_sequence(uvm_phase phase);
    fifo_random_sequence seq = fifo_random_sequence::type_id::create("seq");
    seq.num_operations = 32;
    seq.start(env.agent.sequencer);
  endtask
endclass

class fifo_stress_test extends fifo_test_base;
  `uvm_component_utils(fifo_stress_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_test_sequence(uvm_phase phase);
    fifo_random_sequence seq = fifo_random_sequence::type_id::create("seq");
    seq.num_operations = 500;
    seq.start(env.agent.sequencer);
  endtask
endclass

//============================================================================
// TOP MODULE
// FIX: week 11 had no top module at all - no clock, no reset, no DUT
// instance, no config_db::set, no run_test(). Without it there is nothing
// for the simulator to run.
//============================================================================
module tb_top;

  fifo_if intf();

  fifo dut (
    .clk        (intf.clk),
    .resetN     (intf.resetN),
    .write_en   (intf.write_en),
    .write_data (intf.write_data),
    .full       (intf.full),
    .read_en    (intf.read_en),
    .read_data  (intf.read_data),
    .empty      (intf.empty),
    .occupancy  (intf.occupancy)
  );

  // 100 MHz clock
  initial intf.clk = 0;
  always #5ns intf.clk = ~intf.clk;

  // Reset for 3 cycles
  initial begin
    intf.resetN   = 0;
    intf.write_en = 0;
    intf.read_en  = 0;
    repeat (3) @(posedge intf.clk);
    intf.resetN = 1;
  end

  initial begin
    uvm_config_db #(virtual fifo_if)::set(null, "*", "vif", intf);
    run_test("fifo_full_drain_test");
  end

  // Waveforms (tick "Open EPWave after run" in EDA Playground)
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, tb_top);
  end

endmodule