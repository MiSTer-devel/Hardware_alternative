
// altera message_off 10030
module sid_voice
(
	input         clock,
	input         ce_1m,
	input         reset,
	input   [7:0] freq_lo,
	input   [7:0] freq_hi,
	input   [7:0] pw_lo,
	input   [3:0] pw_hi,
	input   [7:0] control,
	input   [7:0] att_dec,
	input   [7:0] sus_rel,
	input         osc_msb_in,

	input   [7:0] _st_out,
	input   [7:0] p_t_out,
	input   [7:0] ps__out,
	input   [7:0] pst_out,

	output reg [11:0] sawtooth,
	output reg [11:0] triangle,
	
	output        osc_msb_out,
	output [11:0] signal_out,
	output [ 7:0] osc_out,
	output [ 7:0] env_out
);

// Internal Signals
reg  [23:0] oscillator;
reg         osc_edge;
reg         osc_msb_in_prv;
reg  [11:0] pulse;
reg  [11:0] noise;
reg  [22:0] lfsr_noise;
wire [ 7:0] envelope;
reg  [11:0] wave_out;
reg  [19:0] dca_out;

`define noise_ctrl   control[7]
`define pulse_ctrl   control[6]
`define saw_ctrl     control[5]
`define tri_ctrl     control[4]
`define test_ctrl    control[3]
`define ringmod_ctrl control[2]
`define sync_ctrl    control[1]

// Signal Assignments
assign osc_msb_out = oscillator[23];
assign signal_out  = dca_out[19:8];
assign osc_out     = wave_out[11:4];
assign env_out     = envelope;

// Digital Controlled Amplifier
always @(posedge clock) if(ce_1m) dca_out <= wave_out * envelope;

// Envelope Instantiation
sid_envelope adsr
(
	.clock(clock),
	.ce_1m(ce_1m),
	.reset(reset),
	.gate(control[0]),
	.att_dec(att_dec),
	.sus_rel(sus_rel),
	.envelope(envelope)
);

// Phase Accumulating Oscillator
always @(posedge clock) begin
	if(ce_1m) begin
		osc_msb_in_prv <= osc_msb_in;
		if (reset || `test_ctrl || ((`sync_ctrl) && (!osc_msb_in) && (osc_msb_in != osc_msb_in_prv)))
			oscillator <= 0;
		else
			oscillator <= oscillator + {freq_hi, freq_lo};
	end
end

// Waveform Generator
always @(posedge clock) begin
	if (reset) begin
		triangle   <= 0;
		sawtooth   <= 0;
		pulse      <= 0;
		noise      <= 0;
		osc_edge   <= 0;
		lfsr_noise <= 23'h7fffff;
	end
	else if(ce_1m) begin
      triangle   <=	(`ringmod_ctrl) ?
							{({11{osc_msb_in}} ^ {{11{oscillator[23]}}}) ^ oscillator[22:12], 1'b0} :
							{{11{oscillator[23]}} ^ oscillator[22:12], 1'b0};

      sawtooth   <=	oscillator[23:12];

      pulse      <= 	(`test_ctrl) ? 12'hfff :
							(oscillator[23:12] >= {pw_hi, pw_lo}) ? {12{1'b1}} :
							{12{1'b0}};

		noise      <= 	{lfsr_noise[21], lfsr_noise[19], lfsr_noise[15],
							lfsr_noise[12], lfsr_noise[10], lfsr_noise[6],
							lfsr_noise[3], lfsr_noise[1], 4'b0000};

		osc_edge   <= 	(oscillator[19] && !osc_edge) ? 1'b1 :
							(!oscillator[19] && osc_edge) ? 1'b0 :
							osc_edge;

		lfsr_noise <= 	(oscillator[19] && !osc_edge) ?
							{lfsr_noise[21:0], (lfsr_noise[22] | `test_ctrl) ^ lfsr_noise[17]} :
							lfsr_noise;
    end
end

// Waveform Output Selector
always @(*) begin
	case (control[7:4])
		4'b0001: wave_out = triangle;
		4'b0010: wave_out = sawtooth;
		4'b0011: wave_out = {_st_out, 4'b0000};
		4'b0100: wave_out = pulse;
		4'b0101: wave_out = {p_t_out, 4'b0000} & pulse;
		4'b0110: wave_out = {ps__out, 4'b0000} & pulse;
		4'b0111: wave_out = {pst_out, 4'b0000} & pulse;
		4'b1000: wave_out = noise;
		default: wave_out = 0;
	endcase
end


endmodule
