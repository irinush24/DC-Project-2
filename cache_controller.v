`timescale 1ns/1ps

module cache_controller
  #(
    parameter BLOCK_SIZE = 256,
    parameter ADDRESS_WIDTH = 21,
    parameter INDEX_WIDTH = 8,       // 8 for 256 sets
    parameter TAG_WIDTH = 10,
    parameter OFFSET_WIDTH = 3,
    parameter WORD_SIZE = 32,
    parameter NSETS = 256
)
   (
    input                            clock,
    input                            rst_n,
    input [ADDRESS_WIDTH - 1:0]      caddress,
    input [WORD_SIZE - 1:0]          cdin,
    input [BLOCK_SIZE - 1:0]         mdin,
    input                            rden,
    input                            wren,
    output                           hit,
    output reg [WORD_SIZE - 1:0]     cdout,
    output reg [BLOCK_SIZE - 1:0]    mdout,
    output reg [TAG_WIDTH + INDEX_WIDTH - 1:0] maddress,
    output reg                       mrden,
    output reg                       mwren
    );

   // State encoding
   parameter STATE_IDLE       = 3'd0;
   parameter STATE_READ_HIT   = 3'd1;
   parameter STATE_READ_MISS  = 3'd2;
   parameter STATE_WRITE_HIT  = 3'd3;
   parameter STATE_WRITE_MISS = 3'd4;
   parameter STATE_REPLACE    = 3'd5;
   parameter STATE_FETCH      = 3'd6;
   parameter STATE_FILL       = 3'd7;

   reg [2:0] current_state, next_state;

   localparam TAG_MSB           = 20;
   localparam TAG_LSB           = 11;
   localparam INDEX_MSB         = 10;
   localparam INDEX_LSB         = 3;
   localparam BLOCK_OFFSET_MSB  = 2;
   localparam BLOCK_OFFSET_LSB  = 0;

   // 4-Way Set Associative Storage arrays
   reg                      cache_valid [0:NSETS-1][0:3];
   reg                      cache_dirty [0:NSETS-1][0:3];
   reg [TAG_WIDTH - 1:0]    cache_tag   [0:NSETS-1][0:3];
   reg [BLOCK_SIZE - 1:0]   cache_mem   [0:NSETS-1][0:3];
   
   // LRU bits:
   // 3 = most recent, 0 = least recent/eviction target
   reg [1:0]                cache_lru   [0:NSETS-1][0:3];

   reg [ADDRESS_WIDTH - 1:0]   req_addr;
   reg                         req_read;
   reg                         req_write;
   reg [WORD_SIZE - 1:0]       req_wdata;

   wire [ADDRESS_WIDTH - 1:0]  active_addr;
   wire [INDEX_WIDTH - 1:0]    active_index;
   wire [TAG_WIDTH - 1:0]      active_tag;
   wire [OFFSET_WIDTH - 1:0]   active_offset;

   wire                        way_hit [0:3];
   wire                        lookup_hit;
   reg [1:0]                   hit_way_idx;
   reg [1:0]                   victim_way_idx;
   reg [WORD_SIZE - 1:0]       read_data;

   function [WORD_SIZE - 1:0] block_get_word;
      input [BLOCK_SIZE - 1:0] block;
      input [OFFSET_WIDTH - 1:0] word_offset;
      begin
         block_get_word = block[32 * word_offset +: WORD_SIZE];
      end
   endfunction

   function [BLOCK_SIZE - 1:0] block_set_word;
      input [BLOCK_SIZE - 1:0] block;
      input [OFFSET_WIDTH - 1:0] word_offset;
      input [WORD_SIZE - 1:0] word;
      begin
         block_set_word = block;
         block_set_word[32 * word_offset +: WORD_SIZE] = word;
      end
   endfunction

   assign active_addr   = (current_state == STATE_IDLE) ? caddress : req_addr;
   assign active_index  = active_addr[INDEX_MSB:INDEX_LSB];
   assign active_tag    = active_addr[TAG_MSB:TAG_LSB];
   assign active_offset = active_addr[BLOCK_OFFSET_MSB:BLOCK_OFFSET_LSB];

   // Hit evaluation across all 4 ways
   assign way_hit[0] = cache_valid[active_index][0] && (cache_tag[active_index][0] == active_tag);
   assign way_hit[1] = cache_valid[active_index][1] && (cache_tag[active_index][1] == active_tag);
   assign way_hit[2] = cache_valid[active_index][2] && (cache_tag[active_index][2] == active_tag);
   assign way_hit[3] = cache_valid[active_index][3] && (cache_tag[active_index][3] == active_tag);
   
   assign lookup_hit = way_hit[0] || way_hit[1] || way_hit[2] || way_hit[3];
   assign hit = lookup_hit;

   // Select index of the matching way or eviction target
   always @(*) begin
      if (way_hit[0])      hit_way_idx = 2'd0;
      else if (way_hit[1]) hit_way_idx = 2'd1;
      else if (way_hit[2]) hit_way_idx = 2'd2;
      else                 hit_way_idx = 2'd3;

      // Find the LRU item (the way that has rank 0)
      if (cache_lru[active_index][0] == 2'd0)      victim_way_idx = 2'd0;
      else if (cache_lru[active_index][1] == 2'd0) victim_way_idx = 2'd1;
      else if (cache_lru[active_index][2] == 2'd0) victim_way_idx = 2'd2;
      else                                         victim_way_idx = 2'd3;
   end

   always @(*) begin
      read_data = block_get_word(cache_mem[active_index][hit_way_idx], active_offset);
   end

   // Combinational Next State & Output Logic
   always @(*) begin
      next_state = current_state;
      cdout    = 32'b0;
      mdout    = 256'b0;
      maddress = 18'b0;
      mrden    = 1'b0;
      mwren    = 1'b0;

      case (current_state)
         STATE_IDLE: begin
            if (rden && lookup_hit)
               next_state = STATE_READ_HIT;
            else if (rden)
               next_state = STATE_READ_MISS;
            else if (wren && lookup_hit)
               next_state = STATE_WRITE_HIT;
            else if (wren)
               next_state = STATE_WRITE_MISS;
         end

         STATE_READ_HIT: begin
            cdout = read_data;
            next_state = STATE_IDLE;
         end

         STATE_READ_MISS: begin
            if (cache_dirty[active_index][victim_way_idx] && cache_valid[active_index][victim_way_idx])
               next_state = STATE_REPLACE;
            else
               next_state = STATE_FETCH;
         end

         STATE_WRITE_MISS: begin
            if (cache_dirty[active_index][victim_way_idx] && cache_valid[active_index][victim_way_idx])
               next_state = STATE_REPLACE;
            else
               next_state = STATE_FETCH;
         end

         STATE_REPLACE: begin
            mwren    = 1'b1;
            maddress = {cache_tag[active_index][victim_way_idx], active_index};
            mdout    = cache_mem[active_index][victim_way_idx];
            next_state = STATE_FETCH;
         end

         STATE_FETCH: begin
            mrden    = 1'b1;
            maddress = {active_tag, active_index};
            next_state = STATE_FILL;
         end

         STATE_FILL: begin
            if (req_read)
               next_state = STATE_READ_HIT;
            else if (req_write)
               next_state = STATE_WRITE_HIT;
            else
               next_state = STATE_IDLE;
         end

         STATE_WRITE_HIT: begin
            next_state = STATE_IDLE;
         end

         default: begin
            next_state = STATE_IDLE;
         end
      endcase
   end

   integer set_idx, way_idx;

   // Sequential State Machine and Storage Logic
   always @(posedge clock) begin
      if (!rst_n) begin
         current_state <= STATE_IDLE;
         req_read      <= 1'b0;
         req_write     <= 1'b0;
         req_addr      <= 0;
         req_wdata     <= 0;
         for (set_idx = 0; set_idx < NSETS; set_idx = set_idx + 1) begin
            for (way_idx = 0; way_idx < 4; way_idx = way_idx + 1) begin
               cache_valid[set_idx][way_idx] <= 1'b0;
               cache_dirty[set_idx][way_idx] <= 1'b0;
               cache_tag[set_idx][way_idx]   <= 0;
               cache_mem[set_idx][way_idx]   <= 0;
               cache_lru[set_idx][way_idx]   <= way_idx; // Initialize unique ranks
            end
         end
      end else begin
         current_state <= next_state;

         if (current_state == STATE_IDLE && (rden || wren)) begin
            req_addr  <= caddress;
            req_read  <= rden;
            req_write <= wren;
            req_wdata <= cdin;
         end

         // LRU Age Counter Shift Logic on Hits
         if ((current_state == STATE_IDLE && (rden || wren) && lookup_hit) || 
             (current_state == STATE_READ_HIT) || (current_state == STATE_WRITE_HIT)) begin
            for (way_idx = 0; way_idx < 4; way_idx = way_idx + 1) begin
               if (way_idx == hit_way_idx) begin
                  cache_lru[active_index][way_idx] <= 2'd3; // Set to MRU
               end else if (cache_lru[active_index][way_idx] > cache_lru[active_index][hit_way_idx]) begin
                  cache_lru[active_index][way_idx] <= cache_lru[active_index][way_idx] - 1'b1;
               end
            end
         end

         if (current_state == STATE_FILL) begin
            cache_mem[active_index][victim_way_idx]   <= mdin;
            cache_tag[active_index][victim_way_idx]   <= active_tag;
            cache_valid[active_index][victim_way_idx] <= 1'b1;
            cache_dirty[active_index][victim_way_idx] <= 1'b0;
            
            // LRU Update for replacement line
            for (way_idx = 0; way_idx < 4; way_idx = way_idx + 1) begin
               if (way_idx == victim_way_idx) begin
                  cache_lru[active_index][way_idx] <= 2'd3;
               end else if (cache_lru[active_index][way_idx] > cache_lru[active_index][victim_way_idx]) begin
                  cache_lru[active_index][way_idx] <= cache_lru[active_index][way_idx] - 1'b1;
               end
            end
         end

         if (current_state == STATE_WRITE_HIT) begin
            cache_mem[active_index][hit_way_idx]   <= block_set_word(
               cache_mem[active_index][hit_way_idx], active_offset, req_wdata
            );
            cache_dirty[active_index][hit_way_idx] <= 1'b1;
         end
      end
   end

endmodule