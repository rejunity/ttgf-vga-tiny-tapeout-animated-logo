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
  // Suppress unused signals warning
  wire _unused_ok = &{ena, ui_in[7:3], uio_in};

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

  wire logo;
  tt_logo tt_logo(
    .x(x_px),
    .y(y_px),
    .logo(logo)
  );

  reg [9:0] y_prv;
  reg [10:0] frame;
  always @(posedge clk) begin
    if (~rst_n) begin
      frame <= 0;
    end else begin
      y_prv <= y_px;
      if (y_px == 0 && y_prv != y_px) begin
          frame <= frame + 1;
      end
    end
  end

  // Bayer dithering
  // this is a 8x4 Bayer matrix which gets toggled every frame (so the other 8x4 elements are actually on odd frames)
  wire [2:0] bayer_i = x_px[2:0] ^ {3{frame[0]}};
  wire [1:0] bayer_j = y_px[1:0];
  wire [2:0] bayer_x = {bayer_i[2], bayer_i[1]^bayer_j[1], bayer_i[0]^bayer_j[0]};
  wire [4:0] bayer   = {bayer_x[0], bayer_i[0], bayer_x[1], bayer_i[1], bayer_x[2]};

  // output dithered 2 bit color from 6 bit color and 5 bit Bayer matrix
  function [1:0] dither2;
    input [5:0] color6;
    input [4:0] bayer5;
    begin
      dither2 = ({1'b0, color6} + {2'b0, bayer5} + color6[0] + color6[5] + color6[5:1]) >> 5;
    end
  endfunction

  wire [1:0] r_dither = dither2(r, bayer);
  wire [1:0] g_dither = dither2(g, bayer);
  wire [1:0] b_dither = dither2(b, bayer);

  function [17:0] rgb18;
    input [5:0] rgb6;
    begin
      rgb18 = {rgb6[5:4], 4'b0, rgb6[3:2], 4'b0, rgb6[1:0], 4'b0};
    end 
  endfunction

  function signed [17:0] rgb18_add;
    input signed [17:0] rgb0;
    input signed [17:0] rgb1;
    begin
      rgb18_add = {rgb0[17:11] + rgb1[17:11],
                   rgb0[10: 6] + rgb1[10: 6],
                   rgb0[ 5: 0] + rgb1[ 5: 0]};
    end 
  endfunction
  
  reg signed [17:0] bg_at_y0;
  reg signed [17:0] bg_at_x0;
  reg signed [17:0] bg;
  // wire signed  [17:0] bg_inc = {6'b000_000, 6'b111_111, 6'b000_001};
  wire signed [17:0] bg_inc = $signed({{5'b000_00, ~ui_in[2]} , 6'b111_111, 6'b000_001});
  always @(posedge clk) begin
    if (~rst_n) begin
      bg_at_y0 <= bg_inc*640;
      bg_at_x0 <= 0;
      bg <= 0;
    end else
    if (x_px == 0) begin
      if (y_px == 0) begin
        bg_at_x0 <= bg_inc*640 + bg_at_y0;
        // bg_at_y0 <= rgb18_add(bg_at_y0, -bg_inc*3);
        bg_at_y0 <= rgb18_add(bg_at_y0, -bg_inc*(ui_in[1:0] + 3'b1));
      end else begin
        // bg <= rgb18_add(bg, bg_inc);
        bg_at_x0 <= rgb18_add(bg_at_x0, bg_inc);
        bg <= bg_at_x0;
      end
    end else begin
      bg <= rgb18_add(bg, bg_inc);
    end
  end

  wire [5:0] r, g, b;
  assign {r, g, b} = logo ? rgb18(63-2) : bg;

  assign {R, G, B} = 
    ~activevideo ? 0 : { r_dither, g_dither, b_dither };

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


// TODO: move into a separate logo.v file
module tt_logo(
  input wire [9:0] x,
  input wire [9:0] y,
  output wire logo
);
  wire signed [8:0] x_signed = $signed(x[8:0]);
  wire signed [8:0] y_signed = $signed(y[8:0]);

  //wire [17:0] sq0x_; approx_signed_square #(9,3,3) sq0x(.a(x_signed - 9'sd320), .p_approx(x_sq));
  wire [17:0] x_sq; approx_signed_square #(9,4,4) sq0x(.a(x_signed - 9'sd320), .p_approx(x_sq));
  wire [17:0] y_sq; approx_signed_square #(9,4,3) sq0y(.a(y_signed - 9'sd240), .p_approx(y_sq));

  wire _unused_ok = &{x_sq[17:16], y_sq[17:16]};

  wire [15:0] r_sq = x_sq[15:0] + y_sq[15:0];

  // wire ring = (rx+ry) < 240*240 & (rx+ry) > (240-36)*(240-36);
  wire ring = r_sq < 238*238 & r_sq > (238-36)*(238-36);

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

  assign logo = (ring&cut0&cut1)|hat0|leg0|hat1|leg1;
endmodule

module approx_signed_square #(
    parameter integer W = 12,
    parameter integer T = 4,  // truncate this many LSBs
    parameter integer R = 3   // use top R bits of low part to approximate cross-term
)(
    input  wire signed [W-1:0] a,
    output wire [2*W-1:0] p_approx
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
