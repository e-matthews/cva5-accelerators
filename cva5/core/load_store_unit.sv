/*
 * Copyright © 2017-2019 Eric Matthews,  Lesley Shannon
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Initial code developed under the supervision of Dr. Lesley Shannon,
 * Reconfigurable Computing Lab, Simon Fraser University.
 *
 * Author(s):
 *             Eric Matthews <ematthew@sfu.ca>
 */

module load_store_unit

    import cva5_config::*;
    import riscv_types::*;
    import cva5_types::*;
    import opcodes::*;

    # (
        parameter cpu_config_t CONFIG = EXAMPLE_CONFIG
    )

    (
        input logic clk,
        input logic rst,
        input gc_outputs_t gc,

        input decode_packet_t decode_stage,
        output logic unit_needed,
        output logic [REGFILE_READ_PORTS-1:0] uses_rs,
        output logic uses_rd,
        output logic decode_is_store,

        input issue_packet_t issue_stage,
        input logic issue_stage_ready,
        input logic instruction_issued_with_rd,
        input logic rs2_inuse,
        input rs_addr_t issue_rs_addr [REGFILE_READ_PORTS],
        input logic [$clog2(CONFIG.NUM_WB_GROUPS)-1:0] issue_rd_wb_group,
        input logic [31:0] rf [REGFILE_READ_PORTS],

        unit_issue_interface.unit issue,

        input logic dcache_on,
        input logic clear_reservation,
        tlb_interface.requester tlb,
        input logic tlb_on,

        l1_arbiter_request_interface.master l1_request,
        l1_arbiter_return_interface.master l1_response,
        input sc_complete,
        input sc_success,

        axi_interface.master m_axi,
        avalon_interface.master m_avalon,
        wishbone_interface.master dwishbone,

        local_memory_interface.master data_bram,

        //Writeback-Store Interface
        input wb_packet_t wb_packet [CONFIG.NUM_WB_GROUPS],

        //Retire release
        input retire_packet_t store_retire,

        exception_interface.unit exception,
        output load_store_status_t load_store_status,
        unit_writeback_interface.unit wb
    );

    localparam NUM_SUB_UNITS = int'(CONFIG.INCLUDE_DLOCAL_MEM) + int'(CONFIG.INCLUDE_PERIPHERAL_BUS) + int'(CONFIG.INCLUDE_DCACHE);
    localparam NUM_SUB_UNITS_W = (NUM_SUB_UNITS == 1) ? 1 : $clog2(NUM_SUB_UNITS);

    localparam LOCAL_MEM_ID = 0;
    localparam BUS_ID = int'(CONFIG.INCLUDE_DLOCAL_MEM);
    localparam DCACHE_ID = int'(CONFIG.INCLUDE_DLOCAL_MEM) + int'(CONFIG.INCLUDE_PERIPHERAL_BUS);

    //Should be equal to pipeline depth of longest load/store subunit 
    localparam ATTRIBUTES_DEPTH = 1;

    //Subunit signals
    addr_utils_interface #(CONFIG.DLOCAL_MEM_ADDR.L, CONFIG.DLOCAL_MEM_ADDR.H) dlocal_mem_addr_utils ();
    addr_utils_interface #(CONFIG.PERIPHERAL_BUS_ADDR.L, CONFIG.PERIPHERAL_BUS_ADDR.H) dpbus_addr_utils ();
    addr_utils_interface #(CONFIG.DCACHE_ADDR.L, CONFIG.DCACHE_ADDR.H) dcache_addr_utils ();
    memory_sub_unit_interface sub_unit[NUM_SUB_UNITS-1:0]();

    addr_utils_interface #(CONFIG.DCACHE.NON_CACHEABLE.L, CONFIG.DCACHE.NON_CACHEABLE.H) uncacheable_utils ();

    logic [NUM_SUB_UNITS-1:0] sub_unit_address_match;

    data_access_shared_inputs_t shared_inputs;
    logic [31:0] unit_data_array [NUM_SUB_UNITS-1:0];
    logic [NUM_SUB_UNITS-1:0] unit_ready;
    logic [NUM_SUB_UNITS-1:0] unit_data_valid;
    logic [NUM_SUB_UNITS-1:0] last_unit;

    logic sub_unit_ready;
    logic [NUM_SUB_UNITS_W-1:0] subunit_id;

    logic unit_switch;
    logic unit_switch_in_progress;
    logic unit_switch_hold;

    logic sel_load;
    logic sub_unit_issue;
    logic sub_unit_load_issue;
    logic sub_unit_store_issue;

    logic load_complete;

    logic [31:0] virtual_address;

    logic [31:0] unit_muxed_load_data;
    logic [31:0] aligned_load_data;
    logic [31:0] final_load_data;

    logic unaligned_addr;
    logic load_exception_complete;
    logic fence_hold;

    typedef struct packed{
        logic is_signed;
        logic [1:0] byte_addr;
        logic [1:0] sign_sel;
        logic [1:0] final_mux_sel;
        id_t id;
        logic [NUM_SUB_UNITS_W-1:0] subunit_id;
    } load_attributes_t;
    load_attributes_t  mem_attr, wb_attr;

    common_instruction_t instruction;//rs1_addr, rs2_addr, fn3, fn7, rd_addr, upper/lower opcode

    logic [3:0] be;
    //FIFOs
    fifo_interface #(.DATA_WIDTH($bits(load_attributes_t))) load_attributes();

    load_store_queue_interface lsq();
    ////////////////////////////////////////////////////
    //Implementation

    ////////////////////////////////////////////////////
    //Decode
    assign instruction = decode_stage.instruction;

    assign unit_needed = decode_stage.instruction inside {LB, LH, LW, LBU, LHU, SB, SH, SW, FENCE};
    always_comb begin
        uses_rs = '0;
        uses_rs[RS1] = decode_stage.instruction inside {LB, LH, LW, LBU, LHU, SB, SH, SW};
        uses_rs[RS2] = CONFIG.INCLUDE_FORWARDING_TO_STORES ? 0 : decode_stage.instruction inside {SB, SH, SW};
        uses_rd = decode_stage.instruction inside {LB, LH, LW, LBU, LHU};
    end

    amo_details_t amo;
    amo_details_t amo_r;
    logic is_load;
    logic is_store;
    logic is_load_r;
    logic is_store_r;
    logic is_fence_r;
    logic [2:0] fn3_r;
    logic [11:0] ls_offset_r;

    assign amo.is_amo =  CONFIG.INCLUDE_AMO & (instruction.upper_opcode == AMO_T);
    assign amo.op = CONFIG.INCLUDE_AMO ? decode_stage.instruction[31:27] : '0;
    assign amo.is_lr = CONFIG.INCLUDE_AMO & (amo.op == AMO_LR_FN5);
    assign amo.is_sc = CONFIG.INCLUDE_AMO & (amo.op == AMO_SC_FN5);

    assign is_load = (instruction.upper_opcode inside {LOAD_T, AMO_T}) & !(amo.is_amo & amo.is_sc); //LR and AMO_ops perform a read operation as well
    assign is_store = (instruction.upper_opcode == STORE_T) | (amo.is_amo & amo.is_sc);//Used for LS unit and for ID tracking
    assign decode_is_store = is_store;

    always_ff @(posedge clk) begin
        if (issue_stage_ready) begin
            ls_offset_r <= decode_stage.instruction[5] ? {decode_stage.instruction[31:25], decode_stage.instruction[11:7]} : decode_stage.instruction[31:20];
            is_load_r <= is_load;
            is_store_r <= is_store;
            is_fence_r <= (instruction.upper_opcode == FENCE_T);
            amo_r <= amo;
            fn3_r <= amo.is_amo ? LS_W_fn3 : instruction.fn3;
        end
    end

    (* ramstyle = "MLAB, no_rw_check" *) id_t rd_to_id_table [32];
    (* ramstyle = "MLAB, no_rw_check" *) logic [$clog2(CONFIG.NUM_WB_GROUPS)-1:0] rd_to_wb_group_table [32];

    id_t store_forward_id;
    logic [$clog2(CONFIG.NUM_WB_GROUPS)-1:0] store_forward_wb_group;

    always_ff @ (posedge clk) begin
        if (instruction_issued_with_rd) begin
            rd_to_id_table[issue_stage.rd_addr] <= issue_stage.id;
            rd_to_wb_group_table[issue_stage.rd_addr] <= issue_rd_wb_group;
        end
    end

    assign store_forward_id = rd_to_id_table[issue_rs_addr[RS2]];
    assign store_forward_wb_group = rs2_inuse ? rd_to_wb_group_table[issue_rs_addr[RS2]] : '0;

    ////////////////////////////////////////////////////
    //Alignment Exception
    generate if (CONFIG.INCLUDE_M_MODE) begin : gen_ls_exceptions
        logic new_exception;
        always_comb begin
            case(fn3_r)
                LS_H_fn3, L_HU_fn3 : unaligned_addr = virtual_address[0];
                LS_W_fn3 : unaligned_addr = |virtual_address[1:0];
                default : unaligned_addr = 0;
            endcase
        end

        assign new_exception = unaligned_addr & issue.new_request & ~is_fence_r;
        always_ff @(posedge clk) begin
            if (rst)
                exception.valid <= 0;
            else
                exception.valid <= (exception.valid & ~exception.ack) | new_exception;
        end

        always_ff @(posedge clk) begin
            if (new_exception & ~exception.valid) begin
                exception.code <= is_store_r ? STORE_AMO_ADDR_MISSALIGNED : LOAD_ADDR_MISSALIGNED;
                exception.tval <= virtual_address;
                exception.id <= issue.id;
            end
        end

        always_ff @(posedge clk) begin
            if (rst)
                load_exception_complete <= 0;
            else
                load_exception_complete <= exception.valid & exception.ack & (exception.code == LOAD_ADDR_MISSALIGNED);
        end
    end endgenerate

    ////////////////////////////////////////////////////
    //Load-Store status
    assign load_store_status = '{
        sq_empty : lsq.sq_empty,
        no_released_stores_pending : lsq.no_released_stores_pending,
        idle : lsq.empty & (~load_attributes.valid) & (&unit_ready)
    };

    ////////////////////////////////////////////////////
    //TLB interface
    assign virtual_address = rf[RS1] + 32'(signed'(ls_offset_r));

    assign tlb.virtual_address = virtual_address;
    assign tlb.new_request = tlb_on & issue.new_request;
    assign tlb.execute = 0;
    assign tlb.rnw = is_load_r & ~is_store_r;

    ////////////////////////////////////////////////////
    //Byte enable generation
    //Only set on store
    //  SW: all bytes
    //  SH: upper or lower half of bytes
    //  SB: specific byte
    always_comb begin
        be = 0;
        case(fn3_r[1:0])
            LS_B_fn3[1:0] : be[virtual_address[1:0]] = 1;
            LS_H_fn3[1:0] : begin
                be[virtual_address[1:0]] = 1;
                be[{virtual_address[1], 1'b1}] = 1;
            end
            default : be = '1;
        endcase
    end

    ////////////////////////////////////////////////////
    //Load Store Queue
    assign lsq.data_in = '{
        addr : tlb_on ? tlb.physical_address : virtual_address,
        fn3 : fn3_r,
        be : be,
        data : rf[RS2],
        load : is_load_r,
        store : is_store_r,
        id : issue.id,
        id_needed : store_forward_id
    };

    assign lsq.potential_push = issue.possible_issue;
    assign lsq.push = issue.new_request & ~unaligned_addr & (~tlb_on | tlb.done) & ~is_fence_r;

    load_store_queue  # (.CONFIG(CONFIG)) lsq_block (
        .clk (clk),
        .rst (rst),
        .gc (gc),
        .lsq (lsq),
        .store_forward_wb_group (store_forward_wb_group),
        .wb_packet (wb_packet),
        .store_retire (store_retire)
    );
    assign shared_inputs = sel_load ? lsq.load_data_out : lsq.store_data_out;
    assign lsq.load_pop = sub_unit_load_issue;
    assign lsq.store_pop = sub_unit_store_issue;

    ////////////////////////////////////////////////////
    //Unit tracking
    always_ff @ (posedge clk) begin
        if (load_attributes.push)
            last_unit <= sub_unit_address_match;
    end

    //When switching units, ensure no outstanding loads so that there can be no timing collisions with results
    assign unit_switch = lsq.load_valid & (sub_unit_address_match != last_unit) & load_attributes.valid;
    always_ff @ (posedge clk) begin
        unit_switch_in_progress <= (unit_switch_in_progress | unit_switch) & ~load_attributes.valid;
    end
    assign unit_switch_hold = unit_switch | unit_switch_in_progress;

    ////////////////////////////////////////////////////
    //Primary Control Signals
    assign sel_load = lsq.load_valid;

    assign sub_unit_ready = unit_ready[subunit_id] & (~unit_switch_hold);
    assign load_complete = |unit_data_valid;

    assign issue.ready = (~tlb_on | tlb.ready) & (~lsq.full) & (~fence_hold) & (~exception.valid);

    assign sub_unit_load_issue = sel_load & lsq.load_valid & sub_unit_ready & sub_unit_address_match[subunit_id];
    assign sub_unit_store_issue = (lsq.store_valid & ~sel_load) & sub_unit_ready & sub_unit_address_match[subunit_id];
    assign sub_unit_issue = sub_unit_load_issue | sub_unit_store_issue;

    always_ff @ (posedge clk) begin
        if (rst)
            fence_hold <= 0;
        else
            fence_hold <= (fence_hold & ~load_store_status.idle) | (issue.new_request & is_fence_r);
    end

    ////////////////////////////////////////////////////
    //Load attributes FIFO
    logic [1:0] final_mux_sel;

    one_hot_to_integer #(NUM_SUB_UNITS)
    sub_unit_select (
        .one_hot (sub_unit_address_match), 
        .int_out (subunit_id)
    );

    always_comb begin
        case(lsq.load_data_out.fn3)
            LS_B_fn3, L_BU_fn3 : final_mux_sel = 0;
            LS_H_fn3, L_HU_fn3 : final_mux_sel = 1;
            default : final_mux_sel = 2; //LS_W_fn3
        endcase
    end
    
    assign mem_attr = '{
        is_signed : ~|lsq.load_data_out.fn3[2:1],
        byte_addr : lsq.load_data_out.addr[1:0],
        sign_sel : lsq.load_data_out.addr[1:0] | {1'b0, lsq.load_data_out.fn3[0]},//halfwrord
        final_mux_sel : final_mux_sel,
        id : lsq.load_data_out.id,
        subunit_id : subunit_id
    };

    assign load_attributes.data_in = mem_attr;
    assign load_attributes.push = sub_unit_load_issue;
    assign load_attributes.potential_push = load_attributes.push;
    
    cva5_fifo #(.DATA_WIDTH($bits(load_attributes_t)), .FIFO_DEPTH(ATTRIBUTES_DEPTH))
    attributes_fifo (
        .clk (clk),
        .rst (rst), 
        .fifo (load_attributes)
    );

    assign load_attributes.pop = load_complete;
    assign wb_attr = load_attributes.data_out;
    ////////////////////////////////////////////////////
    //Unit Instantiation
    generate for (genvar i=0; i < NUM_SUB_UNITS; i++) begin : gen_load_store_sources
        assign sub_unit[i].new_request = sub_unit_issue & sub_unit_address_match[i];
        assign sub_unit[i].addr = shared_inputs.addr;
        assign sub_unit[i].re = shared_inputs.load;
        assign sub_unit[i].we = shared_inputs.store;
        assign sub_unit[i].be = shared_inputs.be;
        assign sub_unit[i].data_in = shared_inputs.data_in;

        assign unit_ready[i] = sub_unit[i].ready;
        assign unit_data_valid[i] = sub_unit[i].data_valid;
        assign unit_data_array[i] = sub_unit[i].data_out;
    end
    endgenerate

    generate if (CONFIG.INCLUDE_DLOCAL_MEM) begin : gen_ls_local_mem
        assign sub_unit_address_match[LOCAL_MEM_ID] = dlocal_mem_addr_utils.address_range_check(shared_inputs.addr);
        local_mem_sub_unit d_local_mem (
            .clk (clk), 
            .rst (rst),
            .unit (sub_unit[LOCAL_MEM_ID]),
            .local_mem (data_bram)
        );
        end
    endgenerate

    generate if (CONFIG.INCLUDE_PERIPHERAL_BUS) begin : gen_ls_pbus
            assign sub_unit_address_match[BUS_ID] = dpbus_addr_utils.address_range_check(shared_inputs.addr);
            if(CONFIG.PERIPHERAL_BUS_TYPE == AXI_BUS)
                axi_master axi_bus (
                    .clk (clk),
                    .rst (rst),
                    .m_axi (m_axi),
                    .size ({1'b0,shared_inputs.fn3[1:0]}),
                    .ls (sub_unit[BUS_ID])
                ); //Lower two bits of fn3 match AXI specification for request size (byte/halfword/word)
            else if (CONFIG.PERIPHERAL_BUS_TYPE == WISHBONE_BUS)
                wishbone_master wishbone_bus (
                    .clk (clk),
                    .rst (rst),
                    .wishbone (dwishbone),
                    .ls (sub_unit[BUS_ID])
                );
            else if (CONFIG.PERIPHERAL_BUS_TYPE == AVALON_BUS)  begin
                avalon_master avalon_bus (
                    .clk (clk),
                    .rst (rst),
                    .m_avalon (m_avalon), 
                    .ls (sub_unit[BUS_ID])
                );
            end
        end
    endgenerate

    generate if (CONFIG.INCLUDE_DCACHE) begin : gen_ls_dcache
            logic load_ready;
            logic store_ready;
            logic uncacheable_load;
            logic uncacheable_store;
            logic dcache_load_request;
            logic dcache_store_request;

            assign sub_unit_address_match[DCACHE_ID] = dcache_addr_utils.address_range_check(shared_inputs.addr);

            assign uncacheable_load = CONFIG.DCACHE.USE_NON_CACHEABLE & uncacheable_utils.address_range_check(shared_inputs.addr);
            assign uncacheable_store = CONFIG.DCACHE.USE_NON_CACHEABLE & uncacheable_utils.address_range_check(shared_inputs.addr);

            assign dcache_load_request = sub_unit_load_issue & sub_unit_address_match[DCACHE_ID];
            assign dcache_store_request = sub_unit_store_issue & sub_unit_address_match[DCACHE_ID];

            dcache # (.CONFIG(CONFIG))
            data_cache (
                .clk (clk),
                .rst (rst),
                .dcache_on (dcache_on),
                .l1_request (l1_request),
                .l1_response (l1_response),
                .sc_complete (sc_complete),
                .sc_success (sc_success),
                .clear_reservation (clear_reservation),
                .amo (amo_r),
                .uncacheable_load (uncacheable_load),
                .uncacheable_store (uncacheable_store),
                .is_load (sel_load),
                .load_ready (load_ready),
                .store_ready (store_ready),
                .load_request (dcache_load_request),
                .store_request (dcache_store_request),
                .ls_load (lsq.load_data_out),
                .ls_store (lsq.store_data_out),
                .ls (sub_unit[DCACHE_ID])
            );
        end
    endgenerate

    ////////////////////////////////////////////////////
    //Output Muxing
    logic sign_bit_data [4];
    logic sign_bit;
    
    assign unit_muxed_load_data = unit_data_array[wb_attr.subunit_id];

    //Byte/halfword select: assumes aligned operations
    assign aligned_load_data[31:16] = unit_muxed_load_data[31:16];
    assign aligned_load_data[15:8] = wb_attr.byte_addr[1] ? unit_muxed_load_data[31:24] : unit_muxed_load_data[15:8];
    assign aligned_load_data[7:0] = unit_muxed_load_data[wb_attr.byte_addr*8 +: 8];

    assign sign_bit_data = '{unit_muxed_load_data[7], unit_muxed_load_data[15], unit_muxed_load_data[23], unit_muxed_load_data[31]};
    assign sign_bit = wb_attr.is_signed & sign_bit_data[wb_attr.sign_sel];

    //Sign extending
    always_comb begin
        case(wb_attr.final_mux_sel)
            0 : final_load_data = {{24{sign_bit}}, aligned_load_data[7:0]};
            1 : final_load_data = {{16{sign_bit}}, aligned_load_data[15:0]};
            default : final_load_data = aligned_load_data; //LS_W_fn3
        endcase
    end

    ////////////////////////////////////////////////////
    //Output bank
    assign wb.rd = final_load_data;
    assign wb.done = load_complete | load_exception_complete;
    assign wb.id = load_exception_complete ? exception.id : wb_attr.id;

    ////////////////////////////////////////////////////
    //End of Implementation
    ////////////////////////////////////////////////////

    ////////////////////////////////////////////////////
    //Assertions
    spurious_load_complete_assertion:
        assert property (@(posedge clk) disable iff (rst) load_complete |-> (load_attributes.valid && unit_data_valid[wb_attr.subunit_id]))
        else $error("Spurious load complete detected!");


endmodule
