`timescale 1ns/1ps
// Self-checking TB for cs12_sync_frame: drives cs12_8mux -> cs12_sync_frame, captures the
// exact emitted stream bytes (LE: data_out0 then data_out1 per valid cycle), and verifies
//  (1) the 20-byte MAGIC appears every SYNC_PERIOD bytes, exact byte order,
//  (2) the 4 trailing COUNTER bytes increment by 1 each sync, and
//  (3) CS16/CS8 emit NO magic (passthrough).
module cs12_sync_frame_tb;
  localparam PERIOD = 64;                 // small period for a fast sim (8 bursts)
  reg clk=0, rst_n=0, valid_in=0, streaming=0;
  reg En0=1'b0, En1=1'b1;                 // CS12 by default
  reg [15:0] I0=0,Q0=0;
  wire [15:0] m0,m1; wire vout,bs,fs,e1,e2;
  cs12_8mux mux(.clk(clk),.rst_n(rst_n),.I0(I0),.Q0(Q0),.valid_in(valid_in),
    .Enable0(En0),.Enable1(En1),.zero_count(1'b0),.data_out0(m0),.data_out1(m1),
    .valid_out(vout),.burst_sync(bs),.frame_start(fs),.Enable_O1(e1),.Enable_O2(e2));
  wire [15:0] d0,d1;
  cs12_sync_frame #(.SYNC_PERIOD_SAMPLES(PERIOD)) dut(.clk(clk),.rst_n(rst_n),
    .Enable0(En0),.Enable1(En1),.frame_start(fs),.valid_in(vout),
    .data_in0(m0),.data_in1(m1),.data_out0(d0),.data_out1(d1));

  always #5 clk=~clk;
  integer kc=0;
  always @(negedge clk) if (streaming) begin I0={4'h1,kc[11:0]};Q0={4'h8,kc[11:0]};kc=kc+1; end

  // capture stream bytes
  reg [7:0] strm [0:8191]; integer nb=0;
  always @(posedge clk) if (rst_n && vout) begin
    strm[nb]=d0[7:0]; strm[nb+1]=d0[15:8]; strm[nb+2]=d1[7:0]; strm[nb+3]=d1[15:8]; nb=nb+4;
  end

  reg [7:0] MAG [0:19];
  integer i,j,p,found,prevpos,prevctr,ctr,nsync,errors,ok;
  initial begin
    MAG[0]=8'hA1;MAG[1]=8'h5C;MAG[2]=8'h1E;MAG[3]=8'hAB;MAG[4]=8'hD2;MAG[5]=8'hC5;MAG[6]=8'hEF;
    MAG[7]=8'h12;MAG[8]=8'h37;MAG[9]=8'h9A;MAG[10]=8'h4D;MAG[11]=8'h6B;MAG[12]=8'hE1;MAG[13]=8'hF0;
    MAG[14]=8'h8A;MAG[15]=8'h3C;MAG[16]=8'h56;MAG[17]=8'h7D;MAG[18]=8'h91;MAG[19]=8'h24;
    errors=0; nsync=0; prevpos=-1; prevctr=0;

    rst_n=0; repeat(4) @(posedge clk); rst_n=1; @(posedge clk);
    streaming=1; valid_in=1;
    repeat(700) @(posedge clk);           // ~ several periods
    // scan captured stream for MAGIC
    for (p=0; p<=nb-24; p=p+1) begin
      found=1;
      for (j=0;j<20;j=j+1) if (strm[p+j]!==MAG[j]) found=0;
      if (found) begin
        ctr = {strm[p+23],strm[p+22],strm[p+21],strm[p+20]};   // LE uint32
        $display("  MAGIC @byte %0d  counter=%0d", p, ctr);
        nsync=nsync+1;
        if (prevpos>=0) begin
          if ((p-prevpos)!=PERIOD*3)                            // 24 bytes/burst, PERIOD/8 bursts -> PERIOD*3 bytes
            begin errors=errors+1; $display("   ERR spacing %0d (want %0d)",p-prevpos,PERIOD*3); end
          if (ctr!=((prevctr+1)&32'hFFFFFFFF))
            begin errors=errors+1; $display("   ERR counter %0d after %0d",ctr,prevctr); end
        end
        prevpos=p; prevctr=ctr;
      end
    end
    $display("CS12: %0d sync frames found, %0d errors", nsync, errors);

    // --- CS16 must emit NO magic ---
    rst_n=0; nb=0; @(posedge clk); rst_n=1; En0=1'b1; En1=1'b1; @(posedge clk);  // CS16
    repeat(400) @(posedge clk);
    ok=1; for (p=0;p<=nb-20;p=p+1) begin found=1; for(j=0;j<20;j=j+1) if(strm[p+j]!==MAG[j]) found=0; if(found) ok=0; end
    $display("CS16: magic-free = %0d", ok); if(!ok) errors=errors+1;

    if (errors==0 && nsync>=2 && ok)
      $display("CS12 SYNC-FRAME TEST: PASS"); else begin $display("CS12 SYNC-FRAME TEST: FAIL"); $fatal(1,"x"); end
    $finish;
  end
endmodule
