// -----------------------------------------------------------------------------
// Driver: converts flit items into valid/ready handshakes on the selected
// input port, honoring the DUT contract that valid stays asserted (with
// stable data) until ready (mirrors the DUT's StableValidIn assertion).
//
// It also owns the output-side ready lines: each output port's ready is
// re-randomized every cycle (~80% high) to exercise backpressure while
// remaining a legal sink.
//
// Timing discipline: all pins are driven with non-blocking assignments at
// posedge and all DUT outputs are read at posedge (pre-edge values), which
// matches SVA sampling semantics under Verilator --timing.
// -----------------------------------------------------------------------------
class floonoc_driver extends uvm_driver #(floonoc_flit_item);

  `uvm_component_utils(floonoc_driver)

  virtual floonoc_router_if vif;

  // Probability (percent) that an output-port ready is high in a given cycle
  int unsigned ready_pct = 80;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    int rp;
    super.build_phase(phase);
    if (!uvm_config_db#(virtual floonoc_router_if)::get(this, "", "vif", vif)) begin
      `uvm_fatal("DRV", "virtual interface not found in config_db")
    end
    // Overridable for backpressure scenarios (0 = outputs never ready,
    // used by the floonoc_neg_stall self-test)
    if (uvm_config_db#(int)::get(this, "", "ready_pct", rp)) begin
      if (rp < 0) rp = 0;
      ready_pct = unsigned'(rp);
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    floonoc_flit_item item;

    vif.valid_in  <= '0;
    vif.data_in   <= '0;
    vif.ready_out <= '1;

    fork
      drive_output_ready();
    join_none

    wait (vif.rst_n === 1'b1);
    @(posedge vif.clk);

    forever begin
      seq_item_port.get_next_item(item);
      drive_flit(item);
      seq_item_port.item_done();
    end
  endtask

  // Assert valid/data after the current edge; they participate in the
  // handshake from the next posedge on. Hold until ready seen at an edge.
  task drive_flit(floonoc_flit_item item);
    int unsigned p = item.src_port;
    vif.valid_in[p] <= 1'b1;
    vif.data_in[p]  <= item.as_flit();
    do begin
      @(posedge vif.clk);
    end while (!(vif.valid_in[p] === 1'b1 && vif.ready_in[p] === 1'b1));
    vif.valid_in[p] <= 1'b0;
    `uvm_info("DRV", {"sent: ", item.convert2string()}, UVM_HIGH)
  endtask

  // Legal random sink: ready may toggle freely; the DUT does not require
  // ready stability (ready/valid dependency rules only constrain valid).
  task drive_output_ready();
    forever begin
      @(posedge vif.clk);
      for (int unsigned o = 0; o < NumPorts; o++) begin
        vif.ready_out[o] <= bit'($urandom_range(99) < ready_pct);
      end
    end
  endtask

endclass : floonoc_driver
