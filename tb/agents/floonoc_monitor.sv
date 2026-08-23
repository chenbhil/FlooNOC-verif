// -----------------------------------------------------------------------------
// Monitor: observes every input-port and output-port handshake and publishes
// the transactions through two analysis ports. Backpressure (valid && !ready)
// seen while a flit waits is recorded on the transaction for coverage.
// -----------------------------------------------------------------------------
class floonoc_monitor extends uvm_monitor;

  `uvm_component_utils(floonoc_monitor)

  virtual floonoc_router_if vif;

  uvm_analysis_port #(floonoc_flit_item) in_ap;   // accepted input flits
  uvm_analysis_port #(floonoc_flit_item) out_ap;  // delivered output flits

  // Sticky per-port backpressure trackers (cleared on handshake)
  protected bit in_bp  [NumPorts];
  protected bit out_bp [NumPorts];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    in_ap  = new("in_ap", this);
    out_ap = new("out_ap", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual floonoc_router_if)::get(this, "", "vif", vif)) begin
      `uvm_fatal("MON", "virtual interface not found in config_db")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    floonoc_flit_item item;
    wait (vif.rst_n === 1'b1);
    forever begin
      @(posedge vif.clk);
      for (int unsigned p = 0; p < NumPorts; p++) begin
        // Input side
        if (vif.valid_in[p] === 1'b1 && vif.ready_in[p] !== 1'b1) begin
          in_bp[p] = 1'b1;
        end
        if (vif.valid_in[p] === 1'b1 && vif.ready_in[p] === 1'b1) begin
          item = floonoc_flit_item::type_id::create($sformatf("mon_in_p%0d", p));
          item.from_flit(vif.data_in[p], p, /*is_output*/ 1'b0, in_bp[p]);
          in_bp[p] = 1'b0;
          `uvm_info("MON", {"in : ", item.convert2string()}, UVM_HIGH)
          in_ap.write(item);
        end
        // Output side
        if (vif.valid_out[p] === 1'b1 && vif.ready_out[p] !== 1'b1) begin
          out_bp[p] = 1'b1;
        end
        if (vif.valid_out[p] === 1'b1 && vif.ready_out[p] === 1'b1) begin
          item = floonoc_flit_item::type_id::create($sformatf("mon_out_p%0d", p));
          item.from_flit(vif.data_out[p], p, /*is_output*/ 1'b1, out_bp[p]);
          out_bp[p] = 1'b0;
          `uvm_info("MON", {"out: ", item.convert2string()}, UVM_HIGH)
          out_ap.write(item);
        end
      end
    end
  endtask

endclass : floonoc_monitor
