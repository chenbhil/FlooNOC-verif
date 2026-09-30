// -----------------------------------------------------------------------------
// Leaf sequence: sends a prepared list of items, in order, on ONE router's
// sequencer. Every item's src_router must equal that router (the driver
// fatals otherwise). Each finish_item returns after the driver has seen the
// input handshake, so on return `items[i].accept_time` holds the handshake
// edge — which is what the hotspot simultaneity self-check reads.
// -----------------------------------------------------------------------------
class floonoc_mesh_send_seq extends uvm_sequence #(floonoc_mesh_flit_item);

  `uvm_object_utils(floonoc_mesh_send_seq)

  floonoc_mesh_flit_item items[$];

  function new(string name = "floonoc_mesh_send_seq");
    super.new(name);
  endfunction

  virtual task body();
    foreach (items[i]) begin
      start_item(items[i]);
      finish_item(items[i]);
    end
  endtask

endclass : floonoc_mesh_send_seq
