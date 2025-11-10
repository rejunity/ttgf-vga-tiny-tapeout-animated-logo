/*
 * Copyright (c) 2025 Renaldas Zioma
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_rejunity_vga_logo (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // VGA signals
  wire hsync;
  wire vsync;
  wire [1:0] R;
  wire [1:0] G;
  wire [1:0] B;

  // TinyVGA PMOD
  assign uo_out = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};

  // Unused outputs assigned to 0.
  assign uio_out = 0;
  assign uio_oe  = 0;

  wire [9:0] x_px;
  wire [9:0] y_px;
  wire activevideo;
  
  hvsync_generator hvsync_gen(
    .clk(clk),
    .reset(~rst_n),
    .hsync(hsync),
    .vsync(vsync),
    .display_on(activevideo),
    .hpos(x_px),
    .vpos(y_px)
  );

  wire [9:0] x = x_px;
  wire [9:0] y = y_px;

  wire [15:0] sq0x_; approx_signed_square #(9,3,3) sq0x(.a($signed(x_px) - 9'sd320), .p_approx(sq0x_));
  wire [15:0] sq0y_; approx_signed_square #(9,4,3) sq0y(.a($signed(y_px) - 9'sd240), .p_approx(sq0y_));

  wire [15:0] sqR = sq0x_ + sq0y_;
  wire [15:0] r = sqR;

  // wire ring = (rx+ry) < 240*240 & (rx+ry) > (240-36)*(240-36);
  wire ring = r < 238*238 & r > (238-36)*(238-36);

  // xy: 46x100 wh:240x64
  wire hat0 = x >= 80+46  & x < 80+46+240  & y >= 100 & y < 100+64;
  // xy:144x100 wh:70x228
  wire leg0 = x >= 80+144 & x < 80+144+70  & y >= 100 & y < 100+228;
  // xy:144x222 wh:254x64
  wire hat1 = x >= 80+144 & x < 80+144+254 & y >= 222 & y < 222+64;
  // xy:256x222 wh:70x240
  wire leg1 = x >= 80+256 & x < 80+256+70  & y >= 222 & y < 222+240;

  // xy:(256+70)x(222+64) wh:20x...
  wire cut0 = ~(x >= 80   & x < 80+144     & y >= 100+64 & y < 100+60+22);
  // xy:(256+70)x(222+64) wh:20x...
  wire cut1 = ~(x >= 80+256+70 & x < 80+256+70+22 & y >= 222+64 & y < 480);

  // wire bg = y[5]^y[4]^y[3];//y[0]+y[1]+y[2]+y[3]+y[4]+y[5]+y[6]+y[7]+y[8] > 2;
  // wire bg = acc[6]^flip;//(cc == 1)^flip;
  // wire bg = line;

  wire logo = (ring&cut0&cut1)|hat0|leg0|hat1|leg1;
  assign {R, G, B} = 
    ~activevideo ? 0 :
             logo ? 6'b00_00_00 : 6'b11_11_11;
             //   logo ? fg : bg;

  // TinyVGA PMOD
`ifdef VGA_REGISTERED_OUTPUTS
  reg [7:0] UO_OUT;
  always @(posedge clk)
    UO_OUT <= {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};
  assign uo_out = UO_OUT;
`else
  assign uo_out = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};
`endif
endmodule

module approx_signed_square #(
    parameter integer W = 12,
    parameter integer T = 4,  // truncate this many LSBs
    parameter integer R = 3   // use top R bits of low part to approximate cross-term
)(
    input  wire signed [W-1:0] a,
    output wire [2*W-1:0] p_approx
    // output wire signed [15:0] p_approx
);
    // -------------------------
    // Guards
    // -------------------------
    initial begin
        if (W <= 1)  $error("W must be >= 2");
        if (T < 0)   $error("T must be >= 0");
        if (T >= W)  $error("T must be <= W-1");
        if (R < 0)   $error("R must be >= 0");
        if (R > T)   $error("R must be <= T");
    end

    localparam integer H = W - T;                // width of high part
    localparam integer PROD_W_HH = 2*H;          // width of x_h^2
    localparam integer SHIFT_HH  = 2*T;          // alignment for x_h^2
    localparam integer SHIFT_X   = (2*T >= R) ? (2*T - R) : 0; // alignment for cross-term

    // -------------------------
    // Work with magnitude (unsigned) since a^2 is non-negative
    // -------------------------
    wire [W-1:0] x = a[W-1] ? (~a + 1'b1) : a;   // abs(a)

    // Partition (unsigned slices)
    wire [H-1:0] x_h = (T == 0) ? x[W-1:0] : x[W-1:T];
    wire [T-1:0] x_l = (T == 0) ? {T{1'b0}} : x[T-1:0];

    // Core: x_h^2 << (2T)
    wire [PROD_W_HH-1:0] prod_hh_u = x_h * x_h;
    wire [2*W-1:0] term_hh_u = {{(2*W-PROD_W_HH){1'b0}}, prod_hh_u} << SHIFT_HH;

    // Optional cross-term using only top R bits of x_l
    generate
        if (R == 0) begin : no_correction
            assign p_approx = $signed(term_hh_u); // pure truncation
        end else begin : with_correction
            // Top R bits of x_l (unsigned)
            wire [R-1:0] x_l_top = x_l[T-1 -: R];  // x_l >> (T-R), keeping R bits

            // One small multiplier: (H x R)
            wire [H+R-1:0] prod_hl_u = x_h * x_l_top;

            // Approximate 2*x_h*x_l << T  ≈  2*(x_h*x_l_top) << (2T - R)
            // "×2" is a left shift by 1
            wire [2*W-1:0] term_x_u =
                ({{(2*W-(H+R)){1'b0}}, prod_hl_u} << (SHIFT_X + 1));

            assign p_approx = $signed(term_hh_u + term_x_u);
            // assign p_approx = term_hh_u + term_x_u;
        end
    endgenerate

endmodule
