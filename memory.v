module memory
  #(parameter ADDRESS_WIDTH = 18, // 2^18 entries of 256-bit blocks = 8 MiB total
    parameter BLOCK_SIZE = 256,
    parameter FILE = ""
    )
   (
    input                            clock,
    input [BLOCK_SIZE - 1:0]         din,
    input [ADDRESS_WIDTH - 1:0]      address,
    input                            rden,
    input                            wren,
    output reg [BLOCK_SIZE -1:0]     dout
    );

   localparam DEPTH = 262144; // 2 ^ 18
   
   reg [BLOCK_SIZE-1:0] mem [0:DEPTH-1];
   integer i;

   initial begin
      if (FILE != "")
         $readmemh(FILE, mem);
      else
         for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = {BLOCK_SIZE{1'b0}};
   end

   always @(posedge clock) begin
      if (wren)
         mem[address] <= din;
   end

   always @(posedge clock) begin
      if (rden)
         dout <= mem[address];
   end

endmodule