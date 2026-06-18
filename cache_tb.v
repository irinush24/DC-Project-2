`timescale 1ns/1ps

module cache_tb;

    // Parameters matching design
    localparam BLOCK_SIZE    = 256;
    localparam ADDRESS_WIDTH  = 21;
    localparam WORD_SIZE      = 32;
    localparam MEM_ADDR_WIDTH = 18; // 21 - 3 (offset bits)

    // Clock and Reset
    reg clk;
    reg rst_n;

    // CPU <-> Cache Interface
    reg [ADDRESS_WIDTH-1:0] caddress;
    reg [WORD_SIZE-1:0]     cdin;
    reg                     rden;
    reg                     wren;
    wire                    hit;
    wire [WORD_SIZE-1:0]    cdout;

    // Cache <-> Memory Interface
    wire [BLOCK_SIZE-1:0]   mdin;   // Connects to memory dout
    wire [BLOCK_SIZE-1:0]   mdout;  // Connects to memory din
    wire [17:0]             maddress;
    wire                    mrden;
    wire                    mwren;

    cache_controller #(
        .BLOCK_SIZE(BLOCK_SIZE),
        .ADDRESS_WIDTH(ADDRESS_WIDTH),
        .WORD_SIZE(WORD_SIZE)
    ) u_cache (
        .clock(clk),
        .rst_n(rst_n),
        .caddress(caddress),
        .cdin(cdin),
        .mdin(mdin),
        .rden(rden),
        .wren(wren),
        .hit(hit),
        .cdout(cdout),
        .mdout(mdout),
        .maddress(maddress),
        .mrden(mrden),
        .mwren(mwren)
    );

    memory #(
        .ADDRESS_WIDTH(MEM_ADDR_WIDTH),
        .BLOCK_SIZE(BLOCK_SIZE),
        .FILE("") // Empty string fills memory with zeroes
    ) u_mem (
        .clock(clk),
        .din(mdout),
        .address(maddress),
        .rden(mrden),
        .wren(mwren),
        .dout(mdin)
    );

    // Clock Generator (50MHz)
    always #10 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        caddress = 0;
        cdin = 0;
        rden = 0;
        wren = 0;

        // Pre-populate a baseline value in Main Memory block 0 manually for testing
        // Word 0 of Block 0 = 32'hDEADBEEF
        u_mem.mem[0] = {224'b0, 32'hDEADBEEF}; 

        #40 rst_n = 1; // Release reset
        #20;

        // ========================================================
        // TEST 1: Read Miss
        // Read from Word Address 0 (Block 0, Offset 0)
        // ========================================================
        $display("[%0t] TEST 1: Initiating Read from Address 0 (Expect MISS)", $time);
        caddress = 21'd0;
        rden = 1;
        #20;
        rden = 0; // Clear enable, controller captures request in req_addr

        // Wait until cache returns to IDLE state after completing FETCH/FILL
        while (u_cache.current_state != 0) #20; 
        
        // Assert hit on the subsequent cycle evaluation
        caddress = 21'd0; rden = 1; #20;
        $display("[%0t] Result -> Hit: %b, Data Out: %h (Expect DEADBEEF)", $time, hit, cdout);
        rden = 0; #20;

        // ========================================================
        // TEST 2: Write Hit & Allocation (Modify Word 0)
        // ========================================================
        $display("\n[%0t] TEST 2: Writing 32'hCAFEBABE to Address 0 (Expect HIT)", $time);
        caddress = 21'd0;
        cdin = 32'hCAFEBABE;
        wren = 1;
        #20;
        wren = 0;
        
        while (u_cache.current_state != 0) #20;
        $display("[%0t] Cache Line is now Dirty. Checking Tag Array...", $time);

        // ========================================================
        // TEST 3: Conflict & Replacement (Eviction of Dirty Line)
        // Trigger 4 distinct tags mapping to the SAME Set index 
        // to overflow the 4 ways and force an eviction of Way 0.
        // ========================================================
        $display("\n[%0t] TEST 3: Stressing LRU by filling all 4 ways of Set 0...", $time);
        
        // Way 1 (Address space offset by 1st Tag step)
        caddress = {10'd1, 8'd0, 3'd0}; rden = 1; #20; rden = 0;
        while (u_cache.current_state != 0) #20;

        // Way 2
        caddress = {10'd2, 8'd0, 3'd0}; rden = 1; #20; rden = 0;
        while (u_cache.current_state != 0) #20;

        // Way 3
        caddress = {10'd3, 8'd0, 3'd0}; rden = 1; #20; rden = 0;
        while (u_cache.current_state != 0) #20;

        // Way 4: This will kick out our original Address 0 (Way 0) because it is LRU!
        // It must pass through STATE_REPLACE because Address 0 was modified (Dirty)
        $display("[%0t] Accessing 5th unique block on Set 0. Eviction expected.", $time);
        caddress = {10'd4, 8'd0, 3'd0}; rden = 1; #20; rden = 0;
        while (u_cache.current_state != 0) begin
            if (u_cache.current_state == 3'd5) 
                $display("[%0t] --> SUCCESS: Controller entered STATE_REPLACE (Write-Back active)", $time);
            #20;
        end

        // Verify data was written back to memory location index 0
        #20;
        $display("[%0t] Checking Main Memory block 0: %h (Expect CAFEBABE at lowest word)", $time, u_mem.mem[0][31:0]);

        $stop;
    end

endmodule