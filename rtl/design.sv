//============================================================================
// SYNCHRONOUS FIFO WITH ASSERTIONS
// 16 entry, 8 bit data, parameterized design with comprehensive assertions
//============================================================================

module fifo #(
  parameter int DEPTH = 16,
  parameter int DATA_WIDTH = 8,
  parameter int ADDR_WIDTH = 4  // log2(DEPTH)
) (
  input logic clk,
  input logic resetN,
  
  // Write side
  input logic write_en,
  input logic [DATA_WIDTH-1:0] write_data,
  output logic full,
  
  // Read side
  input logic read_en,
  output logic [DATA_WIDTH-1:0] read_data,
  output logic empty,
  
  // Status
  output logic [ADDR_WIDTH:0] occupancy
);

  // Internal storage
  logic [DATA_WIDTH-1:0] fifo_mem [DEPTH-1:0];
  
  // Pointers (one extra bit for wraparound detection)
  logic [ADDR_WIDTH:0] wr_ptr;  // Write pointer
  logic [ADDR_WIDTH:0] rd_ptr;  // Read pointer
  
  //============================================================================
  // POINTER AND STATUS LOGIC
  //============================================================================
  
  always_ff @(posedge clk or negedge resetN) begin
    if (!resetN) begin
      wr_ptr <= 0;
      rd_ptr <= 0;
    end
    else begin
      // Advance write pointer on write
      if (write_en && !full) begin
        wr_ptr <= wr_ptr + 1;
      end
      
      // Advance read pointer on read
      if (read_en && !empty) begin
        rd_ptr <= rd_ptr + 1;
      end
    end
  end
  
  // Flag logic
  assign full = (wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0]) && 
                (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH]);
  
  assign empty = (wr_ptr == rd_ptr);
  
  // Occupancy calculation
  
  /*
  // This is the original calculation formula that threw an error
  assign occupancy = (wr_ptr[ADDR_WIDTH-1:0] >= rd_ptr[ADDR_WIDTH-1:0]) ?
                     (wr_ptr[ADDR_WIDTH-1:0] - rd_ptr[ADDR_WIDTH-1:0]) :
                     (DEPTH - rd_ptr[ADDR_WIDTH-1:0] + wr_ptr[ADDR_WIDTH-1:0]);
  */
  
  // FIX (Round 1): use full-width pointers so the wrap bit distinguishes
  // full (16) from empty (0). Old logic used only the low 4 bits.
  assign occupancy = wr_ptr - rd_ptr;
  //============================================================================
  // READ DATA LOGIC
  //============================================================================
  
  assign read_data = fifo_mem[rd_ptr[ADDR_WIDTH-1:0]];
  
  //============================================================================
  // WRITE LOGIC
  //============================================================================
  
  always_ff @(posedge clk) begin
    if (write_en && !full) begin
      fifo_mem[wr_ptr[ADDR_WIDTH-1:0]] <= write_data;
    end
  end
  
  //============================================================================
  // ASSERTIONS
  //============================================================================
  
  // Assertion 1: Full and empty can never be true at same time (impossible state)
  assert_full_empty_exclusive: assert property (
    @(posedge clk)
    !(full && empty)
  ) else $error("FIFO ERROR: Full and empty flags asserted simultaneously!");
  
  // Assertion 2: Occupancy must be in valid range [0, DEPTH]
  assert_occupancy_range: assert property (
    @(posedge clk)
    (occupancy >= 0) && (occupancy <= DEPTH)
  ) else $error("FIFO ERROR: Occupancy out of valid range! Occupancy=%d", occupancy);
  
  // Assertion 3: Can't write when full
  assert_no_write_when_full: assert property (
    @(posedge clk)
    full -> !write_en
  ) else $error("FIFO ERROR: Write attempted when FIFO is full!");
  
  // Assertion 4: Can't read when empty
  assert_no_read_when_empty: assert property (
    @(posedge clk)
    empty -> !read_en
  ) else $error("FIFO ERROR: Read attempted when FIFO is empty!");
  
  // Assertion 5: Write pointer should only advance on valid write
  assert_write_ptr_progression: assert property (
    @(posedge clk)
    write_en && !full |-> ##1 (wr_ptr == $past(wr_ptr) + 1'b1) // Fix #4
  ) else $error("FIFO ERROR: Write pointer did not increment on write!");
  
  // Assertion 6: Read pointer should only advance on valid read
  assert_read_ptr_progression: assert property (
    @(posedge clk)
    read_en && !empty |-> ##1 (rd_ptr == $past(rd_ptr) + 1'b1) // Fix #4
  ) else $error("FIFO ERROR: Read pointer did not increment on read!");
  
  // Assertion 7: Occupancy should increase on write-only
  assert_occupancy_on_write: assert property (
    @(posedge clk)
    (write_en && !full && !read_en) |-> ##1 (occupancy == $past(occupancy) + 1)
  ) else $error("FIFO ERROR: Occupancy did not increase on write!");
  
  // Assertion 8: Occupancy should decrease on read-only
  assert_occupancy_on_read: assert property (
    @(posedge clk)
    (read_en && !empty && !write_en) |-> ##1 (occupancy == $past(occupancy) - 1)
  ) else $error("FIFO ERROR: Occupancy did not decrease on read!");
  
  // Assertion 9: Empty flag should be true when occupancy is 0
  assert_empty_occupancy_correlation: assert property (
    @(posedge clk)
    (occupancy == 0) <-> empty
  ) else $error("FIFO ERROR: Empty flag doesn't match occupancy!");
  
  // Assertion 10: Full flag should be true when occupancy is DEPTH
  assert_full_occupancy_correlation: assert property (
    @(posedge clk)
    (occupancy == DEPTH) <-> full
  ) else $error("FIFO ERROR: Full flag doesn't match occupancy!");
 
    // FIX (Round 3 regression): removed assert_pointer_wraparound. It    
    //rejected the legal
  // value 31, and a 5-bit pointer cannot hold an out-of-range value anyway.
 
  // Assertion 11: Pointer wraparound should work correctly (max 32-bit)
  //assert_pointer_wraparound: assert property (
  //  @(posedge clk)
  //  (wr_ptr < {ADDR_WIDTH+1{1'b1}}) && (rd_ptr < {ADDR_WIDTH+1{1'b1}})
  //) else $error("FIFO ERROR: Pointer wraparound incorrect!");
  
  // Assertion 12: Write data should be captured correctly
  assert_write_data_capture: assert property (
    @(posedge clk)
    (write_en && !full) |-> ##1 (fifo_mem[$past(wr_ptr[ADDR_WIDTH-1:0])] == $past(write_data))
  ) else $error("FIFO ERROR: Write data not captured correctly!");

endmodule