// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 15.04.2017
// Description: Commits to the architectural state resulting from the scoreboard.

import ariane_pkg::*;

module commit_stage #(
    parameter int unsigned NR_COMMIT_PORTS = 2
)(
    input  logic                                    clk_i,
    input  logic                                    rst_ni,
    input  logic                                    halt_i,             // request to halt the core
    input  logic                                    flush_dcache_i,     // request to flush dcache -> also flush the pipeline
    output exception_t                              exception_o,        // take exception to controller
    input  logic                                    debug_mode_i,       // we are in debug mode
    input  logic                                    debug_req_i,        // debug unit is requesting to enter debug mode
    input  logic                                    single_step_i,      // we are in single step debug mode
    // from scoreboard
    input  scoreboard_entry_t [NR_COMMIT_PORTS-1:0] commit_instr_i,     // the instruction we want to commit
    output logic [NR_COMMIT_PORTS-1:0]              commit_ack_o,       // acknowledge that we are indeed committing
    // to register file
    output  logic [NR_COMMIT_PORTS-1:0][4:0]        waddr_o,            // register file write address
    output  logic [NR_COMMIT_PORTS-1:0][63:0]       wdata_o,            // register file write data
    output  logic [NR_COMMIT_PORTS-1:0]             we_o,               // register file write enable
    // Atomic memory operations
    input  amo_resp_t                               amo_resp_i,         // result of AMO operation
    // to CSR file and PC Gen (because on certain CSR instructions we'll need to flush the whole pipeline)
    output logic [63:0]                             pc_o,
    // to/from CSR file
    output fu_op                                    csr_op_o,           // decoded CSR operation
    output logic [63:0]                             csr_wdata_o,        // data to write to CSR
    input  logic [63:0]                             csr_rdata_i,        // data to read from CSR
    input  exception_t                              csr_exception_i,    // exception or interrupt occurred in CSR stage (the same as commit)
    // commit signals to ex
    output logic                                    commit_lsu_req_o,   // request commit of pending store
    input  logic                                    commit_lsu_ack_i,   // asserted when the LSU can commit the store requested
    output logic                                    amo_valid_commit_o, // valid AMO in commit stage
    input  logic                                    no_st_pending_i,    // there is no store pending
    output logic                                    commit_csr_o,       // commit the pending CSR instruction
    output logic                                    fence_i_o,          // flush I$ and pipeline
    output logic                                    fence_o,            // flush D$ and pipeline
    output logic                                    flush_commit_o,     // request a pipeline flush
    output logic                                    sfence_vma_o        // flush TLBs and pipeline
);

    assign waddr_o[0] = commit_instr_i[0].rd[4:0];
    assign waddr_o[1] = commit_instr_i[1].rd[4:0];

    assign pc_o = commit_instr_i[0].pc;

    logic instr_0_is_amo;
    assign instr_0_is_amo = is_amo(commit_instr_i[0].op);
    // -------------------
    // Commit Instruction
    // -------------------
    // write register file or commit instruction in LSU or CSR Buffer
    always_comb begin : commit
        // default assignments
        commit_ack_o[0] = 1'b0;
        commit_ack_o[1] = 1'b0;

        amo_valid_commit_o = 1'b0;

        we_o[0]         = 1'b0;
        we_o[1]         = 1'b0;

        commit_lsu_req_o= 1'b0;
        commit_csr_o    = 1'b0;
        // amos will commit on port 0
        wdata_o[0]      = (amo_resp_i.ack) ? amo_resp_i.result : commit_instr_i[0].result;
        wdata_o[1]      = commit_instr_i[1].result;
        csr_op_o        = ADD; // this corresponds to a CSR NOP
        csr_wdata_o     = 64'b0;
        fence_i_o       = 1'b0;
        fence_o         = 1'b0;
        sfence_vma_o    = 1'b0;
        flush_commit_o  = 1'b0;

        // we will not commit the instruction if we took an exception
        // and we do not commit the instruction if we requested a halt
        // furthermore if the debugger is requesting to debug do not commit this instruction if we are not yet in debug mode
        // also check that there is no atomic memory operation committing, right now this is the only operation
        // which will take longer than one cycle to commit
        if (commit_instr_i[0].valid && !halt_i && (!debug_req_i || debug_mode_i)) begin

            commit_ack_o[0] = 1'b1;
            // register will be the all zero register.
            // and also acknowledge the instruction, this is mainly done for the instruction tracer
            // as it will listen on the instruction ack signal. For the overall result it does not make any
            // difference as the whole pipeline is going to be flushed anyway.
            if (!exception_o.valid) begin
                // we can definitely write the register file
                // if the instruction is not committing anything the destination
                we_o[0] = 1'b1;

                // check whether the instruction we retire was a store
                // do not commit the instruction if we got an exception since the store buffer will be cleared
                // by the subsequent flush triggered by an exception
                if (commit_instr_i[0].fu == STORE && !instr_0_is_amo) begin
                    // check if the LSU is ready to accept another commit entry (e.g.: a non-speculative store)
                    commit_lsu_req_o = 1'b1;
                    // if the LSU buffer is not ready - do not commit, wait
                    commit_ack_o[0] = commit_lsu_ack_i;
                end
            end

            // ---------
            // CSR Logic
            // ---------
            // check whether the instruction we retire was a CSR instruction
            if (commit_instr_i[0].fu == CSR) begin
                // write the CSR file
                commit_csr_o = 1'b1;
                wdata_o[0]   = csr_rdata_i;
                csr_op_o     = commit_instr_i[0].op;
                csr_wdata_o  = commit_instr_i[0].result;
            end
            // ------------------
            // SFENCE.VMA Logic
            // ------------------
            // check if this instruction was a SFENCE_VMA
            if (commit_instr_i[0].op == SFENCE_VMA) begin
                // no store pending so we can flush the TLBs and pipeline
                sfence_vma_o = no_st_pending_i;
                // wait for the store buffer to drain until flushing the pipeline
                commit_ack_o[0] = no_st_pending_i;
            end
            // ------------------
            // FENCE.I Logic
            // ------------------
            // Fence synchronizes data and instruction streams. That means that we need to flush the private icache
            // and the private dcache. This is the most expensive instruction.
            if (commit_instr_i[0].op == FENCE_I || (flush_dcache_i && commit_instr_i[0].fu != STORE)) begin
                commit_ack_o[0] = no_st_pending_i;
                // tell the controller to flush the I$
                fence_i_o = no_st_pending_i;
            end
            // ------------------
            // FENCE Logic
            // ------------------
            if (commit_instr_i[0].op == FENCE) begin
                commit_ack_o[0] = no_st_pending_i;
                // tell the controller to flush the D$
                fence_o = no_st_pending_i;
            end
            // ------------------
            // AMO
            // ------------------
            if (instr_0_is_amo && !exception_o.valid) begin
                // AMO finished
                commit_ack_o[0] = amo_resp_i.ack;
                // flush the pipeline
                flush_commit_o = amo_resp_i.ack;
                amo_valid_commit_o = 1'b1;
                we_o[0] = amo_resp_i.ack;
            end
        end

        // -----------------
        // Commit Port 2
        // -----------------
        // check if the second instruction can be committed as well and the first wasn't a CSR instruction
        // also if we are in single step mode don't retire the second instruction
        if (commit_ack_o[0] && commit_instr_i[1].valid
                            && !halt_i
                            && !(commit_instr_i[0].fu inside {CSR})
                            && !flush_dcache_i
                            && !instr_0_is_amo
                            && !single_step_i) begin
            // only if the first instruction didn't throw an exception and this instruction won't throw an exception
            // and the operator is of type ALU, LOAD, CTRL_FLOW, MULT
            if (!exception_o.valid && !commit_instr_i[1].ex.valid
                                   && (commit_instr_i[1].fu inside {ALU, LOAD, CTRL_FLOW, MULT})) begin
                we_o[1] = 1'b1;
                commit_ack_o[1] = 1'b1;
            end
        end
    end

    // -----------------------------
    // Exception & Interrupt Logic
    // -----------------------------
    // here we know for sure that we are taking the exception
    always_comb begin : exception_handling
        // Multiple simultaneous interrupts and traps at the same privilege level are handled in the following decreasing
        // priority order: external interrupts, software interrupts, timer interrupts, then finally any synchronous traps. (1.10 p.30)
        // interrupts are correctly prioritized in the CSR reg file, exceptions are prioritized here
        exception_o.valid = 1'b0;
        exception_o.cause = 64'b0;
        exception_o.tval  = 64'b0;
        // we need a valid instruction in the commit stage, otherwise we might loose the PC in case of interrupts as they
        // can happen anywhere in the execution flow and might just happen between two legal instructions - the PC would then
        // be outdated. The solution here is to defer any exception/interrupt until we get a valid PC again (from where we cane
        // resume execution afterwards).
        if (commit_instr_i[0].valid) begin
            // ------------------------
            // check for CSR exception
            // ------------------------
            if (csr_exception_i.valid && !csr_exception_i.cause[63]) begin
                exception_o      = csr_exception_i;
                // if no earlier exception happened the commit instruction will still contain
                // the instruction data from the ID stage. If a earlier exception happened we don't care
                // as we will overwrite it anyway in the next IF bl
                exception_o.tval = commit_instr_i[0].ex.tval;
            end
            // ------------------------
            // Earlier Exceptions
            // ------------------------
            // but we give precedence to exceptions which happened earlier
            if (commit_instr_i[0].ex.valid) begin
                exception_o = commit_instr_i[0].ex;
            end
            // ------------------------
            // Interrupts
            // ------------------------
            // check for CSR interrupts (e.g.: normal interrupts which get triggered here)
            // by putting interrupts here we give them precedence over any other exception
            // Don't take the interrupt if we are committing an AMO.
            if (csr_exception_i.valid && csr_exception_i.cause[63] && !amo_valid_commit_o) begin
                exception_o = csr_exception_i;
                exception_o.tval = commit_instr_i[0].ex.tval;
            end
        end
        // Don't take any exceptions iff:
        // - If we halted the processor
        if (halt_i) begin
            exception_o.valid = 1'b0;
        end
    end

endmodule
